import AVFoundation
import Foundation
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
        let destinationURL: URL
        let stagingDirectoryURL: URL
        let continuation: CheckedContinuation<URL, Error>?
        var stagedAssetURL: URL?
        var isCanceled = false

        init(
            itemID: UUID,
            destinationURL: URL,
            stagingDirectoryURL: URL,
            continuation: CheckedContinuation<URL, Error>?
        ) {
            self.itemID = itemID
            self.destinationURL = destinationURL
            self.stagingDirectoryURL = stagingDirectoryURL
            self.continuation = continuation
        }
    }

    private var transfers: [String: Transfer] = [:]
    private var identifiersByItemID: [UUID: String] = [:]
    private var pairedTasks: [UUID: [URLSessionDownloadTask]] = [:]
    private var pairedDirectories: [UUID: URL] = [:]
    private var pairedProgress: [UUID: [Int: (completed: Int64, total: Int64)]] = [:]
    private var pairedProgressObservations: [UUID: [NSKeyValueObservation]] = [:]
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
                        destinationURL: item.localURL,
                        stagingDirectoryURL: stagingDirectory,
                        continuation: nil
                    )
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
        let manager = DownloadManagerService.shared
        let (item, destinationURL) = manager.beginDownload(
            suggestedFilename: filename,
            sourceURL: resource.url,
            transport: .streaming
        )
        let directoryURL = Self.streamingTemporaryDirectory
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let videoURL = directoryURL.appendingPathComponent("video.mp4")
        let audioFileURL = directoryURL.appendingPathComponent("audio.m4a")
        pairedDirectories[item.id] = directoryURL

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let videoRequest = await WebResourceDownloadService.shared.resourceRequest(
                resource.url,
                pageURL: pageURL,
                webView: webView
            )
            let audioRequest = await WebResourceDownloadService.shared.resourceRequest(
                audioURL,
                pageURL: pageURL,
                webView: webView
            )
            async let videoResult = downloadDirectTrack(
                request: videoRequest,
                destinationURL: videoURL,
                itemID: item.id
            )
            async let audioResult = downloadDirectTrack(
                request: audioRequest,
                destinationURL: audioFileURL,
                itemID: item.id
            )
            _ = try await (videoResult, audioResult)
            guard manager.downloads.first(where: { $0.id == item.id })?.status == .inProgress else {
                throw CancellationError()
            }
            try await mux(videoURL: videoURL, audioURL: audioFileURL, destinationURL: destinationURL)
            manager.markFinished(id: item.id)
            finishPaired(itemID: item.id)
            return destinationURL
        } catch {
            let status = manager.downloads.first(where: { $0.id == item.id })?.status
            if status == .inProgress { manager.markFailed(id: item.id, error: error) }
            finishPaired(itemID: item.id)
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
        let filename = Self.videoFilename(
            preferredFilename ?? resource.suggestedFilename,
            fallback: resource.title
        )
        let (item, destinationURL) = manager.beginDownload(
            suggestedFilename: filename,
            sourceURL: resource.url,
            transport: .hls
        )
        let cookies = await WebResourceDownloadService.shared.allCookies(in: webView)
        var assetOptions: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: AppConstants.mobileWebViewUserAgent
        ]
        let matchingCookies = WebResourceDownloadService.matchingCookies(
            from: cookies,
            for: resource.url
        )
        if !matchingCookies.isEmpty {
            assetOptions[AVURLAssetHTTPCookiesKey] = matchingCookies
        }
        let asset = AVURLAsset(url: resource.url, options: assetOptions)
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloHLSDownloads", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            guard let task = hlsSession.makeAssetDownloadTask(
                asset: asset,
                assetTitle: resource.title.isEmpty ? filename : resource.title,
                assetArtworkData: nil,
                options: nil
            ) else {
                manager.markFailed(id: item.id, error: StreamingMediaDownloadError.unavailable)
                continuation.resume(throwing: StreamingMediaDownloadError.unavailable)
                return
            }
            task.taskDescription = item.id.uuidString
            hlsTransfers[task.taskIdentifier] = HLSTransfer(
                itemID: item.id,
                destinationURL: destinationURL,
                stagingDirectoryURL: stagingDirectory,
                continuation: continuation
            )
            task.resume()
        }
    }

    func cancel(itemID: UUID) {
        if let identifier = identifiersByItemID[itemID],
           let transfer = transfers[identifier] {
            cancel(transfer)
            return
        }
        if pairedTasks[itemID] != nil {
            pairedTasks[itemID]?.forEach { $0.cancel() }
            DownloadManagerService.shared.markCanceled(id: itemID)
            finishPaired(itemID: itemID)
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
        if let tasks = pairedTasks[itemID], !tasks.isEmpty {
            tasks.forEach { $0.suspend() }
            DownloadManagerService.shared.markPaused(id: itemID)
            return
        }
        hlsSession.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskDescription == itemID.uuidString }) else { return }
            task.suspend()
            Task { @MainActor in
                DownloadManagerService.shared.markPaused(id: itemID)
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
        if let tasks = pairedTasks[itemID], !tasks.isEmpty {
            DownloadManagerService.shared.markResumed(id: itemID)
            tasks.forEach { $0.resume() }
            return
        }
        hlsSession.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskDescription == itemID.uuidString }) else { return }
            Task { @MainActor in
                DownloadManagerService.shared.markResumed(id: itemID)
                task.resume()
            }
        }
    }

    func cancelAll() {
        Array(transfers.values).forEach(cancel)
        Array(pairedTasks.keys).forEach { cancel(itemID: $0) }
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
        didFinishDownloadingTo location: URL
    ) {
        guard let transfer = hlsTransfers[assetDownloadTask.taskIdentifier] else { return }
        let stagedURL = transfer.stagingDirectoryURL.appendingPathComponent("asset.movpkg")
        do {
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.moveItem(at: location, to: stagedURL)
            transfer.stagedAssetURL = stagedURL
        } catch {
            transfer.stagedAssetURL = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let transfer = hlsTransfers.removeValue(forKey: task.taskIdentifier) else { return }
        if transfer.isCanceled {
            transfer.continuation?.resume(throwing: CancellationError())
            cleanupHLSTransfer(transfer)
            return
        }
        if let error {
            DownloadManagerService.shared.markFailed(id: transfer.itemID, error: error)
            transfer.continuation?.resume(throwing: error)
            cleanupHLSTransfer(transfer)
            return
        }
        guard let stagedAssetURL = transfer.stagedAssetURL else {
            let error = StreamingMediaDownloadError.unavailable
            DownloadManagerService.shared.markFailed(id: transfer.itemID, error: error)
            transfer.continuation?.resume(throwing: error)
            cleanupHLSTransfer(transfer)
            return
        }
        Task { @MainActor in
            do {
                try await exportHLSAsset(
                    at: stagedAssetURL,
                    destinationURL: transfer.destinationURL
                )
                DownloadManagerService.shared.markFinished(id: transfer.itemID)
                transfer.continuation?.resume(returning: transfer.destinationURL)
            } catch {
                DownloadManagerService.shared.markFailed(id: transfer.itemID, error: error)
                transfer.continuation?.resume(throwing: error)
            }
            cleanupHLSTransfer(transfer)
        }
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

    private func downloadDirectTrack(
        request: URLRequest,
        destinationURL: URL,
        itemID: UUID
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var task: URLSessionDownloadTask!
            task = directSession.downloadTask(with: request) { [weak self] temporaryURL, response, error in
                let result: Result<URL, Error>
                do {
                    if let error { throw error }
                    guard let temporaryURL,
                          let response = response as? HTTPURLResponse,
                          (200...299).contains(response.statusCode) else {
                        throw WebResourceDownloadError.invalidResponse
                    }
                    try? FileManager.default.removeItem(at: destinationURL)
                    do {
                        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                    } catch {
                        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
                    }
                    result = .success(destinationURL)
                } catch {
                    result = .failure(error)
                }
                Task { @MainActor in
                    self?.pairedTasks[itemID]?.removeAll { $0.taskIdentifier == task.taskIdentifier }
                    continuation.resume(with: result)
                }
            }
            pairedTasks[itemID, default: []].append(task)
            let observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self, weak task] _, _ in
                guard let task else { return }
                Task { @MainActor in
                    self?.updatePairedProgress(itemID: itemID, task: task)
                }
            }
            pairedProgressObservations[itemID, default: []].append(observation)
            task.resume()
        }
    }

    private func updatePairedProgress(itemID: UUID, task: URLSessionDownloadTask) {
        pairedProgress[itemID, default: [:]][task.taskIdentifier] = (
            task.countOfBytesReceived,
            task.countOfBytesExpectedToReceive
        )
        let values = pairedProgress[itemID]?.values ?? [:].values
        let completed = values.reduce(Int64(0)) { $0 + max(0, $1.completed) }
        let total = values.reduce(Int64(0)) { $0 + max(0, $1.total) }
        DownloadManagerService.shared.updateProgress(id: itemID, completed: completed, total: total)
    }

    private func finishPaired(itemID: UUID) {
        pairedTasks.removeValue(forKey: itemID)?.forEach { $0.cancel() }
        pairedProgressObservations.removeValue(forKey: itemID)?.forEach { $0.invalidate() }
        pairedProgress.removeValue(forKey: itemID)
        if let directory = pairedDirectories.removeValue(forKey: itemID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func cancelHLSTransfer(itemID: UUID) {
        guard let transfer = hlsTransfers.values.first(where: { $0.itemID == itemID }),
              !transfer.isCanceled else { return }
        transfer.isCanceled = true
        DownloadManagerService.shared.markCanceled(id: itemID)
        hlsSession.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == itemID.uuidString })?.cancel()
        }
    }

    private func cleanupHLSTransfer(_ transfer: HLSTransfer) {
        try? FileManager.default.removeItem(at: transfer.stagingDirectoryURL)
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
    }

    private func mux(
        videoURL: URL,
        audioURL: URL,
        destinationURL: URL,
        maximumDurationSeconds: Double? = nil
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
