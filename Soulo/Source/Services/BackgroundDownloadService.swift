import AVFoundation
import Foundation

final class BackgroundDownloadService: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloadService()
    static let sessionIdentifier = "com.dkluge.Soulo.background-downloads"

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private lazy var foregroundFallbackSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var foregroundFallbackIDs = Set<UUID>()
    private var userScriptPolicies: [UUID: UserScriptDownloadPolicy] = [:]
    private var videoDownloads: [UUID: BackgroundVideoFile] = [:]
    private var startingDownloads = Set<UUID>()
    var backgroundEventsCompletionHandler: (() -> Void)?

    static var stagingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundDownloadStaging", isDirectory: true)
    }

    static func stageDownloadedFile(
        at location: URL,
        id: UUID,
        directory: URL = stagingDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagedURL = directory
            .appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("download")
        try? fileManager.removeItem(at: stagedURL)
        do {
            try fileManager.moveItem(at: location, to: stagedURL)
        } catch {
            // A background session may place its temporary file on a different
            // volume. Copying still preserves it before the delegate returns.
            try? fileManager.removeItem(at: stagedURL)
            try fileManager.copyItem(at: location, to: stagedURL)
        }
        return stagedURL
    }

    static func validateDownloadedFile(
        at url: URL,
        filename: String,
        response: URLResponse?
    ) throws {
        let extensionName = (filename as NSString).pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "webm", "m3u8"].contains(extensionName) else { return }
        let mime = (response?.mimeType ?? "").lowercased()
        if mime == "text/html" || mime == "application/json" {
            throw WebResourceDownloadError.invalidResponse
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 128) ?? Data()
        let sample = String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if sample.hasPrefix("<!doctype html") || sample.hasPrefix("<html")
            || sample.hasPrefix("{") {
            throw WebResourceDownloadError.invalidResponse
        }
    }

    private override init() {
        super.init()
        _ = session
        session.getAllTasks { tasks in
            Task { @MainActor in
                let active = tasks.filter { $0.state == .running || $0.state == .suspended }
                let resumedIDs = await self.restoreDownloads(tasks: active)
                let activeIDs = Set(active.compactMap(Self.downloadID)).union(resumedIDs)
                let startedIDs = self.lock.withLock { Set(self.continuations.keys).union(self.startingDownloads) }
                DownloadManagerService.shared.reconcileBackgroundDownloads(activeIDs: activeIDs.union(startedIDs))
            }
        }
    }

    func start(request: URLRequest, item: BrowserDownloadItem) async throws -> URL {
        guard lock.withLock({ startingDownloads.insert(item.id).inserted }) else { throw CancellationError() }
        defer { _ = lock.withLock { startingDownloads.remove(item.id) } }
        if let policy = item.userScriptPolicy {
            // Background URLSession automatically follows redirects. Script
            // downloads need a foreground session so every hop can be checked.
            lock.withLock {
                userScriptPolicies[item.id] = policy
                _ = foregroundFallbackIDs.insert(item.id)
            }
            return try await startTask(in: foregroundFallbackSession, request: request, item: item)
        }
        do {
            if let file = await prepareVideoDownload(request: request, item: item) {
                return try await startVideoDownload(file, request: request, id: item.id)
            }
            guard await MainActor.run(body: {
                DownloadManagerService.shared.downloads.contains { $0.id == item.id && $0.status == .inProgress }
            }) else { throw CancellationError() }
            return try await startTask(in: session, request: request, item: item)
        } catch {
            guard Self.shouldUseForegroundFallback(for: error) else { throw error }
            let isActive = await MainActor.run {
                DownloadManagerService.shared.downloads.contains { $0.id == item.id && $0.status == .inProgress }
            }
            guard isActive else { throw CancellationError() }
            await MainActor.run {
                DownloadManagerService.shared.markResumed(id: item.id)
            }
            lock.withLock {
                _ = foregroundFallbackIDs.insert(item.id)
            }
            return try await startTask(
                in: foregroundFallbackSession,
                request: request,
                item: item
            )
        }
    }

    static func shouldUseForegroundFallback(for error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorUnknown
    }

    private func startTask(
        in session: URLSession,
        request: URLRequest,
        item: BrowserDownloadItem
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            continuations[item.id] = continuation
            lock.unlock()
            let task = session.downloadTask(with: request)
            task.taskDescription = item.id.uuidString
            task.resume()
        }
    }

    func pause(id: UUID) {
        if videoFile(id: id) != nil {
            Task { @MainActor in
                let manager = DownloadManagerService.shared
                manager.markPaused(id: id)
                let (background, foreground) = await (session.allTasks, foregroundFallbackSession.allTasks)
                guard manager.downloads.contains(where: { $0.id == id && $0.status == .paused }) else { return }
                let tasks = (background + foreground).filter { Self.downloadID($0) == id && $0.state != .completed }
                for task in tasks where task.state == .running { task.suspend() }
            }
            return
        }
        session.getAllTasks { tasks in
            if let task = tasks.first(where: { $0.taskDescription == id.uuidString }) as? URLSessionDownloadTask {
                self.pause(task: task, id: id)
                return
            }
            self.foregroundFallbackSession.getAllTasks { fallbackTasks in
                if let task = fallbackTasks.first(where: { $0.taskDescription == id.uuidString }) as? URLSessionDownloadTask {
                    self.pause(task: task, id: id)
                }
            }
        }
    }

    private func pause(task: URLSessionDownloadTask, id: UUID) {
        task.cancel { resumeData in
            guard let resumeData, !resumeData.isEmpty else { return }
            Task { @MainActor in
                DownloadManagerService.shared.markPaused(id: id, resumeData: resumeData)
            }
        }
    }

    func resume(id: UUID) {
        Task { @MainActor in
            if let file = videoFile(id: id),
               let item = DownloadManagerService.shared.downloads.first(where: { $0.id == id && $0.status == .paused }) {
                DownloadManagerService.shared.markResumed(id: id)
                if file.isComplete { finishVideoDownload(file, id: id); return }
                let (background, foreground) = await (session.allTasks, foregroundFallbackSession.allTasks)
                let tasks = (background + foreground).filter {
                    VideoDownloadPart($0)?.id == id && ($0.state == .suspended || $0.state == .running)
                }
                await resumeVideoDownload(file, item: item, tasks: tasks)
                return
            }
            let manager = DownloadManagerService.shared
            guard let data = manager.resumeData(id: id) else {
                guard let task = await session.allTasks.first(where: { $0.taskDescription == id.uuidString && $0.state == .suspended }),
                      manager.downloads.contains(where: { $0.id == id && $0.status == .paused }) else { return }
                manager.markResumed(id: id)
                task.resume()
                return
            }
            if let policy = manager.downloads.first(where: { $0.id == id })?.userScriptPolicy {
                lock.withLock {
                    userScriptPolicies[id] = policy
                    _ = foregroundFallbackIDs.insert(id)
                }
            }
            let usesFallback = lock.withLock {
                foregroundFallbackIDs.contains(id)
            }
            let task = (usesFallback ? foregroundFallbackSession : session)
                .downloadTask(withResumeData: data)
            task.taskDescription = id.uuidString
            manager.removeResumeData(id: id)
            manager.markResumed(id: id)
            task.resume()
        }
    }

    func abandon(id: UUID) {
        discardVideoFile(id: id)
        session.getAllTasks { tasks in
            for task in tasks where Self.downloadID(task) == id { task.cancel() }
        }
        foregroundFallbackSession.getAllTasks { tasks in
            for task in tasks where Self.downloadID(task) == id { task.cancel() }
        }
        complete(id: id, result: .failure(CancellationError()))
    }

    func pendingTasksForStorageCleanup() async -> Bool {
        for source in [session, foregroundFallbackSession] {
            let tasks = await source.allTasks
            if tasks.contains(where: { $0.state != .completed }) { return true }
        }
        return false
    }
    func cancelTasksForStorageCleanup() async {
        for source in [session, foregroundFallbackSession] {
            for task in await source.allTasks { task.cancel() }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let part = VideoDownloadPart(downloadTask), (downloadTask.response as? HTTPURLResponse)?.statusCode != 200 {
            videoFile(id: part.id)?.recordBytes(bytesWritten)
            return
        }
        guard let id = Self.downloadID(downloadTask) else { return }
        Task { @MainActor in
            DownloadManagerService.shared.updateProgress(
                id: id,
                completed: totalBytesWritten,
                total: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let policy = task.taskDescription.flatMap(UUID.init(uuidString:)).flatMap { id in
            lock.withLock { userScriptPolicies[id] }
        }
        if let policy, request.url.map(policy.allows) != true {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let part = VideoDownloadPart(downloadTask) {
            if part.index == 0, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 {
                // Some servers advertise ranges but return the full body.
                // This is already a complete ordinary download.
                discardVideoFile(id: part.id)
            } else {
                receiveVideoPart(part, from: location, task: downloadTask, session: session)
                return
            }
        }
        guard let id = Self.downloadID(downloadTask) else { return }
        let stagedURL: URL
        do {
            if let policy = lock.withLock({ userScriptPolicies[id] }),
               downloadTask.response?.url.map(policy.allows) != true {
                throw URLError(.unsupportedURL)
            }
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw WebResourceDownloadError.invalidResponse
            }
            // CFNetwork owns `location` and may delete it as soon as this delegate
            // callback returns. Move it synchronously before crossing actors.
            stagedURL = try Self.stageDownloadedFile(at: location, id: id)
        } catch {
            Task { @MainActor in
                DownloadManagerService.shared.markFailed(id: id, error: error)
                self.complete(id: id, result: .failure(error))
            }
            return
        }

        Task { @MainActor in
            guard let item = DownloadManagerService.shared.downloads.first(where: { $0.id == id }),
                  [.inProgress, .paused].contains(item.status) else {
                try? FileManager.default.removeItem(at: stagedURL)
                self.complete(id: id, result: .failure(WebResourceDownloadError.invalidResponse))
                return
            }
            do {
                try Self.validateDownloadedFile(
                    at: stagedURL, filename: item.fileName, response: downloadTask.response
                )
                try FileManager.default.createDirectory(
                    at: item.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: item.localURL)
                try FileManager.default.moveItem(at: stagedURL, to: item.localURL)
                // A pause can race the final response. Preserve the completed
                // file rather than leaving a paused row with no network task.
                if item.status == .paused { DownloadManagerService.shared.markResumed(id: id) }
                DownloadManagerService.shared.markFinished(id: id)
                self.complete(id: id, result: .success(item.localURL))
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                DownloadManagerService.shared.markFailed(id: id, error: error)
                self.complete(id: id, result: .failure(error))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled,
           (nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int) == NSURLErrorCancelledReasonUserForceQuitApplication {
            // The task snapshot on reopening will restart missing work.
            return
        }
        if let part = VideoDownloadPart(task) {
            guard let error, videoFile(id: part.id) != nil else { return }
            if session === self.session, Self.shouldUseForegroundFallback(for: error), let request = task.originalRequest {
                let replacement = foregroundFallbackSession.downloadTask(with: request)
                replacement.taskDescription = part.description
                Task { @MainActor in
                    let status = DownloadManagerService.shared.downloads.first { $0.id == part.id }?.status
                    if status == .inProgress { replacement.resume() }
                    else if status != .paused { replacement.cancel() }
                }
            } else {
                Task { @MainActor in self.failVideoDownload(id: part.id, error: error) }
            }
            return
        }
        guard let error,
              let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            if session === self.session && Self.shouldUseForegroundFallback(for: error) {
                // The caller retries with the foreground session. Do not remove
                // the live playback asset or briefly publish a failed row.
                self.complete(id: id, result: .failure(error))
                return
            }
            if nsError.code == NSURLErrorCancelled,
               let resumeData,
               !resumeData.isEmpty {
                DownloadManagerService.shared.markPaused(id: id, resumeData: resumeData)
                // Keep the original async operation suspended. If the user resumes,
                // the replacement task completes the same continuation normally.
                return
            }
            DownloadManagerService.shared.markFailed(id: id, error: error)
            self.complete(id: id, result: .failure(error))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundEventsCompletionHandler?()
            self.backgroundEventsCompletionHandler = nil
        }
    }

    private func complete(id: UUID, result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        foregroundFallbackIDs.remove(id)
        userScriptPolicies[id] = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func downloadID(_ task: URLSessionTask) -> UUID? {
        VideoDownloadPart(task)?.id ?? task.taskDescription.flatMap(UUID.init(uuidString:))
    }

    private func videoFile(id: UUID) -> BackgroundVideoFile? {
        lock.withLock {
            if let file = videoDownloads[id] { return file }
            guard let file = try? BackgroundVideoFile(id: id) else { return nil }
            videoDownloads[id] = file
            return file
        }
    }

    private func removeVideoFile(id: UUID) -> BackgroundVideoFile? {
        lock.withLock { videoDownloads.removeValue(forKey: id) }
    }

    @discardableResult
    private func discardVideoFile(id: UUID) -> Bool {
        lock.withLock {
            if let file = videoDownloads.removeValue(forKey: id) {
                file.discard()
                return true
            }
            return BackgroundVideoFile.removeStaging(id: id)
        }
    }

    @MainActor
    private func prepareVideoDownload(request: URLRequest, item: BrowserDownloadItem) async -> BackgroundVideoFile? {
        let manager = DownloadManagerService.shared
        guard let source = manager.playbackSource(for: item.id) else { return nil }
        var head = request
        head.httpMethod = "HEAD"
        head.timeoutInterval = 4
        head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 5
        let probe = URLSession(configuration: configuration)
        defer { probe.finishTasksAndInvalidate() }
        guard let (_, response) = try? await probe.data(for: head), let info = response as? HTTPURLResponse,
              info.statusCode == 200, info.expectedContentLength > 1,
              info.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
              (info.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity",
              info.mimeType != "text/html", info.mimeType != "application/json",
              let validator = Self.entityValidator(info),
              manager.playbackSource(for: item.id) === source,
              manager.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }),
              let file = try? BackgroundVideoFile(id: item.id, total: info.expectedContentLength, validator: validator) else { return nil }
        lock.withLock { videoDownloads[item.id] = file }
        return file
    }

    private static func entityValidator(_ response: HTTPURLResponse) -> String? {
        if let tag = response.value(forHTTPHeaderField: "ETag"), tag.hasPrefix("\"") { return tag }
        return response.value(forHTTPHeaderField: "Last-Modified").flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult @MainActor
    private func presentVideoDownload(_ file: BackgroundVideoFile, item: BrowserDownloadItem,
                                      source: DownloadPlaybackSource? = nil) async -> Bool {
        guard let server = try? await TorrentStreamServer.start(size: file.total, name: item.fileName, reader: file.read),
              videoFile(id: item.id) === file,
              DownloadManagerService.shared.downloads.contains(where: { $0.id == item.id && [.inProgress, .paused].contains($0.status) }) else { return false }
        let asset = AVURLAsset(url: server.url)
        ProgressiveVideoPlaybackBridge.associateDownloadTransfer(file.transfer, with: asset)
        DownloadManagerService.shared.registerPlaybackSource(id: item.id, asset: asset,
            pageURL: source?.pageURL, webView: source?.webView, persistPosition: source?.persistsPosition ?? false,
            resourceLease: server)
        return true
    }

    @MainActor
    private func startVideoDownload(_ file: BackgroundVideoFile, request: URLRequest, id: UUID) async throws -> URL {
        guard DownloadManagerService.shared.downloads.contains(where: { $0.id == id && $0.status == .inProgress }) else {
            discardVideoFile(id: id)
            throw CancellationError()
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { continuations[id] = continuation }
            enqueueVideoParts([0], file: file, request: request, id: id, using: session, paused: false)
        }
    }

    private func enqueueVideoParts(_ indexes: [Int], file: BackgroundVideoFile, request: URLRequest,
                                   id: UUID, using session: URLSession, paused: Bool) {
        let tasks = file.claimParts(indexes).map { index in
            let range = file.range(for: index)
            var ranged = request
            ranged.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            ranged.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            ranged.setValue(file.validator, forHTTPHeaderField: "If-Range")
            let task = session.downloadTask(with: ranged)
            task.taskDescription = VideoDownloadPart(id: id, index: index).description
            if index == 0 || index == file.partCount - 1 { task.priority = URLSessionTask.highPriority }
            return task
        }
        if !paused { for task in tasks { task.resume() } }
    }

    private func receiveVideoPart(_ part: VideoDownloadPart, from location: URL,
                                  task: URLSessionDownloadTask, session: URLSession) {
        guard let file = videoFile(id: part.id) else { return }
        do {
            let written = try file.writePart(part.index, from: location, response: task.response)
            DispatchQueue.main.async {
                let manager = DownloadManagerService.shared
                guard let item = manager.downloads.first(where: { $0.id == part.id && [.inProgress, .paused].contains($0.status) }),
                      self.videoFile(id: part.id) === file else { return }
                if part.index == 0, written, let request = task.originalRequest {
                    Task { @MainActor in
                        await self.presentVideoDownload(file, item: item, source: manager.playbackSource(for: item.id))
                        guard let current = manager.downloads.first(where: { $0.id == part.id && [.inProgress, .paused].contains($0.status) }),
                              self.videoFile(id: part.id) === file else { return }
                        manager.updateProgress(id: part.id, completed: file.received, total: file.total)
                        self.enqueueVideoParts(file.missingParts(excluding: []), file: file, request: request, id: part.id,
                                               using: session, paused: current.status == .paused)
                    }
                } else {
                    manager.updateProgress(id: part.id, completed: file.received, total: file.total)
                }
                if file.isComplete { self.finishVideoDownload(file, id: part.id) }
            }
        } catch let error as URLError where error.code == .badServerResponse {
            let request = task.originalRequest
            DispatchQueue.main.async {
                if let request { self.restartWholeVideoDownload(id: part.id, file: file, request: request) }
                else { self.failVideoDownload(id: part.id, error: error) }
            }
        } catch {
            DispatchQueue.main.async { self.failVideoDownload(id: part.id, error: error) }
        }
    }

    @MainActor
    private func restartWholeVideoDownload(id: UUID, file: BackgroundVideoFile, request: URLRequest) {
        let manager = DownloadManagerService.shared
        guard let item = manager.downloads.first(where: { $0.id == id && [.inProgress, .paused].contains($0.status) }),
              videoFile(id: id) === file, discardVideoFile(id: id) else { return }
        // A changed entity validator makes the staged ranges unsafe to combine.
        // Keep the same download and continuation, and transfer the whole entity.
        cancelVideoParts(id: id)
        var whole = request
        whole.setValue(nil, forHTTPHeaderField: "Range")
        whole.setValue(nil, forHTTPHeaderField: "If-Range")
        let task = session.downloadTask(with: whole)
        task.taskDescription = id.uuidString
        let playback = manager.playbackSource(for: id)
        if item.status == .inProgress {
            manager.updateProgress(id: id, completed: 0, total: 0)
            task.resume()
        }
        Task { @MainActor in
            await WebResourceDownloadService.shared.registerDirectVideoPlayback(for: item, request: whole,
                pageURL: playback?.pageURL, webView: playback?.webView)
        }
    }

    @MainActor
    private func restoreDownloads(tasks: [URLSessionTask]) async -> Set<UUID> {
        let manager = DownloadManagerService.shared
        let entries = tasks.compactMap { task in Self.downloadID(task).map { ($0, task) } }
        let byID = Dictionary(grouping: entries, by: \.0)
        var resumed: Set<UUID> = []
        for item in manager.downloads where item.transport == .background && [.inProgress, .paused].contains(item.status) {
            guard !lock.withLock({ startingDownloads.contains(item.id) }) else { continue }
            let pending = byID[item.id]?.map(\.1) ?? []
            if let file = videoFile(id: item.id) {
                if file.isComplete { finishVideoDownload(file, id: item.id); continue }
                if item.status == .inProgress {
                    await resumeVideoDownload(file, item: item, tasks: pending)
                    resumed.insert(item.id)
                }
                continue
            }
            let staleRanges = pending.filter { VideoDownloadPart($0) != nil }
            staleRanges.forEach { $0.cancel() }
            guard item.status == .inProgress else { continue }
            if let existing = pending.first(where: { VideoDownloadPart($0) == nil }) {
                if existing.state == .suspended { existing.resume() }
                continue
            }
            guard !lock.withLock({ continuations[item.id] != nil || startingDownloads.contains(item.id) }) else { continue }
            if let resumeData = manager.resumeData(id: item.id), item.userScriptPolicy == nil {
                let task = session.downloadTask(withResumeData: resumeData)
                task.taskDescription = item.id.uuidString
                manager.removeResumeData(id: item.id)
                task.resume()
                resumed.insert(item.id)
            } else if let request = await WebResourceDownloadService.shared.restoredBackgroundRequest(for: item),
                      manager.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }),
                      !lock.withLock({ continuations[item.id] != nil || startingDownloads.contains(item.id) }) {
                // The old system partial file is no longer accessible. The
                // replacement starts at zero and reports its own progress.
                manager.updateProgress(id: item.id, completed: 0, total: 0)
                resumed.insert(item.id)
                Task { @MainActor in
                    await WebResourceDownloadService.shared.registerDirectVideoPlayback(for: item, request: request)
                    do { _ = try await self.start(request: request, item: item) }
                    catch is CancellationError {}
                    catch { manager.markFailed(id: item.id, error: error) }
                }
            }
        }
        return resumed
    }

    @MainActor
    private func resumeVideoDownload(_ file: BackgroundVideoFile, item: BrowserDownloadItem, tasks: [URLSessionTask]) async {
        let manager = DownloadManagerService.shared
        let active = Set(tasks.compactMap { VideoDownloadPart($0)?.index })
        file.noteActiveParts(active)
        if file.received > 0,
           manager.playbackSource(for: item.id).flatMap({ ProgressiveVideoPlaybackBridge.transfer(for: $0.asset) }) == nil {
            await presentVideoDownload(file, item: item, source: manager.playbackSource(for: item.id))
        }
        guard manager.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }),
              videoFile(id: item.id) === file else { return }
        let missing = file.missingParts(excluding: active)
        if !missing.isEmpty {
            let request: URLRequest?
            if let existing = tasks.first?.originalRequest { request = existing }
            else { request = await WebResourceDownloadService.shared.restoredBackgroundRequest(for: item) }
            guard manager.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }),
                  videoFile(id: item.id) === file else { return }
            guard let request else { failVideoDownload(id: item.id, error: URLError(.networkConnectionLost)); return }
            enqueueVideoParts(missing, file: file, request: request, id: item.id, using: session, paused: false)
        }
        for task in tasks where task.state == .suspended { task.resume() }
        manager.updateProgress(id: item.id, completed: file.received, total: file.total)
    }

    @MainActor
    private func finishVideoDownload(_ file: BackgroundVideoFile, id: UUID) {
        let manager = DownloadManagerService.shared
        guard let item = manager.downloads.first(where: { $0.id == id && [.inProgress, .paused].contains($0.status) }),
              videoFile(id: id) === file else { return }
        do {
            try file.finish(at: item.localURL)
            _ = removeVideoFile(id: id)
            if item.status == .paused { manager.markResumed(id: id) }
            manager.updateProgress(id: id, completed: file.total, total: file.total)
            manager.markFinished(id: id)
            complete(id: id, result: .success(item.localURL))
        } catch { failVideoDownload(id: id, error: error) }
    }

    @MainActor
    private func failVideoDownload(id: UUID, error: Error) {
        guard discardVideoFile(id: id) else { return }
        cancelVideoParts(id: id)
        let manager = DownloadManagerService.shared
        manager.markFailed(id: id, error: error, includingPaused: true)
        complete(id: id, result: .failure(error))
    }

    private func cancelVideoParts(id: UUID) {
        for source in [session, foregroundFallbackSession] {
            source.getAllTasks { tasks in
                for task in tasks where VideoDownloadPart(task)?.id == id { task.cancel() }
            }
        }
    }
}

