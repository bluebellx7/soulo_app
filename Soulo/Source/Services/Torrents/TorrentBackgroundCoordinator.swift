import BackgroundTasks
import Combine
import UIKit

/// One system-visible continued-processing task covers the user's active P2P queue.
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
    private var hasWork: Bool { TorrentDownloadService.shared.hasWork || ED2KDownloadService.shared.hasWork }
    private func suspendDownloads(resumeIfActive: Bool = true) async {
        await TorrentDownloadService.shared.suspendAll()
        await ED2KDownloadService.shared.suspendAll()
        // Foreground may arrive while either checkpoint is still being saved.
        if resumeIfActive, UIApplication.shared.applicationState == .active { resumeForegroundDownloads() }
    }

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
            Task { @MainActor in Self.shared.resumeForegroundDownloads() }
        })
        if UIApplication.shared.applicationState == .active { resumeForegroundDownloads() }
    }
    func userStartedWork() {
        register()
        guard hasWork else { return }
        batch.formUnion(DownloadManagerService.shared.downloads.filter {
            [.torrent, .ed2k].contains($0.transport) && $0.status == .inProgress
        }.map(\.id))
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
        guard let continued = task as? BGContinuedProcessingTask, hasWork else {
            task.setTaskCompleted(success: false); submitted = false; return
        }
        self.task = continued; submitted = false
        continued.expirationHandler = { [weak self, weak continued] in
            Task { @MainActor in
                guard let self, let continued, self.task === continued else { return }
                self.task = nil
                self.message = ToolText.text("torrent_background_paused")
                // A task stopped from the foreground must not immediately
                // resubmit itself. A later foreground transition can resume it.
                let wasBackgrounded = UIApplication.shared.applicationState != .active
                await self.suspendDownloads(resumeIfActive: wasBackgrounded)
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
        if !hasWork {
            if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask {
                continued.setTaskCompleted(success: !DownloadManagerService.shared.downloads.contains { batch.contains($0.id) && $0.status == .failed })
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
        continued.updateTitle(ToolText.text("torrent_background_title"), subtitle: service.activeJobs.first?.name
            ?? records.first(where: { $0.status == .inProgress })?.fileName ?? ToolText.text("torrent_background_running"))
    }
    private func enterBackground() {
        guard hasWork, task == nil else { return }
        // A queued continued task may not have started. A finite grace period protects resume data.
        guard finiteTask == .invalid else { return }
        finiteTask = UIApplication.shared.beginBackgroundTask(withName: "Save torrent progress") {
            Task { @MainActor in
                await self.suspendDownloads()
                Self.shared.workChanged()
                Self.shared.endFiniteTask()
            }
        }
        if #available(iOS 26.0, *), submitted { return }
        Task {
            await suspendDownloads()
            message = ToolText.text("torrent_background_paused")
            workChanged()
            endFiniteTask()
        }
    }
    private func endFiniteTask() {
        guard finiteTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finiteTask); finiteTask = .invalid
    }
    private func resumeForegroundDownloads() {
        endFiniteTask()
        if TorrentDownloadService.shared.jobs.contains(where: { $0.state == .paused && $0.resumeAfterSystemPause == true }) {
            message = nil
        }
        TorrentDownloadService.shared.resumeSystemPausedTasks()
    }
}
