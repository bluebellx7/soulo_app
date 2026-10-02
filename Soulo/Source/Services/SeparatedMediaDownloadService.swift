import AVFoundation
import Foundation
import UIKit

/// Each track belongs to a system background session. Completed tracks are
/// durable until the final MP4 has been committed, so an interrupted merge can
/// restart without downloading them again. Requests/cookies are never journaled.
@MainActor
final class SeparatedMediaDownloadService: NSObject, @preconcurrency URLSessionDownloadDelegate {
    static let shared = SeparatedMediaDownloadService(
        manager: .shared, directory: storageDirectory, sessionIdentifier: sessionIdentifier
    )
    static let sessionIdentifier = "com.dkluge.Soulo.separated-media-downloads"

    enum Track: String, CaseIterable { case video, audio }
    private let manager: DownloadManagerService
    private let rootDirectory: URL
    private let backgroundSessionIdentifier: String
    private var tasks: [UUID: [Track: URLSessionDownloadTask]] = [:]
    private var progress: [UUID: [Track: (received: Int64, expected: Int64)]] = [:]
    private var continuations: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var merges: [UUID: Task<Void, Never>] = [:]
    private var exporters: [UUID: AVAssetExportSession] = [:]
    private var deferredMerges = Set<UUID>()
    private var backgroundAssertions: [UUID: UIBackgroundTaskIdentifier] = [:]
    private var observers: [NSObjectProtocol] = []
    private var recovery: Task<Void, Never>?
    private var finishedEvents = false
    var backgroundEventsCompletionHandler: (() -> Void)? {
        didSet { finishEventsIfPossible() }
    }

