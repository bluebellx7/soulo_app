import Combine
import Foundation
import UIKit

struct TorrentDownloadJob: Codable, Identifiable, Equatable {
    enum State: String, Codable { case metadata, selection, queued, starting, downloading, paused, failed, finished }
    let id: UUID
    let hash: String
    var name: String
    var magnet: String?
    var files: [TorrentFileEntry]
    var selected: Set<Int>
    var state: State
    var error = ""
    var createdAt = Date()
    var directory: String
    var isActive: Bool { [.metadata, .starting, .downloading].contains(state) }
    var priorities: [Bool] { files.map { selected.contains($0.index) && !$0.pad } }
    var selectedBytes: Int64 { files.filter { selected.contains($0.index) && !$0.pad }.reduce(0) { $0 + $1.size } }
}

@MainActor
final class TorrentDownloadService: ObservableObject {
    static let shared = TorrentDownloadService()
    @Published private(set) var jobs: [TorrentDownloadJob] = []
    @Published private(set) var snapshots: [UUID: TorrentSnapshot] = [:]
    @Published private(set) var storageError: String?
    private let worker: any TorrentEngine
    private let manager: DownloadManagerService
    private let workChanged: @MainActor () -> Void
    private let userStartedWork: @MainActor () -> Void
    private let root: URL
    private var engineIDs = Set<UUID>()
    private var pollTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var suspended = false
    private var metadataStarted: [UUID: Date] = [:]
    private var generations: [UUID: UUID] = [:]
    private var pauseCheckpoints: [UUID: Task<Void, Never>] = [:]
    var activeJobs: [TorrentDownloadJob] { jobs.filter(\.isActive) }
    var hasWork: Bool { jobs.contains { $0.isActive || $0.state == .queued } }

