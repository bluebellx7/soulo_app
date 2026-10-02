import XCTest
import AVFoundation
import WebKit
@testable import Soulo

@MainActor
final class DownloadPlaybackTests: XCTestCase {
    private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(message)
        throw URLError(.timedOut)
    }

    private func videoFixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures")))
    }

    func testPlaybackSourcesRespectPauseTerminalStatesAndAreNotPersisted() throws {
        let suite = "download-playback-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let asset = AVURLAsset(url: URL(string: "https://example.com/video.m3u8")!)
        let item = manager.beginDownload(suggestedFilename: "clip.mp4", sourceURL: asset.url, transport: .hls).0
        XCTAssertNil(manager.playbackSource(for: item.id), "A filename alone must not advertise playback")
        manager.registerPlaybackSource(id: item.id, asset: asset)
        XCTAssertTrue(manager.playbackSource(for: item.id)?.asset === asset)
        manager.markPaused(id: item.id)
        XCTAssertNil(manager.playbackSource(for: item.id))
        manager.markResumed(id: item.id)
        XCTAssertTrue(manager.playbackSource(for: item.id)?.asset === asset)
        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertNil(restored.playbackSource(for: item.id), "Cookies and live assets must not enter persisted history")
        manager.markCanceled(id: item.id)
        manager.registerPlaybackSource(id: item.id, asset: asset)
        XCTAssertNil(manager.playbackSource(for: item.id), "Late preparation cannot revive a canceled item")
    }

    func testPrivatePlaybackContextSurvivesWebViewRelease() throws {
        let asset = AVURLAsset(url: URL(string: "https://example.com/private.mp4")!)
        var web: WKWebView? = {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            return WKWebView(frame: .zero, configuration: config)
        }()
        let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: web)
        XCTAssertFalse(source.persistsPosition)
        web = nil
        // WebKit can retain a newly initialized view until a later run-loop
        // turn. Model an unavailable weak reference without depending on that.
        source.webView = nil
        XCTAssertNil(source.webView)
        XCTAssertFalse(source.persistsPosition)
    }

    func testCompletedHLSCacheRemainsUntilPlayerReleasesSource() async throws {
        let session = MediaSession.shared
        defer { session.stop() }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let asset = AVURLAsset(url: file)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".movpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        var source: DownloadPlaybackSource? = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil)
        weak var weakSource = source
        session.open(url: asset.url, asset: asset, persistPosition: false, downloadSource: source)
        XCTAssertFalse(session.deferDownloadPackageRemoval(for: AVURLAsset(url: file), at: package), "Only the actual player asset may lease its cache")
        XCTAssertTrue(session.deferDownloadPackageRemoval(for: asset, at: package))
        source = nil
        XCTAssertNotNil(weakSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        session.stop()
        XCTAssertNil(weakSource)
        try await waitFor("Released HLS cache was not removed") { !FileManager.default.fileExists(atPath: package.path) }
    }

    func testAuthenticatedMP4PlaysAndDownloadContinuesToComplete() async throws {
        let bytes = try videoFixture()
        let server = try DownloadPlaybackHTTPFixture(files: ["/clip.mp4": bytes], requiredCookie: "downloadPlayback=allowed")
        let root = try await server.start()
        defer { server.stop() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "downloadPlayback", .value: "allowed"]))
        await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("clip.mp4"), title: "Concurrent download", posterURL: nil)
        let manager = DownloadManagerService.shared, session = MediaSession.shared
        let oldRate = session.rate; session.setRate(1)
        let download = Task { try await WebResourceDownloadService.shared.download(resource, webView: web) }
        defer {
            session.stop(); session.setRate(oldRate)
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                manager.delete(item); try? FileManager.default.removeItem(at: item.localURL)
            }
            download.cancel()
        }
        try await waitFor("Video download did not publish its playback source") {
            guard let item = manager.activeDownload(for: resource.url) else { return false }
            return manager.playbackSource(for: item.id) != nil && item.receivedBytes > 0
        }
        let item = try XCTUnwrap(manager.activeDownload(for: resource.url))
        let source = try XCTUnwrap(manager.playbackSource(for: item.id))
        let received = server.downloadedBytes
        session.open(url: source.asset.url, asset: source.asset, webView: source.webView,
            persistPosition: source.persistsPosition, downloadSource: source)
        try await waitFor("Native player did not advance during the download: \(session.error ?? "no player error")") {
            session.player.currentTime().seconds > 0.6
        }
        XCTAssertNil(session.error)
        XCTAssertTrue(session.hasVideo)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
        XCTAssertGreaterThan(server.rangeRequests, 0)
        try await waitFor("Opening the player stopped the file transfer") { server.downloadedBytes > received }
        let before = session.player.currentTime().seconds
        server.releaseDownloads()
        let result = try await download.value
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        XCTAssertNil(manager.playbackSource(for: item.id))
        try await waitFor("Finishing the download stopped playback") { session.player.currentTime().seconds > before + 0.3 }
        XCTAssertNil(session.error)
    }

    func testHLSPlaybackReusesDownloadingAssetAndSurvivesCompletion() async throws {
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(index).ts"] = try Data(contentsOf: file)
            playlist += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files, heldPaths: ["/segment3.ts"])
        let root = try await server.start()
        defer { server.stop() }
        let web = WKWebView()
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Concurrent HLS", posterURL: nil, delivery: .hls)
        let manager = DownloadManagerService.shared, session = MediaSession.shared
        let oldRate = session.rate; session.setRate(1)
        let download = Task { try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource, preferredFilename: "concurrent-hls.mp4", pageURL: nil, webView: web) }
        defer {
            session.stop(); session.setRate(oldRate)
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                manager.delete(item); try? FileManager.default.removeItem(at: item.localURL)
            }
            download.cancel()
        }
        try await waitFor("HLS task did not publish its asset") {
            guard let item = manager.activeDownload(for: resource.url) else { return false }
            return manager.playbackSource(for: item.id) != nil
        }
        let item = try XCTUnwrap(manager.activeDownload(for: resource.url))
        let source = try XCTUnwrap(manager.playbackSource(for: item.id))
        session.open(url: source.asset.url, asset: source.asset, persistPosition: false, downloadSource: source)
        try await waitFor("HLS player did not advance before the last segment arrived") { session.player.currentTime().seconds > 0.5 }
        XCTAssertTrue(session.player.currentItem?.asset === source.asset)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
        XCTAssertNil(session.error)
        let before = session.player.currentTime().seconds
        server.releaseDownloads()
        let result = try await download.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        try await waitFor("HLS completion interrupted the active player") { session.player.currentTime().seconds > before + 0.3 }
        XCTAssertNil(session.error)
    }
}
