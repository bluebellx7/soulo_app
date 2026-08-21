import Foundation

final class BackgroundDownloadService: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloadService()
    static let sessionIdentifier = "com.dkluge.Soulo.background-downloads"

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private lazy var foregroundFallbackSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var foregroundFallbackIDs = Set<UUID>()
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

    private override init() {
        super.init()
        _ = session
        session.getAllTasks { tasks in
            let activeIDs = Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
            Task { @MainActor in
                DownloadManagerService.shared.reconcileBackgroundDownloads(activeIDs: activeIDs)
            }
        }
    }

    func start(request: URLRequest, item: BrowserDownloadItem) async throws -> URL {
        do {
            return try await startTask(in: session, request: request, item: item)
        } catch {
            guard Self.shouldUseForegroundFallback(for: error) else { throw error }
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
            guard let data = DownloadManagerService.shared.resumeData(id: id) else { return }
            let usesFallback = lock.withLock {
                foregroundFallbackIDs.contains(id)
            }
            let task = (usesFallback ? foregroundFallbackSession : session)
                .downloadTask(withResumeData: data)
            task.taskDescription = id.uuidString
            DownloadManagerService.shared.removeResumeData(id: id)
            DownloadManagerService.shared.markResumed(id: id)
            task.resume()
        }
    }

    func abandon(id: UUID) {
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == id.uuidString })?.cancel()
        }
        foregroundFallbackSession.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == id.uuidString })?.cancel()
        }
        complete(id: id, result: .failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
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
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let stagedURL: URL
        do {
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
            guard let item = DownloadManagerService.shared.downloads.first(where: { $0.id == id }) else {
                try? FileManager.default.removeItem(at: stagedURL)
                self.complete(id: id, result: .failure(WebResourceDownloadError.invalidResponse))
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: item.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: item.localURL)
                try FileManager.default.moveItem(at: stagedURL, to: item.localURL)
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
        guard let error,
              let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
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
        lock.unlock()
        continuation?.resume(with: result)
    }
}
