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
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-video.defaultPlayer", "system",
            "-restore_last_page_on_launch", "NO", "-icloud_sync_enabled", "NO"]
        app.launch()
        defer { app.terminate() }
        var route = URLComponents()
        route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let download = app.webViews.links["Download orientation fixture"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 20), app.debugDescription)
        download.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.receivedRequests.contains { $0.path == "/clip.mp4" }
        }, object: nil)], timeout: 10)
        server.releaseDownloads()
        app.open(try XCTUnwrap(URL(string: "soulo://downloads")))
        let completed = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "downloads.open.", filename)).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 15), app.debugDescription)
        let player = app.otherElements["media.mkv.fullscreen.player"]
        let close = app.buttons["media.mkv.fullscreen.close"]
        for iteration in 0..<4 {
            completed.tap()
            XCTAssertTrue(player.waitForExistence(timeout: 8), app.debugDescription)
            try await revealControls(player: player, close: close)
            // Close the first presentation immediately. Later iterations also
            // verify that leaving an established landscape player restores portrait.
            if iteration > 0 {
                if app.frame.width < app.frame.height { app.buttons["media.fullscreen.rotate"].tap() }
                await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    app.frame.width > app.frame.height
                }, object: nil)], timeout: 8)
                try await revealControls(player: player, close: close)
            }
            XCTAssertEqual(app.buttons.matching(identifier: "media.mkv.fullscreen.close").count, 1)
            for _ in 0..<2 {
                try await revealControls(player: player, close: close)
                let buttonFrame = close.frame
                let appFrame = app.frame
                if !buttonFrame.isEmpty {
                    // Target the visible control before XCTest's element
                    // lookup can race the player's automatic hide animation.
                    app.coordinate(withNormalizedOffset: .zero).withOffset(
                        CGVector(dx: buttonFrame.midX - appFrame.minX, dy: buttonFrame.midY - appFrame.minY)
                    ).tap()
                }
                if player.waitForNonExistence(timeout: 1) { break }
            }
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.height > app.frame.width && !player.exists && completed.isHittable
            }, object: nil)], timeout: 8)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "fullscreen-exit-restored-portrait"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    private func revealControls(player: XCUIElement, close: XCUIElement) async throws {
        for _ in 0..<3 {
            if close.isHittable { return }
            player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTAssertTrue(close.isHittable, player.debugDescription)
    }
}
