import Foundation
import Network

enum TorrentMediaFile {
    static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "m2ts", "mts", "ogv",
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "caf", "ogg", "opus", "mka", "ape", "wma",
    ]
    static func supports(_ path: String) -> Bool { extensions.contains((path as NSString).pathExtension.lowercased()) }
    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "flv": "video/x-flv"
        case "wmv": "video/x-ms-wmv"
        case "m2ts", "mts": "video/mp2t"
        case "ogv": "video/ogg"
        case "ogg", "opus": "audio/ogg"
        case "mka": "audio/x-matroska"
        case "wma": "audio/x-ms-wma"
        case "ape": "audio/ape"
        case "mp3": "audio/mpeg"
        case "m4a", "aac": "audio/mp4"
        case "wav": "audio/wav"
        case "flac": "audio/flac"
        case "aiff": "audio/aiff"
        case "caf": "audio/x-caf"
        case "mov": "video/quicktime"
        default: "video/mp4"
        }
    }
}

/// Single byte ranges, including suffix ranges used to locate an MP4's index.
enum TorrentHTTPRange {
    static func parse(_ value: String?, size: Int64) throws -> Range<Int64> {
        guard size > 0 else { throw TorrentTaskError.invalid }
        guard let value else { return 0..<size }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw TorrentTaskError.invalid }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw TorrentTaskError.invalid }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw TorrentTaskError.invalid }
            return max(0, size - min(suffix, size))..<size
        }
        guard let first = Int64(parts[0]), first >= 0, first < size else { throw TorrentTaskError.invalid }
        if parts[1].isEmpty { return first..<size }
        guard let last = Int64(parts[1]), last >= first else { throw TorrentTaskError.invalid }
        return first..<(min(last, size - 1) + 1)
    }
}

