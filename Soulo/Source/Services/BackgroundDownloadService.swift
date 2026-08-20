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
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<URL, Error>] = [:]
    var backgroundEventsCompletionHandler: (() -> Void)?

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
            guard let task = tasks.first(where: { $0.taskDescription == id.uuidString }) as? URLSessionDownloadTask else { return }
            task.cancel { resumeData in
                guard let resumeData, !resumeData.isEmpty else { return }
                Task { @MainActor in
                    DownloadManagerService.shared.markPaused(id: id, resumeData: resumeData)
                }
            }
        }
    }

    func resume(id: UUID) {
        Task { @MainActor in
            guard let data = DownloadManagerService.shared.resumeData(id: id) else { return }
            let task = session.downloadTask(withResumeData: data)
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
        Task { @MainActor in
            guard let item = DownloadManagerService.shared.downloads.first(where: { $0.id == id }) else { return }
            do {
                if let response = downloadTask.response as? HTTPURLResponse,
                   !(200...299).contains(response.statusCode) {
                    throw WebResourceDownloadError.invalidResponse
                }
                try? FileManager.default.removeItem(at: item.localURL)
                try FileManager.default.moveItem(at: location, to: item.localURL)
                DownloadManagerService.shared.markFinished(id: id)
                self.complete(id: id, result: .success(item.localURL))
            } catch {
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
        lock.unlock()
        continuation?.resume(with: result)
    }
}
