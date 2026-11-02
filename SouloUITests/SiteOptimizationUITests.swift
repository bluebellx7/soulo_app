import XCTest
import UIKit

@MainActor
final class SiteOptimizationUITests: XCTestCase {
    private func openPlugin(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let extensions = app.buttons["Scripts & Extensions"].firstMatch
        for _ in 0..<10 {
            if extensions.exists && extensions.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(extensions.waitForExistence(timeout: 5), app.debugDescription)
        extensions.tap()
        let toggle = app.switches["extensions.site-plugin.baidu-search"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        return toggle
    }
    func testBuiltInPluginDefaultsOffAndChoicePersistsAcrossLaunches() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US"]
        app.launch(); app.open(URL(string: "soulo://")!)
        let toggle = openPlugin(app)
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["extensions.site-script.details.baidu-search"].firstMatch.tap()
        let source = app.descendants(matching: .any).matching(identifier: "userscripts.source").firstMatch
        for _ in 0..<7 { if source.exists { break }; app.swipeUp() }
        XCTAssertTrue(source.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Copy JavaScript"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Save"].exists, "The bundled script is viewable and read-only")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "baidu-plugin-in-extension-center"; attachment.lifetime = .keepAlways; add(attachment)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        let restored = openPlugin(app)
        XCTAssertEqual(restored.value as? String, "1")
        restored.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(restored.value as? String, "0")
    }
    func testInlineWebVideoKeepsNativeFullscreenUntilClosed() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Inline video fixture</h1><video controls autoplay muted loop playsinline src='/clip.mp4' style='width:100%;height:240px'></video>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/page":Data(html.utf8),"/clip.mp4":try Data(contentsOf: clip)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language","en-US","-privacy_https_upgrade_enabled","NO","-ad_block_enabled","NO"]
        app.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name:"url",value:root.appendingPathComponent("page").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 15), app.debugDescription)
        tools.tap()
        let fullscreen = app.webViews.buttons["Fullscreen"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5), app.debugDescription)
        fullscreen.tap()
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.frame.width > app.frame.height },object:nil)],timeout:8)
        try await Task.sleep(for:.milliseconds(1200))
        XCTAssertGreaterThan(app.frame.width,app.frame.height,"A page resize must not immediately restore portrait")
        let closeButtons = app.buttons.matching(NSPredicate(format: "label IN %@",["Done","Close","完成","关闭"]))
        var close: XCUIElement?
        for _ in 0..<4 {
            close = closeButtons.allElementsBoundByIndex.first { $0.isHittable }
            if close != nil { break }
            app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            try await Task.sleep(for:.milliseconds(180))
        }
        let nativeClose = try XCTUnwrap(close, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "inline-web-video-stays-landscape"; shot.lifetime = .keepAlways; add(shot)
        nativeClose.tap()
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.frame.height > app.frame.width },object:nil)],timeout:8)
    }

    func testLazyLaterVideoAndChangedSourceShowFramesInNativeFullscreen() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <h3>Later video fixture</h3>
        <button onclick="v.pause();const next=document.createElement('video');next.id='v';next.preload='none';next.muted=true;next.loop=true;next.playsInline=true;next.src='/clip.mp4';next.style.cssText='width:100%;height:220px';v.replaceWith(next)">Load later video</button>
        <button onclick="v.pause();v.src='/second.mp4'">Change source</button>
        <video id="v" autoplay muted loop playsinline src="/clip.mp4" style="width:100%;height:220px"></video>
        """
        let data = try Data(contentsOf: clip)
        let server = try DownloadPlaybackHTTPFixture(files: ["/page":Data(html.utf8),"/clip.mp4":data,"/second.mp4":data])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language","en-US","-privacy_https_upgrade_enabled","NO","-ad_block_enabled","NO","-is_incognito","YES"]
        app.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name:"url",value:root.appendingPathComponent("page").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        for action in ["Load later video", "Change source"] {
            let change = app.webViews.buttons[action].firstMatch
            XCTAssertTrue(change.waitForExistence(timeout:15),app.debugDescription)
            change.tap()
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout:5),app.debugDescription)
            tools.tap()
            let fullscreen = app.webViews.buttons["Fullscreen"].firstMatch
            XCTAssertTrue(fullscreen.waitForExistence(timeout:5),app.debugDescription)
            fullscreen.tap()
            await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.frame.width > app.frame.height },object:nil)],timeout:10)
            try await Task.sleep(for:.milliseconds(600))
            let screen = XCUIScreen.main.screenshot()
            XCTAssertGreaterThan(Self.coloredCenter(screen.image),0.65,"Fullscreen must fill the center with video pixels, not only a cropped corner or black AVKit controls")
            let attachment = XCTAttachment(screenshot:screen)
            attachment.name = "web-fullscreen-\(action)"; attachment.lifetime = .keepAlways; add(attachment)
            let closeButtons = app.buttons.matching(NSPredicate(format:"label IN %@",["Done","Close","完成","关闭"]))
            var close: XCUIElement?
            for _ in 0..<4 {
                close = closeButtons.allElementsBoundByIndex.first { $0.isHittable }
                if close != nil { break }
                app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)).tap()
                try await Task.sleep(for:.milliseconds(150))
            }
            try XCTUnwrap(close,app.debugDescription).tap()
            await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.frame.height > app.frame.width },object:nil)],timeout:8)
        }
    }

    private static func coloredCenter(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating:0,count:64*64*4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:64,height:64,bitsPerComponent:8,bytesPerRow:64*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage,in:CGRect(x:0,y:0,width:64,height:64))
            return true
        }
        guard rendered else { return 0 }
        var colored = 0
        for y in 16..<48 { for x in 16..<48 {
            let offset = (y*64+x)*4
            let values = [pixels[offset],pixels[offset+1],pixels[offset+2]]
            if values.max()! > 32 { colored += 1 }
        }}
        return Double(colored)/1024
    }
}