/// A playback-scoped, loopback-only range server. Missing pieces wait for the
/// torrent engine; sparse/preallocated bytes are never sent to the player.
final class TorrentStreamServer: @unchecked Sendable {
    typealias Reader = @Sendable (Int64, Int) async throws -> Data?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dkluge.Soulo.torrent-stream", qos: .utility)
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: (NWConnection, Task<Void, Never>)] = [:]
    private var stopped = false
    private var startupCompleted = false
    private let size: Int64
    private let contentType: String
    private let reader: Reader
    private let path: String
    private var localFiles: [String: URL] = [:]
    private var resourceProvider: (@Sendable (String) async throws -> URL?)?
    private(set) var url: URL!

    private init(size: Int64, name: String, reader: @escaping Reader) throws {
        guard size > 0 else { throw TorrentTaskError.invalid }
        self.size = size; self.reader = reader
        contentType = TorrentMediaFile.contentType(name)
        var components = URLComponents()
        components.path = "/" + UUID().uuidString + "/" + (name as NSString).lastPathComponent
        path = components.percentEncodedPath
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }

    static func start(size: Int64, name: String, reader: @escaping Reader) async throws -> TorrentStreamServer {
        let server = try TorrentStreamServer(size: size, name: name, reader: reader)
        return try await server.start()
    }

    /// Serve only the files in an app-generated offline HLS bundle. AVPlayer
    /// needs HTTP HLS URLs even though every byte is already on this device.
    static func startHLS(directory: URL, playlist: String) async throws -> TorrentStreamServer {
        let entry = directory.appendingPathComponent(playlist)
        let size = try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let server = try TorrentStreamServer(size: Int64(size), name: playlist, reader: fileReader(entry))
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard files.count <= 10_002 else { throw TorrentTaskError.invalid }
        let prefix = String(server.path.prefix(through: server.path.lastIndex(of: "/")!))
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  ["m3u8", "ts", "bin", "key", "mp4", "m4s", "m4a", "cmfv", "cmfa"].contains(file.pathExtension.lowercased()) else { continue }
            var path = URLComponents(); path.path = prefix + file.lastPathComponent
            server.localFiles[path.percentEncodedPath] = file
        }
        guard server.localFiles[server.path] != nil else { throw TorrentTaskError.invalid }
        return try await server.start()
    }

    /// A playback lease can lazily materialize a bounded set of remote HLS
    /// resources. Requests stay under the random loopback-only directory.
    static func startHLSResources(provider: @escaping @Sendable (String) async throws -> URL?) async throws -> TorrentStreamServer {
        let server = try TorrentStreamServer(size: 1, name: "index.m3u8", reader: { _, _ in nil })
        server.resourceProvider = provider
        return try await server.start()
    }

    private static func fileReader(_ file: URL) -> Reader {
        { offset, count in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        }
    }

    private func start() async throws -> TorrentStreamServer {
        let server = self
        server.listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard server.finishStartup(), let port = server.listener.port else { return }
                    server.url = URL(string: "http://127.0.0.1:\(port.rawValue)\(server.path)")!
                    server.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    guard server.finishStartup() else { return }
                    server.listener.stateUpdateHandler = nil
                    server.stop(); continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    private func finishStartup() -> Bool {
        lock.withLock {
            guard !startupCompleted else { return false }
            startupCompleted = true; return true
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            guard !stopped, connections.count < 8 else { connection.cancel(); return }
            connection.start(queue: queue)
            let task = Task.detached(priority: .utility) { [self] in
                defer {
                    connection.cancel()
                    _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
                }
                do { try await serve(connection) } catch { }
            }
            connections[ObjectIdentifier(connection)] = (connection, task)
        }
    }

    func stop() {
        let active = lock.withLock {
            stopped = true
            let active = Array(connections.values); connections.removeAll(); return active
        }
        listener.cancel()
        active.forEach { $0.1.cancel(); $0.0.cancel() }
    }
    deinit { stop() }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: URLError(complete ? .networkConnectionLost : .badServerResponse)) }
            }
        }
    }
    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func reject(_ status: String, connection: NWConnection, extra: String = "") async throws {
        try await send(Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\(extra)\r\n".utf8), to: connection)
    }
    private func serve(_ connection: NWConnection) async throws {
        let headerDeadline = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { connection.cancel() }
        }
        defer { headerDeadline.cancel() }
        var header = Data()
        while header.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard header.count < 16_384 else { try await reject("431 Request Header Fields Too Large", connection: connection); return }
            header.append(try await receive(connection))
        }
        headerDeadline.cancel()
        guard let text = String(data: header, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3 else { try await reject("400 Bad Request", connection: connection); return }
        let size: Int64, contentType: String, reader: Reader
        var resourceHandle: FileHandle?
        defer { try? resourceHandle?.close() }
        let suppliedFile: URL?
        if let resourceProvider {
            let requested = String(request[1]), prefix = String(path.prefix(through: path.lastIndex(of: "/")!))
            guard requested.hasPrefix(prefix), !requested.dropFirst(prefix.count).contains("/"),
                  !requested.contains("%"), !requested.contains("?"), !requested.contains("..") else {
                try await reject("404 Not Found", connection: connection); return
            }
            suppliedFile = try await resourceProvider(String(requested.dropFirst(prefix.count)))
            guard suppliedFile != nil else { try await reject("404 Not Found", connection: connection); return }
        } else { suppliedFile = nil }
        if let file = suppliedFile ?? localFiles[String(request[1])] {
            size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            switch file.pathExtension.lowercased() {
            case "m3u8": contentType = "application/vnd.apple.mpegurl"
            case "ts": contentType = "video/mp2t"
            case "mp4", "m4s", "cmfv": contentType = "video/mp4"
            case "m4a", "cmfa": contentType = "audio/mp4"
            default: contentType = "application/octet-stream"
            }
            if suppliedFile != nil {
                let handle = try FileHandle(forReadingFrom: file); resourceHandle = handle
                reader = { offset, count in
                    try handle.seek(toOffset: UInt64(offset)); return try handle.read(upToCount: count)
                }
            } else { reader = Self.fileReader(file) }
        } else {
            guard localFiles.isEmpty, request[1] == Substring(path) else { try await reject("404 Not Found", connection: connection); return }
            size = self.size; contentType = self.contentType; reader = self.reader
        }
        guard request[0] == "GET" || request[0] == "HEAD" else { try await reject("405 Method Not Allowed", connection: connection); return }
        let rangeHeaders = lines.dropFirst().filter { $0.lowercased().hasPrefix("range:") }
        guard rangeHeaders.count < 2 else { try await reject("400 Bad Request", connection: connection); return }
        let rangeHeader = rangeHeaders.first.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let range: Range<Int64>
        do { range = try TorrentHTTPRange.parse(rangeHeader, size: size) }
        catch { try await reject("416 Range Not Satisfiable", connection: connection, extra: "Content-Range: bytes */\(size)\r\n"); return }
        let status = rangeHeader == nil ? "200 OK" : "206 Partial Content"
        let contentRange = rangeHeader == nil ? "" : "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)\r\n"
        try await send(Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\n\(contentRange)Cache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), to: connection)
        guard request[0] != "HEAD" else { return }
        var offset = range.lowerBound
        var lastProgress = ContinuousClock.now
        while offset < range.upperBound {
            try Task.checkCancellation()
            if let data = try await reader(offset, Int(min(128 * 1024, range.upperBound - offset))) {
                guard !data.isEmpty, Int64(data.count) <= range.upperBound - offset else { throw TorrentTaskError.invalid }
                try await send(data, to: connection)
                offset += Int64(data.count); lastProgress = .now
            } else {
                // Large MP4 indexes may be at the tail and span several pieces.
                // Let verified-piece acquisition buffer on slower swarms. Closing
                // playback still cancels the wait immediately through its lease.
                guard lastProgress.duration(to: .now) < .seconds(180) else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

final class TorrentPlaybackLease: @unchecked Sendable {
    let server: TorrentStreamServer
    let id: UUID
    let worker: any TorrentEngine
    private let lock = NSLock()
    private var finishTask: Task<Void, Never>?
    var url: URL { server.url }
    init(server: TorrentStreamServer, id: UUID, worker: any TorrentEngine) {
        self.server = server; self.id = id; self.worker = worker
    }
    private func cleanupTask() -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        if let finishTask { return finishTask }
        let server = server, worker = worker, id = id
        let task = Task { server.stop(); await worker.endStreaming(id: id) }
        finishTask = task
        return task
    }
    func finish() async {
        await cleanupTask().value
    }
    deinit {
        _ = cleanupTask()
    }
}
