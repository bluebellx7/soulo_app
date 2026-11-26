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
    let knownPeers: Int
    let seeders: Int
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
        knownPeers = max(peers, d["knownPeers"] as? Int ?? 0)
        seeders = d["seeders"] as? Int ?? 0
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
    private static let maximumDHTStateBytes = 256 * 1024
    private let queue = DispatchQueue(label: "com.dkluge.Soulo.torrent-engine", qos: .utility)
    private let discoveryEnabled: Bool
    private let dhtStateURL: URL
    private var engine: SLTorrentEngine?
    private var lastDHTCheckpoint: ContinuousClock.Instant?

    init(discoveryEnabled: Bool = true, dhtStateURL: URL? = nil) {
        self.discoveryEnabled = discoveryEnabled
        self.dhtStateURL = dhtStateURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouloTorrentDHT.dat")
    }

    private func instance() -> SLTorrentEngine {
        if let engine { return engine }
        let dhtState: Data?
        if discoveryEnabled, let size = try? dhtStateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           (1...Self.maximumDHTStateBytes).contains(size) {
            dhtState = try? Data(contentsOf: dhtStateURL)
        } else {
            dhtState = nil
        }
        let value = SLTorrentEngine(certificateFile: Bundle.main.path(forResource: "torrent-ca", ofType: "pem") ?? "",
                                    discoveryEnabled: discoveryEnabled, dhtState: dhtState)
        engine = value
        if discoveryEnabled {
            let trackers = PublicTorrentTrackerStore.cachedTrackers()
            value.updatePublicTrackers(PublicTorrentTrackerStore.discoveryTrackers(trackers))
        }
        return value
    }

    private func checkpointDHT(_ engine: SLTorrentEngine, minimumInterval: Duration) {
        let now = ContinuousClock.now
        guard discoveryEnabled, lastDHTCheckpoint.map({ $0.duration(to: now) >= minimumInterval }) ?? true else { return }
        lastDHTCheckpoint = now
        guard let data = engine.dhtState(), data.count <= Self.maximumDHTStateBytes else { return }
        try? data.write(to: dhtStateURL, options: .atomic)
    }

    private func refreshPublicTrackers() {
        guard discoveryEnabled else { return }
        Task { [weak self] in
            let store = PublicTorrentTrackerStore.shared
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
        guard case .magnet(let url) = try PeerDownloadLink.parse(magnet) else { throw TorrentTaskError.invalid }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: TorrentMetadata(try SLTorrentEngine.inspectMagnet(url.absoluteString))) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func add(id: UUID, data: Data?, magnet: String?, directory: URL, resume: Data?, priorities: [Bool], metadataOnly: Bool) async throws {
        let magnetURL: URL?
        if let magnet {
            guard case .magnet(let url) = try PeerDownloadLink.parse(magnet) else { throw TorrentTaskError.invalid }
            magnetURL = url
        } else {
            magnetURL = nil
        }
        try await perform { engine in
            try engine.addIdentifier(id.uuidString, data: data, magnet: magnetURL?.absoluteString, directory: directory.path,
                                 resumeData: resume, priorities: priorities.map(NSNumber.init(value:)), metadataOnly: metadataOnly)
        }
        refreshPublicTrackers()
    }
    func snapshots() async -> [TorrentSnapshot] {
        (try? await perform { engine in
            let snapshots = engine.snapshots().compactMap(TorrentSnapshot.init)
            if !snapshots.isEmpty { self.checkpointDHT(engine, minimumInterval: .seconds(60)) }
            return snapshots
        }) ?? []
    }
    func save(id: UUID, pause: Bool = false) async throws -> Data? {
        try await perform { engine in
            if pause {
                let resume = try engine.pauseAndSave(id.uuidString)
                self.checkpointDHT(engine, minimumInterval: .seconds(5))
                return resume
            }
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
    private static let webFallback = ["http://tracker.opentrackr.org:1337/announce",
        "https://tr.nyacat.pw/announce", "https://tracker.7471.top/announce"]
    private static let sources = [
        ["https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
         "https://ngosang.github.io/trackerslist/trackers_best.txt"],
        ["https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt",
         "https://trackerslist.com/best.txt"]
    ]
    private struct Cache: Codable, Equatable, Sendable { let updatedAt: Date; let trackers: [String] }
    typealias Fetch = @Sendable (URL) async throws -> Data
    static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouloTorrentTrackers.json")
    }

    nonisolated static func discoveryTrackers(_ trackers: [String]) -> [String] {
        // Keep HTTP and HTTPS discovery available when a UDP announce times out.
        Array(trackers.lazy.filter { !webFallback.contains($0) }.prefix(24 - webFallback.count)) + webFallback
    }
    private let cacheURL: URL
    private let fetch: Fetch
    private var cache: [String: Cache]?
    private var attemptedAt: [String: Date] = [:]
    private var pending: Task<[String: Cache], Never>?

    init(cacheURL: URL? = nil, fetch: @escaping Fetch = PublicTorrentTrackerStore.download) {
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
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

    private static func readCache(at url: URL) -> [String: Cache] {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...(128 * 1024)).contains(size),
              let data = try? Data(contentsOf: url), data.count <= 128 * 1024 else { return [:] }
        let decoder = JSONDecoder()
        let saved = (try? decoder.decode([String: Cache].self, from: data))
            ?? (try? decoder.decode(Cache.self, from: data)).map { [sources[0][0]: $0] } ?? [:]
        var valid: [String: Cache] = [:]
        for source in sources {
            let key = source[0]
            guard let entry = saved[key] else { continue }
            let trackers = parse(Data(entry.trackers.joined(separator: "\n").utf8))
            if trackers.count >= 2 { valid[key] = Cache(updatedAt: entry.updatedAt, trackers: trackers) }
        }
        return valid
    }

    private static func trackers(in cache: [String: Cache]) -> [String] {
        let lists = sources.compactMap { cache[$0[0]]?.trackers }
        guard !lists.isEmpty else { return fallback }
        var seen = Set<String>()
        var merged: [String] = []
        // Give each subscription a chance to contribute before reaching the cap.
        for index in 0..<24 {
            for list in lists where list.indices.contains(index) {
                let tracker = list[index]
                if seen.insert(tracker).inserted { merged.append(tracker) }
                if merged.count == 24 { return merged }
            }
        }
        return merged
    }

    static func cachedTrackers() -> [String] {
        trackers(in: readCache(at: defaultCacheURL))
    }

    func current() -> [String] {
        if let cache { return Self.trackers(in: cache) }
        let restored = Self.readCache(at: cacheURL)
        cache = restored
        return Self.trackers(in: restored)
    }

    func refreshIfNeeded(now: Date = Date()) async -> [String] {
        if let pending { return Self.trackers(in: await pending.value) }
        let previous = cache ?? Self.readCache(at: cacheURL)
        cache = previous
        let stale = Self.sources.filter { source in
            let key = source[0]
            let age = previous[key].map { now.timeIntervalSince($0.updatedAt) }
            let sinceAttempt = attemptedAt[key].map { now.timeIntervalSince($0) }
            return !(age.map { (0..<86400).contains($0) } ?? false)
                && !(sinceAttempt.map { (0..<3600).contains($0) } ?? false)
        }
        guard !stale.isEmpty else { return Self.trackers(in: previous) }
        for source in stale { attemptedAt[source[0]] = now }
        let fetch = self.fetch
        let work = Task {
            await withTaskGroup(of: (String, Cache)?.self, returning: [String: Cache].self) { group in
                for source in stale {
                    group.addTask {
                        for address in source {
                            guard !Task.isCancelled else { break }
                            guard let url = URL(string: address), let data = try? await fetch(url) else { continue }
                            let trackers = Self.parse(data)
                            if trackers.count >= 2 { return (source[0], Cache(updatedAt: now, trackers: trackers)) }
                        }
                        return nil
                    }
                }
                var updated = previous
                for await result in group {
                    if let (key, entry) = result { updated[key] = entry }
                }
                return updated
            }
        }
        pending = work
        let updated = await work.value
        cache = updated
        if updated != previous {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(updated) { try? data.write(to: cacheURL, options: .atomic) }
        }
        pending = nil
        return Self.trackers(in: updated)
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
