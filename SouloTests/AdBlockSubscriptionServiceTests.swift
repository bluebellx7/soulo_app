import XCTest
import WebKit
@testable import Soulo

final class AdBlockSubscriptionServiceTests: XCTestCase {
    @MainActor
    func testLargeSubscriptionArchiveMigratesWithoutLosingRulesOrSettings() throws {
        let suite = "SubscriptionArchive.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let archive = directory.appendingPathComponent("rules.json")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let rules = AdBlockRuleParser.parse("||ads.example.com^\nexample.com##.advert")
        let key = "soulo_ad_block_subscription_rules_by_id"
        defaults.set(try JSONEncoder().encode(["easylist": rules]), forKey: key)
        defaults.set(false, forKey: BrowserAutomaticNavigationPolicy.preferenceKey)
        let service = AdBlockSubscriptionService(userDefaults: defaults, rulesArchiveURL: archive)
        XCTAssertNil(defaults.data(forKey: key))
        let saved = try JSONDecoder().decode([String: ParsedAdBlockRules].self, from: Data(contentsOf: archive))
        XCTAssertEqual(saved["easylist"], rules)
        XCTAssertEqual(service.enabledRuleSummary.networkRules, rules.networkRules)
        XCTAssertFalse(defaults.bool(forKey: BrowserAutomaticNavigationPolicy.preferenceKey))
        let restored = AdBlockSubscriptionService(userDefaults: defaults, rulesArchiveURL: archive)
        XCTAssertEqual(restored.enabledRuleSummary, service.enabledRuleSummary)
        let subscription = try XCTUnwrap(restored.subscriptions.first { $0.id == "easylist" })
        restored.setEnabled(false, for: subscription)
        XCTAssertEqual(AdBlockSubscriptionService(userDefaults: defaults, rulesArchiveURL: archive).enabledRuleSummary, .empty)
        restored.setEnabled(true, for: subscription)
        XCTAssertEqual(restored.enabledRuleSummary.networkRules, rules.networkRules)
    }

    @MainActor
    func testFailedArchiveMigrationKeepsLegacyRules() throws {
        let suite = "SubscriptionArchiveFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try Data("file blocks directory creation".utf8).write(to: blocker)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: blocker) }
        let rules = AdBlockRuleParser.parse("||ads.example.com^")
        let key = "soulo_ad_block_subscription_rules_by_id"
        let data = try JSONEncoder().encode(["easylist": rules])
        defaults.set(data, forKey: key)
        let service = AdBlockSubscriptionService(userDefaults: defaults, rulesArchiveURL: blocker.appendingPathComponent("rules.json"))
        XCTAssertEqual(defaults.data(forKey: key), data)
        XCTAssertEqual(service.enabledRuleSummary.networkRules, rules.networkRules)
        XCTAssertFalse(service.lastError.isEmpty)
    }

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

    func testAnchorsPathsSeparatorsAndCaseArePreserved() throws {
        func matches(_ filter: String, _ url: String) throws -> Bool {
            try AdBlockRuleParser.parse(filter).networkRules.contains { rule in
                let regex = try NSRegularExpression(pattern: rule.urlFilter, options: rule.caseSensitive ? [] : [.caseInsensitive])
                return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            }
        }
        XCTAssertTrue(try matches("||cdn.example.com/promo.js^", "https://a.cdn.example.com/promo.js?v=1"))
        XCTAssertTrue(try matches("||cdn.example.com/promo.js^", "https://cdn.example.com/promo.js"))
        for url in ["https://cdn.example.com/player.js", "https://notcdn.example.com/promo.js",
                    "https://cdn.example.com.evil.test/promo.js", "https://normal.test/?url=https://cdn.example.com/promo.js",
                    "https://cdn.example.com/promo.json", "https://cdn.example.com/promo.js_extra"] {
            XCTAssertFalse(try matches("||cdn.example.com/promo.js^", url), url)
        }
        XCTAssertTrue(try matches("|https://example.com/exact|", "https://example.com/exact"))
        XCTAssertFalse(try matches("|https://example.com/exact|", "https://example.com/exact/more"))
        XCTAssertFalse(try matches("|https://example.com/exact|", "https://other.test/https://example.com/exact"))
        XCTAssertFalse(try matches("/Promo.js$match-case", "https://example.com/promo.js"))
        XCTAssertTrue(try matches("/Promo.js", "https://example.com/promo.js"))
    }

