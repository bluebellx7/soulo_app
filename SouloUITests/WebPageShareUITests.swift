import XCTest

@MainActor final class WebPageShareUITests: XCTestCase {
    private func start(language: String = "zh-Hans", landscape: Bool = false) async throws -> (XCUIApplication, DownloadPlaybackHTTPFixture) {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Viewport Share Fixture</title>
        <style>body{margin:0;font:20px system-ui;background:#eaf0f6;color:#162b42}header{padding:28px;background:#18384e;color:white}article{padding:24px}p{line-height:1.8}</style>
        <header><h1>看见的这一页</h1><p>Viewport Share Fixture</p></header>
        <article><h2>只分享眼前的内容</h2><p>周末沿着河岸散步，走过旧书店，也经过刚开门的咖啡馆。</p><p>页面下方的内容不会被拼成长图；分享图片底部会保留 Soulo 标识。</p>
        \((1...12).map { "<h3>沿途记录 \($0)</h3><p>慢下来，看见城市里熟悉又新鲜的细节。</p>" }.joined())</article>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8)])
        let root = try await server.start()
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", language, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-appearance", "light", "-privacy_https_upgrade_enabled", "NO", "-icloud_sync_enabled", "NO",
            "-ad_block_enabled", "YES", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
            "-is_incognito", "YES"]
        app.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page.html").absoluteString + "?q=chosen%2Bvalue#part")]
        app.open(try XCTUnwrap(route.url))
        guard app.webViews.staticTexts["Viewport Share Fixture"].firstMatch.waitForExistence(timeout: 25) else {
            XCTFail(app.debugDescription); return (app, server)
        }
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height
            }, object: nil)], timeout: 8)
        }
        return (app, server)
    }

    private func preview(_ app: XCUIApplication) -> Bool {
        let more = app.buttons["ellipsis"].firstMatch
        guard more.waitForExistence(timeout: 10) else { XCTFail(app.debugDescription); return false }
        more.tap()
        let share = app.descendants(matching: .any)["browser.moreMenu.share"].firstMatch
        guard share.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return false }
        share.tap()
        guard app.images["pageShare.preview"].waitForExistence(timeout: 12) else { XCTFail(app.debugDescription); return false }
        return true
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + " accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    func testPreviewShowsBrandedViewportAndCopyFeedback() async throws {
        let (app, server) = try await start(); defer { app.terminate(); server.stop() }
        app.webViews.firstMatch.swipeUp()
        // Scrolling down collapses browser chrome; a short upward scroll reveals it.
        let web = app.webViews.firstMatch
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        guard preview(app) else { return }
        for id in ["pageShare.shareImage", "pageShare.copyLink", "pageShare.shareLink"] {
            XCTAssertTrue(app.buttons[id].isEnabled)
            XCTAssertTrue(app.buttons[id].isHittable, app.debugDescription)
        }
        XCTAssertEqual(app.images["pageShare.preview"].value as? String, "Soulo：多重搜索浏览器")
        record(app, "中文分享预览与 Soulo Logo")
        app.buttons["pageShare.copyLink"].tap()
        XCTAssertTrue(app.buttons["pageShare.copyLink"].label.contains("已复制"))
        app.buttons["pageShare.close"].tap()
        XCTAssertTrue(app.buttons["ellipsis"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(preview(app), "The preview can be opened again after copying")
    }

    func testImageActionOpensSystemImageSharing() async throws {
        let (app, server) = try await start(language: "en-US"); defer { app.terminate(); server.stop() }
        guard preview(app) else { return }
        app.buttons["pageShare.shareImage"].tap()
        let saveImage = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Save Image", "存储图像", "保存图像", "儲存影像"])).firstMatch
        XCTAssertTrue(saveImage.waitForExistence(timeout: 10), app.debugDescription)
        record(app, "Image sharing uses the branded viewport")
    }

    func testLinkActionOpensSystemURLSharing() async throws {
        let (app, server) = try await start(language: "en-US"); defer { app.terminate(); server.stop() }
        guard preview(app) else { return }
        app.buttons["pageShare.shareLink"].tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Copy", "拷贝", "複製"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10), app.debugDescription)
        let saveImage = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save Image")).firstMatch
        XCTAssertFalse(saveImage.exists)
        record(app, "URL sharing keeps ordinary link actions")
    }

    func testPreviewActionsFitInIPadLandscape() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad landscape layout") }
        let (app, server) = try await start(language: "en-US", landscape: true)
        defer { app.terminate(); server.stop(); XCUIDevice.shared.orientation = .portrait }
        guard preview(app) else { return }
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Verify an actual landscape layout")
        for id in ["pageShare.shareImage", "pageShare.copyLink", "pageShare.shareLink"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, app.debugDescription)
            XCTAssertGreaterThanOrEqual(button.frame.height, 40)
        }
        XCTAssertTrue(app.buttons["pageShare.close"].isHittable)
        record(app, "Landscape viewport share preview")
    }
}
