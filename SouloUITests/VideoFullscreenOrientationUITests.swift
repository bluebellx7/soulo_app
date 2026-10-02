import XCTest

final class VideoFullscreenOrientationUITests: XCTestCase {
    @MainActor
    func testNativeFullscreenRepeatedAndImmediateExitRestoresPortrait() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let filename = "orientation-\(UUID().uuidString).mp4"
        let page = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><a href='/clip.mp4' download>Download orientation fixture</a></body></html>"
        let server = try DownloadPlaybackHTTPFixture(
            files: ["/page.html": Data(page.utf8), "/clip.mp4": try Data(contentsOf: fixture)],
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
        let download = app.webViews.links["Download orientation fixture"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 20), app.debugDescription)
        download.tap()
        let status = app.buttons["browser.downloadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        status.tap()
        server.releaseDownloads()
        let completed = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "downloads.open.", filename)).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 15), app.debugDescription)
        completed.tap()
        let fullscreen = app.buttons["media.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 10), app.debugDescription)
        let repeatOne = app.buttons["Repeat one"]
        XCTAssertTrue(repeatOne.waitForExistence(timeout: 5), app.debugDescription)
        repeatOne.tap()
        for iteration in 0..<4 {
            fullscreen.tap()
            let player = app.otherElements["media.fullscreen.player"]
            XCTAssertTrue(player.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["media.fullscreen.close"].exists, "AVKit already owns the close button")
            XCTAssertFalse(app.buttons["media.rotate"].exists, "Rotation must not float above native controls")
            let closeQuery = player.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Done", "关闭", "完成"]))
            let close = closeQuery.firstMatch
            // The first exit exercises dismissal while entry geometry is still
            // changing. Later iterations verify an established landscape session.
            if iteration > 0 {
                await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    app.frame.width > app.frame.height
                }, object: nil)], timeout: 8)
            }
            let revealed = try await revealControls(player: player, close: close)
            XCTAssertTrue(revealed, app.debugDescription)
            XCTAssertEqual(closeQuery.count, 1)
            if iteration == 1 {
                let visible = XCTAttachment(screenshot: app.screenshot())
                visible.name = "fullscreen-native-controls-visible"; visible.lifetime = .keepAlways; add(visible)
                await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !close.exists && player.exists
                }, object: nil)], timeout: 10)
                let hidden = XCTAttachment(screenshot: app.screenshot())
                hidden.name = "fullscreen-all-controls-hidden"; hidden.lifetime = .keepAlways; add(hidden)
                let revealedAgain = try await revealControls(player: player, close: close)
                XCTAssertTrue(revealedAgain, app.debugDescription)
            }
            close.tap()
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.height > app.frame.width && !player.exists && fullscreen.exists
            }, object: nil)], timeout: 8)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "fullscreen-exit-restored-portrait"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    private func revealControls(player: XCUIElement, close: XCUIElement) async throws -> Bool {
        // AVKit may fade between a snapshot and waitForExistence's first
        // one-second poll. Reveal only when hidden, then check immediately.
        for _ in 0..<3 {
            if close.exists { return true }
            player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            try await Task.sleep(for: .milliseconds(150))
        }
        return close.exists
    }
}
