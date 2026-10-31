import XCTest

@MainActor
final class LibraryPagingUITests: XCTestCase {
    private let sections = ["bookmarks", "history", "downloads", "files"]

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light",
            "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        return app
    }

    private func open(_ section: String, app: XCUIApplication) throws {
        app.open(try XCTUnwrap(URL(string: "soulo://" + section)))
        assertSelected(section, app: app)
    }

    private func assertSelected(_ section: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["library.section." + section]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in button.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription, file: file, line: line)
        if section != "files" {
            let page = app.collectionViews.firstMatch
            let viewport = app.scrollViews["library.pages"].firstMatch
            let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                page.exists && abs(page.frame.midX - viewport.frame.midX) < 1.5
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed, "Selected content must be on screen: " + app.debugDescription, file: file, line: line)
        }
        for other in sections where other != section {
            XCTAssertFalse(app.buttons["library.section." + other].isSelected, file: file, line: line)
        }
    }

    private func page(left: Bool, app: XCUIApplication) {
        let viewport = app.scrollViews["library.pages"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), app.debugDescription)
        // Start outside the inset row's swipe actions. A rightward page drag
        // begins well inside the viewport, away from the navigation edge.
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.97 : 0.25, dy: 0.7))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.95, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    func testSwipingAndTappingKeepPageSelectionAndToolbarInSync() throws {
        let app = launch()
        try open("bookmarks", app: app)
        XCTAssertTrue(app.buttons["favorites.manage"].exists)
        XCTAssertFalse(app.buttons["files.import"].exists)
        for section in sections.dropFirst() {
            page(left: true, app: app)
            assertSelected(section, app: app)
        }
        XCTAssertTrue(app.buttons["files.import"].exists)
        XCTAssertFalse(app.buttons["favorites.manage"].exists)
        for section in sections.dropLast().reversed() {
            page(left: false, app: app)
            assertSelected(section, app: app)
        }
        app.buttons["library.section.files"].tap()
        assertSelected("files", app: app)
        XCTAssertTrue(app.buttons["files.viewMode"].exists)
        app.buttons["library.section.history"].tap()
        assertSelected("history", app: app)
        XCTAssertFalse(app.buttons["files.viewMode"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Library after swipes and tab taps"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLeftEdgeExitsEverySectionAndShortEdgeDragCancels() throws {
        let app = launch()
        for section in sections {
            try open(section, app: app)
            let y = app.frame.height * 0.55
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: y))
            if section == "history" {
                let cancel = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: y))
                start.press(forDuration: 0.05, thenDragTo: cancel, withVelocity: .slow, thenHoldForDuration: 0.3)
                assertSelected(section, app: app)
            }
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            XCTAssertTrue(app.buttons["library.section." + section].waitForNonExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5), app.debugDescription)
        }
    }

    func testBookmarkFolderStaysOpenAcrossPagesAndRowsKeepSwipeActions() throws {
        let app = launch()
        try open("bookmarks", app: app)
        let name = "Paging QA " + UUID().uuidString.prefix(6)
        app.buttons["favorites.manage"].tap()
        app.buttons["New Folder"].firstMatch.tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
        input.typeText(name)
        app.alerts.buttons["Done"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        folder.tap()
        XCTAssertTrue(app.buttons["favorites.parent"].waitForExistence(timeout: 5), app.debugDescription)
        page(left: true, app: app)
        assertSelected("history", app: app)
        page(left: false, app: app)
        assertSelected("bookmarks", app: app)
        XCTAssertTrue(app.buttons["favorites.parent"].exists, "Swapping pages must preserve the open bookmark folder")
        app.buttons["favorites.parent"].tap()
        folder.swipeLeft()
        assertSelected("bookmarks", app: app)
        app.buttons["Delete"].firstMatch.tap()
        app.alerts.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 5), app.debugDescription)
    }
}
