import XCTest

final class ExternalWebLinkUITests: XCTestCase {
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

    func testBingVideoResultStaysInSouloOnDevice() throws {
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launch()

        let bingURL = URL(string: "https://www.bing.com/videos/search?q=%E9%B8%A1%E8%9B%8B")!
        var route = URLComponents()
        route.scheme = "soulo"
        route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: bingURL.absoluteString)]
        app.open(try XCTUnwrap(route.url))

        let bilibiliLink = app.webViews.links.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "bilibili")
        ).firstMatch
        XCTAssertTrue(bilibiliLink.waitForExistence(timeout: 30), app.debugDescription)
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
