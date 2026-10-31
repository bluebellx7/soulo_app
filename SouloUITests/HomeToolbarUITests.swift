import XCTest

@MainActor
final class HomeToolbarUITests: XCTestCase {
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.homeToolbar"]
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
    }
    func testFiveHomeShortcutsPersistAndOpenTheirPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        openSettings(app)
        let actions = ["downloads", "files", "bookmarks", "history", "wallpaper"]
        for (index, action) in actions.enumerated() {
            app.buttons["home-toolbar.slot.\(index)"].tap()
            app.buttons["home-toolbar.action.\(action)"].tap()
        }
        app.buttons["home-toolbar.save"].tap()
        app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "five-home-glass-shortcuts"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        for (index, section) in actions.prefix(4).enumerated() {
            let button = app.buttons["home.toolbar.\(index)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
            button.tap()
            let tab = app.buttons["library.section.\(section)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(tab.isSelected)
            app.navigationBars.buttons.firstMatch.tap()
        }
        let fifth = app.buttons["home.toolbar.4"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 5)); XCTAssertTrue(fifth.isHittable)
        XCTAssertGreaterThanOrEqual(fifth.frame.minX, 0)
        XCTAssertLessThanOrEqual(fifth.frame.maxX, app.frame.width)
        fifth.tap()
        XCTAssertTrue(app.navigationBars["Wallpaper"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        openSettings(app)
        app.buttons["Hide All"].firstMatch.tap()
        app.sheets.buttons["Hide All"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
        XCTAssertFalse(app.buttons["home.toolbar.4"].exists)
    }
}
