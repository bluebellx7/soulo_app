import XCTest

final class SettingsCertificateUITests: XCTestCase {
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
    func settings() {
        launch(); open("soulo://home")
        app.buttons["home.menu"].stableTap(); app.buttons["设置"].stableTap()
    }
    func reveal(_ element: XCUIElement) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp(); Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    func testVersionLinksAndQuickActionOrder() {
        settings()
        let version = app.buttons["settings.version"]
        reveal(version); shot("settings-other-and-version")
        XCTAssertFalse(app.buttons["version.privacy"].exists)
        version.stableTap()
        for id in ["version.privacy", "version.licenses", "version.terms"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.images["version.logo"].exists)
        shot("version-legal-details")
        app.buttons["version.licenses"].stableTap()
        shot("version-open-source-licenses")
        app.navigationBars.buttons.firstMatch.stableTap()
        app.navigationBars.buttons.firstMatch.stableTap()
        let shortcuts = app.buttons["settings.quick-actions"]
        reveal(shortcuts); shortcuts.stableTap()
        XCTAssertTrue(app.navigationBars["长按快捷操作"].waitForExistence(timeout: 5))
        if app.buttons["还原"].isEnabled { app.buttons["还原"].stableTap() }
        shot("quick-actions-order-before")

        let handles = app.buttons.matching(NSPredicate(format: "label CONTAINS '重新排序' OR label CONTAINS 'Reorder'"))
        let allHandles = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 4"), object: handles)
        XCTAssertEqual(XCTWaiter.wait(for: [allHandles], timeout: 5), .completed, app.debugDescription)
        if handles.count >= 4 {
            handles.element(boundBy: 3).press(forDuration: 1, thenDragTo: handles.element(boundBy: 0))
            Thread.sleep(forTimeInterval: 1)
            shot("quick-actions-order-after")
        } else {
            XCTFail("No drag handles: " + app.debugDescription)
        }
        XCTAssertTrue(app.buttons["还原"].isEnabled)
        app.buttons["还原"].stableTap()
        XCTAssertFalse(app.buttons["还原"].isEnabled)
        let removeScan = app.buttons["quick-action.remove.com.dkluge.Soulo.quick-action.scan"]
        removeScan.stableTap()
        let addFiles = app.buttons["quick-action.add.com.dkluge.Soulo.quick-action.files"]
        reveal(addFiles); XCTAssertTrue(addFiles.isEnabled); addFiles.stableTap()
        shot("quick-actions-added-files")
        let selectedFiles = app.buttons["quick-action.remove.com.dkluge.Soulo.quick-action.files"]
        reveal(selectedFiles); XCTAssertTrue(selectedFiles.waitForExistence(timeout: 5), app.debugDescription)
        shot("quick-actions-custom-selection")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons.matching(NSPredicate(format: "label == 'Soulo'")).firstMatch
        for _ in 0..<5 {
            if icon.exists && icon.isHittable { break }
            springboard.swipeLeft(); Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(icon.isHittable, springboard.debugDescription)
        icon.press(forDuration: 1.2)
        XCTAssertTrue(springboard.buttons["文件"].waitForExistence(timeout: 8), springboard.debugDescription)
        let desktop = XCTAttachment(screenshot: springboard.screenshot()); desktop.name = "desktop-custom-quick-actions"; desktop.lifetime = .keepAlways; add(desktop)
        springboard.buttons["文件"].stableTap()
        selected("files")
        settings(); reveal(app.buttons["settings.quick-actions"])
        app.buttons["settings.quick-actions"].stableTap()
        app.buttons["还原"].stableTap()
    }
    func testDarkVersionAndQuickActions() {
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", "dark"]
        app.launch(); open("soulo://home")
        app.buttons["home.menu"].stableTap(); app.buttons["设置"].stableTap()
        reveal(app.buttons["settings.version"]); app.buttons["settings.version"].stableTap()
        XCTAssertTrue(app.images["version.logo"].exists)
        shot("version-logo-and-badges-dark")
        app.navigationBars.buttons.firstMatch.stableTap()
        reveal(app.buttons["settings.quick-actions"]); app.buttons["settings.quick-actions"].stableTap()
        shot("quick-actions-badges-dark")
    }
    func testLiveCertificateAndCopyAlignment() {
        launch(); open("soulo://open?url=https%3A%2F%2Fwww.apple.com%2Flibrary%2Ftest%2Fsuccess.html")
        XCTAssertTrue(app.webViews.staticTexts["Success"].waitForExistence(timeout: 90), app.debugDescription)
        app.buttons["browser.siteInformation"].stableTap()
        app.buttons["site.connection"].stableTap()
        XCTAssertTrue(app.buttons["site.copy-link"].waitForExistence(timeout: 5))
        shot("connection-url-copy-aligned")
        app.buttons["site.copy-link"].stableTap()
        XCTAssertTrue(app.buttons["site.copy-link"].label.contains("已复制"))
        app.buttons["site.certificate"].stableTap()
        XCTAssertTrue(app.staticTexts["颁发给"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["颁发者"].exists)
        XCTAssertTrue(app.staticTexts["到期时间"].exists)
        shot("live-https-certificate")
    }
}

private extension XCUIElement {
    func stableTap() {
        XCTAssertTrue(waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: self)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 0.6); tap(); Thread.sleep(forTimeInterval: 0.6)
    }
}
