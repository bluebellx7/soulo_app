import Foundation
import Network
import CryptoKit

struct TransferHTTPHead {
    let method: String
    let target: String
    let headers: [String: String]
    let length: Int
    static func parse(_ data: Data) throws -> TransferHTTPHead {
        guard data.count <= 16384, let text = String(data: data, encoding: .utf8) else { throw ReadingToolError.invalid }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST", "PUT"].contains(String(first[0])), first[1].hasPrefix("/") else { throw ReadingToolError.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw ReadingToolError.invalid }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw ReadingToolError.invalid }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw ReadingToolError.invalid }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length >= 0, length <= Int(ArchiveService.maximumFileSize), headers["content-length"] == nil || Int(headers["content-length"]!) != nil else { throw ReadingToolError.limit }
        if first[0] != "GET", headers["content-length"] == nil { throw ReadingToolError.invalid }
        return TransferHTTPHead(method: String(first[0]), target: String(first[1]), headers: headers, length: length)
    }
}

struct WiFiTransferEvent: Identifiable, Sendable {
    enum Direction: Sendable { case received, sent }
    let id = UUID()
    let name: String
    let size: Int64
    let direction: Direction
    let kind: FilePresentation.Kind
}

/// All network and file state is confined to queue. No document directory is exposed implicitly.
final class WiFiTransferServer: @unchecked Sendable {
    let directory: URL
    let code: String
    let requiresPairing: Bool
    private let sessionToken = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "soulo.wifi.transfer", qos: .utility)
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private var connections: [UUID: Client] = [:]
    private var expiry: DispatchWorkItem?
    private var attempts = 0
    private var active = false
    var onState: (@Sendable (UInt16?, String?) -> Void)?
    var onTransfer: (@Sendable (WiFiTransferEvent) -> Void)?
    init(directory: URL, code: String = String(format: "%06d", Int.random(in: 0...999999)), requiresPairing: Bool = true) {
        self.directory = directory; self.code = code; self.requiresPairing = requiresPairing
    }
    func start(wifiOnly: Bool = true) throws {
        let params = NWParameters.tcp
        if wifiOnly { params.requiredInterfaceType = .wifi }
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.active = true; self.onState?(listener?.port?.rawValue, nil)
                let expiry = DispatchWorkItem { [weak self] in self?.shutdown(reason: ToolText.text("transfer_expired")) }
                self.expiry = expiry; self.queue.asyncAfter(deadline: .now() + 900, execute: expiry)
            case .failed(let error): self.shutdown(reason: error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.active, self.connections.count < 8 else { connection.cancel(); return }
            let client = Client(connection, server: self)
            self.connections[client.id] = client; client.start()
        }
        listener.start(queue: queue)
        if wifiOnly {
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            var previous: String?
            monitor.pathUpdateHandler = { [weak self] path in
                let signature = "\(path.status)-\(Self.address() ?? "")"
                if let previous, previous != signature { self?.shutdown(reason: ToolText.text("network_changed")) }
                previous = signature
            }
            self.monitor = monitor; monitor.start(queue: queue)
        }
    }
    func stop() { queue.async { self.shutdown(reason: nil) } }
    private func shutdown(reason: String?) {
        active = false; expiry?.cancel(); expiry = nil; monitor?.cancel(); monitor = nil
        listener?.cancel(); listener = nil
        for client in Array(connections.values) { client.close() }
        connections.removeAll(); onState?(nil, reason)
    }
    static func address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return nil }
        defer { freeifaddrs(pointer) }
        var current = pointer
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
    private func acceptsHost(_ head: TransferHTTPHead) -> Bool {
        guard let host = head.headers["host"], let parts = URLComponents(string: "http://" + host),
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil,
              parts.port == listener?.port.map({ Int($0.rawValue) }), let name = parts.host else { return false }
        // The address shown on the phone is numeric. Reject rebinding through an
        // unrelated hostname, including when the user permits pairing without a code.
        return ["127.0.0.1", "localhost", "[::1]", "::1", Self.address()].compactMap { $0 }.contains(name)
    }
    private func authorized(_ head: TransferHTTPHead) -> Bool {
        head.headers["cookie"]?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.contains("soulo=" + sessionToken) == true
    }
    private func targetURL(_ head: TransferHTTPHead) throws -> URL {
        guard let components = URLComponents(string: "http://localhost" + head.target), let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
              !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix("."), !name.contains("\\"), !name.contains("\0") else { throw ReadingToolError.unsafePath }
        _ = try FileSafety.relativePath(name)
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile != true { throw ReadingToolError.unsafePath }
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw ReadingToolError.unsafePath }
        return url
    }
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        unowned let server: WiFiTransferServer
        var buffer = Data(), body = Data()
        var head: TransferHTTPHead?
        var received = 0
        var temporary: URL?
        var output: FileHandle?
        var timeout: DispatchWorkItem?
        var finished = false
        init(_ connection: NWConnection, server: WiFiTransferServer) { self.connection = connection; self.server = server }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
                if case .cancelled = state { self?.close() }
            }
            connection.start(queue: server.queue); receive()
        }
        func receive() {
            guard !finished else { return }
            timeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.close() }; self.timeout = timeout
            server.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self, !self.finished else { return }
                do {
                    if let data { try self.consume(data) }
                    if !self.finished {
                        if complete || error != nil { self.close() } else { self.receive() }
                    }
                } catch { self.respond(400, Data(error.localizedDescription.utf8)) }
            }
        }
        func consume(_ data: Data) throws {
            if head == nil {
                buffer.append(data)
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= 16384 else { throw ReadingToolError.limit }; return
                }
                let parsed = try TransferHTTPHead.parse(buffer[..<range.lowerBound])
                head = parsed
                let remaining = Data(buffer[range.upperBound...]); buffer.removeAll()
                let path = parsed.target.components(separatedBy: "?")[0]
                guard server.acceptsHost(parsed) else { respond(403); return }
                if let origin = parsed.headers["origin"], origin != "http://" + (parsed.headers["host"] ?? "") { respond(403); return }
                if path != "/" && path != "/pair" && path != "/session" && !server.authorized(parsed) { respond(401); return }
                if path == "/pair", parsed.length > 1024 { throw ReadingToolError.limit }
                if parsed.method == "PUT", path == "/file" {
                    let target = try server.targetURL(parsed)
                    guard !FileManager.default.fileExists(atPath: target.path) else { respond(409); return }
                    let temporary = server.directory.appendingPathComponent(".upload-" + UUID().uuidString)
                    FileManager.default.createFile(atPath: temporary.path, contents: nil)
                    self.temporary = temporary; output = try FileHandle(forWritingTo: temporary)
                } else if parsed.length > 1024 { throw ReadingToolError.limit }
                try consumeBody(remaining)
            } else { try consumeBody(data) }
        }
        func consumeBody(_ data: Data) throws {
            guard let head else { return }
            guard received + data.count <= head.length else { throw ReadingToolError.invalid }
            if let output { try output.write(contentsOf: data) } else { body.append(data) }
            received += data.count
            if received == head.length { try route(head) }
        }
        func route(_ head: TransferHTTPHead) throws {
            let path = head.target.components(separatedBy: "?")[0]
            switch (head.method, path) {
            case ("GET", "/"):
                guard let url = Bundle.main.url(forResource: "SouloWiFiTransfer", withExtension: "html") else { throw ReadingToolError.invalid }
                respond(200, try Data(contentsOf: url), type: "text/html; charset=utf-8")
            case ("GET", "/session"):
                respond(200, try JSONSerialization.data(withJSONObject: ["requiresPairing": server.requiresPairing]))
            case ("POST", "/pair"):
                if server.requiresPairing {
                    guard server.attempts < 10 else { respond(429); return }
                    guard String(data: body, encoding: .utf8) == server.code else {
                        server.attempts += 1; respond(403); return
                    }
                }
                respond(200, Data("{}".utf8), extra: "Set-Cookie: soulo=\(server.sessionToken); HttpOnly; SameSite=Strict; Path=/; Max-Age=900\r\n")
            case ("GET", "/files"):
                let urls = try FileManager.default.contentsOfDirectory(at: server.directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: .skipsHiddenFiles)
                let files: [[String: Any]] = try urls.compactMap { url in
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
                    let presentation = FilePresentation.inspect(url)
                    return ["name": url.lastPathComponent, "size": info.fileSize ?? 0, "kind": presentation.kind.rawValue, "extension": presentation.fileExtension]
                }
                respond(200, try JSONSerialization.data(withJSONObject: files))
            case ("PUT", "/file"):
                guard let temporary else { throw ReadingToolError.invalid }
                try output?.close(); output = nil
                let target = try server.targetURL(head)
                guard !FileManager.default.fileExists(atPath: target.path) else { respond(409); return }
                try FileManager.default.moveItem(at: temporary, to: target)
                self.temporary = nil
                let info = FilePresentation.inspect(target)
                server.onTransfer?(WiFiTransferEvent(name: target.lastPathComponent, size: info.size, direction: .received, kind: info.kind))
                respond(201, Data("{}".utf8))
            case ("GET", "/file"):
                let file = try server.targetURL(head)
                let handle = try FileHandle(forReadingFrom: file)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let event = WiFiTransferEvent(name: file.lastPathComponent, size: Int64(size), direction: .sent, kind: FilePresentation.inspect(file).kind)
                finished = true; timeout?.cancel()
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\nContent-Disposition: attachment\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                    if error != nil { try? handle.close(); self?.close() } else { self?.sendFile(handle, event: event) }
                })
            default: respond(404)
            }
        }
        func sendFile(_ handle: FileHandle, event: WiFiTransferEvent) {
            do {
                guard let data = try handle.read(upToCount: 65536), !data.isEmpty else { try handle.close(); server.onTransfer?(event); close(); return }
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { try? handle.close(); self?.close() } else { self?.sendFile(handle, event: event) }
                })
            } catch { try? handle.close(); close() }
        }
        func respond(_ status: Int, _ data: Data = Data(), type: String = "application/json", extra: String = "") {
            guard !finished else { return }
            finished = true; timeout?.cancel()
            let header = "HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\nContent-Length: \(data.count)\r\nContent-Type: \(type)\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
            connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in self?.close() })
        }
        func close() {
            finished = true; timeout?.cancel(); connection.cancel(); try? output?.close(); output = nil
            if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil
            server.connections.removeValue(forKey: id)
        }
    }
}
