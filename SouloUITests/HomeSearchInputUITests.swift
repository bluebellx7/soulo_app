import XCTest

/// Tap the system Pinyin keys and its candidate bar; typeText("你好") would
/// bypass composition and cannot catch the feedback's first-letter problem.
final class HomeSearchInputUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-app_language", "zh-Hans", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn",
            "-icloud_sync_enabled", "NO", "-last_selected_region", "china",
            "-last_selected_group_id", "", "-show_top_search_bar", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
    }

    override func tearDownWithError() throws {
        let globe = keyboardSwitcher
        if app.state == .runningForeground && globe.exists {
            globe.press(forDuration: 1)
            let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "English", "英语")
            let button = app.buttons.matching(predicate).firstMatch
            let text = app.staticTexts.matching(predicate).firstMatch
            if button.exists { button.tap() }
            else if text.exists { text.tap() }
        }
        app.terminate()
    }

    func testSystemPinyinCandidateSelectionClearAndSearchKeepWholeWords() throws {
        app.launch()
        let field = app.textFields["search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), app.debugDescription)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        selectSystemPinyinKeyboard()
        try enterPinyin("nihao", candidate: "你好", field: field)
        XCTAssertEqual(field.value as? String, "你好")
        app.buttons["search.clear"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertNotEqual(field.value as? String, "你好")
        try enterPinyin("zhongwen", candidate: "中文", field: field)
        XCTAssertEqual(field.value as? String, "中文")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "system-pinyin-committed-whole-word"; before.lifetime = .keepAlways; add(before)
        let submit = app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["搜索", "Search", "search"])).firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5), app.debugDescription)
        submit.tap()
        let address = app.buttons["编辑地址或搜索"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 30), app.debugDescription)
        address.tap()
        let query = app.textFields["addressEditor.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(query.value as? String, "中文", "The complete committed word must reach browser search")
    }

    private func enterPinyin(_ syllables: String, candidate: String, field: XCUIElement) throws {
        for letter in syllables {
            let key = app.keys[String(letter)].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 5), app.debugDescription)
            key.tap()
        }
        let exact = NSPredicate(format: "label == %@", candidate)
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        let matches = app.buttons.matching(exact).allElementsBoundByIndex
            + app.staticTexts.matching(exact).allElementsBoundByIndex
        guard let choice = matches.first(where: { $0.isHittable && $0.frame.midY >= keyboardTop - 90 }) else {
            print("PINYIN_KEYBOARD_TREE\n\(app.debugDescription)")
            XCTFail("The system Pinyin candidate must be available: \(candidate)")
            return
        }
        let composing = XCTAttachment(screenshot: app.screenshot())
        composing.name = "system-pinyin-composing-\(syllables)"; composing.lifetime = .keepAlways; add(composing)
        choice.tap()
        XCTAssertEqual(field.value as? String, candidate)
    }

    private func selectSystemPinyinKeyboard() {
        let globe = keyboardSwitcher
        XCTAssertTrue(globe.waitForExistence(timeout: 5), app.debugDescription)
        globe.press(forDuration: 1)
        let predicate = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "拼音", "Pinyin")
        let button = app.buttons.matching(predicate).firstMatch
        let text = app.staticTexts.matching(predicate).firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() }
        else {
            XCTAssertTrue(text.exists, app.debugDescription)
            text.tap()
        }
    }

    private var keyboardSwitcher: XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "label IN %@ OR identifier IN %@", ["Next keyboard", "下一键盘", "下一个键盘"], ["nextKeyboard", "Next keyboard"])).firstMatch
    }
}