private struct VideoDownloadPart {
    let id: UUID
    let index: Int
    var description: String { "\(id.uuidString)/\(index)" }

    init(id: UUID, index: Int) { self.id = id; self.index = index }

    init?(_ task: URLSessionTask) {
        guard let fields = task.taskDescription?.split(separator: "/"), fields.count == 2,
              let id = UUID(uuidString: String(fields[0])), let index = Int(fields[1]), index >= 0 else { return nil }
        self.init(id: id, index: index)
    }
}

/// A sparse staging file and durable index of validated, readable HTTP ranges.
/// The open handle remains valid after the final file is moved to Downloads.
private final class BackgroundVideoFile: @unchecked Sendable {
    private struct Manifest: Codable {
        var receivedParts: Set<Int> = []
        let total: Int64
        let chunkSize: Int64
        let validator: String
    }

    let transfer = VideoPlaybackTransfer()
    private let lock = NSLock()
    private let directory: URL
    private let handle: FileHandle
    private var manifest: Manifest
    private var closed = false
    private var scheduled = Set<Int>()
    private var measuredBytes: Int64 = 0
    private var measuredSince = ContinuousClock.now
    let total: Int64
    let validator: String
    private let chunkSize: Int64
    var partCount: Int { Int((total - 1) / chunkSize + 1) }
    var isComplete: Bool { lock.withLock { manifest.receivedParts.count == partCount } }
    var received: Int64 { lock.withLock { receivedBytes } }
    private var receivedBytes: Int64 { manifest.receivedParts.reduce(0) { $0 + Int64(range(for: $1).count) } }
    private var stagingFile: URL { directory.appendingPathComponent("media") }
    private var manifestFile: URL { directory.appendingPathComponent("ranges.json") }

