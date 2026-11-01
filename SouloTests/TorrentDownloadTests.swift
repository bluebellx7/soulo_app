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
    @MainActor
    func testResumeCheckingKeepsSavedProgressUntilVerifiedSnapshotArrives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root.appendingPathComponent("Downloads"))
        let worker = ControlledTorrentEngine()
        let service = TorrentDownloadService(manager: manager, root: root.appendingPathComponent("Tasks"), worker: worker, workChanged: {}, userStartedWork: {})
        let id = try await service.create(data: Data([1]), magnet: nil)
        service.start(id)
        try await wait { manager.downloads.first?.receivedBytes == 500 }
        await service.suspendAll()
        await worker.setChecking(true)
        service.start(id)
        try await wait { service.snapshots[id]?.checking == true }
        XCTAssertEqual(manager.downloads.first?.receivedBytes, 500)
        XCTAssertEqual(manager.downloads.first?.progress, 0.5)
        await worker.setChecking(false, completed: 750)
        try await wait { manager.downloads.first?.receivedBytes == 750 }
        await service.suspendAll()
    }

    @MainActor
    func testResumeWaitsForBackgroundPauseToFinishForEveryJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root.appendingPathComponent("Downloads"))
        let worker = ControlledTorrentEngine()
        let service = TorrentDownloadService(manager: manager, root: root.appendingPathComponent("Tasks"), worker: worker, workChanged: {}, userStartedWork: {})
        let first = try await service.create(data: Data([1]), magnet: nil)
        let second = try await service.create(data: Data([2]), magnet: nil)
        service.start(first); service.start(second)
        try await wait { service.jobs.allSatisfy { $0.state == .downloading } }
        await worker.holdPauses()
        let suspension = Task { await service.suspendAll() }
        try await waitAsync { await worker.hasHeldPause }
        // The first-created job is last in the persisted queue. Its pause must
        // already be pending even while another job's checkpoint is blocked.
        service.start(first)
        try await Task.sleep(for: .milliseconds(150))
        let earlyResumes = await worker.resumeCount(first)
        XCTAssertEqual(earlyResumes, 0, "Continuing must wait for its background checkpoint")
        await worker.releasePauses()
        await suspension.value
        try await wait { service.job(first)?.state == .downloading }
        let stillPaused = await worker.isPaused(first)
        XCTAssertFalse(stillPaused, "An older checkpoint must not pause the resumed engine")
        await service.suspendAll()
    }

    @MainActor
    func testAppRestartRestoresPausedTorrentSelectionAndSavedProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = root.appendingPathComponent("Downloads"), tasks = root.appendingPathComponent("Tasks")
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: files)
        let service = TorrentDownloadService(manager: manager, root: tasks, worker: ControlledTorrentEngine(), workChanged: {}, userStartedWork: {})
        let id = try await service.create(data: Data([1]), magnet: nil)
        service.start(id)
        try await wait { manager.downloads.first?.receivedBytes == 500 }
        await service.suspendAll()
        let ledger = tasks.appendingPathComponent("tasks.json")
        var oldJobs = try JSONDecoder().decode([TorrentDownloadJob].self, from: Data(contentsOf: ledger))
        oldJobs[0].directory = "/old-container/Documents/Downloads/old-folder"
        try JSONEncoder().encode(oldJobs).write(to: ledger)
        let restoredManager = DownloadManagerService(userDefaults: defaults, storageDirectory: files)
        let worker = ControlledTorrentEngine()
        let restored = TorrentDownloadService(manager: restoredManager, root: tasks, worker: worker, workChanged: {}, userStartedWork: {})
        XCTAssertEqual(restored.job(id)?.state, .paused)
        XCTAssertEqual(restored.job(id)?.selected, [0])
        XCTAssertEqual(restored.job(id)?.directory, restoredManager.downloads.first?.localPath)
        XCTAssertEqual(restoredManager.downloads.first?.progress, 0.5)
        await worker.setChecking(false, completed: 750)
        restored.start(id)
        try await wait { restoredManager.downloads.first?.receivedBytes == 750 }
        await restored.suspendAll()
    }

    private func waitAsync(until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the controlled engine")
        throw URLError(.timedOut)
    }

    func testNativePauseAndResumeReconnectsWithoutReplacingHandleOrResettingFiles() async throws {
        let fixture = fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed"), download = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: seed.appendingPathComponent("BTFixture"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try fixture.first.write(to: seed.appendingPathComponent("BTFixture/selected.bin"))
        try fixture.second.write(to: seed.appendingPathComponent("BTFixture/excluded.bin"))
        let seeder = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        let client = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
        defer { client.remove("download", deleteFiles: false); seeder.remove("seed", deleteFiles: false) }
        try seeder.addIdentifier("seed", data: fixture.data, magnet: nil, directory: seed.path, resumeData: nil, priorities: [1,1], metadataOnly: false)
        try await wait { seeder.snapshots().first?["finished"] as? Bool == true && seeder.listeningPort > 0 }
        try client.addIdentifier("download", data: fixture.data, magnet: nil, directory: download.path, resumeData: nil, priorities: [1,0], metadataOnly: false)
        client.setDownloadLimit(128 * 1024, identifier: "download")
        client.connectIdentifier("download", host: "127.0.0.1", port: seeder.listeningPort)
        try await wait { (client.snapshots().first?["done"] as? Int64 ?? 0) > 128 * 1024 }
        _ = try XCTUnwrap(client.pauseAndSave("download"))
        let checkpoint = client.snapshots().first?["done"] as? Int64 ?? 0
        client.resume("download", priorities: [1,0])
        // No test-only connect_peer call after resuming: the engine must recover.
        try await wait { (client.snapshots().first?["done"] as? Int64 ?? 0) > checkpoint }
        try await wait { client.snapshots().first?["finished"] as? Bool == true }
        XCTAssertEqual(try Data(contentsOf: download.appendingPathComponent("BTFixture/selected.bin")), fixture.first)
    }

}

