import XCTest
import Network
import ObjectiveC

@MainActor
final class BrowserGestureUITests: XCTestCase {
    private func launch(chinese: Bool = false, hidden: Bool = false, largeText: Bool = false,
                        gestures: Bool? = nil, edgeFallback: Bool = true, execution: String? = nil, grouped: Bool? = nil) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", chinese ? "zh-Hans" : "en-US", "-appearance", chinese ? "dark" : "light",
            "-is_incognito", "NO", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
            "-wallpaper_source", "gradient", "-wallpaper_refresh_interval", "0", "-keep_fullscreen_browsing", "NO",
            "-browser_toolbar_hidden", hidden ? "YES" : "NO", "-privacy_https_upgrade_enabled", "NO"]
        if let gestures { app.launchArguments += ["-browser.twoFingerSwipe.enabled", gestures ? "YES" : "NO"] }
        if hidden { app.launchArguments += ["-browser.twoFingerSwipe.right", "closeTab", "-browser.twoFingerSwipe.left", "tabs"] }
        if hidden { app.launchArguments += ["-browser.noHistorySwipe.action", edgeFallback ? "closeTab" : "none"] }
        if let execution { app.launchArguments += ["-browser.swipe.execution", execution] }
        if let grouped { app.launchArguments += ["-tab_overview_grouped", grouped ? "YES" : "NO"] }
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func open(_ url: URL, app: XCUIApplication, title: String) {
        let home = app.buttons["Home Screen"].firstMatch
        if home.exists { home.tap() }
        let field = app.textFields["search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        let clear = app.buttons["search.clear"].firstMatch
        if clear.exists { clear.tap(); field.tap() }
        field.typeText(url.absoluteString)
        let submit = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Search", "search", "搜索", "Go", "前往"])).firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5)); submit.tap()
        XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
    }

    func testTwoFingerHintAppearsWhileHeldAndReleaseClosesTab() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(hidden: true, gestures: true, edgeFallback: false, execution: "release"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        try swipe(app, right: true, captureWhileHeld: true)
        XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.waitForNonExistence(timeout: 5))
    }

    func testTapModeHintsRemainSmallAndWebTouchesCancelThem() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(hidden: true, gestures: true, edgeFallback: false, execution: "tap"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        let first = app.webViews.staticTexts[fixture.firstTitle].firstMatch
        try swipe(app, right: true, reverse: true)
        XCTAssertTrue(first.exists)
        XCTAssertFalse(app.buttons["browser.gesture.action.closeTab"].exists)
        try swipe(app, right: true)
        let close = app.buttons["browser.gesture.action.closeTab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(close.frame.height, 100)
        XCTAssertLessThan(close.frame.width, 190, "The hint must hug its icon and label")
        XCTAssertLessThan(close.frame.minX, 36, "Rightward swipes must keep the hint at the left edge")
        XCTAssertEqual(close.frame.maxY, app.frame.height * 0.42 - 24, accuracy: 8, "The hint must stay above the upper finger with a clear gap")
        capture(app, "compact-tap-hint-light")
        XCTAssertTrue(close.exists)
        XCTAssertTrue(close.isHittable, "Tap mode must keep the small hint available after lifting")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.82)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        app.webViews.firstMatch.swipeUp(); XCTAssertFalse(first.isHittable)
        app.webViews.firstMatch.swipeDown(); XCTAssertTrue(first.isHittable)
        app.webViews.firstMatch.pinch(withScale: 1.3, velocity: 1)
        XCTAssertFalse(close.exists)
        try swipe(app, right: false)
        let tabs = app.buttons["browser.gesture.action.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(tabs.frame.maxX, app.frame.width - 36, "Leftward swipes must keep the hint at the right edge")
        tabs.tap()
        XCTAssertTrue(app.buttons["tabs.done"].waitForExistence(timeout: 5)); app.buttons["tabs.done"].tap()
        XCTAssertTrue(app.buttons["tabs.done"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        try swipe(app, right: true)
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
    }

    func testNoHistoryEdgeReleaseWorksWithTwoFingerGesturesOff() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(hidden: true, gestures: false, execution: "release"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        let first = app.webViews.staticTexts[fixture.firstTitle].firstMatch
        try swipe(app, right: true, fingers: 1, fromEdge: true, reverse: true)
        XCTAssertTrue(first.exists)
        XCTAssertFalse(app.buttons["browser.gesture.action.closeTab"].exists)
        try swipe(app, right: true, fingers: 1, fromEdge: true)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
    }

    func testUnevenTwoFingerMotionAndStaggeredLiftKeepHintUntilBothRelease() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(hidden: true, gestures: true, edgeFallback: false, execution: "release"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        try swipe(app, right: true, captureWhileHeld: true, uneven: true)
        XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.waitForNonExistence(timeout: 5))
    }

    func testNoHistoryTapModeCancelsAndExecutes() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(hidden: true, gestures: false, execution: "tap"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        let first = app.webViews.staticTexts[fixture.firstTitle].firstMatch
        try swipe(app, right: true, fingers: 1, fromEdge: true)
        let close = app.buttons["browser.gesture.action.closeTab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertTrue(first.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.82)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        try swipe(app, right: true, fingers: 1, fromEdge: true)
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
    }

    func testExistingHistoryNeverOffersTheNoHistoryCloseAction() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(gestures: true, execution: "release"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        app.webViews.links["Next page"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts[fixture.secondTitle].firstMatch.waitForExistence(timeout: 5))
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.isEnabled)
        try swipe(app, right: true, fingers: 1, fromEdge: true)
        XCTAssertFalse(app.buttons["browser.gesture.action.closeTab"].exists)
        let first = app.webViews.staticTexts[fixture.firstTitle].firstMatch
        if !first.exists { back.tap() }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
    }

    func testGestureSettingsIllustrationChoicesAndCompactMenuPreview() {
        let app = launch(); defer { app.terminate() }
        openGestureSettings(app)
        let toggle = app.switches["settings.gestures.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        capture(app, "webpage-gestures-two-finger-default-off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["settings.gestures.right"].isEnabled)
        app.buttons["settings.gestures.right"].tap(); app.buttons["Close Tab"].firstMatch.tap()
        app.buttons["settings.gestures.preview.right"].tap()
        let close = app.buttons["browser.gesture.action.closeTab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertLessThan(close.frame.height, 100)
        close.tap(); XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.buttons["settings.gestures.right"].tap(); app.buttons["Quick Menu"].firstMatch.tap()
        app.buttons["settings.gestures.preview.right"].tap()
        let show = app.buttons["browser.gesture.action.showToolbar"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        capture(app, "compact-custom-menu-preview")
        show.tap()
        XCTAssertTrue(show.waitForNonExistence(timeout: 3))
        app.buttons["settings.gestures.right"].tap(); app.buttons["Close Tab"].firstMatch.tap()
        let mode = app.buttons["settings.gestures.execution"]
        reveal(mode, in: app); mode.tap(); app.buttons["On Tap"].firstMatch.tap()
        capture(app, "gesture-execution-choice")
        mode.tap(); app.buttons["On Release"].firstMatch.tap()
        let feedbackSettings = app.buttons["settings.gestures.feedback"]
        reveal(feedbackSettings, in: app); feedbackSettings.tap()
        let haptics = app.switches["settings.feedback.haptics"]
        reveal(haptics, in: app)
        if haptics.value as? String == "1" { haptics.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(haptics.value as? String, "0")
        let sound = app.switches["settings.feedback.sound"]
        if sound.value as? String != "1" { sound.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(sound.value as? String, "1")
        app.buttons["settings.feedback.preview"].tap()
        capture(app, "gesture-feedback-options")
        sound.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        haptics.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(toggle, in: app, upward: false)
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
    }

    func testChineseDarkCompactHintAndLargestText() {
        let standard = launch(chinese: true)
        openGestureSettings(standard, chinese: true)
        capture(standard, "gesture-settings-chinese-dark")
        let feedback = standard.buttons["settings.gestures.feedback"]
        reveal(feedback, in: standard); feedback.tap()
        capture(standard, "gesture-settings-chinese-feedback")
        standard.terminate()
        let app = launch(chinese: true, largeText: true); defer { app.terminate() }
        openGestureSettings(app, chinese: true)
        let preview = app.buttons["settings.gestures.preview.noHistory"]
        reveal(preview, in: app); preview.tap()
        let close = app.buttons["browser.gesture.action.closeTab"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertLessThan(close.frame.height, 190)
        capture(app, "compact-hint-chinese-dark-accessibility")
        close.tap(); XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    func testShortHorizontalFlicksDoNotActivateOverviewCards() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(); defer { app.terminate() }
        func load(_ url: URL, title: String) throws {
            var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
            route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            app.open(try XCTUnwrap(route.url))
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 15))
        }
        try load(root, title: fixture.firstTitle)
        app.buttons["browser.tabs"].tap()
        app.buttons["tabs.options"].tap()
        let closeOthers = app.buttons["Close Other Tabs"].firstMatch
        if closeOthers.exists { closeOthers.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap() }
        let done = app.buttons["tabs.done"]
        done.tap()
        try load(root.appendingPathComponent("second"), title: fixture.secondTitle)
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let groups = app.scrollViews["tabs.groups"]
        let mode = app.buttons["tabs.view-mode"]
        if groups.exists { mode.tap() }
        XCTAssertTrue(groups.waitForNonExistence(timeout: 5))

        func card(_ title: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "tabs.card.", title)).firstMatch
        }
        let recent = card(fixture.secondTitle)
        let previous = card(fixture.firstTitle)
        for grouped in [false, true] {
            if grouped {
                mode.tap()
                XCTAssertTrue(groups.waitForExistence(timeout: 5))
                if !recent.exists { app.buttons["tabs.group.host:127.0.0.1"].tap() }
            }
            XCTAssertTrue(recent.waitForExistence(timeout: 5), app.debugDescription)
            for distance: CGFloat in [-6.5, 6.5] {
                let start = recent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                            withVelocity: .fast, thenHoldForDuration: 0)
                XCTAssertTrue(done.exists, "A short flick must leave the \(grouped ? "grouped" : "carousel") overview open")
                XCTAssertTrue(recent.exists && previous.exists, "A short flick must retain both tabs")
            }
            if !grouped {
                let start = recent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: -145, dy: 0)),
                            withVelocity: .fast, thenHoldForDuration: 0)
                XCTAssertTrue(done.exists)
                XCTAssertEqual(previous.frame.midX, app.frame.midX, accuracy: 18, "A horizontal drag must still browse the carousel")
                previous.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
                XCTAssertTrue(done.waitForNonExistence(timeout: 5))
                XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.waitForExistence(timeout: 5))
                app.buttons["browser.tabs"].tap()
                XCTAssertTrue(done.waitForExistence(timeout: 5))
            }
        }
        let groupedCard = recent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        groupedCard.press(forDuration: 0.8)
        let duplicate = app.buttons["Duplicate Tab"].firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "Long press must still show the card menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(duplicate.waitForNonExistence(timeout: 5))
        groupedCard.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts[fixture.secondTitle].firstMatch.waitForExistence(timeout: 5))
    }

    func testGroupedBlankTapsDismissWithoutStealingCardGestures() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(grouped: true); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        app.buttons["browser.tabs"].tap()
        app.buttons["tabs.options"].tap()
        let closeOthers = app.buttons["Close Other Tabs"].firstMatch
        if closeOthers.exists { closeOthers.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap() }
        app.buttons["tabs.done"].tap()
        XCTAssertTrue(app.buttons["tabs.done"].waitForNonExistence(timeout: 5))
        open(root.appendingPathComponent("second"), app: app, title: fixture.secondTitle)
        app.buttons["browser.tabs"].tap()
        let groups = app.scrollViews["tabs.groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        let header = app.descendants(matching: .any).matching(identifier: "tabs.group.host:127.0.0.1").firstMatch
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(groups.exists, "A group header is not an empty dismiss area")
        let cards = groups.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tabs.card."))
        let current = cards.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.secondTitle)).firstMatch
        let other = cards.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.firstTitle)).firstMatch
        if !current.exists { header.tap() }
        XCTAssertTrue(current.isHittable && other.isHittable, app.debugDescription)
        XCTAssertTrue(current.isSelected)
        XCTAssertFalse(other.isSelected)
        capture(app, "grouped-overview-active-card")
        other.tap()
        XCTAssertTrue(groups.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.waitForExistence(timeout: 5),
                      "Tapping an inactive card must select it, not just dismiss the overview")
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        XCTAssertTrue(other.isSelected)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let blankDrag = origin.withOffset(CGVector(dx: 8, dy: current.frame.midY))
        blankDrag.press(forDuration: 0.05, thenDragTo: blankDrag.withOffset(CGVector(dx: 0, dy: -70)))
        XCTAssertTrue(groups.exists, "Dragging from empty space must not dismiss")
        current.swipeLeft()
        XCTAssertTrue(current.waitForNonExistence(timeout: 5), "Left swipe must still close exactly that card")
        XCTAssertTrue(groups.exists && other.exists, "Deleting a card must keep the overview and other tabs")
        capture(app, "grouped-overview-after-card-swipe")
        let blank = origin.withOffset(CGVector(dx: app.frame.width - 32, dy: other.frame.midY))
        blank.tap()
        XCTAssertTrue(groups.waitForNonExistence(timeout: 5), "Tapping an unused grid slot must dismiss")
        XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.waitForExistence(timeout: 5))
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        let remaining = groups.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", fixture.firstTitle + ",")).firstMatch
        remaining.tap()
        XCTAssertTrue(groups.waitForNonExistence(timeout: 5), "Card taps must still select the tab")
        XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.exists)
    }

    func testWebsiteZoomIsRestoredOnAnotherVisitToTheSameDomain() throws {
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(); defer { app.terminate() }
        func showZoom() {
            app.buttons["More"].firstMatch.tap(); app.buttons["browser.moreMenu.pageTools"].tap()
            app.buttons["Page Zoom"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Zoom In"].waitForExistence(timeout: 5))
        }
        open(root, app: app, title: fixture.firstTitle); showZoom()
        app.buttons["Reset to 100%"].tap(); app.buttons["Zoom In"].tap()
        XCTAssertEqual(app.buttons["Reset to 100%"].value as? String, "110%")
        app.buttons["Done"].firstMatch.tap()
        open(root.appendingPathComponent("revisit"), app: app, title: fixture.firstTitle); showZoom()
        XCTAssertEqual(app.buttons["Reset to 100%"].value as? String, "110%")
        capture(app, "website-zoom-restored-next-visit")
        app.buttons["Reset to 100%"].tap()
    }

    private func openGestureSettings(_ app: XCUIApplication, chinese: Bool = false) {
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons[chinese ? "设置" : "Settings"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        search.typeText(chinese ? "网页手势" : "Webpage Gestures")
        let link = app.buttons["settings.gestures"]
        XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        let toggle = app.switches["settings.gestures.enabled"]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.exists && abs(toggle.frame.midX - app.frame.midX) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    func testNativeHistoryWithTwoFingerGesturesDisabled() throws {
        guard ProcessInfo.processInfo.environment["SOULO_NATIVE_EDGE_QA"] == "1" else {
            throw XCTSkip("Opt-in WebKit edge injection diagnostic; see docs/qa/2026-11-01-browser-state-performance.md")
        }
        let fixture = try GestureHTTPFixture(); defer { fixture.stop() }
        let root = try fixture.start()
        let app = launch(hidden: true, gestures: false, edgeFallback: false, execution: "release"); defer { app.terminate() }
        open(root, app: app, title: fixture.firstTitle)
        app.webViews.links["Next page"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts[fixture.secondTitle].firstMatch.waitForExistence(timeout: 5))
        try swipe(app, right: true, fingers: 1, fromEdge: true)
        XCTAssertTrue(app.webViews.staticTexts[fixture.firstTitle].firstMatch.waitForExistence(timeout: 5))
    }

    // XCTest's public swipe methods only expose one touch. The test runner's
    // event synthesizer sends two real simultaneous touch paths to the app.
    // These runtime calls are confined to the UI test bundle.
    private func swipe(_ app: XCUIApplication, right: Bool, fingers: Int = 2, fromEdge: Bool = false, reverse: Bool = false, captureWhileHeld: Bool = false, uneven: Bool = false) throws {
        let record = try allocate("XCSynthesizedEventRecord")
        let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        let recordInit = unsafeBitCast(try XCTUnwrap(record.method(for: initRecord)),
            to: (@convention(c) (NSObject, Selector, NSString, Int) -> Unmanaged<NSObject>).self)
        let initializedRecord = recordInit(record, initRecord, "Soulo two-finger swipe", 1).takeUnretainedValue()
        let width = app.frame.width
        let heights = fingers == 1 ? [app.frame.height * 0.5] : captureWhileHeld
            ? [app.frame.height * 0.28, app.frame.height * 0.36] : [app.frame.height * 0.42, app.frame.height * 0.50]
        for (index, y) in heights.enumerated() {
            let path = try allocate("XCPointerEventPath")
            let start = CGPoint(x: fromEdge ? 2 : width * (right ? 0.27 : 0.73), y: y)
            let end = CGPoint(x: width * (fromEdge ? 0.95 : right ? 0.73 : 0.27) + (uneven && index == 1 ? -22 : 0), y: y + (uneven ? index == 0 ? 6 : -8 : 0))
            let selector = NSSelectorFromString("initForTouchAtPoint:offset:")
            let initialize = unsafeBitCast(try XCTUnwrap(path.method(for: selector)),
                to: (@convention(c) (NSObject, Selector, CGPoint, Double) -> Unmanaged<NSObject>).self)
            let initialized = initialize(path, selector, start, uneven && index == 1 ? 0.04 : 0).takeUnretainedValue()
            let moveSelector = NSSelectorFromString("moveToPoint:atOffset:")
            let move = unsafeBitCast(try XCTUnwrap(initialized.method(for: moveSelector)),
                to: (@convention(c) (NSObject, Selector, CGPoint, Double) -> Void).self)
            move(initialized, moveSelector, start, uneven ? 0.1 : 0.05)
            move(initialized, moveSelector, end, 0.4)
            if reverse { move(initialized, moveSelector, start, 0.75) }
            let liftSelector = NSSelectorFromString("liftUpAtOffset:")
            let lift = unsafeBitCast(try XCTUnwrap(initialized.method(for: liftSelector)),
                to: (@convention(c) (NSObject, Selector, Double) -> Void).self)
            lift(initialized, liftSelector, uneven && index == 0 ? 1.2 : captureWhileHeld ? 5.0 : reverse ? 0.8 : 0.45)
            initializedRecord.perform(NSSelectorFromString("addPointerEventPath:"), with: initialized)
        }
        let synthesizer = try XCTUnwrap(XCUIDevice.shared.perform(NSSelectorFromString("eventSynthesizer"))?.takeUnretainedValue() as? NSObject)
        let finished = expectation(description: "two-finger events delivered")
        let completion: @convention(block) (Bool, NSError?) -> Void = { success, error in
            XCTAssertTrue(success, error?.localizedDescription ?? "Touch synthesis failed")
            finished.fulfill()
        }
        synthesizer.perform(NSSelectorFromString("synthesizeEvent:completion:"), with: initializedRecord, with: completion)
        if captureWhileHeld {
            let started = Date()
            Thread.sleep(forTimeInterval: uneven ? 2 : 0.8)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = uneven ? "hint-stays-after-first-finger-lifts" : "compact-hint-during-live-swipe"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "Screenshot must be captured before the fingers lift")
        }
        wait(for: [finished], timeout: 12)
    }

    private func allocate(_ name: String) throws -> NSObject {
        let type = try XCTUnwrap(NSClassFromString(name))
        let selector = NSSelectorFromString("alloc")
        let implementation = try XCTUnwrap(class_getMethodImplementation(object_getClass(type), selector))
        return unsafeBitCast(implementation, to: (@convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>).self)(type, selector).takeRetainedValue()
    }
}

private final class GestureHTTPFixture: @unchecked Sendable {
    private let token = String(UUID().uuidString.prefix(6))
    var firstTitle: String { "First " + token }
    var secondTitle: String { "Second " + token }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.gesture-ui-fixture")
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue, firstTitle, secondTitle] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let path = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                if path.hasPrefix("GET /trace?") { print("GESTURE_TRACE|" + (path.components(separatedBy: "\r\n").first ?? "")) }
                let title = path.hasPrefix("GET /second ") ? secondTitle : firstTitle
                let html = Data("<html><head><title>\(title)</title><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:30px;font:22px -apple-system;background:#f1f5fa'><h1>\(title)</h1><p>Use two fingers to reveal browser actions.</p><a href='/second'>Next page</a><div style='height:1600px'></div><script>addEventListener('pageshow',()=>{new Image().src='/trace?path='+encodeURIComponent(location.pathname)+'&history='+history.length+'&target='+document.querySelector('a').target+'&time='+Date.now()})</script></body></html>".utf8)
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(html)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else { throw NSError(domain: "GestureFixture", code: 1) }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
    }
    func stop() { listener.cancel() }
}
