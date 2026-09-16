import XCTest

final class FeedbackAndLibrarySmokeTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    func shot(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testFeedbackDiagnosticsAndLibraryNavigation() {
        continueAfterFailure = false
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", "light"]
        app.launch(); app.open(URL(string: "soulo://search")!)
        if !app.buttons["home.menu"].waitForExistence(timeout: 3) { app.buttons["首页"].firstMatch.tap() }
        app.buttons["home.menu"].tap(); app.buttons["设置"].tap()
        let feedback = app.buttons["发送反馈"].firstMatch
        for _ in 0..<8 {
            if feedback.exists && feedback.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(feedback.isHittable, app.debugDescription)
        feedback.tap()
        let content = app.textViews["feedback.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.tap(); content.typeText("界面回归测试，仅填写，不提交。")
        app.swipeUp()
        let include = app.switches["feedback.include-diagnostics"]
        for _ in 0..<5 {
            if include.exists && include.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(include.isHittable, app.debugDescription)
        let preview = app.buttons["feedback.diagnostics-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        XCTAssertTrue(app.staticTexts["设备型号"].waitForExistence(timeout: 5))
        shot("feedback-diagnostics-light")
        preview.tap()
        include.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        let submit = app.buttons["feedback.submit"]
        XCTAssertTrue(submit.exists && submit.isEnabled)
        shot("feedback-diagnostics-opt-out")
        app.buttons["取消"].firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
        app.open(URL(string: "soulo://files")!)
        XCTAssertTrue(app.buttons["files.viewMode"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["files.import"].exists)
        XCTAssertTrue(app.buttons["files.wifi"].exists)
        shot("files-library-light")
        app.buttons["files.viewMode"].tap(); shot("files-alternate-view-light")
        app.buttons["files.viewMode"].tap()
        for section in ["downloads", "history", "bookmarks", "files"] {
            let tab = app.buttons["library.section.\(section)"]
            XCTAssertTrue(tab.exists, app.debugDescription)
            tab.tap()
            XCTAssertTrue(app.navigationBars["资料库"].exists)
        }
    }
}
