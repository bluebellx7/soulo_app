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
    private let discoveryEnabled: Bool
    private var engine: SLTorrentEngine?

    init(discoveryEnabled: Bool = true) { self.discoveryEnabled = discoveryEnabled }

    private func instance() -> SLTorrentEngine {
        if let engine { return engine }
        let value = SLTorrentEngine(certificateFile: Bundle.main.path(forResource: "torrent-ca", ofType: "pem") ?? "",
                                    discoveryEnabled: discoveryEnabled)
        engine = value
        if discoveryEnabled { value.updatePublicTrackers(PublicTorrentTrackerStore.discoveryTrackers(PublicTorrentTrackerStore.fallback)) }
        refreshPublicTrackers()
        return value
    }
    private func refreshPublicTrackers() {
        guard discoveryEnabled else { return }
        Task { [weak self] in
            let store = PublicTorrentTrackerStore.shared
            self?.applyTrackers(await store.current())
            self?.applyTrackers(await store.refreshIfNeeded())
        }
    }
    private func applyTrackers(_ trackers: [String]) {
        let discovery = PublicTorrentTrackerStore.discoveryTrackers(trackers)
        queue.async { [weak self] in self?.engine?.updatePublicTrackers(discovery) }
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
        refreshPublicTrackers()
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

/// Small, rate-limited discovery data. Downloads never wait for this request.
/// Keep a validated last-good cache when a source is unavailable or malformed.
actor PublicTorrentTrackerStore {
    static let shared = PublicTorrentTrackerStore()
    static let fallback = ["udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce", "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.demonii.com:1337/announce"]
    private static let httpsFallback = ["https://tr.nyacat.pw/announce", "https://tracker.7471.top/announce"]
    static let sources = ["https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
        "https://ngosang.github.io/trackerslist/trackers_best.txt"].compactMap(URL.init(string:))
    struct Cache: Codable, Sendable { let updatedAt: Date; let trackers: [String] }
    typealias Fetch = @Sendable (URL) async throws -> Data

    nonisolated static func discoveryTrackers(_ trackers: [String]) -> [String] {
        // Always leave room for HTTPS discovery on networks that filter UDP.
        Array(trackers.lazy.filter { !httpsFallback.contains($0) }.prefix(24 - httpsFallback.count)) + httpsFallback
    }
    private let cacheURL: URL
    private let fetch: Fetch
    private var cache: Cache?
    private var attemptedAt: Date?
    private var pending: Task<Cache?, Never>?

    init(cacheURL: URL? = nil, fetch: @escaping Fetch = PublicTorrentTrackerStore.download) {
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouloTorrentTrackers.json")
        self.fetch = fetch
    }

    static func parse(_ data: Data) -> [String] {
        guard data.count <= 128 * 1024, let text = String(data: data, encoding: .utf8) else { return [] }
        var seen = Set<String>(), result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 512, let url = URL(string: value),
                  ["udp", "http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased(), host.contains("."), host != "localhost",
                  !host.hasSuffix(".local"), !host.hasPrefix("127."), !host.hasPrefix("10."),
                  !host.hasPrefix("192.168."), !host.hasPrefix("169.254."),
                  !(16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? -1) || !host.hasPrefix("172."),
                  url.user == nil, url.password == nil, url.fragment == nil,
                  !url.path.isEmpty, url.port.map({ (1...65535).contains($0) }) ?? true,
                  seen.insert(value).inserted else { continue }
            result.append(value)
            if result.count == 24 { break }
        }
        return result
    }

    func current() -> [String] {
        if cache == nil, let data = try? Data(contentsOf: cacheURL), data.count <= 128 * 1024,
           let saved = try? JSONDecoder().decode(Cache.self, from: data) {
            let valid = Self.parse(Data(saved.trackers.joined(separator: "\n").utf8))
            if valid.count >= 2 { cache = Cache(updatedAt: saved.updatedAt, trackers: valid) }
        }
        return cache?.trackers ?? Self.fallback
    }

    func refreshIfNeeded(now: Date = Date()) async -> [String] {
        let previous = current()
        if let pending {
            if let updated = await pending.value { cache = updated }
            return current()
        }
        if let cache, now.timeIntervalSince(cache.updatedAt) >= 0, now.timeIntervalSince(cache.updatedAt) < 86400 { return previous }
        if let attemptedAt, now.timeIntervalSince(attemptedAt) >= 0, now.timeIntervalSince(attemptedAt) < 3600 { return previous }
        attemptedAt = now
        let fetch = self.fetch
        let work = Task<Cache?, Never> {
            for source in Self.sources {
                guard !Task.isCancelled else { return nil }
                guard let data = try? await fetch(source) else { continue }
                let trackers = Self.parse(data)
                if trackers.count >= 2 { return Cache(updatedAt: now, trackers: trackers) }
            }
            return nil
        }
        pending = work
        let updated = await work.value
        if let updated {
            cache = updated
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(updated) { try? data.write(to: cacheURL, options: .atomic) }
        }
        pending = nil
        return current()
    }

    private static func download(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 128 * 1024 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in stream {
            guard data.count < 128 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}
