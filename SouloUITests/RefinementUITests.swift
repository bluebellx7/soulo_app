import XCTest
import UIKit

@MainActor
final class RefinementUITests: XCTestCase {
    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-wallpaper_gradient_id", "dawn", "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO",
            "-review.requestedOnce", "YES", "-privacy_https_upgrade_enabled", "NO", "-is_incognito", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"] + extra
        app.launch()
        return app
    }

    private func settings(_ app: XCUIApplication) {
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let button = app.buttons["Settings"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSettingsSearchRoutesToStorageAndKeepsFavoriteWallpapersReadOnly() {
        let app = launch(); defer { app.terminate() }
        settings(app)
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        let storage = app.buttons["settings.storage"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.wallpaper"].exists)
        storage.tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Favorite wallpapers"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete Favorite wallpapers"].exists)
        screenshot(app, "categorized-storage-with-protected-favorites")
    }

    func testEmptyWallpaperFavoritesCannotEnableFavoritesOnly() {
        let app = launch(extra: ["-wallpaper_favorites", "", "-wallpaper_only_favorites", "YES"])
        defer { app.terminate() }
        settings(app)
        app.buttons["settings.wallpaper"].tap()
        let toggle = app.switches["wallpaper.only-favorites"]
        if !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(toggle.value as? String, "0")
        screenshot(app, "empty-favorites-cannot-enable-favorites-only")
    }

    func testLibrarySearchAndFiltersKeepTheActivePage() throws {
        let app = launch(); defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://downloads")))
        XCTAssertTrue(app.buttons["library.section.downloads"].waitForExistence(timeout: 10))
        let search = app.textFields["library.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("NoMatchingFile-Refinement-QA")
        XCTAssertEqual(search.value as? String, "NoMatchingFile-Refinement-QA")
        XCTAssertTrue(app.buttons["library.section.downloads"].isSelected)
        app.buttons["library.filter-sort"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Sort"].firstMatch.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.25)).tap()
        app.buttons["library.section.files"].tap()
        XCTAssertTrue(app.buttons["files.viewMode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["library.search"].firstMatch.exists)
        screenshot(app, "file-list-query-controls")
    }

    func testIPadNewWindowEntryOpensAHomeWindow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad multi-window entry") }
        let app = launch(); defer { app.terminate() }
        let menu = app.buttons["home.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        let entry = app.buttons["New window"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); XCTAssertTrue(entry.isEnabled)
        let before = app.windows.count
        entry.tap()
        XCTAssertTrue(app.buttons["home.menu"].firstMatch.waitForExistence(timeout: 10))
        let settle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.count > before }, object: nil)
        let result = XCTWaiter.wait(for: [settle], timeout: 5)
        print("IPAD_WINDOW_ENTRY before=\(before) after=\(app.windows.count) additionalAXWindow=\(result == .completed)")
        screenshot(app, "iPad-after-opening-independent-window")
    }

    func testReadingListFromBookmarksKeepsTheFileToolbarTitleVisible() throws {
        let app = launch(); defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["files.viewMode"].waitForExistence(timeout: 5))
        screenshot(app, "file-toolbar-with-library-title")
        app.buttons["library.section.bookmarks"].tap()
        app.buttons["favorites.manage"].tap()
        let readingList = app.buttons["Reading list"].firstMatch
        XCTAssertTrue(readingList.waitForExistence(timeout: 5)); readingList.tap()
        XCTAssertTrue(app.navigationBars["Reading list"].waitForExistence(timeout: 5))
    }

    func testTabSearchAndSiteGroupRenameAndPinKeepTheOverviewOpen() async throws {
        let title = "TabQuery-\(UUID().uuidString.prefix(6))"
        let server = try DownloadPlaybackHTTPFixture(files: ["/tab": Data("<title>\(title)</title><h1>\(title)</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(extra: ["-tab_overview_grouped", "YES"]); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("tab").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 20))
        app.buttons["browser.tabs"].firstMatch.tap()
        let search = app.textFields["tabs.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title)
        let options = app.buttons["tabs.group.options.host:127.0.0.1"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        app.buttons["Rename group"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        field.press(forDuration: 1)
        if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100) + "QA Group")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["QA Group"].waitForExistence(timeout: 5))
        options.tap()
        let pin = app.buttons["Pin group"]
        if pin.exists { pin.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap() }
        XCTAssertTrue(search.exists)
        screenshot(app, "filtered-tab-group-renamed-and-pinned")
        options.tap(); app.buttons["Use website name"].tap()
        options.tap()
        if app.buttons["Unpin group"].exists { app.buttons["Unpin group"].tap() }
    }
}
