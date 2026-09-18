import XCTest
final class AdVideoTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    func shot(_ name: String) { Thread.sleep(forTimeInterval: 1); let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-app_language", "zh-Hans", "-ad_block_enabled", "YES"]
        app.launch()
    }
    func testHiddenBannerGuardPreservesScrollAndRealLinks() {
        app.open(URL(string:"soulo://open?url=http%3A%2F%2F127.0.0.1%3A8917%2Fhidden-hit-test.html")!)
        XCTAssertTrue(app.webViews.staticTexts["点击回归"].waitForExistence(timeout:15))
        Thread.sleep(forTimeInterval:2)
        app.webViews.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.89)).tap()
        Thread.sleep(forTimeInterval:2)
        XCTAssertTrue(app.webViews.staticTexts["点击回归"].exists)
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(app.webViews.staticTexts["滚动正常"].waitForExistence(timeout:5))
        let link = app.webViews.links["正常链接"]
        XCTAssertTrue(link.exists)
        link.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(app.webViews.staticTexts["正常链接已打开"].waitForExistence(timeout:10),app.debugDescription)
        shot("hidden-ad-guard-keeps-real-links")
    }
    func testAdManagementSections() {
        app.open(URL(string:"soulo://open?url=https%3A%2F%2Fwww.yinsuw.cc%2Fvoddetail%2Fdw977F%2F")!)
        XCTAssertTrue(app.webViews.staticTexts["八仙！"].firstMatch.waitForExistence(timeout:35))
        app.descendants(matching:.any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        XCTAssertTrue(app.buttons["adBlock.subscriptions"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["adBlock.manualRules"].exists)
        XCTAssertTrue(app.buttons["adBlock.builtInRules"].exists)
        XCTAssertFalse(app.staticTexts["EasyList"].exists)
        XCTAssertFalse(app.buttons["重置订阅"].exists)
        shot("ad-management-organized-portrait")
        app.buttons["adBlock.subscriptions"].tap()
        XCTAssertTrue(app.staticTexts["EasyList"].waitForExistence(timeout:5))
        shot("ad-management-subscriptions")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["adBlock.allowedSites"].tap()
        XCTAssertTrue(app.staticTexts["暂无允许的网站"].waitForExistence(timeout:5))
        shot("ad-management-allowed-sites")
        app.navigationBars.buttons.firstMatch.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval:2)
        shot("ad-management-organized-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["完成"].tap()
    }
    func testHiddenBottomBannerClicks() {
        for (address,title,name) in [("https://www.pianbs.com/html/226611.html","无邪","pianbs"),("https://www.yinsuw.cc/voddetail/dw977F/","八仙！","yinsuw")] {
            let encoded=address.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
            app.open(URL(string:"soulo://open?url="+encoded)!)
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout:35))
            Thread.sleep(forTimeInterval:10)
            XCTAssertEqual(app.state,.runningForeground)
            shot(name+"-before-bottom-taps")
            for x in [0.5,0.7,0.85] {
                app.webViews.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:x,dy:0.87)).tap()
                Thread.sleep(forTimeInterval:3)
                shot(name+"-after-bottom-tap-"+String(x))
                XCTAssertEqual(app.state,.runningForeground)
                XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.exists,app.debugDescription)
            }
            for round in 0..<2 {
                app.descendants(matching:.any)["browser.siteInformation"].firstMatch.tap()
                app.buttons["browser.markAdvertisement"].tap()
                XCTAssertTrue(app.descendants(matching:.any)["browser.manualAdPicker"].firstMatch.waitForExistence(timeout:5))
                Thread.sleep(forTimeInterval:3)
                shot(name+"-picker-keeps-filtering-"+String(round))
                app.buttons["取消"].tap()
            }
        }
    }
    func testAPianbsRemoveQAMark() {
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pianbs.com%2Fhtml%2F226611.html")!)
        XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35))
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        Thread.sleep(forTimeInterval: 1)
        let manual = app.buttons["adBlock.manualRules"]
        for _ in 0..<10 {
            if manual.exists && manual.frame.midY > 160 && manual.frame.midY < app.frame.height-120 { break }
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55))
            let delta:CGFloat=manual.exists && manual.frame.midY<160 ? 160 : -160
            start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:0,dy:delta)))
        }
        manual.tap()
        let restore = app.buttons["manualAds.restoreHost.www.pianbs.com"]
        if restore.waitForExistence(timeout: 3) { restore.tap() }
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
    }
    func testNativePickerThroughHostilePageOverlay() {
        app.open(URL(string: "soulo://open?url=http%3A%2F%2F127.0.0.1%3A8917%2Fhostile-picker.html")!)
        XCTAssertTrue(app.webViews.staticTexts["正常页面与透明点击层"].waitForExistence(timeout: 15))
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser.manualAdPicker"].firstMatch.waitForExistence(timeout: 5))
        app.webViews.firstMatch.swipeUp()
        XCTAssertTrue(app.webViews.staticTexts["已滚动"].waitForExistence(timeout: 5), "Native picking must preserve page scrolling")
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["扩大范围"].isEnabled)
        XCTAssertTrue(app.webViews.staticTexts["正常页面与透明点击层"].exists)
        shot("native-picker-hostile-overlay-selected")
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
        shot("native-picker-hostile-overlay-saved")
        app.buttons["恢复"].tap()
    }
    private func setMosaicForQA(_ enabled: Bool) {
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        let entry = app.buttons["adBlock.builtInRules"]
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<10 {
            if entry.exists && entry.frame.midY > 160 && entry.frame.midY < app.frame.height - 120 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let direction: CGFloat = entry.exists && entry.frame.midY < 160 ? 160 : -160
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: direction)))
        }
        entry.tap()
        let field = app.searchFields.firstMatch
        if !field.isHittable { app.swipeDown() }
        field.tap(); field.typeText("底部拼图")
        app.buttons["builtInRule.tiled-bottom-banner"].tap()
        let toggle = app.switches["builtInRule.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        if toggle.value as? String != (enabled ? "1" : "0") { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        app.buttons["builtInRule.save"].tap()
        XCTAssertTrue(app.buttons["builtInRule.tiled-bottom-banner"].waitForExistence(timeout: 5))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.87, dy: 0.94)).tap() }
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
    }
    private func setImageBannerForQA(_ enabled: Bool) {
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        let entry = app.buttons["adBlock.builtInRules"]
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<10 {
            if entry.exists && entry.frame.midY > 160 && entry.frame.midY < app.frame.height - 120 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let direction: CGFloat = entry.exists && entry.frame.midY < 160 ? 160 : -160
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: direction)))
        }
        entry.tap()
        let field = app.searchFields.firstMatch
        if !field.isHittable { app.swipeDown() }
        field.tap(); field.typeText("data-soulo-image-banner")
        app.buttons["builtInRule.paired-image-banner"].tap()
        let toggle = app.switches["builtInRule.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        if toggle.value as? String != (enabled ? "1" : "0") { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        app.buttons["builtInRule.save"].tap()
        XCTAssertTrue(app.buttons["builtInRule.paired-image-banner"].waitForExistence(timeout: 5))
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.87, dy: 0.94)).tap() }
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
    }
    func testYinsuwManualPickerWithAutomaticRuleDisabled() {
        let url = URL(string: "soulo://open?url=https%3A%2F%2Fwww.yinsuw.cc%2Fvoddetail%2Fdw977F%2F")!
        app.open(url)
        XCTAssertTrue(app.webViews.staticTexts["八仙！"].firstMatch.waitForExistence(timeout: 35))
        setImageBannerForQA(false)
        app.open(url)
        XCTAssertTrue(app.webViews.staticTexts["八仙！"].firstMatch.waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 10)
        shot("yinsuw-default-auto-filtered")
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser.manualAdPicker"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 5)
        shot("yinsuw-manual-filter-disabled-marking-visible")
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 2)
        shot("yinsuw-manual-filter-disabled-marking-selected")
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
        shot("yinsuw-manual-filter-disabled-marking-saved")
        app.buttons["完成"].tap()
        setImageBannerForQA(false)
        app.terminate(); app.launch()
        app.open(url)
        XCTAssertTrue(app.webViews.staticTexts["八仙！"].firstMatch.waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 8)
        shot("yinsuw-manual-filter-disabled-marking-reopened")
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        let manual = app.buttons["adBlock.manualRules"]
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<10 {
            if manual.exists && manual.frame.midY > 160 && manual.frame.midY < app.frame.height-120 { break }
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55))
            let delta:CGFloat=manual.exists && manual.frame.midY<160 ? 160 : -160
            start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:0,dy:delta)))
        }
        manual.tap()
        XCTAssertTrue(app.staticTexts["[data-soulo-image-banner=\"s8d87dabb3fb\"]"].waitForExistence(timeout: 5), app.debugDescription)
        shot("yinsuw-manual-filter-disabled-marking-rule")
        app.buttons["manualAds.restoreHost.www.yinsuw.cc"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        setImageBannerForQA(true)
        app.open(url)
        Thread.sleep(forTimeInterval: 8)
        shot("yinsuw-final-auto-filtered")
    }
    func testPianbsManualPickerWithAutomaticRuleDisabled() {
        let url = URL(string: "soulo://open?url=https%3A%2F%2Fwww.pianbs.com%2Fhtml%2F226611.html")!
        app.open(url)
        XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35))
        setMosaicForQA(false)
        app.open(url)
        XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35))
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser.manualAdPicker"].firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 5)
        shot("pianbs-manual-filter-disabled-marking-visible")
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5), app.debugDescription)
        Thread.sleep(forTimeInterval: 2)
        shot("pianbs-manual-filter-disabled-marking-selected")
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
        shot("pianbs-manual-filter-disabled-marking-saved")
        app.buttons["完成"].tap()
        app.open(url)
        XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 8)
        shot("pianbs-manual-filter-disabled-marking-reopened")
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        let manual = app.buttons["adBlock.manualRules"]
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<10 {
            if manual.exists && manual.frame.midY > 160 && manual.frame.midY < app.frame.height-120 { break }
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55))
            let delta:CGFloat=manual.exists && manual.frame.midY<160 ? 160 : -160
            start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:0,dy:delta)))
        }
        manual.tap()
        XCTAssertTrue(app.staticTexts["[data-soulo-tiled-banner=\"bottom\"]"].waitForExistence(timeout: 5), app.debugDescription)
        shot("pianbs-manual-filter-disabled-marking-rule")
        app.buttons["manualAds.restoreHost.www.pianbs.com"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        setMosaicForQA(true)
        app.open(url)
    }
    func testPianbsBottomPickerAndSavedRule() {
        testAPianbsRemoveQAMark()
        setMosaicForQA(false)
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pianbs.com%2Fhtml%2F226611.html")!)
        XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 10)
        shot("pianbs-bottom-control-visible")
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        let panel = app.descendants(matching: .any)["browser.manualAdPicker"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(panel.frame.minY, app.frame.height / 2, "Marking controls must stay at the bottom")
        shot("pianbs-bottom-picker-open")
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.firstMatch.buttons.element(boundBy: 1).isSelected)
        shot("pianbs-bottom-picker-selected")
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
        shot("pianbs-bottom-picker-saved")
        app.buttons["完成"].tap()
        app.terminate(); app.launch()
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pianbs.com%2Fhtml%2F226611.html")!)
        XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35))
        Thread.sleep(forTimeInterval: 8)
        shot("pianbs-bottom-saved-relaunch")
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["site.ad-block-details"].tap()
        let manual = app.buttons["adBlock.manualRules"]
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<10 {
            if manual.exists && manual.frame.midY > 160 && manual.frame.midY < app.frame.height-120 { break }
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55))
            let delta:CGFloat=manual.exists && manual.frame.midY<160 ? 160 : -160
            start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:0,dy:delta)))
        }
        manual.tap()
        XCTAssertTrue(app.buttons["manualAds.restoreHost.www.pianbs.com"].waitForExistence(timeout: 5), app.debugDescription)
        shot("pianbs-bottom-rule-persisted")
        app.buttons["manualAds.restoreHost.www.pianbs.com"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
        setMosaicForQA(true)
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pianbs.com%2Fhtml%2F226611.html")!)
        Thread.sleep(forTimeInterval: 10)
        shot("pianbs-conservative-auto-filtered")
    }
    func testPianbsFilteringMarkingAndBuiltinControls() {
        let url = URL(string: "soulo://open?url=https%3A%2F%2Fwww.pianbs.com%2Fhtml%2F226611.html")!
        func openPage() {
            app.open(url)
            XCTAssertTrue(app.webViews.staticTexts["无邪"].firstMatch.waitForExistence(timeout: 35), app.debugDescription)
            Thread.sleep(forTimeInterval: 15)
        }
        func openBuiltins() {
            app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
            app.buttons["site.ad-block-details"].tap()
            let entry = app.buttons["adBlock.builtInRules"]
            Thread.sleep(forTimeInterval: 1)
            for _ in 0..<10 {
                if entry.exists && entry.frame.midY > 160 && entry.frame.midY < app.frame.height - 120 { break }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                let direction: CGFloat = entry.exists && entry.frame.midY < 160 ? 160 : -160
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: direction)))
            }
            XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
            entry.tap()
            XCTAssertTrue(app.navigationBars["内置规则"].waitForExistence(timeout: 5), app.debugDescription)
        }
        func search(_ query: String) {
            let field = app.searchFields.firstMatch
            if !field.isHittable { app.swipeDown() }
            field.tap(); field.typeText(query)
        }
        func toggleMosaic(_ enabled: Bool) {
            openBuiltins(); search("底部拼图")
            app.buttons["builtInRule.tiled-bottom-banner"].tap()
            let toggle = app.switches["builtInRule.enabled"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
            Thread.sleep(forTimeInterval: 1)
            if toggle.value as? String != (enabled ? "1" : "0") { toggle.switches.firstMatch.tap() }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
            shot(enabled ? "builtin-mosaic-enabled" : "builtin-mosaic-disabled")
            app.buttons["builtInRule.save"].tap()
            XCTAssertTrue(app.buttons["builtInRule.tiled-bottom-banner"].waitForExistence(timeout: 5), app.debugDescription)
            let cancelSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            if cancelSearch.exists { cancelSearch.tap() }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.87, dy: 0.94)).tap() }
            XCTAssertTrue(app.navigationBars["内置规则"].waitForExistence(timeout: 5), app.debugDescription)
            app.navigationBars.buttons.firstMatch.tap()
            app.buttons["完成"].tap()
            Thread.sleep(forTimeInterval: 15)
        }
        openPage(); toggleMosaic(true); shot("pianbs-auto-filtered")
        shot("pianbs-settled-filtered")
        toggleMosaic(false)
        openPage()
        shot("pianbs-mosaic-control-visible")
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        XCTAssertTrue(app.staticTexts["点选要隐藏的区域，可滚动寻找。"].waitForExistence(timeout: 5))
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.segmentedControls.firstMatch.buttons.element(boundBy: 1).isSelected)
        XCTAssertFalse(app.buttons["扩大范围"].isEnabled, "The target must be a complete tiled banner, not ordinary content")
        shot("pianbs-mosaic-selected")
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
        shot("pianbs-manual-hidden")
        app.buttons["完成"].tap()
        openPage(); shot("pianbs-manual-hidden-reopened")
        app.terminate(); app.launch(); openPage(); shot("pianbs-manual-hidden-relaunched")
        toggleMosaic(true)
        openBuiltins(); search("pbpbw")
        XCTAssertTrue(app.buttons["builtInRule.pbpbw:site-render"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["builtInRule.pbpbw:site-config"].exists)
        shot("builtin-pbpbw-rules")
        app.buttons["builtInRule.pbpbw:site-render"].tap()
        XCTAssertTrue(app.textViews["builtInRule.pattern"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["builtInRule.domains"].value as? String, "pbpbw.com")
        shot("builtin-rule-editor")
        app.navigationBars.buttons.firstMatch.tap()
        let cancelSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        if cancelSearch.exists { cancelSearch.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.87, dy: 0.94)).tap() }
        app.navigationBars.buttons.firstMatch.tap()
        let manual = app.buttons["adBlock.manualRules"]
        if !manual.isHittable { app.swipeDown() }
        manual.tap()
        let restore = app.buttons["manualAds.restoreHost.www.pianbs.com"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5), app.debugDescription)
        restore.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["完成"].tap()
    }
    func testLivePBPBWFilteringComparison() {
        let url = URL(string: "soulo://open?url=https%3A%2F%2Fwww.pbpbw.com%2Fhtml%2F235867.html")!
        for enabled in [false, true] {
            app.terminate()
            app.launchArguments = ["-app_language", "zh-Hans", "-ad_block_enabled", enabled ? "YES" : "NO"]
            app.launch(); app.open(url)
            XCTAssertTrue(app.webViews.staticTexts["诛仙最终季"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
            let settled = expectation(description: "Wait for real mobile ad loaders")
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { settled.fulfill() }
            waitForExpectations(timeout: 23)
            shot(enabled ? "pbpbw-filter-on" : "pbpbw-filter-off")
        }
    }
    func testLivePBPBW() {
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pbpbw.com%2Fhtml%2F235867.html")!)
        let title = app.webViews.staticTexts["诛仙最终季"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), app.debugDescription)
        shot("pbpbw-top-initial")
        let quiet = expectation(description: "Allow delayed ads to load")
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { quiet.fulfill() }
        waitForExpectations(timeout: 15)
        shot("pbpbw-top-delayed")
        print("PBPBW_TOP", app.debugDescription)
        app.webViews.firstMatch.swipeUp()
        app.webViews.firstMatch.swipeUp()
        shot("pbpbw-bottom")
        print("PBPBW_BOTTOM", app.debugDescription)
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pbpbw.com%2Fhtml%2F235867.html")!)
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        shot("pbpbw-reloaded")
    }
    func testMarkBottomTilesDefaultsToSiteAndRestore() {
        app.open(URL(string: "soulo://open?url=http%3A%2F%2F127.0.0.1%3A8917%2Findex.html%3Fqa%3Dhd")!)
        XCTAssertTrue(app.webViews.staticTexts["正常页面内容"].waitForExistence(timeout: 15), app.debugDescription)
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        XCTAssertTrue(app.staticTexts["点选要隐藏的区域，可滚动寻找。"].waitForExistence(timeout: 5), app.debugDescription)
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)).tap()
        XCTAssertTrue(app.buttons["隐藏并记住"].waitForExistence(timeout: 5), app.debugDescription)
        let segmented = app.segmentedControls.firstMatch
        print("SCOPE", segmented.debugDescription)
        XCTAssertTrue(segmented.buttons.element(boundBy: 1).isSelected)
        shot("bottom-tiles-selected")
        app.buttons["隐藏并记住"].tap()
        XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5), app.debugDescription)
        shot("bottom-tiles-hidden")
        app.buttons["恢复"].tap()
        shot("bottom-tiles-restored")
    }
    func testContinuousMarkingPersistsAfterRelaunch() {
        let run = UUID().uuidString
        func url(_ path: String) -> URL {
            var components = URLComponents(string: "soulo://open")!
            components.queryItems = [URLQueryItem(name: "url", value: "http://127.0.0.1:8917/\(path)?run=\(run)")]
            return components.url!
        }
        func assertHidden() {
            XCTAssertTrue(app.webViews.staticTexts["页面加载完成"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertFalse(app.webViews.staticTexts["第一推广区域"].exists)
            XCTAssertFalse(app.webViews.staticTexts["第二推广区域"].exists)
            XCTAssertTrue(app.webViews.staticTexts["正常内容始终保留"].exists)
        }
        app.open(url("continuous.html"))
        XCTAssertTrue(app.webViews.staticTexts["页面加载完成"].waitForExistence(timeout: 15))
        app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
        app.buttons["browser.markAdvertisement"].tap()
        for (index, title) in ["第一推广区域", "第二推广区域"].enumerated() {
            XCTAssertTrue(app.staticTexts["点选要隐藏的区域，可滚动寻找。"].waitForExistence(timeout: 5))
            app.webViews.staticTexts[title].tap()
            let save = app.buttons["隐藏并记住"]
            XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.segmentedControls.firstMatch.buttons.element(boundBy: 1).isSelected)
            save.tap()
            XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["browser.manualAdContinue"].isHittable)
            if index == 0 {
                shot("manual-ad-continue")
                app.buttons["browser.manualAdContinue"].tap()
                XCTAssertFalse(app.webViews.staticTexts[title].exists)
            }
        }
        app.buttons["完成"].tap()
        assertHidden()
        app.open(url("continuous.html"))
        assertHidden()
        app.terminate()
        app.launch()
        app.open(url("continuous-next.html"))
        assertHidden()
        shot("manual-ads-persisted")
    }
    func testDomainGroupingAndRestore() {
        let run = UUID().uuidString
        for host in ["127.0.0.1", "localhost"] {
            var components = URLComponents(string: "soulo://open")!
            components.queryItems = [URLQueryItem(name: "url", value: "http://\(host):8917/continuous.html?run=\(run)")]
            app.open(components.url!)
            XCTAssertTrue(app.webViews.staticTexts["页面加载完成"].waitForExistence(timeout: 15))
            app.buttons["browser.siteInformation"].tap()
            app.buttons["browser.markAdvertisement"].tap()
            for (index, title) in ["第一推广区域", "第二推广区域"].enumerated() {
                XCTAssertTrue(app.staticTexts["点选要隐藏的区域，可滚动寻找。"].waitForExistence(timeout: 5))
                app.webViews.staticTexts[title].tap()
                app.buttons["隐藏并记住"].tap()
                XCTAssertTrue(app.staticTexts["已隐藏并保存"].waitForExistence(timeout: 5))
                if index == 0 { app.buttons["browser.manualAdContinue"].tap() }
            }
            app.buttons["完成"].tap()
        }
        app.buttons["browser.siteInformation"].tap()
        app.buttons["site.ad-block-details"].tap()
        let rules = app.buttons["adBlock.manualRules"]
        if !rules.isHittable { app.swipeUp() }
        XCTAssertTrue(rules.waitForExistence(timeout: 5), app.debugDescription)
        rules.tap()
        let restoreCurrent = app.buttons["manualAds.restoreHost.localhost"]
        XCTAssertTrue(restoreCurrent.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["manualAds.restoreHost.127.0.0.1"].exists)
        let current = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "localhost")).firstMatch
        current.tap()
        XCTAssertFalse(restoreCurrent.exists)
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "127.0.0.1")).firstMatch
        other.tap()
        XCTAssertTrue(app.buttons["manualAds.restoreHost.127.0.0.1"].waitForExistence(timeout: 5))
        other.tap()
        current.tap()
        shot("manual-ad-domains")
        restoreCurrent.tap()
        XCTAssertFalse(app.buttons["manualAds.restoreHost.localhost"].exists)
        XCTAssertTrue(app.buttons["manualAds.undo"].waitForExistence(timeout: 5))
        XCTAssertTrue(other.exists)
        app.buttons["manualAds.undo"].tap()
        XCTAssertTrue(restoreCurrent.waitForExistence(timeout: 5))
        shot("manual-ad-domain-undo")
        print("RULE_DOMAINS", app.debugDescription)
    }
    func testAutomaticNavigationToggleAndTrustedClicks() {
        func openPage(auto: Bool = false) {
            app.open(URL(string: "soulo://open?url=http%3A%2F%2F127.0.0.1%3A8917%2Fnavigation.html" + (auto ? "%3Fauto" : ""))!)
        }
        func openSettings() {
            app.descendants(matching: .any)["browser.siteInformation"].firstMatch.tap()
            app.buttons["site.ad-block-details"].tap()
            XCTAssertTrue(app.switches["adBlock.allowAutomaticNavigation"].waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
        }
        openPage()
        XCTAssertTrue(app.webViews.staticTexts["跳转测试"].waitForExistence(timeout: 15))
        openSettings()
        let toggle = app.switches["adBlock.allowAutomaticNavigation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        if toggle.value as? String != "0" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "0")
        shot("automatic-navigation-explicit-off")
        app.buttons["完成"].tap()
        for title in ["手动链接", "脚本按钮", "提交表单", "新窗口链接", "新窗口按钮"] {
            openPage()
            XCTAssertTrue(app.webViews.staticTexts["跳转测试"].waitForExistence(timeout: 10))
            let target = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", title, XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.link.rawValue)).firstMatch
            target.tap()
            XCTAssertTrue(app.webViews.staticTexts["已到达目标页面"].waitForExistence(timeout: 5), "Failed trusted click: \(title)\n\(app.debugDescription)")
        }
        openPage(auto: true)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.webViews.staticTexts["跳转测试"].exists)
        XCTAssertFalse(app.webViews.staticTexts["已到达目标页面"].exists)
        openSettings()
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1", app.debugDescription)
        app.buttons["完成"].tap()
        openPage(auto: true)
        XCTAssertTrue(app.webViews.staticTexts["已到达目标页面"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        openPage()
        XCTAssertTrue(app.webViews.staticTexts["跳转测试"].waitForExistence(timeout: 10))
        openSettings()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["完成"].tap()
        openPage(auto: true)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.webViews.staticTexts["跳转测试"].exists)
        shot("automatic-navigation-blocked")
        openSettings()
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        shot("automatic-navigation-enabled")
        app.buttons["完成"].tap()
    }
    func testLivePBPBWPlayerFullscreen() {
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pbpbw.com%2Fplayer%2F235867-1-1.html")!)
        XCTAssertTrue(app.webViews.buttons["横屏播放"].firstMatch.waitForExistence(timeout: 35), app.debugDescription)
        shot("pbpbw-player-before-fullscreen")
        assertFullscreenAndRestore()
    }
    func testWebFullscreenLandscapeAndRestore() {
        app.open(URL(string: "soulo://open?url=http%3A%2F%2F127.0.0.1%3A8917%2Findex.html%3Fqa%3Dhd")!)
        XCTAssertTrue(app.webViews.staticTexts["正常页面内容"].waitForExistence(timeout: 15))
        assertFullscreenAndRestore()
    }
    func testEmbeddedPlayerFullscreenAndRestore() {
        app.open(URL(string: "soulo://open?url=http%3A%2F%2F127.0.0.1%3A8917%2Fframes.html%3Fqa%3D3")!)
        assertFullscreenAndRestore()
    }
    private func assertFullscreenAndRestore() {
        let full = app.webViews.buttons["横屏播放"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 10), app.debugDescription)
        let originalButtonFrame = full.frame
        full.tap()
        expectation(for: NSPredicate { _,_ in self.app.frame.width > self.app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        shot("web-fullscreen-landscape")
        XCTAssertTrue(app.frame.width > app.frame.height, app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "Close Button", ["完成", "Done", "关闭", "Close", "退出全屏", "Exit Full Screen"])).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        shot("fullscreen-player-controls")
        close.tap()
        expectation(for: NSPredicate { _,_ in self.app.frame.height > self.app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(full.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(full.frame.width, originalButtonFrame.width, accuracy: 2)
        XCTAssertEqual(full.frame.minX, originalButtonFrame.minX, accuracy: 2)
        shot("web-fullscreen-return")
    }
    func testNativeLandscapePreviewLayout() {
        app.open(URL(string: "soulo://files")!)
        let mode = app.buttons["files.selectionMode"]
        if mode.waitForExistence(timeout: 5), mode.label == "完成" { mode.tap() }
        let file = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "files.item.QA-Landscape.mp4")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["media.landscape"].waitForExistence(timeout: 8))
        shot("native-landscape-preview")
    }
    func testLandscapeHomeAndBrowserLayout() {
        app.open(URL(string: "soulo://home")!)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        shot("home-landscape")
        app.open(URL(string: "soulo://open?url=https%3A%2F%2Fwww.pbpbw.com%2Fhtml%2F235867.html")!)
        XCTAssertTrue(app.webViews.staticTexts["诛仙最终季"].firstMatch.waitForExistence(timeout: 30))
        shot("browser-landscape")
    }
    func testNativeLandscapeAndRestore() {
        app.open(URL(string:"soulo://files")!)
        let mode = app.buttons["files.selectionMode"]
        if mode.waitForExistence(timeout: 5), mode.label == "完成" { mode.tap() }
        let file = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "files.item.QA-Landscape.mp4")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
        let rotate = app.buttons["media.landscape"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 10), app.debugDescription)
        rotate.tap()
        XCTAssertTrue(app.buttons["media.rotate"].waitForExistence(timeout: 8), app.debugDescription)
        expectation(for: NSPredicate { _,_ in self.app.frame.width > self.app.frame.height }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        shot("native-landscape")
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(rotate.waitForExistence(timeout: 8))
        expectation(for: NSPredicate { _,_ in self.app.frame.height > self.app.frame.width }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        shot("native-portrait-restored")
    }
}
