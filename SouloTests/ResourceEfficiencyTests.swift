import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore
@testable import Soulo

@MainActor
final class ResourceEfficiencyTests: XCTestCase {
    func testWallpaperSourceSelectionLoadsProviderAndDefaultsToNature() async throws {
        try await withWallpaperSession { manager, image in
            WallpaperSwitchProtocol.setHandler { stub in
                if stub.request.url?.host == "api.pexels.com" {
                    let query = URLComponents(url: stub.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
                    XCTAssertEqual(query, "Nature")
                    stub.respond(json: #"{"photos":[{"id":"test-pexels","src":{"original":"https://wallpaper.test/pexels.jpg"}}]}"#)
                } else if stub.request.url?.host == "pixabay.com" {
                    let query = URLComponents(url: stub.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
                    XCTAssertEqual(query, "Nature")
                    stub.respond(json: #"{"hits":[{"id":"test-pixabay","largeImageURL":"https://wallpaper.test/pixabay.jpg"}]}"#)
                } else { stub.respond(data: image, mime: "image/jpeg") }
            }
            XCTAssertEqual(manager.vibeTags, ["Nature"])
            await manager.selectSource(.pexels)
            XCTAssertEqual(manager.currentImageID, "test-pexels")
            XCTAssertNotNil(manager.currentImage)
            manager.searchTopic = "Bing Daily"
            await manager.selectSource(.pixabay)
            XCTAssertEqual(manager.searchTopic, "Nature")
            XCTAssertEqual(manager.currentImageID, "test-pixabay")
            XCTAssertEqual(manager.candidateWallpapers.map(\.source), ["pixabay"])
            XCTAssertFalse(manager.networkLoading)
        }
    }

    func testLateWallpaperResponseCannotReplaceNewSourceOrEndItsLoadingState() async throws {
        try await withWallpaperSession { manager, image in
            let held = WallpaperHeldRequests()
            let oldStarted = expectation(description: "Old source started")
            let newStarted = expectation(description: "New source started")
            WallpaperSwitchProtocol.setHandler { stub in
                if stub.request.url?.host == "api.pexels.com" {
                    held.store(stub, host: "pexels"); oldStarted.fulfill()
                } else if stub.request.url?.host == "pixabay.com" {
                    held.store(stub, host: "pixabay"); newStarted.fulfill()
                } else { stub.respond(data: image, mime: "image/jpeg") }
            }
            let old = Task { await manager.selectSource(.pexels) }
            await fulfillment(of: [oldStarted], timeout: 3)
            let new = Task { await manager.selectSource(.pixabay) }
            await fulfillment(of: [newStarted], timeout: 3)
            try XCTUnwrap(held.request(host: "pexels")).respond(json: #"{"photos":[{"id":"late","src":{"original":"https://wallpaper.test/old.jpg"}}]}"#)
            await old.value
            XCTAssertEqual(manager.source, .pixabay)
            XCTAssertTrue(manager.networkLoading)
            XCTAssertTrue(manager.candidateWallpapers.isEmpty)
            try XCTUnwrap(held.request(host: "pixabay")).respond(json: #"{"hits":[{"id":"latest","largeImageURL":"https://wallpaper.test/new.jpg"}]}"#)
            await new.value
            XCTAssertEqual(manager.currentImageID, "latest")
            XCTAssertFalse(manager.networkLoading)
            await manager.selectSource(.solid)
            XCTAssertNil(manager.currentImage)
            XCTAssertTrue(manager.candidateWallpapers.isEmpty)
        }
    }

    func testWallpaperHTTPErrorIsVisibleAndChangingSourceRecovers() async throws {
        try await withWallpaperSession { manager, image in
            WallpaperSwitchProtocol.setHandler { stub in
                if stub.request.url?.host == "pixabay.com" {
                    stub.respond(data: Data("Forbidden".utf8), status: 403, mime: "text/plain")
                } else if stub.request.url?.path == "/HPImageArchive.aspx" {
                    stub.respond(json: #"{"images":[{"startdate":"test-bing","url":"/test-wallpaper.jpg"}]}"#)
                } else { stub.respond(data: image, mime: "image/jpeg") }
            }
            await manager.selectSource(.pixabay)
            XCTAssertFalse(manager.lastRemoteError.isEmpty)
            XCTAssertFalse(manager.networkLoading)
            await manager.selectSource(.bing)
            XCTAssertEqual(manager.currentImageID, "test-bing")
            XCTAssertNotNil(manager.currentImage)
            XCTAssertTrue(manager.lastRemoteError.isEmpty)
            XCTAssertFalse(manager.networkLoading)
        }
    }

    private func withWallpaperSession(_ check: (WallpaperManager, Data) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["wallpaper_source", "wallpaper_topic", "wallpaper_vibe_tags", "wallpaper_refresh_interval",
                    "wallpaper_only_favorites", "wallpaper_favorites", "wallpaper_blocked",
                    "wallpaper_current_cache_file", "wallpaper_current_cache_id", "wallpaper_current_cache_url"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set("gradient", forKey: "wallpaper_source")
        defaults.set(0, forKey: "wallpaper_refresh_interval")
        defaults.set(false, forKey: "wallpaper_only_favorites")
        for key in keys where !["wallpaper_source", "wallpaper_refresh_interval", "wallpaper_only_favorites"].contains(key) {
            defaults.removeObject(forKey: key)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WallpaperSwitchProtocol.self]
        let session = URLSession(configuration: configuration)
        let resources = BrowserResourcePolicy(readAllowance: { false })
        let manager = WallpaperManager(resources: resources, session: session)
        defer {
            manager.suspendAutomaticRefresh()
            session.invalidateAndCancel()
            WallpaperSwitchProtocol.setHandler(nil)
            if let name = defaults.string(forKey: "wallpaper_current_cache_file") {
                let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("CurrentWallpaper").appendingPathComponent(name)
                try? FileManager.default.removeItem(at: file)
            }
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
        }
        try await check(manager, jpeg(width: 32, height: 64))
    }

    func testCachedWallpaperLoadsAfterConstructionAndCannotReplaceANewSource() async throws {
        let defaults = UserDefaults.standard
        let keys = ["wallpaper_source", "wallpaper_refresh_interval", "wallpaper_current_cache_file",
                    "wallpaper_current_cache_id", "wallpaper_current_cache_url"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let name = "startup-\(UUID()).jpg"
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CurrentWallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try jpeg(width: 6000, height: 4000).write(to: file)
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: file)
        }
        defaults.set("bing", forKey: "wallpaper_source")
        defaults.set(0, forKey: "wallpaper_refresh_interval")
        defaults.set(name, forKey: "wallpaper_current_cache_file")
        defaults.set(name, forKey: "wallpaper_current_cache_id")
        let manager = WallpaperManager()
        defer { manager.suspendAutomaticRefresh() }
        XCTAssertNil(manager.currentImage, "Constructing home state must return before disk decoding")
        try await wait { manager.currentImage != nil }
        XCTAssertEqual(manager.currentImageID, name)

        let switched = WallpaperManager()
        defer { switched.suspendAutomaticRefresh() }
        switched.source = .gradient
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(switched.currentImage, "A canceled cache restore cannot overwrite the selected gradient")
        XCTAssertNotEqual(switched.currentImageID, name)
    }

    private func jpeg(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(UIColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(UIColor.systemYellow.cgColor); context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            let data = try XCTUnwrap(CFDataCreateMutable(nil, 0))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
    }

    func testWallpaperDecodeBoundsMemoryAndPreservesRotationAndOriginalBytes() throws {
        let data = try jpeg(width: 6000, height: 4000)
        let start = CFAbsoluteTimeGetCurrent()
        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        let originalMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let thumbStart = CFAbsoluteTimeGetCurrent()
        let image = try XCTUnwrap(WallpaperImageDecoder.decode(data, targetPixels: CGSize(width: 1000, height: 2000)))
        let decodedMS = (CFAbsoluteTimeGetCurrent() - thumbStart) * 1000
        let fullBytes = full.bytesPerRow * full.height, displayBytes = image.bytesPerRow * image.height
        XCTAssertEqual(image.width, 3000); XCTAssertEqual(image.height, 2000)
        XCTAssertLessThanOrEqual(displayBytes, fullBytes / 3)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let originalSize = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(originalSize[kCGImagePropertyPixelWidth as String] as? Int, 6000)
        let rotated = try jpeg(width: 800, height: 400, orientation: 6)
        let upright = try XCTUnwrap(WallpaperImageDecoder.decode(rotated, targetPixels: CGSize(width: 80, height: 160)))
        XCTAssertEqual(upright.width, 160); XCTAssertEqual(upright.height, 320)
        let small = try XCTUnwrap(WallpaperImageDecoder.decode(try jpeg(width: 20, height: 10), targetPixels: CGSize(width: 1000, height: 2000)))
        XCTAssertEqual(small.width, 20); XCTAssertEqual(small.height, 10)
        XCTAssertNil(WallpaperImageDecoder.decode(Data("invalid".utf8), targetPixels: CGSize(width: 100, height: 100)))
        print("PERF wallpaper: full_bitmap_bytes=\(fullBytes), display_bitmap_bytes=\(displayBytes), full_decode_ms=\(originalMS), display_decode_ms=\(decodedMS), compressed_bytes=\(data.count)")
    }

    func testPowerConstraintReleasesSpareButKeepsExplicitNavigationAvailable() async throws {
        let notifications = NotificationCenter()
        var permitted = true
        let resources = BrowserResourcePolicy(notificationCenter: notifications, readAllowance: { permitted })
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .milliseconds(10), resources: resources)
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await wait { pool.isPreparedWebViewReady }
        let claimed = pool.makeWebView(isIncognito: false, for: nil)
        _ = try await claimed.evaluateJavaScript("window.retainedState=42")
        try await wait { pool.isPreparedWebViewReady }
        permitted = false
        notifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await wait { !resources.allowsSpeculation && pool.preparedWebView == nil }
        let explicit = pool.makeWebView(isIncognito: false, for: nil)
        let value = try await explicit.evaluateJavaScript("6*7") as? Int
        XCTAssertEqual(value, 42)
        let retained = try await claimed.evaluateJavaScript("window.retainedState") as? Int
        XCTAssertEqual(retained, 42)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(pool.preparedWebView)
        permitted = true
        notifications.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await wait { resources.allowsSpeculation && pool.isPreparedWebViewReady }
    }

    func testWallpaperAutomaticWorkPausesForPowerAndBackgroundWithoutChangingPreference() async throws {
        let defaults = UserDefaults.standard
        let keys = ["wallpaper_source", "wallpaper_refresh_interval", "wallpaper_only_favorites", "wallpaper_favorites", "wallpaper_last_auto_refresh_at"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("gradient", forKey: "wallpaper_source")
        defaults.set(60, forKey: "wallpaper_refresh_interval")
        defaults.set(true, forKey: "wallpaper_only_favorites")
        defaults.removeObject(forKey: "wallpaper_favorites")
        let notifications = NotificationCenter()
        var permitted = true
        let resources = BrowserResourcePolicy(notificationCenter: notifications, readAllowance: { permitted })
        let manager = WallpaperManager(resources: resources)
        defer { manager.suspendAutomaticRefresh() }
        manager.refreshIfNeededAfterForeground()
        XCTAssertTrue(manager.hasAutomaticRefreshWork)
        permitted = false
        notifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await wait { !resources.allowsSpeculation && !manager.hasAutomaticRefreshWork }
        XCTAssertEqual(manager.autoRefreshInterval, .min1)
        permitted = true
        notifications.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await wait { manager.hasAutomaticRefreshWork }
        manager.suspendAutomaticRefresh()
        XCTAssertFalse(manager.hasAutomaticRefreshWork)
        manager.setupAutoRefreshTimer()
        XCTAssertFalse(manager.hasAutomaticRefreshWork, "Changing a preference while backgrounded cannot restart timers")
        manager.refreshIfNeededAfterForeground()
        XCTAssertTrue(manager.hasAutomaticRefreshWork)
        XCTAssertEqual(manager.autoRefreshInterval, .min1)
    }

    func testIdleAndHiddenPagesDoNotKeepVideoHeartbeatTimers() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=globalThis, events={},windowEvents={},videos=[],timers={},nextTimer=0,messages=[],innerHeight=800;
        var document={hidden:false,querySelectorAll:function(){return videos;},addEventListener:function(name,fn){events[name]=fn;}};
        window.addEventListener=function(name,fn){windowEvents[name]=fn;};
        var webkit={messageHandlers:{souloVideoAwake:{postMessage:function(p){messages.push(p.active);}}}};
        function getComputedStyle(){return {display:'block',visibility:'visible'};}
        function requestAnimationFrame(fn){fn();}
        function setInterval(fn){var id=++nextTimer;timers[id]=fn;return id;}
        function clearInterval(id){delete timers[id];}
        var video={paused:false,ended:false,readyState:4,getBoundingClientRect:function(){return {width:640,height:360,top:0,bottom:360};}};
        """)
        context.evaluateScript(WebViewScripts.videoScreenAwake)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("Object.keys(timers).length")?.toInt32(), 0)
        context.evaluateScript("videos=[video];events.playing();events.playing();")
        XCTAssertEqual(context.evaluateScript("Object.keys(timers).length")?.toInt32(), 1)
        context.evaluateScript("video.paused=true;events.pause();")
        XCTAssertEqual(context.evaluateScript("Object.keys(timers).length")?.toInt32(), 0)
        context.evaluateScript("video.paused=false;events.playing();document.hidden=true;events.visibilitychange();")
        XCTAssertEqual(context.evaluateScript("Object.keys(timers).length")?.toInt32(), 0)
        context.evaluateScript("document.hidden=false;events.visibilitychange();")
        XCTAssertEqual(context.evaluateScript("Object.keys(timers).length")?.toInt32(), 1)
        context.evaluateScript("windowEvents.pagehide();")
        XCTAssertEqual(context.evaluateScript("Object.keys(timers).length")?.toInt32(), 0)
        XCTAssertFalse(context.evaluateScript("messages[messages.length-1]")!.toBool())
        print("PERF video heartbeat: idle_timers=0, active_timers=1, paused_or_hidden_timers=0")
    }

    func testCacheClearDropsPendingPreviewAndAllowsFutureCapture() async throws {
        let defaults = UserDefaults.standard, saved = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        defer { defaults.set(saved, forKey: "is_incognito") }
        let model = WebViewModel(), id = UUID()
        model.configureSnapshotPersistence(id: id)
        defer { model.deletePersistedSnapshot() }
        model.loadCachedURL(URL(string: "https://cache-regression.example/preview")!)
        model.errorMessage = "Cache regression fixture"
        let file = WebViewModel.snapshotDirectory.appendingPathComponent(id.uuidString + ".jpg")
        var firstFinished = false
        model.takeSnapshot { firstFinished = true }
        model.clearSnapshotCache()
        try await wait { firstFinished }
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "A capture queued before Clear must not recreate its file")
        var secondFinished = false
        model.takeSnapshot { secondFinished = true }
        try await wait { secondFinished }
        try await wait { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertNotNil(model.snapshot, "Clearing a cache must preserve future preview capture")
        let cacheBytes = await BrowserCacheService.currentSizeInBytes()
        print("PERF cache: estimated_bytes=\(cacheBytes), snapshot_directory=ApplicationSupport/SouloTabSnapshots")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Resource policy condition timed out")
        throw CancellationError()
    }
}

private final class WallpaperHeldRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: WallpaperSwitchProtocol] = [:]
    func store(_ request: WallpaperSwitchProtocol, host: String) { lock.withLock { requests[host] = request } }
    func request(host: String) -> WallpaperSwitchProtocol? { lock.withLock { requests[host] } }
}

private final class WallpaperSwitchProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((WallpaperSwitchProtocol) -> Void)?
    static func setHandler(_ value: ((WallpaperSwitchProtocol) -> Void)?) { lock.withLock { handler = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        handler?(self)
    }
    override func stopLoading() {}
    func respond(json: String) { respond(data: Data(json.utf8), mime: "application/json") }
    func respond(data: Data, status: Int = 200, mime: String) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
