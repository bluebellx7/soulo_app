import XCTest

final class URLSchemeUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func launch() {
        continueAfterFailure = false
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", "light"]
        app.launch()
    }
    func open(_ value: String) { app.open(URL(string: value)!) }
    func selected(_ section: String) {
        let tab = app.buttons["library.section." + section]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: tab)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
    func testColdLaunchAndLibraryRoutes() {
        launch(); app.terminate()
        open("soulo://Files"); selected("files")
        for section in ["bookmarks", "history", "downloads", "files"] {
            open("soulo://" + section); selected(section)
        }
        open("soulo://Books"); selected("files")
        shot("scheme-files-cold-and-warm")
        open("soulo://Search")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        shot("scheme-search-focus")
    }
    func testGuideAndScanFromSettings() {
        launch(); open("soulo://")
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 8))
        app.buttons["home.menu"].tap(); app.buttons["设置"].tap()
        let guide = app.buttons["settings.url-schemes"]
        for _ in 0..<10 {
            if guide.exists && guide.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(guide.isHittable, app.debugDescription)
        shot("scheme-settings-about-entry")
        guide.tap()
        XCTAssertTrue(app.navigationBars["URL Scheme 使用说明"].waitForExistence(timeout: 5))
        let copy = app.buttons["scheme.copy.scheme_home"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap(); XCTAssertTrue(copy.label.contains("已复制"))
        shot("scheme-guide-copy")
        open("soulo://QRCode")
        XCTAssertTrue(app.buttons["scanner.photos"].waitForExistence(timeout: 10), app.debugDescription)
        shot("scheme-scanner-from-settings")
        open("soulo://files"); selected("files")
    }
    func testWebPageAndBackgroundDownloadRoutes() {
        launch()
        open("soulo://open?url=http%3A%2F%2F127.0.0.1%3A8898%2Findex.html%3Fscheme%3Dopen")
        XCTAssertTrue(app.webViews.staticTexts["正常文章内容"].waitForExistence(timeout: 15), app.debugDescription)
        shot("scheme-open-webpage")
        open("soulo://search?q=http%3A%2F%2F127.0.0.1%3A8898%2Findex.html%3Fscheme%3Dsearch")
        XCTAssertTrue(app.webViews.staticTexts["正常文章内容"].waitForExistence(timeout: 15))
        open("soulo://download?url=http%3A%2F%2F127.0.0.1%3A8898%2FSoulo-Scheme-QA.txt")
        selected("downloads")
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Soulo-Scheme-QA' AND label CONTAINS '已完成'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription)
        shot("scheme-background-download-completed")
    }
}
