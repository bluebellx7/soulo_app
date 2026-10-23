import XCTest

/// Exercise actual external URL delivery and the user-initiated Settings handoff.
/// Choosing Soulo as the system default is a separate signed-device acceptance check.
final class DefaultBrowserUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    private var fixture: DownloadPlaybackHTTPFixture?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
            "-icloud_sync_enabled", "NO",
            "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn"]
    }

    override func tearDownWithError() throws {
        fixture?.stop()
        app.terminate()
    }

    @MainActor
    func testDirectWebLinksRenderRequestedAddressOnLaunch() async throws {
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <h1 id="part">External browser link</h1>
        <p id="address"></p><script>document.getElementById('address').textContent =
        location.pathname + location.search + location.hash;</script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/entry.html": Data(html.utf8)])
        fixture = server
        let root = try await server.start()
        // XCUIApplication.open launches the target with the URL each time.
        // Live delivery to an already-running default browser is covered by
        // the signed-device acceptance checklist, not by this launch API.
        for query in ["?q=a%2Bb&percent=100%25#part", "?q=second&value=a+b#part"] {
            let url = try XCTUnwrap(URL(string: root.absoluteString + "/entry.html" + query))
            app.open(url)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(app.webViews.staticTexts["External browser link"].firstMatch.waitForExistence(timeout: 40), app.debugDescription)
            XCTAssertTrue(app.webViews.staticTexts["/entry.html" + query].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        }
    }

    func testRealDocumentationRendersWithWorkingBrowserControls() throws {
        app.open(try XCTUnwrap(URL(string: "https://www.swift.org/documentation/")))
        let content = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Swift")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 45), app.debugDescription)
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "restored-browser-real-documentation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5), app.debugDescription)
        let tabs = app.buttons["browser.tabs"]
        XCTAssertTrue(tabs.isHittable, app.debugDescription)
    }

    func testBaiduSearchInputKeepsKeyboardWithShakeActionEnabled() throws {
        app.launchArguments += ["-browser_shake_action", "fullscreen", "-is_incognito", "YES"]
        var url = URLComponents(string: "https://www.baidu.com/s")!
        url.queryItems = [URLQueryItem(name: "wd", value: "鸡蛋")]
        app.open(try XCTUnwrap(url.url))
        let field = app.webViews.descendants(matching: .any).matching(NSPredicate(
            format: "elementType IN %@", [XCUIElement.ElementType.textField.rawValue,
                XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textView.rawValue]
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(field.isHittable, app.debugDescription)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText("test")
        XCTAssertTrue((field.value as? String)?.contains("test") == true, app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.exists, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "baidu-input-keyboard-with-shake"; shot.lifetime = .keepAlways; add(shot)
    }

    func testRecentGroupsUseRealWebpagesAndReopenAtTheTop() throws {
        app.launchArguments += ["-tab_overview_grouped", "YES", "-show_top_tab_bar", "NO"]
        app.open(try XCTUnwrap(URL(string: "https://www.swift.org/")))
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Swift")).firstMatch.waitForExistence(timeout: 45), app.debugDescription)
        app.buttons["browser.tabs"].tap()
        app.buttons["tabs.options"].tap()
        let closeOthers = app.buttons["Close Other Tabs"].firstMatch
        if closeOthers.exists { closeOthers.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap() }
        app.buttons["tabs.tab_new_tab"].tap()
        app.open(try XCTUnwrap(URL(string: "https://www.swift.org/documentation/")))
        XCTAssertTrue(app.webViews.staticTexts["Swift Documentation"].firstMatch.waitForExistence(timeout: 45), app.debugDescription)
        app.buttons["browser.tabs"].tap()
        let docs = app.descendants(matching: .any).matching(identifier: "tabs.group.host:docs.swift.org").firstMatch
        let site = app.descendants(matching: .any).matching(identifier: "tabs.group.host:swift.org").firstMatch
        XCTAssertTrue(docs.waitForExistence(timeout: 10) && site.exists, app.debugDescription)
        XCTAssertLessThan(docs.frame.minY, site.frame.minY)
        XCTAssertLessThan(docs.frame.minY, app.frame.height * 0.25)
        let oldSite = app.scrollViews["tabs.group-row.host:swift.org"].buttons.firstMatch
        XCTAssertTrue(oldSite.isHittable, app.debugDescription)
        oldSite.tap()
        XCTAssertTrue(app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Swift")).firstMatch.waitForExistence(timeout: 30))
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(site.waitForExistence(timeout: 10))
        XCTAssertLessThan(site.frame.minY, docs.frame.minY, "Returning to an older real page makes its group most recent")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "recent-groups-real-swift-webpages"; shot.lifetime = .keepAlways; add(shot)
    }

    func testDefaultBrowserEntryOpensSystemSettings() throws {
        app.launch()
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let settingsButton = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), app.debugDescription)
        settingsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), app.debugDescription)

        let entry = app.buttons["settings.defaultBrowser"]
        for _ in 0..<6 {
            if entry.exists && entry.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(entry.exists && entry.isHittable, app.debugDescription)
        XCTAssertEqual(entry.label, "Default Browser")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "default-browser-settings-entry"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        entry.tap()

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.navigationBars.firstMatch.waitForExistence(timeout: 30), settings.debugDescription)
        app.activate()
    }

    @MainActor
    func testSharingAWebPageFromSafariOpensSouloWithoutAnotherChoice() async throws {
        try await verifySafariShare(terminateSoulo: false)
    }

    @MainActor
    func testSharingAWebPageFromSafariLaunchesTerminatedSoulo() async throws {
        try await verifySafariShare(terminateSoulo: true)
    }

    @MainActor
    private func verifySafariShare(terminateSoulo: Bool) async throws {
        // Keep asynchronous assertion failures from throwing across XCTest's
        // actor boundary. Guards below stop the flow after any missing element.
        continueAfterFailure = true
        let html = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Soulo Share Fixture</title><h1 id="part">Shared page reached Soulo</h1>
        <p id="address"></p><script>document.getElementById('address').textContent =
        location.pathname + location.search + location.hash;</script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/shared.html": Data(html.utf8)])
        fixture = server
        let root = try await server.start()
        let query = "?q=a%2Bb&percent=100%25#part"
        let url = try XCTUnwrap(URL(string: root.absoluteString + "/shared.html" + query))
        app.launch()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        defer { safari.terminate() }
        safari.open(url)
        XCTAssertTrue(safari.webViews.staticTexts["Shared page reached Soulo"].firstMatch.waitForExistence(timeout: 30), safari.debugDescription)
        let tipClose = safari.buttons["xmark.circle.fill"]
        if tipClose.exists { tipClose.tap() }
        let share = safari.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
            ["Share", "共享", "分享"], ["Share", "ToolbarShareButton"])).firstMatch
        if !share.exists {
            // iOS 26's compact toolbar keeps Share in the More menu.
            let more = safari.buttons.matching(NSPredicate(format: "label IN %@", ["More", "更多"])).firstMatch
            guard more.waitForExistence(timeout: 10) else { XCTFail(safari.debugDescription); return }
            more.tap()
        }
        guard share.waitForExistence(timeout: 10) else { XCTFail(safari.debugDescription); return }
        share.tap()
        let soulo = safari.cells["Soulo"].firstMatch
        guard soulo.waitForExistence(timeout: 10) else { XCTFail(safari.debugDescription); return }
        if terminateSoulo { app.terminate() }
        soulo.tap()
        guard app.wait(for: .runningForeground, timeout: 15) else { XCTFail(safari.debugDescription); return }
        XCTAssertTrue(app.webViews.staticTexts["Shared page reached Soulo"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["/shared.html" + query].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Private Search"].exists, app.debugDescription)
    }

    func testSettingsBackupCanBeSavedAndRestoredWithConfirmation() throws {
        app.launch()
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let settingsButton = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), app.debugDescription)
        settingsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), app.debugDescription)
        let entry = app.buttons["settings.backups"]
        for _ in 0..<9 {
            if entry.exists && entry.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(entry.exists && entry.isHittable, app.debugDescription)
        entry.tap()
        let save = app.buttons["settings.backups.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        save.tap()
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.backups.restore.")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10), app.debugDescription)
        restore.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(confirmation.staticTexts["Restoring will turn off iCloud Sync and back up your current settings first."].exists, app.debugDescription)
        confirmation.buttons["Restore"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(save.exists && restore.exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
    }
}
