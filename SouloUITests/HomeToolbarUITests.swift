import XCTest

@MainActor
final class HomeToolbarUITests: XCTestCase {
    func testWallpaperSettingsSwitchSourcesAndApplyGradient() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient",
            "-wallpaper_gradient_id", "aurora", "-wallpaper_refresh_interval", "0",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES"]
        app.launch(); defer { app.terminate() }
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let sources = app.scrollViews["wallpaper.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.swipeLeft()
        let solid = app.buttons["wallpaper.source.solid"]
        XCTAssertTrue(solid.isHittable); solid.tap()
        XCTAssertTrue(solid.isSelected)
        let gradient = app.buttons["wallpaper.source.gradient"]
        gradient.tap(); XCTAssertTrue(gradient.isSelected)
        let forest = app.buttons["wallpaper.gradient.forest"]
        if !forest.isHittable { app.swipeUp() }
        XCTAssertTrue(forest.waitForExistence(timeout: 5)); forest.tap()
        XCTAssertTrue(forest.isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "wallpaper-local-source-and-forest-applied"; shot.lifetime = .keepAlways; add(shot)
    }

    func testStartupAndForegroundKeepHomeMenuAndSearchResponsive() async throws {
        continueAfterFailure = false
        let title = "Startup interaction \(UUID().uuidString.prefix(6))"
        let server = try DownloadPlaybackHTTPFixture(files: ["/startup": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>\(title)</title><h1>\(title)</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        for wallpaper in ["gradient", "bing"] {
            app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO",
                "-wallpaper_source", wallpaper, "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO",
                "-review.requestedOnce", "YES",
                "-soulo_ad_block_subscription_auto_update_check", "0", "-privacy_https_upgrade_enabled", "NO",
                "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
            app.launch()
            let menu = app.buttons["home.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settings = app.buttons["Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 3), "The first home menu tap must work")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
            let field = app.textFields["search.query"].firstMatch
            field.tap()
            if app.buttons["search.clear"].exists { app.buttons["search.clear"].tap(); field.tap() }
            let url = root.appendingPathComponent("startup").absoluteString
            field.typeText(url)
            XCTAssertEqual(field.value as? String, url, "Startup work must not lose the first typed query")
            field.typeText("\n")
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 15))
            app.buttons["Home Screen"].firstMatch.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            // runningForeground precedes the SpringBoard activation animation.
            // Its transient AX frames can still be scaled to the app preview.
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                menu.isHittable && menu.frame.width >= 40
            }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: 3) == .completed else {
                XCTFail("Home controls must become ready after the system activation transition")
                return
            }
            XCTAssertLessThan(menu.frame.maxY, app.frame.height * 0.25)
            // Native tap() can attempt to scroll this fixed button after a
            // scene transition and choose a point below its visible frame.
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 3), "Returning from the background must preserve home hit testing")
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settingsBar = app.navigationBars["Settings"]
            XCTAssertTrue(settingsBar.waitForExistence(timeout: 5), "The menu action must actually open Settings")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "startup-responsive-\(wallpaper)"; shot.lifetime = .keepAlways; add(shot)
            settingsBar.buttons["Done"].tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            field.tap()
            if app.buttons["search.clear"].exists { app.buttons["search.clear"].tap(); field.tap() }
            field.typeText("Foreground query")
            XCTAssertEqual(field.value as? String, "Foreground query", "Search must accept input after returning to the foreground")
            app.terminate()
        }
    }

    func testHomeTitleRecentSearchAndBookmarkKeepTapAndLongPressActions() async throws {
        continueAfterFailure = false
        let title = "Home press \(UUID().uuidString.prefix(6))"
        let server = try DownloadPlaybackHTTPFixture(files: ["/press": Data("<title>\(title)</title><h1>\(title)</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let url = root.appendingPathComponent("press")
        let query = "Press recent \(UUID().uuidString.prefix(6))"
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-home_title", "Soulo", "-is_incognito", "NO",
            "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-show_bookmarks_on_home", "YES", "-show_group_picker_on_home", "YES", "-show_recent_searches_on_home", "YES",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
            "-browser_toolbar_actions", "(home,bookmark,tabs,more)"]
        app.launch(); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 15))
        app.buttons["Bookmarks"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bookmark.fill"].waitForExistence(timeout: 5))
        app.buttons["Home Screen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        app.buttons["Home title, Soulo"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()

        let field = app.textFields["search.query"].firstMatch
        field.tap(); field.typeText(query + "\n")
        XCTAssertTrue(app.buttons["Edit Address or Search"].firstMatch.waitForExistence(timeout: 10))
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        let recent = app.buttons["Recent search, \(query)"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(app.buttons["Edit Address or Search"].firstMatch.waitForExistence(timeout: 10), "A short tap must still search")
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.press(forDuration: 1)
        XCTAssertTrue(app.buttons["home.menu"].isHittable, "Long press must reveal deletion without starting a search")
        recent.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -22, dy: 0)).tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5), "The inline delete control must remain tappable")

        let bookmark = app.buttons[title]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        bookmark.press(forDuration: 1)
        let remove = app.buttons["Delete"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "Bookmark context menus must still open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.18)).tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
        bookmark.tap()
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 15), "A regular bookmark tap must still open the page")
        app.buttons["Bookmarks"].firstMatch.tap()
    }

    func testIllustratedReviewPageReturnsToSettingsAndVersionInBothAppearances() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        for (appearance, language, settings) in [("light", "zh-Hans", "设置"), ("dark", "en-US", "Settings")] {
            app.launchArguments = ["-app_language", language, "-appearance", appearance,
                "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO"]
            app.launch(); app.open(URL(string: "soulo://")!)
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
            app.buttons["home.menu"].tap()
            app.buttons[settings].firstMatch.tap()
            let rate = app.buttons["settings.rate"]
            reveal(rate, in: app); rate.tap()
            let store = app.descendants(matching: .any)["review.write"].firstMatch
            XCTAssertTrue(store.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(store.isHittable, "The explicit App Store link must be reachable")
            XCTAssertEqual(store.label, language == "zh-Hans" ? "去 App Store 好评" : "Review on the App Store")
            let review = XCTAttachment(screenshot: app.screenshot())
            review.name = "illustrated-review-\(appearance)"; review.lifetime = .keepAlways; add(review)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["settings.rate"].waitForExistence(timeout: 5), "Back must return to Settings")
            let version = app.buttons["settings.version"]
            reveal(version, in: app); version.tap()
            XCTAssertTrue(app.descendants(matching: .any)["version.website"].firstMatch.waitForExistence(timeout: 5))
            let about = XCTAttachment(screenshot: app.screenshot())
            about.name = "illustrated-version-\(appearance)"; about.lifetime = .keepAlways; add(about)
            app.terminate()
        }
    }

    func testUndoIsFirstAndRestoresWithoutLeavingEitherOverviewLayout() async throws {
        continueAfterFailure = false
        let prefix = "Undo \(UUID().uuidString)"
        let pages = ["grouped", "carousel"]
        let server = try DownloadPlaybackHTTPFixture(files: Dictionary(uniqueKeysWithValues: pages.map { page in
            ("/undo-\(page)", Data("<title>\(prefix) \(page)</title><h1>\(prefix) \(page)</h1>".utf8))
        }))
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        for grouped in [true, false] {
            let page = grouped ? "grouped" : "carousel"
            let title = "\(prefix) \(page)"
            app.launchArguments = ["-app_language", "en-US", "-browser_toolbar_hidden", "NO",
                "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO",
                "-icloud_sync_enabled", "NO", "-wallpaper_source", "gradient",
                "-tab_overview_grouped", grouped ? "YES" : "NO"]
            app.open(root.appendingPathComponent("undo-\(page)"))
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
            app.buttons["browser.tabs"].tap()
            XCTAssertTrue(app.buttons["tabs.done"].waitForExistence(timeout: 5))
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "tabs.card.", title)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
            // The top tab strip and recent history also expose "Close Tab" /
            // the page title. Tap the actual card's close control, in both layouts.
            card.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
                .withOffset(CGVector(dx: -22, dy: 22)).tap()
            XCTAssertTrue(card.waitForNonExistence(timeout: 5))
            let undo = app.buttons["tabs.tab_restore_last"]
            let mode = app.buttons["tabs.view-mode"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            XCTAssertLessThan(undo.frame.midX, mode.frame.midX)
            XCTAssertEqual(undo.frame.midY, mode.frame.midY, accuracy: 1)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = grouped ? "grouped-undo-first-orange" : "carousel-undo-first-orange"
            shot.lifetime = .keepAlways; add(shot)
            undo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["tabs.done"].isHittable, "Undo must leave tab management open")
            XCTAssertTrue(card.waitForExistence(timeout: 5), "Restored tab must reappear in the overview")
            app.buttons["tabs.done"].tap()
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 20))
            app.terminate()
        }
    }

    func testHiddenToolbarLockOpensTheSharedSitePanel() async throws {
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: ["/page": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Site panel fixture</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-browser_toolbar_hidden", "YES", "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Site panel fixture"].waitForExistence(timeout: 10))
        app.buttons["More"].firstMatch.tap()
        let lock = app.buttons["browser.hiddenSiteInformation"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), app.debugDescription)
        lock.tap()
        XCTAssertTrue(app.buttons["site.connection"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["site.user-agent"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Shared site information from the hidden toolbar lock"; shot.lifetime = .keepAlways; add(shot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["site.user-agent"].waitForNonExistence(timeout: 3))
    }

    func testVideoSettingsAndTelegramFeedbackEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", "light", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-video.holdSpeed", "2"]
        app.launch(); app.open(URL(string: "soulo://")!)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        app.buttons["home.menu"].tap(); app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(app.switches["settings.keepScreenAwake"].waitForExistence(timeout: 5))
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        capture("Settings appearance and home icon columns")
        let video = app.buttons["settings.video"]
        reveal(video, in: app); video.tap()
        let holdSpeed = app.descendants(matching: .any)["video-settings.hold-speed"].firstMatch
        XCTAssertTrue(app.switches["video-settings.episode-dock"].waitForExistence(timeout: 5))
        XCTAssertTrue(holdSpeed.waitForExistence(timeout: 5))
        XCTAssertTrue(holdSpeed.label.contains("2") || (holdSpeed.value as? String)?.contains("2") == true, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Soulo"].firstMatch.exists)
        capture("Video settings hold speed and decoder explanations")
        app.navigationBars.buttons.firstMatch.tap()
        let backups = app.buttons["settings.backups"]
        reveal(backups, in: app); backups.tap()
        let save = app.buttons["settings.backups.save"]
        XCTAssertTrue(app.staticTexts["将当前设置备份到此设备，方便以后恢复。备份不包含浏览记录、登录状态和下载文件。"].exists)
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        let copy = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.backups.restore.")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let identifier = copy.identifier
        copy.swipeLeft()
        app.buttons["删除"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.buttons[identifier].waitForNonExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        let feedback = app.buttons["settings.feedback"]
        reveal(feedback, in: app)
        capture("Settings other and support icon columns")
        feedback.tap()
        let telegram = app.descendants(matching: .any)["feedback.telegram"].firstMatch
        XCTAssertTrue(telegram.waitForExistence(timeout: 5))
        XCTAssertTrue(telegram.isHittable)
        XCTAssertTrue(app.staticTexts["加入群组，交流问题与建议。"].exists)
        capture("Feedback Telegram group entry")
        app.navigationBars["用户反馈"].buttons["取消"].tap()
        let version = app.buttons["settings.version"]
        reveal(version, in: app); version.tap()
        let versionTelegram = app.descendants(matching: .any)["version.telegram"].firstMatch
        XCTAssertTrue(versionTelegram.waitForExistence(timeout: 5))
        XCTAssertTrue(versionTelegram.isHittable)
        capture("Version Telegram group entry and aligned icons")
    }

    func testOverviewPlusReturnsHomeAndKeepsTheExistingTabCount() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/page": Data("<h1>Keep this tab</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let tabs = app.buttons["browser.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), app.debugDescription)
        let countLabel = tabs.label
        tabs.tap()
        let home = app.buttons["tabs.browser_home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = NSPredicate { _, _ in !app.otherElements["tabs.dock"].exists }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 5)
        XCTAssertTrue(app.buttons["home.menu"].isHittable, app.debugDescription)
        let homeTabs = app.descendants(matching: .any)["home.tabs"].firstMatch
        XCTAssertEqual(homeTabs.value as? String, countLabel.split(separator: " ").first.map(String.init), app.debugDescription)
    }

    func testBookmarkFromHomeOpensNewTabWithoutReplacingTheOriginalPage() async throws {
        try await checkLibrarySelectionUsesSeparateTab(section: "bookmarks", returnHome: true)
    }

    func testHistoryFromBrowserOpensNewTabWithoutReplacingTheOriginalPage() async throws {
        try await checkLibrarySelectionUsesSeparateTab(section: "history", returnHome: false)
    }

    func testBookmarkFromHomeReusesTheExplicitBlankTab() async throws {
        try await checkLibrarySelectionUsesSeparateTab(section: "bookmarks", returnHome: true, createBlank: true)
    }

    private func checkLibrarySelectionUsesSeparateTab(section: String, returnHome: Bool, createBlank: Bool = false) async throws {
        continueAfterFailure = false
        let token = UUID().uuidString.prefix(8)
        let savedTitle = "Saved \(token)"
        let originalTitle = "Original \(token)"
        let state = "Keep state \(token)"
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/saved.html": Data("<title>\(savedTitle)</title><h1>\(savedTitle)</h1>".utf8),
            "/original.html": Data("""
                <title>\(originalTitle)</title><h1>\(originalTitle)</h1>
                <input aria-label="Original note" onkeydown="if(event.key==='Enter'){this.blur();return false}">
                """.utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO",
            "-soulo_primary_browser_window_id", UUID().uuidString,
            "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-show_top_tab_bar", "YES",
            "-show_top_search_bar", "NO", "-browser_toolbar_actions", "(home,bookmark,library,tabs)"]
        if createBlank { app.launchArguments += ["-home_toolbar_actions", "(newTab)"] }
        app.launch(); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("saved.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts[savedTitle].waitForExistence(timeout: 15), app.debugDescription)
        let tabs = app.buttons["browser.tabs"]
        if section == "bookmarks" {
            app.buttons["Bookmarks"].firstMatch.tap()
            XCTAssertTrue(app.buttons["bookmark.fill"].waitForExistence(timeout: 5))
        }
        app.buttons["Edit Address or Search"].firstMatch.tap()
        let address = app.textFields["addressEditor.query"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        app.buttons["addressEditor.clearQuery"].tap()
        address.tap(); address.typeText(root.appendingPathComponent("original.html").absoluteString + "\n")
        let note = app.webViews.textFields["Original note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription)
        // Finish typing before sending the page's blur-on-Enter action, then
        // verify that the keyboard no longer covers the bottom toolbar.
        note.tap(); note.typeText(state)
        let returnKey = app.keyboards.buttons["Return"]
        guard returnKey.waitForExistence(timeout: 3) else {
            XCTFail("The page input must have its return key available")
            return
        }
        returnKey.tap()
        guard app.keyboards.firstMatch.waitForNonExistence(timeout: 5) else {
            XCTFail("Finish page input before tapping browser toolbar controls")
            return
        }
        // Restored simulator sessions can contain earlier tabs. Measure from the
        // occupied original document rather than assuming a single-tab session.
        let initialCount = try XCTUnwrap(Int(tabs.label.split(separator: " ").first.map(String.init) ?? ""))
        let expectedCount = initialCount + 1
        if createBlank {
            app.buttons["Home Screen"].firstMatch.tap()
            let newTab = app.buttons["home.toolbar.0"]
            guard newTab.waitForExistence(timeout: 5) else {
                XCTFail("The configured home New Tab control must be visible: \(app.debugDescription)")
                return
            }
            newTab.tap()
            XCTAssertTrue(tabs.waitForExistence(timeout: 5))
            XCTAssertEqual(tabs.label, "\(expectedCount) Tabs")
        }
        if returnHome {
            tabs.tap()
            app.buttons["tabs.browser_home"].tap()
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
            app.buttons["home.menu"].tap()
            let favorites = app.buttons["My Favorites"].firstMatch
            XCTAssertTrue(favorites.waitForExistence(timeout: 5), app.debugDescription)
            favorites.tap()
        } else {
            app.buttons["Library"].firstMatch.tap()
            let history = app.buttons["library.section.history"]
            guard history.waitForExistence(timeout: 5) else {
                XCTFail("Opening Library must reveal its History section: \(app.debugDescription)")
                return
            }
            history.tap()
        }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", savedTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.webViews.staticTexts[savedTitle].waitForExistence(timeout: 15), app.debugDescription)
        // Clean only the bookmark created by this fixture, including on the pre-fix failure.
        if section == "bookmarks", app.buttons["bookmark.fill"].exists { app.buttons["Bookmarks"].firstMatch.tap() }
        XCTAssertEqual(tabs.label, "\(expectedCount) Tabs", "A library selection must preserve the occupied tab and reuse an explicit blank tab")
        guard tabs.label == "\(expectedCount) Tabs" else { return }
        let original = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", originalTitle + ", tab ")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), app.debugDescription)
        original.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.value as? String, state, "The original document must retain its live form state")
        app.buttons["Edit Address or Search"].firstMatch.tap()
        let pageURL = app.textFields["addressEditor.pageURL"]
        XCTAssertTrue(pageURL.waitForExistence(timeout: 5))
        XCTAssertEqual(pageURL.value as? String, root.appendingPathComponent("original.html").absoluteString)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library preserves original \(section) blank-\(createBlank)"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

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
        let background = app.switches["home-toolbar.background"].firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 5), app.debugDescription)
        if background.value as? String != "1" {
            background.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(background.value as? String, "1")
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
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "five-home-framed-shortcuts"; shot.lifetime = .keepAlways; add(shot)
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
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "home-shortcuts-after-presentations"; returned.lifetime = .keepAlways; add(returned)
        openSettings(app)
        let restoredBackground = app.switches["home-toolbar.background"].firstMatch
        XCTAssertEqual(restoredBackground.value as? String, "1")
        restoredBackground.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(restoredBackground.value as? String, "0")
        let setting = XCTAttachment(screenshot: app.screenshot())
        setting.name = "home-toolbar-background-setting"; setting.lifetime = .keepAlways; add(setting)
        app.buttons["home-toolbar.save"].tap()
        app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        let plain = XCTAttachment(screenshot: app.screenshot())
        plain.name = "five-home-plain-shortcuts"; plain.lifetime = .keepAlways; add(plain)
        openSettings(app)
        XCTAssertEqual(app.switches["home-toolbar.background"].firstMatch.value as? String, "0")
        app.buttons["Hide All"].firstMatch.tap()
        app.sheets.buttons["Hide All"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
        XCTAssertFalse(app.buttons["home.toolbar.4"].exists)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, downward: Bool = false) {
        let save = app.buttons["home-toolbar.save"]
        for _ in 0..<8 {
            let bottom = save.exists ? save.frame.minY - 12 : app.frame.maxY - 40
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : app.frame.minY
            if element.exists && element.isHittable && (!save.exists || (element.frame.minY >= top && element.frame.maxY <= bottom)) { return }
            if downward { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func assertFourColumns(_ app: XCUIApplication, prefix: String, firstRow: [String], next: String) {
        let cells = firstRow.map { app.buttons[prefix + $0] }
        XCTAssertTrue(cells[0].waitForExistence(timeout: 5), app.debugDescription)
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(cell.exists)
            XCTAssertEqual(cell.frame.midY, cells[0].frame.midY, accuracy: 2)
            XCTAssertGreaterThanOrEqual(cell.frame.minX, 0)
            XCTAssertLessThanOrEqual(cell.frame.maxX, app.frame.width)
            if index > 0 { XCTAssertGreaterThan(cell.frame.minX, cells[index-1].frame.minX) }
        }
        XCTAssertGreaterThan(app.buttons[prefix + next].frame.minY, cells[0].frame.maxY)
    }

    func testSettingsLayoutWebsiteEntryAndRemovedCosmeticStatistics() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.switches["settings.keepScreenAwake"].waitForExistence(timeout: 5))
        let appearance = XCTAttachment(screenshot: app.screenshot())
        appearance.name = "settings-aligned-appearance-rows"; appearance.lifetime = .keepAlways; add(appearance)
        let toolbar = app.buttons["settings.homeToolbar"]
        reveal(toolbar, in: app); toolbar.tap()
        let normalHeight = app.buttons["home-toolbar.action.downloads"].frame.height
        let longTitle = app.buttons["home-toolbar.action.urlSchemes"]
        reveal(longTitle, in: app)
        XCTAssertEqual(longTitle.frame.height, normalHeight, accuracy: 1)
        XCTAssertEqual(longTitle.frame.height, app.buttons["home-toolbar.action.quickActions"].frame.height, accuracy: 1)
        let cards = XCTAttachment(screenshot: app.screenshot())
        cards.name = "toolbar-long-titles-uniform-height"; cards.lifetime = .keepAlways; add(cards)
        app.navigationBars.buttons.firstMatch.tap()
        let version = app.buttons["settings.version"]
        reveal(version, in: app); version.tap()
        let website = app.buttons["version.website"]
        XCTAssertTrue(website.waitForExistence(timeout: 5), app.debugDescription)
        let about = XCTAttachment(screenshot: app.screenshot())
        about.name = "version-soulo-website-entry"; about.lifetime = .keepAlways; add(about)
        website.tap()
        let storeLink = app.webViews.links.matching(NSPredicate(format: "label CONTAINS[c] %@", "App Store")).firstMatch
        XCTAssertTrue(storeLink.waitForExistence(timeout: 25), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        let adFiltering = app.buttons["Ad Blocking"].firstMatch
        reveal(adFiltering, in: app, downward: true); adFiltering.tap()
        XCTAssertTrue(app.switches["adBlock.enabled"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "adBlock.statistics").firstMatch.exists)
        let filtering = XCTAttachment(screenshot: app.screenshot())
        filtering.name = "ad-filtering-without-cosmetic-counts"; filtering.lifetime = .keepAlways; add(filtering)
    }

    func testDirectWallpaperChangeAndMatchingFourColumnPickers() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient",
            "-wallpaper_gradient_id", "dawn", "-wallpaper_refresh_interval", "0", "-wallpaper_favorites", "", "-wallpaper_only_favorites", "NO"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        openSettings(app)
        assertFourColumns(app, prefix: "home-toolbar.action.", firstRow: ["none", "downloads", "files", "bookmarks"], next: "history")
        let background = app.switches["home-toolbar.background"].firstMatch
        let originalBackground = background.value as? String
        if originalBackground != "1" { background.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        let homePicker = XCTAttachment(screenshot: app.screenshot())
        homePicker.name = "home-toolbar-four-columns"; homePicker.lifetime = .keepAlways; add(homePicker)
        for (index, action) in ["refreshWallpaper", "wallpaper", "help", "homeToolbar", "browserToolbar"].enumerated() {
            let slot = app.buttons["home-toolbar.slot.\(index)"]
            reveal(slot, in: app, downward: true); slot.tap()
            XCTAssertTrue(slot.isSelected)
            let choice = app.buttons["home-toolbar.action." + action]
            reveal(choice, in: app); choice.tap()
            XCTAssertTrue(choice.isSelected, "The selected action must be assigned before saving")
        }
        app.buttons["home-toolbar.save"].tap(); app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["Done"].firstMatch.tap()
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.toolbar.1"].waitForExistence(timeout: 10))
        app.buttons["home.toolbar.1"].tap()
        let randomSources = app.switches["wallpaper.randomSources"].firstMatch
        reveal(randomSources, in: app)
        let originalRandom = randomSources.value as? String
        if originalRandom == "1" { randomSources.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.0"].tap()
        XCTAssertTrue(app.buttons["home.menu"].exists, "Changing wallpaper stays on the home page")
        let changed = XCTAttachment(screenshot: app.screenshot())
        changed.name = "home-wallpaper-changed-borderless-buttons"; changed.lifetime = .keepAlways; add(changed)
        app.buttons["home.toolbar.1"].tap()
        let nextGradient = app.buttons["wallpaper.gradient.deep_sea"]
        reveal(nextGradient, in: app)
        XCTAssertTrue(nextGradient.isSelected, app.debugDescription)
        if originalRandom == "1" {
            reveal(randomSources, in: app, downward: true)
            randomSources.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.2"].tap()
        XCTAssertTrue(app.navigationBars["Help Center"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.4"].tap()
        assertFourColumns(app, prefix: "browser-toolbar.action.", firstRow: ["none", "home", "back", "forward"], next: "tabs")
        app.buttons["browser-toolbar.action.none"].tap()
        XCTAssertTrue(app.buttons["browser-toolbar.action.none"].isSelected)
        let browserPicker = XCTAttachment(screenshot: app.screenshot())
        browserPicker.name = "browser-toolbar-four-columns"; browserPicker.lifetime = .keepAlways; add(browserPicker)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.3"].tap()
        app.buttons["home-toolbar.slot.0"].tap()
        XCTAssertTrue(app.buttons["home-toolbar.action.refreshWallpaper"].isSelected)
        let restoredBackground = app.switches["home-toolbar.background"].firstMatch
        if restoredBackground.value as? String != originalBackground {
            restoredBackground.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        app.buttons["Hide All"].firstMatch.tap(); app.sheets.buttons["Hide All"].tap()
        app.buttons["home-toolbar.save"].tap(); app.alerts.buttons["Done"].tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
    }

}
