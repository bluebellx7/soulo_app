import XCTest
final class ManualAdPickerTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    func shot(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    var markCount = 0
    func mark() {
        markCount += 1
        app.buttons["browser.siteInformation"].tap()
        if markCount == 3 { app.buttons["site.ad-block-details"].tap() }
        let button = markCount == 3 ? app.buttons["标记广告"].firstMatch : app.buttons["browser.markAdvertisement"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
        XCTAssertTrue(app.staticTexts["点选要隐藏的区域，可滚动寻找。"].waitForExistence(timeout: 5), app.debugDescription)
    }
    func testSiteControlsAndDetails() {
        continueAfterFailure = false
        app.launchArguments = ["-app_language", "zh-Hans", "-ad_block_enabled", "YES"]
        app.launch()
        openFixture()
        app.buttons["browser.siteInformation"].tap()
        let ad = app.buttons["site.ad-block-toggle"]
        let tracking = app.buttons["site.tracking-toggle"]
        XCTAssertTrue(ad.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(ad.frame.height, 48)
        XCTAssertLessThanOrEqual(tracking.frame.height, 48)
        shot("site-controls-compact")
        let originalAdState = ad.isSelected
        ad.tap()
        XCTAssertNotEqual(ad.isSelected, originalAdState)
        XCTAssertFalse(app.buttons["browser.markAdvertisement"].isEnabled)
        ad.tap()
        XCTAssertEqual(ad.isSelected, originalAdState)
        let originalTrackingState = tracking.isSelected
        tracking.tap()
        XCTAssertNotEqual(tracking.isSelected, originalTrackingState)
        tracking.tap()
        XCTAssertEqual(tracking.isSelected, originalTrackingState)
        app.buttons["site.protection-details"].tap()
        XCTAssertTrue(app.staticTexts["站点保护"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        shot("site-protection-details")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["browser.siteInformation"].tap()
        app.buttons["site.ad-block-details"].tap()
        XCTAssertTrue(app.buttons["标记广告"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        shot("site-ad-block-details")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["browser.siteInformation"].tap()
        app.buttons["site.privacy-settings"].tap()
        XCTAssertTrue(app.navigationBars["隐私设置"].waitForExistence(timeout: 5), app.debugDescription)
        shot("privacy-settings-from-site")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["更多"].firstMatch.tap()
        app.buttons["网页工具"].firstMatch.tap()
        XCTAssertTrue(app.buttons["browser.ad-block-management"].exists)
        XCTAssertFalse(app.buttons["browser.markAdvertisement"].exists)
        XCTAssertFalse(app.buttons["站点保护"].exists)
    }

    func testMarkPreviewCancelPersistAndRestore() {
        continueAfterFailure = false
        app.launchArguments = ["-app_language", "zh-Hans", "-ad_block_enabled", "YES"]
        app.launch()
        openFixture()
        let promotion = app.webViews.links["示例推广区域"].firstMatch
        if !promotion.exists { restoreRules() }
        XCTAssertTrue(promotion.waitForExistence(timeout:5), app.debugDescription)
        mark()
        if markCount == 1 {
            let web = app.webViews.firstMatch
            web.swipeUp()
            let bottom = app.webViews.staticTexts["页面底部"].firstMatch
            XCTAssertTrue(bottom.isHittable, app.debugDescription)
            web.swipeDown()
        }
        promotion.coordinate(withNormalizedOffset: CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["扩大范围"].tap()
        shot("manual-ad-selected")
        app.buttons["预览"].tap()
        XCTAssertTrue(promotion.waitForNonExistence(timeout: 5))
        shot("manual-ad-preview")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(promotion.waitForExistence(timeout: 5))
        mark()
        promotion.coordinate(withNormalizedOffset: CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5))
        app.buttons["扩大范围"].tap()
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(promotion.waitForNonExistence(timeout: 5))
        shot("manual-ad-saved")
        app.buttons["恢复"].tap()
        XCTAssertTrue(promotion.waitForExistence(timeout: 5))
        shot("manual-ad-restored")
        mark()
        promotion.coordinate(withNormalizedOffset: CGVector(dx:0.5,dy:0.5)).tap()
        app.buttons["扩大范围"].tap()
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout:5))
        app.buttons["完成"].firstMatch.tap()
        app.buttons["browser.siteInformation"].tap()
        XCTAssertEqual(app.buttons["browser.markAdvertisement"].value as? String, "1")
        shot("site-marked-ad-count")
        // Optional restart stress pass. Some simulator runs lose XCTest's
        // animation-completion notifications after terminating and relaunching.
        if ProcessInfo.processInfo.environment["SOULO_QA_RELAUNCH"] == "1" {
            app.terminate(); app.launch()
            openFixture()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:10))
            XCTAssertTrue(app.webViews.staticTexts["正常文章内容"].waitForExistence(timeout:10))
            XCTAssertFalse(promotion.exists)
        }
        restoreRules()
        XCTAssertTrue(promotion.waitForExistence(timeout:5),app.debugDescription)
    }
    func openFixture() {
        app.open(URL(string: "soulo://search")!)
        let field = app.textFields.firstMatch
        if !field.waitForExistence(timeout: 2) {
            app.buttons["首页"].firstMatch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 8),app.debugDescription)
        field.tap(); field.typeText("http://127.0.0.1:8898/index.html\n")
        XCTAssertTrue(app.webViews.staticTexts["正常文章内容"].waitForExistence(timeout:10),app.debugDescription)
    }
    func restoreRules() {
        if !app.buttons["site.ad-block-details"].exists { app.buttons["browser.siteInformation"].tap() }
        app.buttons["site.ad-block-details"].tap()
        let rules = app.buttons["adBlock.manualRules"]
        if !rules.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(rules.waitForExistence(timeout:5),app.debugDescription)
        rules.tap()
        shot("manual-ad-rules")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'manualAds.rule.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["标记详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["区域标识"].exists)
        shot("manual-ad-rule-details")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.buttons["恢复"].firstMatch.waitForExistence(timeout:5))
        app.buttons["恢复"].firstMatch.tap()
        XCTAssertTrue(app.buttons["manualAds.undo"].waitForExistence(timeout: 5))
        shot("manual-ad-restore-feedback")
        app.buttons["manualAds.undo"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["恢复"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].firstMatch.tap()
    }
}
