import UIKit
import XCTest

@MainActor
final class WebImageGalleryUITests: XCTestCase {
    func testLongPressImagePagesZoomsAndOpensWebResources() async throws {
        continueAfterFailure = false
        func png(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320)).image { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            }.pngData()!
        }
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>body{margin:12px}img{display:block;width:280px;height:180px;margin-bottom:12px}</style>
        <img src='/one.png' alt='First poster'><img src='/two.png' alt='Second poster'><img src='/three.png' alt='Third poster'>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/gallery": Data(html.utf8), "/one.png": png(.systemPurple), "/two.png": png(.systemBlue), "/three.png": png(.systemPink)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("gallery").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let poster = app.webViews.images["Second poster"].firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15), app.debugDescription)
        poster.press(forDuration: 0.8)
        let viewImage = app.buttons["View Image"].firstMatch
        XCTAssertTrue(viewImage.waitForExistence(timeout: 5), app.debugDescription); viewImage.tap()
        let position = app.staticTexts["browser.imagePreview.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(position.label, "2 / 3")
        var surface = app.scrollViews["image.zoomSurface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10), app.debugDescription)
        surface.swipeLeft()
        let third = NSPredicate(format: "label == %@", "3 / 3")
        await fulfillment(of: [expectation(for: third, evaluatedWith: position)], timeout: 5)
        surface = app.scrollViews["image.zoomSurface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        surface.doubleTap()
        let zoom = NSPredicate(format: "value != %@", "100%")
        await fulfillment(of: [expectation(for: zoom, evaluatedWith: surface)], timeout: 5)
        surface.doubleTap()
        await fulfillment(of: [expectation(for: NSPredicate(format: "value == %@", "100%"), evaluatedWith: surface)], timeout: 5)
        surface.swipeRight()
        await fulfillment(of: [expectation(for: NSPredicate(format: "label == %@", "2 / 3"), evaluatedWith: position)], timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "web-image-gallery"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["browser.imagePreview.resources"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Web Resources"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["resources.images.select"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
    }
}
