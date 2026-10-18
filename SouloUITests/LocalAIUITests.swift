import XCTest
import UIKit

/// These tests use the real downloaded GGUF on the dedicated QA simulator.
final class LocalAIUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    private func launchApp(enabled: Bool, isPrivate: Bool = false, introductionSeen: Bool = true, toolbar: String? = "(home,back,tabs,more)", language: String = "en-US", extraArguments: [String] = []) {
        app.launchEnvironment["SOULO_LOCAL_AI_QA_METERED"] = nil
        let chinese = language.hasPrefix("zh")
        app.launchArguments = ["-app_language", language, "-AppleLanguages", chinese ? "(zh-Hans)" : "(en)", "-AppleLocale", chinese ? "zh_CN" : "en_US",
            "-soulo.localAI.enabled", enabled ? "YES" : "NO", "-is_incognito", isPrivate ? "YES" : "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-builtin_reader_enabled", "NO",
            "-soulo.localAI.introductionSeen", introductionSeen ? "YES" : "NO", "-ad_block_enabled", "NO",
            "-soulo.localAI.model", "light",
            "-privacy_https_upgrade_enabled", "NO"]
        if let toolbar { app.launchArguments += ["-browser_toolbar_actions", toolbar] }
        app.launchArguments += extraArguments

        app.launch()
    }
    private func launch(enabled: Bool, isPrivate: Bool = false) throws {
        launchApp(enabled: enabled, isPrivate: isPrivate)
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: "https://www.swift.org/documentation/")]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.staticTexts["Documentation"].firstMatch.waitForExistence(timeout: 45), app.debugDescription)
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        let assistant = app.buttons["browser.localAI"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(assistant.isHittable); assistant.tap()
        XCTAssertTrue(app.textFields["localAI.input"].waitForExistence(timeout: 10), app.debugDescription)
    }
    private func openHomeAssistant() {
        app.buttons["home.menu"].tap(); app.buttons["home.localAI"].tap()
    }
    private func assertFullPageChat() {
        let bar = app.navigationBars["Local AI"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(bar.frame.minY, app.frame.minY + 90, "Chat must use full-page navigation, not an inset sheet")
        XCTAssertFalse(app.buttons["Done"].exists, "A pushed chat uses the system Back button")
        XCTAssertTrue(app.textFields["localAI.input"].waitForExistence(timeout: 5), app.debugDescription)
    }
    private func returnFromChat() {
        app.navigationBars["Local AI"].firstMatch.buttons.element(boundBy: 0).tap()
    }
    func testHomeAndSettingsOpenIndependentChatPages() throws {
        launchApp(enabled: true)
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        app.buttons["home.menu"].tap(); app.buttons["home.localAI"].tap()
        assertFullPageChat()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-full-page-chat"; shot.lifetime = .keepAlways; add(shot)
        returnFromChat()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        app.buttons["settings.localAI"].tap()
        let open = app.buttons["localAI.open-chat"]
        for _ in 0..<4 { if open.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(open.isHittable, app.debugDescription); open.tap()
        assertFullPageChat(); returnFromChat()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
    }
    func testIntroductionIsASeparatePageAndStartsChat() throws {
        launchApp(enabled: true, introductionSeen: false)
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        app.buttons["home.menu"].tap(); app.buttons["home.localAI"].tap()
        let start = app.buttons["localAI.introduction.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Conversations with context"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-introduction"; shot.lifetime = .keepAlways; add(shot)
        start.tap(); assertFullPageChat()
    }
    func testChineseIntroductionAndRealModelBrowserAction() throws {
        launchApp(enabled: true, introductionSeen: false, language: "zh-Hans")
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        app.buttons["home.menu"].tap(); app.buttons["home.localAI"].tap()
        let start = app.buttons["localAI.introduction.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["一句话，操作浏览器"].exists)
        let intro = XCTAttachment(screenshot: app.screenshot()); intro.name = "local-ai-introduction-zh"; intro.lifetime = .keepAlways; add(intro)
        start.tap()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("把应用外观改成深色")
        app.buttons["localAI.send"].tap()
        let undo = app.buttons["localAI.undo-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 120), app.debugDescription)
        defer { if undo.exists && undo.isEnabled { undo.tap() } }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已设置：应用外观")).firstMatch.exists, app.debugDescription)
        let answer = XCTAttachment(screenshot: app.screenshot()); answer.name = "local-ai-browser-action-zh-dark"; answer.lifetime = .keepAlways; add(answer)
        undo.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已恢复：应用外观")).firstMatch.waitForExistence(timeout: 10))
    }
    func testReadingActionOpensOriginalReaderAndCanReturnToThePage() throws {
        try launch(enabled: false)
        assertFullPageChat()
        app.buttons["localAI.action.read"].tap()
        XCTAssertTrue(app.navigationBars["Reader"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }
    @MainActor func testCustomToolbarRemovesAdsInPlaceAndRestoresThem() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font:18px system-ui;padding:20px"><main><article><h1>Reading with Soulo</h1>
        <p>A calm morning is a good time to read. This article is useful content and must stay visible.</p></article></main>
        <aside class="advertisement" style="padding:20px;background:#fde9aa">Advertisement: Sponsored sale. Buy our subscription today.</aside>
        <form><label>Search notes<input type="text"></label><button>Search</button></form></body>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/ads.html": Data(html.utf8)])
        let root = try await server.start(); defer { server.stop() }
        launchApp(enabled: true, toolbar: nil)
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        let customization = app.buttons["settings.toolbar"]
        for _ in 0..<5 { if customization.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(customization.isHittable, app.debugDescription); customization.tap()
        app.buttons["toolbar.slot.1"].tap(); app.buttons["toolbar.action.removeAds"].tap()
        app.buttons["toolbar.slot.2"].tap(); app.buttons["toolbar.action.localAI"].tap()
        let toolbarShot = XCTAttachment(screenshot: app.screenshot()); toolbarShot.name = "local-ai-custom-toolbar"; toolbarShot.lifetime = .keepAlways; add(toolbarShot)
        app.buttons["toolbar.save"].tap(); app.alerts.buttons["Done"].tap()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [.init(name: "url", value: root.appendingPathComponent("ads.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let ad = app.webViews.staticTexts["Advertisement: Sponsored sale. Buy our subscription today."]
        XCTAssertTrue(ad.waitForExistence(timeout: 20), app.debugDescription)
        let remove = app.buttons["Remove ads"].firstMatch
        XCTAssertTrue(remove.isHittable, app.debugDescription); remove.tap()
        let undo = app.buttons["localAI.cleanup.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertFalse(ad.exists)
        XCTAssertTrue(app.webViews.staticTexts["Reading with Soulo"].exists)
        XCTAssertTrue(app.webViews.buttons["Search"].exists)
        XCTAssertFalse(app.textFields["localAI.input"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-toolbar-ads-removed"; shot.lifetime = .keepAlways; add(shot)
        undo.tap()
        XCTAssertTrue(ad.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["localAI.cleanup.close"].tap()
        app.buttons["Local AI"].firstMatch.tap(); assertFullPageChat()
        restoreDefaultToolbar()
    }
    private func restoreDefaultToolbar() {
        app.open(URL(string: "soulo://home")!)
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        let customization = app.buttons["settings.toolbar"]
        for _ in 0..<5 { if customization.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(customization.isHittable); customization.tap()
        app.buttons["toolbar.reset"].tap(); app.alerts.buttons["Restore Default Toolbar"].tap()
    }
    func testRestoreDefaultToolbarAndOriginalSearch() throws {
        launchApp(enabled: true, toolbar: nil)
        restoreDefaultToolbar()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [.init(name: "url", value: "https://www.swift.org/documentation/")]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.buttons["More"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["browser.toolbar.action.home"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["browser.toolbar.action.back"].exists)
        XCTAssertFalse(app.buttons["browser.toolbar.action.removeAds"].exists)
        XCTAssertFalse(app.buttons["browser.toolbar.action.localAI"].exists)
        XCTAssertTrue(app.staticTexts["Documentation"].firstMatch.waitForExistence(timeout: 45), app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "local-ai-default-toolbar"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testModelChoosesExactCountAndFilteredLinkToolsFromNaturalQuestions() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Agent live page</title>
        <body style="font:18px system-ui;padding:20px"><header>鸡蛋 鸡蛋</header><article><h1>Agent live page</h1><p>鸡蛋</p></article>
        <footer>鸡蛋 鸡蛋 鸡蛋 鸡蛋</footer><input value="鸡蛋"><div hidden>鸡蛋 鸡蛋 鸡蛋</div>
        <p><a href="https://weibo.com/first">First Weibo post</a></p>
        <div class="result" data-log='{"mu":"https://m.weibo.com/second"}'><a href="https://www.baidu.com/link?url=tracking">Second Weibo post</a></div>
        <p><a href="https://weibo.com.evil.example/spoof">Unrelated</a></p><a hidden href="https://weibo.com/hidden">Hidden</a></body>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/agent.html": Data(html.utf8)])
        let root = try await server.start(); defer { server.stop() }
        launchApp(enabled: true, language: "zh-Hans")
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [.init(name: "url", value: root.appendingPathComponent("agent.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.staticTexts["Agent live page"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap(); app.buttons["browser.localAI"].tap()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("这页中有几个鸡蛋文字")
        app.buttons["localAI.send"].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "出现", "7")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 40), app.debugDescription)
        input.tap(); input.typeText("这个页面中只有一个“鸡蛋”文字？")
        app.buttons["localAI.send"].tap()
        let repeated = app.staticTexts.matching(identifier: "localAI.answer").matching(NSPredicate(format: "label CONTAINS %@", "7"))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in repeated.count >= 2 }, object: nil)], timeout: 40) == .completed, app.debugDescription)
        input.tap(); input.typeText("把这个页面中微博的链接提取给我")
        app.buttons["localAI.send"].tap()
        let copy = app.buttons["localAI.link.copy.2"]
        XCTAssertTrue(copy.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertFalse(app.buttons["localAI.link.copy.3"].exists)
        copy.tap(); XCTAssertEqual(copy.label, "已复制")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "local-ai-agent-count-links"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["localAI.link.1"].tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !input.exists }, object: nil)], timeout: 10) == .completed)
        XCTAssertTrue(app.buttons["browser.siteInformation"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "weibo", "weibo")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
    }
    func testModelTreatsNegatedNavigationAsExplanation() throws {
        launchApp(enabled: true, language: "zh-Hans")
        app.open(try XCTUnwrap(URL(string: "soulo://home"))); openHomeAssistant()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("不要打开百度，请解释浏览器是什么，简短回答。")
        app.buttons["localAI.send"].tap()
        let answer = app.descendants(matching: .any)["localAI.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertTrue(input.exists)
        XCTAssertTrue(input.isHittable)
        XCTAssertFalse(app.buttons["localAI.action-review"].exists)
    }
    func testRealModelChangesAppearanceAndUndoRestoresIt() throws {
        try launch(enabled: true)
        let input = app.textFields["localAI.input"]
        input.tap(); input.typeText("Set app appearance to dark.")
        app.buttons["localAI.send"].tap()
        let undo = app.buttons["localAI.undo-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 120), app.debugDescription)
        defer { if undo.exists && undo.isEnabled { undo.tap() } }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Changed: App appearance")).firstMatch.exists, app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-browser-action-dark"; shot.lifetime = .keepAlways; add(shot)
        undo.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Restored: App appearance")).firstMatch.waitForExistence(timeout: 10))
    }
    func testHomeSearchKeepsOriginalLayoutAndAssistantCanVisitARealPage() throws {
        launchApp(enabled: true)
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        XCTAssertTrue(app.textFields["search.input"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["search.localAI"].exists)
        openHomeAssistant()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("Open https://www.swift.org/documentation/")
        app.buttons["localAI.send"].tap()
        XCTAssertTrue(app.staticTexts["Documentation"].firstMatch.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertFalse(app.textFields["localAI.input"].exists)
    }
    func testGreetingAndWebsiteNameActuallyOpenBaidu() throws {
        launchApp(enabled: true, language: "zh-Hans")
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        openHomeAssistant()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("你好 打开百度")
        app.buttons["localAI.send"].tap()
        XCTAssertTrue(app.buttons["browser.siteInformation"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "baidu.com", "baidu.com")).firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.textFields["localAI.input"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-open-baidu"; shot.lifetime = .keepAlways; add(shot)
    }
    func testMeteredDownloadExplainsSizeAndCancelKeepsItStopped() throws {
        launchApp(enabled: true, language: "zh-Hans")
        app.terminate(); app.launchEnvironment["SOULO_LOCAL_AI_QA_METERED"] = "1"; app.launch()
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        app.buttons["home.menu"].tap(); app.buttons["设置"].firstMatch.tap(); app.buttons["settings.localAI"].tap()
        let download = app.buttons["localAI.download.minicpm-v47-vision"]
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription); download.tap()
        let alert = app.alerts["使用移动网络下载？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GB")).firstMatch.exists)
        XCTAssertTrue(alert.buttons["等待 Wi-Fi"].exists); XCTAssertTrue(alert.buttons["使用移动网络"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-mobile-download-warning"; shot.lifetime = .keepAlways; add(shot)
        alert.buttons["取消"].tap()
        XCTAssertTrue(download.exists); XCTAssertFalse(alert.exists)
    }
    func testEnhancedModelSelectionShowsWholeDownloadAndCanCancel() throws {
        launchApp(enabled: true, language: "zh-Hans")
        app.terminate(); app.launchEnvironment["SOULO_LOCAL_AI_QA_METERED"] = "1"; app.launch()
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        app.buttons["home.menu"].tap(); app.buttons["设置"].firstMatch.tap(); app.buttons["settings.localAI"].tap()
        let picker = app.buttons["localAI.model-profile"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription); picker.tap()
        app.buttons["Agent · 35B-A3B"].firstMatch.tap()
        let download = app.buttons["localAI.download.enhanced"]
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-enhanced-model"; shot.lifetime = .keepAlways; add(shot)
        download.tap()
        let alert = app.alerts["使用移动网络下载？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "15.5")).firstMatch.exists, app.debugDescription)
        alert.buttons["取消"].tap()
        XCTAssertTrue(download.exists)
        picker.tap(); app.buttons["轻量 · 1B"].firstMatch.tap()
    }
    @MainActor func testExtractImagesOpensActualResourcesIncludingSmallImages() async throws {
        func image(_ label: String, color: UIColor, width: CGFloat) -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: 80), format: format).pngData { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: 80))
                (label as NSString).draw(at: CGPoint(x: 10, y: 26), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.white])
            }
        }
        let html = "<meta name='viewport' content='width=device-width'><h1>Image extraction</h1><p>These are real image resources.</p><img src='/one.png' width='80' height='80'><img src='/two.png' width='120' height='120'>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/images.html": Data(html.utf8), "/one.png": image("ONE", color: .systemOrange, width: 80), "/two.png": image("TWO", color: .systemTeal, width: 120)])
        let root = try await server.start(); defer { server.stop() }
        launchApp(enabled: true, language: "zh-Hans")
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [.init(name: "url", value: root.appendingPathComponent("images.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.staticTexts["Image extraction"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["更多"].firstMatch.tap(); app.buttons["browser.localAI"].tap()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("提取网页中所有图片")
        app.buttons["localAI.send"].tap()
        XCTAssertTrue(app.buttons["resources.tab.images"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["resources.image." + root.appendingPathComponent("one.png").absoluteString].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["resources.image." + root.appendingPathComponent("two.png").absoluteString].exists)
        XCTAssertFalse(app.textFields["localAI.input"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-extracted-images"; shot.lifetime = .keepAlways; add(shot)
    }
    func testAvatarCanBeChangedAndFloatingEntryDoesNotCoverChat() throws {
        launchApp(enabled: true)
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        openHomeAssistant(); assertFullPageChat()
        app.buttons["Settings"].firstMatch.tap(); app.buttons["Settings"].firstMatch.tap()
        let avatars = app.buttons["localAI.avatar-settings"]
        for _ in 0..<4 { if avatars.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(avatars.isHittable); avatars.tap()
        let floating = app.switches["localAI.floating.enable"]
        if floating.value as? String == "0" { floating.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertEqual(floating.value as? String, "1", app.debugDescription)
        app.buttons["localAI.avatar.cat"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-avatars"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["Assistant appearance"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["localAI.floating"].exists)
        returnFromChat()
        XCTAssertTrue(app.buttons["localAI.floating"].waitForExistence(timeout: 5), app.debugDescription)
        let floatingEntry = app.buttons["localAI.floating"]
        floatingEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.24, dy: 0.5)))
        XCTAssertEqual(floatingEntry.frame.width, 44, accuracy: 1)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(floatingEntry.frame.minX - self.app.frame.minX) < 1 }, object: nil)], timeout: 3) == .completed)
        XCTAssertEqual(floatingEntry.frame.minX, app.frame.minX, accuracy: 1, "The visible half retains a full touch target at the edge")
        let docked = XCTAttachment(screenshot: app.screenshot()); docked.name = "local-ai-companion-docked"; docked.lifetime = .keepAlways; add(docked)
        floatingEntry.tap(); assertFullPageChat()
        returnFromChat()
        floatingEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(floatingEntry.frame.maxX - self.app.frame.maxX) < 1 }, object: nil)], timeout: 3) == .completed)
        XCTAssertEqual(floatingEntry.frame.maxX, app.frame.maxX, accuracy: 1)
        let right = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); right.name = "local-ai-companion-docked-right"; right.lifetime = .keepAlways; add(right)
        floatingEntry.tap(); assertFullPageChat()
    }
    func testDisabledAssistantExplainsSetupAndKeepsThePageAvailable() throws {
        try launch(enabled: false)
        XCTAssertFalse(app.buttons["localAI.send"].isEnabled)
        app.buttons["localAI.setup"].tap()
        XCTAssertTrue(app.switches["localAI.enable"].waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-settings"; shot.lifetime = .keepAlways; add(shot)
        app.swipeUp()
        XCTAssertTrue(app.buttons["localAI.prompts"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        returnFromChat()
        XCTAssertTrue(app.staticTexts["Documentation"].firstMatch.waitForExistence(timeout: 10))
    }
    func testRealModelAnswersAboutRealPageAndCanBeStopped() throws {
        try launch(enabled: true)
        let input = app.textFields["localAI.input"]
        input.tap(); input.typeText("Which programming language is this page about? Answer with the language name in one short sentence.")
        app.buttons["localAI.send"].tap()
        let answer = app.staticTexts["localAI.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertTrue(app.buttons["localAI.send"].waitForExistence(timeout: 120), app.debugDescription)
        XCTAssertTrue(answer.label.lowercased().contains("swift"), answer.label)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-real-page-answer"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["New chat"].tap()
        app.switches["localAI.attach-page"].tap()
        input.tap(); input.typeText("Write a very long story about a journey across the ocean.")
        app.buttons["localAI.send"].tap()
        let stop = app.buttons["localAI.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        XCTAssertTrue(app.buttons["localAI.send"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(input.isEnabled)
        returnFromChat()
        XCTAssertTrue(app.staticTexts["Documentation"].firstMatch.waitForExistence(timeout: 10))
    }
    func testPrivateAssistantHasNoHistoryAction() throws {
        try launch(enabled: true, isPrivate: true)
        XCTAssertTrue(app.staticTexts["Private conversation · not saved"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Ask about screenshot"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["History"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-private-menu"; shot.lifetime = .keepAlways; add(shot)
    }
    func testLargeTypeAndLandscapeKeepTheComposerReachable() throws {
        launchApp(enabled: true, extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        openHomeAssistant()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); XCTAssertTrue(input.isHittable)
        let large = XCTAttachment(screenshot: app.screenshot()); large.name = "local-ai-accessibility-large-text"; large.lifetime = .keepAlways; add(large)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("Draft with a large font")
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(app.buttons["localAI.send"].isHittable)
        XCTAssertLessThanOrEqual(input.frame.maxY, app.frame.maxY)
        XCTAssertGreaterThanOrEqual(input.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(input.frame.maxX, app.frame.maxX)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "local-ai-landscape-keyboard"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
    }
    func testRightToLeftLayoutAndTraditionalChineseRemainUsable() throws {
        for language in ["ar-SA", "zh-Hant"] {
            launchApp(enabled: true, language: language)
            app.open(try XCTUnwrap(URL(string: "soulo://home")))
            openHomeAssistant()
            let input = app.textFields["localAI.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 10)); XCTAssertTrue(input.isHittable)
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            XCTAssertTrue(back.isHittable)
            if language == "ar-SA" { XCTAssertGreaterThan(back.frame.midX, app.frame.midX) }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "local-ai-layout-" + language; shot.lifetime = .keepAlways; add(shot)
            back.tap(); XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        }
    }
    func testReadingEarlierMessagesDoesNotGetPulledBackByStreaming() throws {
        launchApp(enabled: true)
        app.open(try XCTUnwrap(URL(string: "soulo://home")))
        openHomeAssistant()
        let input = app.textFields["localAI.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
        input.typeText("Write 40 numbered paragraphs about a sea voyage. Each paragraph must have at least 20 words. Continue through all 40 paragraphs.")
        app.buttons["localAI.send"].tap()
        let answer = app.staticTexts["localAI.answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        func length() -> Int { app.staticTexts.matching(identifier: "localAI.answer").allElementsBoundByIndex.reduce(0) { $0 + $1.label.count } }
        let longEnough = NSPredicate { _, _ in answer.exists && length() > 1800 }
        expectation(for: longEnough, evaluatedWith: nil); waitForExpectations(timeout: 90)
        app.scrollViews["localAI.transcript"].swipeDown()
        let latest = app.buttons["localAI.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5), app.debugDescription)
        let before = length()
        if app.buttons["localAI.stop"].exists {
            let stillEarlier = NSPredicate { _, _ in latest.exists && latest.isHittable && length() > before + 20 }
            expectation(for: stillEarlier, evaluatedWith: nil); waitForExpectations(timeout: 15)
        }
        latest.tap()
        if app.buttons["localAI.stop"].exists { app.buttons["localAI.stop"].tap() }
        XCTAssertTrue(app.buttons["localAI.send"].waitForExistence(timeout: 15))
    }
}
