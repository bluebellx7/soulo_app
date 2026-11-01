import XCTest
import Network
import UIKit

/// Actual screen taps catch chrome occlusion that model-only navigation tests miss.
final class BrowserToolbarResponsivenessUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    private var fixture: ToolbarHTTPFixture!
    private var root: URL!

    func testClipboardHintDoesNotRequestPermissionOnActivation() throws {
        let home = app.buttons["Home Screen"].firstMatch
        if home.exists { home.tap() }
        XCUIDevice.shared.press(.home)
        UIPasteboard.general.string = "https://example.com/clipboard-performance-qa"
        app.activate()
        let preview = app.staticTexts["clipboard.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(preview.label.contains("clipboard-performance-qa"), "Automatic detection must not read the copied text")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "粘贴", "paste")).firstMatch.exists)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        fixture = try ToolbarHTTPFixture()
        root = try fixture.start()
        app.launchArguments = ["-app_language", "en-US", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-is_incognito", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
    }

    override func tearDownWithError() throws { fixture?.stop() }

    private func open(_ path: String) throws {
        try open(url: root.appendingPathComponent(path))
    }

    private func open(url: URL) throws {
        var route = URLComponents()
        route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        app.open(try XCTUnwrap(route.url))
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element.isHittable, app.debugDescription)
        // Coordinate taps exercise hit testing instead of accessibility activation.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func checkMoreAndTabs() {
        let more = app.buttons["More"].firstMatch
        let panel = app.popovers.firstMatch
        for _ in 0..<3 {
            tap(more)
            XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5), app.debugDescription)
        }
        tap(app.buttons["browser.tabs"])
        let newTab = app.buttons["tabs.tab_new_tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5), app.debugDescription)
        tap(newTab)
        XCTAssertTrue(app.buttons["browser.tabs"].waitForExistence(timeout: 5))
    }

    func testPageLinksAndBottomToolbarRespondDuringSlowLoading() throws {
        // Enter through the real search field; reopening an already running
        // app through XCUIApplication.open can stall the simulator launcher.
        let home = app.buttons["Home Screen"].firstMatch
        if home.exists { tap(home) }
        let field = app.textFields["search.query"].firstMatch
        tap(field)
        let clear = app.buttons["search.clear"].firstMatch
        if clear.exists { tap(clear); tap(field) }
        field.typeText(root.appendingPathComponent("slow").absoluteString)
        let submit = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Search", "search", "搜索"])).firstMatch
        tap(submit)
        let link = app.webViews.links["Next page"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(fixture.hasPendingSlowResource)
        let loading = app.descendants(matching: .any).matching(identifier: "browser.initial-loading").firstMatch
        XCTAssertTrue(loading.waitForNonExistence(timeout: 5), "First content must appear before hanging subresources finish")
        let ready = XCTAttachment(screenshot: app.screenshot())
        ready.name = "visible-page-before-slow-resources-finish"; ready.lifetime = .keepAlways; add(ready)
        checkMoreAndTabs()
        XCTAssertTrue(fixture.hasPendingSlowResource)
        // Return through the real overview to exercise retained WebView remounting.
        tap(app.buttons["browser.tabs"])
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "tabs.card.", fixture.pageTitle + ",")).firstMatch
        tap(card)
        tap(link)
        XCTAssertTrue(app.webViews.staticTexts["Second page"].firstMatch.waitForExistence(timeout: 10))
        tap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        tap(app.buttons["Home Screen"].firstMatch)
        XCTAssertTrue(app.buttons["Home Screen"].firstMatch.waitForNonExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "toolbar-responsive-returned-home"; shot.lifetime = .keepAlways; add(shot)
    }

    func testPendingNavigationKeepsThePreviousPageScrollableAndInteractive() throws {
        try open("interactive-source")
        let web = app.webViews.firstMatch
        tap(web.links["Open slow result"].firstMatch)
        XCTAssertTrue(fixture.hasPendingSlowResource)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "browser.navigation-preview").firstMatch.exists)
        let button = web.buttons["Check response"].firstMatch
        let before = button.frame.minY
        web.swipeUp(velocity: .slow)
        XCTAssertLessThan(button.frame.minY, before - 100, "The previous document must still scroll while a response is pending")
        for _ in 0..<3 where !button.isHittable { web.swipeUp(velocity: .slow) }
        tap(button)
        XCTAssertTrue(web.staticTexts["Still responsive"].firstMatch.waitForExistence(timeout: 3))
        tap(web.links["Open another result"].firstMatch)
        XCTAssertTrue(web.staticTexts["Second page"].firstMatch.waitForExistence(timeout: 10))
    }

    func testOneBackLeavesPlayerAfterTwoTrustedFrameNavigations() throws {
        try open("history-list")
        tap(app.webViews.links["Watch video"].firstMatch)
        tap(app.webViews.links["Load player"].firstMatch)
        tap(app.webViews.links["Start video"].firstMatch)
        XCTAssertTrue(app.webViews.staticTexts["Player ready"].firstMatch.waitForExistence(timeout: 10))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "player-with-nested-history"; before.lifetime = .keepAlways; add(before)
        tap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(app.webViews.links["Watch video"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "one-back-returned-to-list"; after.lifetime = .keepAlways; add(after)
        tap(app.buttons["More"].firstMatch)
        tap(app.buttons["Forward"].firstMatch)
        XCTAssertTrue(app.webViews.staticTexts["Video player"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBackDismissesFailureWhenRestoringSameDocumentHistory() throws {
        try open("history-error-state")
        XCTAssertTrue(app.webViews.staticTexts["History page"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        tap(app.webViews.buttons["Open panel"].firstMatch)
        XCTAssertTrue(app.webViews.staticTexts["Panel opened"].firstMatch.waitForExistence(timeout: 5))
        tap(app.webViews.links["Unavailable page"].firstMatch)
        let error = app.staticTexts["browser.error.message"]
        XCTAssertTrue(error.waitForExistence(timeout: 20), app.debugDescription)
        tap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(error.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Panel closed"].firstMatch.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "back-restores-page-without-stale-error"; image.lifetime = .keepAlways; add(image)
        tap(app.buttons["More"].firstMatch)
        tap(app.buttons["Forward"].firstMatch)
        XCTAssertTrue(app.webViews.staticTexts["Panel opened"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
    }

    func testBottomToolbarRespondsBeforeBlockedDocumentFinishes() throws {
        try open("blocked")
        XCTAssertTrue(app.buttons["browser.tabs"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.webViews.staticTexts["Interactive page"].firstMatch.exists)
        XCTAssertTrue(fixture.hasPendingSlowResource)
        checkMoreAndTabs()
    }

    func testFirstLoadMatchesDarkThemeAndLaterNavigationKeepsPreviousPage() throws {
        try checkInitialLoading(appearance: "dark")
    }

    func testFirstLoadMatchesLightThemeAndLaterNavigationKeepsPreviousPage() throws {
        try checkInitialLoading(appearance: "light")
    }

    private func checkInitialLoading(appearance: String) throws {
        app.terminate()
        app.launchArguments += ["-wallpaper_source", "bing", "-appearance", appearance]
        app.launch()
        let initialLoading = app.descendants(matching: .any).matching(identifier: "browser.initial-loading").firstMatch
        let navigationPreview = app.descendants(matching: .any).matching(identifier: "browser.navigation-preview").firstMatch
        try open("blocked")
        XCTAssertTrue(initialLoading.waitForExistence(timeout: 20), app.debugDescription)
        let first = XCTAttachment(screenshot: app.screenshot())
        first.name = "first-load-\(appearance)-canvas"; first.lifetime = .keepAlways; add(first)
        // Keep a second frame for visual review of the native loading indicator.
        Thread.sleep(forTimeInterval: 0.4)
        let orbit = XCTAttachment(screenshot: app.screenshot())
        orbit.name = "first-load-\(appearance)-animation-next-frame"; orbit.lifetime = .keepAlways; add(orbit)
        try open("preview-first")
        let heading = app.webViews.staticTexts["Keep this page visible"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(initialLoading.waitForNonExistence(timeout: 5))
        tap(app.webViews.links["Open slow page"].firstMatch)
        XCTAssertFalse(navigationPreview.exists, "Loading must keep the live page interactive")
        XCTAssertTrue(fixture.hasPendingSlowResource)
        XCTAssertFalse(initialLoading.exists)
        let next = XCTAttachment(screenshot: app.screenshot())
        next.name = "navigation-without-frozen-cover"; next.lifetime = .keepAlways; add(next)
        tap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(navigationPreview.waitForNonExistence(timeout: 5))
    }

    func testToolbarRespondsAfterAddressKeyboardDismissal() throws {
        try open("slow")
        XCTAssertTrue(app.webViews.links["Next page"].firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<2 {
            tap(app.buttons["Edit Address or Search"].firstMatch)
            let field = app.textFields["addressEditor.query"].firstMatch
            tap(field)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        checkMoreAndTabs()
    }

    func testWebPageTextFieldsKeepFocusAndAcceptTyping() throws {
        try checkWebPageTyping(shakeAction: "none")
    }

    func testWebPageTextFieldsKeepFocusWithShakeActionEnabled() throws {
        try checkWebPageTyping(shakeAction: "darkMode")
    }

    private func checkWebPageTyping(shakeAction: String) throws {
        app.terminate()
        app.launchArguments += ["-browser_shake_action", shakeAction, "-is_incognito", "YES"]
        app.launch()
        try open("forms")
        let field = app.webViews.textFields["Page text input"].firstMatch
        tap(field)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText("hello")
        XCTAssertEqual(field.value as? String, "hello", app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Focused: text"].exists, app.debugDescription)

        let notes = app.webViews.textViews["Page notes"].firstMatch
        tap(notes)
        notes.typeText("message")
        XCTAssertEqual(notes.value as? String, "message", app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.exists, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "webpage-input-keyboard"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAddressKeywordKeepsKeyboardWithShakeActionEnabled() throws {
        app.terminate()
        app.launchArguments += ["-browser_shake_action", "fullscreen", "-is_incognito", "YES"]
        app.launch()
        try open("forms")
        XCTAssertTrue(app.webViews.staticTexts["Web page inputs"].firstMatch.waitForExistence(timeout: 15))
        tap(app.buttons["Edit Address or Search"].firstMatch)
        let field = app.textFields["addressEditor.query"].firstMatch
        tap(app.buttons["addressEditor.clearQuery"])
        tap(field)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText("eggs")
        XCTAssertEqual(field.value as? String, "eggs", app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.exists, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "address-keyword-keyboard-with-shake"; shot.lifetime = .keepAlways; add(shot)
    }

    func testMoreDropdownsStayOpenAndRunActions() throws {
        app.terminate()
        app.launchArguments += ["-builtin_reader_enabled", "YES"]
        app.launch()
        try open("second")
        XCTAssertTrue(app.webViews.staticTexts["Second page"].firstMatch.waitForExistence(timeout: 20))

        let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2))
        for iteration in 0..<2 {
            for (page, item) in [("openPage", "Open in Default Browser"),
                                  ("pageTools", "browser.ad-block-management"),
                                  ("scriptCommands", "browser.reader-command")] {
                tap(app.buttons["More"].firstMatch)
                tap(app.buttons["browser.moreMenu.\(page)"])
                let action = app.buttons[item].firstMatch
                XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
                // Keep the native dropdown open across a page-availability poll.
                Thread.sleep(forTimeInterval: 1.2)
                XCTAssertTrue(action.isHittable, app.debugDescription)
                XCTAssertFalse(app.buttons["browser.moreMenu.back"].exists)
                if iteration == 0 {
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.name = "more-dropdown-\(page)"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                }
                outside.tap()
                let panel = app.popovers.firstMatch
                if !panel.waitForNonExistence(timeout: 2) { outside.tap() }
                XCTAssertTrue(panel.waitForNonExistence(timeout: 5), app.debugDescription)
            }
        }

        tap(app.buttons["More"].firstMatch)
        tap(app.buttons["browser.moreMenu.pageTools"])
        tap(app.buttons["Page Zoom"].firstMatch)
        XCTAssertTrue(app.buttons["Zoom In"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "more-dropdown-zoom-action"; shot.lifetime = .keepAlways; add(shot)
    }

    func testFindInPageSearchesNavigatesAndDoesNotLeaveMenuBehind() throws {
        try open("find")
        XCTAssertTrue(app.webViews.staticTexts["needle first"].firstMatch.waitForExistence(timeout: 20))
        func openFind() -> XCUIElement {
            tap(app.buttons["More"].firstMatch)
            tap(app.buttons["browser.moreMenu.pageTools"])
            tap(app.buttons["Find in Page"].firstMatch)
            let field = app.searchFields["find.searchField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5), app.debugDescription)
            return field
        }
        let field = openFind()
        field.typeText("needle")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "system-find-native-panel"; shot.lifetime = .keepAlways; add(shot)
        let count = app.staticTexts["find.resultLabel"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 of 3"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed, app.debugDescription)
        let next = app.buttons["find.nextButton"]
        let previous = app.buttons["find.previousButton"]
        tap(next)
        XCTAssertTrue(app.webViews.staticTexts["NEEDLE second"].firstMatch.isHittable, app.debugDescription)
        tap(previous)
        XCTAssertTrue(app.webViews.staticTexts["needle first"].firstMatch.isHittable, app.debugDescription)
        tap(app.buttons["find.doneButton"])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let again = openFind()
        again.typeText("second")
        tap(app.buttons["find.doneButton"])
        XCTAssertTrue(again.waitForNonExistence(timeout: 5))
        tap(app.buttons["More"].firstMatch)
        tap(app.buttons["browser.moreMenu.pageTools"])
        tap(app.buttons["Page Zoom"].firstMatch)
        XCTAssertTrue(app.buttons["Zoom In"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testTabOverviewRecoversScreenshotAfterAppRestart() throws {
        try open("refined")
        XCTAssertTrue(app.webViews.staticTexts["Refined page"].firstMatch.waitForExistence(timeout: 20))
        tap(app.buttons["browser.tabs"])
        let preview = app.buttons.matching(identifier: "tabs.card.preview").matching(
            NSPredicate(format: "label BEGINSWITH %@", "Refined fixture,")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "overview-saved-screenshot"; before.lifetime = .keepAlways; add(before)
        app.terminate(); app.launch()
        let homeTabs = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+,? Tabs")).firstMatch
        tap(homeTabs)
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "overview-restored-screenshot"; after.lifetime = .keepAlways; add(after)
        tap(preview)
        XCTAssertTrue(app.webViews.staticTexts["Refined page"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
    }

    func testSlowPageCoverSurvivesOverviewAndRestartBeforeLoadFinishes() throws {
        try open("cover-slow")
        XCTAssertTrue(app.webViews.links["Next page"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(fixture.hasPendingSlowResource)
        tap(app.buttons["browser.tabs"])
        let preview = app.buttons.matching(identifier: "tabs.card.preview").matching(
            NSPredicate(format: "label BEGINSWITH %@", fixture.coverTitle + ",")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        app.terminate(); app.launch()
        tap(app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+,? Tabs")).firstMatch)
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "A page that never finishes loading must retain its cover across restart")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "slow-loading-tab-cover-after-restart"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testLiveDomainGroupsScrollBothWaysKeepDockFixedAndRememberView() throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_TAB_QA"] == "1" else {
            throw XCTSkip("Set SOULO_LIVE_TAB_QA=1 to verify tab groups with real websites")
        }
        let pages = [
            ("https://www.apple.com.cn/", "iPhone"), ("https://www.apple.com.cn/iphone/", "iPhone"),
            ("https://www.apple.com.cn/mac/", "Mac"), ("https://www.apple.com.cn/ipad/", "iPad"),
            ("https://github.com/", "GitHub"), ("https://www.swift.org/", "Swift"),
            ("https://www.baidu.com/", "百度"), ("https://www.wikipedia.org/", "Wikipedia")]
        func loadPage(_ index: Int) throws {
            try open(url: XCTUnwrap(URL(string: pages[index].0)))
            let content = app.webViews.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", pages[index].1)).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 45), app.debugDescription)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "live-tab-page-\(index)"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        try loadPage(0)
        tap(app.buttons["browser.tabs"])
        if app.scrollViews["tabs.groups"].exists { tap(app.buttons["tabs.view-mode"]) }
        tap(app.buttons["tabs.options"])
        if app.buttons["Close Other Tabs"].firstMatch.exists {
            tap(app.buttons["Close Other Tabs"].firstMatch)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        }
        tap(app.buttons["tabs.done"])
        for index in 1..<pages.count {
            tap(app.buttons["browser.tabs"])
            tap(app.buttons["tabs.tab_new_tab"])
            try loadPage(index)
        }
        tap(app.buttons["browser.tabs"])
        let toggle = app.buttons["tabs.view-mode"]
        XCTAssertLessThan(toggle.frame.midX, app.buttons["tabs.tab_new_tab"].frame.midX)
        tap(toggle)
        let groups = app.scrollViews["tabs.groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Group by Domain")
        let dockFrame = app.buttons["tabs.done"].frame
        for _ in 0..<3 { groups.swipeDown() }
        let row = app.descendants(matching: .any).matching(identifier: "tabs.group-row.host:apple.com.cn").firstMatch
        XCTAssertTrue(row.isHittable, app.debugDescription)
        XCTAssertEqual(app.buttons["tabs.done"].frame.midY, dockFrame.midY, accuracy: 1)
        let lastCard = row.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "iPad")).firstMatch
        XCTAssertTrue(lastCard.isHittable, app.debugDescription)
        XCTAssertEqual(lastCard.identifier, "tabs.card.preview", "The live iPad page must have its own saved cover")
        lastCard.press(forDuration: 1)
        tap(app.buttons["Close Tab"].firstMatch)
        XCTAssertTrue(lastCard.waitForNonExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "live-domain-groups-fixed-dock"; before.lifetime = .keepAlways; add(before)

        app.terminate(); app.launch()
        tap(app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+,? Tabs")).firstMatch)
        XCTAssertTrue(groups.waitForExistence(timeout: 5), "The chosen overview layout survives reopening the app")
        for _ in 0..<3 { groups.swipeDown() }
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "live-domain-groups-restored"; restored.lifetime = .keepAlways; add(restored)
        let first = row.buttons.matching(identifier: "tabs.card.preview").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "The Apple group must recover durable page covers")
        tap(first)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        tap(app.buttons["browser.tabs"])
        tap(toggle)
        XCTAssertTrue(groups.waitForNonExistence(timeout: 5))
        let carousel = XCTAttachment(screenshot: app.screenshot())
        carousel.name = "live-tabs-carousel-smaller-corners"; carousel.lifetime = .keepAlways; add(carousel)
        tap(app.buttons["tabs.done"])
    }

    func testFailedPageShowsFullAddressCopiesAndRetries() throws {
        let url = try XCTUnwrap(URL(string: "https://dkluge.shop/library/articles/reading-notes?query=%E4%B8%AD%E6%96%87&section=browser#full-address"))
        try open(url: url)
        let address = app.staticTexts["browser.error.url"]
        XCTAssertTrue(address.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertEqual(address.label, url.absoluteString, "Show the entire address, including its path, query and fragment")
        let copy = app.buttons["browser.error.copy-url"]
        if !copy.isHittable { app.scrollViews.firstMatch.swipeUp() }
        tap(copy)
        XCTAssertEqual(copy.label, "Link Copied")
        let retry = app.buttons["browser.error.retry"]
        if !retry.isHittable { app.scrollViews.firstMatch.swipeUp() }
        tap(retry)
        XCTAssertTrue(address.waitForExistence(timeout: 45), app.debugDescription)
        if !copy.isHittable { app.scrollViews.firstMatch.swipeUp() }
        tap(copy)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "live-load-failure-full-url-copied"; image.lifetime = .keepAlways; add(image)
        XCTAssertTrue(app.buttons["browser.error.compatibility"].exists)
        tap(app.buttons["browser.tabs"])
        let failedCover = app.buttons.matching(identifier: "tabs.card.preview").matching(
            NSPredicate(format: "value == %@", "Active tab")).firstMatch
        XCTAssertTrue(failedCover.waitForExistence(timeout: 10), "A failed real URL needs a rendered error cover")
        tap(failedCover)
        let home = app.buttons["browser.error.home"]
        if !home.isHittable { app.scrollViews.firstMatch.swipeUp() }
        tap(home)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
    }

    func testWholeGroupCloseRequiresConfirmationAndKeepsOtherGroups() throws {
        app.terminate()
        app.launchArguments += ["-tab_overview_grouped", "YES"]
        app.launch()
        try open("recent/1")
        XCTAssertTrue(app.webViews.staticTexts["Recent page 1"].firstMatch.waitForExistence(timeout: 20))
        tap(app.buttons["browser.tabs"])
        tap(app.buttons["tabs.options"])
        let closeOthers = app.buttons["Close Other Tabs"].firstMatch
        if closeOthers.exists { tap(closeOthers) }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap() }
        tap(app.buttons["tabs.done"])
        for number in 2...3 {
            tap(app.buttons["browser.tabs"])
            tap(app.buttons["tabs.tab_new_tab"])
            var url = try XCTUnwrap(URLComponents(url: root, resolvingAgainstBaseURL: false))
            url.host = "localhost"; url.path = "/recent/\(number)"
            try open(url: XCTUnwrap(url.url))
            XCTAssertTrue(app.webViews.staticTexts["Recent page \(number)"].firstMatch.waitForExistence(timeout: 20))
        }
        tap(app.buttons["browser.tabs"])
        let closeGroup = app.buttons["tabs.group.close.host:localhost"].firstMatch
        tap(closeGroup)
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "localhost")).firstMatch.exists)
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "whole-group-close-confirmation"; confirmation.lifetime = .keepAlways; add(confirmation)
        let cancel = dialog.buttons["Cancel"].firstMatch
        if cancel.exists { tap(cancel) }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap() }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        let target = app.descendants(matching: .any).matching(identifier: "tabs.group.host:localhost").firstMatch
        let other = app.descendants(matching: .any).matching(identifier: "tabs.group.host:127.0.0.1").firstMatch
        XCTAssertTrue(target.exists && other.exists, "Cancel must keep both groups")
        tap(closeGroup)
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        tap(dialog.buttons["Close Group"].firstMatch)
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
        XCTAssertTrue(other.exists, "Closing a group must preserve the other website")
        let remaining = XCTAttachment(screenshot: app.screenshot())
        remaining.name = "whole-group-close-preserves-other-site"; remaining.lifetime = .keepAlways; add(remaining)
        tap(app.buttons["tabs.done"])
        XCTAssertTrue(app.webViews.staticTexts["Recent page 1"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(["1 Tab", "1 Tabs"].contains(app.buttons["browser.tabs"].label))
    }

    func testGroupedOverviewStartsAtTopUsesRecentTabsAndKeepsOrderAfterRestart() throws {
        app.terminate()
        app.launchArguments += ["-tab_overview_grouped", "YES"]
        app.launch()
        let hosts = ["127.0.0.1", "localhost", "127.0.0.1", "localhost", "localhost", "localhost"]
        func load(_ number: Int) throws {
            var url = try XCTUnwrap(URLComponents(url: root, resolvingAgainstBaseURL: false))
            url.host = hosts[number - 1]; url.path = "/recent/\(number)"
            try open(url: XCTUnwrap(url.url))
            XCTAssertTrue(app.webViews.staticTexts["Recent page \(number)"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        }
        try load(1)
        tap(app.buttons["browser.tabs"])
        tap(app.buttons["tabs.options"])
        let closeOthers = app.buttons["Close Other Tabs"].firstMatch
        if closeOthers.exists { tap(closeOthers) }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap() }
        tap(app.buttons["tabs.done"])
        // Older blank tabs provide real vertical overflow in portrait without
        // depending on rotation support or extra loopback aliases.
        for _ in 0..<6 {
            tap(app.buttons["browser.tabs"]); tap(app.buttons["tabs.tab_new_tab"])
        }
        for number in 2...6 {
            tap(app.buttons["browser.tabs"]); tap(app.buttons["tabs.tab_new_tab"])
            try load(number)
        }
        func checkTop(_ first: Int, _ second: Int) {
            let header = app.descendants(matching: .any).matching(identifier: "tabs.group.host:localhost").firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertLessThan(header.frame.minY, app.frame.height * 0.25, "The most recently used group starts at the top")
            let row = app.descendants(matching: .any).matching(identifier: "tabs.group-row.host:localhost").firstMatch
            let firstCard = row.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent page \(first),")).firstMatch
            let secondCard = row.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent page \(second),")).firstMatch
            XCTAssertTrue(firstCard.isHittable && secondCard.isHittable, app.debugDescription)
            XCTAssertLessThan(firstCard.frame.minX, secondCard.frame.minX, "Tabs inside a group follow recent use")
            let wrapped = row.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent page 2,")).firstMatch
            XCTAssertTrue(wrapped.isHittable, app.debugDescription)
            XCTAssertGreaterThan(wrapped.frame.minY, firstCard.frame.maxY, "The fourth tab wraps onto the next row")
            XCTAssertEqual(wrapped.frame.minX, firstCard.frame.minX, accuracy: 2)
        }
        tap(app.buttons["browser.tabs"])
        checkTop(6, 5)
        let topGroup = app.descendants(matching: .any).matching(identifier: "tabs.group.host:localhost").firstMatch
        let dockY = app.buttons["tabs.done"].frame.midY
        let groups = app.scrollViews["tabs.groups"]
        @discardableResult
        func dragInsideCard(verticalDistance: CGFloat, horizontalDrift: CGFloat,
            velocity: XCUIGestureVelocity = .slow, hold: TimeInterval = 0.2) -> (card: XCUIElement, y: CGFloat)? {
            let viewport = groups.frame.intersection(CGRect(x: app.frame.minX, y: groups.frame.minY + 8,
                width: app.frame.width, height: max(0, dockY - 44 - groups.frame.minY - 8)))
            let cards = groups.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tabs.card.")).allElementsBoundByIndex
            var target: CGRect?
            var targetCard: XCUIElement?
            var largestArea: CGFloat = 0
            for card in cards {
                let visibleFrame = card.frame.intersection(viewport)
                guard !visibleFrame.isNull, visibleFrame.width > 40, visibleFrame.height > 35 else { continue }
                let area = visibleFrame.width * visibleFrame.height
                if area > largestArea { target = visibleFrame; targetCard = card; largestArea = area }
            }
            guard let target, let targetCard else { XCTFail("A visible card is required for the scroll gesture"); return nil }
            let originalY = targetCard.frame.minY
            // Visible element indices change when LazyVStack recycles rows.
            // Keep the same card identity for the post-scroll assertion.
            let stableCard = groups.buttons.matching(NSPredicate(format: "label == %@", targetCard.label)).firstMatch
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: target.midX - app.frame.minX, dy: target.midY - app.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: horizontalDrift, dy: verticalDistance)),
                withVelocity: velocity, thenHoldForDuration: hold)
            return (stableCard, originalY)
        }
        // Begin on card content, including a small diagonal drift, rather than
        // on empty list spacing where the card recognizer never participates.
        for drift in [CGFloat(-14), 12, -6] {
            let topY = topGroup.frame.minY
            dragInsideCard(verticalDistance: -115, horizontalDrift: drift)
            XCTAssertTrue(groups.exists)
            XCTAssertTrue(!topGroup.isHittable || topGroup.frame.minY < topY - 20,
                "Upward drags starting on cards must scroll even with horizontal drift")
            XCTAssertEqual(app.buttons["tabs.done"].frame.midY, dockY, accuracy: 1)
            if let moved = dragInsideCard(verticalDistance: 150, horizontalDrift: -drift) {
                XCTAssertTrue(groups.exists)
                XCTAssertTrue(!moved.card.exists || !moved.card.isHittable || moved.card.frame.minY > moved.y + 20,
                    "Downward card drags must move the list toward its top")
            }
            tap(app.buttons["tabs.done"])
            XCTAssertEqual(app.buttons["browser.tabs"].label, "12 Tabs", "Vertical drags must not delete tabs")
            tap(app.buttons["browser.tabs"])
            checkTop(6, 5)
        }
        // Fast flicks may coast much farther than the finger. Check direction,
        // then reopen to verify the top position separately from deceleration.
        if let moved = dragInsideCard(verticalDistance: -115, horizontalDrift: 10, velocity: .fast, hold: 0) {
            XCTAssertTrue(groups.exists)
            XCTAssertTrue(!moved.card.exists || !moved.card.isHittable || moved.card.frame.minY < moved.y - 20)
        }
        if let moved = dragInsideCard(verticalDistance: 150, horizontalDrift: -10, velocity: .fast, hold: 0) {
            XCTAssertTrue(groups.exists)
            XCTAssertTrue(!moved.card.exists || !moved.card.isHittable || moved.card.frame.minY > moved.y + 20)
        }
        tap(app.buttons["tabs.done"])
        XCTAssertEqual(app.buttons["browser.tabs"].label, "12 Tabs", "Fast flicks must not delete tabs")
        tap(app.buttons["browser.tabs"])
        checkTop(6, 5)
        let fifth = app.descendants(matching: .any).matching(identifier: "tabs.group-row.host:localhost").firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent page 5,")).firstMatch
        tap(fifth)
        XCTAssertTrue(app.webViews.staticTexts["Recent page 5"].firstMatch.waitForExistence(timeout: 10), "Selecting a reordered card must open the correct tab")
        app.terminate(); app.launch()
        tap(app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+,? Tabs")).firstMatch)
        checkTop(5, 6)
        let firstPage = app.descendants(matching: .any).matching(identifier: "tabs.group-row.host:127.0.0.1").firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent page 1,")).firstMatch
        tap(firstPage)
        XCTAssertTrue(app.webViews.staticTexts["Recent page 1"].firstMatch.waitForExistence(timeout: 10))
        tap(app.buttons["browser.tabs"])
        let currentCard = app.descendants(matching: .any).matching(identifier: "tabs.group-row.host:127.0.0.1").firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recent page 1,")).firstMatch
        currentCard.swipeLeft()
        XCTAssertTrue(currentCard.waitForNonExistence(timeout: 5), "Left swipe closes only this grouped card")
        let remainingGroup = app.descendants(matching: .any).matching(identifier: "tabs.group.host:127.0.0.1").firstMatch
        let otherGroup = app.descendants(matching: .any).matching(identifier: "tabs.group.host:localhost").firstMatch
        XCTAssertTrue(remainingGroup.exists && otherGroup.exists)
        XCTAssertLessThan(remainingGroup.frame.minY, otherGroup.frame.minY, "Closing the newest card must not move the rest of its group")
        tap(app.buttons["tabs.done"])
        XCTAssertEqual(app.buttons["browser.tabs"].label, "11 Tabs", "Left swipe closes exactly one card")
        XCTAssertTrue(app.webViews.staticTexts["Recent page 5"].firstMatch.waitForExistence(timeout: 10), "Closing the current card returns to the most recently used remaining page")
        tap(app.buttons["browser.tabs"])
        checkTop(5, 6)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "recent-domain-groups-restored-at-top"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testManyTabsUseBoundedPreviewsAndScrubberWithoutLoadingUntilSelection() throws {
        try open("refined")
        XCTAssertTrue(app.webViews.staticTexts["Refined page"].firstMatch.waitForExistence(timeout: 20))
        tap(app.buttons["browser.tabs"])
        tap(app.buttons["tabs.options"])
        let closeOthers = app.buttons["Close Other Tabs"].firstMatch
        if closeOthers.exists {
            tap(closeOthers)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        }
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        tap(app.buttons["tabs.done"])
        for _ in 0..<25 {
            tap(app.buttons["browser.tabs"])
            tap(app.buttons["tabs.tab_new_tab"])
        }
        XCTAssertTrue(app.buttons["browser.tabs"].label.hasPrefix("26 "), app.debugDescription)
        tap(app.buttons["browser.tabs"])
        if app.scrollViews["tabs.groups"].exists { tap(app.buttons["tabs.view-mode"]) }
        let scrubber = app.sliders["tabs.position"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), app.debugDescription)
        scrubber.adjust(toNormalizedSliderPosition: 1)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Refined fixture,")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(scrubber.frame.intersects(card.frame), "Position control must remain below the preview card")
        XCTAssertFalse(card.isSelected, "Browsing a preview must not mark the background page as the active tab")
        XCTAssertFalse(app.webViews.staticTexts["Refined page"].firstMatch.exists,
            "Scrubbing previews must not activate or load the background page")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "many-tabs-bounded-previews-and-position"; screenshot.lifetime = .keepAlways; add(screenshot)
        tap(card)
        XCTAssertTrue(app.webViews.staticTexts["Refined page"].firstMatch.waitForExistence(timeout: 10))
    }

    func testHomeSearchCreatesTabAndAddressSearchKeepsIt() throws {
        app.terminate()
        app.launchArguments += ["-is_incognito", "YES", "-show_top_tab_bar", "YES"]
        app.launch()

        let homeField = app.textFields["Private search or enter URL"].firstMatch
        tap(homeField)
        homeField.typeText(root.appendingPathComponent("slow").absoluteString + "\n")
        XCTAssertTrue(app.webViews.links["Next page"].firstMatch.waitForExistence(timeout: 20))
        let tabs = app.buttons["browser.tabs"]
        XCTAssertEqual(tabs.label, "1 Tabs", "The initial empty tab should be reused")

        tap(app.buttons["Home Screen"].firstMatch)
        tap(homeField)
        homeField.typeText(root.appendingPathComponent("second").absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Second page"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(tabs.label, "2 Tabs", "Searching from Home should preserve the original tab")

        tap(app.buttons["Edit Address or Search"].firstMatch)
        let address = app.textFields["addressEditor.query"].firstMatch
        tap(app.buttons["addressEditor.clearQuery"])
        tap(address)
        address.typeText(root.appendingPathComponent("refined").absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Refined page"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(tabs.label, "2 Tabs", "Address searches should stay in the active tab")

        tap(app.buttons[fixture.pageTitle + ", tab 1 of 2"])
        XCTAssertTrue(app.webViews.links["Next page"].firstMatch.waitForExistence(timeout: 10))
    }
}

private final class ToolbarHTTPFixture: @unchecked Sendable {
    let pageTitle = "Toolbar fixture \(UUID().uuidString.prefix(8))"
    let coverTitle = "Slow cover fixture \(UUID().uuidString.prefix(8))"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.toolbar.ui-fixture")
    private var connections: [NWConnection] = []
    private var slowRequests = 0
    private var completedSlowRequests = 0
    var hasPendingSlowResource: Bool { queue.sync { slowRequests > completedSlowRequests } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self, let data else { connection.cancel(); return }
                let path = String(decoding: data, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if path == "/disconnect" { connection.cancel(); return }
                let body: String
                if path == "/slow.js" { body = "window.slowResourceFinished=true;" }
                else if path == "/second" { body = "<html><body><p>Second page</p></body></html>" }
                else if path == "/interactive-source" { body = """
                    <meta name='viewport' content='width=device-width,initial-scale=1'>
                    <h1>Search results</h1><a href='/never-commits' style='font:24px system-ui'>Open slow result</a>
                    <div style='height:750px'>More results</div>
                    <button style='font:24px system-ui' onclick="document.getElementById('status').textContent='Still responsive'">Check response</button>
                    <p id='status'>Ready</p><a href='/second' style='font:24px system-ui'>Open another result</a>
                    <div style='height:1600px'>More results below</div>
                    """ }
                else if path == "/preview-first" { body = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='background:#edf5ff;color:#163050;font:24px system-ui;padding:28px'><h1>Keep this page visible</h1><a href='/blocked'>Open slow page</a></body></html>" }
                else if path == "/history-list" { body = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Video list</h1><a href='/history-player' style='font:24px system-ui'>Watch video</a>" }
                else if path == "/history-player" { body = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Video player</h1><iframe src='/history-frame-one' style='width:90%;height:200px'></iframe>" }
                else if path == "/history-frame-one" { body = "<a href='/history-frame-two' style='font:24px system-ui'>Load player</a>" }
                else if path == "/history-frame-two" { body = """
                    <a href='/history-frame-three' style='font:24px system-ui'>Start video</a>
                    <script>addEventListener('pageshow',()=>{
                      const frame=document.createElement('iframe');frame.src='/history-frame-warmup';document.body.append(frame);
                    });</script>
                    """ }
                else if path == "/history-frame-three" { body = "<h2>Player ready</h2>" }
                else if path == "/history-frame-warmup" { body = "<body></body>" }
                else if path == "/history-error-state" { body = """
                    <meta name='viewport' content='width=device-width,initial-scale=1'><h1>History page</h1>
                    <button onclick="history.pushState({panel:true},'',location.href);statusText.textContent='Panel opened'" style='font:24px system-ui'>Open panel</button>
                    <p id='statusText'>Panel closed</p><a href='/disconnect' style='font:24px system-ui'>Unavailable page</a>
                    <script>addEventListener('popstate',()=>statusText.textContent=history.state?.panel?'Panel opened':'Panel closed')</script>
                    """ }
                else if path == "/forms" { body = """
                    <!doctype html><html><head><title>Input focus fixture</title><meta name="viewport" content="width=device-width,initial-scale=1">
                    <style>body{font:18px system-ui;margin:24px}label{display:block;margin:16px 0}input,textarea{display:block;box-sizing:border-box;width:100%;padding:12px;font:18px system-ui}textarea{height:90px}</style></head>
                    <body><h1>Web page inputs</h1><label>Page text input<input id="text" aria-label="Page text input"></label>
                    <label>Page notes<textarea id="notes" aria-label="Page notes"></textarea></label><p id="focus">No field focused</p>
                    <script>document.addEventListener('focusin',e=>document.getElementById('focus').textContent='Focused: '+e.target.id);
                    document.addEventListener('focusout',()=>document.getElementById('focus').textContent='No field focused');</script></body></html>
                    """ }
                else if path.hasPrefix("/recent/"), let number = Int(path.split(separator: "/").last ?? "") {
                    body = "<html><head><title>Recent page \(number)</title><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='font:24px system-ui;background:#eee9fa'><h1>Recent page \(number)</h1><p>Saved page preview for recent tab ordering.</p></body></html>"
                }
                else if path == "/refined" { body = """
                    <html><head><title>Refined fixture</title><meta name="viewport" content="width=device-width, initial-scale=1">
                    <style>body{margin:0;background:#eee9fa;font:18px -apple-system;color:#312050}header{background:#6950a1;color:white;padding:48px 28px}h1{font-size:32px}article{margin:24px;padding:24px;border-radius:20px;background:white;line-height:1.6}</style></head>
                    <body><header><h1>Refined page</h1><p>Saved tab preview</p></header><article>This page remains recognizable after WebKit is released and the app restarts.</article></body></html>
                    """ }
                else if path == "/find" {
                    body = """
                    <html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Find fixture</title></head>
                    <body style="font:24px system-ui">
                    <p>needle first</p><div style="height:1000px"></div>
                    <p>NEEDLE second</p><div style="height:1000px"></div><p>needle third</p>
                    <p style="display:none">needle hidden</p><script>window.find = undefined;</script>
                    </body></html>
                    """
                }
                else {
                    let script = path == "/blocked" ? "<script src='/slow.js'></script>" : "<script async src='/slow.js'></script>"
                    let title = path == "/cover-slow" ? self.coverTitle : self.pageTitle
                    body = "<html><head><title>\(title)</title>\(script)</head><body style='font:20px system-ui'><p>Interactive page</p><a href='/second'>Next page</a></body></html>"
                }
                let bytes = Data(body.utf8)
                let type = path == "/slow.js" ? "application/javascript" : "text/html; charset=utf-8"
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                response.append(bytes)
                let send = { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
                if path == "/slow.js" || path == "/never-commits" {
                    self.slowRequests += 1
                    self.queue.asyncAfter(deadline: .now() + 180) { [weak self] in
                        self?.completedSlowRequests += 1
                        send()
                    }
                }
                else { send() }
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            throw NSError(domain: "ToolbarHTTPFixture", code: 1)
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func stop() {
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll(); listener.cancel() }
    }
}
