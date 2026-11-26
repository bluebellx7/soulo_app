import XCTest

final class BackgroundDownloadUITests: XCTestCase {
    @MainActor
    func testWebsiteVideoFinishesWhileVisitingSettingsAndLibrary() async throws {
        continueAfterFailure = false
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let filename = "settings-download-\(UUID().uuidString.prefix(8)).mp4"
        let path = "/" + filename
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><a href='\(path)' download>Download video</a>"
        let server = try DownloadPlaybackHTTPFixture(
            files: ["/page.html": Data(html.utf8), path: try Data(contentsOf: video)],
            responseHeaders: [path: ["Content-Disposition": "attachment; filename=\(filename)"]],
            slowChunkSize: 128
        )
        let root = try await server.start()
        defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        defer { app.terminate() }
        var route = URLComponents()
        route.scheme = "soulo"
        route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let link = app.webViews.links["Download video"]
        XCTAssertTrue(link.waitForExistence(timeout: 20), app.debugDescription)
        link.tap()
        let status = app.buttons["browser.downloadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["browser.more"].tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.wallpaper"].waitForExistence(timeout: 8), app.debugDescription)
        let receivedInSettings = server.downloadedBytes
        let transferAdvanced = NSPredicate { _, _ in server.downloadedBytes > receivedInSettings }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: transferAdvanced, object: nil)], timeout: 5)
        XCTAssertEqual(app.state, .runningForeground)
        app.navigationBars.buttons["Done"].firstMatch.tap()
        status.tap()
        XCTAssertTrue(app.staticTexts[filename].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["library.section.files"].tap()
        server.releaseDownloads()
        app.buttons["library.section.downloads"].tap()
        let completed = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "downloads.open.", filename)).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 20), app.debugDescription)
    }

    @MainActor
    func testWebsiteAttachmentContinuesAfterHome() async throws {
        continueAfterFailure = false
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let filename = "background-\(UUID().uuidString).mp4"
        let html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><a href='/clip.mp4' download>Download attachment</a></body></html>"
        let server = try DownloadPlaybackHTTPFixture(
            files: ["/page.html": Data(html.utf8), "/clip.mp4": try Data(contentsOf: video)],
            responseHeaders: ["/clip.mp4": ["Content-Disposition": "attachment; filename=\(filename)"]]
        )
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
        let link = app.webViews.links["Download attachment"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), app.debugDescription)
        link.tap()
        let status = app.buttons["browser.downloadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        let keepOpenNotice = "Keep Soulo open while downloading"
        XCTAssertFalse(status.label.contains(keepOpenNotice))
        status.tap()
        XCTAssertTrue(app.staticTexts[filename].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts[keepOpenNotice].exists)
        // Keep Soulo backgrounded well beyond the ordinary suspension delay.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        let before = server.downloadedBytes
        try await Task.sleep(for: .seconds(12))
        XCTAssertGreaterThan(server.downloadedBytes, before)
        XCTAssertEqual(app.state, .runningBackground)
        server.releaseDownloads()
        try await Task.sleep(for: .seconds(8))
        app.activate()
        let completed = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "downloads.open.", filename)).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 15), app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "website-download-finished-after-background"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
