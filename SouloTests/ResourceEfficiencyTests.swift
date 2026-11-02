import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore
@testable import Soulo

@MainActor
final class ResourceEfficiencyTests: XCTestCase {
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
