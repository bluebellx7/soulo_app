import XCTest

@MainActor
final class FeatureGuidanceUITests: XCTestCase {
    private func launch(chineseDark: Bool = false, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", chineseDark ? "zh-Hans" : "en-US",
            "-appearance", chineseDark ? "dark" : "light", "-is_incognito", "NO",
            "-wallpaper_source", "gradient", "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO",
            "-review.requestedOnce", "YES", "-browser_toolbar_hidden", "NO"] + extra
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication, title: String = "Settings") {
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        app.buttons["home.menu"].tap()
        app.buttons[title].firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func searchSettings(_ app: XCUIApplication, query: String, destination: String) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if !search.isHittable { app.swipeDown() }
        search.tap()
        let value = search.value as? String ?? ""
        let previous = value == "Search" || value == "搜索" ? "" : value
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + query)
        let entry = app.buttons["settings." + destination]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFeatureDescriptionsAppearOnTheirOwnPagesAndControlsRemainReachable() throws {
        let app = launch(); defer { app.terminate() }
        openSettings(app)
        searchSettings(app, query: "Video", destination: "video")
        XCTAssertTrue(app.staticTexts["video-settings.explanation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["video-settings.tools"].isHittable)
        capture(app, name: "video-guidance-light")
        app.navigationBars.buttons.firstMatch.tap()
        searchSettings(app, query: "Backups", destination: "backups")
        XCTAssertTrue(app.staticTexts["settings.backups.explanation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.backups.save"].isHittable)
        capture(app, name: "backup-guidance-light")
        let clear = app.buttons["settings.backups.clear"]
        XCTAssertTrue(clear.exists)
        if clear.isEnabled {
            clear.tap()
            XCTAssertTrue(app.staticTexts["All local settings backups will be deleted. Your current settings will stay the same."].waitForExistence(timeout: 3))
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].firstMatch.tap() }
            else {
                // An anchored confirmation on iOS 26 can omit the cancel row.
                // Tapping outside cancels it without activating the destructive action.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.4)).tap()
            }
            XCTAssertTrue(app.buttons["settings.backups.confirm-clear"].waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["settings.backups.save"].exists)
            XCTAssertTrue(clear.isEnabled, "Cancel must keep existing backups")
        }
        app.navigationBars.buttons.firstMatch.tap()
        searchSettings(app, query: "Quick Actions", destination: "quickActions")
        XCTAssertTrue(app.staticTexts["quick-actions.explanation"].waitForExistence(timeout: 5))
        capture(app, name: "quick-action-guidance-light")
        // Open the real reading-list entry after dismissing Settings.
        app.navigationBars.buttons.firstMatch.tap()
        let closeSearch = app.buttons["关闭"]
        if closeSearch.exists { closeSearch.tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        app.navigationBars["Settings"].buttons["Done"].tap()
        app.open(try XCTUnwrap(URL(string: "soulo://bookmarks")))
        XCTAssertTrue(app.buttons["favorites.manage"].waitForExistence(timeout: 5))
        app.buttons["favorites.manage"].tap()
        app.buttons["Reading list"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["reading-list.explanation"].waitForExistence(timeout: 5))
        capture(app, name: "reading-list-guidance-light")
    }

    func testVideoDescriptionInChineseDarkModeKeepsTheSettingsAccessible() {
        let app = launch(chineseDark: true); defer { app.terminate() }
        openSettings(app, title: "设置")
        searchSettings(app, query: "视频", destination: "video")
        XCTAssertTrue(app.staticTexts["video-settings.explanation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["video-settings.tools"].isHittable)
        capture(app, name: "video-guidance-chinese-dark")
    }

    func testRetiredHelpEntryIsUnavailableAndOtherSavedToolbarSlotsStillOpen() {
        let app = launch(extra: ["-home_toolbar_actions", "(help,backups,quickActions,none,none)"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
        app.buttons["home.toolbar.1"].tap()
        XCTAssertTrue(app.staticTexts["settings.backups.explanation"].waitForExistence(timeout: 5))
        let done = app.navigationBars.buttons.matching(identifier: "Done")
        XCTAssertEqual(done.count, 1); done.firstMatch.tap()
        openSettings(app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap(); search.typeText("Help")
        XCTAssertFalse(app.buttons["settings.help"].exists)
        XCTAssertFalse(app.buttons["Help Center"].exists)
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 5))
    }

    func testWebsiteContentExtendsToBottomWhileNavigationAndToolbarStayVisible() {
        let app = launch(extra: ["-home_toolbar_actions", "(version)"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10))
        app.buttons["home.toolbar.0"].tap()
        XCTAssertTrue(app.buttons["version.website"].waitForExistence(timeout: 5))
        app.buttons["version.website"].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        _ = web.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Soulo")).firstMatch.waitForExistence(timeout: 15)
        capture(app, name: "website-bottom-safe-area")
        XCTAssertGreaterThanOrEqual(web.frame.maxY, app.frame.maxY - 2, "The website must fill the bottom safe area")
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
        XCTAssertTrue(app.buttons.matching(identifier: "More").allElementsBoundByIndex.contains { $0.isHittable },
                      "The website's toolbar must remain usable above the home indicator")
    }
}
