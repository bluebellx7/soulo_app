import Combine
import Foundation
import SouloED2K

private struct ED2KEngineResponse: Decodable {
    var error: String?
    var items: [ED2KSnapshot]?
}
struct ED2KSnapshot: Decodable {
    let id: UUID
    let done: Int64
    let total: Int64
    let speed: Int64
    let peers: Int
    let state: String
    let error: String
}
private struct ED2KEngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private final class ED2KEngineWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dkluge.Soulo.ed2k", qos: .utility)
    func call(_ request: [String: Any]) async throws -> [ED2KSnapshot] {
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = json.withCString { SouloED2KCommand($0) }
                    guard let result else { throw ED2KEngineError(message: ToolText.text("load_error")) }
                    defer { SouloED2KFree(result) }
                    let response = try JSONDecoder().decode(ED2KEngineResponse.self, from: Data(String(cString: result).utf8))
                    if let error = response.error, !error.isEmpty { throw ED2KEngineError(message: error) }
                    continuation.resume(returning: response.items ?? [])
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Network and disk work live on a separate worker. Constructing this service
/// restores the ledger only; it never starts the eD2K network while browsing.
@MainActor
final class ED2KDownloadService: ObservableObject {
    static let shared = ED2KDownloadService()
    @Published private(set) var snapshots: [UUID: ED2KSnapshot] = [:]
    private let worker = ED2KEngineWorker()
    private let manager = DownloadManagerService.shared
    private let root: URL
    private var active = Set<UUID>()
    private var generations: [UUID: UUID] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var pollTask: Task<Void, Never>?
    private var pendingCheckpoints = 0
    var hasWork: Bool { !active.isEmpty || pendingCheckpoints > 0 }

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ED2KTasks", isDirectory: true)
        for item in manager.downloads where item.transport == .ed2k && item.status == .inProgress {
            manager.markPaused(id: item.id)
        }
    }
    private func resumeURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }

    @discardableResult
    func create(_ link: ED2KFileLink) async throws -> UUID {
        if let existing = manager.downloads.first(where: { item in
            guard item.transport == .ed2k, let parsed = try? PeerDownloadLink.parse(item.sourceURLString), case .ed2k(let old) = parsed else { return false }
            return old.hash == link.hash
        }) {
            if existing.status != .finished { try await start(existing.id) }
            return existing.id
        }
        let (item, _) = manager.beginDownload(suggestedFilename: link.name, sourceURL: link.url, transport: .ed2k)
        manager.updateProgress(id: item.id, completed: 0, total: link.size)
        do { try await start(item.id) }
        catch { manager.markFailed(id: item.id, error: error); throw error }
        return item.id
    }

    private func start(_ id: UUID) async throws {
        guard !active.contains(id), let item = manager.downloads.first(where: { $0.id == id && $0.transport == .ed2k }),
              item.status != .finished else { return }
        guard active.count < 3 else { throw TorrentTaskError.limit }
        guard case .ed2k(let link) = try PeerDownloadLink.parse(item.sourceURLString) else { throw TorrentTaskError.invalid }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let generation = UUID(); generations[id] = generation
        active.insert(id); manager.markResumed(id: id)
        await operations[id]?.value
        guard generations[id] == generation, active.contains(id) else { return }
        do {
            _ = try await worker.call(["action": "start", "id": id.uuidString, "hash": link.hash, "size": link.size,
                "path": item.localPath, "resume": resumeURL(id).path,
                "sources": link.sources,
                "nodes": Bundle.main.url(forResource: "nodes", withExtension: "dat")?.path ?? "",
                "servers": Bundle.main.url(forResource: "server", withExtension: "met")?.path ?? ""])
            guard generations[id] == generation, active.contains(id) else { return }
            beginPolling()
            TorrentBackgroundCoordinator.shared.userStartedWork()
        } catch {
            if generations[id] == generation { active.remove(id); manager.markFailed(id: id, error: error) }
            throw error
        }
    }
    func resume(_ id: UUID) {
        Task {
            do { try await start(id) }
            catch { manager.markResumed(id: id); manager.markFailed(id: id, error: error) }
        }
    }
    func pause(_ id: UUID) {
        generations[id] = UUID(); active.remove(id)
        manager.markPaused(id: id)
        checkpoint(id, remove: false, deleteFile: nil)
    }
    func remove(_ id: UUID, deleteFiles: Bool) {
        let file = manager.downloads.first { $0.id == id }?.localURL
        generations[id] = UUID(); active.remove(id); snapshots.removeValue(forKey: id)
        checkpoint(id, remove: true, deleteFile: deleteFiles ? file : nil)
    }
    @discardableResult
    private func checkpoint(_ id: UUID, remove: Bool, deleteFile: URL?) -> Task<Void, Never> {
        let previous = operations[id]
        pendingCheckpoints += 1
        let work = Task { [self] in
            defer {
                pendingCheckpoints -= 1
                TorrentBackgroundCoordinator.shared.workChanged()
            }
            await previous?.value
            do { _ = try await worker.call(["action": remove ? "remove" : "pause", "id": id.uuidString]) }
            catch { manager.markResumed(id: id); manager.markFailed(id: id, error: error) }
            if remove {
                try? FileManager.default.removeItem(at: resumeURL(id))
                if let deleteFile { try? FileManager.default.removeItem(at: deleteFile) }
            }
        }
        operations[id] = work
        return work
    }
    func suspendAll() async {
        let ids = Array(active)
        for id in ids { pause(id) }
        let work = ids.compactMap { operations[$0] }
        for task in work { await task.value }
    }
    private func beginPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            defer { pollTask = nil }
            while !Task.isCancelled && !active.isEmpty {
                do {
                    let rows = try await worker.call(["action": "poll"])
                    for row in rows where active.contains(row.id) {
                        snapshots[row.id] = row
                        if row.state != "LOADING_RESUME_DATA" {
                            manager.updateProgress(id: row.id, completed: row.done, total: row.total)
                        }
                        if !row.error.isEmpty {
                            pause(row.id)
                            manager.markResumed(id: row.id)
                            manager.markFailed(id: row.id, error: ED2KEngineError(message: row.error))
                        } else if row.state == "FINISHED" {
                            active.remove(row.id)
                            manager.markFinished(id: row.id)
                            checkpoint(row.id, remove: true, deleteFile: nil)
                        }
                    }
                    TorrentBackgroundCoordinator.shared.workChanged()
                } catch {
                    let ids = Array(active)
                    for id in ids {
                        pause(id); manager.markResumed(id: id); manager.markFailed(id: id, error: error)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
