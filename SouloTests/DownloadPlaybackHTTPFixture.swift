import Foundation
import Network

/// Range reads are fast; the separate full-file download is deliberately slow.
/// HLS can hold its final segment to prove playback starts before completion.
final class DownloadPlaybackHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.download-playback.fixture")
    private let files: [String: Data]
    private let requiredCookie: String?
    private let heldPaths: Set<String>
    private let responseHeaders: [String: [String: String]]
    private var connections: [NWConnection] = []
    private var released = false
    private var started = false
    private var fullFileBytes = 0
    private var ranges = 0

    var downloadedBytes: Int { queue.sync { fullFileBytes } }
    var rangeRequests: Int { queue.sync { ranges } }

    init(files: [String: Data], heldPaths: Set<String> = [], requiredCookie: String? = nil,
         responseHeaders: [String: [String: String]] = [:]) throws {
        self.files = files; self.heldPaths = heldPaths; self.requiredCookie = requiredCookie
        self.responseHeaders = responseHeaders
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error): self.started = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    func releaseDownloads() { queue.async { self.released = true } }
    func stop() {
        queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffered; if let data { bytes.append(data) }
            guard bytes.count < 65536 else { connection.cancel(); return }
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() }
                else { self.receive(connection, buffered: bytes) }
                return
            }
            let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let path = String(parts[1]).components(separatedBy: "?")[0]
            if let cookie = self.requiredCookie, headers["cookie"]?.contains(cookie) != true {
                self.sendError(connection, code: 403); return
            }
            self.respond(connection, path: path, range: headers["range"], isHead: parts[0] == "HEAD")
        }
    }

    private func sendError(_ connection: NWConnection, code: Int) {
        connection.send(content: Data("HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    private func respond(_ connection: NWConnection, path: String, range: String?, isHead: Bool) {
        guard let file = files[path], !file.isEmpty else { sendError(connection, code: 404); return }
        if heldPaths.contains(path), !released {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.connections.isEmpty else { return }
                self.respond(connection, path: path, range: range, isHead: isHead)
            }
            return
        }
        var start = 0, end = file.count - 1
        if let range, range.hasPrefix("bytes=") {
            ranges += 1
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2 else { sendError(connection, code: 416); return }
            if bounds[0].isEmpty { start = max(0, file.count - (Int(bounds[1]) ?? file.count)) }
            else { start = Int(bounds[0]) ?? 0; end = min(end, Int(bounds[1]) ?? end) }
        }
        guard start >= 0, end >= start, start < file.count else { sendError(connection, code: 416); return }
        let body = file.subdata(in: start..<(end + 1))
        let ext = (path as NSString).pathExtension
        let mime = ext == "mp4" ? "video/mp4" : ext == "ts" ? "video/mp2t" : ext == "m3u8" ? "application/vnd.apple.mpegurl" : "text/html; charset=utf-8"
        var header = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if range != nil { header += "Content-Range: bytes \(start)-\(end)/\(file.count)\r\n" }
        for (name, value) in responseHeaders[path] ?? [:] { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !isHead else { connection.cancel(); return }
            self.sendBody(connection, body: body, offset: 0, slow: ext == "mp4" && range == nil)
        })
    }

    private func sendBody(_ connection: NWConnection, body: Data, offset: Int, slow: Bool) {
        guard !connections.isEmpty else { connection.cancel(); return }
        let count = slow && !released ? (offset == 0 ? 8192 : 1024) : body.count - offset
        let end = min(offset + count, body.count)
        if slow { fullFileBytes += end - offset }
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, end < body.count else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + (slow && !self.released ? 1 : 0)) { [weak self] in
                self?.sendBody(connection, body: body, offset: end, slow: slow)
            }
        })
    }
}
