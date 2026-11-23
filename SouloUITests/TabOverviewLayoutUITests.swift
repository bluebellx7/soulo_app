import XCTest

@MainActor
final class TabOverviewLayoutUITests: XCTestCase {
    func testManyTabsCanScrollCollapseAndReopenGroups() async throws {
        continueAfterFailure = false
        let files = Dictionary(uniqueKeysWithValues: (0..<36).map { index in
            ("/many-\(index)", Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>Many tabs \(index)</title><body style='background:linear-gradient(#263974,#f4d1a3);min-height:1600px'><h1>Many tabs \(index)</h1><p>Saved page preview</p><a target='_blank' href='/many-\(index + 1)'>Open next tab</a></body>".utf8))
        })
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-is_incognito", "YES",
            "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
            "-browser_toolbar_hidden", "NO", "-tab_overview_grouped", "YES", "-keep_fullscreen_browsing", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(root.appendingPathComponent("many-0"))
        for index in 0..<36 {
            XCTAssertTrue(app.webViews.staticTexts["Many tabs \(index)"].firstMatch.waitForExistence(timeout: 8))
            if index < 35 { app.webViews.links["Open next tab"].firstMatch.tap() }
        }
        app.buttons["browser.tabs"].tap()
        let done = app.buttons["tabs.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let groups = app.scrollViews["tabs.groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        for _ in 0..<5 { groups.swipeUp(velocity: .fast) }
        for _ in 0..<5 { groups.swipeDown(velocity: .fast) }
        XCTAssertTrue(done.isHittable, "Scrolling dozens of previews must leave the app responsive")
        let header = app.buttons["tabs.group.host:127.0.0.1"]
        let row = app.descendants(matching: .any)["tabs.group-row.host:127.0.0.1"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 3)); XCTAssertTrue(row.exists)
        XCTAssertTrue(app.staticTexts["36"].exists, "All fixture pages must be separate tabs in the same group")
        header.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        capture(app, "many-tabs-group-collapsed")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        let tabs = app.buttons["browser.tabs"]
        // iOS 16 can retain a stale AX hit point after the overlay fades out.
        // Tap the visible control's frame, then verify the actual reopened view.
        XCTAssertTrue(tabs.exists); XCTAssertTrue(app.frame.intersects(tabs.frame))
        tabs.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5)); XCTAssertFalse(row.exists)
        header.tap(); XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "many-tabs-group-expanded")
        app.buttons["tabs.view-mode"].tap()
        let position = app.sliders["tabs.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5), "The fixture must contain more than 20 separate tabs")
        for value in [0.9, 0.2, 1.0, 0.0] { position.adjust(toNormalizedSliderPosition: value) }
        done.tap()
        XCTAssertTrue(app.webViews.staticTexts["Many tabs 35"].firstMatch.waitForExistence(timeout: 8))
    }

    func testLayoutSwitchUpdatesImmediatelyAndPersistsWhenReopened() async throws {
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: ["/mode": Data("<title>Tab mode QA</title><h1>Tab mode QA</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO", "-icloud_sync_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(root.appendingPathComponent("mode"))
        XCTAssertTrue(app.webViews.staticTexts["Tab mode QA"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["browser.tabs"].tap()
        let mode = app.buttons["tabs.view-mode"], groups = app.descendants(matching: .any)["tabs.groups"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        let initial = groups.exists
        func expectGrouped(_ expected: Bool) {
            let predicate = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in groups.exists == expected }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [predicate], timeout: 1.5), .completed, "The visible layout must change on the first tap")
        }
        mode.tap(); expectGrouped(!initial)
        capture(app, "tab-layout-first-tap")
        mode.tap(); expectGrouped(initial)
        mode.tap(); expectGrouped(!initial)
        app.buttons["tabs.done"].tap()
        app.buttons["browser.tabs"].tap(); expectGrouped(!initial)
        mode.tap(); expectGrouped(initial)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func assertDockFits(_ app: XCUIApplication, aboveKeyboard: Bool = false) {
        let bounds = app.frame
        let bottom = aboveKeyboard ? app.keyboards.firstMatch.frame.minY : bounds.maxY
        for id in ["tabs.view-mode", "tabs.browser_home", "tabs.options", "tabs.done", "tabs.tab_restore_last"] {
            let button = app.buttons[id]
            if id == "tabs.tab_restore_last" && !button.exists { continue }
            XCTAssertTrue(button.isHittable, id)
            XCTAssertGreaterThanOrEqual(button.frame.minX, bounds.minX, id)
            XCTAssertLessThanOrEqual(button.frame.maxX, bounds.maxX, id)
            XCTAssertLessThanOrEqual(button.frame.maxY, bottom - 12, "The entire dock must remain visible: " + id)
        }
    }

    func testDockFitsInBothLayoutsAfterRotationAndWhileSearching() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let server = try DownloadPlaybackHTTPFixture(files: ["/overview": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>Overview layout QA</title><h1>Overview layout QA</h1>".utf8)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-is_incognito", "NO",
            "-wallpaper_source", "gradient", "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO",
            "-review.requestedOnce", "YES", "-browser_toolbar_hidden", "NO", "-tab_overview_grouped", "NO",
            "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(root.appendingPathComponent("overview"))
        XCTAssertTrue(app.webViews.staticTexts["Overview layout QA"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(app.buttons["tabs.done"].waitForExistence(timeout: 5))
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "tabs.card.", "Overview layout QA")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 3))
        XCTAssertTrue(card.isSelected)
        let search = app.textFields["tabs.search"]
        XCTAssertLessThan(search.frame.minY - app.frame.minY, 102)
        card.press(forDuration: 0.8)
        let close = app.buttons["Close Tab"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let undo = app.buttons["tabs.tab_restore_last"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3)); assertDockFits(app)
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        app.buttons["tabs.done"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Overview layout QA"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        capture(app, "overview-portrait-carousel"); assertDockFits(app)
        app.buttons["tabs.view-mode"].tap()
        capture(app, "overview-portrait-grouped"); assertDockFits(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        await fulfillment(of: [landscape], timeout: 5)
        try await Task.sleep(for: .milliseconds(500))
        capture(app, "overview-landscape-grouped"); assertDockFits(app)
        app.buttons["tabs.view-mode"].tap()
        capture(app, "overview-landscape-carousel"); assertDockFits(app)
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
        await fulfillment(of: [portrait], timeout: 5)
        try await Task.sleep(for: .milliseconds(500))
        search.tap(); search.typeText("Overview layout")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        capture(app, "overview-with-search-keyboard"); assertDockFits(app, aboveKeyboard: true)
        app.buttons["tabs.done"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Overview layout QA"].firstMatch.waitForExistence(timeout: 5))
    }
}