    private static func directory(for id: UUID) -> URL {
        BackgroundDownloadService.stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func removeStaging(id: UUID) -> Bool {
        (try? FileManager.default.removeItem(at: directory(for: id))) != nil
    }

    init(id: UUID, total: Int64, validator: String) throws {
        let directory = Self.directory(for: id), manager = FileManager.default
        let targetChunkSize = min(4 * 1_024 * 1_024, max(128 * 1_024, (total - 1) / 16 + 1))
        let minimumChunkSize = (total - 1) / 128 + 1
        let chunkSize = min((total - 1) / 2 + 1, max(targetChunkSize, minimumChunkSize))
        let manifest = Manifest(total: total, chunkSize: chunkSize, validator: validator)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let file = directory.appendingPathComponent("media")
            guard manager.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forUpdating: file)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("ranges.json"), options: .atomic)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        self.directory = directory; self.manifest = manifest
        self.total = total; self.chunkSize = chunkSize; self.validator = validator
    }

    init(id: UUID) throws {
        let directory = Self.directory(for: id)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("ranges.json")))
        guard manifest.total > 1, manifest.chunkSize > 0, manifest.chunkSize < manifest.total,
              manifest.receivedParts.allSatisfy({ $0 >= 0 && Int64($0) <= (manifest.total - 1) / manifest.chunkSize }) else { throw URLError(.cannotParseResponse) }
        handle = try FileHandle(forUpdating: directory.appendingPathComponent("media"))
        self.directory = directory; self.manifest = manifest
        total = manifest.total; chunkSize = manifest.chunkSize; validator = manifest.validator
        transfer.setCachedBytes(receivedBytes, total: total)
    }

    func range(for index: Int) -> Range<Int64> {
        let start = Int64(index) * chunkSize
        return start..<(start + min(chunkSize, total - start))
    }

    func read(_ offset: Int64, _ count: Int) throws -> Data? {
        try lock.withLock {
            guard !closed else { throw CancellationError() }
            let index = Int(offset / chunkSize)
            guard manifest.receivedParts.contains(index) else { return nil }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: min(count, Int(range(for: index).upperBound - offset)))
        }
    }

    func missingParts(excluding active: Set<Int>) -> [Int] {
        lock.withLock {
            if !manifest.receivedParts.contains(0) { return active.contains(0) ? [] : [0] }
            // Fetch the tail before other missing ranges. MP4 files can put
            // their seek index at the end.
            return ([partCount - 1] + Array(1..<(partCount - 1))).filter {
                !active.contains($0) && !manifest.receivedParts.contains($0)
            }
        }
    }

    func noteActiveParts(_ indexes: Set<Int>) {
        lock.withLock { scheduled.formUnion(indexes) }
    }

    func claimParts(_ indexes: [Int]) -> [Int] {
        lock.withLock {
            guard !closed else { return [] }
            return indexes.filter { !manifest.receivedParts.contains($0) && scheduled.insert($0).inserted }
        }
    }

    func recordBytes(_ bytes: Int64) {
        lock.withLock {
            guard !closed, bytes > 0 else { return }
            measuredBytes += bytes
            let now = ContinuousClock.now
            guard measuredSince.duration(to: now) >= .milliseconds(500) else { return }
            transfer.record(bytes: measuredBytes, started: measuredSince, finished: now)
            measuredBytes = 0; measuredSince = now
        }
    }

    func writePart(_ index: Int, from url: URL, response: URLResponse?) throws -> Bool {
        try lock.withLock {
            guard !closed, !manifest.receivedParts.contains(index) else { return false }
            guard (0..<partCount).contains(index), let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let range = range(for: index)
            guard response.statusCode == 206,
                  response.value(forHTTPHeaderField: "Content-Range") == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)",
                  (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity",
                  response.value(forHTTPHeaderField: "ETag") == validator || response.value(forHTTPHeaderField: "Last-Modified") == validator,
                  try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == range.count else { throw URLError(.badServerResponse) }
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            while let data = try input.read(upToCount: 128 * 1_024), !data.isEmpty { try handle.write(contentsOf: data) }
            try handle.synchronize()
            manifest.receivedParts.insert(index)
            try JSONEncoder().encode(manifest).write(to: manifestFile, options: .atomic)
            transfer.setCachedBytes(receivedBytes, total: total)
            return true
        }
    }

    func finish(at destination: URL) throws {
        try lock.withLock {
            guard !closed, manifest.receivedParts.count == partCount else { throw URLError(.networkConnectionLost) }
            try BackgroundDownloadService.validateDownloadedFile(at: stagingFile, filename: destination.lastPathComponent, response: nil)
            try FileManager.default.moveItem(at: stagingFile, to: destination)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func discard() {
        lock.withLock {
            closed = true
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
