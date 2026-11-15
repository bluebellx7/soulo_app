import AVFoundation
import BackgroundTasks
import UIKit

enum MediaExportBackgroundError: LocalizedError {
    case interrupted
    var errorDescription: String? { ToolText.text("video_export_failed") }
}

/// A system-visible task covers only active, user-initiated native exports.
/// Network transfers retain their URLSession background sessions.
@MainActor
final class MediaExportBackgroundService {
    static let shared = MediaExportBackgroundService()
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.dkluge.Soulo") + ".media.exports"
    private var registered = false
    private var submitted = false
    private struct Job {
        let progress: () -> Double
        let cancel: () -> Void
    }
    private var jobs: [UUID: Job] = [:]
    private var interrupted: Set<UUID> = []
    private var systemTask: BGTask?
    private var timer: Timer?
    private var allSucceeded = true
    private var batchUnits: Int64 = 0
    private var completedUnits: Int64 = 0
    var isRunning: Bool { systemTask != nil }
    #if SOULO_ACCEPTANCE
    private(set) var acceptanceRegistration: Bool?
    private(set) var acceptanceSubmissionError: String?
    var acceptanceProgress: Double? {
        guard #available(iOS 26.0, *), let task = systemTask as? BGContinuedProcessingTask else { return nil }
        return task.progress.fractionCompleted
    }
    #endif

    func register() {
        guard !registered else { return }; registered = true
        if #available(iOS 26.0, *) {
            let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
                Task { @MainActor in Self.shared.accept(task) }
            }
            #if SOULO_ACCEPTANCE
            acceptanceRegistration = accepted
            #else
            _ = accepted
            #endif
        }
    }

    @available(iOS 26.0, *)
    private func accept(_ task: BGTask) {
        submitted = false
        guard let task = task as? BGContinuedProcessingTask, !jobs.isEmpty else {
            task.setTaskCompleted(success: false); return
        }
        systemTask = task
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task, self.systemTask === task else { return }
                self.interrupted.formUnion(self.jobs.keys)
                self.jobs.values.forEach { $0.cancel() }
                self.systemTask = nil
                task.setTaskCompleted(success: false)
            }
        }
        updateProgress()
    }

    private func begin(progress: @escaping () -> Double, cancel: @escaping () -> Void) -> UUID {
        register()
        if jobs.isEmpty { allSucceeded = true; batchUnits = 0; completedUnits = 0 }
        let id = UUID(); jobs[id] = Job(progress: progress, cancel: cancel)
        batchUnits += 10_000
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in Self.shared.updateProgress() }
            }
        }
        if #available(iOS 26.0, *), UIApplication.shared.applicationState == .active,
           !submitted, systemTask == nil {
            let request = BGContinuedProcessingTaskRequest(identifier: Self.identifier,
                title: ToolText.text("video_export_mp4"), subtitle: LanguageManager.shared.localizedString("downloads"))
            request.strategy = .queue
            do { try BGTaskScheduler.shared.submit(request); submitted = true }
            catch {
                #if SOULO_ACCEPTANCE
                acceptanceSubmissionError = String(describing: error)
                #endif
                // Existing finite background assertions remain the fallback.
            }
        }
        updateProgress()
        return id
    }

    private func finish(_ id: UUID, success: Bool) {
        allSucceeded = allSucceeded && success
        jobs.removeValue(forKey: id); interrupted.remove(id)
        completedUnits += 10_000
        guard jobs.isEmpty else { updateProgress(); return }
        timer?.invalidate(); timer = nil
        systemTask?.setTaskCompleted(success: allSucceeded); systemTask = nil
        if #available(iOS 26.0, *), submitted {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        }
        submitted = false
    }

    private func updateProgress() {
        guard #available(iOS 26.0, *), let task = systemTask as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = batchUnits
        task.progress.completedUnitCount = jobs.values.reduce(completedUnits) {
            let fraction = $1.progress()
            return $0 + Int64((fraction.isFinite ? min(1, max(0, fraction)) : 0) * 10_000)
        }
    }

    func perform<Result>(progress: Progress, operation: () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        let id = begin(progress: { progress.fractionCompleted }, cancel: { progress.cancel() })
        do {
            let result = try await operation()
            try Task.checkCancellation()
            if progress.isCancelled { throw CancellationError() }
            finish(id, success: true)
            return result
        } catch {
            let wasInterrupted = interrupted.contains(id)
            finish(id, success: false)
            if wasInterrupted { throw MediaExportBackgroundError.interrupted }
            throw error
        }
    }

    func export(_ exporter: AVAssetExportSession) async throws {
        try Task.checkCancellation()
        let id = begin(progress: { Double(exporter.progress) }, cancel: { exporter.cancelExport() })
        let box = ExporterBox(exporter)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                    exporter.exportAsynchronously {
                        switch box.value.status {
                        case .completed: reply.resume()
                        case .cancelled: reply.resume(throwing: CancellationError())
                        default: reply.resume(throwing: box.value.error ?? StreamingMediaDownloadError.exportFailed(""))
                        }
                    }
                }
            } onCancel: { box.value.cancelExport() }
            try Task.checkCancellation()
            finish(id, success: true)
        } catch {
            let wasInterrupted = interrupted.contains(id)
            finish(id, success: false)
            if wasInterrupted { throw MediaExportBackgroundError.interrupted }
            throw error
        }
    }
}

private final class ExporterBox: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}