    func testExceptionsAndNegativeTypesSurviveRoundTrip() throws {
        let parsed = AdBlockRuleParser.parse("""
        ||example.com/file$~image,~stylesheet
        @@||example.com/allowed$script,domain=news.example.com|~private.news.example.com
        ##.sponsor
        www.example.com#@#.sponsor
        """)
        let block = try XCTUnwrap(parsed.networkRules.first { !$0.isException })
        XCTAssertFalse(block.resourceTypes.contains("image"))
        XCTAssertFalse(block.resourceTypes.contains("style-sheet"))
        XCTAssertTrue(block.resourceTypes.contains("script"))
        let exception = try XCTUnwrap(parsed.networkRules.first { $0.isException })
        XCTAssertEqual(exception.resourceTypes, ["script"])
        XCTAssertEqual(exception.ifDomains, ["*news.example.com"])
        XCTAssertEqual(exception.unlessDomains, ["*private.news.example.com"])
        XCTAssertEqual(parsed.cosmeticExceptions.first?.ifDomains, ["*www.example.com"])
        XCTAssertEqual(try JSONDecoder().decode(ParsedAdBlockRules.self, from: JSONEncoder().encode(parsed)), parsed)
    }

    func testUnknownConstraintsCannotBecomeBroadBlockingRules() {
        for line in ["||example.com^$unknown", "||example.com^$redirect=noopjs", "||example.com^$script,~script",
                     "||example.com^$domain=example.*", "example.*##.ad", "||example.com^$domain=",
                     "||example.com^$subdocument", "||example.com^$document", "||example.com^$third-party,~third-party"] {
            let rules = AdBlockRuleParser.parse(line)
            XCTAssertTrue(rules.networkRules.isEmpty && rules.cosmeticRules.isEmpty, line)
        }
        let conditional = AdBlockRuleParser.parse("!#if unknown\n||example.com^\n!#else\n##.advert\n!#endif\n##.valid")
        XCTAssertTrue(conditional.networkRules.isEmpty)
        XCTAssertEqual(conditional.cosmeticSelectors, [".valid"])
    }

    @MainActor
    func testLargeListsAndCrossSubscriptionExceptionsAreNotTruncated() throws {
        let suite = "CompleteRules.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let text = (0..<5_100).map { "||assets.example.com/file\($0).js|" }.joined(separator: "\n")
            + "\n" + (0..<2_100).map { "##.promotion-\($0)" }.joined(separator: "\n")
        let blocks = AdBlockRuleParser.parse(text)
        let exceptions = AdBlockRuleParser.parse("@@||assets.example.com/file5099.js|\nexample.com#@#.promotion-2099")
        XCTAssertEqual(blocks.networkRules.count, 5_100)
        XCTAssertEqual(blocks.cosmeticRules.count, 2_100)
        defaults.set(try JSONEncoder().encode(["easylist": blocks, "easylist-china": exceptions]), forKey: "soulo_ad_block_subscription_rules_by_id")
        let service = AdBlockSubscriptionService(userDefaults: defaults)
        XCTAssertEqual(service.enabledRuleSummary.networkRules.count, 5_101)
        XCTAssertEqual(service.enabledRuleSummary.cosmeticRules.count, 2_100)
        XCTAssertEqual(service.enabledRuleSummary.cosmeticExceptions, exceptions.cosmeticExceptions)
    }

    @MainActor
    func testOldBroadRulesAreInvalidatedAndScheduledForRefresh() throws {
        let suite = "OldParser.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = AdBlockRuleParser.parse("||example.com^")
        old.parserVersion = 0
        defaults.set(try JSONEncoder().encode(["easylist": old]), forKey: "soulo_ad_block_subscription_rules_by_id")
        defaults.set(try JSONEncoder().encode(old), forKey: "soulo_ad_block_subscription_rules")
        defaults.set(Date().timeIntervalSince1970, forKey: "soulo_ad_block_subscription_auto_update_check")
        let service = AdBlockSubscriptionService(userDefaults: defaults)
        XCTAssertEqual(service.enabledRuleSummary, .empty)
        XCTAssertNil(defaults.object(forKey: "soulo_ad_block_subscription_auto_update_check"))
        XCTAssertEqual(service.subscriptions.first?.networkRuleCount, 0)
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

        XCTAssertTrue(parsed.networkURLFilters.contains { $0.contains("ads\\.example\\.com") })
        XCTAssertTrue(parsed.networkURLFilters.contains { $0.hasSuffix("cpcad\\.js") })
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
        let rule = parsed.networkRules.first { $0.urlFilter.contains("tracker\\.example") }

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
