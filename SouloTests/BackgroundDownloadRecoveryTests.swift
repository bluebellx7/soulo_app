import AVFoundation
import WebKit
import XCTest
@testable import Soulo

@MainActor
final class BackgroundDownloadRecoveryTests: XCTestCase {
    func testOnlyReplayableHTTPGetMovesOutOfWebKit() {
        var request = URLRequest(url: URL(string: "https://example.com/file")!)
        XCTAssertTrue(WebResourceDownloadService.canDownloadInBackground(request))
        XCTAssertFalse(WebResourceDownloadService.canDownloadInBackground(nil))
        request.httpMethod = "POST"
        XCTAssertFalse(WebResourceDownloadService.canDownloadInBackground(request))
        request.httpMethod = "GET"; request.httpBody = Data("form".utf8)
        XCTAssertFalse(WebResourceDownloadService.canDownloadInBackground(request))
        request.httpBody = nil; request.setValue("bytes=10-", forHTTPHeaderField: "Range")
        XCTAssertFalse(WebResourceDownloadService.canDownloadInBackground(request))
        for url in ["blob:https://example.com/id", "data:text/plain,hello", "file:///tmp/file"] {
            XCTAssertFalse(WebResourceDownloadService.canDownloadInBackground(URLRequest(url: URL(string: url)!)))
        }
    }

