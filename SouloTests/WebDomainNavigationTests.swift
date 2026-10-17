import XCTest
@testable import Soulo

@MainActor final class WebDomainNavigationTests: XCTestCase {
    func testEpisodeToolsAreNotAnInstalledExtension() {
        XCTAssertFalse(BuiltInUserScripts.all.contains { $0.namespace == "com.dkluge.soulo.builtin.video-helper" })
        XCTAssertTrue(BuiltInUserScripts.retiredNamespaces.contains("com.dkluge.soulo.builtin.video-helper"))
        XCTAssertFalse(WebEpisodeRuntime.script.isEmpty)
        XCTAssertFalse(WebEpisodeRuntime.script.contains("soulo-video-helper-host"))
    }

    func testCrossDomainConfirmationDefaultsOffAndUsesOnlyItsOwnSetting() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source=URL(string:"https://www.pbpbw.com/player/1-1-1.html")!
        func check(_ value:String)->Bool { BrowserDomainNavigationPolicy.requiresConfirmation(from:source,to:URL(string:value)!,defaults:defaults) }
        defaults.set(true,forKey:"video_helper_confirm_cross_domain")
        XCTAssertFalse(check("https://other.example/"),"The retired extension preference must not enable the new setting")
        defaults.set(true,forKey:BrowserDomainNavigationPolicy.preferenceKey)
        XCTAssertFalse(check("https://www.pbpbw.com/next"))
        XCTAssertFalse(check("http://WWW.PBPBW.COM.:8080/next"))
        XCTAssertTrue(check("https://other.example/"))
        XCTAssertTrue(check("https://www.pbpbw.com.evil.test/"))
        XCTAssertTrue(check("https://player.pbpbw.com/"))
        XCTAssertFalse(check("about:blank"))
        XCTAssertFalse(check("weixin://scan"))
        defaults.set(false,forKey:BrowserDomainNavigationPolicy.preferenceKey)
        XCTAssertFalse(check("https://other.example/"))
    }

    func testOnlyNativeRequestsAndExactTrustedDestinationsAreExplicit() {
        let target=URL(string:"https://example.com/video")!
        XCTAssertTrue(BrowserDomainNavigationPolicy.isExplicitNavigation(nativeRequest:true,destination:target,recentGestureDestination:nil))
        XCTAssertTrue(BrowserDomainNavigationPolicy.isExplicitNavigation(nativeRequest:false,destination:target,recentGestureDestination:target))
        XCTAssertFalse(BrowserDomainNavigationPolicy.isExplicitNavigation(nativeRequest:false,destination:target,recentGestureDestination:nil))
        XCTAssertFalse(BrowserDomainNavigationPolicy.isExplicitNavigation(nativeRequest:false,destination:target,recentGestureDestination:URL(string:"https://ad.example/")!))
    }

    func testDefaultAndCustomAllowlistMatchesOnlyDestinationDomains() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: BrowserDomainNavigationPolicy.preferenceKey)
        let source = URL(string: "https://origin.example/")!
        for host in ["qq.com", "v.qq.com", "a.b.qq.com", "WWW.BILIBILI.COM.", "v.youku.com"] {
            XCTAssertFalse(BrowserDomainNavigationPolicy.requiresConfirmation(from: source,
                to: URL(string: "https://\(host)/watch")!, defaults: defaults), host)
        }
        for host in ["notqq.com", "qq.com.evil.example", "qq.com-example.com", "other.example"] {
            XCTAssertTrue(BrowserDomainNavigationPolicy.requiresConfirmation(from: source,
                to: URL(string: "https://\(host)/")!, defaults: defaults), host)
        }
        XCTAssertTrue(BrowserDomainNavigationPolicy.requiresConfirmation(from: URL(string: "https://v.qq.com/")!,
            to: source, defaults: defaults), "Trust applies to the destination, not every link from a trusted site")
        let store = BrowserDomainAllowlist(defaults: defaults)
        XCTAssertTrue(store.add(" *.Example.COM. "))
        XCTAssertTrue(store.add("*.example.com"))
        XCTAssertEqual(store.rules.filter { $0 == "*.example.com" }.count, 1)
        XCTAssertFalse(BrowserDomainNavigationPolicy.requiresConfirmation(from: source,
            to: URL(string: "https://video.example.com/")!, defaults: defaults))
        store.remove("*.example.com")
        XCTAssertTrue(BrowserDomainNavigationPolicy.requiresConfirmation(from: source,
            to: URL(string: "https://video.example.com/")!, defaults: defaults))
        defaults.set(["exact.example"], forKey: BrowserDomainNavigationPolicy.allowlistKey)
        XCTAssertTrue(BrowserDomainNavigationPolicy.isAllowlisted(URL(string: "https://exact.example/")!, defaults: defaults))
        XCTAssertFalse(BrowserDomainNavigationPolicy.isAllowlisted(URL(string: "https://sub.exact.example/")!, defaults: defaults))
        defaults.set([], forKey: BrowserDomainNavigationPolicy.allowlistKey)
        XCTAssertFalse(BrowserDomainNavigationPolicy.isAllowlisted(URL(string: "https://qq.com/")!, defaults: defaults))
        store.reset()
        XCTAssertEqual(BrowserDomainNavigationPolicy.allowlist(defaults: defaults), BrowserDomainNavigationPolicy.defaultAllowlist)
    }

    func testInvalidDomainRulesCannotBecomeBroadOrURLMatches() {
        for value in ["*", "*.com", "https://qq.com", "qq.com/path", "qq.com:443", "user@qq.com",
                      "a..com", "*-qq.com", "*.127.0.0.1", "qq.com?target=other", "qq.com%2fevil"] {
            XCTAssertNil(BrowserDomainNavigationPolicy.normalizedRule(value), value)
        }
        XCTAssertEqual(BrowserDomainNavigationPolicy.trustRule(for: URL(string: "https://video.example.com/")!), "*.video.example.com")
        XCTAssertEqual(BrowserDomainNavigationPolicy.trustRule(for: URL(string: "http://localhost:1234/")!), "localhost")
    }

    func testPendingNavigationDecisionIsResolvedOnceAndIgnoresStaleButtons() throws {
        let model = WebViewModel()
        let source = URL(string: "https://origin.example/")!
        let destination = URL(string: "https://destination.example/")!
        var decisions: [Bool] = []
        let first = try XCTUnwrap(model.requestDomainNavigationConfirmation(from: source, to: destination) { decisions.append($0) })
        XCTAssertNil(model.requestDomainNavigationConfirmation(from: source, to: destination) { _ in XCTFail("Must not replace a pending decision") })
        model.resolveDomainNavigationConfirmation(id: UUID(), allowed: true)
        XCTAssertTrue(decisions.isEmpty)
        model.resolveDomainNavigationConfirmation(id: first, allowed: false)
        model.resolveDomainNavigationConfirmation(id: first, allowed: true)
        XCTAssertEqual(decisions, [false])
        XCTAssertNil(model.domainNavigationConfirmation)

        let second = try XCTUnwrap(model.requestDomainNavigationConfirmation(from: source, to: destination) { decisions.append($0) })
        model.resolveDomainNavigationConfirmation(id: first, allowed: true)
        XCTAssertEqual(model.domainNavigationConfirmation?.id, second)
        model.resolveDomainNavigationConfirmation(id: second, allowed: true)
        XCTAssertEqual(decisions, [false, true])
    }

    func testOpeningANewAddressCancelsPendingPageNavigation() throws {
        let model = WebViewModel()
        let source = URL(string: "https://origin.example/")!
        let destination = URL(string: "https://destination.example/")!
        var decision: Bool?
        model.requestDomainNavigationConfirmation(from: source, to: destination) { decision = $0 }
        model.loadURL(URL(string: "https://chosen.example/")!)
        XCTAssertEqual(decision, false)
        XCTAssertNil(model.domainNavigationConfirmation)
        XCTAssertEqual(model.currentURL?.host, "chosen.example")
    }

    func testNewTabCancelsOriginalNavigationOnceAndKeepsSourcePage() throws {
        let key = "soulo_saved_tabs.domain-confirmation.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let source = try XCTUnwrap(manager.activeWebViewModel)
        let origin = URL(string: "https://origin.example/")!
        let destination = URL(string: "https://destination.example/watch")!
        source.loadURL(origin)
        var decisions: [Bool] = []
        var request = URLRequest(url: destination)
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Referer")
        let id = try XCTUnwrap(source.requestDomainNavigationConfirmation(from: origin, to: destination,
            originalRequest: request) { decisions.append($0) })
        XCTAssertEqual(source.domainNavigationConfirmation?.requestForNewTab.value(forHTTPHeaderField: "Referer"), origin.absoluteString)
        XCTAssertFalse(manager.openDomainNavigationInNewTab(from: source, confirmationID: UUID()))
        XCTAssertEqual(manager.tabCount, 1)
        XCTAssertTrue(manager.openDomainNavigationInNewTab(from: source, confirmationID: id))
        XCTAssertEqual(manager.tabCount, 2)
        XCTAssertEqual(manager.activeWebViewModel?.currentURL, destination)
        XCTAssertEqual(source.currentURL, origin)
        XCTAssertEqual(decisions, [false])
        XCTAssertNil(source.domainNavigationConfirmation)
        XCTAssertFalse(manager.openDomainNavigationInNewTab(from: source, confirmationID: id))
        XCTAssertEqual(manager.tabCount, 2)
    }

    func testConfirmationOpensNewTabBeyondFormerLimit() throws {
        let key = "soulo_saved_tabs.domain-confirmation.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let source = try XCTUnwrap(manager.activeWebViewModel)
        let origin = URL(string: "https://origin.example/")!
        let destination = URL(string: "https://destination.example/")!
        source.loadURL(origin)
        for _ in 1..<100 { manager.createTab(switchTo: false) }
        let ids = manager.tabs.map(\.id)
        var decisions: [Bool] = []
        let id = try XCTUnwrap(source.requestDomainNavigationConfirmation(from: origin, to: destination) { decisions.append($0) })
        XCTAssertTrue(manager.openDomainNavigationInNewTab(from: source, confirmationID: id))
        XCTAssertEqual(manager.tabCount, 101)
        XCTAssertEqual(Array(manager.tabs.prefix(100)).map(\.id), ids)
        XCTAssertEqual(manager.activeWebViewModel?.currentURL, destination)
        XCTAssertEqual(source.currentURL, origin)
        XCTAssertNil(source.domainNavigationConfirmation)
        XCTAssertEqual(decisions, [false])
        manager.saveToDisk()
    }

    func testNewTabOpensAddressForPostAndStreamedRequestsWithoutReplayingBodies() throws {
        let key = "soulo_saved_tabs.domain-confirmation.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let source = try XCTUnwrap(manager.activeWebViewModel)
        let origin = URL(string: "https://origin.example/")!
        let destination = URL(string: "https://destination.example/")!
        source.loadURL(origin)
        var post = URLRequest(url: destination)
        post.httpMethod = "POST"
        post.httpBody = Data("query=chosen".utf8)
        var stream = URLRequest(url: destination)
        stream.httpBodyStream = InputStream(data: Data("payload".utf8))
        for (index, request) in [post, stream].enumerated() {
            var decisions: [Bool] = []
            let id = try XCTUnwrap(source.requestDomainNavigationConfirmation(from: origin, to: destination,
                originalRequest: request) { decisions.append($0) })
            let confirmation = try XCTUnwrap(source.domainNavigationConfirmation)
            let newRequest = confirmation.requestForNewTab
            XCTAssertEqual(newRequest.url, destination)
            XCTAssertEqual(newRequest.httpMethod, "GET")
            XCTAssertNil(newRequest.httpBody)
            XCTAssertNil(newRequest.httpBodyStream)
            XCTAssertEqual(confirmation.originalRequest?.httpMethod, request.httpMethod)
            XCTAssertEqual(confirmation.originalRequest?.httpBody, request.httpBody)
            XCTAssertTrue(manager.openDomainNavigationInNewTab(from: source, confirmationID: id))
            XCTAssertEqual(manager.tabCount, index + 2)
            XCTAssertEqual(manager.activeWebViewModel?.currentURL, destination)
            XCTAssertEqual(source.currentURL, origin)
            XCTAssertNil(source.domainNavigationConfirmation)
            XCTAssertEqual(decisions, [false])
        }
    }

    func testBrowserControlsAndRuntimeChangesCancelPendingNavigation() {
        let actions: [(WebViewModel) -> Void] = [
            { $0.canGoBack = true; $0.goBack() },
            { $0.canGoForward = true; $0.goForward() },
            { $0.reload() }, { $0.releaseWebViewRuntime() }, { $0.rebuildWebViewRuntime() }
        ]
        for action in actions {
            let model = WebViewModel()
            var decisions: [Bool] = []
            model.requestDomainNavigationConfirmation(from: URL(string: "https://origin.example/")!,
                to: URL(string: "https://destination.example/")!) { decisions.append($0) }
            action(model)
            XCTAssertEqual(decisions, [false])
            XCTAssertNil(model.domainNavigationConfirmation)
        }
    }
}
