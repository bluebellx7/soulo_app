import Foundation
import SouloTorrent

struct TorrentFileEntry: Codable, Identifiable, Equatable, Sendable {
    let index: Int
    let path: String
    let size: Int64
    let pad: Bool
    var id: Int { index }
}
struct TorrentMetadata: Sendable {
    let name: String
    let hash: String
    let files: [TorrentFileEntry]
    init(_ value: [String: Any]) {
        name = value["name"] as? String ?? "Torrent"
        hash = value["hash"] as? String ?? ""
        files = (value["files"] as? [[String: Any]] ?? []).compactMap {
            guard let index = $0["index"] as? Int, let path = $0["path"] as? String,
                  let size = $0["size"] as? Int64 else { return nil }
            return TorrentFileEntry(index: index, path: path, size: size, pad: $0["pad"] as? Bool ?? false)
        }
    }
}
struct TorrentSnapshot: Sendable {
    let id: UUID
    let completed: Int64
    let total: Int64
    let speed: Int64
    let peers: Int
    let finished: Bool
    let checking: Bool
    let error: String
    let metadata: TorrentMetadata?
    let fileProgress: [Int64]
    init?(_ d: [String: Any]) {
        guard let id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        self.id = id
        completed = d["done"] as? Int64 ?? 0
        total = d["total"] as? Int64 ?? 0
        speed = d["speed"] as? Int64 ?? 0
        peers = d["peers"] as? Int ?? 0
        finished = d["finished"] as? Bool ?? false
        checking = d["checking"] as? Bool ?? false
        error = d["error"] as? String ?? ""
        metadata = (d["metadata"] as? [String: Any]).map(TorrentMetadata.init)
        fileProgress = d["fileProgress"] as? [Int64] ?? []
    }
}

protocol TorrentEngine: Sendable {
    func inspect(data: Data) async throws -> TorrentMetadata
    func inspect(magnet: String) async throws -> TorrentMetadata
    func add(id: UUID, data: Data?, magnet: String?, directory: URL, resume: Data?, priorities: [Bool], metadataOnly: Bool) async throws
    func snapshots() async -> [TorrentSnapshot]
    func save(id: UUID, pause: Bool) async throws -> Data?
    func resumeMetadata(id: UUID) async
    func resume(id: UUID, priorities: [Bool]) async
    func remove(id: UUID, deleteFiles: Bool) async -> Bool
    func streamData(id: UUID, file: Int, offset: Int64, length: Int) async throws -> Data?
    func endStreaming(id: UUID) async
}

extension TorrentEngine {
    func streamData(id: UUID, file: Int, offset: Int64, length: Int) async throws -> Data? {
        throw TorrentTaskError.invalid
    }
    func endStreaming(id: UUID) async {}
}

/// Owns all C++ calls on one worker queue, including synchronous resume-data creation.
final class TorrentEngineWorker: TorrentEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dkluge.Soulo.torrent-engine", qos: .utility)
    private var engine: SLTorrentEngine?
    private func instance() -> SLTorrentEngine {
        if let engine { return engine }
        let value = SLTorrentEngine(certificateFile: Bundle.main.path(forResource: "torrent-ca", ofType: "pem") ?? "", discoveryEnabled: true)
        engine = value
        return value
    }
    private func perform<T>(_ work: @escaping (SLTorrentEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try work(instance())) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func inspect(data: Data) async throws -> TorrentMetadata {
        // Inspection needs no session or network traffic.
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: TorrentMetadata(try SLTorrentEngine.inspectData(data))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func inspect(magnet: String) async throws -> TorrentMetadata {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: TorrentMetadata(try SLTorrentEngine.inspectMagnet(magnet))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func add(id: UUID, data: Data?, magnet: String?, directory: URL, resume: Data?, priorities: [Bool], metadataOnly: Bool) async throws {
        try await perform {
            try $0.addIdentifier(id.uuidString, data: data, magnet: magnet, directory: directory.path,
                                 resumeData: resume, priorities: priorities.map(NSNumber.init(value:)), metadataOnly: metadataOnly)
        }
    }
    func snapshots() async -> [TorrentSnapshot] {
        (try? await perform { $0.snapshots().compactMap(TorrentSnapshot.init) }) ?? []
    }
    func save(id: UUID, pause: Bool = false) async throws -> Data? {
        try await perform { engine in
            if pause { return try engine.pauseAndSave(id.uuidString) }
            return try engine.save(id.uuidString)
        }
    }
    func resumeMetadata(id: UUID) async {
        _ = try? await perform { $0.resumeMetadata(id.uuidString) }
    }
    func resume(id: UUID, priorities: [Bool]) async {
        _ = try? await perform { $0.resume(id.uuidString, priorities: priorities.map(NSNumber.init(value:))) }
    }
    func remove(id: UUID, deleteFiles: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                // Removing an unstarted import must not start DHT or open sockets.
                continuation.resume(returning: engine?.remove(id.uuidString, deleteFiles: deleteFiles) ?? false)
            }
        }
    }
    func streamData(id: UUID, file: Int, offset: Int64, length: Int) async throws -> Data? {
        let data = try await perform { try $0.availableData(id: id.uuidString, file: file, offset: offset, length: length) }
        return data.isEmpty ? nil : data
    }
    func endStreaming(id: UUID) async {
        _ = try? await perform { $0.endStreaming(id: id.uuidString) }
    }
}
