import XCTest
import UIKit
import WebKit

@MainActor
final class IPadBrowserBenchmarkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SOULO_IPAD_BENCHMARK"] == "1",
              UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Opt-in physical iPad browser comparison")
        }
    }
    func testFixtureDiagnosticsAreNotCached() async throws {
        let server=try BrowserBenchmarkHTTPFixture(),root=try await server.start()
        defer {server.stop()}
        let web=WKWebView()
        web.loadHTMLString("""
        <script>(async()=>{for(let i=0;i<2;i++)await fetch('/_mark?browser=cache-check&phase=probe&elapsed=1');document.title='done'})().catch(()=>document.title='error')</script>
        """,baseURL:root)
        for _ in 0..<100 where web.title != "done" {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertEqual(web.title,"done")
        XCTAssertEqual(server.events("cache-check","probe").count,2,"Identical timing markers must both reach the recorder")
    }
    private var benchmarkBrowsers: [String] {
        let value=ProcessInfo.processInfo.environment["SOULO_BENCH_BROWSER"] ?? "both"
        return ["safari","soulo"].contains(value) ? [value] : ["safari","soulo"]
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testPhysicalIPadSmoke() throws {
        XCUIDevice.shared.orientation = .portrait
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        safari.typeKey("t", modifierFlags: .command)
        defer { safari.activate(); safari.typeKey("w", modifierFlags: .command) }
        safari.typeKey("l", modifierFlags: .command)
        safari.typeText("https://m.baidu.com/s?word=%E7%9B%90%E7%84%97\n")
        XCTAssertTrue(safari.webViews.firstMatch.waitForExistence(timeout: 30), safari.debugDescription)
        attach(safari, "ipad-safari-baseline")
        safari.webViews.firstMatch.swipeUp(velocity: .fast)
        attach(safari, "ipad-safari-after-scroll")
        let soulo = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        soulo.launchArguments = ["-is_incognito","YES","-baidu_search_optimization_enabled","NO"]
        soulo.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name:"url",value:"https://m.baidu.com/s?word=%E7%9B%90%E7%84%97")]
        soulo.open(try XCTUnwrap(route.url))
        XCTAssertTrue(soulo.webViews.firstMatch.waitForExistence(timeout: 30), soulo.debugDescription)
        attach(soulo,"ipad-soulo-baseline")
        soulo.webViews.firstMatch.swipeUp(velocity:.fast)
        attach(soulo,"ipad-soulo-after-scroll")
    }
    func testLiveSaltComparison() throws {
        XCUIDevice.shared.orientation = .portrait
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        var ownsSafariTab = false
        defer { if ownsSafariTab { safari.activate(); safari.typeKey("w", modifierFlags:.command) } }
        for browser in benchmarkBrowsers {
            let app = browser == "safari" ? safari : XCUIApplication(bundleIdentifier:"com.dkluge.Soulo")
            let url = "https://m.baidu.com/s?word=%E7%9B%90%E7%84%97"
            if browser == "safari" {
                app.activate(); app.typeKey("t",modifierFlags:.command); ownsSafariTab = true
                app.typeKey("l",modifierFlags:.command); app.typeText(url+"\n")
            } else {
                app.launchArguments=["-app_language","en-US","-is_incognito","YES","-baidu_search_optimization_enabled",ProcessInfo.processInfo.environment["SOULO_BENCH_BAIDU"] ?? "YES"]
                app.launch()
                var route=URLComponents();route.scheme="soulo";route.host="open";route.queryItems=[URLQueryItem(name:"url",value:url)]
                app.open(try XCTUnwrap(route.url))
            }
            let web=app.webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout:30))
            let salt=web.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","盐焗")).firstMatch
            XCTAssertTrue(salt.waitForExistence(timeout:30),"Salt results must appear")
            attach(app,"ipad-live-\(browser)-start")
            print("IPAD_BENCH_PHASE|\(browser)|scroll-start|\(Date().timeIntervalSince1970)");fflush(stdout)
            let scrolls=min(10,max(0,Int(ProcessInfo.processInfo.environment["SOULO_BENCH_SCROLLS"] ?? "4") ?? 4))
            for _ in 0..<scrolls {web.swipeUp(velocity:.fast)}
            attach(app,"ipad-live-\(browser)-scrolled")
            for _ in 0..<scrolls {web.swipeDown(velocity:.fast)}
            print("IPAD_BENCH_PHASE|\(browser)|scroll-end|\(Date().timeIntervalSince1970)");fflush(stdout)
            XCTAssertTrue(salt.exists,"The results remain responsive and accessible after scrolling")
            attach(app,"ipad-live-\(browser)-returned-top")
            if browser == "safari" { app.typeKey("w",modifierFlags:.command); ownsSafariTab=false }
        }
    }
    func testLongPressSelectionAndHistory() async throws {
        XCUIDevice.shared.orientation = .portrait
        let server=try BrowserBenchmarkHTTPFixture(),root=try await server.start()
        defer {server.stop()}
        let app=XCUIApplication(bundleIdentifier:"com.dkluge.Soulo")
        app.launchArguments=["-app_language","en-US","-is_incognito","YES","-ad_block_enabled",ProcessInfo.processInfo.environment["SOULO_BENCH_ADS"] ?? "NO","-keep_fullscreen_browsing","NO","-browser_toolbar_hidden","NO"]
        app.launch()
        let url=root.appendingPathComponent("selection").appending(queryItems:[URLQueryItem(name:"browser",value:"soulo")])
        var route=URLComponents();route.scheme="soulo";route.host="open";route.queryItems=[URLQueryItem(name:"url",value:url.absoluteString)]
        app.open(try XCTUnwrap(route.url));try waitForMark(server,"soulo","ready",1)
        let web=app.webViews.firstMatch
        web.staticTexts["Salt search benchmark"].firstMatch.press(forDuration:1)
        let copy=app.menuItems.matching(NSPredicate(format:"label IN %@",["Copy","拷贝","复制"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout:10),"Stationary holds still open native text selection")
        attach(app,"ipad-native-selection")
        web.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.1)).tap()
        web.links["Open benchmark result"].firstMatch.tap();try waitForMark(server,"soulo","result",1)
        if ProcessInfo.processInfo.environment["SOULO_BENCH_EDGE"] == "1" {
            let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.002,dy:0.5))
            let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5))
            start.press(forDuration:0.1,thenDragTo:end,withVelocity:.default,thenHoldForDuration:0)
        } else {
            let back=app.buttons.matching(NSPredicate(format:"label IN %@",["Back","返回","后退"])).allElementsBoundByIndex.first {$0.isEnabled && $0.isHittable}
            try XCTUnwrap(back).tap()
        }
        try waitForMark(server,"soulo","back",1)
        XCTAssertTrue(try XCTUnwrap(server.events("soulo","back").first).persisted,"History must preserve the cached document")
        attach(app,"ipad-native-history-back")
    }
    private func waitForMark(_ server:BrowserBenchmarkHTTPFixture,_ browser:String,_ phase:String,_ count:Int) throws {
        let ready=XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in server.events(browser,phase).count>=count },object:nil)
        guard XCTWaiter.wait(for:[ready],timeout:20) == .completed else {
            throw NSError(domain:"BrowserBenchmark",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing \(browser) \(phase) marker"])
        }
    }
    func testScrolledHistoryPreservesPosition() async throws {
        XCUIDevice.shared.orientation = .portrait
        let server = try BrowserBenchmarkHTTPFixture(), root = try await server.start()
        defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-is_incognito", "YES", "-ad_block_enabled", "YES"]
        app.launch()
        let url = root.appendingPathComponent("history").appending(queryItems: [URLQueryItem(name: "browser", value: "soulo")])
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        app.open(try XCTUnwrap(route.url)); try waitForMark(server, "soulo", "ready", 1)
        let web = app.webViews.firstMatch
        web.swipeUp(velocity: .slow)
        let link = web.links.matching(NSPredicate(format: "label BEGINSWITH %@", "Open result at ")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(link).tap()
        try waitForMark(server, "soulo", "leaving-source", 1)
        try waitForMark(server, "soulo", "result", 1)
        let before = try XCTUnwrap(server.events("soulo", "leaving-source").last?.scrollOffset)
        XCTAssertGreaterThan(before, 100, "Exercise a genuinely scrolled document")
        let back = app.buttons.matching(NSPredicate(format: "label IN %@", ["Back", "返回", "后退"])).allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable }
        try XCTUnwrap(back).tap(); try waitForMark(server, "soulo", "back", 1)
        // pageshow can precede WebKit's native scroll restoration. Observe its
        // completion without scrolling or otherwise modifying the document.
        try waitForMark(server, "soulo", "position-restored", 1)
        let restored = try XCTUnwrap(server.events("soulo", "position-restored").last)
        print("IPAD_HISTORY_POSITION|before=\(before)|after=\(restored.scrollOffset ?? -1)|wait=\(restored.elapsed)ms")
        XCTAssertTrue(restored.persisted)
        XCTAssertEqual(try XCTUnwrap(restored.scrollOffset), before, accuracy: 2)
        attach(app, "ipad-scrolled-history-restored")
    }
    func testFixtureComparison() async throws {
        XCUIDevice.shared.orientation = .portrait
        let server=try BrowserBenchmarkHTTPFixture(),root=try await server.start()
        defer { server.stop() }
        print("IPAD_BENCH_DEVICE|thermal=\(ProcessInfo.processInfo.thermalState.rawValue)|lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)");fflush(stdout)
        var ownsSafariTab = false
        let safari=XCUIApplication(bundleIdentifier:"com.apple.mobilesafari")
        defer { if ownsSafariTab { safari.activate();safari.typeKey("w",modifierFlags:.command) } }
        for browser in benchmarkBrowsers {
            let app=XCUIApplication(bundleIdentifier:browser=="safari" ? "com.apple.mobilesafari":"com.dkluge.Soulo")
            print("IPAD_BENCH_PHASE|\(browser)|begin|\(Date().timeIntervalSince1970)");fflush(stdout)
            let url=root.appendingPathComponent("source").appending(queryItems:[URLQueryItem(name:"browser",value:browser)])
            if browser=="safari" {
                app.activate();app.typeKey("t",modifierFlags:.command);ownsSafariTab=true;app.typeKey("l",modifierFlags:.command);app.typeText(url.absoluteString+"\n")
            } else {
                app.launchArguments=["-app_language","en-US","-is_incognito","YES","-baidu_search_optimization_enabled","NO","-ad_block_enabled",ProcessInfo.processInfo.environment["SOULO_BENCH_ADS"] ?? "NO"]
                app.launch()
                var route=URLComponents();route.scheme="soulo";route.host="open";route.queryItems=[URLQueryItem(name:"url",value:url.absoluteString)]
                app.open(try XCTUnwrap(route.url))
            }
            try waitForMark(server,browser,"ready",1)
            let web=app.webViews.firstMatch
            let trials=min(10,max(1,Int(ProcessInfo.processInfo.environment["SOULO_BENCH_TRIALS"] ?? "3") ?? 3))
            for trial in 0..<(ProcessInfo.processInfo.environment["SOULO_BENCH_SCROLL_ONLY"] == "1" ? 0 : trials) {
                if trial>0 {web.links["Reload benchmark page"].firstMatch.tap();try waitForMark(server,browser,"ready",trial+1)}
                web.links["Open benchmark result"].firstMatch.tap();try waitForMark(server,browser,"result",trial+1)
                let back=app.buttons.matching(NSPredicate(format:"label IN %@",["Back","返回","后退"])).allElementsBoundByIndex.first{$0.isEnabled&&$0.isHittable}
                if let back {back.tap()} else {
                    let origin=app.coordinate(withNormalizedOffset:.zero)
                    origin.withOffset(CGVector(dx:2,dy:app.frame.height*0.5)).press(forDuration:0.05,thenDragTo:origin.withOffset(CGVector(dx:app.frame.width*0.8,dy:app.frame.height*0.5)))
                }
                try waitForMark(server,browser,"back",trial+1)
            }
            print("IPAD_BENCH_PHASE|\(browser)|scroll-start|\(Date().timeIntervalSince1970)");fflush(stdout)
            let scrolls=min(10,max(0,Int(ProcessInfo.processInfo.environment["SOULO_BENCH_SCROLLS"] ?? "4") ?? 4))
            for _ in 0..<scrolls {web.swipeUp(velocity:.fast)}
            for _ in 0..<scrolls {web.swipeDown(velocity:.fast)}
            print("IPAD_BENCH_PHASE|\(browser)|scroll-end|\(Date().timeIntervalSince1970)");fflush(stdout)
            attach(app,"ipad-fixture-\(browser)")
            if browser=="safari" {app.typeKey("w",modifierFlags:.command);ownsSafariTab=false}
            else {app.terminate()}
            print("IPAD_BENCH_PHASE|\(browser)|end|\(Date().timeIntervalSince1970)");fflush(stdout)
        }
        let data=try JSONEncoder().encode(server.allEvents())
        let report=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");report.name="ipad-browser-timings.json";report.lifetime = .keepAlways;add(report)
        print("IPAD_BENCH_TIMINGS|"+String(decoding:data,as:UTF8.self));fflush(stdout)
    }

}