    nonisolated static var storageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeparatedMediaDownloads", isDirectory: true)
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    init(manager: DownloadManagerService, directory: URL, sessionIdentifier: String) {
        self.manager = manager
        rootDirectory = directory
        backgroundSessionIdentifier = sessionIdentifier
        super.init()
        _ = session
        recovery = Task { await restore() }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.recovery?.value
                self.resumePendingMerges()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .cancelActiveDownloads, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingIDs().forEach { self.cancel(id: $0) }
            }
        })
    }

    nonisolated static func taskKey(id: UUID, track: Track) -> String { "\(id.uuidString)/\(track.rawValue)" }

    nonisolated static func parseTaskKey(_ value: String?) -> (id: UUID, track: Track)? {
        guard let parts = value?.split(separator: "/"), parts.count == 2,
              let id = UUID(uuidString: String(parts[0])), let track = Track(rawValue: String(parts[1])) else {
            return nil
        }
        return (id, track)
    }

    nonisolated static func trackURL(id: UUID, track: Track, directory: URL = storageDirectory) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(track == .video ? "video.mp4" : "audio.m4a")
    }

    nonisolated static func hasCompletedTracks(id: UUID, directory: URL = storageDirectory) -> Bool {
        Track.allCases.allSatisfy {
            let values = try? trackURL(id: id, track: $0, directory: directory)
                .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }

    private func directory(id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func pendingIDs() -> [UUID] {
        ((try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: nil
        )) ?? []).compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    func prepare() async { await recovery?.value }

    func resumePendingMerges() {
        for id in pendingIDs() {
            deferredMerges.remove(id)
            mergeIfReady(id: id)
        }
    }

    func deferMergeUntilForeground(id: UUID) {
        guard merges[id] != nil else { return }
        deferredMerges.insert(id)
        merges[id]?.cancel()
        exporters[id]?.cancelExport()
        // The track files are already durable. Leave the row pending;
        // the next foreground activation restarts only the merge.
        endAssertion(id: id)
        finishEventsIfPossible()
    }

    func invalidate() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        session.invalidateAndCancel()
    }

    func start(item: BrowserDownloadItem, videoRequest: URLRequest, audioRequest: URLRequest) async throws -> URL {
        await recovery?.value
        guard manager.downloads.contains(where: { $0.id == item.id && [.inProgress, .paused].contains($0.status) }) else {
            throw CancellationError()
        }
        do {
            try FileManager.default.createDirectory(at: directory(id: item.id), withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory(id: item.id).path
            )
            var storage = directory(id: item.id)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try storage.setResourceValues(values)
        } catch {
            manager.markFailed(id: item.id, error: error)
            cleanup(id: item.id)
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[item.id] = continuation
            for (track, request) in [(Track.video, videoRequest), (.audio, audioRequest)] {
                let task = session.downloadTask(with: request)
                task.taskDescription = Self.taskKey(id: item.id, track: track)
                tasks[item.id, default: [:]][track] = task
                if manager.downloads.first(where: { $0.id == item.id })?.status == .inProgress {
                    task.resume()
                }
            }
        }
    }

    private func restore() async {
        let restored = await session.allTasks
        for task in restored {
            guard let key = Self.parseTaskKey(task.taskDescription), let task = task as? URLSessionDownloadTask else {
                task.cancel(); continue
            }
            guard let item = manager.downloads.first(where: { $0.id == key.id }),
                  item.transport == .separated, [.inProgress, .paused].contains(item.status) else {
                task.cancel(); continue
            }
            tasks[key.id, default: [:]][key.track] = task
            if item.status == .paused && task.state == .running { task.suspend() }
            else if item.status == .inProgress && task.state == .suspended { task.resume() }
            updateProgress(id: key.id, track: key.track, received: task.countOfBytesReceived,
                           expected: task.countOfBytesExpectedToReceive)
        }
        // Delegate delivery and getAllTasks can overlap during a background
        // relaunch. Allow already completed files to arrive before reconciliation.
        try? await Task.sleep(for: .milliseconds(200))
        for item in manager.downloads where item.transport == .separated && [.inProgress, .paused].contains(item.status) {
            let missing = Track.allCases.contains {
                !FileManager.default.fileExists(atPath: Self.trackURL(id: item.id, track: $0, directory: rootDirectory).path)
                    && tasks[item.id]?[$0] == nil
            }
            if missing {
                fail(id: item.id, error: StreamingMediaDownloadError.unavailable)
            } else {
                mergeIfReady(id: item.id)
            }
        }
        for id in pendingIDs() where !manager.downloads.contains(where: {
            $0.id == id && $0.transport == .separated && [.inProgress, .paused].contains($0.status)
        }) { cleanup(id: id) }
    }

    func pause(id: UUID) {
        guard manager.downloads.first(where: { $0.id == id })?.status == .inProgress else { return }
        manager.markPaused(id: id)
        tasks[id]?.values.forEach { $0.suspend() }
        merges[id]?.cancel()
        exporters[id]?.cancelExport()
    }

    func resume(id: UUID) {
        guard manager.downloads.first(where: { $0.id == id })?.status == .paused else { return }
        manager.markResumed(id: id)
        tasks[id]?.values.forEach { $0.resume() }
        mergeIfReady(id: id)
    }

    func cancel(id: UUID) {
        manager.markCanceled(id: id)
        merges[id]?.cancel()
        exporters[id]?.cancelExport()
        cleanup(id: id)
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = Self.parseTaskKey(downloadTask.taskDescription) else { return }
        updateProgress(id: key.id, track: key.track, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    private func updateProgress(id: UUID, track: Track, received: Int64, expected: Int64) {
        progress[id, default: [:]][track] = (max(0, received), expected)
        let parts = Track.allCases.map { track -> (received: Int64, expected: Int64) in
            if let value = progress[id]?[track] { return value }
            let size = (try? Self.trackURL(id: id, track: track, directory: rootDirectory).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (Int64(size), size > 0 ? Int64(size) : -1)
        }
        let expected = parts.allSatisfy { $0.expected > 0 } ? parts.reduce(Int64(0)) { $0 + $1.expected } : -1
        manager.updateProgress(id: id, completed: parts.reduce(Int64(0)) { $0 + $1.received }, total: expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = Self.parseTaskKey(downloadTask.taskDescription),
              let item = manager.downloads.first(where: { $0.id == key.id }),
              [.inProgress, .paused].contains(item.status) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw WebResourceDownloadError.invalidResponse
            }
            let destination = Self.trackURL(id: key.id, track: key.track, directory: rootDirectory)
            try FileManager.default.createDirectory(at: directory(id: key.id), withIntermediateDirectories: true)
            try BackgroundDownloadService.validateDownloadedFile(at: location, filename: destination.lastPathComponent, response: response)
            try? FileManager.default.removeItem(at: destination)
            // This callback must claim the system-owned temporary file before
            // returning. The main delegate queue serializes cancellation with it.
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            let size = Int64((try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard size > 0 else { throw WebResourceDownloadError.invalidResponse }
            updateProgress(id: key.id, track: key.track, received: size, expected: size)
            tasks[key.id]?.removeValue(forKey: key.track)
            mergeIfReady(id: key.id)
        } catch { fail(id: key.id, error: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = Self.parseTaskKey(task.taskDescription) else { return }
        fail(id: key.id, error: error)
    }

    private func mergeIfReady(id: UUID) {
        guard merges[id] == nil, Self.hasCompletedTracks(id: id, directory: rootDirectory),
              let item = manager.downloads.first(where: { $0.id == id }),
              item.status == .inProgress else { return }
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "Finish media download") { [weak self] in
            Task { @MainActor in
                self?.deferMergeUntilForeground(id: id)
            }
        }
        if assertion != .invalid { backgroundAssertions[id] = assertion }
        merges[id] = Task {
            let output = directory(id: id).appendingPathComponent("merged.mp4")
            defer {
                let retryInForeground = !deferredMerges.contains(id)
                    && Task.isCancelled && UIApplication.shared.applicationState == .active
                try? FileManager.default.removeItem(at: output)
                exporters.removeValue(forKey: id)
                merges.removeValue(forKey: id)
                deferredMerges.remove(id)
                endAssertion(id: id)
                finishEventsIfPossible()
                // A quick pause/resume may happen before canceled export unwinds.
                if retryInForeground {
                    mergeIfReady(id: id)
                }
            }
            do {
                try await StreamingMediaDownloadService.shared.mux(
                    videoURL: Self.trackURL(id: id, track: .video, directory: rootDirectory),
                    audioURL: Self.trackURL(id: id, track: .audio, directory: rootDirectory), destinationURL: output,
                    onExporter: { self.exporters[id] = $0 }
                )
                try Task.checkCancellation()
                guard manager.downloads.first(where: { $0.id == id })?.status == .inProgress else {
                    throw CancellationError()
                }
                try FileManager.default.createDirectory(at: item.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: item.localURL)
                try FileManager.default.moveItem(at: output, to: item.localURL)
                manager.markFinished(id: id)
                cleanup(id: id)
                continuations.removeValue(forKey: id)?.resume(returning: item.localURL)
            } catch {
                if !Task.isCancelled { fail(id: id, error: error) }
            }
        }
    }

    private func fail(id: UUID, error: Error) {
        // A late cancellation callback cannot discard a finished item.
        guard let item = manager.downloads.first(where: { $0.id == id }),
              [.inProgress, .paused].contains(item.status) else { return }
        if item.status == .paused { manager.markResumed(id: id) }
        manager.markFailed(id: id, error: error)
        merges[id]?.cancel()
        exporters[id]?.cancelExport()
        cleanup(id: id)
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cleanup(id: UUID) {
        tasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
        progress.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: directory(id: id))
    }

    private func endAssertion(id: UUID) {
        if let assertion = backgroundAssertions.removeValue(forKey: id) {
            UIApplication.shared.endBackgroundTask(assertion)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishedEvents = true
        finishEventsIfPossible()
    }

    private func finishEventsIfPossible() {
        let hasActiveMerge = merges.keys.contains { !deferredMerges.contains($0) }
        guard finishedEvents, !hasActiveMerge, let handler = backgroundEventsCompletionHandler else { return }
        finishedEvents = false
        backgroundEventsCompletionHandler = nil
        handler()
    }
}
