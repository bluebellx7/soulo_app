import XCTest

final class ExternalWebLinkUITests: XCTestCase {
    @MainActor
    private func launchFixture(_ url: URL, promptEnabled: Bool = true) throws -> XCUIApplication {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Fixture deep link and clipboard permission") { alert in
            if ["在“Soulo”中打开？", "Open in “Soulo”?", "Open in \"Soulo\"?"].contains(alert.label) {
                for title in ["打开", "Open"] {
                    let open = alert.buttons[title]
                    if open.exists { open.tap(); return true }
                }
            }
            for title in ["不允许粘贴", "Don't Allow Paste", "Don’t Allow Paste"] {
                let deny = alert.buttons[title]
                if deny.exists { deny.tap(); return true }
            }
            return false
        }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-ad_block_enabled", "YES",
            "-ad_block_confirm_cross_domain", "NO", "-icloud_sync_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-is_incognito", "NO",
            "-soulo_external_navigation_prompt_enabled", promptEnabled ? "YES" : "NO"]
        app.launch()
        var route = URLComponents()
        route.scheme = "soulo"
        route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        app.open(try XCTUnwrap(route.url))
        return app
    }

    @MainActor
    func testExternalAppPromptsWaitForChoiceAndCanBeShownAgain() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font:20px system-ui"><h1>External app fixture</h1>
        <p><a href="spotify://track/example">Same window app link</a></p>
        <p><a href="spotify://track/example" target="_blank">New window app link</a></p></body>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = try launchFixture(root.appendingPathComponent("page.html"))
        defer { app.terminate() }
        XCTAssertTrue(app.webViews.staticTexts["External app fixture"].waitForExistence(timeout: 20))
        for label in ["Same window app link", "New window app link", "Same window app link"] {
            app.webViews.links[label].tap()
            let confirm = app.buttons["browser.external-app-confirmation.continue"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
            try await Task.sleep(for: .seconds(5))
            XCTAssertTrue(confirm.exists && confirm.isHittable, "The prompt must wait for a choice")
            app.buttons["browser.external-app-confirmation.cancel"].tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.webViews.staticTexts["External app fixture"].exists)
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    @MainActor
    func testEmbeddedSignInPopupRequestsExternalAppConfirmation() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font:20px system-ui"><h1>Popup origin</h1>
        <button onclick="window.open('/oauth.html','_blank')">Open sign in popup</button></body>
        """
        let popup = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font:20px system-ui;padding-top:90px"><h1>Embedded sign in</h1>
        <a href="weixin://authorize">Continue in WeChat</a></body>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8),
            "/oauth.html": Data(popup.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = try launchFixture(root.appendingPathComponent("page.html"))
        defer { app.terminate() }
        let open = app.webViews.buttons["Open sign in popup"]
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        let link = app.webViews.links["Continue in WeChat"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let cancel = app.buttons["browser.external-app-confirmation.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(link.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testScriptedFooterItemsAndIframeAppHandoffsShowConfirmation() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font:20px system-ui"><h1>Footer app actions</h1>
        <div style="position:fixed;bottom:120px;display:flex;flex-direction:column;gap:20px">
        <div onclick="location.href='baiduboxapp://video/detail'">Open app item</div>
        <div onclick="const f=document.createElement('iframe');f.hidden=true;f.src='baiduboxapp://video/comment';document.body.append(f)">Comment item</div>
        <div onclick="location.href='https://boxer.baidu.com/scheme?scheme=baiduboxapp%3A%2F%2Fvideo%2Fcomment'">Baidu handoff item</div>
        </div></body>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = try launchFixture(root.appendingPathComponent("page.html"))
        defer { app.terminate() }
        for label in ["Open app item", "Comment item", "Baidu handoff item"] {
            let item = app.webViews.buttons[label].firstMatch
            guard item.waitForExistence(timeout: 20) else { XCTFail(app.debugDescription); return }
            item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let cancel = app.buttons["browser.external-app-confirmation.cancel"]
            guard cancel.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
            cancel.tap()
        }
    }

    @MainActor
    func testDisabledPromptOpensAppDirectly() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <a href="maps://?q=Soulo">Open Maps</a>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = try launchFixture(root.appendingPathComponent("page.html"), promptEnabled: false)
        defer { app.terminate() }
        let link = app.webViews.links["Open Maps"]
        guard link.waitForExistence(timeout: 20) else { XCTFail(app.debugDescription); return }
        link.tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        defer { maps.terminate() }
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertFalse(app.buttons["browser.external-app-confirmation.continue"].exists)
    }

    @MainActor
    func testAppPromptSettingLivesInAdBlockingAndAppliesImmediately() async throws {
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Prompt settings fixture</h1><a href='soulo-test-missing-app://open'>Open unavailable app</a>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = try launchFixture(root.appendingPathComponent("page.html"))
        defer { app.terminate() }
        guard app.webViews.links["Open unavailable app"].waitForExistence(timeout: 20) else { XCTFail(app.debugDescription); return }
        app.buttons["browser.siteInformation"].tap()
        guard app.buttons["site.ad-block-details"].waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        app.buttons["site.ad-block-details"].tap()
        let toggle = app.switches["adBlock.promptBeforeOpeningApp"]
        guard toggle.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.switches["adBlock.allowAutomaticNavigation"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "App prompt setting inside Ad Blocking"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Done"].firstMatch.tap()
        app.webViews.links["Open unavailable app"].tap()
        let failed = app.staticTexts["Unable to Open External App"]
        XCTAssertTrue(failed.waitForExistence(timeout: 5))
        XCTAssertTrue(failed.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["browser.external-app-confirmation.continue"].exists)
        app.buttons["browser.siteInformation"].tap()
        guard app.buttons["site.ad-block-details"].waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        app.buttons["site.ad-block-details"].tap()
        guard toggle.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["Done"].firstMatch.tap()
        app.webViews.links["Open unavailable app"].tap()
        XCTAssertTrue(app.buttons["browser.external-app-confirmation.cancel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testBaiduVideoFooterAppActionWithAdBlockingEnabled() throws {
        let url = URL(string: "https://mbd.baidu.com/newspage/data/videoshare?nid=sv_2439918007444607660&sourceFrom=qmj")!
        let app = try launchFixture(url)
        defer { app.terminate() }
        let comment = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@ OR label CONTAINS %@", "评论", "说两句")).firstMatch
        guard comment.waitForExistence(timeout: 40) else {
            XCTFail(app.debugDescription)
            return
        }
        let cancel = app.buttons["browser.external-app-confirmation.cancel"]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
            XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        }
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Baidu video footer before app action"; before.lifetime = .keepAlways; add(before)
        comment.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "Baidu video footer app confirmation"; after.lifetime = .keepAlways; add(after)
    }

    func testBingDouyinVideoResultStaysInSouloOnDevice() throws {
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launch()

        let bingURL = URL(string: "https://www.bing.com/videos/search?q=site%3Adouyin.com%20%E9%B8%A1%E8%9B%8B")!
        var route = URLComponents()
        route.scheme = "soulo"
        route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: bingURL.absoluteString)]
        app.open(try XCTUnwrap(route.url))

        let douyinLink = app.webViews.links.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "douyin")
        ).firstMatch
        XCTAssertTrue(douyinLink.waitForExistence(timeout: 30), app.debugDescription)
        douyinLink.tap()

        sleep(3)
        let douyin = XCUIApplication(bundleIdentifier: "com.ss.iphone.ugc.Aweme")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertNotEqual(douyin.state, .runningForeground)
        let address = app.buttons.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "douyin.com")
        ).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testBingVideoResultStaysInSouloOnDevice() throws {
        let app = try launchFixture(URL(string: "https://cn.bing.com/search?q=%E9%B8%A1%E8%9B%8B")!)
        let videoTab = app.webViews.links.matching(
            NSPredicate(format: "label == %@ OR label == %@", "视频", "Videos")
        ).firstMatch
        guard videoTab.waitForExistence(timeout: 30) else { XCTFail(app.debugDescription); return }
        videoTab.tap()

        let bilibiliLink = app.webViews.links.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "bilibili")
        ).firstMatch
        guard bilibiliLink.waitForExistence(timeout: 30) else { XCTFail(app.debugDescription); return }
        bilibiliLink.tap()

        // An installed Bilibili app must not take over a normal web result.
        sleep(3)
        let bilibili = XCUIApplication(bundleIdentifier: "tv.danmaku.bilianime")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Bing video after card tap"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertNotEqual(bilibili.state, .runningForeground)
        let address = app.buttons.matching(
            NSPredicate(format: "value CONTAINS[c] %@", "bilibili.com")
        ).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15), app.debugDescription)
    }
}