    func testHandoffRetainsOriginalHeadersAndAddsPrivateBrowserCookies() async throws {
        let webView = WKWebView(frame: .zero, configuration: {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); return config
        }())
        webView.customUserAgent = "BackgroundDownloadTest"
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: "login", .value: "private"
        ]))
        await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        var original = URLRequest(url: URL(string: "https://example.com/file")!)
        original.setValue("Bearer signed", forHTTPHeaderField: "Authorization")
        original.setValue("application/pdf", forHTTPHeaderField: "Accept")
        original.setValue("https://example.com/custom-referrer", forHTTPHeaderField: "Referer")
        let request = await WebResourceDownloadService.shared.backgroundRequest(
            from: original, pageURL: URL(string: "https://example.com/page"), webView: webView
        )
        XCTAssertEqual(request.url, original.url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/pdf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://example.com/custom-referrer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "BackgroundDownloadTest")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("login=private") == true)
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testSeparatedTrackDownloadsRemainAttachableAcrossHistoryReload() throws {
        let suite = "separated-reload-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let active = manager.beginDownload(suggestedFilename: "active.mp4", sourceURL: nil, transport: .separated).0
        let paused = manager.beginDownload(suggestedFilename: "paused.mp4", sourceURL: nil, transport: .separated).0
        manager.markPaused(id: paused.id)
        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertEqual(restored.downloads.first { $0.id == active.id }?.status, .inProgress)
        XCTAssertEqual(restored.downloads.first { $0.id == paused.id }?.status, .paused)
    }

    func testCompletedTracksResumeMergeWithoutNetworkAfterRelaunch() async throws {
        let context = try Context()
        defer { context.clean() }
        let item = context.manager.beginDownload(suggestedFilename: "merged.mp4", sourceURL: nil, transport: .separated).0
        context.manager.markPaused(id: item.id)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"
        ))
        for track in SeparatedMediaDownloadService.Track.allCases {
            let destination = SeparatedMediaDownloadService.trackURL(id: item.id, track: track, directory: context.tracks)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: destination)
        }
        // Construct a fresh service using only persisted history and track files.
        let service = context.service()
        defer { service.invalidate() }
        await service.prepare()
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .paused)
        service.resume(id: item.id)
        try await waitFor { context.manager.downloads.first { $0.id == item.id }?.status == .finished }
        let output = AVURLAsset(url: item.localURL)
        let videos = try await output.loadTracks(withMediaType: .video)
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1); XCTAssertEqual(audio.count, 1)
        XCTAssertFalse(SeparatedMediaDownloadService.hasCompletedTracks(id: item.id, directory: context.tracks))
    }

    func testMissingTrackAfterRelaunchFailsAndCleansPartialFiles() async throws {
        let context = try Context()
        defer { context.clean() }
        let item = context.manager.beginDownload(suggestedFilename: "missing.mp4", sourceURL: nil, transport: .separated).0
        let video = SeparatedMediaDownloadService.trackURL(id: item.id, track: .video, directory: context.tracks)
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial video".utf8).write(to: video)
        let service = context.service()
        defer { service.invalidate() }
        await service.prepare()
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
    }

    func testExpiredMergeKeepsTracksReleasesBackgroundEventsAndRestartsInForeground() async throws {
        let context = try Context()
        defer { context.clean() }
        let item = context.manager.beginDownload(suggestedFilename: "expired.mp4", sourceURL: nil, transport: .separated).0
        context.manager.markPaused(id: item.id)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"
        ))
        for track in SeparatedMediaDownloadService.Track.allCases {
            let destination = SeparatedMediaDownloadService.trackURL(id: item.id, track: track, directory: context.tracks)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: destination)
        }
        let service = context.service()
        defer { service.invalidate() }
        await service.prepare()
        var eventCompletions = 0
        service.backgroundEventsCompletionHandler = { eventCompletions += 1 }
        service.resume(id: item.id)
        service.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        XCTAssertEqual(eventCompletions, 0, "Background events must wait for an active merge")
        // Exercise the same cancellation path as UIKit's expiration handler.
        service.deferMergeUntilForeground(id: item.id)
        XCTAssertEqual(eventCompletions, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .inProgress)
        XCTAssertTrue(SeparatedMediaDownloadService.hasCompletedTracks(id: item.id, directory: context.tracks))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.localURL.path))
        service.resumePendingMerges()
        try await waitFor { context.manager.downloads.first { $0.id == item.id }?.status == .finished }
        XCTAssertEqual(eventCompletions, 1)
    }

    func testBackgroundTracksDownloadPauseResumeAndMerge() async throws {
        let context = try Context()
        defer { context.clean() }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"
        ))
        let bytes = try Data(contentsOf: fixture)
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.mp4": bytes, "/audio.mp4": bytes])
        let root = try await server.start()
        defer { server.stop() }
        let service = context.service()
        defer { service.invalidate() }
        await service.prepare()
        let item = context.manager.beginDownload(suggestedFilename: "network.mp4", sourceURL: root, transport: .separated).0
        let operation = Task {
            try await service.start(item: item, videoRequest: URLRequest(url: root.appendingPathComponent("video.mp4")),
                                    audioRequest: URLRequest(url: root.appendingPathComponent("audio.mp4")))
        }
        defer { service.cancel(id: item.id) }
        try await waitFor { (context.manager.downloads.first { $0.id == item.id }?.receivedBytes ?? 0) > 0 }
        service.pause(id: item.id)
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .paused)
        server.releaseDownloads()
        service.resume(id: item.id)
        let output = try await operation.value
        XCTAssertEqual(output, item.localURL)
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .finished)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    func testTrackIdentifiersCannotAliasAnotherDownload() {
        let id = UUID()
        let key = SeparatedMediaDownloadService.taskKey(id: id, track: .audio)
        XCTAssertEqual(SeparatedMediaDownloadService.parseTaskKey(key)?.id, id)
        XCTAssertEqual(SeparatedMediaDownloadService.parseTaskKey(key)?.track, .audio)
        for key in ["", "../audio", "\(id)/invalid", "\(id)/video/extra"] {
            XCTAssertNil(SeparatedMediaDownloadService.parseTaskKey(key))
        }
    }

    func testPauseBeforeTrackTasksExistCanResumeNormally() async throws {
        let context = try Context()
        defer { context.clean() }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"
        ))
        let bytes = try Data(contentsOf: fixture)
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.mp4": bytes, "/audio.mp4": bytes])
        let root = try await server.start()
        defer { server.stop() }
        let service = context.service()
        defer { service.invalidate() }
        await service.prepare()
        let item = context.manager.beginDownload(suggestedFilename: "startup.mp4", sourceURL: root, transport: .separated).0
        service.pause(id: item.id)
        let operation = Task {
            try await service.start(item: item, videoRequest: URLRequest(url: root.appendingPathComponent("video.mp4")),
                                    audioRequest: URLRequest(url: root.appendingPathComponent("audio.mp4")))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .paused)
        XCTAssertEqual(server.downloadedBytes, 0)
        server.releaseDownloads()
        service.resume(id: item.id)
        _ = try await operation.value
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .finished)
    }

    func testCancelRejectsLateTrackCompletionAndRemovesStaging() async throws {
        let context = try Context()
        defer { context.clean() }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"
        ))
        let bytes = try Data(contentsOf: fixture)
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.mp4": bytes, "/audio.mp4": bytes])
        let root = try await server.start()
        defer { server.stop() }
        let service = context.service()
        defer { service.invalidate() }
        await service.prepare()
        let item = context.manager.beginDownload(suggestedFilename: "cancel.mp4", sourceURL: root, transport: .separated).0
        let operation = Task {
            try await service.start(item: item, videoRequest: URLRequest(url: root.appendingPathComponent("video.mp4")),
                                    audioRequest: URLRequest(url: root.appendingPathComponent("audio.mp4")))
        }
        try await waitFor { (context.manager.downloads.first { $0.id == item.id }?.receivedBytes ?? 0) > 0 }
        service.cancel(id: item.id)
        server.releaseDownloads()
        do { _ = try await operation.value; XCTFail("Canceled transfer returned a file") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(context.manager.downloads.first { $0.id == item.id }?.status, .canceled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.tracks.appendingPathComponent(item.id.uuidString).path))
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Background download did not reach the expected state")
        throw URLError(.timedOut)
    }

    @MainActor
    private struct Context {
        let suite = "background-recovery-" + UUID().uuidString
        let defaults: UserDefaults
        let root: URL
        let tracks: URL
        let manager: DownloadManagerService
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            tracks = root.appendingPathComponent("tracks")
            manager = DownloadManagerService(userDefaults: defaults, storageDirectory: root.appendingPathComponent("downloads"))
        }
        func service() -> SeparatedMediaDownloadService {
            SeparatedMediaDownloadService(manager: manager, directory: tracks, sessionIdentifier: "com.dkluge.Soulo.tests.\(suite)")
        }
        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
