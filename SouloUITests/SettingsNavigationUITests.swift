import XCTest
import Network

/// Does not depend on XCUIApplication.open, so the boundary runner can also
/// exercise the shipping app's minimum OS (iOS 16.0).
@MainActor
final class SettingsNavigationUITests: XCTestCase {
    func testHomeToolbarPreviewReordersAndSavesFreePlacement() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let actions = try XCTUnwrap(app.launchArguments.firstIndex(of: "-home_toolbar_actions"))
        app.launchArguments[actions + 1] = "(settings,files,downloads)"
        app.launchArguments += ["-home_quick_search", "YES", "-restore_last_page_on_launch", "NO"]
        app.launch(); defer { app.terminate() }
        let homeSettings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(homeSettings.waitForExistence(timeout: 8))
        homeSettings.tap()
        let toolbar = app.buttons["settings.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5)); toolbar.tap()
        let previewSearch = app.descendants(matching: .any)["home-toolbar.preview.search"].firstMatch
        if !previewSearch.exists {
            app.buttons["home-toolbar.editor.visibility"].tap()
            app.buttons["home-toolbar.visibility.search"].tap()
        }
        let buttons = app.buttons["home-toolbar.editor.buttons"]
        let style = "home-toolbar.style"
        let placement = "home-toolbar.position"
        let searchPosition = "home-toolbar.search-position"
        func choose(_ identifier: String, _ item: String, title: String) {
            let option = app.buttons[identifier + "." + item]
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(option.label, title)
            option.tap()
            XCTAssertTrue(option.isSelected)
        }
        buttons.tap()
        choose(style, "capsule", title: "Capsule")
        XCTAssertTrue(app.scrollViews["home-toolbar.content"].frame.contains(app.buttons[style + ".capsule"].frame))
        let first = app.buttons["home-toolbar.slot.0"]
        let third = app.buttons["home-toolbar.slot.2"]
        first.press(forDuration: 0.06, thenDragTo: third)
        XCTAssertTrue(app.buttons["home-toolbar.slot.2"].label.contains("Settings"))
        let position = app.buttons["home-toolbar.editor.position"]
        let save = app.buttons["home-toolbar.save"]
        XCTAssertLessThanOrEqual(position.frame.maxY, save.frame.minY)
        XCTAssertEqual(app.buttons["toolbar.restore"].frame.maxY, save.frame.maxY, accuracy: 1)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(app.frame.maxY - save.frame.maxY, 16, accuracy: 2)
        }
        position.tap()
        choose(placement, "bottom", title: "Bottom")
        XCTAssertTrue(previewSearch.waitForExistence(timeout: 5))
        choose(searchPosition, "center", title: "Center")
        let previewCenterY = previewSearch.frame.midY
        choose(searchPosition, "bottom", title: "Page Bottom")
        XCTAssertGreaterThan(previewSearch.frame.midY, previewCenterY + 10)
        XCTAssertEqual(app.staticTexts["home-toolbar.alignment"].label, "Toolbar Alignment")
        let panel = XCTAttachment(screenshot: app.screenshot())
        panel.name = "home-toolbar-position-panel"
        panel.lifetime = .keepAlways
        add(panel)
        XCTAssertFalse(app.buttons["home-toolbar.search-position.upper"].exists)
        XCTAssertFalse(app.buttons["home-toolbar.search-position.lower"].exists)
        choose(searchPosition, "center", title: "Center")
        XCTAssertFalse(app.buttons["home-toolbar.position.belowSearch"].exists)
        choose(placement, "free", title: "Free Placement")
        let strip = app.descendants(matching: .any)["home-toolbar.drag"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let belowSearchY = previewSearch.frame.maxY + strip.frame.height / 2 + 12
        start.press(forDuration: 0.07, thenDragTo: start.withOffset(CGVector(dx: -40, dy: belowSearchY - strip.frame.midY)))
        XCTAssertGreaterThan(strip.frame.minY, previewSearch.frame.maxY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-toolbar-free-placement-preview"; screenshot.lifetime = .keepAlways; add(screenshot)
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons["Done"].firstMatch.tap()
        let moved = app.buttons["home.toolbar.2"]
        XCTAssertTrue(moved.waitForExistence(timeout: 5)); XCTAssertTrue(moved.isHittable)
        XCTAssertEqual(moved.label, "Settings")
        XCTAssertLessThan(moved.frame.maxY, app.frame.maxY - 60)
        XCTAssertGreaterThanOrEqual(moved.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(moved.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(moved.frame.width, 44)
        let searchField = app.textFields["search.query"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(moved.frame.minY, searchField.frame.maxY)
        let centerY = searchField.frame.midY
        let customize = app.buttons["Customize Home Toolbar"].firstMatch
        func reopenToolbar() {
            moved.press(forDuration: 0.7)
            XCTAssertTrue(customize.waitForExistence(timeout: 5)); customize.tap()
            XCTAssertTrue(position.waitForExistence(timeout: 5))
        }
        func saveAndReturnHome() {
            save.tap()
            XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(moved.waitForExistence(timeout: 5)); XCTAssertTrue(moved.isHittable)
        }
        reopenToolbar()
        buttons.tap()
        XCTAssertTrue(app.buttons[style + ".capsule"].isSelected)
        position.tap()
        XCTAssertTrue(app.buttons[placement + ".free"].isSelected)
        XCTAssertTrue(app.buttons[searchPosition + ".center"].isSelected)
        choose(searchPosition, "bottom", title: "Page Bottom")
        choose(placement, "bottom", title: "Bottom")
        saveAndReturnHome()
        XCTAssertGreaterThan(searchField.frame.midY, centerY + 40)
        let bottomPresetY = moved.frame.maxY
        let freeBottomY = bottomPresetY + 10

        reopenToolbar()
        position.tap()
        choose(placement, "free", title: "Free Placement")
        func dragToBottom() {
            let from = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = from.withOffset(CGVector(dx: 0, dy: position.frame.midY - strip.frame.midY))
            from.press(forDuration: 0.07, thenDragTo: to)
        }
        dragToBottom()
        XCTAssertLessThanOrEqual(previewSearch.frame.maxY + 6, strip.frame.minY)
        let clearance = XCTAttachment(screenshot: app.screenshot())
        clearance.name = "home-toolbar-avoids-search-preview"
        clearance.lifetime = .keepAlways
        add(clearance)
        saveAndReturnHome()
        let searchBox = app.otherElements["home.search.field"]
        XCTAssertTrue(searchBox.isHittable)
        XCTAssertLessThanOrEqual(searchBox.frame.maxY + 8, moved.frame.minY)
        XCTAssertEqual(moved.frame.maxY, freeBottomY, accuracy: 2)
        let docked = XCTAttachment(screenshot: app.screenshot())
        docked.name = "home-toolbar-bottom-with-search"
        docked.lifetime = .keepAlways
        add(docked)

        reopenToolbar()
        position.tap()
        choose(searchPosition, "center", title: "Center")
        dragToBottom()
        saveAndReturnHome()
        // The capsule's background extends 3 points below the buttons.
        let bottomGap = app.frame.maxY - moved.frame.maxY
        XCTAssertLessThanOrEqual(bottomGap, 17)
        XCTAssertGreaterThanOrEqual(bottomGap, 4)
        XCTAssertEqual(moved.frame.maxY, freeBottomY, accuracy: 2)
        let bottomScreenshot = XCTAttachment(screenshot: app.screenshot())
        bottomScreenshot.name = "home-toolbar-free-placement-bottom"
        bottomScreenshot.lifetime = .keepAlways
        add(bottomScreenshot)

        reopenToolbar()
        position.tap()
        choose(searchPosition, "bottom", title: "Page Bottom")
        choose(placement, "bottom", title: "Bottom")
        saveAndReturnHome()
        XCTAssertGreaterThan(moved.frame.minY, searchField.frame.maxY)
        XCTAssertLessThan(moved.frame.minY - searchField.frame.maxY, 45)
        app.buttons["search.actions"].tap()
        let scan = app.buttons["search.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertLessThan(scan.frame.maxY, searchField.frame.minY)
        let menuScreenshot = XCTAttachment(screenshot: app.screenshot())
        menuScreenshot.name = "bottom-search-actions"
        menuScreenshot.lifetime = .keepAlways
        add(menuScreenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.22)).tap()
        XCTAssertTrue(scan.waitForNonExistence(timeout: 5))
        searchField.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        searchField.typeText("SwiftUI")
        let platforms = app.otherElements["home.quick-search.platforms"]
        XCTAssertTrue(platforms.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(searchField.frame.maxY, keyboard.frame.minY)
        XCTAssertLessThan(platforms.frame.maxY, searchField.frame.minY)
        let quickSearch = XCTAttachment(screenshot: app.screenshot())
        quickSearch.name = "bottom-search-platforms"
        quickSearch.lifetime = .keepAlways
        add(quickSearch)
    }

    func testFourSettingsGroupsKeepDirectSearchAndNestedPagesWorking() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO", "-extend_page_background", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        for mode in ["system", "light", "dark"] {
            XCTAssertTrue(app.buttons["settings.appearance." + mode].waitForExistence(timeout: 5))
        }
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let root = XCTAttachment(screenshot: app.screenshot()); root.name = "settings-four-groups-root"; root.lifetime = .keepAlways; add(root)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Wallpaper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wallpaper.sources"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["settings.personalization.section"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.toolbar"].tap()
        let toolbarSections = app.segmentedControls["browser-toolbar.section"]
        XCTAssertTrue(toolbarSections.waitForExistence(timeout: 5))
        XCTAssertTrue(toolbarSections.buttons.element(boundBy: 0).isSelected, "Home settings must start on the Home toolbar")
        app.navigationBars.buttons.firstMatch.tap()
        let browsing = app.buttons["settings.browsingDisplay"]
        scrollStorageRow(browsing, in: app); browsing.tap()
        XCTAssertTrue(app.staticTexts["Startup & Tabs"].exists)
        XCTAssertTrue(app.buttons["settings.defaultBrowser"].exists)
        XCTAssertTrue(app.switches["settings.browsingDisplay.restoreLastPage"].exists)
        let awake = app.switches["settings.keepScreenAwake"]
        scrollStorageRow(awake, in: app); XCTAssertTrue(awake.exists)
        let zoom = app.buttons["settings.websiteZoom"]
        scrollStorageRow(zoom, in: app); zoom.tap()
        XCTAssertTrue(app.switches["settings.zoom.remember"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Browsing Settings"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let about = app.buttons["settings.version"]
        scrollStorageRow(about, in: app); about.tap()
        XCTAssertTrue(app.navigationBars["About & Feedback"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.telegram"].exists, "Telegram belongs in the root settings")
        app.navigationBars.buttons.firstMatch.tap()
        let telegram = app.buttons["settings.telegram"]
        scrollStorageRow(telegram, in: app); XCTAssertTrue(telegram.exists); telegram.tap()
        XCTAssertTrue(app.staticTexts["settings.telegram.link"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Wallpaper")
        app.buttons["settings.wallpaper"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Wallpaper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wallpaper.sources"].firstMatch.waitForExistence(timeout: 5))
    }

    private func platformArgumentData(_ value: Any) throws -> String {
        "<" + (try JSONSerialization.data(withJSONObject: value)).map { String(format: "%02x", $0) }.joined() + ">"
    }

    func testPlatformHighlightFollowsDomainAndExplicitTabSwitchRechecksAutoHide() async throws {
        continueAfterFailure = false
        let alphaHTML = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Domain Alpha</title>
        <h1>Domain Alpha page</h1><a id="beta" href="/beta">Go to Beta</a>
        <script>document.getElementById('beta').href='http://127.0.0.1:'+location.port+'/beta';</script>
        """
        let betaHTML = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Domain Beta</title>
        <h1>Domain Beta page</h1><a id="outside" target="_blank" href="/outside">Open unrelated tab</a>
        <script>document.getElementById('outside').href='http://[::1]:'+location.port+'/outside';</script>
        """
        let outsideHTML = "<meta name='viewport' content='width=device-width,initial-scale=1'><title>Domain Outside</title><h1>Unrelated domain page</h1>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/alpha": Data(alphaHTML.utf8), "/beta": Data(betaHTML.utf8), "/outside": Data(outsideHTML.utf8)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        func platform(_ name: String, host: String, path: String, order: Int) -> [String: Any] {
            let base = "http://\(host):\(root.port!)"
            return ["id": UUID().uuidString, "name": name, "iconName": "icon_google",
                "searchURLTemplate": base + path + "?q=%@", "homeURL": base + path,
                "region": "international", "isBuiltIn": false, "isVisible": true,
                "sortOrder": order, "usageCount": 0, "isCustom": true]
        }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO", "-is_incognito", "YES",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO", "-ad_block_confirm_cross_domain", "NO", "-browser_toolbar_hidden", "NO",
            "-keep_fullscreen_browsing", "NO", "-show_platform_bar", "YES", "-auto_hide_platform_bar", "YES",
            "-show_top_tab_bar", "YES", "-last_selected_region", "international", "-last_selected_group_id", "",
            "-platform_config_version", "47", "-platform_config", try platformArgumentData([
                platform("QA Alpha", host: "localhost", path: "/alpha", order: 0),
                platform("QA Beta", host: "127.0.0.1", path: "/beta", order: 1)]),
            "-browser_toolbar_actions", "(home,back,tabs,more)"]
        app.launch(); defer { app.terminate() }
        let query = app.textFields["search.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10), app.debugDescription)
        query.tap(); query.typeText("domain-check\n")
        XCTAssertTrue(app.webViews.staticTexts["Domain Alpha page"].waitForExistence(timeout: 20), app.debugDescription)
        let alpha = app.descendants(matching: .any).matching(identifier: "QA Alpha").firstMatch
        let beta = app.descendants(matching: .any).matching(identifier: "QA Beta").firstMatch
        let picker = app.buttons["search.group-picker"]
        XCTAssertTrue(alpha.isSelected)
        XCTAssertFalse(beta.isSelected)
        let initialSearchRequests = server.receivedRequests.filter { $0.path == "/alpha" && $0.method == "GET" }.count
        app.webViews.links["Go to Beta"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Domain Beta page"].waitForExistence(timeout: 10), String(describing: server.receivedRequests.map { $0.path }))
        let highlighted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in beta.isSelected && !alpha.isSelected }, object: nil)
        await fulfillment(of: [highlighted], timeout: 5)
        XCTAssertTrue(picker.exists)
        XCTAssertEqual(server.receivedRequests.filter { $0.path == "/alpha" && $0.method == "GET" }.count, initialSearchRequests,
            "Domain highlighting must not trigger another search or replace the current document")
        app.webViews.links["Open unrelated tab"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Unrelated domain page"].waitForExistence(timeout: 15), String(describing: server.receivedRequests.map { $0.path }) + "\n" + app.debugDescription)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "A user-opened result tab outside the group must hide the bar on its first load")
        let betaTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Domain Beta, tab ")).firstMatch
        let outsideTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Domain Outside, tab ")).firstMatch
        XCTAssertTrue(betaTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Domain Beta, tab ")).count, 1)
        betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(app.webViews.staticTexts["Domain Beta page"].waitForExistence(timeout: 5))
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(beta.isSelected)
        outsideTab.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(app.webViews.staticTexts["Unrelated domain page"].waitForExistence(timeout: 5))
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5), "Explicit activation of an unmatched tab must hide the platform bar")
        let hidden = XCTAttachment(screenshot: app.screenshot()); hidden.name = "unmatched-tab-platform-bar-hidden"; hidden.lifetime = .keepAlways; add(hidden)
        betaTab.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(beta.isSelected)
        let restored = XCTAttachment(screenshot: app.screenshot()); restored.name = "matching-tab-domain-platform-highlight"; restored.lifetime = .keepAlways; add(restored)
    }

    func testReturningFromLibraryKeepsTheSelectedSearchPlatform() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try DownloadPlaybackHTTPFixture(files: ["/first": Data("<h1>First search engine</h1>".utf8),
            "/second": Data("<h1>Second search engine</h1>".utf8)])
        let root = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }

        let platforms: [[String: Any]] = ["first", "second"].enumerated().map { index, path in
            let url = root.appendingPathComponent(path).absoluteString
            return ["id": UUID().uuidString, "name": "QA \(path)", "iconName": "icon_google",
                "searchURLTemplate": url + "?q=%@", "homeURL": url, "region": "international", "isBuiltIn": false,
                "isVisible": true, "sortOrder": index, "usageCount": 0, "isCustom": true]
        }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO",
            "-is_incognito", "YES", "-restore_last_page_on_launch", "NO", "-review.requestedOnce", "YES",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO", "-keep_fullscreen_browsing", "NO",
            "-browser_toolbar_hidden", "NO", "-show_platform_bar", "YES", "-auto_hide_platform_bar", "NO",
            "-last_selected_region", "international", "-last_selected_group_id", "", "-platform_config_version", "47",
            "-platform_config", try platformArgumentData(platforms), "-browser_toolbar_actions", "(home,back,library,more)"]
        app.launch()
        defer { app.terminate() }

        let query = app.textFields["search.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap(); query.typeText("library platform regression\n")
        XCTAssertTrue(app.webViews.staticTexts["First search engine"].waitForExistence(timeout: 15), app.debugDescription)
        let second = app.descendants(matching: .any).matching(identifier: "QA second").firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        second.tap()
        let heading = app.webViews.staticTexts["Second search engine"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        let searchRequests = server.receivedRequests.filter { ["/first", "/second"].contains($0.path) && $0.method == "GET" }.count

        let library = app.buttons["browser.action.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        XCTAssertTrue(app.buttons["library.section.bookmarks"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(second.isSelected)
        XCTAssertEqual(server.receivedRequests.filter { ["/first", "/second"].contains($0.path) && $0.method == "GET" }.count,
                       searchRequests)
    }

    func testRecentSearchHidesPlatformBarForScriptOpenedResult() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let results = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Dictionary results</title>
        <h1>Dictionary results</h1>
        <a href="javascript:void(0)" onclick="window.open('http://[::1]:'+location.port+'/dictionary')">Dictionary entry</a>
        """
        let dictionary = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Dictionary definition</h1>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/results": Data(results.utf8), "/dictionary": Data(dictionary.utf8)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let platform = ["id": UUID().uuidString, "name": "QA Dictionary Search", "iconName": "icon_google",
            "searchURLTemplate": root.appendingPathComponent("results").absoluteString + "?q=%@",
            "homeURL": root.absoluteString, "region": "international", "isBuiltIn": false, "isVisible": true,
            "sortOrder": 0, "usageCount": 0, "isCustom": true] as [String: Any]
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-is_incognito", "NO",
            "-restore_last_page_on_launch", "NO", "-show_recent_searches_on_home", "YES", "-show_bookmarks_on_home", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO", "-ad_block_confirm_cross_domain", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-show_platform_bar", "YES", "-auto_hide_platform_bar", "YES",
            "-show_top_tab_bar", "YES", "-last_selected_region", "international", "-last_selected_group_id", "", "-platform_config_version", "47",
            "-platform_config", try platformArgumentData([platform]), "-browser_toolbar_actions", "(home,back,tabs,more)"]
        app.launch(); defer { app.terminate() }
        let term = "dictionary qa \(UUID().uuidString.prefix(6))"
        let query = app.textFields["search.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap(); query.typeText(term + "\n")
        let resultsPage = app.webViews.staticTexts["Dictionary results"].firstMatch
        XCTAssertTrue(resultsPage.waitForExistence(timeout: 20), app.debugDescription)
        let home = app.buttons["browser.action.home"]
        home.tap()
        let recent = app.buttons["Recent search, \(term)"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5)); recent.tap()
        XCTAssertTrue(resultsPage.waitForExistence(timeout: 15))
        let bar = app.buttons["search.group-picker"]
        XCTAssertTrue(bar.exists)
        app.webViews.links["Dictionary entry"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Dictionary definition"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "A real tap that opens an off-platform result with JavaScript must hide the bar")
        let resultsTab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dictionary results, tab ")).firstMatch
        XCTAssertTrue(resultsTab.waitForExistence(timeout: 5)); XCTAssertTrue(resultsTab.isHittable)
        resultsTab.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(resultsPage.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
    }

    func testLiveBaiduDictionaryResultFromRecentSearchHidesPlatformBar() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_BAIDU_HISTORY_QA"] == "1", "Requires the live Baidu dictionary card")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let baidu = ["id": UUID().uuidString, "name": "Baidu QA", "iconName": "icon_baidu",
            "searchURLTemplate": "https://www.baidu.com/s?wd=%@", "homeURL": "https://www.baidu.com",
            "region": "china", "isBuiltIn": false, "isVisible": true, "sortOrder": 0,
            "usageCount": 0, "isCustom": true] as [String: Any]
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-is_incognito", "NO",
            "-restore_last_page_on_launch", "NO", "-show_recent_searches_on_home", "YES", "-show_bookmarks_on_home", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-show_platform_bar", "YES", "-auto_hide_platform_bar", "YES",
            "-last_selected_region", "china", "-last_selected_group_id", "", "-platform_config_version", "47",
            "-platform_config", try platformArgumentData([baidu]), "-browser_toolbar_actions", "(home,back,address,tabs,more)"]
        app.launch(); defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://search?q=%E4%BA%BA")))
        let home = app.buttons["browser.action.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15)); home.tap()
        let recent = app.buttons["Recent search, 人"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8)); recent.tap()
        let bar = app.buttons["search.group-picker"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let web = app.webViews.firstMatch
        let result = web.staticTexts["zd.souf.com.cn"].firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        for _ in 0..<12 {
            if result.exists && result.isHittable { break }
            web.swipeUp()
        }
        guard result.isHittable else { throw XCTSkip("Baidu did not return the requested dictionary card in the simulator") }
        result.tap()
        XCTAssertTrue(app.webViews.staticTexts["基本解释"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    }

    func testPlatformPanelSwitchesGroupsAndPlatformsWithHiddenBar() async throws {
        continueAfterFailure = false
        let fixture = try AdSettingsPageFixture(), root = try await fixture.start()
        defer { fixture.stop() }
        func platform(_ name: String, _ path: String, visible: Bool = true) -> [String: Any] {
            ["id": UUID().uuidString, "name": name, "iconName": "icon_google",
             "searchURLTemplate": root.appendingPathComponent(path).absoluteString + "?q=%@",
             "homeURL": root.appendingPathComponent(path + "-home").absoluteString,
             "region": "international", "isBuiltIn": false, "isVisible": visible,
             "sortOrder": 0, "usageCount": 0, "isCustom": true]
        }
        let a = platform("Panel Alpha", "alpha"), b = platform("Panel Beta", "beta"), hidden = platform("Panel Hidden", "hidden", visible: false)
        let groups: [[String: Any]] = [
            ["id": UUID().uuidString, "name": "Panel A", "platformIDs": [a["id"]!, hidden["id"]!]],
            ["id": UUID().uuidString, "name": "Panel B", "platformIDs": [b["id"]!]],
            ["id": UUID().uuidString, "name": "Panel Empty", "platformIDs": []]]
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO", "-browser_toolbar_hidden", "NO",
            "-keep_fullscreen_browsing", "NO", "-show_platform_bar", "NO", "-auto_hide_platform_bar", "YES",
            "-platform_config", try platformArgumentData([a,b,hidden]), "-platform_config_version", "47",
            "-custom_groups", try platformArgumentData(groups), "-last_selected_group_id", groups[0]["id"] as! String,
            "-browser_toolbar_actions", "(platforms,back,tabs,more)",
            "-browser_more_menu_actions", "(platforms,newTab,siteInformation,forward,fullscreen,desktopMode,darkMode,tabs,share,copyLink,bookmark,library)",
            "-browser_toolbar_leading_action", "platforms"]
        app.launch(); defer { app.terminate() }
        let query = app.textFields["search.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap(); query.typeText("panelterm\n")
        XCTAssertTrue(app.webViews.staticTexts["Ad settings page fixture"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["search.group-picker"].exists)
        XCTAssertTrue(app.buttons["browser.addressLeading.platforms"].exists)
        XCTAssertFalse(app.buttons["browser.siteInformation"].exists)
        let open = app.buttons["browser.action.platforms"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(app.buttons["browser.platform." + (hidden["id"] as! String)].waitForExistence(timeout: 5))
        app.buttons["browser.platformGroupPicker"].tap()
        app.buttons["browser.platformGroup.group:" + (groups[1]["id"] as! String)].tap()
        XCTAssertFalse(fixture.requestSummary.contains("GET /beta?q=panelterm "), "Browsing groups must not navigate")
        app.buttons["browser.platform." + (b["id"] as! String)].tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixture.requestSummary.contains("GET /beta?q=panelterm ") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed, fixture.requestSummary)
        XCTAssertTrue(app.buttons["browser.platforms.close"].waitForNonExistence(timeout: 5))
        app.buttons["browser.more"].firstMatch.tap()
        app.descendants(matching: .any).matching(identifier: "browser.moreMenu.platforms").firstMatch.tap()
        XCTAssertTrue(app.buttons["browser.platform." + (b["id"] as! String)].waitForExistence(timeout: 5))
        app.buttons["browser.platformGroupPicker"].tap()
        app.buttons["browser.platformGroup.group:" + (groups[2]["id"] as! String)].tap()
        XCTAssertTrue(app.staticTexts["No platforms yet"].waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "browser.platforms.close").firstMatch.tap()
        app.buttons["browser.more"].firstMatch.tap()
        app.descendants(matching: .any).matching(identifier: "browser.moreMenu.newTab").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "new-tab.search.field").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        app.buttons["browser.platformGroupPicker"].tap()
        app.buttons["browser.platformGroup.group:" + (groups[1]["id"] as! String)].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "platform-grid-hidden-bar"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["browser.platform." + (b["id"] as! String)].tap()
        let home = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixture.requestSummary.contains("GET /beta-home ") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [home], timeout: 10), .completed, fixture.requestSummary)
        open.tap()
        app.buttons["browser.platformGroupPicker"].tap()
        app.buttons["browser.platformGroup.group:" + (groups[0]["id"] as! String)].tap()
        app.buttons["browser.platform." + (a["id"] as! String)].tap()
        let direct = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixture.requestSummary.contains("GET /alpha-home ") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [direct], timeout: 10), .completed, fixture.requestSummary)
        app.buttons["browser.more"].firstMatch.tap()
        app.descendants(matching: .any).matching(identifier: "browser.moreMenu.siteInformation").firstMatch.tap()
        XCTAssertTrue(app.buttons["site.user-agent"].waitForExistence(timeout: 5), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
        app.buttons["browser.addressLeading.platforms"].tap()
        let manage = app.buttons["browser.platforms.settings"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5)); manage.tap()
        XCTAssertTrue(app.navigationBars["Platform Management"].waitForExistence(timeout: 5))
    }

    func testGesturesShortcutsGroupKeepsAllFourDestinationsInteractive() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Gestures")
        app.buttons["settings.interaction"].tap()
        XCTAssertTrue(app.navigationBars["Gestures & Shortcuts"].waitForExistence(timeout: 5))
        for (route, ready) in [("shake", "settings.shake.direction"), ("gestures", "settings.gestures.enabled"),
                               ("feedback", "settings.feedback.haptics"), ("quickActions", "quick-actions.explanation")] {
            let row = app.buttons["settings.interaction." + route]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 5))
            if let done = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.first(where: { $0.isHittable }) {
                done.tap()
            } else { app.navigationBars.buttons.firstMatch.tap() }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "gestures-shortcuts-four-destinations"; shot.lifetime = .keepAlways; add(shot)
    }

    func testUnifiedToolbarSectionsKeepIndependentDraftsAndSavedLayouts() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-browser_toolbar_actions", "(home,back,tabs,more)"]
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Toolbars")
        let entry = app.buttons["settings.toolbar"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let sections = app.segmentedControls["browser-toolbar.section"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5)); XCTAssertEqual(sections.buttons.count, 3)
        XCTAssertTrue(sections.buttons.element(boundBy: 0).isSelected)
        let restore = app.buttons["toolbar.restore"]
        let homeRestore = restore.frame
        let homeSave = app.buttons["home-toolbar.save"].frame
        for index in [1, 2] {
            sections.buttons.element(boundBy: index).tap()
            let save = app.buttons["browser-toolbar.save"]
            XCTAssertTrue(save.waitForExistence(timeout: 3))
            XCTAssertEqual(restore.frame.minY, homeRestore.minY, accuracy: 1)
            XCTAssertEqual(restore.frame.height, homeRestore.height, accuracy: 1)
            XCTAssertEqual(restore.frame.width, homeRestore.width, accuracy: 1)
            XCTAssertEqual(save.frame.minY, homeSave.minY, accuracy: 1)
            XCTAssertEqual(save.frame.height, homeSave.height, accuracy: 1)
        }
        sections.buttons.element(boundBy: 1).tap()
        func choose(_ id: String) {
            let button = app.buttons[id]
            for _ in 0..<5 where !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, id); button.tap()
        }
        func save(_ id: String) {
            let button = app.buttons[id]
            button.tap()
            let notice = app.descendants(matching: .any)["toolbar.saved"].firstMatch
            XCTAssertTrue(notice.waitForExistence(timeout: 5))
            XCTAssertEqual(button.label, "Saved")
            XCTAssertLessThan(notice.frame.maxY, button.frame.minY)
        }
        func goBackAndReopen() {
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            XCTAssertTrue(sections.waitForExistence(timeout: 5))
            sections.buttons.element(boundBy: 1).tap()
        }
        choose("browser-toolbar.slot.0")
        choose("browser-toolbar.action.forward") // leave Browsing unsaved
        sections.buttons.element(boundBy: 0).tap()
        choose("home-toolbar.slot.0")
        choose("home-toolbar.action.newTab")
        save("home-toolbar.save")
        sections.buttons.element(boundBy: 2).tap()
        choose("browser-toolbar.more-slot.11")
        choose("browser-toolbar.action.platforms")
        save("browser-toolbar.save")
        goBackAndReopen()
        XCTAssertEqual(app.buttons["browser-toolbar.preview-slot.0"].label, "Home Screen", "Saving Home and More must not save the pending Browsing draft")
        sections.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home-toolbar.slot.0"].label.contains("New Tab"))
        // Swipe the native pager from Home to Browsing, then Browsing to More.
        func swipePage() {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let y = sections.frame.maxY - app.frame.minY + 40
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.84, dy: y))
            start.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.16, dy: y)))
        }
        swipePage()
        XCTAssertTrue(sections.buttons.element(boundBy: 1).isSelected)
        swipePage()
        XCTAssertTrue(sections.buttons.element(boundBy: 2).isSelected)
        XCTAssertTrue(app.buttons["browser-toolbar.more-slot.11"].label.contains("Platforms"))
        // Reset only More, then verify Home and Browsing are unchanged.
        app.buttons["toolbar.restore"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Restore Defaults"].tap()
        goBackAndReopen()
        XCTAssertEqual(app.buttons["browser-toolbar.preview-slot.0"].label, "Home Screen")
        sections.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.buttons["browser-toolbar.more-slot.11"].label.contains("Library"))
        sections.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home-toolbar.slot.0"].label.contains("New Tab"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "unified-toolbar-independent-home-layout"; shot.lifetime = .keepAlways; add(shot)
    }

    func testMorePanelEditorKeepsLastSlotSafeAcrossSectionSwitches() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Customize Browser Toolbar")
        app.buttons["settings.toolbar"].firstMatch.tap()
        let section = app.segmentedControls["browser-toolbar.section"]
        XCTAssertTrue(section.waitForExistence(timeout: 5)); section.buttons.element(boundBy: 2).tap()
        func checkPinnedPreview(_ slot: XCUIElement, list: XCUIElement, name: String) {
            let field = app.textFields["browser-toolbar.action-search"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(list.exists)
            let previewY = slot.frame.midY
            let fieldY = field.frame.minY
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.72))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.44))
            start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
            XCTAssertLessThan(field.frame.minY, fieldY - 8, app.debugDescription)
            XCTAssertEqual(slot.frame.midY, previewY, accuracy: 2)
            XCTAssertTrue(slot.isHittable)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        let last = app.buttons["browser-toolbar.more-slot.11"]
        XCTAssertTrue(last.waitForExistence(timeout: 5)); last.tap()
        checkPinnedPreview(last, list: app.scrollViews["browser-toolbar.more-actions"], name: "toolbar-more-pinned")
        let option = app.buttons["browser-toolbar.action.platforms"]
        for _ in 0..<4 where !option.isHittable { app.swipeUp() }
        XCTAssertTrue(option.isHittable); option.tap()
        for _ in 0..<5 where !section.isHittable { app.swipeDown() }
        section.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["browser-toolbar.slot.4"].waitForExistence(timeout: 5))
        let leading = app.buttons["browser-toolbar.slot.5"]
        checkPinnedPreview(leading, list: app.scrollViews["browser-toolbar.browsing-actions"], name: "toolbar-browsing-pinned")
        XCTAssertTrue(leading.exists); leading.tap()
        let leadingOption = app.buttons["browser-toolbar.action.platforms"]
        for _ in 0..<4 where !leadingOption.isHittable { app.swipeUp() }
        leadingOption.tap()
        for _ in 0..<5 where !section.isHittable { app.swipeDown() }
        XCTAssertEqual(app.buttons["browser-toolbar.leading-preview"].label, "Platforms")
        section.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(last.label.contains("Platforms"), last.label)
        app.buttons["browser-toolbar.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "custom-more-panel"; shot.lifetime = .keepAlways; add(shot)
    }

    func testHiddenPlatformBarHidesAutomaticControlsAndCanBeEnabledInManagement() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-icloud_sync_enabled", "NO", "-wallpaper_source", "solid",
            "-home_toolbar_actions", "(platforms)", "-restore_last_page_on_launch", "NO"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let automatic = app.switches["platform.auto-hide-platforms"]
        let visible = app.switches["platform.show-platform-bar"]
        func flipVisibility() {
            let native = visible.descendants(matching: .switch).firstMatch
            if native.exists { native.tap() }
            else { visible.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        XCTAssertTrue(visible.waitForExistence(timeout: 10)); XCTAssertTrue(visible.label.contains("Show Platform Bar"))
        if visible.value as? String == "0" { flipVisibility() }
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        flipVisibility()
        XCTAssertTrue(app.buttons["browsing-guide.done"].waitForExistence(timeout: 5)); app.buttons["browsing-guide.done"].tap()
        XCTAssertTrue(automatic.waitForNonExistence(timeout: 5))
        flipVisibility()
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "platform-visibility-controls"; shot.lifetime = .keepAlways; add(shot)
        let automaticSwitch = automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        let wasEnabled = automatic.value as? String == "1"
        if wasEnabled { automaticSwitch.tap() }
        XCTAssertFalse(app.buttons["platform.guide.done"].exists)
        automaticSwitch.tap()
        XCTAssertTrue(app.staticTexts["platform.guide.autoHide"].waitForExistence(timeout: 5), app.debugDescription)
        let guide = XCTAttachment(screenshot: app.screenshot())
        guide.name = "platform-auto-hide-guide"
        guide.lifetime = .keepAlways
        add(guide)
        app.buttons["platform.guide.done"].tap()
        XCTAssertEqual(automatic.value as? String, "1")
        app.buttons["platform.layout"].tap()
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "1")
        automaticSwitch.tap()
        XCTAssertEqual(automatic.value as? String, "0")
        XCTAssertFalse(app.buttons["platform.guide.done"].exists)
        automaticSwitch.tap()
        XCTAssertTrue(app.staticTexts["platform.guide.autoHide"].waitForExistence(timeout: 5))
        app.buttons["platform.guide.done"].tap()
        if !wasEnabled { automaticSwitch.tap() }
        app.buttons["platform.layout"].tap()
    }

    func testHidingPlatformBarShowsIllustratedToolbarShortcutGuide() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        // Remove the prior launch override; UI changes should persist normally.
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Show Platform Bar")
        let platforms = app.buttons["settings.platforms"].firstMatch
        XCTAssertTrue(platforms.waitForExistence(timeout: 5)); platforms.tap()
        let visible = app.switches["platform.show-platform-bar"]
        XCTAssertTrue(visible.waitForExistence(timeout: 5))
        if visible.value as? String == "0" { visible.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        visible.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let customize = app.buttons["browsing-guide.customize-toolbar"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "hidden-platform-bar-guide"; shot.lifetime = .keepAlways; add(shot)
        customize.tap()
        XCTAssertTrue(app.segmentedControls["browser-toolbar.section"].waitForExistence(timeout: 5))
    }

    func testRestoredNewTabBuildsRegularAndFloatingMoreMenus() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-icloud_sync_enabled", "NO", "-icloud_bookmarks_sync_enabled", "NO",
            "-review.requestedOnce", "YES", "-ad_block_enabled", "NO", "-keep_fullscreen_browsing", "NO",
            "-home_toolbar_actions", "(newTab)", "-browser_toolbar_hidden", "NO"]
        app.launch(); defer { app.terminate() }
        let create = app.buttons["home.toolbar.0"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        func openMore(_ name: String) {
            let menu = app.buttons["browser.more"].firstMatch
            // Startup can return to Home while retaining the saved tab models.
            // Enter a new tab without clearing any of that restored state.
            if !menu.exists, create.exists { create.tap() }
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription); menu.tap()
            XCTAssertTrue(app.buttons["browser.moreMenu.pageTools"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
        }
        openMore("new-tab-regular-more-menu")
        app.terminate(); app.launch()
        openMore("restored-new-tab-regular-more-menu")
        app.terminate()
        app.launchArguments[app.launchArguments.count - 1] = "YES"
        app.launch()
        openMore("restored-new-tab-floating-more-menu")
    }

    func testSettingsBackupRestoreReturnsToInteractiveList() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Settings Backups")
        app.buttons["settings.backups"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Sync & Backups"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.icloud-sync"].exists)
        XCTAssertTrue(app.switches["settings.icloud-bookmarks"].exists)
        XCTAssertTrue(app.staticTexts["Manual backups"].exists)
        let save = app.buttons["settings.backups.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8)); save.tap()
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.backups.restore.")).firstMatch
        scrollStorageRow(restore, in: app)
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
        let confirm = app.alerts.buttons["Restore"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); let start = Date(); confirm.tap()
        scrollStorageRow(save, in: app)
        let interactive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 10), .completed)
        print("BACKUP RESTORE UI elapsed \(Date().timeIntervalSince(start))s")
        save.tap()
        let importButton = app.buttons["settings.backups.import"]
        let exportButton = app.buttons["settings.backups.export"]
        scrollStorageRow(importButton, in: app)
        XCTAssertTrue(importButton.isHittable && exportButton.isHittable)
        XCTAssertEqual(importButton.frame.midY, exportButton.frame.midY, accuracy: 4)
        XCTAssertFalse(app.navigationBars.buttons["settings.backups.clear"].exists, "Clear belongs to manual backups, not the page toolbar")
        exportButton.tap()
        // UIKit's menu view exposes the date labels but can drop the SwiftUI identifiers.
        let exportChoice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label MATCHES %@",
            "settings.backups.export.", #".*\d{1,2}:\d{2}:\d{2}.*"#)).firstMatch
        XCTAssertTrue(exportChoice.waitForExistence(timeout: 5), app.debugDescription)
        exportChoice.tap()
        let cancelExport = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancelExport.waitForExistence(timeout: 8), app.debugDescription)
        cancelExport.tap()
        let manage = app.buttons["settings.backups.manage"]
        scrollStorageRow(manage, in: app)
        XCTAssertTrue(manage.isEnabled)
        let design = XCTAttachment(screenshot: app.screenshot()); design.name = "manual-backups-action-strip-and-records"; design.lifetime = .keepAlways; add(design)
        manage.tap()
        let clear = app.buttons["settings.backups.clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        // iOS 26 exposes both a wrapper and its nested button for this sheet.
        let confirmClear = app.sheets.buttons["settings.backups.confirm-clear"].firstMatch
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 5)); confirmClear.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: manage)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed)
        let history = app.staticTexts["Automatic & previous backups"]
        scrollStorageRow(history, in: app)
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        let retained = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.backups.restore.")).firstMatch
        scrollStorageRow(retained, in: app)
        XCTAssertTrue(retained.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "configuration-backup-restored-interactive"; shot.lifetime = .keepAlways; add(shot)
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back' OR label == 'Settings'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.buttons["settings.backups"].waitForExistence(timeout: 5))
    }

    private func revealSearch(in app: XCUIApplication) -> XCUIElement {
        let search = app.searchFields.firstMatch
        for _ in 0..<6 {
            if search.waitForExistence(timeout: 0.5) { return search }
            // iOS 16/17 collapses the navigation-drawer search field. Reveal
            // it with a short pull instead of assuming iOS 26's floating bar.
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            guard list.exists else { continue }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 170)))
        }
        return search
    }

    private func scrollStorageRow(_ row: XCUIElement, in app: XCUIApplication) {
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        let bar = app.navigationBars.firstMatch
        for _ in 0..<12 {
            // iOS 26's floating search bar can cover a row's tap point while
            // accessibility still reports the partly visible row as hittable.
            let bottomSearch = app.searchFields.allElementsBoundByIndex.first {
                $0.exists && $0.frame.midY > list.frame.midY && $0.frame.minY < list.frame.maxY
            }
            let bottom = min(list.frame.maxY - 24, bottomSearch.map { $0.frame.minY - 16 } ?? list.frame.maxY)
            if row.exists, row.isHittable, row.frame.minY > bar.frame.maxY + 12, row.frame.maxY < bottom { return }
            let delta: CGFloat = row.exists && row.frame.midY <= bar.frame.maxY + 12 ? 180 : -180
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta)), withVelocity: .slow, thenHoldForDuration: 0.1)
        }
    }

    func testStorageRefreshesAfterDeletingADownloadAndReturning() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else {
            throw XCTSkip("Requires the isolated QA container download fixture")
        }
        continueAfterFailure = false
        let name = "storage-refresh-fixture.bin"
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-files.gridView", "NO"]
        app.launch(); defer { app.terminate() }
        guard app.buttons["home.toolbar.0"].waitForExistence(timeout: 10) else { XCTFail(app.debugDescription); return }
        app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        guard app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        app.buttons["Storage"].firstMatch.tap()
        openStorageSubgroup("files", in: app)
        let row = app.buttons["storage.manage.downloads"]
        scrollStorageRow(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let measured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (Int64(row.value as? String ?? "") ?? 0) >= 2 * 1024 * 1024 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 8), .completed)
        let before = try XCTUnwrap(Int64(row.value as? String ?? "")); row.tap()
        let file = app.descendants(matching: .any).matching(identifier: "files.item." + name).firstMatch
        let fileSearch = app.textFields["library.search"].firstMatch
        guard fileSearch.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        fileSearch.tap(); fileSearch.typeText(name)
        guard file.waitForExistence(timeout: 8) else { XCTFail(app.debugDescription); return }
        let fileRow = app.cells.containing(.staticText, identifier: name).firstMatch
        guard fileRow.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        fileRow.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete"].firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        XCTAssertTrue(file.waitForNonExistence(timeout: 5))
        app.navigationBars["Files"].buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = Int64(row.value as? String ?? "") else { return false }
            return value <= before - 2 * 1024 * 1024
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 8), .completed, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "storage-refreshed-after-file-deletion"; shot.lifetime = .keepAlways; add(shot)
    }

    func testStorageCacheConfirmationIsAnchoredAndCleanupChangesUsage() throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else {
            throw XCTSkip("Requires the isolated QA container cache fixture; never operates on user data")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-files.gridView", "NO"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        guard app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        app.buttons["Storage"].firstMatch.tap()
        openStorageSubgroup("cache", in: app)
        let row = app.buttons["storage.manage.otherCaches"]
        let trash = app.buttons["storage.clearButton.otherCaches"]
        for _ in 0..<5 where !trash.isHittable { app.swipeUp() }
        let measured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in trash.isEnabled && (Int64(row.value as? String ?? "") ?? 0) >= 1024 * 1024 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 8), .completed)
        let before = try XCTUnwrap(Int64(row.value as? String ?? ""))
        trash.tap()
        let remove = app.buttons["storage.confirm.delete"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(abs(remove.frame.midY - trash.frame.midY), 220, "Confirmation must remain next to the row, not in the middle of the whole list")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "storage-delete-confirmation-at-source"; shot.lifetime = .keepAlways; add(shot)
        remove.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = Int64(row.value as? String ?? "") else { return false }
            return value <= before - 1024 * 1024
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 8), .completed, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testStorageDetailClearConfirmationKeepsItsWidthAtTheLeftEdge() throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else {
            throw XCTSkip("Requires the isolated QA wallpaper-cache fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-files.gridView", "NO"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        guard app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        app.buttons["Storage"].firstMatch.tap()
        openStorageSubgroup("cache", in: app)
        let entry = app.buttons["storage.manage.wallpaperCache"]
        scrollStorageRow(entry, in: app)
        guard entry.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }; entry.tap()
        let clear = app.buttons["storage.clear.wallpaperCache"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed); clear.tap()
        let remove = app.buttons["storage.confirm.delete"]
        guard remove.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        XCTAssertTrue(remove.isHittable)
        XCTAssertGreaterThan(remove.frame.width, 60)
        XCTAssertGreaterThanOrEqual(remove.frame.minX, 8)
        XCTAssertLessThanOrEqual(remove.frame.maxX, app.frame.maxX - 8)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "storage-left-clear-confirmation"; shot.lifetime = .keepAlways; add(shot)
        remove.tap()
        let emptied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [emptied], timeout: 8), .completed, app.debugDescription)
    }

    func testStorageBulkCleanupDefaultsExcludeSavedContent() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launch(); defer { app.terminate() }
        app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        app.buttons["Storage"].firstMatch.tap()
        let entry = app.buttons["storage.cleanup"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let safe = app.buttons["storage.cleanup.choice.webData"]
        XCTAssertTrue(safe.waitForExistence(timeout: 5)); XCTAssertEqual(safe.value as? String, "1")
        let saved = app.buttons["storage.cleanup.choice.backups"]
        for _ in 0..<8 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); XCTAssertEqual(saved.value as? String, "0"); saved.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: saved)], timeout: 3), .completed)
        let execute = app.buttons["storage.cleanup.execute"]
        XCTAssertFalse(execute.isEnabled)
        let field = app.textFields["storage.cleanup.confirmation"]
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("CLEA")
        XCTAssertFalse(execute.isEnabled); field.typeText("R"); XCTAssertTrue(execute.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "storage-cleanup-explicit-saved-data"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    func testCompactBrowserPopoversStayAnchoredAndContentSized() async throws {
        let server = try AdSettingsPageFixture(); let url = try await server.start(); defer { server.stop() }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false)
        app.launchArguments += ["-privacy_https_upgrade_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-browser_toolbar_leading_action", "siteInformation"]
        app.launch(); defer { app.terminate() }
        let query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap(); query.typeText(url.absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Ad settings page fixture"].firstMatch.waitForExistence(timeout: 20))
        for (entry, child, name) in [("browser.siteInformation", "site.user-agent", "site-information"), ("browser.more", "browser.moreMenu.pageTools", "more-menu")] {
            let button = app.buttons[entry].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
            let item = app.buttons[child].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
            if #unavailable(iOS 16.4) {
                let host = app.descendants(matching: .any).matching(identifier: "soulo.legacy-popover").firstMatch
                XCTAssertTrue(host.waitForExistence(timeout: 5)); XCTAssertLessThan(host.frame.height, app.frame.height * 0.82)
            }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "compact-popover-" + name; shot.lifetime = .keepAlways; add(shot)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)).tap()
        }
    }

    func testHomeTitleAndSubtitleCanRestoreTheirDefaults() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Home")
        let home = app.buttons["settings.homeDisplay"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5)); home.tap()
        XCTAssertTrue(app.buttons["home-toolbar.editor.visibility"].isSelected)
        let preview = app.descendants(matching: .any)["home-toolbar.preview.heading"].firstMatch
        for (id, expected) in [("title", "Soulo"), ("subtitle", "Search anytime, anywhere.")] {
            let visibility = app.buttons["home-toolbar.visibility." + id]
            XCTAssertTrue(visibility.waitForExistence(timeout: 5))
            if !visibility.isSelected { visibility.tap() }
            let editor = app.buttons["home-toolbar.heading.edit." + id]
            XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
            let input = app.textFields["home-toolbar.heading.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let value = input.value as? String ?? ""
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + "Custom QA " + id)
            XCTAssertEqual(input.value as? String, "Custom QA " + id)
            app.buttons["home-toolbar.heading.done"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertTrue(preview.label.contains("Custom QA " + id), preview.label)
            editor.tap()
            let restore = app.buttons["home-toolbar.heading.reset"]
            XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertTrue(preview.label.contains(expected), preview.label)
        }

        let pane = app.scrollViews["home-toolbar.content"]
        let island = app.buttons["home-toolbar.visibility.liveActivity"]
        func revealIsland() {
            for _ in 0..<4 where !island.isHittable { pane.swipeUp() }
            XCTAssertTrue(island.isHittable)
        }
        revealIsland()
        let original = island.isSelected
        island.tap()
        XCTAssertNotEqual(island.isSelected, original)
        app.buttons["home-toolbar.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5)); home.tap()
        revealIsland()
        XCTAssertNotEqual(island.isSelected, original)
        island.tap()
        app.buttons["home-toolbar.save"].tap()
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "home-branding-defaults-restored"; image.lifetime = .keepAlways; add(image)
    }

    func testClearBookmarksRequiresTypedConfirmationAndCanBeCanceled() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"; app.launchEnvironment["SOULO_ACCEPTANCE_BOOKMARKS"] = "1"
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        app.buttons["Storage"].firstMatch.tap()
        app.buttons["storage.cleanup"].tap()
        let bookmarks = app.buttons["storage.cleanup.choice.bookmarks"]
        scrollStorageRow(bookmarks, in: app)
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 5)); bookmarks.tap()
        let field = app.textFields["storage.cleanup.confirmation"], execute = app.buttons["storage.cleanup.execute"]
        scrollStorageRow(field, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertFalse(execute.isEnabled)
        field.tap(); field.typeText("CLEA"); XCTAssertFalse(execute.isEnabled)
        field.typeText("R"); XCTAssertTrue(execute.isEnabled)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(field.exists); XCTAssertTrue(app.buttons["storage.cleanup"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "bookmark-clear-confirmation-canceled"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBatchImportPromptAndNamedGroups() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let slot = try XCTUnwrap(app.launchArguments.firstIndex(of: "-home_toolbar_actions"))
        app.launchArguments[slot + 1] = "(platforms)"
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO", "-platform_management_layout", "grid"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        app.buttons["platform.managementMenu"].tap()
        app.buttons["Batch Import"].firstMatch.tap()
        let promptEntry = app.buttons["batch-import.ai-prompt"]
        XCTAssertTrue(promptEntry.waitForExistence(timeout: 5)); XCTAssertTrue(promptEntry.isHittable)
        let layout = XCTAttachment(screenshot: app.screenshot()); layout.name = "batch-import-compact-cards"; layout.lifetime = .keepAlways; add(layout)
        promptEntry.tap()
        let copy = app.buttons["batch-import.copy-prompt"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        XCTAssertTrue(copy.label.contains("Copied"), copy.label)
        let explanation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy this prompt, add your requirements")).firstMatch
        XCTAssertTrue(explanation.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "batch-import-ai-prompt"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["AI Prompt"].buttons.firstMatch.tap()
        let field = app.textViews["batch-import.json"]
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let suffix = String(UUID().uuidString.prefix(6))
        let first = "QA Alpha " + suffix, second = "QA Beta " + suffix
        field.typeText("{\"groups\":[{\"name\":\"\(first)\",\"platforms\":[{\"name\":\"Alpha\",\"url\":\"https://alpha.example/\(suffix)?q=%@\"}]},{\"name\":\"\(second)\",\"platforms\":[{\"name\":\"Beta\",\"url\":\"https://beta.example/\(suffix)?q=%@\"}]}]}")
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        let execute = app.buttons["batch-import.execute"]
        XCTAssertTrue(execute.isHittable); XCTAssertTrue(execute.isEnabled); execute.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: execute)], timeout: 8), .completed)
        for name in [first, second] {
            let group = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", name)).firstMatch
            for _ in 0..<15 where !group.isHittable { app.swipeUp() }
            XCTAssertTrue(group.exists, app.debugDescription)
        }
        let result = XCTAttachment(screenshot: app.screenshot()); result.name = "batch-import-multiple-named-groups"; result.lifetime = .keepAlways; add(result)
    }

    func testVideoTakeoverSwitchStartsOffAndCanBeChanged() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_VIDEO_TAKEOVER_RESET"] = "1"
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Video Settings")
        let video = app.buttons["Video Settings"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 5)); video.tap()
        let toggle = app.switches["video-settings.takeover"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "video-takeover-setting"; screenshot.lifetime = .keepAlways; add(screenshot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testPlatformAIExportAndConfirmedReplacement() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let toolbar = try XCTUnwrap(app.launchArguments.firstIndex(of: "-home_toolbar_actions"))
        app.launchArguments[toolbar + 1] = "(platforms)"
        app.launchArguments += ["-platform_management_layout", "grid", "-icloud_bookmarks_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        app.buttons["platform.managementMenu"].tap(); app.buttons["Batch Import"].firstMatch.tap()
        app.buttons["batch-import.ai-prompt"].tap()
        let copy = app.buttons["batch-import.copy-platforms"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap(); XCTAssertTrue(copy.label.contains("Copied"))
        XCTAssertTrue(app.buttons["batch-import.export-platforms"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "platform-ai-copy-and-export"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["AI Prompt"].buttons.firstMatch.tap()
        let input = app.textViews["batch-import.json"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        let suffix = String(UUID().uuidString.prefix(6)), name = "Reorganized " + suffix
        input.typeText("{\"groups\":[{\"name\":\"\(name)\",\"platforms\":[{\"name\":\"AI platform\",\"url\":\"https://example.com/\(suffix)?q=%@\"}]}]}")
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        let replace = app.segmentedControls["batch-import.mode"].buttons["Replace all"]
        for _ in 0..<3 where !replace.isHittable { app.swipeUp() }
        XCTAssertTrue(replace.waitForExistence(timeout: 5)); replace.tap()
        app.buttons["batch-import.execute"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "A settings backup is saved")).firstMatch.exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(input.exists, "Cancel keeps the original configuration and editable import")
        app.buttons["batch-import.execute"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["batch-import.replace-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["batch-import.execute"].waitForNonExistence(timeout: 8))
        let group = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", name)).firstMatch
        for _ in 0..<12 where !group.isHittable { app.swipeUp() }
        XCTAssertTrue(group.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["AI platform"].exists)
        let result = XCTAttachment(screenshot: app.screenshot()); result.name = "platform-ai-replacement-applied"; result.lifetime = .keepAlways; add(result)
    }

    func testExitHistorySwitchClearsVisitsOnActualAppBackgroundAndKeepsSearchTerms() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_HISTORY"] = "1"
        app.launch(); defer { app.terminate() }
        let probe = app.staticTexts["qa.acceptance"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        func waitFor(_ value: String) -> Bool {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (probe.value as? String ?? "").contains(value) }, object: nil)
            return XCTWaiter.wait(for: [expected], timeout: 10) == .completed
        }
        XCTAssertTrue(waitFor("history-visits=1;history-queries=1"))
        app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        let storage = app.buttons["Storage"].firstMatch
        XCTAssertTrue(storage.waitForExistence(timeout: 5)); storage.tap()
        let toggle = app.switches["privacy.clear-browsing-on-exit"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons.firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 2); app.activate()
        XCTAssertTrue(waitFor("history-visits=0;history-queries=1"), probe.value as? String ?? app.debugDescription)
    }

    func testPlatformManagementAutoHideWorksInBothLayoutsAndPersists() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let position = app.launchArguments.firstIndex(of: "-home_toolbar_actions")!
        app.launchArguments[position + 1] = "(platforms)"
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_PLATFORM_RESET"] = "1"
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["qa.acceptance"].waitForExistence(timeout: 10))
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let toggle = app.switches["platform.auto-hide-platforms"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["platform.guide.autoHide"].waitForExistence(timeout: 5))
        app.buttons["platform.guide.done"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["platform.layout"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        entry.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); XCTAssertEqual(toggle.value as? String, "0")
    }

    func testWebsiteDataUsesChineseInStorageAndDetails() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments[1] = "zh-Hans"
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("存储空间")
        app.buttons["存储空间"].firstMatch.tap()
        let websiteData = app.buttons["storage.group.websites"]
        XCTAssertTrue(websiteData.waitForExistence(timeout: 8))
        XCTAssertTrue(websiteData.label.contains("网站数据"), websiteData.label)
        XCTAssertFalse(app.staticTexts["Website data"].exists)
        websiteData.tap()
        XCTAssertTrue(app.navigationBars["网站数据"].waitForExistence(timeout: 8), app.debugDescription)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "website-data-chinese"; image.lifetime = .keepAlways; add(image)
    }

    func testPopulatedRuleManagementFromStorage() {
        continueAfterFailure = false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        configure(app,enabled:true,fromSettings:true,populated:true)
        app.launch();defer{app.terminate()}
        let settings=app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout:10));settings.tap()
        let storage=app.buttons["Storage"].firstMatch
        for _ in 0..<8 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.waitForExistence(timeout:8)); XCTAssertTrue(storage.isHittable)
        storage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout:8),app.debugDescription)
        openStorageSubgroup("saved", in: app)
        let filtering=app.buttons["storage.manage.filterRules"]
        for _ in 0..<4 where !filtering.isHittable {app.swipeUp()}
        XCTAssertTrue(filtering.waitForExistence(timeout:8)); XCTAssertTrue(filtering.isHittable)
        filtering.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Ad Blocking"].waitForExistence(timeout:5))
        checkRuleRoutes(app,populated:true)
    }
    private func openStorageSubgroup(_ id: String, in app: XCUIApplication) {
        let entry = app.buttons["storage.group." + id]
        guard entry.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        entry.tap()
    }
    private func storageSubgroup(_ category: String) -> (String, String) {
        if ["webData", "websiteStorage"].contains(category) { return ("websites", "Website data") }
        if category == "otherData" { return ("other", "Other app data") }
        if ["downloads", "downloadTasks"].contains(category) { return ("files", "Downloads & files") }
        if ["wallpaperCache", "otherCaches", "temporaryFiles", "ruleCache", "tabSnapshots", "favicons"].contains(category) { return ("cache", "Caches & temporary files") }
        return ("saved", "Saved content")
    }
    private func storageCategoryEntry(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let group = storageSubgroup(id).0
        if group == "websites" || group == "other" { return app.buttons["storage.group." + group] }
        openStorageSubgroup(group, in: app)
        let entry = app.buttons["storage.manage." + id]
        scrollStorageRow(entry, in: app)
        return entry
    }
    private func closeStorageCategory(_ id: String, title: String, in app: XCUIApplication) {
        app.navigationBars[title].buttons.firstMatch.tap()
        let (group, groupTitle) = storageSubgroup(id)
        if group != "websites" && group != "other" {
            XCTAssertTrue(app.navigationBars[groupTitle].waitForExistence(timeout: 5))
            app.navigationBars[groupTitle].buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 5))
    }

    func testAdditionalStorageCategoriesAreVisibleAndManageable() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        XCTAssertTrue(app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Storage"].firstMatch.tap()
        for (id,title) in [("wallpaperCache","Wallpaper cache"),("otherCaches","Other caches"),("temporaryFiles","Temporary files"),("ruleCache","Cached Rules"),
            ("downloadTasks","Download task data"),("extensions","Scripts & Extensions"),("personalData","Settings and records"),
            ("sharedData","Shared app data"),("otherData","Other app data")] {
            let entry = storageCategoryEntry(id, in: app)
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8), app.debugDescription)
            if ["wallpaperCache","otherCaches","temporaryFiles","ruleCache","downloadTasks"].contains(id) { XCTAssertTrue(app.buttons["storage.clear." + id].exists) }
            closeStorageCategory(id, title: title, in: app)
        }
    }

    func testStorageManagementRoutesAndReadingExplanation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        XCTAssertTrue(app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Storage"].firstMatch.tap()
        for (id,title) in [("websiteStorage","Website data"),("downloads","Files"),("wallpapers","My Favorites"),("readingData","Reading data"),("filterRules","Ad Blocking"),("backups","Sync & Backups")] {
            let entry = storageCategoryEntry(id, in: app)
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8), app.debugDescription)
            if id == "readingData" { XCTAssertTrue(app.buttons["Reading list"].exists) }
            closeStorageCategory(id, title: title, in: app)
        }
    }

    func testStorageFiveGroupsAndBulkWebsiteDataClear() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        XCTAssertTrue(app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Storage"].firstMatch.tap()
        for group in ["websites", "files", "cache", "saved", "other"] { XCTAssertTrue(app.buttons["storage.group." + group].waitForExistence(timeout: 5), app.debugDescription) }
        let overview = XCTAttachment(screenshot: app.screenshot()); overview.name = "storage-five-groups"; overview.lifetime = .keepAlways; add(overview)
        openStorageSubgroup("websites", in: app)
        XCTAssertFalse(app.staticTexts["IndexedDB"].exists)
        let clear = app.buttons["storage.websites.clear-all"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); clear.tap()
        let confirm = app.alerts.buttons.matching(identifier: "storage.confirm.delete").firstMatch
        let confirmationReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            confirm.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmationReady], timeout: 8), .completed, app.debugDescription)
        let warning = XCTAttachment(screenshot: app.screenshot()); warning.name = "storage-all-websites-confirmation"; warning.lifetime = .keepAlways; add(warning)
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in clear.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.navigationBars["Website data"].exists)
    }

    func testStorageDefaultsAndSettingsQuickClearWorkWithoutAnExtraConfirmation() {
        continueAfterFailure = false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        configure(app,enabled:false,fromSettings:true)
        app.launch();defer{app.terminate()}
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout:10));app.buttons["home.toolbar.0"].tap()
        let search=app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5));search.tap();search.typeText("Storage")
        let storage=app.buttons["settings.storage"].firstMatch, quick=app.buttons["settings.quickClear"]
        XCTAssertTrue(storage.waitForExistence(timeout:5));XCTAssertTrue(quick.exists)
        XCTAssertGreaterThan(quick.frame.midY,storage.frame.midY)
        storage.tap()
        let cleanup=app.buttons["storage.cleanup"]
        XCTAssertTrue(cleanup.waitForExistence(timeout:10));cleanup.tap()
        for category in ["tabSnapshots","favicons"] {
            let choice=app.buttons["storage.cleanup.choice."+category]
            XCTAssertTrue(choice.waitForExistence(timeout:5));XCTAssertEqual(choice.value as? String,"0")
        }
        let defaults=XCTAttachment(screenshot:app.screenshot());defaults.name="cleanup-previews-and-icons-default-off";defaults.lifetime = .keepAlways;add(defaults)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(quick.waitForExistence(timeout:5));quick.tap()
        XCTAssertFalse(app.buttons["storage.confirm.delete"].exists,"The shortcut starts the safe defaults immediately")
        let success=app.descendants(matching:.any)["settings.quickClear.success"].firstMatch
        XCTAssertTrue(success.waitForExistence(timeout:25),app.debugDescription)
        let size=app.descendants(matching:.any)["settings.quickClear.size"].firstMatch
        let measured=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            size.exists && Int64(size.value as? String ?? "") != nil
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[measured],timeout:15),.completed,app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists,"Successful cleanup is shown inline without an automatic alert")
        let finished=XCTAttachment(screenshot:app.screenshot());finished.name="settings-quick-cleanup-finished";finished.lifetime = .keepAlways;add(finished)
        XCTAssertTrue(quick.isEnabled)
    }

    func testLargeWebsiteDataTotalsAndClearFromOverviewRemainResponsive() throws {
        guard ProcessInfo.processInfo.environment["SOULO_WEBSITE_LARGE_FIXTURE"] == "1",
              SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else {
            throw XCTSkip("Requires the seeded isolated 512 MiB website store")
        }
        continueAfterFailure = false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        configure(app,enabled:false,fromSettings:true)
        app.launch();defer{app.terminate()}
        app.buttons["home.toolbar.0"].tap()
        let search=app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5));search.tap();search.typeText("Storage")
        app.buttons["Storage"].firstMatch.tap()
        let websites=app.buttons["storage.group.websites"]
        XCTAssertTrue(websites.waitForExistence(timeout:10))
        let seeded=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            (Int64(websites.value as? String ?? "") ?? 0)>=512*1024*1024
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[seeded],timeout:20),.completed)
        websites.tap()
        let total=app.descendants(matching:.any)["storage.websites.total"].firstMatch
        let populated=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            (Int64(total.value as? String ?? "") ?? 0)>=512*1024*1024
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[populated],timeout:20),.completed)
        let rows=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","storage.site.")).allElementsBoundByIndex
        let siteBytes=rows.reduce(Int64(0)){ $0+(Int64($1.value as? String ?? "") ?? 0) }
        let shared=app.descendants(matching:.any)["storage.websites.shared"].firstMatch
        let sharedBytes=shared.exists ? Int64(shared.value as? String ?? "") ?? 0 : 0
        XCTAssertEqual(siteBytes+sharedBytes,Int64(total.value as? String ?? ""))
        let details=XCTAttachment(screenshot:app.screenshot());details.name="website-512MB-breakdown";details.lifetime = .keepAlways;add(details)
        app.navigationBars.buttons.firstMatch.tap()
        let clear=app.buttons["storage.clear.websites"]
        XCTAssertTrue(clear.waitForExistence(timeout:5));clear.tap()
        let confirmation=app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout:5),"The trash icon must present a native confirmation without starting cleanup")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(clear.isEnabled)
        XCTAssertGreaterThanOrEqual(Int64(websites.value as? String ?? "") ?? 0,512*1024*1024,
            "Cancelling confirmation must leave website data untouched")
        clear.tap()
        app.buttons["storage.confirm.delete"].tap()
        // Navigation stays usable even if WebKit is still deleting data.
        let back=app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.isEnabled);back.tap()
        XCTAssertTrue(app.buttons["settings.storage"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
        if !app.buttons["Storage"].firstMatch.waitForExistence(timeout:2) {
            search.tap();search.typeText("Storage")
        }
        app.buttons["Storage"].firstMatch.tap()
        let reclaimed=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            websites.exists && (Int64(websites.value as? String ?? "") ?? Int64.max)<32*1024*1024
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[reclaimed],timeout:30),.completed,app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let after=XCTAttachment(screenshot:app.screenshot());after.name="website-512MB-cleared-without-freeze";after.lifetime = .keepAlways;add(after)
    }

    func testManagedOfflineMediaCanBeDeletedFromOtherStorage() throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else { throw XCTSkip("Requires isolated storage fixture") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        XCTAssertTrue(app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Storage"].firstMatch.tap()
        openStorageSubgroup("other", in: app)
        let clear = app.buttons["storage.clear.managed.com.apple.UserManagedAssets.StorageCleanupFixture"]
        scrollStorageRow(clear, in: app)
        XCTAssertTrue(clear.waitForExistence(timeout: 8)); clear.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "offline videos")).firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "managed-offline-clear-warning"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["storage.confirm.delete"].tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 20), app.debugDescription)
    }

    func testOtherStorageBulkCleanupIncludesOfflineVideosWithTapConfirmation() throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else { throw XCTSkip("Requires isolated storage fixture") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        XCTAssertTrue(app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Storage"].firstMatch.tap()
        let remove = app.buttons["storage.group.clear.other"]
        scrollStorageRow(remove, in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 8)); remove.tap()
        let caches = app.buttons["storage.cleanup.choice.systemCaches"], media = app.buttons["storage.cleanup.choice.offlineMedia"]
        XCTAssertTrue(caches.waitForExistence(timeout: 5)); XCTAssertEqual(caches.value as? String, "1")
        XCTAssertTrue(media.exists); XCTAssertEqual(media.value as? String, "0")
        XCTAssertFalse(app.buttons["storage.cleanup.choice.bookmarks"].exists)
        media.tap()
        let execute = app.buttons["storage.cleanup.execute"]
        let field = app.textFields["storage.cleanup.confirmation"]
        XCTAssertFalse(field.exists, "Offline remnants only need a tap confirmation")
        XCTAssertTrue(execute.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "other-storage-bulk-confirmation"; shot.lifetime = .keepAlways; add(shot)
        execute.tap()
        let confirmation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Clear", "storage.cleanup.execute"))
                .allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmation], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Cached Rules、")).firstMatch.exists,
                       "A scoped cleanup must not select hidden categories")
        try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Clear", "storage.cleanup.execute"))
            .allElementsBoundByIndex.first { $0.isHittable }).tap()
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.alerts.firstMatch.exists || (!media.exists && remove.exists)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 25), .completed)
        if app.alerts.firstMatch.exists { app.alerts.buttons["Done"].firstMatch.tap() }
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        scrollStorageRow(app.buttons["storage.group.other"], in: app)
        openStorageSubgroup("other", in: app)
        XCTAssertTrue(app.navigationBars["Other app data"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["storage.clear.managed.com.apple.UserManagedAssets.StorageCleanupFixture"].exists)
    }

    func testTemporaryStorageOffersConfirmedStopAndClear() throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else { throw XCTSkip("Requires isolated storage fixture") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        XCTAssertTrue(app.buttons["Storage"].firstMatch.waitForExistence(timeout: 5)); app.buttons["Storage"].firstMatch.tap()
        let entry = storageCategoryEntry("temporaryFiles", in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let clear = app.buttons["storage.clear.released-temporary"]
        XCTAssertTrue(clear.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); clear.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Completed downloads are kept")).firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "stop-and-clear-temporary-warning"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["storage.confirm.delete"].tap()
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in clear.isEnabled || app.alerts.firstMatch.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed)
        if app.alerts.firstMatch.exists { app.alerts.buttons.firstMatch.tap() }
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "StorageReleasedCleanupFixture.bin")).firstMatch.exists)
    }

    func testLocalMediaOpensDirectFullscreenWithLegacySystemPreference() throws { try localMediaFullscreen(engine: "system") }
    func testLocalMediaOpensDirectFullscreenSoulo() throws { try localMediaFullscreen(engine: "soulo") }
    private func localMediaFullscreen(engine: String) throws {
        guard ProcessInfo.processInfo.environment["SOULO_STORAGE_CACHE_FIXTURE"] == "YES" else { throw XCTSkip("Requires isolated local media fixtures") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-home_toolbar_actions", "(files)", "-files.gridView", "NO", "-video.defaultPlayer", engine]
        XCUIDevice.shared.orientation = .portrait
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for name in ["qa-fullscreen-video.mp4", "qa-fullscreen-audio.wav"] {
            // Each fixture starts with fresh search state; iOS 16 exposes
            // inactive library pages' identically labelled clear buttons too.
            app.launch()
            XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 10)); app.buttons["home.toolbar.0"].tap()
            let search = app.collectionViews["files.list"].textFields["library.search"].firstMatch
            guard search.waitForExistence(timeout: 8) else { XCTFail(app.debugDescription); return }
            search.tap(); search.typeText(name)
            let item = app.descendants(matching: .any).matching(identifier: "files.item." + name).firstMatch
            guard item.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }; item.tap()
            let prefix = "media.mkv"
            let close = app.buttons["media.mkv.fullscreen.close"]
            guard close.waitForExistence(timeout: 20) else { XCTFail(app.debugDescription); return }
            XCTAssertFalse(app.otherElements["media.preview"].exists)
            let play = app.buttons[prefix + ".play"]
            // Pause before one-second accessibility waits allow auto-hide to
            // remove controls; this is a transport check, not a visibility test.
            func pauseAtVisiblePosition() {
                guard play.exists, play.label == "Pause" else { return }
                // Element.tap() waits for idleness and resolves the element
                // again, potentially after timed controls have disappeared.
                // Freeze the observed location before synthesizing the touch.
                let frame = play.frame
                guard !frame.isEmpty else { return }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
            pauseAtVisiblePosition()
            let timeline = app.sliders[prefix + ".timeline"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
                return timeline.exists && timeline.isEnabled
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed, app.debugDescription)
            if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
            pauseAtVisiblePosition()
            let portraitShot = XCTAttachment(screenshot: app.screenshot())
            portraitShot.name = "local-fullscreen-initial-" + engine + "-" + name
            portraitShot.lifetime = .keepAlways; add(portraitShot)
            let rotate = app.buttons["media.fullscreen.rotate"]
            if rotate.exists {
                let canvas = app.descendants(matching: .any).matching(identifier: "media.fullscreen.canvas").firstMatch
                XCTAssertTrue(canvas.waitForExistence(timeout: 5))
                let original = canvas.value as? String ?? "portrait"
                let expected = original == "landscape" ? "portrait" : "landscape"
                rotate.tap()
                let requestedAt = Date()
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    canvas.value as? String == expected && Date().timeIntervalSince(requestedAt) >= 2.3
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 6), .completed)
                if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
                XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertFalse(app.otherElements["media.preview"].exists)
            }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-fullscreen-" + engine + "-" + name; shot.lifetime = .keepAlways; add(shot)
            close.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 8), "Closing must return directly to the files list")
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            app.terminate(); XCUIDevice.shared.orientation = .portrait
        }
    }

    func testRuleManagementWithFilteringEnabled() { checkRules(enabled: true) }
    func testRuleManagementWithFilteringDisabled() { checkRules(enabled: false) }
    func testRuleManagementFromSettings() { checkRules(enabled: true, fromSettings: true) }
    func testPopulatedRulesFromSettings() { checkRules(enabled: true, fromSettings: true, populated: true) }

    func testCombinedProtectionRulePagesAndPrivacyFooter() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: true, fromSettings: true)
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Ad Blocking")
        app.buttons["settings.adBlock"].firstMatch.tap()
        let pages = app.segmentedControls["protection.section"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(pages.buttons.element(boundBy: 1).isSelected)
        app.swipeUp(); app.swipeUp()
        XCTAssertFalse(app.buttons["privacy.storage"].exists)
        pages.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(pages.buttons.element(boundBy: 0).isSelected)
        checkRuleRoutes(app, populated: false, passes: 1)
        XCTAssertTrue(pages.exists, "Returning from every rule page must restore the combined settings page")
    }

    func testRuleManagementDuringAutomaticSubscriptionRefresh() async throws {
        let server = try AdSettingsPageFixture(ruleCount: 20_000)
        let url = try await server.start()
        defer { server.stop() }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: true, fromSettings: true, populated: true)
        let disabledDefaults = ["easylist", "easyprivacy", "easylist-china", "adguard-base", "adguard-chinese", "adguard-mobile", "adguard-annoyances"]
        var subscriptions: [[String: Any]] = disabledDefaults.map { id in
            ["id": id, "name": id, "urlString": url.appendingPathComponent("unused").absoluteString,
             "isEnabled": false, "networkRuleCount": 0, "cosmeticRuleCount": 0, "errorMessage": ""]
        }
        subscriptions.append(["id": "automatic-refresh-fixture", "name": "Automatic refresh fixture",
            "urlString": url.appendingPathComponent("rules.txt").absoluteString, "isEnabled": true,
            "networkRuleCount": 0, "cosmeticRuleCount": 0, "errorMessage": ""])
        let data = try JSONSerialization.data(withJSONObject: subscriptions, options: [.sortedKeys])
        app.launchArguments += ["-soulo_ad_block_subscriptions", "<" + data.map { String(format: "%02x", $0) }.joined() + ">",
            "-soulo_ad_block_subscription_auto_update_check", "0"]
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { app.launchEnvironment[key] = "" }
        app.launchEnvironment["NO_PROXY"] = "127.0.0.1,localhost"
        app.launch(); defer { app.terminate() }
        // Wait for the actual idle-home automatic request, not a guessed
        // startup delay. Keep its response pending while navigation begins.
        for _ in 0..<450 {
            if server.hasRequestedRules { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let requested = server.hasRequestedRules
        XCTAssertTrue(requested, "The normal app activation must request the fixture: \(server.requestSummary)")
        guard requested else { return }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = revealSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Ad Blocking")
        app.buttons["settings.adBlock"].firstMatch.tap()
        checkRuleRoutes(app, populated: true, expectsAutomaticRefresh: true)
    }

    func testPopulatedRulesFromWebpageInformation() async throws {
        let server = try AdSettingsPageFixture()
        let url = try await server.start()
        defer { server.stop() }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: true, populated: true)
        app.launchArguments += ["-privacy_https_upgrade_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch(); defer { app.terminate() }
        // Use the real address field instead of XCUIApplication.open, which
        // is unavailable on the shipping iOS 16.0 boundary.
        let query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap()
        let focused = app.textFields["search.query"].firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        focused.typeText(url.absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Ad settings page fixture"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["browser.siteInformation"].tap()
        let entry = app.buttons["site.ad-block-details"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        checkRuleRoutes(app, populated: true)
    }

    private func configure(_ app: XCUIApplication, enabled: Bool, fromSettings: Bool = false, populated: Bool = false) {
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-ad_block_enabled", enabled ? "YES" : "NO",
            "-home_toolbar_actions", fromSettings ? "(settings)" : "(adBlock)"]
        if populated {
            let records: [[String: Any]] = (0..<500).map { index in
                ["id": UUID().uuidString, "host": String(format: "qa-%03d.example.test", index % 20),
                 "selector": ".fixture-ad-\(index)", "createdAt": Double(index)]
            }
            let data = try! JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            let hosts = (0..<200).map { String(format: "\"allow-%03d.example.test\"", $0) }.joined(separator: ",")
            app.launchArguments += ["-soulo_manual_ad_rules_v1", "<" + data.map { String(format: "%02x", $0) }.joined() + ">",
                "-ad_block_cross_domain_allowlist", "(" + hosts + ")", "-soulo_ad_block_allowlisted_hosts", "(" + hosts + ")"]
        }
    }

    private func checkRules(enabled: Bool, fromSettings: Bool = false, populated: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: enabled, fromSettings: fromSettings, populated: populated)
        app.launch(); defer { app.terminate() }
        let filtering = app.buttons["home.toolbar.0"]
        XCTAssertTrue(filtering.waitForExistence(timeout: 10)); filtering.tap()
        if fromSettings {
            let search = revealSearch(in: app)
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Ad Blocking")
            app.buttons["settings.adBlock"].firstMatch.tap()
        }
        checkRuleRoutes(app, populated: populated)
    }

    private func checkRuleRoutes(_ app: XCUIApplication, populated: Bool, expectsAutomaticRefresh: Bool = false, passes: Int = 3) {
        let routes = [("domainAllowlist", "Trusted domains"), ("manualRules", "Marked ads"),
            ("builtInRules", "Built-in rules"), ("subscriptions", "Filter lists"), ("allowedSites", "Allowed Sites")]
        for pass in 0..<passes {
            for (id, title) in routes {
                let entry = app.buttons["adBlock." + id]
                for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
                for _ in 0..<4 where !entry.isHittable { app.swipeDown() }
                XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
                if populated {
                    switch id {
                    case "manualRules":
                        XCTAssertTrue(app.descendants(matching: .any)["manualAds.host.qa-000.example.test"].firstMatch.waitForExistence(timeout: 5), "The 500-rule fixture must really be loaded")
                    case "domainAllowlist":
                        XCTAssertTrue(app.staticTexts["domainAllowlist.rule.allow-000.example.test"].waitForExistence(timeout: 5))
                    case "allowedSites": XCTAssertTrue(app.staticTexts["allow-000.example.test"].firstMatch.waitForExistence(timeout: 5))
                    default: break
                    }
                }
                if expectsAutomaticRefresh && id == "subscriptions" {
                    XCTAssertTrue(app.switches["adBlock.subscription.enabled.automatic-refresh-fixture"].exists)
                    let prefix = 20_000.formatted(.number.locale(Locale(identifier: "en_US"))) + " "
                    let refreshed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch.waitForExistence(timeout: 10)
                    XCTAssertTrue(refreshed,
                                  "The real automatic HTTP refresh must finish, not just render cached metadata")
                    guard refreshed else { return }
                }
                // Scope dismissal to the visible child bar. A global Done
                // query can select the still-mounted, underlying sheet's button.
                app.navigationBars[title].buttons.firstMatch.tap()
                let closed = NSPredicate(format: "exists == false")
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: app.navigationBars[title])], timeout: 5), .completed)
                XCTAssertTrue(entry.waitForExistence(timeout: 5), "Return from \(id), pass \(pass)")
            }
        }
    }
}

private final class AdSettingsPageFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Soulo.AdSettingsPageFixture")
    private let rules: String
    private let requestLock = NSLock()
    private var requestedRules = false
    private var requestLines: [String] = []
    var requestSummary: String {
        requestLock.lock(); defer { requestLock.unlock() }
        return requestLines.joined(separator: " | ")
    }
    private func recordRequest(_ data: Data?) {
        requestLock.lock(); defer { requestLock.unlock() }
        requestLines.append(data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? "no request bytes")
    }
    var hasRequestedRules: Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        return requestedRules
    }
    private func recordRulesRequest() {
        requestLock.lock(); defer { requestLock.unlock() }
        requestedRules = true
    }
    init(ruleCount: Int = 0) throws {
        listener = try NWListener(using: .tcp, on: .any)
        rules = (0..<ruleCount).map { "||ad-\($0).example.test^" }.joined(separator: "\n")
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self, queue, rules] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { request, _, _, _ in
                self?.recordRequest(request)
                let isRules = request.flatMap { String(data: $0, encoding: .utf8) }?.hasPrefix("GET /rules.txt ") == true
                if isRules { self?.recordRulesRequest() }
                let body = isRules ? rules : "<meta name='viewport' content='width=device-width,initial-scale=1'><p>Ad settings page fixture</p>"
                let type = isRules ? "text/plain" : "text/html"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                // Return new rule metadata while the user navigates the child
                // pages, reproducing the live-update/legacy-navigation overlap.
                queue.asyncAfter(deadline: .now() + (isRules ? 8 : 0)) {
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        return try await withCheckedThrowingContinuation { reply in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port else { return }
                    self?.listener.stateUpdateHandler = nil
                    reply.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
                case .failed(let error): self?.listener.stateUpdateHandler = nil; reply.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
