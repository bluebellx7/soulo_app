import CryptoKit
import AVFoundation
import Foundation
import SouloTorrent
import XCTest
@testable import Soulo

final class TorrentDownloadTests: XCTestCase {
    @MainActor
    func testVideoActuallyPlaysAndSeeksBeforeNativeTorrentFinishes() async throws {
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "torrent-stream-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: video)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed"), destination = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try bytes.write(to: seed.appendingPathComponent("stream.mp4"))
        var pieces = Data()
        for first in stride(from: 0, to: bytes.count, by: 16384) {
            pieces.append(contentsOf: Insecure.SHA1.hash(data: bytes[first..<min(first + 16384, bytes.count)]))
        }
        let metainfo = bencode(["info": ["name":"stream.mp4", "length":bytes.count, "piece length":16384, "pieces":pieces]])
        let peer = try StreamingTorrentTestPeer(metadata: metainfo, seed: seed, destination: destination)
        for _ in 0..<100 {
            if await peer.ready() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await peer.connect()
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "stream.mp4") { offset, count in
            try await peer.read(offset: offset, count: count)
        }
        let source = DownloadPlaybackSource(asset: AVURLAsset(url: server.url), pageURL: nil,
                                            webView: nil, persistPosition: false)
        let extended = try await TorrentFileDecoder.prefersExtended(source.asset, path: "stream.mp4")
        XCTAssertFalse(extended, "Ordinary H.264 torrent playback must keep its native player")
        source.resourceLease = TorrentPlaybackLease(server: server, id: UUID(), worker: ControlledTorrentEngine())
        let session = MediaSession(), player = session.player
        defer { session.stop(); server.stop() }
        do {
            // Exercise the shipped player's buffering and seek recovery, without
            // substituting test-only AVPlayer settings or a seek completion fix.
            session.open(url: server.url, asset: source.asset, persistPosition: false, downloadSource: source)
            for _ in 0..<200 {
                if player.currentTime().seconds > 0.6 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(player.currentTime().seconds, 0.6, player.currentItem?.error?.localizedDescription ?? "Torrent video did not start")
            guard player.currentTime().seconds > 0.6 else { throw URLError(.cannotDecodeContentData) }
            let finished = await peer.finished()
            XCTAssertFalse(finished, "This must stream an incomplete video, not wait for a completed file")
            session.seek(6)
            for _ in 0..<150 {
                if player.currentTime().seconds > 6.2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(player.currentTime().seconds, 6.2, "Seeking must request and verify missing torrent pieces")
            await peer.stop()
        } catch { await peer.stop(); throw error }
    }

    @MainActor
    func testPartialTorrentFilesUseStreamingAndRejectOutsidePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString, defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root.appendingPathComponent("Downloads"))
        let service = TorrentDownloadService(manager: manager, root: root.appendingPathComponent("Tasks"), workChanged: {}, userStartedWork: {})
        let metadata = bencode(["info":["name":"clip.mkv", "length":100, "piece length":16384, "pieces":Data(Insecure.SHA1.hash(data: Data(count:100)))]])
        let id = try await service.create(data: metadata, magnet: nil)
        let job = try XCTUnwrap(service.job(id)), file = try XCTUnwrap(job.files.first)
        let url = URL(fileURLWithPath: job.directory).appendingPathComponent(file.path)
        try Data(count:100).write(to:url)
        XCTAssertEqual(service.playbackTarget(for:url)?.id, id)
        XCTAssertNil(service.playbackTarget(for:root.appendingPathComponent(name + ".mkv")))
        try FileManager.default.removeItem(at:url)
        let outside = root.appendingPathComponent("outside.mkv"); try Data(count:100).write(to:outside)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:outside)
        XCTAssertNil(service.playbackTarget(for:url), "A torrent path must not expose an outside file through a symlink")
        service.select(id,indices:[])
        XCTAssertFalse(service.canStream(id,file:file))
    }

    func testStreamingReadsOnlyVerifiedPiecesAndPrioritizesSeekWithoutDownloadingExcludedFiles() async throws {
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
        defer { client.endStreaming(id: "stream"); client.remove("stream", deleteFiles: false); seeder.remove("seed", deleteFiles: false) }
        try seeder.addIdentifier("seed", data: fixture.data, magnet: nil, directory: seed.path, resumeData: nil, priorities: [1,1], metadataOnly: false)
        try await wait { seeder.snapshots().first?["finished"] as? Bool == true && seeder.listeningPort > 0 }
        try client.addIdentifier("stream", data: fixture.data, magnet: nil, directory: download.path, resumeData: nil, priorities: [1,0], metadataOnly: false)
        XCTAssertTrue(try client.availableData(id: "stream", file: 0, offset: 0, length: 4096).isEmpty)
        client.setDownloadLimit(128 * 1024, identifier: "stream")
        client.connectIdentifier("stream", host: "127.0.0.1", port: seeder.listeningPort)
        var prefix: Data?
        try await wait { prefix = try client.availableData(id: "stream", file: 0, offset: 0, length: 4096); return prefix?.isEmpty == false }
        XCTAssertEqual(prefix, fixture.first.prefix(4096))
        XCTAssertFalse(client.snapshots().first?["finished"] as? Bool ?? true,
                       "Playback data must be available before the torrent completes")
        var tail: Data?
        try await wait { tail = try client.availableData(id: "stream", file: 0, offset: Int64(fixture.first.count - 32), length: 32); return tail?.isEmpty == false }
        XCTAssertEqual(tail, fixture.first.suffix(32), "Seeking must fetch and verify the requested piece")
        XCTAssertTrue(try client.availableData(id: "stream", file: 1, offset: 0, length: 32).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.appendingPathComponent("BTFixture/excluded.bin").path))
    }

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
    func testBase32MagnetMatchesHexadecimalInfoHash() throws {
        let expected = "35b81a7384baec7e7b62cedd07fa83356dbc28b7"
        for hash in ["gw4bu44exlwh463cz3oqp6udgvw3ykfx", "GW4BU44EXLWH463CZ3OQP6UDGVW3YKFX", expected] {
            let metadata = try SLTorrentEngine.inspectMagnet("magnet:?xt=urn:btih:" + hash)
            XCTAssertEqual(metadata["hash"] as? String, expected)
        }
    }
    func testV2AndHybridMagnetHashesAreAccepted() throws {
        let v2 = String(repeating: "ab", count: 32)
        for suffix in ["", "&xt=urn:btih:35b81a7384baec7e7b62cedd07fa83356dbc28b7"] {
            let metadata = try SLTorrentEngine.inspectMagnet("magnet:?xt=urn:btmh:1220" + v2 + suffix)
            XCTAssertEqual(metadata["hash"] as? String, v2)
        }
        XCTAssertThrowsError(try SLTorrentEngine.inspectMagnet("magnet:?xt=urn:btmh:1220abcd"))
    }
    func testRealMagnetSearchSamplesUseTheNativeParserWithoutLosingTheirHash() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "magnet-source-links", withExtension: "json", subdirectory: "ReadingFixtures"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: String]])
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            let raw = try XCTUnwrap(row["uri"])
            guard case .magnet(let url) = try PeerDownloadLink.parse(raw) else { return XCTFail("Not a magnet") }
            let metadata = try SLTorrentEngine.inspectMagnet(url.absoluteString)
            XCTAssertEqual(metadata["hash"] as? String, row["hash"], row["source"] ?? "source")
        }
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
    func testOnlySystemPausedTasksResumeAndManualPauseOverridesAutomaticResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root.appendingPathComponent("Downloads"))
        let worker = ControlledTorrentEngine()
        let service = TorrentDownloadService(manager: manager, root: root.appendingPathComponent("Tasks"), worker: worker, workChanged: {}, userStartedWork: {})
        let manual = try await service.create(data: Data([1]), magnet: nil)
        let automatic = try await service.create(data: Data([2]), magnet: nil)
        service.start(manual); service.start(automatic)
        try await wait { service.jobs.allSatisfy { $0.state == .downloading } }
        service.pause(manual)
        await service.suspendAll()
        XCTAssertEqual(service.job(automatic)?.resumeAfterSystemPause, true)
        service.resumeSystemPausedTasks()
        try await wait { service.job(automatic)?.state == .downloading }
        XCTAssertEqual(service.job(manual)?.state, .paused)
        await service.suspendAll()
        service.pause(automatic) // Explicitly stop an already system-paused task.
        service.resumeSystemPausedTasks()
        XCTAssertEqual(service.job(automatic)?.state, .paused)
        XCTAssertEqual(service.job(automatic)?.resumeAfterSystemPause, false)
    }

    @MainActor
    func testAutomaticForegroundResumeWaitsForItsBackgroundCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root.appendingPathComponent("Downloads"))
        let worker = ControlledTorrentEngine()
        let service = TorrentDownloadService(manager: manager, root: root.appendingPathComponent("Tasks"), worker: worker, workChanged: {}, userStartedWork: {})
        let id = try await service.create(data: Data([1]), magnet: nil)
        service.start(id)
        try await wait { service.job(id)?.state == .downloading }
        await worker.holdPauses()
        let suspension = Task { await service.suspendAll() }
        try await waitAsync { await worker.hasHeldPause }
        service.resumeSystemPausedTasks()
        try await Task.sleep(for: .milliseconds(100))
        let earlyResumes = await worker.resumeCount(id)
        XCTAssertEqual(earlyResumes, 0)
        await worker.releasePauses(); await suspension.value
        try await wait { service.job(id)?.state == .downloading }
        let paused = await worker.isPaused(id)
        XCTAssertFalse(paused)
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
        XCTAssertEqual(restored.job(id)?.resumeAfterSystemPause, true)
        await worker.setChecking(false, completed: 750)
        restored.resumeSystemPausedTasks()
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

private actor StreamingTorrentTestPeer {
    private let seed = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
    private let client = SLTorrentEngine(certificateFile: "", discoveryEnabled: false)
    init(metadata: Data, seed: URL, destination: URL) throws {
        try self.seed.addIdentifier("seed", data: metadata, magnet: nil, directory: seed.path, resumeData: nil, priorities: [1], metadataOnly: false)
        try client.addIdentifier("client", data: metadata, magnet: nil, directory: destination.path, resumeData: nil, priorities: [1], metadataOnly: false)
        client.setDownloadLimit(96 * 1024, identifier: "client")
    }
    func ready() -> Bool { seed.snapshots().first?["finished"] as? Bool == true && seed.listeningPort > 0 }
    func connect() { client.connectIdentifier("client", host: "127.0.0.1", port: seed.listeningPort) }
    func read(offset: Int64, count: Int) throws -> Data? {
        let data = try client.availableData(id: "client", file: 0, offset: offset, length: count)
        return data.isEmpty ? nil : data
    }
    func finished() -> Bool { client.snapshots().first?["finished"] as? Bool == true }
    func stop() { client.endStreaming(id: "client"); client.remove("client", deleteFiles: false); seed.remove("seed", deleteFiles: false) }
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
