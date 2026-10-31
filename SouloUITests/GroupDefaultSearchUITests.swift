import XCTest

@MainActor
final class GroupDefaultSearchUITests: XCTestCase {
    private func argumentData(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
    }
    func testAllPlatformsDisabledHomeNewTabAndBookmarkWorkAfterRestart() async throws {
        continueAfterFailure = false
        let title = "FallbackBookmark-" + UUID().uuidString.prefix(6)
        let searchHTML = "<html><head><title>Fallback search</title><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><h1>Fallback search loaded</h1></body></html>"
        let bookmarkHTML = "<html><head><title>\(title)</title><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><h1>Bookmark target loaded</h1></body></html>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/search": Data(searchHTML.utf8), "/bookmark": Data(bookmarkHTML.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let platform: [String: Any] = ["id": UUID().uuidString, "name":"Hidden", "iconName":"icon_google", "searchURLTemplate":"https://example.com/?q=%@", "homeURL":"https://example.com", "region":"international", "isBuiltIn":true,"isVisible":false,"sortOrder":0,"usageCount":0,"isCustom":false]
        let engine: [String: Any] = ["id":UUID().uuidString,"name":"Fixture","template":root.appendingPathComponent("search").absoluteString+"?q=%@","homeURL":root.absoluteString,"icon":"icon_google"]
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language","en-US","-privacy_https_upgrade_enabled","NO","-browser_toolbar_hidden","NO","-keep_fullscreen_browsing","NO",
            "-platform_config",try argumentData([platform]),"-platform_config_version","43","-group_default_search_engines",try argumentData(["region:china":engine]),
            "-last_selected_region","china","-last_selected_group_id","","-browser_toolbar_actions","(home,bookmark,tabs,more)"]
        app.launch(); app.open(URL(string:"soulo://")!)
        let field = app.textFields["search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        field.tap(); field.typeText("native fallback one\n")
        XCTAssertTrue(app.webViews.staticTexts["Fallback search loaded"].waitForExistence(timeout:20),app.debugDescription)
        app.buttons["browser.tabs"].tap()
        let newTab = app.buttons["tabs.tab_new_tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout:5),app.debugDescription); newTab.tap()
        let newField = app.textFields["search.query"].firstMatch
        XCTAssertTrue(newField.waitForExistence(timeout:5),app.debugDescription)
        newField.tap();newField.typeText("native fallback two\n")
        XCTAssertTrue(app.webViews.staticTexts["Fallback search loaded"].waitForExistence(timeout:20),app.debugDescription)
        var route=URLComponents();route.scheme="soulo";route.host="open"
        route.queryItems=[URLQueryItem(name:"url",value:root.appendingPathComponent("bookmark").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Bookmark target loaded"].waitForExistence(timeout:20),app.debugDescription)
        app.buttons["Bookmarks"].firstMatch.tap()
        let added = app.buttons["bookmark.fill"]
        XCTAssertTrue(added.waitForExistence(timeout: 5), app.debugDescription)
        app.terminate();app.launch();app.open(URL(string:"soulo://bookmarks")!)
        let saved = app.buttons.matching(NSPredicate(format:"label CONTAINS %@",String(title))).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout:10),app.debugDescription);saved.tap()
        XCTAssertTrue(app.webViews.staticTexts["Bookmark target loaded"].waitForExistence(timeout:20),app.debugDescription)
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="bookmark-open-with-all-platforms-disabled";shot.lifetime = .keepAlways;add(shot)
        app.buttons["Bookmarks"].firstMatch.tap()
    }
    private func replace(_ field: XCUIElement, with value: String) {
        let old = field.value as? String ?? ""
        field.tap(); field.press(forDuration: 0.7)
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        let selectAll = app.buttons["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap(); field.typeText(value)
        } else {
            // Tap below the final line to place the caret at the end.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + value)
        }
        XCTAssertEqual(field.value as? String, value)
    }
    func testGroupDefaultEditorAndBatchImportDefaults() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language","en-US","-platform_management_layout","list"]
        app.launch();app.open(URL(string:"soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout:10))
        app.buttons["home.menu"].tap();app.buttons["Settings"].firstMatch.tap()
        let platformLink = app.buttons["Platforms"].firstMatch
        XCTAssertTrue(platformLink.waitForExistence(timeout: 5), app.debugDescription); platformLink.tap()
        let entry=app.buttons["platform.default-search.china"]
        XCTAssertTrue(entry.waitForExistence(timeout:5),app.debugDescription);entry.tap()
        let name=app.textFields["group-search.engineName"]
        let url=app.textFields["group-search.template"].exists ? app.textFields["group-search.template"] : app.textViews["group-search.template"]
        let originalName = "Baidu", originalURL = "https://www.baidu.com/s?wd=%@"
        replace(name,with:"UI Search");replace(url,with:"https://example.com")
        app.buttons["group-search.save"].tap()
        XCTAssertTrue(app.staticTexts["Enter a name and a valid HTTP or HTTPS search URL containing %@."].waitForExistence(timeout:5),app.debugDescription)
        replace(url,with:"https://example.com/?q=%@")
        app.buttons["group-search.save"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout:5));XCTAssertTrue(entry.label.localizedCaseInsensitiveContains("UI Search"))
        entry.tap();replace(name,with:originalName);replace(url,with:originalURL);app.buttons["group-search.save"].tap()
        app.buttons["platform.managementMenu"].tap();app.buttons["Batch Import"].firstMatch.tap()
        let groupName=app.textFields["batch-import.groupName"]
        XCTAssertTrue(groupName.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertTrue((groupName.value as? String ?? "").hasPrefix("Imported Group"))
        let shot=XCTAttachment(screenshot:app.screenshot());shot.name="batch-import-default-new-group";shot.lifetime = .keepAlways;add(shot)
        app.buttons["Cancel"].firstMatch.tap()
    }

}
