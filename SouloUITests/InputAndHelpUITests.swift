import XCTest

@MainActor
final class InputAndHelpUITests: XCTestCase {
    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-is_incognito", "NO",
            "-wallpaper_source", "gradient", "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO",
            "-review.requestedOnce", "YES", "-browser_toolbar_hidden", "NO"] + extra
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func tapBlankBesideContent(_ app: XCUIApplication) {
        // Stay inside a presented iPad sheet: tapping outside a popover closes
        // the page, which is a different action from dismissing its keyboard.
        // A collection's center may be covered by the keyboard, so its
        // isHittable flag cannot determine which presentation owns the form.
        let navigation = app.navigationBars.allElementsBoundByIndex.last?.frame
        let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.frame.maxY
        let y = max((navigation?.maxY ?? app.frame.minY) + 24, min(app.frame.midY, keyboardTop - 20))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (navigation?.minX ?? app.frame.minX) + 2 - app.frame.minX,
                                 dy: y - app.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), app.debugDescription)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testHomeSearchClearsWithoutLosingFocusAndBlankTapDismissesKeyboard() {
        let app = launch(); defer { app.terminate() }
        let field = app.textFields["search.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Clear-QA")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["search.clear"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        field.typeText("Input-QA")
        tapBlankBesideContent(app)
        XCTAssertEqual(field.value as? String, "Input-QA")
    }

    func testDownloadSearchRowMatchesBookmarksAndBlankTapsDismissLibraryKeyboards() throws {
        let app = launch(); defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://downloads")))
        let field = app.textFields["library.search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let downloadRow = app.cells.containing(.textField, identifier: "library.search").firstMatch
        let downloadHeight = downloadRow.frame.height
        capture(app, name: "compact-download-search")
        field.tap(); field.typeText("NoMatching-QA")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["Clear search text"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clearing a query must retain keyboard focus")
        field.typeText("NoMatching-QA")
        tapBlankBesideContent(app)
        XCTAssertEqual(field.value as? String, "NoMatching-QA")
        app.buttons["library.section.bookmarks"].tap()
        let bookmark = app.textFields["favorites.search"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        let bookmarkHeight = app.cells.containing(.textField, identifier: "favorites.search").firstMatch.frame.height
        XCTAssertEqual(downloadHeight, bookmarkHeight, accuracy: 1, "Library search rows should have equal height")
        XCTAssertGreaterThanOrEqual(downloadHeight, 44, "Compact rows must retain a usable touch target")
        let measurement = XCTAttachment(string: "Download row: \(downloadHeight) pt; bookmark row: \(bookmarkHeight) pt")
        measurement.name = "search-row-heights"; measurement.lifetime = .keepAlways; add(measurement)
        bookmark.tap(); bookmark.typeText("Bookmark-QA")
        tapBlankBesideContent(app)
        app.buttons["favorites.manage"].tap()
        XCTAssertTrue(app.buttons["Reading list"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Show duplicates"].exists)
        capture(app, name: "compact-search-and-bookmark-menu")
    }

    func testKeyboardDismissalCoversSettingsAndTaskSheetsWithoutInterruptingFieldSwitching() throws {
        let app = launch(); defer { app.terminate() }
        openSettings(app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap(); search.typeText("Wallpaper")
        tapBlankBesideContent(app)
        XCTAssertEqual(search.value as? String, "Wallpaper")
        // iOS keeps searchable active after resigning the keyboard. Close that
        // search session before using the settings navigation bar.
        let closeSearch = app.buttons["关闭"]
        if closeSearch.exists { closeSearch.tap() }
        else if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.navigationBars["Settings"].buttons["Done"].tap()
        app.open(try XCTUnwrap(URL(string: "soulo://downloads")))
        XCTAssertTrue(app.buttons["downloads.new"].waitForExistence(timeout: 5)); app.buttons["downloads.new"].tap()
        let address = app.textFields["downloads.new.address"].exists ? app.textFields["downloads.new.address"] : app.textViews["downloads.new.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeText("https://example.com/qa.mp4")
        let name = app.textFields["downloads.new.filename"]
        name.tap(); name.typeText("QA")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(name.value as? String, "QA")
        address.tap(); address.typeText("?test=1")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        tapBlankBesideContent(app)
        XCTAssertTrue(app.buttons["downloads.new.create"].isEnabled)
        name.tap(); name.typeText(" copy")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(name.value as? String, "QA copy")
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["downloads.new"].waitForExistence(timeout: 5))
    }

    func testHelpOpensFromSettingsAndReturnsToSettings() {
        let app = launch(); defer { app.terminate() }
        openSettings(app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap(); search.typeText("Help")
        let help = app.buttons["Help Center"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 5)); help.tap()
        XCTAssertTrue(app.staticTexts["How can we help?"].waitForExistence(timeout: 5), app.debugDescription)
        capture(app, name: "help-opened-from-settings")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.help"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testHelpOpensFromHomeToolbarAndDoneClosesIt() {
        let app = launch(extra: ["-home_toolbar_actions", "(help)"])
        defer { app.terminate() }
        let help = app.buttons["home.toolbar.0"]
        XCTAssertTrue(help.waitForExistence(timeout: 10)); help.tap()
        XCTAssertTrue(app.staticTexts["How can we help?"].waitForExistence(timeout: 5))
        let done = app.navigationBars.buttons.matching(identifier: "Done")
        XCTAssertEqual(done.count, 1, "The help page must expose one unambiguous close action")
        capture(app, name: "help-opened-from-home")
        done.firstMatch.tap()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
    }
}
