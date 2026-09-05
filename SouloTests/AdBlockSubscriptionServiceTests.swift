import XCTest
@testable import Soulo

final class AdBlockSubscriptionServiceTests: XCTestCase {
    @MainActor
    func testSubscriptionUpdatePreservesToggleChangedDuringRequestAndCountsScopedRules() async throws {
        let suite = "SubscriptionRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            SubscriptionTestProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AdBlockSubscriptionService(userDefaults: defaults, session: session)
        for item in service.subscriptions { service.setEnabled(item.id == "easylist", for: item) }
        let subscription = try XCTUnwrap(service.subscriptions.first { $0.id == "easylist" })
        SubscriptionTestProtocol.handler = { request in
            Task { @MainActor in
                service.setEnabled(false, for: subscription)
                request.respond(body: "||ads.example.com^\nexample.com##.advert", mimeType: "text/plain")
            }
        }

        await service.updateEnabledSubscriptions()
        let updated = try XCTUnwrap(service.subscriptions.first { $0.id == subscription.id })
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.networkRuleCount, 1)
        XCTAssertEqual(updated.cosmeticRuleCount, 1)
        XCTAssertEqual(service.enabledRuleSummary, .empty)
        service.reloadFromDefaults()
        XCTAssertFalse(try XCTUnwrap(service.subscriptions.first { $0.id == subscription.id }).isEnabled)
        service.setEnabled(true, for: updated)
        XCTAssertEqual(service.enabledRuleSummary.cosmeticRules.first?.selector, ".advert")
    }

    @MainActor
    func testHTMLResponseKeepsValidRulesAndUnchangedRulesKeepTheirSignature() async throws {
        let suite = "SubscriptionCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            SubscriptionTestProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AdBlockSubscriptionService(userDefaults: defaults, session: session)
        for item in service.subscriptions { service.setEnabled(item.id == "easylist", for: item) }
        SubscriptionTestProtocol.handler = { $0.respond(body: "||ads.example.com^", mimeType: "text/plain") }
        await service.updateEnabledSubscriptions()
        let validRules = service.enabledRuleSummary
        XCTAssertFalse(validRules.networkRules.isEmpty)
        // A fixed sentinel makes this independent of clock resolution.
        defaults.set(1234.0, forKey: "soulo_ad_block_subscription_rules_version")
        let restored = AdBlockSubscriptionService(userDefaults: defaults, session: session)
        XCTAssertEqual(AdBlockSubscriptionService.rulesSignature(userDefaults: defaults), "1234.0")
        SubscriptionTestProtocol.handler = { $0.respond(body: "<!doctype html><html>Sign in</html>", mimeType: "text/html") }
        await restored.updateEnabledSubscriptions()
        XCTAssertEqual(restored.enabledRuleSummary, validRules)
        XCTAssertFalse(restored.lastError.isEmpty)
        XCTAssertEqual(AdBlockSubscriptionService.rulesSignature(userDefaults: defaults), "1234.0")
    }

    func testParserConvertsABPNetworkAndCosmeticRules() {
        let sample = """
        ! comment
        ||ads.example.com^
        /cpcad.js
        @@||allowed.example.com^
        ##.ad-banner
        example.com##.site-specific
        #@#.exception
        """

        let parsed = AdBlockRuleParser.parse(sample)

        XCTAssertTrue(parsed.networkURLFilters.contains("ads\\.example\\.com"))
        XCTAssertTrue(parsed.networkURLFilters.contains("/cpcad\\.js"))
        XCTAssertFalse(parsed.networkURLFilters.contains { $0.contains("allowed") })
        XCTAssertTrue(parsed.cosmeticSelectors.contains(".ad-banner"))
        XCTAssertFalse(parsed.cosmeticSelectors.contains(".site-specific"))
        XCTAssertTrue(parsed.cosmeticRules.contains {
            $0.selector == ".site-specific" && $0.ifDomains.contains("*example.com")
        })
        XCTAssertFalse(parsed.cosmeticSelectors.contains(".exception"))
    }

    func testParserPreservesResourceTypesLoadTypesAndDomainOptions() {
        let sample = """
        ||tracker.example^$script,image,third-party,domain=example.com|~admin.example.com
        """

        let parsed = AdBlockRuleParser.parse(sample)
        let rule = parsed.networkRules.first { $0.urlFilter == "tracker\\.example" }

        XCTAssertEqual(rule?.resourceTypes.sorted(), ["image", "script"])
        XCTAssertEqual(rule?.loadTypes, ["third-party"])
        XCTAssertTrue(rule?.ifDomains.contains("*example.com") == true)
        XCTAssertTrue(rule?.unlessDomains.contains("*admin.example.com") == true)
    }

    func testParserDoesNotEmitWebKitUnsupportedDisjunctions() {
        let sample = """
        /waWQiOjE*=eyJ.js^
        """

        let parsed = AdBlockRuleParser.parse(sample)

        XCTAssertFalse(parsed.networkURLFilters.isEmpty)
        XCTAssertFalse(parsed.networkURLFilters.contains { $0.contains("|") })
        XCTAssertFalse(parsed.networkURLFilters.contains { $0.contains("([\\\\/:?&=]|$)") })
    }

    func testAdBlockServiceMergesCachedSubscriptionRules() throws {
        let defaults = UserDefaults.standard
        let key = "soulo_ad_block_subscription_rules"
        let oldData = defaults.data(forKey: key)
        defer {
            if let oldData {
                defaults.set(oldData, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let cached = ParsedAdBlockRules(
            networkURLFilters: ["ads\\.subscription\\.test"],
            cosmeticSelectors: [".subscription-ad"]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())

        XCTAssertTrue(json.contains("ads\\\\.subscription\\\\.test"))
        XCTAssertTrue(json.contains(".subscription-ad"))
    }

    @MainActor
    func testSubscriptionCacheMergePreservesStructuredConstraints() throws {
        let suiteName = "AdBlockSubscriptionServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let subscriptionsKey = "subscriptions"
        let cacheKey = "rules"
        let subscriptions = [
            AdBlockSubscription(
                id: "test",
                name: "Test",
                urlString: "https://example.com/list.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 1,
                cosmeticRuleCount: 1,
                errorMessage: ""
            )
        ]
        defaults.set(try JSONEncoder().encode(subscriptions), forKey: subscriptionsKey)
        let networkRule = AdBlockNetworkRule(
            urlFilter: "tracker\\.example",
            resourceTypes: ["script"],
            loadTypes: ["third-party"],
            ifDomains: ["*example.com"]
        )
        let cosmeticRule = AdBlockCosmeticRule(selector: ".sponsor", ifDomains: ["*example.com"])
        let stored = [
            "test": ParsedAdBlockRules(
                networkURLFilters: [networkRule.urlFilter],
                networkRules: [networkRule],
                cosmeticRules: [cosmeticRule]
            )
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: "\(cacheKey)_by_id")

        let service = AdBlockSubscriptionService(
            subscriptionsKey: subscriptionsKey,
            cachedRulesKey: cacheKey,
            versionKey: "version",
            autoUpdateCheckKey: "update",
            userDefaults: defaults
        )

        XCTAssertEqual(service.enabledRuleSummary.networkRules, [networkRule])
        XCTAssertEqual(service.enabledRuleSummary.cosmeticRules, [cosmeticRule])
    }
}

private final class SubscriptionTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((SubscriptionTestProtocol) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler(self)
    }
    override func stopLoading() {}

    func respond(body: String, mimeType: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mimeType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