    init(manager: DownloadManagerService? = nil, root: URL? = nil, worker: any TorrentEngine = TorrentEngineWorker(),
         workChanged: @escaping @MainActor () -> Void = { TorrentBackgroundCoordinator.shared.workChanged() },
         userStartedWork: @escaping @MainActor () -> Void = { TorrentBackgroundCoordinator.shared.userStartedWork() }) {
        self.manager = manager ?? .shared
        self.worker = worker
        self.workChanged = workChanged
        self.userStartedWork = userStartedWork
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TorrentTasks", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let ledger = self.root.appendingPathComponent("tasks.json")
            if FileManager.default.fileExists(atPath: ledger.path) {
                jobs = try JSONDecoder().decode([TorrentDownloadJob].self, from: Data(contentsOf: ledger))
                let records = Set(self.manager.downloads.filter { $0.transport == .torrent }.map(\.id))
                jobs = jobs.filter { records.contains($0.id) }
                for i in jobs.indices {
                    if let record = self.manager.downloads.first(where: { $0.id == jobs[i].id }) {
                        jobs[i].directory = record.localURL.path
                    }
                }
                for i in jobs.indices where jobs[i].isActive || jobs[i].state == .queued {
                    jobs[i].state = .paused
                    self.manager.markPaused(id: jobs[i].id)
                }
                persist()
            }
        } catch { storageError = error.localizedDescription }
    }
    func job(_ id: UUID) -> TorrentDownloadJob? { jobs.first { $0.id == id } }
    private func dataURL(_ id: UUID, _ suffix: String) -> URL { root.appendingPathComponent(id.uuidString + "." + suffix) }
    private func persist() {
        do {
            try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent("tasks.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil
        } catch { storageError = error.localizedDescription }
    }
    private func mutate(_ id: UUID, _ work: (inout TorrentDownloadJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        work(&jobs[i]); persist()
    }
    func create(data: Data?, magnet: String?, openExisting: Bool = false) async throws -> UUID {
        guard jobs.count < 200 else { throw TorrentTaskError.limit }
        let metadata: TorrentMetadata
        if let data { metadata = try await worker.inspect(data: data) }
        else if let magnet { metadata = try await worker.inspect(magnet: magnet) }
        else { throw TorrentTaskError.invalid }
        try Task.checkCancellation()
        if let existing = jobs.first(where: { $0.hash == metadata.hash }) {
            if openExisting { return existing.id }
            throw TorrentTaskError.duplicate
        }
        let name = metadata.name.isEmpty ? "Torrent " + String(metadata.hash.prefix(8)) : metadata.name
        let (item, destination) = manager.beginDownload(suggestedFilename: name, sourceURL: magnet.flatMap(URL.init(string:)), transport: .torrent)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if let data { try data.write(to: dataURL(item.id, "torrent"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            let job = TorrentDownloadJob(id: item.id, hash: metadata.hash, name: name, magnet: magnet, files: metadata.files,
                selected: Set(metadata.files.filter { !$0.pad }.map(\.index)), state: data == nil ? .queued : .selection, directory: destination.path)
            jobs.insert(job, at: 0); persist()
            guard storageError == nil else { throw TorrentTaskError.persistence }
            if data == nil { suspended = false; pump(); userStartedWork() }
            else { manager.markPaused(id: item.id) }
            return item.id
        } catch {
            remove(id: item.id, deleteFiles: true)
            manager.delete(item)
            throw error
        }
    }
    func select(_ id: UUID, indices: Set<Int>) {
        guard let job = job(id), !job.isActive && job.state != .finished else { return }
        let valid = Set(job.files.filter { !$0.pad }.map(\.index))
        mutate(id) { $0.selected = indices.intersection(valid) }
    }
    func start(_ id: UUID) {
        guard let job = job(id), !job.isActive, job.state != .finished else { return }
        if !job.files.isEmpty && job.selected.isEmpty { return }
        suspended = false
        mutate(id) { $0.state = .queued; $0.error = "" }
        self.manager.markResumed(id: id)
        pump()
        userStartedWork()
    }
    private func pump() {
        guard !suspended else { return }
        let available = max(0, 3 - activeJobs.count)
        let next = jobs.filter { $0.state == .queued }.prefix(available).map(\.id)
        for id in next {
            mutate(id) { $0.state = .starting }
            Task { await launch(id, metadataOnly: job(id)?.files.isEmpty ?? true) }
        }
    }
    private func launch(_ id: UUID, metadataOnly: Bool) async {
        guard !suspended, job(id)?.isActive == true else { return }
        let generation = UUID(); generations[id] = generation
        await pauseCheckpoints[id]?.value
        guard !suspended, generations[id] == generation, let job = job(id), job.isActive else { return }
        if metadataOnly { metadataStarted[id] = Date() }
        mutate(id) { $0.state = metadataOnly ? .metadata : .starting; $0.error = "" }
        self.manager.markResumed(id: id)
        do {
            if engineIDs.contains(id) && !metadataOnly { await worker.resume(id: id, priorities: job.priorities) }
            else if !engineIDs.contains(id) {
                let torrent = try? Data(contentsOf: dataURL(id, "torrent"))
                let resume = try? Data(contentsOf: dataURL(id, "resume"))
                try await worker.add(id: id, data: torrent, magnet: job.magnet, directory: URL(fileURLWithPath: job.directory),
                    resume: resume, priorities: job.priorities, metadataOnly: metadataOnly)
                if self.job(id) != nil { engineIDs.insert(id) }
            } else { await worker.resumeMetadata(id: id) }
            guard generations[id] == generation, self.job(id)?.isActive == true else { return }
            mutate(id) { $0.state = metadataOnly ? .metadata : .downloading }
            beginPolling()
        } catch {
            guard generations[id] == generation else { return }
            fail(id, error: error)
        }
        workChanged()
    }
    func pause(_ id: UUID) {
        guard let job = job(id), job.isActive || job.state == .queued else { return }
        generations[id] = UUID()
        mutate(id) { $0.state = .paused }
        self.manager.markPaused(id: id)
        let checkpoint = checkpointPause(id)
        Task { await checkpoint.value; pump(); workChanged() }
    }
    /// Used by expiration handlers. The completion waits for the native engine and atomic resume writes.
    func suspendAll() async {
        suspended = true
        let ids = jobs.filter { $0.isActive || $0.state == .queued }.map(\.id)
        for id in ids {
            generations[id] = UUID()
            mutate(id) { $0.state = .paused }
            self.manager.markPaused(id: id)
        }
        // Register every checkpoint before yielding. A newly resumed job must
        // never be paused later by the remainder of this background batch.
        let checkpoints = ids.map { checkpointPause($0) }
        for checkpoint in checkpoints { await checkpoint.value }
        persist()
    }
    @discardableResult
    private func checkpointPause(_ id: UUID) -> Task<Void, Never> {
        let previous = pauseCheckpoints[id]
        let checkpoint = Task { [weak self] in
            await previous?.value
            await self?.save(id, pause: true)
        }
        pauseCheckpoints[id] = checkpoint
        return checkpoint
    }
    private func save(_ id: UUID, pause: Bool = false) async {
        do {
            if let data = try await worker.save(id: id, pause: pause), self.job(id) != nil {
                try data.write(to: dataURL(id, "resume"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch { storageError = error.localizedDescription }
    }
    func remove(id: UUID, deleteFiles: Bool) {
        generations[id] = UUID()
        let existing = job(id)
        jobs.removeAll { $0.id == id }; snapshots[id] = nil; persist()
        engineIDs.remove(id)
        let checkpoint = pauseCheckpoints.removeValue(forKey: id)
        Task {
            // Wait for preceding add/save calls before removing native ownership.
            await checkpoint?.value
            let nativeOwned = await worker.remove(id: id, deleteFiles: deleteFiles)
            if deleteFiles && !nativeOwned, let existing { try? FileManager.default.removeItem(atPath: existing.directory) }
            try? FileManager.default.removeItem(at: dataURL(id, "torrent"))
            try? FileManager.default.removeItem(at: dataURL(id, "resume"))
            pump(); workChanged()
        }
    }
    private func fail(_ id: UUID, error: Error) {
        mutate(id) { $0.state = .failed; $0.error = error.localizedDescription }
        self.manager.markFailed(id: id, error: error)
        let checkpoint = checkpointPause(id)
        Task { await checkpoint.value; pump() }
    }
    private func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.hasWork {
                await self.poll()
                try? await Task.sleep(for: .seconds(1))
            }
            self?.pollTask = nil
        }
    }
    private func poll() async {
        let values = await worker.snapshots()
        for value in values {
            guard let job = job(value.id), job.isActive else { continue }
            snapshots[value.id] = value
            if !value.error.isEmpty { fail(value.id, error: NSError(domain: "Torrent", code: 1, userInfo: [NSLocalizedDescriptionKey: value.error])); continue }
            if job.state == .metadata, let metadata = value.metadata {
                generations[job.id] = UUID()
                mutate(job.id) {
                    $0.files = metadata.files; $0.name = metadata.name
                    $0.selected = Set(metadata.files.filter { !$0.pad }.map(\.index)); $0.state = .selection
                }
                self.manager.renameTorrent(id: job.id, name: metadata.name)
                self.manager.markPaused(id: job.id)
                await checkpointPause(job.id).value
            } else if job.state == .metadata && Date().timeIntervalSince(metadataStarted[job.id] ?? Date()) > 300 {
                fail(job.id, error: TorrentTaskError.metadataTimeout)
            } else if job.state == .downloading, !value.checking, value.total == job.selectedBytes {
                // Initial checking/priority snapshots can temporarily report zero.
                // Only replace persisted progress once the selected data is verified.
                self.manager.updateProgress(id: job.id, completed: value.completed, total: value.total)
                if value.finished && !job.selected.isEmpty && value.completed >= job.selectedBytes {
                    mutate(job.id) { $0.state = .finished }
                    await checkpointPause(job.id).value // Do not seed after completion.
                    self.manager.markFinished(id: job.id)
                }
            }
        }
        if Date().timeIntervalSince(lastSave) > 20 {
            lastSave = Date()
            for id in activeJobs.map(\.id) { await save(id) }
        }
        pump()
        workChanged()
    }
}

enum TorrentTaskError: LocalizedError {
    case invalid, duplicate, limit, persistence, metadataTimeout, oversized
    var errorDescription: String? {
        switch self {
        case .invalid: ToolText.text("download_invalid_address")
        case .duplicate: ToolText.text("torrent_duplicate")
        case .limit: ToolText.text("torrent_task_limit")
        case .persistence: ToolText.text("torrent_save_error")
        case .metadataTimeout: ToolText.text("torrent_metadata_timeout")
        case .oversized: ToolText.text("torrent_too_large")
        }
    }
}
