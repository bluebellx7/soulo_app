import AVFoundation
import Foundation
import QuartzCore
import WebKit

private struct StreamingUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

enum StreamingMediaDownloadError: LocalizedError {
    case unavailable
    case alreadyInProgress
    case unsupportedManifest
    case invalidChunk
    case missingTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return AppLocalization.string("resource_stream_download_unavailable")
        case .alreadyInProgress:
            return AppLocalization.string("downloading")
        case .unsupportedManifest:
            return AppLocalization.string("resource_stream_download_unsupported")
        case .invalidChunk:
            return AppLocalization.string("resource_stream_download_invalid_chunk")
        case .missingTrack:
            return AppLocalization.string("resource_stream_download_missing_track")
        case .exportFailed(let message):
            return message.isEmpty
                ? AppLocalization.string("resource_stream_download_export_failed")
                : message
        }
    }
}

private actor StreamingTrackWriter {
    enum Track: String { case video, audio }

    private let videoHandle: FileHandle
    private let audioHandle: FileHandle
    private var nextIndexes: [Track: Int] = [.video: 0, .audio: 0]
    private var byteCounts: [Track: Int64] = [.video: 0, .audio: 0]
    private var isClosed = false

    init(videoURL: URL, audioURL: URL) throws {
        guard FileManager.default.createFile(atPath: videoURL.path, contents: nil),
              FileManager.default.createFile(atPath: audioURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        videoHandle = try FileHandle(forWritingTo: videoURL)
        audioHandle = try FileHandle(forWritingTo: audioURL)
    }

    func append(_ data: Data, to track: Track, index: Int) throws -> (video: Int64, audio: Int64) {
        guard !isClosed, nextIndexes[track] == index else {
            throw StreamingMediaDownloadError.invalidChunk
        }
        try (track == .video ? videoHandle : audioHandle).write(contentsOf: data)
        nextIndexes[track, default: 0] += 1
        byteCounts[track, default: 0] += Int64(data.count)
        return (byteCounts[.video, default: 0], byteCounts[.audio, default: 0])
    }

    func close() throws -> (video: Int64, audio: Int64) {
        if !isClosed {
            try videoHandle.close()
            try audioHandle.close()
            isClosed = true
        }
        return (byteCounts[.video, default: 0], byteCounts[.audio, default: 0])
    }
}

@MainActor
final class StreamingMediaDownloadService: NSObject, WKScriptMessageHandlerWithReply, @preconcurrency AVAssetDownloadDelegate {
    static let shared = StreamingMediaDownloadService()
    static let messageHandlerName = "souloSABRDownload"
    private static let sabrEngineVersion = 2
    static let hlsSessionIdentifier = "com.dkluge.Soulo.hls-downloads"
    private static var streamingTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloStreamingMedia", isDirectory: true)
    }

    private final class Transfer {
        let identifier: String
        let itemID: UUID
        let destinationURL: URL
        let directoryURL: URL
        let videoURL: URL
        let audioURL: URL
        let writer: StreamingTrackWriter
        weak var webView: WKWebView?
        var expectedVideoBytes: Int64 = 0
        var expectedAudioBytes: Int64 = 0
        var failureMessage = ""
        var isCanceled = false
        var isPaused = false
        var pendingChunkReplies: [(Any?, String?) -> Void] = []

        init(
            identifier: String,
            itemID: UUID,
            destinationURL: URL,
            directoryURL: URL,
            videoURL: URL,
            audioURL: URL,
            writer: StreamingTrackWriter,
            webView: WKWebView
        ) {
            self.identifier = identifier
            self.itemID = itemID
            self.destinationURL = destinationURL
            self.directoryURL = directoryURL
            self.videoURL = videoURL
            self.audioURL = audioURL
            self.writer = writer
            self.webView = webView
        }
    }

    private final class HLSTransfer {
        let itemID: UUID
        let sourceURL: URL?
        let destinationURL: URL
        let stagingDirectoryURL: URL
        let continuation: CheckedContinuation<URL, Error>?
        var downloadedAssetURL: URL?
        var isCanceled = false

        init(
            itemID: UUID,
            sourceURL: URL?,
            destinationURL: URL,
            stagingDirectoryURL: URL,
            continuation: CheckedContinuation<URL, Error>?
        ) {
            self.itemID = itemID
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
            self.stagingDirectoryURL = stagingDirectoryURL
            self.continuation = continuation
        }
    }

    private var transfers: [String: Transfer] = [:]
    private var identifiersByItemID: [UUID: String] = [:]
    private var hlsTransfers: [Int: HLSTransfer] = [:]
    private var cancelObserver: NSObjectProtocol?
    private let directSession: URLSession
    nonisolated static let nativeFetchBridgeScript = #"""
    (() => {
        if (window.__souloNativeFetchBridgeInstalled) return;
        const originalFetch = window.fetch.bind(window);

        function encodeBase64(bytes) {
            let binary = '';
            for (let offset = 0; offset < bytes.length; offset += 32768) {
                const part = bytes.subarray(offset, Math.min(offset + 32768, bytes.length));
                binary += String.fromCharCode.apply(null, Array.from(part));
            }
            return btoa(binary);
        }

        function decodeBase64(value) {
            const binary = atob(String(value || ''));
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; index += 1) {
                bytes[index] = binary.charCodeAt(index);
            }
            return bytes;
        }

        async function bodyBase64(body) {
            if (body == null) return '';
            if (typeof body === 'string') return encodeBase64(new TextEncoder().encode(body));
            if (body instanceof URLSearchParams) {
                return encodeBase64(new TextEncoder().encode(body.toString()));
            }
            if (body instanceof ArrayBuffer) return encodeBase64(new Uint8Array(body));
            if (ArrayBuffer.isView(body)) {
                return encodeBase64(new Uint8Array(body.buffer, body.byteOffset, body.byteLength));
            }
            if (body instanceof Blob) return encodeBase64(new Uint8Array(await body.arrayBuffer()));
            throw new TypeError('Unsupported native fetch request body');
        }

        window.__souloNativeFetch = async function(input, init) {
            const urlValue = input instanceof Request ? input.url : String(input);
            let parsedURL;
            try { parsedURL = new URL(urlValue, location.href); } catch (_) {
                return originalFetch(input, init);
            }
            const host = parsedURL.hostname.toLowerCase();
            const isBotGuard = host === 'jnn-pa.googleapis.com';
            const isGoogleVideoSABR = (host === 'googlevideo.com' || host.endsWith('.googlevideo.com'))
                && parsedURL.searchParams.get('sabr') === '1';
            if (parsedURL.protocol !== 'https:' || (!isBotGuard && !isGoogleVideoSABR)) {
                return originalFetch(input, init);
            }

            // Keep media requests in the page's WebKit network session. The
            // active SABR URL can be bound to the player session and return
            // 403 when replayed by a separate URLSession.
            if (isGoogleVideoSABR) {
                const pageInit = Object.assign({}, init || {});
                if (!pageInit.credentials) pageInit.credentials = 'include';
                return originalFetch(input, pageInit);
            }

            const handler = window.webkit?.messageHandlers?.souloSABRDownload;
            if (!handler) return originalFetch(input, init);

            const headers = {};
            if (input instanceof Request) {
                input.headers.forEach((value, key) => { headers[key] = value; });
            }
            new Headers(init?.headers || {}).forEach((value, key) => { headers[key] = value; });
            const body = init && Object.prototype.hasOwnProperty.call(init, 'body')
                ? init.body
                : null;
            const payload = await Promise.resolve(handler.postMessage({
                type: 'networkRequest',
                url: parsedURL.href,
                method: String(init?.method || (input instanceof Request ? input.method : 'GET')),
                headers,
                bodyBase64: await bodyBase64(body),
                pageURL: location.href
            }));
            return new Response(decodeBase64(payload.bodyBase64), {
                status: Number(payload.status || 500),
                statusText: String(payload.statusText || ''),
                headers: payload.headers || {}
            });
        };
        window.__souloNativeFetchBridgeInstalled = true;
    })();
    """#
    var backgroundEventsCompletionHandler: (() -> Void)?
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.hlsSessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
    }()

    private override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        directSession = URLSession(configuration: configuration)
        super.init()
        try? FileManager.default.removeItem(at: Self.streamingTemporaryDirectory)
        try? FileManager.default.createDirectory(
            at: Self.streamingTemporaryDirectory,
            withIntermediateDirectories: true
        )
        cancelObserver = NotificationCenter.default.addObserver(
            forName: .cancelActiveDownloads,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelAll() }
        }
        _ = hlsSession
        hlsSession.getAllTasks { tasks in
            let activeIDs = Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
            Task { @MainActor in
                let manager = DownloadManagerService.shared
                for task in tasks {
                    guard let itemID = task.taskDescription.flatMap(UUID.init(uuidString:)),
                          let item = manager.downloads.first(where: { $0.id == itemID }) else { continue }
                    let stagingDirectory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SouloHLSDownloads", isDirectory: true)
                        .appendingPathComponent(itemID.uuidString, isDirectory: true)
                    try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                    self.hlsTransfers[task.taskIdentifier] = HLSTransfer(
                        itemID: itemID,
                        sourceURL: URL(string: item.sourceURLString),
                        destinationURL: item.localURL,
                        stagingDirectoryURL: stagingDirectory,
                        continuation: nil
                    )
                    if let assetTask = task as? AVAssetDownloadTask {
                        manager.registerPlaybackSource(id: itemID, asset: assetTask.urlAsset, persistPosition: false)
                    }
                    if item.status == .inProgress && task.state == .suspended {
                        task.resume()
                    }
                }
                manager.reconcileHLSDownloads(activeIDs: activeIDs)
            }
        }
    }

    func downloadYouTubeVideo(
        resource: WebMediaResource,
        preferredFilename: String?,
        pageURL: URL?,
        webView: WKWebView
    ) async throws -> URL {
        guard resource.kind == .video,
              resource.delivery == .youtubeSABR,
              Self.isYouTubePage(pageURL ?? webView.url) else {
            throw StreamingMediaDownloadError.unavailable
        }

        let filename = Self.videoFilename(
            preferredFilename ?? resource.suggestedFilename,
            fallback: resource.title
        )
        let manager = DownloadManagerService.shared
        let sourceURL = WebResourceMediaService.downloadIdentityURL(
            for: resource,
            pageURL: pageURL ?? webView.url
        )
        guard manager.activeDownload(for: sourceURL) == nil else {
            throw StreamingMediaDownloadError.alreadyInProgress
        }
        manager.removeFailedDownloads(for: sourceURL)
        let (item, destinationURL) = manager.beginDownload(
            suggestedFilename: filename,
            sourceURL: sourceURL,
            transport: .streaming
        )

        let identifier = UUID().uuidString
        let directoryURL = Self.streamingTemporaryDirectory
            .appendingPathComponent(identifier, isDirectory: true)
        let videoURL = directoryURL.appendingPathComponent("video.mp4")
        let audioURL = directoryURL.appendingPathComponent("audio.m4a")

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let writer = try StreamingTrackWriter(videoURL: videoURL, audioURL: audioURL)
            let transfer = Transfer(
                identifier: identifier,
                itemID: item.id,
                destinationURL: destinationURL,
                directoryURL: directoryURL,
                videoURL: videoURL,
                audioURL: audioURL,
                writer: writer,
                webView: webView
            )
            transfers[identifier] = transfer
            identifiersByItemID[item.id] = identifier

            let playerResponseJSON = try await prepareYouTubePlayerContext(in: webView)
            try await installEngineIfNeeded(in: webView)
            let engineResult = try await webView.callAsyncJavaScript(
                "return await window.__souloSABRDownload(configuration);",
                arguments: [
                    "configuration": [
                        "downloadID": identifier,
                        "videoQuality": "720p",
                        "playerResponseJSON": playerResponseJSON
                    ]
                ],
                in: nil,
                contentWorld: .page
            )
            let pageDurationSeconds = ((engineResult as? [String: Any])?["durationSeconds"] as? NSNumber)?
                .doubleValue

            if transfer.isCanceled { throw CancellationError() }
            if !transfer.failureMessage.isEmpty {
                throw StreamingMediaDownloadError.exportFailed(transfer.failureMessage)
            }
            let byteCounts = try await transfer.writer.close()
            guard byteCounts.video > 0, byteCounts.audio > 0 else {
                throw StreamingMediaDownloadError.missingTrack
            }

            manager.updateProgress(
                id: item.id,
                completed: byteCounts.video + byteCounts.audio,
                total: max(byteCounts.video + byteCounts.audio, transfer.expectedVideoBytes + transfer.expectedAudioBytes)
            )
            try await mux(
                videoURL: videoURL,
                audioURL: audioURL,
                destinationURL: destinationURL,
                maximumDurationSeconds: pageDurationSeconds
            )
            manager.markFinished(id: item.id)
            finish(transfer)
            return destinationURL
        } catch {
            let surfacedError = Self.surfacedStreamingError(error)
            if let transfer = transfers[identifier] {
                _ = try? await transfer.writer.close()
                if !transfer.isCanceled,
                   manager.downloads.first(where: { $0.id == item.id })?.status == .inProgress {
                    manager.markFailed(id: item.id, error: surfacedError)
                }
                finish(transfer)
            }
            throw surfacedError
        }
    }

    func downloadSeparatedTracks(
        resource: WebMediaResource,
        audioURL: URL,
        preferredFilename: String?,
        pageURL: URL?,
        webView: WKWebView
    ) async throws -> URL {
        let filename = Self.videoFilename(
            preferredFilename ?? resource.suggestedFilename,
            fallback: resource.title
        )
        let service = SeparatedMediaDownloadService.shared
        await service.prepare()
        let manager = DownloadManagerService.shared
        let (item, _) = manager.beginDownload(
            suggestedFilename: filename, sourceURL: resource.url, transport: .separated
        )
        do {
            let videoRequest = await WebResourceDownloadService.shared.resourceRequest(
                resource.url, pageURL: pageURL, webView: webView
            )
            let audioRequest = await WebResourceDownloadService.shared.resourceRequest(
                audioURL, pageURL: pageURL, webView: webView
            )
            return try await service.start(item: item, videoRequest: videoRequest, audioRequest: audioRequest)
        } catch {
            if manager.downloads.first(where: { $0.id == item.id })?.status == .inProgress {
                manager.markFailed(id: item.id, error: error)
            }
            throw error
        }
    }

    func downloadHLS(
        resource: WebMediaResource,
        preferredFilename: String?,
        pageURL: URL?,
        webView: WKWebView
    ) async throws -> URL {
        guard resource.kind == .video, resource.delivery == .hls else {
            throw StreamingMediaDownloadError.unavailable
        }
        let manager = DownloadManagerService.shared
        guard manager.activeDownload(for: resource.url) == nil else {
            throw StreamingMediaDownloadError.alreadyInProgress
        }
        let filename = Self.videoFilename(
            preferredFilename ?? resource.suggestedFilename,
            fallback: resource.title
        )
        let (item, destinationURL) = manager.beginDownload(
            suggestedFilename: filename,
            sourceURL: resource.url,
            transport: .hls
        )
        let asset = await WebResourceMediaService.asset(
            for: resource,
            webView: webView,
            preferDownloadedCopy: false
        )
        guard let initialStatus = manager.downloads.first(where: { $0.id == item.id })?.status,
              initialStatus == .inProgress || initialStatus == .paused else {
            throw CancellationError()
        }
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloHLSDownloads", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            manager.markFailed(id: item.id, error: error)
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            guard let task = hlsSession.makeAssetDownloadTask(
                asset: asset,
                assetTitle: resource.title.isEmpty ? filename : resource.title,
                assetArtworkData: nil,
                options: nil
            ) else {
                manager.markFailed(id: item.id, error: StreamingMediaDownloadError.unavailable)
                try? FileManager.default.removeItem(at: stagingDirectory)
                continuation.resume(throwing: StreamingMediaDownloadError.unavailable)
                return
            }
            task.taskDescription = item.id.uuidString
            // AVFoundation reads downloaded HLS segments during playback only
            // when the player reuses this exact asset (including its cookies).
            manager.registerPlaybackSource(id: item.id, asset: task.urlAsset, pageURL: pageURL, webView: webView)
            hlsTransfers[task.taskIdentifier] = HLSTransfer(
                itemID: item.id,
                sourceURL: resource.url,
                destinationURL: destinationURL,
                stagingDirectoryURL: stagingDirectory,
                continuation: continuation
            )
            if initialStatus == .inProgress { task.resume() }
        }
    }

    func cancel(itemID: UUID) {
        if let identifier = identifiersByItemID[itemID],
           let transfer = transfers[identifier] {
            cancel(transfer)
            return
        }
        cancelHLSTransfer(itemID: itemID)
    }

    func pause(itemID: UUID) {
        if let identifier = identifiersByItemID[itemID],
           let transfer = transfers[identifier],
           !transfer.isCanceled,
           !transfer.isPaused {
            transfer.isPaused = true
            DownloadManagerService.shared.markPaused(id: itemID)
            return
        }
        guard DownloadManagerService.shared.downloads.first(where: { $0.id == itemID })?.status == .inProgress else {
            return
        }
        DownloadManagerService.shared.markPaused(id: itemID)
        hlsSession.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskDescription == itemID.uuidString }) else { return }
            Task { @MainActor in
                guard DownloadManagerService.shared.downloads.first(where: { $0.id == itemID })?.status == .paused else {
                    return
                }
                task.suspend()
            }
        }
    }

    func resume(itemID: UUID) {
        if let identifier = identifiersByItemID[itemID],
           let transfer = transfers[identifier],
           !transfer.isCanceled,
           transfer.isPaused {
            transfer.isPaused = false
            DownloadManagerService.shared.markResumed(id: itemID)
            let pendingReplies = transfer.pendingChunkReplies
            transfer.pendingChunkReplies.removeAll()
            pendingReplies.forEach { $0(["resumed": true], nil) }
            return
        }
        guard DownloadManagerService.shared.downloads.first(where: { $0.id == itemID })?.status == .paused else {
            return
        }
        DownloadManagerService.shared.markResumed(id: itemID)
        guard DownloadManagerService.shared.downloads.first(where: { $0.id == itemID })?.status == .inProgress else {
            return
        }
        hlsSession.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskDescription == itemID.uuidString }) else { return }
            Task { @MainActor in
                guard DownloadManagerService.shared.downloads.first(where: { $0.id == itemID })?.status == .inProgress else {
                    return
                }
                task.resume()
            }
        }
    }

    func cancelAll() {
        Array(transfers.values).forEach(cancel)
        Array(hlsTransfers.values.map(\.itemID)).forEach(cancelHLSTransfer)
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        guard let transfer = hlsTransfers[assetDownloadTask.taskIdentifier] else { return }
        let loaded = loadedTimeRanges.reduce(0.0) {
            $0 + $1.timeRangeValue.duration.seconds
        }
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard loaded.isFinite, expected.isFinite, expected > 0 else { return }
        let scale: Int64 = 1_000_000
        DownloadManagerService.shared.updateProgress(
            id: transfer.itemID,
            completed: Int64(min(max(loaded / expected, 0), 1) * Double(scale)),
            total: scale
        )
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        hlsTransfers[assetDownloadTask.taskIdentifier]?.downloadedAssetURL = location
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let transfer = hlsTransfers[assetDownloadTask.taskIdentifier] else { return }
        // AVAssetDownloadURLSession owns this package. Moving it breaks offline playback.
        transfer.downloadedAssetURL = location
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let transfer = hlsTransfers.removeValue(forKey: task.taskIdentifier) else { return }
        let playbackAsset = (task as? AVAssetDownloadTask)?.urlAsset
        if transfer.isCanceled {
            transfer.continuation?.resume(throwing: CancellationError())
            if let package = transfer.downloadedAssetURL { removeHLSCache(at: package, playbackAsset: playbackAsset) }
            cleanupHLSTransfer(transfer)
            return
        }
        if let error {
            DownloadManagerService.shared.markFailed(id: transfer.itemID, error: error)
            transfer.continuation?.resume(throwing: error)
            if let package = transfer.downloadedAssetURL { removeHLSCache(at: package, playbackAsset: playbackAsset) }
            cleanupHLSTransfer(transfer)
            return
        }
        guard let downloadedAssetURL = transfer.downloadedAssetURL else {
            let error = StreamingMediaDownloadError.unavailable
            DownloadManagerService.shared.markFailed(id: transfer.itemID, error: error)
            transfer.continuation?.resume(throwing: error)
            cleanupHLSTransfer(transfer)
            return
        }
        Task { @MainActor in
            do {
                let managedAssetURL = try OfflineHLSReference.canonicalPackageURL(for: downloadedAssetURL)
                let completedURL: URL
                do {
                    try await exportHLSAsset(
                        at: managedAssetURL,
                        destinationURL: transfer.destinationURL
                    )
                    // The player may still read the task's local segment cache.
                    // Release it when that player source is replaced or stopped.
                    if playbackAsset.map({ MediaSession.shared.deferDownloadPackageRemoval(for: $0, at: managedAssetURL) }) != true {
                        try? FileManager.default.removeItem(at: managedAssetURL)
                    }
                    completedURL = transfer.destinationURL
                } catch {
                    let asset = AVURLAsset(url: managedAssetURL)
                    guard asset.assetCache?.isPlayableOffline == true,
                          try await asset.load(.isPlayable),
                          await offlineHLSHasVideo(asset) else {
                        throw error
                    }
                    let referenceURL = uniqueHLSReferenceURL(for: transfer.destinationURL)
                    try? FileManager.default.removeItem(at: transfer.destinationURL)
                    try OfflineHLSReference.write(
                        packageURL: managedAssetURL, sourceURL: transfer.sourceURL, to: referenceURL
                    )
                    DownloadManagerService.shared.updateFileReference(
                        from: transfer.destinationURL, to: referenceURL
                    )
                    completedURL = referenceURL
                }
                DownloadManagerService.shared.markFinished(id: transfer.itemID)
                transfer.continuation?.resume(returning: completedURL)
            } catch {
                DownloadManagerService.shared.markFailed(id: transfer.itemID, error: error)
                transfer.continuation?.resume(throwing: error)
                removeHLSCache(at: downloadedAssetURL, playbackAsset: playbackAsset)
            }
            cleanupHLSTransfer(transfer)
        }
    }

    private func removeHLSCache(at callbackURL: URL, playbackAsset: AVURLAsset?) {
        if let playbackAsset, let package = try? OfflineHLSReference.canonicalPackageURL(for: callbackURL),
           MediaSession.shared.deferDownloadPackageRemoval(for: playbackAsset, at: package) { return }
        OfflineHLSReference.removeDownloadedPackage(at: callbackURL)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsCompletionHandler?()
        backgroundEventsCompletionHandler = nil
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            await self.handle(message: message, replyHandler: replyHandler)
        }
    }

    private func handle(
        message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) async {
        guard message.name == Self.messageHandlerName,
              let body = message.body as? [String: Any] else {
            replyHandler(nil, "Invalid streaming download message")
            return
        }
        if body["type"] as? String == "networkRequest" {
            await handleNativeFetch(body, replyHandler: replyHandler)
            return
        }
        guard let identifier = body["downloadID"] as? String,
              let transfer = transfers[identifier],
              !transfer.isCanceled else {
            replyHandler(nil, "Unknown or canceled streaming download")
            return
        }

        switch body["type"] as? String {
        case "started":
            transfer.expectedVideoBytes = Self.int64(body["videoExpectedBytes"])
            transfer.expectedAudioBytes = Self.int64(body["audioExpectedBytes"])
            replyHandler(["accepted": true], nil)

        case "chunk":
            guard let encoded = body["base64"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let rawTrack = body["track"] as? String,
                  let track = StreamingTrackWriter.Track(rawValue: rawTrack),
                  let index = Self.integer(body["index"]) else {
                replyHandler(nil, StreamingMediaDownloadError.invalidChunk.localizedDescription)
                return
            }
            do {
                let byteCounts = try await transfer.writer.append(data, to: track, index: index)
                let completed = byteCounts.video + byteCounts.audio
                let expected = transfer.expectedVideoBytes + transfer.expectedAudioBytes
                DownloadManagerService.shared.updateProgress(
                    id: transfer.itemID,
                    completed: completed,
                    total: expected
                )
                if transfer.isPaused {
                    transfer.pendingChunkReplies.append(replyHandler)
                } else {
                    replyHandler(["received": index], nil)
                }
            } catch {
                transfer.failureMessage = error.localizedDescription
                replyHandler(nil, error.localizedDescription)
            }

        case "trackFinished":
            replyHandler(["finished": true], nil)

        case "finished":
            replyHandler(["finished": true], nil)

        case "failed":
            transfer.failureMessage = body["message"] as? String ?? ""
            replyHandler(["failed": true], nil)

        default:
            replyHandler(nil, "Unknown streaming download message")
        }
    }

    private func installEngineIfNeeded(in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(Self.nativeFetchBridgeScript)
        let nativeFetchReady = try await webView.evaluateJavaScript(
            "typeof window.__souloNativeFetch === 'function'"
        ) as? Bool ?? false
        guard nativeFetchReady else { throw StreamingMediaDownloadError.unavailable }
        let installed = try await webView.evaluateJavaScript(
            "typeof window.__souloSABRDownload === 'function' && window.__souloSABREngineVersion === \(Self.sabrEngineVersion)"
        ) as? Bool ?? false
        if installed { return }
        guard let url = Bundle.main.url(forResource: "SouloSABREngine", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw StreamingMediaDownloadError.unavailable
        }
        _ = try await webView.evaluateJavaScript(
            Self.preparedSABREngineSource(source)
                + ";window.__souloSABREngineVersion=\(Self.sabrEngineVersion);"
        )
        let ready = try await webView.evaluateJavaScript(
            "typeof window.__souloSABRDownload === 'function'"
        ) as? Bool ?? false
        guard ready else { throw StreamingMediaDownloadError.unavailable }
    }

    private func prepareYouTubePlayerContext(in webView: WKWebView) async throws -> String {
        for attempt in 0..<20 {
            let playerResponseJSON = try await webView.evaluateJavaScript(#"""
        (() => {
            function currentVideoID() {
                try {
                    const pageURL = new URL(location.href);
                    let host = String(pageURL.hostname || '').toLowerCase();
                    if (host.startsWith('www.')) host = host.slice(4);
                    if (host === 'youtu.be') {
                        return pageURL.pathname.split('/').filter(Boolean)[0] || '';
                    }
                    if (host !== 'youtube.com' && host !== 'm.youtube.com') return '';
                    if (pageURL.pathname === '/watch') return pageURL.searchParams.get('v') || '';
                    const parts = pageURL.pathname.split('/').filter(Boolean);
                    return parts.length >= 2 && ['shorts', 'embed', 'live'].includes(parts[0])
                        ? parts[1]
                        : '';
                } catch (_) {
                    return '';
                }
            }

            const expectedVideoID = currentVideoID();
            function cache(value) {
                try {
                    if (typeof value === 'string') value = JSON.parse(value);
                    const snapshot = JSON.parse(JSON.stringify(value));
                    const responseVideoID = String(snapshot?.videoDetails?.videoId || '');
                    if (expectedVideoID && responseVideoID !== expectedVideoID) return false;
                    const streamingData = snapshot && snapshot.streamingData;
                    if (!streamingData || typeof streamingData !== 'object') return false;
                    if (!streamingData.serverAbrStreamingUrl
                        || !Array.isArray(streamingData.adaptiveFormats)
                        || !streamingData.adaptiveFormats.length) return false;
                    window.__souloYouTubePlayerResponses = window.__souloYouTubePlayerResponses || Object.create(null);
                    if (responseVideoID) window.__souloYouTubePlayerResponses[responseVideoID] = snapshot;
                    window.__souloYouTubePlayerResponse = snapshot;
                    window.__souloPreparedYouTubePlayerResponse = snapshot;
                    return true;
                } catch (_) {
                    return false;
                }
            }

            const candidates = [];
            try {
                if (typeof window.__souloResolveCurrentYouTubePlayerResponse === 'function') {
                    candidates.push(window.__souloResolveCurrentYouTubePlayerResponse());
                }
            } catch (_) {}
            candidates.push(
                expectedVideoID && window.__souloYouTubePlayerResponses?.[expectedVideoID],
                window.__souloYouTubePlayerResponse,
                window.ytInitialPlayerResponse,
                window.ytplayer?.bootstrapPlayerResponse,
                window.ytplayer?.config?.args?.raw_player_response,
                window.ytplayer?.config?.args?.player_response,
                window.ytcfg?.get?.('PLAYER_RESPONSE')
            );
            try {
                const initialData = typeof window.getInitialData === 'function'
                    ? window.getInitialData()
                    : null;
                candidates.push(initialData?.playerResponse);
            } catch (_) {}
            for (const candidate of candidates) {
                if (cache(candidate)) {
                    return JSON.stringify(window.__souloPreparedYouTubePlayerResponse);
                }
            }
            return '';
        })();
        """#) as? String ?? ""
            if !playerResponseJSON.isEmpty { return playerResponseJSON }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw StreamingMediaDownloadError.unavailable
    }

    nonisolated static func preparedSABREngineSource(_ source: String) -> String {
        let playerResponseFinder = "function xn(){let e=[window.ytInitialPlayerResponse,window.ytplayer?.bootstrapPlayerResponse,window.ytplayer?.config?.args?.raw_player_response];for(let n of e)if(n){if(typeof n==\"string\")try{return JSON.parse(n)}catch{continue}return n}throw new Error(\"YouTube player response unavailable\")}" 
        let pageAwarePlayerResponseFinder = "function xn(){let e=\"\";try{let n=new URL(location.href),t=String(n.hostname||\"\").toLowerCase();t.startsWith(\"www.\")&&(t=t.slice(4)),t===\"youtu.be\"?e=n.pathname.split(\"/\").filter(Boolean)[0]||\"\":(t===\"youtube.com\"||t===\"m.youtube.com\")&&(n.pathname===\"/watch\"?e=n.searchParams.get(\"v\")||\"\":((n=n.pathname.split(\"/\").filter(Boolean)).length>=2&&[\"shorts\",\"embed\",\"live\"].includes(n[0])&&(e=n[1])))}catch{}let n=[window.__souloPreparedYouTubePlayerResponse,e&&window.__souloYouTubePlayerResponses?.[e],window.__souloYouTubePlayerResponse,window.ytInitialPlayerResponse,window.ytplayer?.bootstrapPlayerResponse,window.ytplayer?.config?.args?.raw_player_response,window.ytplayer?.config?.args?.player_response,window.ytcfg?.get?.(\"PLAYER_RESPONSE\")];try{n.push(window.getInitialData?.()?.playerResponse)}catch{}for(let t of n)if(t){if(typeof t==\"string\")try{t=JSON.parse(t)}catch{continue}let n=t?.videoDetails?.videoId||\"\",r=t?.streamingData;if(e&&n!==e)continue;if(!r?.serverAbrStreamingUrl||!Array.isArray(r.adaptiveFormats)||!r.adaptiveFormats.length)continue;return t}throw new Error(\"YouTube player response unavailable\")}" 
        let endpointResolver = "function gn(e){return performance.getEntriesByType(\"resource\").map(r=>r.name).reverse().find(r=>/[?&]sabr=1(?:&|$)/.test(r))||e.streamingData?.serverAbrStreamingUrl||\"\"}" 
        let pageAwareResolver = "function gn(e){let n=window.__souloLatestPageSABR;return n&&n.videoID===e.videoDetails?.videoId?n.url:e.streamingData?.serverAbrStreamingUrl||\"\"}" 
        return source
            .replacingOccurrences(of: playerResponseFinder, with: pageAwarePlayerResponseFinder)
            .replacingOccurrences(of: endpointResolver, with: pageAwareResolver)
            .replacingOccurrences(
                of: "let t=xn(),r=",
                with: "let t=e?.playerResponseJSON?JSON.parse(e.playerResponseJSON):xn(),r="
            )
            .replacingOccurrences(
                of: "fetch:window.fetch.bind(window)",
                with: "fetch:window.__souloNativeFetch.bind(window)"
            )
    }

    nonisolated static func surfacedStreamingError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let nsError = error as NSError
        let keys = [
            "WKJavaScriptExceptionMessage",
            "WKJavaScriptExceptionStackTrace",
            NSLocalizedFailureReasonErrorKey,
            NSDebugDescriptionErrorKey
        ]
        for key in keys {
            if let message = nsError.userInfo[key] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return StreamingMediaDownloadError.exportFailed(message)
            }
        }
        return error
    }

    nonisolated static func isAllowedNativeFetchURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        if host == "jnn-pa.googleapis.com" { return true }
        guard host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name.lowercased() == "sabr" && $0.value == "1" }) == true
    }

    private func handleNativeFetch(
        _ body: [String: Any],
        replyHandler: @escaping (Any?, String?) -> Void
    ) async {
        guard let rawURL = body["url"] as? String,
              let url = URL(string: rawURL),
              Self.isAllowedNativeFetchURL(url),
              let encodedBody = body["bodyBase64"] as? String,
              encodedBody.utf8.count <= 2_000_000,
              let requestBody = Data(base64Encoded: encodedBody) else {
            replyHandler(nil, StreamingMediaDownloadError.unavailable.localizedDescription)
            return
        }

        var request = URLRequest(url: url)
        let method = (body["method"] as? String)?.uppercased() ?? "GET"
        guard ["GET", "POST"].contains(method) else {
            replyHandler(nil, StreamingMediaDownloadError.unavailable.localizedDescription)
            return
        }
        request.httpMethod = method
        request.httpBody = requestBody.isEmpty ? nil : requestBody
        request.timeoutInterval = 60
        if let headers = body["headers"] as? [String: Any] {
            let permittedHeaders = Set([
                "accept", "accept-encoding", "content-type", "x-goog-api-key", "x-user-agent"
            ])
            for (key, value) in headers where permittedHeaders.contains(key.lowercased()) {
                request.setValue(String(describing: value), forHTTPHeaderField: key)
            }
        }
        if url.host?.lowercased().hasSuffix("googlevideo.com") == true {
            request.setValue(AppConstants.mobileWebViewUserAgent, forHTTPHeaderField: "User-Agent")
            if let rawPageURL = body["pageURL"] as? String,
               let pageURL = URL(string: rawPageURL),
               Self.isYouTubePage(pageURL) {
                request.setValue("https://\(pageURL.host ?? "m.youtube.com")", forHTTPHeaderField: "Origin")
                request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
            }
        }

        do {
            let (data, response) = try await directSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  data.count <= 16_000_000 else {
                throw StreamingMediaDownloadError.unavailable
            }
            let headers = Dictionary(uniqueKeysWithValues: httpResponse.allHeaderFields.map {
                (String(describing: $0.key), String(describing: $0.value))
            })
            replyHandler([
                "status": httpResponse.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                "headers": headers,
                "bodyBase64": data.base64EncodedString()
            ], nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    private func cancel(_ transfer: Transfer) {
        guard !transfer.isCanceled else { return }
        transfer.isCanceled = true
        let pendingReplies = transfer.pendingChunkReplies
        transfer.pendingChunkReplies.removeAll()
        pendingReplies.forEach { $0(nil, "Streaming download canceled") }
        if let webView = transfer.webView {
            webView.evaluateJavaScript(
                "window.__souloCancelSABRDownload && window.__souloCancelSABRDownload(\(Self.javascriptString(transfer.identifier)));"
            )
        }
        Task {
            _ = try? await transfer.writer.close()
            DownloadManagerService.shared.markCanceled(id: transfer.itemID)
            finish(transfer)
        }
    }

    private func finish(_ transfer: Transfer) {
        let pendingReplies = transfer.pendingChunkReplies
        transfer.pendingChunkReplies.removeAll()
        pendingReplies.forEach { $0(nil, "Streaming download finished") }
        transfers.removeValue(forKey: transfer.identifier)
        identifiersByItemID.removeValue(forKey: transfer.itemID)
        try? FileManager.default.removeItem(at: transfer.directoryURL)
    }

    private func cancelHLSTransfer(itemID: UUID) {
        if let transfer = hlsTransfers.values.first(where: { $0.itemID == itemID }) {
            guard !transfer.isCanceled else { return }
            transfer.isCanceled = true
        }
        DownloadManagerService.shared.markCanceled(id: itemID)
        hlsSession.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == itemID.uuidString })?.cancel()
        }
    }

    private func cleanupHLSTransfer(_ transfer: HLSTransfer) {
        try? FileManager.default.removeItem(at: transfer.stagingDirectoryURL)
    }

    private func uniqueHLSReferenceURL(for destinationURL: URL) -> URL {
        let directory = destinationURL.deletingLastPathComponent()
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(stem)
            .appendingPathExtension(OfflineHLSReference.fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix))")
                .appendingPathExtension(OfflineHLSReference.fileExtension)
            suffix += 1
        }
        return candidate
    }

    private func offlineHLSHasVideo(_ asset: AVURLAsset) async -> Bool {
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }
        for _ in 0..<50 {
            if item.status == .failed { return false }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func exportHLSAsset(at sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard try await asset.load(.isExportable) else {
            throw StreamingMediaDownloadError.exportFailed("")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw StreamingMediaDownloadError.exportFailed("")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        let exporterBox = StreamingUncheckedSendable(value: exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                let exporter = exporterBox.value
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(
                        throwing: exporter.error ?? StreamingMediaDownloadError.exportFailed("")
                    )
                }
            }
        }
        let output = AVURLAsset(url: destinationURL)
        let size = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard try await output.load(.isPlayable),
              !(try await output.loadTracks(withMediaType: .video)).isEmpty,
              size > 0 else {
            throw StreamingMediaDownloadError.exportFailed("")
        }
    }

    func mux(
        videoURL: URL,
        audioURL: URL,
        destinationURL: URL,
        maximumDurationSeconds: Double? = nil,
        onExporter: ((AVAssetExportSession) -> Void)? = nil
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw StreamingMediaDownloadError.missingTrack
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let duration = Self.constrainedDuration(
            videoDuration: videoDuration,
            audioDuration: audioDuration,
            maximumDurationSeconds: maximumDurationSeconds
        )
        guard duration.isNumeric, duration > .zero else {
            throw StreamingMediaDownloadError.missingTrack
        }

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw StreamingMediaDownloadError.exportFailed("")
        }
        try compositionVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )
        try compositionAudio.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack,
            at: .zero
        )
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destinationURL)
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw StreamingMediaDownloadError.exportFailed("")
        }
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        onExporter?(exporter)
        let exporterBox = StreamingUncheckedSendable(value: exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                let exporter = exporterBox.value
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: exporter.error ?? StreamingMediaDownloadError.exportFailed(""))
                }
            }
        }
    }

    private static func isYouTubePage(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }

    static func constrainedDuration(
        videoDuration: CMTime,
        audioDuration: CMTime,
        maximumDurationSeconds: Double?
    ) -> CMTime {
        var duration = CMTimeMinimum(videoDuration, audioDuration)
        if let maximumDurationSeconds,
           maximumDurationSeconds.isFinite,
           maximumDurationSeconds > 0 {
            duration = CMTimeMinimum(
                duration,
                CMTime(seconds: maximumDurationSeconds, preferredTimescale: 600)
            )
        }
        return duration
    }

    private static func videoFilename(_ value: String, fallback: String) -> String {
        let sanitized = DownloadFilenameSanitizer.sanitize(
            value,
            fallbackBaseName: fallback.isEmpty ? "Video" : fallback,
            preferredExtension: "mp4"
        )
        let name = sanitized as NSString
        return name.pathExtension.lowercased() == "mp4"
            ? sanitized
            : "\(name.deletingPathExtension).mp4"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    private static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

/// A small file in Downloads points to an HLS asset at AVFoundation's managed location.
/// Apple requires downloaded HLS packages to remain at that location.
enum OfflineHLSReference {
    static let fileExtension = "soulohls"

    private struct Record: Codable {
        let relativePackagePath: String
        let sourceURLString: String?
    }

    static func write(packageURL: URL, sourceURL: URL? = nil, to referenceURL: URL) throws {
        let package = try canonicalPackageURL(for: packageURL)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let relativePath = String(package.path.dropFirst(home.path.count + 1))
        let data = try JSONEncoder().encode(Record(
            relativePackagePath: relativePath, sourceURLString: sourceURL?.absoluteString
        ))
        try data.write(to: referenceURL, options: .atomic)
    }

    static func sourceURL(for referenceURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: referenceURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let value = record.sourceURLString else { return nil }
        return URL(string: value)
    }

    static func canonicalPackageURL(for callbackURL: URL) throws -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let package = callbackURL.standardizedFileURL
        let containerMarker = "/Application/\(home.lastPathComponent)/"
        guard package.isFileURL,
              let markerRange = package.path.range(of: containerMarker),
              package.pathExtension.lowercased() == "movpkg" else {
            throw StreamingMediaDownloadError.unavailable
        }
        // The system callback may prepend /.nofollow/private to the same app
        // container. Persist only the part after the container identifier.
        let relativePath = String(package.path[markerRange.upperBound...])
        let localPackage = home.appendingPathComponent(relativePath).standardizedFileURL
        guard relativePath.hasPrefix("Library/"),
              !relativePath.split(separator: "/").contains(".."),
              FileManager.default.fileExists(atPath: localPackage.path) else {
            throw StreamingMediaDownloadError.unavailable
        }
        return localPackage
    }

    static func packageURL(for referenceURL: URL) throws -> URL {
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: referenceURL))
        guard record.relativePackagePath.hasPrefix("Library/"),
              !record.relativePackagePath.hasPrefix("/"),
              !record.relativePackagePath.split(separator: "/").contains("..") else {
            throw StreamingMediaDownloadError.unavailable
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let package = home.appendingPathComponent(record.relativePackagePath).standardizedFileURL
        guard package.path.hasPrefix(home.path + "/"),
              package.pathExtension.lowercased() == "movpkg",
              FileManager.default.fileExists(atPath: package.path) else {
            throw StreamingMediaDownloadError.unavailable
        }
        return package
    }

    static func playableAsset(for referenceURL: URL) throws -> AVURLAsset {
        try playablePackage(at: packageURL(for: referenceURL))
    }

    static func playablePackage(at packageURL: URL) throws -> AVURLAsset {
        let asset = AVURLAsset(url: packageURL)
        guard asset.assetCache?.isPlayableOffline == true else {
            throw StreamingMediaDownloadError.unavailable
        }
        return asset
    }

    static func removePackage(for referenceURL: URL) throws {
        let package = try packageURL(for: referenceURL)
        try FileManager.default.removeItem(at: package)
    }

    static func removeDownloadedPackage(at callbackURL: URL) {
        let package = (try? canonicalPackageURL(for: callbackURL)) ?? callbackURL
        try? FileManager.default.removeItem(at: package)
    }
}

/// Exports a verified, single-rendition transport-stream package as standard
/// HLS files. The system-owned package remains in place for in-app playback.
enum PortableHLSBundle {
    private struct Fragment {
        let start: Int
        let part: Int
        let duration: Double
        let url: URL
        let size: Int
    }

    static func export(referenceURL: URL, sourceURL: URL? = nil, into directory: URL,
                       session: URLSession = .shared, operation: FileOperationProgress? = nil) async throws -> URL {
        try await export(
            packageURL: OfflineHLSReference.packageURL(for: referenceURL),
            name: referenceURL.deletingPathExtension().lastPathComponent,
            into: directory,
            sourceURL: sourceURL ?? OfflineHLSReference.sourceURL(for: referenceURL),
            session: session, operation: operation
        )
    }

    static func export(packageURL: URL, name: String, into directory: URL,
                       sourceURL: URL? = nil, session: URLSession = .shared,
                       operation: FileOperationProgress? = nil) async throws -> URL {
        try operation?.check()
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: packageURL, includingPropertiesForKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]) else { throw StreamingMediaDownloadError.unsupportedManifest }
        let pattern = try NSRegularExpression(pattern: #"^\(([0-9]+)\)_\(([0-9]+)\)_\(([0-9.]+)\)\.frag$"#)
        var fragments: [Fragment] = []
        var renditionDirectory: URL?
        while let candidate = enumerator.nextObject() {
            guard let entry = candidate as? URL, entry.pathExtension == "frag" else { continue }
            try operation?.check()
            let filename = entry.lastPathComponent
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            guard let match = pattern.firstMatch(in: filename, range: range),
                  let startRange = Range(match.range(at: 1), in: filename),
                  let partRange = Range(match.range(at: 2), in: filename),
                  let durationRange = Range(match.range(at: 3), in: filename),
                  let start = Int(filename[startRange]), let part = Int(filename[partRange]),
                  let duration = Double(filename[durationRange]), duration.isFinite,
                  duration > 0, duration <= 600,
                  entry.deletingLastPathComponent().standardizedFileURL.path.hasPrefix(
                    packageURL.standardizedFileURL.path + "/"
                  ) else { throw StreamingMediaDownloadError.unsupportedManifest }
            let info = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size >= 16,
                  fragments.count < 10_000 else {
                throw StreamingMediaDownloadError.unsupportedManifest
            }
            let parent = entry.deletingLastPathComponent().standardizedFileURL
            guard renditionDirectory == nil || renditionDirectory == parent else {
                throw StreamingMediaDownloadError.unsupportedManifest
            }
            renditionDirectory = parent
            fragments.append(Fragment(start: start, part: part, duration: duration, url: entry, size: size))
        }
        guard !fragments.isEmpty else { throw StreamingMediaDownloadError.unsupportedManifest }
        operation?.progress.totalUnitCount = Int64(fragments.count + 1)
        operation?.progress.completedUnitCount = 0
        fragments.sort { ($0.start, $0.part) < ($1.start, $1.part) }
        for index in 1..<fragments.count {
            guard (fragments[index - 1].start, fragments[index - 1].part)
                    < (fragments[index].start, fragments[index].part) else {
                throw StreamingMediaDownloadError.unsupportedManifest
            }
        }

        guard let renditionDirectory else { throw StreamingMediaDownloadError.unsupportedManifest }
        let innerPlaylists = try manager.contentsOfDirectory(at: renditionDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "m3u8" }
        guard innerPlaylists.count == 1 else { throw StreamingMediaDownloadError.unsupportedManifest }
        let mediaPlaylist = try String(contentsOf: innerPlaylists[0], encoding: .utf8)
            .replacingOccurrences(of: "\0", with: "")
        let mediaLines = mediaPlaylist.components(separatedBy: .newlines)
        guard mediaLines.filter({ $0.hasPrefix("#EXTINF:") }).count == fragments.count,
              mediaLines.contains("#EXT-X-ENDLIST") else {
            throw StreamingMediaDownloadError.unsupportedManifest
        }
        let mediaSequence = mediaLines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
            .flatMap { Int($0.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) } ?? 0
        let keyLines = mediaLines.filter { $0.hasPrefix("#EXT-X-KEY:") }
        guard keyLines.count <= 1 else { throw StreamingMediaDownloadError.unsupportedManifest }
        let keyLine = keyLines.first
        let encrypted = keyLine != nil
        let keyURI = keyLine.flatMap { capture(#"URI="([^"]+)""#, in: $0) }
        let iv = keyLine.flatMap { capture(#"IV=(0x[0-9A-Fa-f]{32})"#, in: $0) }
        if let keyLine {
            guard keyLine.contains("METHOD=AES-128"), keyURI != nil,
                  !keyLine.contains("KEYFORMAT=") || keyLine.contains("KEYFORMAT=\"identity\"") else {
                throw StreamingMediaDownloadError.unsupportedManifest
            }
        }
        for fragment in fragments {
            try operation?.check()
            let handle = try FileHandle(forReadingFrom: fragment.url)
            let header = try handle.read(upToCount: 564) ?? Data()
            try handle.close()
            if encrypted {
                guard fragment.size.isMultiple(of: 16) else {
                    throw StreamingMediaDownloadError.unsupportedManifest
                }
            } else {
                guard fragment.size >= 564, fragment.size.isMultiple(of: 188),
                      header.count == 564, header[0] == 0x47,
                      header[188] == 0x47, header[376] == 0x47 else {
                    throw StreamingMediaDownloadError.unsupportedManifest
                }
            }
        }
        let keyData: Data?
        var exportedIV = iv
        if keyURI != nil {
            guard let sourceURL else { throw StreamingMediaDownloadError.unsupportedManifest }
            let (mediaURL, remoteManifest) = try await self.mediaPlaylist(
                from: sourceURL, renditionDirectory: renditionDirectory, session: session
            )
            let remoteKeyLines = remoteManifest.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("#EXT-X-KEY:") }
            let remoteSequence = remoteManifest.components(separatedBy: .newlines)
                .first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
                .flatMap { Int($0.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) } ?? 0
            guard remoteKeyLines.count == 1,
                  remoteKeyLines[0].contains("METHOD=AES-128"),
                  remoteSequence == mediaSequence,
                  let remoteKeyURI = capture(#"URI="([^"]+)""#, in: remoteKeyLines[0]),
                  let remoteKeyURL = URL(string: remoteKeyURI, relativeTo: mediaURL)?.absoluteURL,
                  ["http", "https"].contains(remoteKeyURL.scheme?.lowercased() ?? "") else {
                throw StreamingMediaDownloadError.unsupportedManifest
            }
            let remoteIV = capture(#"IV=(0x[0-9A-Fa-f]{32})"#, in: remoteKeyLines[0])
            if let iv, let remoteIV, iv.caseInsensitiveCompare(remoteIV) != .orderedSame {
                throw StreamingMediaDownloadError.unsupportedManifest
            }
            exportedIV = iv ?? remoteIV
            let data = try await fetch(remoteKeyURL, referrer: sourceURL, session: session)
            guard data.count == 16 else { throw StreamingMediaDownloadError.unsupportedManifest }
            keyData = data
        } else {
            keyData = nil
        }

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = DownloadFilenameSanitizer.sanitize(name + ".hls", preferredExtension: "hls")
        let stem = (safeName as NSString).deletingPathExtension
        var target = directory.appendingPathComponent(safeName, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(stem) (\(suffix)).hls", isDirectory: true)
            suffix += 1
        }
        let staging = directory.appendingPathComponent(".SouloHLS-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let targetDuration = Int(ceil(fragments.map(\.duration).max() ?? 1))
            var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(targetDuration)\n"
                + "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            if let keyData {
                try keyData.write(to: staging.appendingPathComponent("key.bin"), options: .atomic)
                playlist += "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\""
                if let exportedIV { playlist += ",IV=\(exportedIV)" }
                playlist += "\n"
            }
            for (index, fragment) in fragments.enumerated() {
                try operation?.check()
                let filename = String(format: "%06d.ts", index)
                try manager.copyItem(at: fragment.url, to: staging.appendingPathComponent(filename))
                operation?.progress.completedUnitCount = Int64(index + 1)
                playlist += "#EXTINF:\(String(format: "%.5f", fragment.duration)),\n\(filename)\n"
            }
            playlist += "#EXT-X-ENDLIST\n"
            try playlist.write(to: staging.appendingPathComponent("index.m3u8"),
                               atomically: true, encoding: .utf8)
            try operation?.check()
            try manager.moveItem(at: staging, to: target)
            operation?.progress.completedUnitCount = operation?.progress.totalUnitCount ?? 0
            return target
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func capture(_ expression: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: expression),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func mediaPlaylist(from sourceURL: URL, renditionDirectory: URL,
                                      session: URLSession) async throws -> (URL, String) {
        let data = try await fetch(sourceURL, referrer: sourceURL, session: session)
        guard data.count <= 1_000_000,
              let manifest = String(data: data, encoding: .utf8),
              manifest.hasPrefix("#EXTM3U") else {
            throw StreamingMediaDownloadError.unsupportedManifest
        }
        if manifest.contains("#EXTINF:") { return (sourceURL, manifest) }
        let lines = manifest.components(separatedBy: .newlines)
        let bandwidth = renditionDirectory.lastPathComponent.split(separator: "-")
            .dropFirst().first.flatMap { Int($0) }
        var variants: [(bandwidth: Int, url: URL)] = []
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            guard index + 1 < lines.count,
                  let value = capture(#"BANDWIDTH=([0-9]+)"#, in: lines[index]).flatMap(Int.init),
                  let url = URL(string: lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines),
                                relativeTo: sourceURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            variants.append((value, url))
        }
        let variantURL: URL
        if let bandwidth, let variant = variants.first(where: { $0.bandwidth == bandwidth }) {
            variantURL = variant.url
        } else {
            guard variants.count == 1 else { throw StreamingMediaDownloadError.unsupportedManifest }
            variantURL = variants[0].url
        }
        let variantData = try await fetch(variantURL, referrer: sourceURL, session: session)
        guard let variantManifest = String(data: variantData, encoding: .utf8),
              variantManifest.hasPrefix("#EXTM3U"), variantManifest.contains("#EXTINF:") else {
            throw StreamingMediaDownloadError.unsupportedManifest
        }
        return (variantURL, variantManifest)
    }

    private static func fetch(_ url: URL, referrer: URL, session: URLSession) async throws -> Data {
        let request = await WebResourceDownloadService.shared.resourceRequest(
            url, pageURL: referrer, webView: nil
        )
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              data.count <= 1_000_000 else {
            throw StreamingMediaDownloadError.unsupportedManifest
        }
        return data
    }
}
