import XCTest
import UIKit

@MainActor
final class HomeColdStartUITests: XCTestCase {
    func testIPadEightHomeActionsStayNarrowerThanSearchBox() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad toolbar layout") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language","en-US","-appearance","light","-wallpaper_source","gradient","-home_title","Soulo","-home_subtitle","","-icloud_sync_enabled","NO","-review.requestedOnce","YES","-home_toolbar_actions","(settings,files,downloads,tabs,bookmarks,extensions,wallpaper,history)"]
        app.launch(); defer { app.terminate() }
        let box = app.otherElements["home.search.field"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        let actions = (0..<8).map { app.buttons["home.toolbar.\($0)"] }
        for action in actions { XCTAssertTrue(action.exists); XCTAssertTrue(action.isHittable) }
        let left = try XCTUnwrap(actions.map { $0.frame.minX }.min())
        let right = try XCTUnwrap(actions.map { $0.frame.maxX }.max())
        XCTAssertLessThan(right-left, box.frame.width)
        XCTAssertGreaterThan(left, box.frame.minX); XCTAssertLessThan(right, box.frame.maxX)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "ipad-eight-home-toolbar-actions"; image.lifetime = .keepAlways; add(image)
    }

    func testColdMenu() { check("menu") }
    func testColdSettings() { check("settings") }
    func testColdFiles() { check("files") }
    func testColdDownloads() { check("downloads") }
    func testColdTabs() { check("tabs") }
    func testColdSearch() { check("search") }

    func testClosingAllAndLastTabReturnsToHome() {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        app.launchArguments=["-app_language","en-US","-appearance","light","-wallpaper_source","gradient",
            "-keep_screen_awake","YES","-icloud_sync_enabled","NO","-review.requestedOnce","YES",
            "-home_toolbar_actions","(tabs)","-tab_overview_grouped","NO"]
        app.launch();defer{app.terminate()}
        let tabs=app.buttons["home.toolbar.0"]
        XCTAssertTrue(tabs.waitForExistence(timeout:10));tabs.tap()
        let options=app.buttons["tabs.options"]
        XCTAssertTrue(options.waitForExistence(timeout:5));options.tap()
        let closeAll=app.buttons["tabs.close-all"]
        XCTAssertTrue(closeAll.waitForExistence(timeout:5));closeAll.tap()
        let hidden=NSPredicate(format:"exists == false")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:hidden,object:options)],timeout:5),.completed)
        XCTAssertTrue(app.buttons["home.menu"].isHittable,"Closing all must reveal the actual home, not an empty browser or card")
        tabs.tap()
        let card=app.descendants(matching:.any).matching(identifier:"tabs.card.placeholder").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout:5))
        // The card is one accessible item with a named close action. Exercise
        // the real visible X hit target rather than its select/open action.
        card.coordinate(withNormalizedOffset:CGVector(dx:1,dy:0)).withOffset(CGVector(dx:-26,dy:22)).tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:hidden,object:options)],timeout:5),.completed)
        XCTAssertTrue(app.buttons["home.menu"].isHittable)
        let image=XCTAttachment(screenshot:app.screenshot());image.name="last-tab-returns-home";image.lifetime = .keepAlways;add(image)
    }

    func testRemovingHomeBrandingKeepsSearchPosition() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        let base = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
            "-home_toolbar_actions", "(settings,files,downloads,tabs)",
            "-show_bookmarks_on_home", "NO", "-show_group_picker_on_home", "NO", "-show_recent_searches_on_home", "NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_HISTORY"] = "1"
        app.launchArguments = base + ["-home_title", "Soulo", "-home_subtitle", "Search Everything Everywhere"]
        app.launch()
        let query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        let before = query.frame
        let area = app.scrollViews["home.search.area"]
        XCTAssertTrue(area.exists)
        let searchBox = app.otherElements["home.search.field"]
        XCTAssertTrue(searchBox.exists)
        XCTAssertEqual(before.midY, area.frame.midY - searchBox.frame.height / 2, accuracy: 3, "Place the field half its visible box height above the usable area's center")
        app.terminate()
        app.launchArguments = base + ["-home_title", "", "-home_subtitle", ""]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        XCTAssertEqual(query.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(query.frame.height, before.height, accuracy: 1)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Edit title")).firstMatch.exists)
        app.terminate()
        app.launchArguments = base + ["-home_title", "", "-home_subtitle", "", "-show_group_picker_on_home", "YES", "-show_bookmarks_on_home", "YES", "-show_recent_searches_on_home", "YES"]
        app.launch()
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        XCTAssertEqual(query.frame.midY, before.midY, accuracy: 3, "Rows below the field must not shift its anchor")
        let recentTitle = app.staticTexts["home.recent.title"], terms = app.otherElements["home.recent.terms"]
        XCTAssertTrue(recentTitle.waitForExistence(timeout: 5)); XCTAssertTrue(terms.exists)
        XCTAssertEqual(recentTitle.frame.minX, searchBox.frame.minX, accuracy: 2)
        XCTAssertEqual(terms.frame.minX, searchBox.frame.minX, accuracy: 2)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "home-without-branding-stable-search"; image.lifetime = .keepAlways; add(image)
        query.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    private func check(_ action: String) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        let wallpaper = ProcessInfo.processInfo.environment["SOULO_HOME_TEST_WALLPAPER"] == "photo" ? "photo" : "gradient"
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", wallpaper,
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-ad_block_enabled", "YES",
            "-home_toolbar_actions", "(\(action == "menu" ? "settings" : action))"]
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        let started = ProcessInfo.processInfo.systemUptime
        app.launch(); defer { app.terminate() }
        let entry = app.buttons[action == "menu" ? "home.menu" : "home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        let tapping = ProcessInfo.processInfo.systemUptime
        entry.tap()
        let destination: XCUIElement
        switch action {
        case "menu": destination = app.buttons["Settings"].firstMatch
        case "settings": destination = app.searchFields.firstMatch
        case "files", "downloads": destination = app.buttons["library.section.\(action)"]
        case "tabs": destination = app.buttons["tabs.done"]
        default: destination = app.keyboards.firstMatch
        }
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
        if action == "menu", wallpaper == "photo" {
            XCTAssertTrue(app.buttons["home.wallpaper.download"].exists, "The photo must actually be loaded, not its fallback")
        }
        let finished = ProcessInfo.processInfo.systemUptime
        let timing = XCTAttachment(string: "\(action) (\(wallpaper)): launch→tap \(tapping - started)s; driver tap→destination \(finished - tapping)s. Includes XCTest synchronization, not raw touch latency.")
        timing.name = "cold-home-\(action)"; timing.lifetime = .keepAlways; add(timing)
    }
}
