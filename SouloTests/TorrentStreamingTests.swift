import AVFoundation
import Foundation
import XCTest
@testable import Soulo

final class TorrentStreamingTests: XCTestCase {
    func testByteRangesSupportSeekingAndRejectMalformedRequests() throws {
        XCTAssertEqual(try TorrentHTTPRange.parse(nil, size: 100), 0..<100)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=10-19", size: 100), 10..<20)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=90-", size: 100), 90..<100)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=-20", size: 100), 80..<100)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=90-9223372036854775807", size: 100), 90..<100)
        for range in ["bytes=100-", "bytes=20-10", "bytes=-0", "bytes=1-2,4-5", "bytes=a-b", "bytes=9223372036854775808-", "items=0-1"] {
            XCTAssertThrowsError(try TorrentHTTPRange.parse(range, size: 100), range)
        }
    }

    func testStreamWaitsForVerifiedBytesAndSupportsRangeAndHead() async throws {
        let fixture = ProgressiveTorrentBytes()
        let server = try await TorrentStreamServer.start(size: Int64(fixture.bytes.count), name: "movie.mkv") { offset, count in
            await fixture.read(offset: offset, count: count)
        }
        defer { server.stop() }
        XCTAssertEqual(server.url.host, "127.0.0.1")
        var request = URLRequest(url: server.url)
        request.setValue("bytes=4096-8191", forHTTPHeaderField: "Range")
        let download = Task {
            let result = try await URLSession.shared.data(for: request)
            await fixture.finish()
            return result
        }
        defer { download.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        let finishedEarly = await fixture.finished
        XCTAssertFalse(finishedEarly, "Missing pieces must buffer; preallocated zeroes are not playable data")
        await fixture.makeAvailable()
        let (data, response) = try await download.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 4096-8191/16384")
        XCTAssertEqual(data, fixture.bytes.subdata(in: 4096..<8192))
        var head = URLRequest(url: server.url); head.httpMethod = "HEAD"
        let (body, headResponse) = try await URLSession.shared.data(for: head)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "16384")
        var invalid = URLRequest(url: server.url); invalid.setValue("bytes=16384-", forHTTPHeaderField: "Range")
        let (_, rejected) = try await URLSession.shared.data(for: invalid)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 416)
        let wrong = server.url.deletingLastPathComponent().appendingPathComponent("other.mkv")
        let (_, wrongResponse) = try await URLSession.shared.data(from: wrong)
        XCTAssertEqual((wrongResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    @MainActor
    func testMKVDecodesAndAdvancesWithTheExtendedPlayer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mkv", subdirectory: "ReadingFixtures"))
        XCTAssertEqual(FilePresentation.inspect(url).kind, .video)
        playback.open(url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5, "An MKV must actually decode and play, not merely open a preview")
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
        XCTAssertGreaterThan(playback.duration, 0)
        playback.togglePlayback()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(playback.playing)
        playback.seek(1)
        playback.togglePlayback()
    }

    @MainActor
    func testMKVPlaysAndSeeksFromTheTorrentHTTPStream() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mkv", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "clip.mkv") { offset, count in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(server.url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5)
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
        playback.seek(4)
        for _ in 0..<100 {
            if playback.elapsed > 4.2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(playback.elapsed, 4.2, "MKV seeking must work through the same HTTP ranges used for torrent playback")
    }

    @MainActor
    func testHEV1MP4UsesExtendedDecoderAndPlaysThroughTheTorrentStream() async throws {
        let fixture = "playback-hevc-hev1"
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "hev1.mp4") { offset, count in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        defer { server.stop() }
        let extended = try await TorrentFileDecoder.prefersExtended(AVURLAsset(url: server.url), path: "hev1.mp4")
        XCTAssertTrue(extended, "A .mp4 suffix must not force an incompatible HEVC sample through AVPlayer")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(server.url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5, (playback.player?.media?.statistics.displayedPictures ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5, "\(fixture): state=\(String(describing: playback.player?.state.rawValue)), duration=\(playback.duration), position=\(playback.player?.position ?? 0)")
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
        let stats = try XCTUnwrap(playback.player?.media?.statistics)
        XCTAssertGreaterThan(stats.decodedVideo, 0)
        XCTAssertGreaterThan(stats.displayedPictures, 0, "Audio progress alone does not prove HEVC video playback")
        print("HEVC_ACTUAL_FRAMES|decoded=\(stats.decodedVideo)|displayed=\(stats.displayedPictures)")
    }

    @MainActor
    func testSilentDecoderStopIsReportedInsteadOfLeavingABlackScreen() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-hevc-hev1-no-audio", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "no-audio.mp4") { offset, count in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(server.url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 || playback.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Capabilities vary by decoder/device. Either actual playback progresses
        // or the UI must present its retry/error state; opening alone isn't success.
        XCTAssertTrue(playback.elapsed > 0.5 || playback.error != nil)
        if playback.error != nil {
            XCTAssertFalse(playback.buffering)
            print("HEVC_VIDEO_ONLY|decoder_stopped_early|explicit_error_presented")
        }
    }
}

private actor ProgressiveTorrentBytes {
    nonisolated let bytes = Data((0..<16384).map { UInt8($0 % 251) })
    private var available = false
    private(set) var finished = false
    func finish() { finished = true }
    func makeAvailable() { available = true }
    func read(offset: Int64, count: Int) -> Data? {
        guard available else { return nil }
        let first = Int(offset)
        return bytes.subdata(in: first..<min(bytes.count, first + count))
    }
}
