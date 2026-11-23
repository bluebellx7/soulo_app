import XCTest

@available(iOS 16.4, *)
@MainActor
final class GroupDefaultSearchUITests: XCTestCase {
    private func argumentData(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
    }

    func testHomeQuickSearchUsesTappedPlatformAndMatchesSearchWidth() async throws {
        try await checkHomeQuickSearch(landscape: false)
    }

    func testLandscapeIPadQuickSearchUsesMoreVerticalSpaceAboveKeyboard() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad")
        try await checkHomeQuickSearch(landscape: true)
    }

    func testBottomHomeSearchShowsLiveSuggestionsAboveTheField() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_SUGGESTIONS"] == "1",
            "Requires a reachable live suggestion service")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO",
            "-restore_last_page_on_launch", "NO", "-home_quick_search", "NO", "-last_selected_region", "china",
            "-home_toolbar_layout", "{placement=bottom;searchPlacement=bottom;}", "-review.requestedOnce", "YES"]
        app.launch()
        defer { app.terminate() }
        let query = app.textFields["search.query"]
        let field = app.otherElements["home.search.field"]
        let panel = app.otherElements["home.search.suggestions"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        query.typeText("swift")
        XCTAssertTrue(panel.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(panel.buttons.firstMatch.isHittable, app.debugDescription)
        XCTAssertEqual(panel.frame.minX, field.frame.minX, accuracy: 2)
        XCTAssertEqual(panel.frame.width, field.frame.width, accuracy: 2)
        XCTAssertLessThan(panel.frame.maxY, field.frame.minY)
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY)
        XCTAssertFalse(app.otherElements["home.quick-search.platforms"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "bottom-search-suggestions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func checkHomeQuickSearch(landscape: Bool) async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let page = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <h1 id='result'></h1><script>
        document.getElementById('result').textContent = 'Second platform: ' + new URLSearchParams(location.search).get('q');
        </script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/second": Data(page.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let first = UUID()
        let target = UUID()
        let filler = (1...(landscape ? 34 : 22)).map { (UUID(), "Platform \($0)", "first") }
        let entries = [(first, "First platform", "first")] + filler + [(target, "Second platform", "second")]
        let platforms: [[String: Any]] = entries.enumerated().map { index, item in
                ["id": item.0.uuidString, "name": item.1, "iconName": "icon_google",
                 "searchURLTemplate": root.appendingPathComponent(item.2).absoluteString + "?q=%@",
                 "homeURL": root.absoluteString, "region": "international", "isBuiltIn": false,
                 "isVisible": true, "sortOrder": index, "usageCount": 0, "isCustom": true]
        }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-platform_management_layout", "list",
            "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO", "-restore_last_page_on_launch", "NO",
            "-review.requestedOnce", "YES", "-home_toolbar_actions", "(platforms)",
            "-home_toolbar_layout", "{placement=bottom;searchPlacement=center;}",
            "-privacy_https_upgrade_enabled", "NO", "-platform_config", try argumentData(platforms),
            "-platform_config_version", "47", "-last_selected_region", "international", "-last_selected_group_id", ""]
        app.launch()
        defer { app.terminate() }
        let platformSettings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(platformSettings.waitForExistence(timeout: 10), app.debugDescription)
        platformSettings.tap()
        let preference = app.switches["platform.home-quick-search"]
        XCTAssertTrue(preference.waitForExistence(timeout: 5), app.debugDescription)
        if preference.value as? String == "1" {
            preference.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertFalse(app.buttons["platform.guide.done"].exists)
        preference.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let guide = app.staticTexts["platform.guide.quickSearch"]
        XCTAssertTrue(guide.waitForExistence(timeout: 5), app.debugDescription)
        let guideScreenshot = XCTAttachment(screenshot: app.screenshot())
        guideScreenshot.name = "platform-quick-search-guide"
        guideScreenshot.lifetime = .keepAlways
        add(guideScreenshot)
        app.buttons["platform.guide.done"].tap()
        XCTAssertEqual(preference.value as? String, "1")
        app.terminate()
        app.launch()

        let field = app.otherElements["home.search.field"]
        let query = app.textFields["search.query"].firstMatch
        let panel = app.otherElements["home.quick-search.platforms"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        XCTAssertFalse(panel.exists)
        query.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let fieldBeforeTyping = field.frame
        query.typeText("swift tests")
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-quick-search-platforms"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let panelFrame = panel.frame, fieldFrame = field.frame
            return abs(panelFrame.minX - fieldFrame.minX) < 2 && abs(panelFrame.maxX - fieldFrame.maxX) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 3), .completed)
        XCTAssertGreaterThan(panel.frame.minY, field.frame.maxY)
        XCTAssertEqual(field.frame.midY, fieldBeforeTyping.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(panel.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        let grid = panel.scrollViews.firstMatch
        let firstPlatform = panel.buttons["browser.platform." + first.uuidString]
        XCTAssertTrue(firstPlatform.isHittable)
        XCTAssertGreaterThan(grid.frame.height, firstPlatform.frame.height)
        let rowHeight = firstPlatform.frame.height + 6
        if landscape {
            XCTAssertGreaterThan(grid.frame.height, 2 * rowHeight)
        }
        XCTAssertLessThanOrEqual(grid.frame.height, (landscape ? 4 : 3) * rowHeight + 2)
        let targetPlatform = panel.buttons["browser.platform." + target.uuidString]
        XCTAssertFalse(targetPlatform.isHittable)
        for _ in 0..<4 where !targetPlatform.isHittable { grid.swipeUp() }
        XCTAssertTrue(targetPlatform.isHittable, app.debugDescription)
        targetPlatform.tap()
        XCTAssertTrue(app.webViews.staticTexts["Second platform: swift tests"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testOptionalPlatformBarWaitsForTrustedPageTapAndSharesHomeToggle() async throws {
        continueAfterFailure = false
        let search = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <h1 id='status'>Search fixture</h1><a href='/detail'>Open result</a>
        <button id='script' onclick="document.body.dataset.synthetic='done'">Script button</button>
        <div style='height:2400px;background:linear-gradient(white,#ddd)'>Scrollable content</div>
        <script>setTimeout(()=>{
          document.querySelector('#script').click();
          history.replaceState(null,'',location.pathname+'?automatic=1');
          document.querySelector('#status').textContent='Automatic transition complete';
        },700);</script>
        """
        let detail = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Result fixture</h1><button onclick='history.back()'>Return to results</button>"
        // Keep the configured platform host distinct from the result host.
        // The bar stays visible on a platform's own domain even after a tap.
        let server = try DownloadPlaybackHTTPFixture(files: ["/search": Data(search.utf8), "/detail": Data(detail.utf8)],
                                                     redirects: ["/launch": (host: "localhost", path: "/search")])
        let root = try await server.start(); defer { server.stop() }
        let platform: [String: Any] = ["id": UUID().uuidString, "name": "Fixture", "iconName": "icon_google", "searchURLTemplate": root.appendingPathComponent("launch").absoluteString + "?q=%@", "homeURL": root.absoluteString, "region": "international", "isBuiltIn": false, "isVisible": true, "sortOrder": 0, "usageCount": 0, "isCustom": true]
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO", "-privacy_https_upgrade_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-platform_config", try argumentData([platform]), "-platform_config_version", "43", "-last_selected_region", "international", "-last_selected_group_id", ""]
        app.launch(); defer { app.terminate() }
        app.open(URL(string: "soulo://")!)
        let query = app.textFields["search.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        app.buttons["search.actions"].tap()
        let homeToggle = app.switches["home.auto-hide-platforms"]
        XCTAssertTrue(homeToggle.waitForExistence(timeout: 5), app.debugDescription)
        if homeToggle.value as? String == "1" { homeToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(homeToggle.value as? String, "0")
        homeToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let hint = app.alerts["Auto-hide Platform Bar"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(hint.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tap webpage content")).firstMatch.exists)
        hint.buttons["Done"].tap()
        query.tap(); query.typeText("first query\n")
        let automatic = app.webViews.staticTexts["Automatic transition complete"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 15), app.debugDescription)
        let picker = app.buttons["search.group-picker"]
        XCTAssertTrue(picker.exists, "Automatic URL changes and script clicks must keep the platform bar visible")
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(picker.exists, "Scrolling must not hide the platform bar")
        app.webViews.firstMatch.swipeDown()
        automatic.tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "A real tap on non-link page content must hide the bar")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "platform-bar-hidden-only-after-page-tap"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Home Screen"].firstMatch.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeText("second query\n")
        XCTAssertTrue(automatic.waitForExistence(timeout: 15))
        XCTAssertTrue(picker.exists, "A new search must restore the bar")
        app.webViews.links["Open result"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Result fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        app.webViews.buttons["Return to results"].tap()
        XCTAssertTrue(automatic.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Returning to the actual tapped search document must restore the bar")
        picker.tap()
        let browserToggle = app.switches["search.auto-hide-platforms"]
        XCTAssertTrue(browserToggle.waitForExistence(timeout: 5)); XCTAssertEqual(browserToggle.value as? String, "1")
        browserToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // Dismiss the popover without touching webpage content.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.6)).tap()
        automatic.tap()
        XCTAssertTrue(picker.exists, "The disabled option must keep the bar visible after a real tap")
        app.buttons["Home Screen"].firstMatch.tap()
        XCTAssertTrue(query.waitForExistence(timeout: 5)); app.buttons["search.actions"].tap()
        XCTAssertTrue(homeToggle.waitForExistence(timeout: 5)); XCTAssertEqual(homeToggle.value as? String, "0", "Home and browser menus share one preference")
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
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language","en-US","-privacy_https_upgrade_enabled","NO","-browser_toolbar_hidden","NO","-keep_fullscreen_browsing","NO",
            "-platform_config",try argumentData([platform]),"-platform_config_version","43","-group_default_search_engines",try argumentData(["region:china":engine]),
            "-last_selected_region","china","-last_selected_group_id","","-browser_toolbar_actions","(home,bookmark,tabs,more)"]
        app.launch(); app.open(URL(string:"soulo://")!)
        let field = app.textFields["search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout:10),app.debugDescription)
        field.tap(); field.typeText("native fallback one\n")
        XCTAssertTrue(app.webViews.staticTexts["Fallback search loaded"].waitForExistence(timeout:20),app.debugDescription)
        XCTAssertFalse(app.buttons["search.group-picker"].exists, "Fallback search must not show the platform row")
        let hiddenRow = XCTAttachment(screenshot: app.screenshot())
        hiddenRow.name = "search-without-platform-row"; hiddenRow.lifetime = .keepAlways; add(hiddenRow)
        app.buttons["browser.tabs"].tap()
        app.buttons["tabs.options"].tap()
        let newTab = app.buttons["tabs.new-tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout:5),app.debugDescription); newTab.tap()
        let newField = app.textFields["search.query"].firstMatch
        XCTAssertTrue(newField.waitForExistence(timeout:5),app.debugDescription)
        newField.tap();newField.typeText("native fallback two\n")
        XCTAssertTrue(app.webViews.staticTexts["Fallback search loaded"].waitForExistence(timeout:20),app.debugDescription)
        XCTAssertFalse(app.buttons["search.group-picker"].exists)
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

        // Restoring an enabled platform must restore the switcher for searches.
        var enabledPlatform = platform
        enabledPlatform["name"] = "Fixture platform"
        enabledPlatform["region"] = "china"
        enabledPlatform["isVisible"] = true
        enabledPlatform["searchURLTemplate"] = root.appendingPathComponent("search").absoluteString + "?q=%@"
        enabledPlatform["homeURL"] = root.absoluteString
        let configIndex = try XCTUnwrap(app.launchArguments.firstIndex(of: "-platform_config"))
        app.terminate()
        app.launchArguments[configIndex + 1] = try argumentData([enabledPlatform])
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap(); field.typeText("enabled platform search\n")
        XCTAssertTrue(app.webViews.staticTexts["Fallback search loaded"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["search.group-picker"].exists, "An enabled platform keeps the switcher available")
        let visibleRow = XCTAttachment(screenshot: app.screenshot())
        visibleRow.name = "search-with-enabled-platform-row"; visibleRow.lifetime = .keepAlways; add(visibleRow)
        app.terminate()
    }
    func testCrossRegionDropWorksInGridAndListAndSurvivesRestart() throws {
        continueAfterFailure = false
        for layout in ["grid","list"] {
            let sourceID=UUID(),keepID=UUID(),targetID=UUID()
            func platform(_ id:UUID,_ name:String,_ region:String,_ order:Int)->[String:Any] {
                ["id":id.uuidString,"name":name,"iconName":"icon_google","searchURLTemplate":"https://example.com/?q=%@&engine=\(name)","homeURL":"https://example.com/","region":region,"isBuiltIn":false,"isVisible":true,"sortOrder":order,"usageCount":0,"isCustom":true]
            }
            let data=try argumentData([platform(sourceID,"Drag source","china",0),platform(keepID,"Keep China","china",1),platform(targetID,"Drop target","international",0)])
            let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
            app.launchArguments=["-app_language","en-US","-platform_management_layout",layout,"-icloud_sync_enabled","NO","-platform_config",data,"-platform_config_version","47","-custom_groups",try argumentData([])]
            func open() {
                app.launch();app.open(URL(string:"soulo://")!)
                XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout:10));app.buttons["home.menu"].tap()
                app.buttons["Settings"].firstMatch.tap()
                let platforms=app.buttons["Platforms"].firstMatch
                XCTAssertTrue(platforms.waitForExistence(timeout:5));platforms.tap()
                XCTAssertTrue(app.buttons["platform.layout"].waitForExistence(timeout:5))
            }
            open()
            let prefix=layout == "grid" ? "platform.grid." : "platform.row."
            func item(_ id:UUID)->XCUIElement {
                if layout == "list" { return app.cells.containing(.any,identifier:prefix+id.uuidString).firstMatch }
                return app.descendants(matching:.any).matching(identifier:prefix+id.uuidString).firstMatch
            }
            let source=item(sourceID),target=item(targetID)
            XCTAssertTrue(source.waitForExistence(timeout:5));XCTAssertTrue(target.waitForExistence(timeout:5))
            if layout == "grid" {
                XCTAssertTrue(source.isHittable);XCTAssertTrue(target.isHittable,app.debugDescription)
            } else {
                // List rows are accessibility containers with a separate
                // visibility button. Their center remains a real drag surface.
                XCTAssertGreaterThan(source.frame.height,20,app.debugDescription)
                XCTAssertGreaterThan(target.frame.height,20,app.debugDescription)
                XCTAssertTrue(source.frame.intersects(app.frame))
                XCTAssertTrue(target.frame.intersects(app.frame))
            }
            source.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.9,
                thenDragTo:target.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)),withVelocity:.slow,thenHoldForDuration:0.4)
            let region=app.descendants(matching:.any).matching(identifier:"platform.group.international").firstMatch
            let moved=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in source.exists && region.exists && source.frame.minY > region.frame.minY },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[moved],timeout:5),.completed,app.debugDescription)
            XCTAssertFalse(app.textFields["platform.name"].exists,"Dragging must not open the editor")
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="cross-region-platform-drop-"+layout;shot.lifetime = .keepAlways;add(shot)
            app.terminate()
            // The saved configuration must be read without test fixture overrides.
            app.launchArguments=["-app_language","en-US","-platform_management_layout",layout,"-icloud_sync_enabled","NO"]
            open()
            XCTAssertTrue(item(sourceID).waitForExistence(timeout:5));XCTAssertTrue(region.exists)
            XCTAssertGreaterThan(item(sourceID).frame.minY,region.frame.minY,"The destination persists after relaunch")
            if layout == "list" {
                let row = item(sourceID), visibility = row.buttons["Show platform"]
                XCTAssertTrue(visibility.exists, app.debugDescription)
                visibility.tap()
                XCTAssertEqual(visibility.value as? String, "Disabled")
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                let editor = app.textFields.matching(NSPredicate(format: "value == %@", "Drag source")).firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
                app.navigationBars.buttons["Cancel"].firstMatch.tap()
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                row.swipeLeft()
                let delete = app.buttons["Delete"].firstMatch
                XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)], timeout: 5), .completed)
            }
            app.terminate()
        }
    }

    private func replace(_ field: XCUIElement, with value: String) {
        let old = field.value as? String ?? ""
        field.tap(); field.press(forDuration: 0.7)
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
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
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
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

@available(iOS 16.4, *)
extension GroupDefaultSearchUITests {
    @MainActor func testPlatformGridLongPressReordersAndPersists() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-platform_management_layout", "grid", "-icloud_sync_enabled", "NO"]
        func openManagement() {
            app.launch(); app.open(URL(string: "soulo://")!)
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10)); app.buttons["home.menu"].tap()
            app.buttons["Settings"].firstMatch.tap()
            let platforms = app.buttons["Platforms"].firstMatch
            XCTAssertTrue(platforms.waitForExistence(timeout: 5)); platforms.tap()
            XCTAssertTrue(app.buttons["platform.layout"].waitForExistence(timeout: 5))
        }
        openManagement()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "platform.grid."))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let visible = cards.allElementsBoundByIndex.filter { $0.isHittable }.sorted {
            abs($0.frame.minY - $1.frame.minY) > 10 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        XCTAssertGreaterThanOrEqual(visible.count, 3)
        let firstID = visible[0].identifier, targetID = visible[2].identifier
        func card(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        card(firstID).press(forDuration: 0.8, thenDragTo: card(targetID), withVelocity: .slow, thenHoldForDuration: 0.5)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in card(firstID).frame.midX > card(targetID).frame.midX }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 3), .completed, app.debugDescription)
        XCTAssertFalse(app.textFields["platform.name"].exists, "Dragging must not open the editor")
        app.terminate(); openManagement()
        XCTAssertGreaterThan(card(firstID).frame.midX, card(targetID).frame.midX, "Grid order must persist after restart")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "platform-grid-drag-order"; shot.lifetime = .keepAlways; add(shot)
        card(firstID).press(forDuration: 0.8, thenDragTo: visible[1], withVelocity: .slow, thenHoldForDuration: 0.3)
        app.terminate()
    }
}
