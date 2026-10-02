import XCTest

final class DownloadPlaybackUITests: XCTestCase {
    @MainActor
    func testDownloadingVideoLinkOpensPlayerAndDownloadFinishes() async throws {
        continueAfterFailure = false
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><h2>Concurrent video download</h2><video src='/clip.mp4' controls autoplay loop playsinline style='width:100%'></video></body></html>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/clip.mp4": try Data(contentsOf: video)])
        let root = try await server.start()
        defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        var route = URLComponents()
        route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 20), app.debugDescription)
        tools.tap()
        let download = app.webViews.buttons["Download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), app.debugDescription)
        download.tap()
        let status = app.buttons["browser.downloadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        status.tap()
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.playWhileDownloading.")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(link.label, "Play while downloading")
        let rowShot = XCTAttachment(screenshot: app.screenshot())
        rowShot.name = "download-row-play-while-downloading"; rowShot.lifetime = .keepAlways; add(rowShot)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.otherElements["media.preview"].waitForExistence(timeout: 10), app.debugDescription)
        let position = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), app.debugDescription)
        let before = position.value as? String
        let advance = NSPredicate { _, _ in (position.value as? String) != before }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: advance, object: nil)], timeout: 8)
        let playerShot = XCTAttachment(screenshot: app.screenshot())
        playerShot.name = "download-in-progress-native-player"; playerShot.lifetime = .keepAlways; add(playerShot)
        let received = server.downloadedBytes
        let continued = NSPredicate { _, _ in server.downloadedBytes > received }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: continued, object: nil)], timeout: 5)
        server.releaseDownloads()
        XCTAssertTrue(app.buttons["downloads.completion-toast"].waitForExistence(timeout: 15), app.debugDescription)
    }
}
