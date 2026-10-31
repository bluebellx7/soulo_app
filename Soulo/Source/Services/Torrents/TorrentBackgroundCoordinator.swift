import BackgroundTasks
import Combine
import UIKit

/// One system-visible continued-processing task covers the user's active BT queue.
@MainActor
final class TorrentBackgroundCoordinator: ObservableObject {
    static let shared = TorrentBackgroundCoordinator()
    static let identifier = "com.dkluge.Soulo.torrents.session"
    @Published private(set) var message: String?
    private var registered = false
    private var submitted = false
    private var task: BGTask?
    private var finiteTask: UIBackgroundTaskIdentifier = .invalid
    private var batch = Set<UUID>()
    private var observers: [NSObjectProtocol] = []
    private init() {}

    func register() {
        guard !registered else { return }
        registered = true
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
                Task { @MainActor in Self.shared.accept(task) }
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.enterBackground() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.endFiniteTask() }
        })
    }
    func userStartedWork() {
        register()
        guard TorrentDownloadService.shared.hasWork else { return }
        batch.formUnion(TorrentDownloadService.shared.jobs.filter { $0.isActive || $0.state == .queued }.map(\.id))
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active,
              !submitted, task == nil else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier,
            title: ToolText.text("torrent_background_title"), subtitle: ToolText.text("torrent_background_running"))
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = true; message = nil
        } catch {
            submitted = false
            message = ToolText.text("torrent_background_unavailable")
        }
    }
    @available(iOS 26.0, *)
    private func accept(_ task: BGTask) {
        guard let continued = task as? BGContinuedProcessingTask, TorrentDownloadService.shared.hasWork else {
            task.setTaskCompleted(success: false); submitted = false; return
        }
        self.task = continued; submitted = false
        continued.expirationHandler = { [weak self, weak continued] in
            Task { @MainActor in
                guard let self, let continued, self.task === continued else { return }
                self.task = nil
                self.message = ToolText.text("torrent_background_paused")
                await TorrentDownloadService.shared.suspendAll()
                continued.setTaskCompleted(success: false)
                self.workChanged()
                self.endFiniteTask()
            }
        }
        endFiniteTask()
        workChanged()
    }
    func workChanged() {
        let service = TorrentDownloadService.shared
        if !service.hasWork {
            if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
                continued.setTaskCompleted(success: !service.jobs.contains { batch.contains($0.id) && $0.state == .failed })
            }
            task = nil
            if submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
            submitted = false; batch.removeAll(); endFiniteTask()
            return
        }
        guard #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask else { return }
        let records = DownloadManagerService.shared.downloads.filter { batch.contains($0.id) }
        let total = records.reduce(Int64(0)) { $0 + $1.expectedBytes }
        let done = records.reduce(Int64(0)) { $0 + $1.receivedBytes }
        // Metadata acquisition is indeterminate. Never invent progress to keep a task alive.
        continued.progress.totalUnitCount = total > 0 ? total : -1
        continued.progress.completedUnitCount = min(done, max(0, total))
        continued.updateTitle(ToolText.text("torrent_background_title"), subtitle: service.activeJobs.first?.name ?? ToolText.text("torrent_background_running"))
    }
    private func enterBackground() {
        guard TorrentDownloadService.shared.hasWork, task == nil else { return }
        // A queued continued task may not have started. A finite grace period protects resume data.
        guard finiteTask == .invalid else { return }
        finiteTask = UIApplication.shared.beginBackgroundTask(withName: "Save torrent progress") {
            Task { @MainActor in
                await TorrentDownloadService.shared.suspendAll()
                Self.shared.workChanged()
                Self.shared.endFiniteTask()
            }
        }
        if #available(iOS 26.0, *), submitted { return }
        Task {
            await TorrentDownloadService.shared.suspendAll()
            message = ToolText.text("torrent_background_paused")
            workChanged()
            endFiniteTask()
        }
    }
    private func endFiniteTask() {
        guard finiteTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finiteTask); finiteTask = .invalid
    }
}
