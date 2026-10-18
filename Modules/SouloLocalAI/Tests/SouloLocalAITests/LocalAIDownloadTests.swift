import XCTest
import Network
import CryptoKit
@testable import SouloLocalAI

private final class ModelHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.localAI.download-fixture")
    private let bytes: Data
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var ranges = 0
    var rangeRequests: Int { lock.lock(); defer { lock.unlock() }; return ranges }
    init(bytes: Data) throws { self.bytes = bytes; listener = try NWListener(using: .tcp, on: .any) }
    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection); connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
                var offset = 0
                if let range = request.lowercased().range(of: "range: bytes="),
                   let number = request[range.upperBound...].split(separator: "-").first, let start = Int(number) {
                    offset = start; self.lock.lock(); self.ranges += 1; self.lock.unlock()
                }
                let partial = offset > 0
                let response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Length: \(self.bytes.count - offset)\r\nAccept-Ranges: bytes\r\nETag: \"soulo-fixture-v1\"\r\nLast-Modified: Fri, 16 Oct 2026 00:00:00 GMT\r\n" +
                    (partial ? "Content-Range: bytes \(offset)-\(self.bytes.count - 1)/\(self.bytes.count)\r\n" : "") + "Connection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
                    if error == nil { self.send(connection, offset: offset) }
                })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { throw URLError(.cannotConnectToHost) }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/model.gguf")!
    }
    private func send(_ connection: NWConnection, offset: Int) {
        guard offset < bytes.count else { connection.cancel(); return }
        let next = min(offset + 65_536, bytes.count)
        connection.send(content: bytes.subdata(in: offset..<next), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + 0.02) { self.send(connection, offset: next) }
        })
    }
    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}

@MainActor final class LocalAIDownloadTests: XCTestCase {
    func testMeteredDownloadWaitsForAChoiceAndConsentIsPerTransfer() async throws {
        var data = Data("GGUF".utf8); data.append(Data(repeating: 17, count: 200_000))
        let server = try ModelHTTPFixture(bytes: data)
        let url = try server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = LocalAIModelAsset(id: "metered", filename: "model.gguf", bytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), url: url)
        let wifiAsset = LocalAIModelAsset(id: "wifi", filename: "wifi.gguf", bytes: asset.bytes, sha256: asset.sha256, url: url)
        let store = LocalAIModelStore(directory: directory, assets: [asset, wifiAsset], configuration: .ephemeral)
        let prompt = LocalAIDownloadPrompt(store: store, needsConfirmation: { true })
        var starts = 0
        prompt.request(asset, source: .huggingFace) { starts += 1 }
        XCTAssertNotNil(prompt.pending); XCTAssertEqual(starts, 0)
        let expiredChoice = try XCTUnwrap(prompt.pending)
        XCTAssertNil(store.activeRequest(for: asset)); XCTAssertEqual(store.statuses[asset.id], .missing)
        prompt.cancel()
        prompt.confirm(expiredChoice, allowsCellular: true)
        XCTAssertNil(prompt.pending); XCTAssertNil(store.activeRequest(for: asset)); XCTAssertEqual(starts, 0)
        prompt.request(asset, source: .huggingFace) { starts += 1 }
        prompt.confirm(allowsCellular: true)
        XCTAssertEqual(starts, 1); XCTAssertNil(prompt.pending)
        XCTAssertEqual(store.activeRequest(for: asset)?.allowsCellularAccess, true)
        XCTAssertEqual(store.activeRequest(for: asset)?.allowsExpensiveNetworkAccess, true)
        for _ in 0..<200 where store.statuses[asset.id] != .installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.statuses[asset.id], .installed)
        XCTAssertFalse(store.cellularDownloads.contains(asset.id), "Completion must clear the one-transfer permission")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(asset.id + ".network").path))
        prompt.request(wifiAsset, source: .huggingFace)
        XCTAssertNil(store.activeRequest(for: wifiAsset), "The previous model's permission must not authorize another download")
        prompt.confirm(allowsCellular: false)
        XCTAssertEqual(store.activeRequest(for: wifiAsset)?.allowsCellularAccess, false)
        XCTAssertEqual(store.activeRequest(for: wifiAsset)?.allowsExpensiveNetworkAccess, false)
        for _ in 0..<200 where store.statuses[wifiAsset.id] != .installed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.statuses[wifiAsset.id], .installed)
    }
    func testUnexpectedLargerResponseIsCancelledBeforeItCanFillStorage() async throws {
        var data = Data("GGUF".utf8); data.append(Data(repeating: 9, count: 8_000_000))
        let server = try ModelHTTPFixture(bytes: data), url = try server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = LocalAIModelAsset(id: "oversized", filename: "model.gguf", bytes: 100_000, sha256: "invalid", url: url)
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        store.download(asset)
        for _ in 0..<200 {
            if case .failed = store.statuses[asset.id] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.statuses[asset.id], .failed(LocalAIError.modelInvalid.localizedDescription))
        XCTAssertNil(store.activeRequest(for: asset)); XCTAssertNil(store.installedURL(for: asset))
        XCTAssertFalse(store.hasResumeData(for: asset))
    }
    func testActualDownloadPausesResumesAndVerifiesBeforeInstallation() async throws {
        var data = Data("GGUF".utf8); data.append(Data(repeating: 42, count: 8_000_000))
        let server = try ModelHTTPFixture(bytes: data)
        let url = try server.start(); defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = LocalAIModelAsset(id: "network", filename: "model.gguf", bytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), url: url)
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        store.download(asset)
        XCTAssertEqual(store.activeRequest(for: asset)?.allowsCellularAccess, false)
        XCTAssertEqual(store.activeRequest(for: asset)?.allowsExpensiveNetworkAccess, false)
        var received = false
        for _ in 0..<200 {
            if case .downloading(let count, _) = store.statuses[asset.id], count > 100_000 { received = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(received, "The production download delegate must report progress")
        XCTAssertNil(store.installedURL(for: asset))
        store.pause(asset)
        XCTAssertEqual(store.statuses[asset.id], .paused)
        let resume = directory.appendingPathComponent(asset.id + ".resume")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: resume.path) { try await Task.sleep(for: .milliseconds(20)) }
        let hasResumeData = FileManager.default.fileExists(atPath: resume.path)
        XCTAssertTrue(hasResumeData, "The range-capable server should produce resume data")
        store.download(asset)
        for _ in 0..<1000 {
            if store.statuses[asset.id] == .installed { break }
            if case .failed(let error) = store.statuses[asset.id] { XCTFail(error); break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.statuses[asset.id], .installed)
        let installed = try XCTUnwrap(store.installedURL(for: asset))
        XCTAssertEqual(try Data(contentsOf: installed), data)
        if hasResumeData { XCTAssertGreaterThan(server.rangeRequests, 0, "Resume should request the remaining bytes") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
    }
}