private actor ControlledTorrentEngine: TorrentEngine {
    private var ids = Set<UUID>()
    private var paused = Set<UUID>()
    private var resumes: [UUID: Int] = [:]
    private var checking = false
    private var completed: Int64 = 500
    private var holding = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    var hasHeldPause: Bool { !pending.isEmpty }
    func holdPauses() { holding = true }
    func releasePauses() { holding = false; let values = pending; pending.removeAll(); values.forEach { $0.resume() } }
    func resumeCount(_ id: UUID) -> Int { resumes[id, default: 0] }
    func isPaused(_ id: UUID) -> Bool { paused.contains(id) }
    func setChecking(_ value: Bool, completed: Int64 = 500) { checking = value; self.completed = completed }
    func inspect(data: Data) async throws -> TorrentMetadata {
        TorrentMetadata(["name": UUID().uuidString, "hash": UUID().uuidString,
            "files": [["index": 0, "path": "file.bin", "size": Int64(1000), "pad": false]]])
    }
    func inspect(magnet: String) async throws -> TorrentMetadata { try await inspect(data: Data()) }
    func add(id: UUID, data: Data?, magnet: String?, directory: URL, resume: Data?, priorities: [Bool], metadataOnly: Bool) async throws { ids.insert(id) }
    func snapshots() async -> [TorrentSnapshot] {
        ids.compactMap { TorrentSnapshot(["id": $0.uuidString, "done": checking ? Int64(0) : completed, "total": Int64(1000), "checking": checking]) }
    }
    func save(id: UUID, pause: Bool) async throws -> Data? {
        if pause {
            if holding { await withCheckedContinuation { pending.append($0) } }
            paused.insert(id)
        }
        return Data([1])
    }
    func resumeMetadata(id: UUID) async { paused.remove(id) }
    func resume(id: UUID, priorities: [Bool]) async { resumes[id, default: 0] += 1; paused.remove(id) }
    func remove(id: UUID, deleteFiles: Bool) async -> Bool { ids.remove(id) != nil }
}
