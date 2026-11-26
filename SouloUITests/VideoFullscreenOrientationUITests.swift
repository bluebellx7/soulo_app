import XCTest

final class VideoFullscreenOrientationUITests: XCTestCase {
    @MainActor
    func testWebToolsImmediateExitRestoresBrowserOrientation() async throws {
        continueAfterFailure = false
        let landscape = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }

        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let page = """
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <h1>Web tools orientation</h1>
            <video src="/clip.mp4" controls preload="auto" playsinline loop style="width:100%;max-height:55vh"></video>
            """
        let server = try DownloadPlaybackHTTPFixture(files: ["/first.html": Data(page.utf8),
            "/second.html": Data(page.utf8), "/clip.mp4": try Data(contentsOf: fixture)])
        let root = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }

        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-restore_last_page_on_launch", "NO", "-icloud_sync_enabled", "NO", "-is_incognito", "NO",
            "-video.showsWebTools", "YES", "-ad_block_enabled", "NO", "-review.requestedOnce", "YES"]
        app.launch()
        defer { app.terminate() }

        let player = app.otherElements["media.mkv.fullscreen.player"].firstMatch
        let close = app.buttons["media.mkv.fullscreen.close"].firstMatch
        let heading = app.webViews.staticTexts["Web tools orientation"].firstMatch
        for path in ["first.html", "second.html"] {
            var route = URLComponents(string: "soulo://open")!
            route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent(path).absoluteString)]
            app.open(try XCTUnwrap(route.url))
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertEqual(app.frame.width > app.frame.height, landscape)
            tools.tap()
            let play = app.webViews.buttons["Fullscreen"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 5), app.debugDescription)
            play.tap()
            XCTAssertTrue(player.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<2 {
                try await revealControls(player: player, close: close)
                let frame = close.frame
                let window = app.frame
                if !frame.isEmpty {
                    // Use the visible position before control auto-hide can race XCTest's lookup.
                    app.coordinate(withNormalizedOffset: .zero).withOffset(
                        CGVector(dx: frame.midX - window.minX, dy: frame.midY - window.minY)
                    ).tap()
                }
                if player.waitForNonExistence(timeout: 1) { break }
            }
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !player.exists && heading.isHittable && (app.frame.width > app.frame.height) == landscape
            }, object: nil)], timeout: 8)
            // UIKit may deliver the player's pending geometry request after the browser reappears.
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(app.frame.width > app.frame.height, landscape)
        }
    }

    @MainActor
    func testNativeFullscreenRepeatedAndImmediateExitRestoresPortrait() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let filename = "orientation-\(UUID().uuidString).mp4"
        let server = try DownloadPlaybackHTTPFixture(files: ["/" + filename: try Data(contentsOf: fixture)])
        let root = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-video.defaultPlayer", "system",
            "-restore_last_page_on_launch", "NO", "-icloud_sync_enabled", "NO", "-is_incognito", "NO"]
        app.launch()
        defer { app.terminate() }
        var route = URLComponents()
        // This regression starts from the saved file. Keep WebKit page
        // readiness out of the repeated orientation and dismissal assertions.
        route.scheme = "soulo"; route.host = "download"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent(filename).absoluteString)]
        app.open(try XCTUnwrap(route.url))
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
