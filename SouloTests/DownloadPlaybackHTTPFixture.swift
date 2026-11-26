import Foundation
import Network

/// Range reads are fast; the separate full-file download is deliberately slow.
/// HLS can hold its final segment to prove playback starts before completion.
final class DownloadPlaybackHTTPFixture: @unchecked Sendable {
    struct ReceivedRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let receivedAt = ContinuousClock.now
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.download-playback.fixture")
    private let files: [String: Data]
    private let requiredCookie: String?
    private let heldPaths: Set<String>
    private let holdAfterRequestCount: [String: Int]
    private let holdRequest: @Sendable (ReceivedRequest) -> Bool
    private let initialServiceFailures: [String: Int]
    private let initialRateLimits: [String: Int]
    private let responseHeaders: [String: [String: String]]
    private let rangeResponseHeaders: @Sendable (Int) -> [String: String]
    private let redirects: [String: (host: String, path: String)]
    private let slowChunkSize: Int
    private let maximumRangeLength: Int?
    private var connections: [NWConnection] = []
    private var released = false
    private var started = false
    private var fullFileBytes = 0
    private var ranges = 0
    private var requests: [ReceivedRequest] = []
    private var completedResponses: [String] = []

    var downloadedBytes: Int { queue.sync { fullFileBytes } }
    var rangeRequests: Int { queue.sync { ranges } }
    var receivedRequests: [ReceivedRequest] { queue.sync { requests } }
    var completedResponsePaths: [String] { queue.sync { completedResponses } }

    init(files: [String: Data], heldPaths: Set<String> = [], requiredCookie: String? = nil,
         responseHeaders: [String: [String: String]] = [:],
         redirects: [String: (host: String, path: String)] = [:],
         slowChunkSize: Int = 1024, holdAfterRequestCount: [String: Int] = [:], initialServiceFailures: [String: Int] = [:],
         initialRateLimits: [String: Int] = [:],
         maximumRangeLength: Int? = nil,
         rangeResponseHeaders: @escaping @Sendable (Int) -> [String: String] = { _ in [:] },
         holdRequest: @escaping @Sendable (ReceivedRequest) -> Bool = { _ in false }) throws {
        precondition(slowChunkSize > 0)
        precondition(maximumRangeLength.map { $0 > 0 } ?? true)
        self.files = files; self.heldPaths = heldPaths; self.requiredCookie = requiredCookie
        self.holdAfterRequestCount = holdAfterRequestCount
        self.holdRequest = holdRequest
        self.initialServiceFailures = initialServiceFailures
        self.initialRateLimits = initialRateLimits
        self.responseHeaders = responseHeaders
        self.rangeResponseHeaders = rangeResponseHeaders
        self.redirects = redirects
        self.slowChunkSize = slowChunkSize
        self.maximumRangeLength = maximumRangeLength
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
            guard let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() }
                else { self.receive(connection, buffered: bytes) }
                return
            }
            let lines = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count >= 2 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let path = String(parts[1]).components(separatedBy: "?")[0]
            let bodyLength = max(0, Int(headers["content-length"] ?? "0") ?? 0)
            guard bytes.count - headerEnd.upperBound >= bodyLength else {
                if done || error != nil { connection.cancel() }
                else { self.receive(connection, buffered: bytes) }
                return
            }
            let request = ReceivedRequest(method: String(parts[0]), path: path, headers: headers,
                body: Data(bytes[headerEnd.upperBound..<(headerEnd.upperBound + bodyLength)]))
            self.requests.append(request)
            if let cookie = self.requiredCookie, headers["cookie"]?.contains(cookie) != true {
                self.sendError(connection, code: 403); return
            }
            if let delay = self.initialRateLimits[path], self.requests.lazy.filter({ $0.path == path }).count == 1 {
                self.sendError(connection, code: 429, retryAfter: delay); return
            }
            if let count = self.initialServiceFailures[path], self.requests.lazy.filter({ $0.path == path }).count <= count {
                self.sendError(connection, code: 503); return
            }
            let hold = self.heldPaths.contains(path) || self.holdRequest(request) || self.holdAfterRequestCount[path].map { threshold in
                self.requests.filter { $0.path == path }.count >= threshold
            } == true
            self.respond(connection, path: path, range: headers["range"], isHead: parts[0] == "HEAD", held: hold)
        }
    }

    private func sendError(_ connection: NWConnection, code: Int, retryAfter: Int? = nil) {
        let retry = retryAfter.map { "Retry-After: \($0)\r\n" } ?? ""
        connection.send(content: Data("HTTP/1.1 \(code) Error\r\n\(retry)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            contentContext: .finalMessage, completion: .contentProcessed { error in if error != nil { connection.cancel() } })
    }

    private func respond(_ connection: NWConnection, path: String, range: String?, isHead: Bool, held: Bool) {
        if let target = redirects[path], let port = listener.port {
            var url = URLComponents()
            url.scheme = "http"; url.host = target.host; url.port = Int(port.rawValue); url.path = target.path
            let response = "HTTP/1.1 302 Found\r\nLocation: \(url.url!.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), contentContext: .finalMessage,
                completion: .contentProcessed { error in if error != nil { connection.cancel() } })
            return
        }
        guard let file = files[path], !file.isEmpty else { sendError(connection, code: 404); return }
        if held, !released {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.connections.isEmpty else { return }
                self.respond(connection, path: path, range: range, isHead: isHead, held: held)
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
        if range != nil, let maximumRangeLength { end = start + min(maximumRangeLength, end - start + 1) - 1 }
        let body = file.subdata(in: start..<(end + 1))
        let ext = (path as NSString).pathExtension
        let defaultMIME = ext == "mp4" ? "video/mp4" : ext == "ts" ? "video/mp2t" : ext == "m3u8" ? "application/vnd.apple.mpegurl" : "text/html; charset=utf-8"
        var headers = responseHeaders[path] ?? [:]
        if range != nil { headers.merge(rangeResponseHeaders(start)) { _, new in new } }
        let mime = headers.first { $0.key.lowercased() == "content-type" }?.value ?? defaultMIME
        let declaredRange = headers.first { $0.key.lowercased() == "content-range" }?.value
        let partial = range != nil || declaredRange != nil
        var header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n"
        if partial { header += "Content-Range: \(declaredRange ?? "bytes \(start)-\(end)/\(file.count)")\r\n" }
        for (name, value) in headers where !["content-type", "content-range"].contains(name.lowercased()) {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        connection.send(content: Data(header.utf8), contentContext: isHead ? .finalMessage : .defaultMessage,
            completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            guard !isHead else { return }
            self.sendBody(connection, path: path, body: body, offset: 0, slow: ext == "mp4" && range == nil)
        })
    }

    private func sendBody(_ connection: NWConnection, path: String, body: Data, offset: Int, slow: Bool) {
        guard !connections.isEmpty else { connection.cancel(); return }
        let count = slow && !released ? (offset == 0 ? 8192 : slowChunkSize) : body.count - offset
        let end = min(offset + count, body.count)
        if slow { fullFileBytes += end - offset }
        let final = end == body.count
        connection.send(content: body.subdata(in: offset..<end), contentContext: final ? .finalMessage : .defaultMessage,
            completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            if final { self.completedResponses.append(path); return }
            self.queue.asyncAfter(deadline: .now() + (slow && !self.released ? 1 : 0)) { [weak self] in
                self?.sendBody(connection, path: path, body: body, offset: end, slow: slow)
            }
        })
    }
}
