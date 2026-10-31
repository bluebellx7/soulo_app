import CryptoKit
import Foundation
import SouloTorrent
import XCTest
@testable import Soulo

final class TorrentDownloadTests: XCTestCase {
    private func bencode(_ value: Any) -> Data {
        if let v = value as? Data { return Data("\(v.count):".utf8) + v }
        if let v = value as? String { return bencode(Data(v.utf8)) }
        if let v = value as? Int { return Data("i\(v)e".utf8) }
        if let v = value as? [Any] { return Data("l".utf8) + v.reduce(Data()) { $0 + bencode($1) } + Data("e".utf8) }
        let v = value as! [String: Any]
        return Data("d".utf8) + v.keys.sorted().reduce(Data()) { $0 + bencode($1) + bencode(v[$1]!) } + Data("e".utf8)
    }
    private func fixture() -> (data: Data, magnet: String, first: Data, second: Data) {
        let first = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let second = Data(repeating: 0x73, count: 512 * 1024)
        let payload = first + second
        var pieces = Data()
        for offset in stride(from: 0, to: payload.count, by: 16384) {
            pieces.append(contentsOf: Insecure.SHA1.hash(data: payload[offset..<min(offset+16384,payload.count)]))
        }
        let info: [String: Any] = ["name": "BTFixture", "piece length": 16384, "pieces": pieces,
            "files": [["length": first.count, "path": ["selected.bin"]], ["length": second.count, "path": ["excluded.bin"]]]]
        let hash = Insecure.SHA1.hash(data: bencode(info)).map { String(format: "%02x", $0) }.joined()
        return (bencode(["info": info]), "magnet:?xt=urn:btih:\(hash)&dn=BTFixture", first, second)
    }
    private func wait(_ seconds: TimeInterval = 30, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Timed out waiting for native transfer")
        throw URLError(.timedOut)
    }
    func testNativePeerDownloadSelectionAndResumeAcrossEngineRestart() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed"), download = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: seed.appendingPathComponent("BTFixture"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try fixture.first.write(to: seed.appendingPathComponent("BTFixture/selected.bin"))
        try fixture.second.write(to: seed.appendingPathComponent("BTFixture/excluded.bin"))
        let seeder = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        try seeder.addIdentifier("seed", data: fixture.data, magnet: nil, directory: seed.path, resumeData: nil,
                                priorities: [1,1], metadataOnly: false)
        try await wait { (seeder.snapshots().first?["finished"] as? Bool) == true && seeder.listeningPort > 0 }
        var leecher: SLTorrentEngine? = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        try leecher!.addIdentifier("download", data: fixture.data, magnet: nil, directory: download.path, resumeData: nil,
                                  priorities: [1,0], metadataOnly: false)
        leecher!.setDownloadLimit(96 * 1024, identifier: "download")
        leecher!.connectIdentifier("download", host: "127.0.0.1", port: seeder.listeningPort)
        try await wait { (leecher!.snapshots().first?["done"] as? Int64 ?? 0) > 128 * 1024 }
        let resume = try XCTUnwrap(leecher!.pauseAndSave("download"))
        XCTAssertFalse(resume.isEmpty)
        leecher!.remove("download", deleteFiles: false)
        leecher = nil
        let restored = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        try restored.addIdentifier("restored", data: nil, magnet: nil, directory: download.path, resumeData: resume,
                                   priorities: [1,0], metadataOnly: false)
        restored.connectIdentifier("restored", host: "127.0.0.1", port: seeder.listeningPort)
        try await wait { (restored.snapshots().first?["finished"] as? Bool) == true }
        XCTAssertEqual(try Data(contentsOf: download.appendingPathComponent("BTFixture/selected.bin")), fixture.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.appendingPathComponent("BTFixture/excluded.bin").path))
        _ = try restored.pauseAndSave("restored")
        restored.remove("restored", deleteFiles: false)
        seeder.remove("seed", deleteFiles: false)
    }
    func testMagnetGetsMetadataWithoutDownloadingPayloadThenUsesSelectedFile() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed"), download = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: seed.appendingPathComponent("BTFixture"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try fixture.first.write(to: seed.appendingPathComponent("BTFixture/selected.bin"))
        try fixture.second.write(to: seed.appendingPathComponent("BTFixture/excluded.bin"))
        let seeder = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        try seeder.addIdentifier("seed", data: fixture.data, magnet: nil, directory: seed.path, resumeData: nil, priorities: [1,1], metadataOnly: false)
        try await wait { seeder.snapshots().first?["finished"] as? Bool == true && seeder.listeningPort > 0 }
        let client = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        try client.addIdentifier("magnet", data: nil, magnet: fixture.magnet, directory: download.path, resumeData: nil, priorities: [], metadataOnly: true)
        client.connectIdentifier("magnet", host: "127.0.0.1", port: seeder.listeningPort)
        try await wait { client.snapshots().first?["metadata"] != nil }
        XCTAssertEqual(client.snapshots().first?["done"] as? Int64, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.appendingPathComponent("BTFixture/selected.bin").path))
        _ = try client.pauseAndSave("magnet")
        client.resume("magnet", priorities: [0,1])
        // File priorities are committed asynchronously by libtorrent's disk thread.
        // Wait until the chosen file is wanted before making a direct test-only peer connection.
        do {
            try await wait(5) { client.snapshots().first?["total"] as? Int64 == Int64(fixture.second.count) }
        } catch {
            print("Magnet selection status:", client.snapshots())
            throw error
        }
        client.connectIdentifier("magnet", host: "127.0.0.1", port: seeder.listeningPort)
        try await wait {
            let status = client.snapshots().first
            return status?["finished"] as? Bool == true && status?["total"] as? Int64 == Int64(fixture.second.count)
        }
        XCTAssertEqual(try Data(contentsOf: download.appendingPathComponent("BTFixture/excluded.bin")), fixture.second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.appendingPathComponent("BTFixture/selected.bin").path))
        client.remove("magnet", deleteFiles: false); seeder.remove("seed", deleteFiles: false)
    }
    func testRejectsInvalidOrOversizedMetadataAndMissingMagnetHash() throws {
        XCTAssertThrowsError(try SLTorrentEngine.inspectData(Data("not a torrent".utf8)))
        XCTAssertThrowsError(try SLTorrentEngine.inspectData(Data(repeating: 0, count: 8*1024*1024+1)))
        XCTAssertThrowsError(try SLTorrentEngine.inspectMagnet("magnet:?dn=no-hash"))
        let metadata = try SLTorrentEngine.inspectData(fixture().data)
        XCTAssertEqual((metadata["files"] as? [[String:Any]])?.count, 2)
    }
    @MainActor
    func testDownloadFailurePreservesTorrentPartialDataButNormalFailureCleansUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let (torrent, folder) = manager.beginDownload(suggestedFilename: "torrent", sourceURL: nil, transport: .torrent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: folder.appendingPathComponent("partial"))
        manager.markFailed(id: torrent.id, error: URLError(.networkConnectionLost))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("partial").path))
        let (normal, file) = manager.beginDownload(suggestedFilename: "normal", sourceURL: nil, transport: .background)
        try Data([1]).write(to: file)
        manager.markFailed(id: normal.id, error: URLError(.networkConnectionLost))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
