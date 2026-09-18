import XCTest
import WebKit
@testable import Soulo

final class AdBlockServiceTests: XCTestCase {
    private var savedBuiltInOverrides: Data?
    private var savedBuiltInRevision: String?
    private var savedSubscriptionCache: Data?
    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSubscriptionCache = defaults.data(forKey: "soulo_ad_block_subscription_rules")
        defaults.set(try? JSONEncoder().encode(ParsedAdBlockRules.empty), forKey: "soulo_ad_block_subscription_rules")
        savedBuiltInOverrides = defaults.data(forKey: BuiltInAdRuleStore.storageKey)
        savedBuiltInRevision = defaults.string(forKey: BuiltInAdRuleStore.versionKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.versionKey)
    }
    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.set(savedSubscriptionCache, forKey: "soulo_ad_block_subscription_rules")
        defaults.set(savedBuiltInOverrides, forKey: BuiltInAdRuleStore.storageKey)
        defaults.set(savedBuiltInRevision, forKey: BuiltInAdRuleStore.versionKey)
        super.tearDown()
    }

    func testLegacyImageBannerOverrideKeepsChoiceButNoLongerRevealsOnPicker() throws {
        let suite = "ImageBannerMigration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var rule = BuiltInAdRule(id: "paired-image-banner", kind: .cosmetic,
            pattern: ":root:not([data-soulo-ad-picker-active]) [data-soulo-image-banner]")
        rule.isEnabled = false
        rule.domains = ["example.com"]
        defaults.set(try JSONEncoder().encode([rule.id:rule]), forKey: BuiltInAdRuleStore.storageKey)
        let effective = try XCTUnwrap(BuiltInAdRuleStore.effectiveRules(defaults:defaults).first { $0.id == rule.id })
        XCTAssertEqual(effective.pattern, ManualAdBlockRuntime.imageBannerSelector)
        XCTAssertFalse(effective.isEnabled)
        XCTAssertEqual(effective.domains, rule.domains)
        rule.pattern = ".custom-ad"
        defaults.set(try JSONEncoder().encode([rule.id:rule]), forKey: BuiltInAdRuleStore.storageKey)
        XCTAssertEqual(BuiltInAdRuleStore.effectiveRules(defaults:defaults).first { $0.id == rule.id }?.pattern, ".custom-ad")
    }

    @MainActor
    func testBuiltInEditsPersistValidateAndReset() async throws {
        let suite = "BuiltInRulesTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuiltInAdRuleStore(defaults: defaults)
        var rule = try XCTUnwrap(store.rules.first { $0.id == "pbpbw:site-render" })
        let original = rule
        rule.pattern = "qa-tracker\\.example"
        rule.domains = ["news.example.com"]
        rule.isEnabled = false
        let saved = await store.save(rule)
        XCTAssertTrue(saved)
        XCTAssertEqual(BuiltInAdRuleStore(defaults: defaults).rules.first { $0.id == rule.id }, rule)
        XCTAssertNotEqual(BuiltInAdRuleStore.signature(defaults: defaults), "default")
        var invalid = rule
        invalid.resourceTypes = ["document"]
        let rejected = await store.save(invalid)
        XCTAssertFalse(rejected)
        XCTAssertEqual(store.rules.first { $0.id == rule.id }, rule)
        invalid = rule
        invalid.pattern = "["
        let invalidRegex = await store.save(invalid)
        XCTAssertFalse(invalidRegex)
        store.reset(rule.id)
        XCTAssertEqual(store.rules.first { $0.id == rule.id }, original)
        var cosmetic = try XCTUnwrap(store.rules.first { $0.kind == .cosmetic })
        cosmetic.pattern = ".qa-promotion"
        let cosmeticSaved = await store.save(cosmetic)
        XCTAssertTrue(cosmeticSaved)
        store.reset()
        XCTAssertEqual(store.rules, AdBlockService.defaultBuiltInRules)
        XCTAssertEqual(Set(store.rules.map(\.id)).count, store.rules.count)
        print("BUILT_IN_RULE_COUNT", store.rules.count)
    }

    @MainActor
    func testDisabledBuiltInRulesLeaveNativeAndScriptOutputs() async throws {
        let defaults = UserDefaults.standard
        let keys = [BuiltInAdRuleStore.storageKey, BuiltInAdRuleStore.versionKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        let store = BuiltInAdRuleStore(defaults: defaults)
        var rule = try XCTUnwrap(store.rules.first { $0.id == "pbpbw:site-render" })
        rule.isEnabled = false
        let disabled = await store.save(rule)
        XCTAssertTrue(disabled)
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        XCTAssertFalse(json.contains("site-render"))
        XCTAssertTrue(json.contains("site-config"))
        var cosmetic = try XCTUnwrap(store.rules.first { $0.kind == .cosmetic })
        cosmetic.pattern = ".unique-qa-sponsor"
        let edited = await store.save(cosmetic)
        XCTAssertTrue(edited)
        XCTAssertTrue(AdBlockService.encodedContentRuleList()!.contains("unique-qa-sponsor"))
        XCTAssertTrue(AdBlockService.adHidingScript(cosmetic: true).contains("unique-qa-sponsor"))
        cosmetic.isEnabled = false
        let hidden = await store.save(cosmetic)
        XCTAssertTrue(hidden)
        XCTAssertFalse(AdBlockService.encodedContentRuleList()!.contains("unique-qa-sponsor"))
        XCTAssertFalse(AdBlockService.adHidingScript(cosmetic: true).contains("unique-qa-sponsor"))
    }

    func testDomainRulesRequireActualHostAndPreserveEditedLegacyRules() throws {
        let rules = AdBlockService.defaultBuiltInRules
        let domains = rules.filter { $0.isEnabled && $0.id.hasPrefix("domain:") }
        for rule in domains {
            let regex = try NSRegularExpression(pattern: rule.pattern)
            for url in ["https://example.com/help?url=https://doubleclick.net/", "https://doubleclick.net.example.com/image.png", "https://notdoubleclick.net/image.png"] {
                XCTAssertNil(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), rule.id + " matched " + url)
            }
        }
        let rule = try XCTUnwrap(domains.first { $0.id == "domain:doubleclick\\.net" })
        for url in ["https://doubleclick.net/ad.js", "https://ad.doubleclick.net/ad.js"] {
            XCTAssertNotNil(url.range(of: rule.pattern, options: .regularExpression))
        }
        let suite = "ConservativeRuleDefaults-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var edited = try XCTUnwrap(rules.first { $0.id == "pattern:/gg/" })
        XCTAssertFalse(edited.isEnabled)
        edited.isEnabled = true
        edited.domains = ["chosen.example"]
        defaults.set(try JSONEncoder().encode([edited.id: edited]), forKey: BuiltInAdRuleStore.storageKey)
        XCTAssertEqual(BuiltInAdRuleStore.effectiveRules(defaults: defaults).first { $0.id == edited.id }, edited)
        print("CONSERVATIVE_RULE_DEFAULTS", rules.count, rules.filter(\.isEnabled).count)
    }

    func testProductionRuleCompilationFromBackgroundTask() async {
        let rules = await Task.detached {
            await AdBlockService.compileRuleLists(allowlistedHosts: ["soulo-test.example"])
        }.value
        XCTAssertNotNil(rules)
    }

    func testEncodedContentRulesAreValidAndContainBlockActions() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any] else { return false }
            return action["type"] as? String == "block"
        })
        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any] else { return false }
            return action["type"] as? String == "css-display-none"
        })
    }

    func testNetworkBlockRulesDoNotTargetMainDocuments() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        let blockRules = rules.filter { rule in
            (rule["action"] as? [String: Any])?["type"] as? String == "block"
        }

        XCTAssertFalse(blockRules.isEmpty)
        for rule in blockRules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let resourceTypes = try XCTUnwrap(trigger["resource-type"] as? [String])
            XCTAssertFalse(resourceTypes.contains("document"))
        }
    }

    func testEncodedContentRulesCompileWithWebKit() async throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let identifier = "SouloTests-\(UUID().uuidString)"

        _ = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        )
    }

    func testEncodedContentRulesSanitizeLegacyUnsupportedURLFilters() async throws {
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
            networkRules: [
                AdBlockNetworkRule(
                    urlFilter: #"/waWQiOjE.*=eyJ\.js([\\/:?&=]|$)"#,
                    resourceTypes: ["script"]
                )
            ]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())

        XCTAssertFalse(json.contains(#"([\\/:?&=]|$)"#))
        _ = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "SouloLegacyFilterTest-\(UUID().uuidString)",
            encodedContentRuleList: json
        )
    }

    func testEncodedContentRulesIncludeAllowlistDomains() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList(allowlistedHosts: ["www.example.com"]))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let firstTrigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let unlessDomain = try XCTUnwrap(firstTrigger["unless-domain"] as? [String])

        XCTAssertTrue(unlessDomain.contains("*example.com"))
        XCTAssertTrue(unlessDomain.contains("example.com"))
        XCTAssertTrue(unlessDomain.contains("*weixin.qq.com"))
        XCTAssertTrue(unlessDomain.contains("weixin.qq.com"))
    }

    func testEncodedContentRulesPreserveSupportedStructuredConditionsAndSkipUnsupportedMixedDomains() throws {
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
            networkURLFilters: ["tracker\\.example"],
            cosmeticSelectors: [],
            networkRules: [
                AdBlockNetworkRule(
                    urlFilter: "tracker\\.example",
                    resourceTypes: ["script"],
                    loadTypes: ["third-party"],
                    ifDomains: ["*example.com"],
                    unlessDomains: ["*admin.example.com"]
                ),
                AdBlockNetworkRule(
                    urlFilter: "scoped\\.example",
                    resourceTypes: ["script"],
                    loadTypes: ["third-party"],
                    ifDomains: ["*example.com"]
                )
            ],
            cosmeticRules: [
                AdBlockCosmeticRule(selector: ".site-ad", ifDomains: ["*example.com"])
            ]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]])

        XCTAssertFalse(rules.contains { rule in
            guard let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (trigger["url-filter"] as? String) == "tracker\\.example"
        })

        XCTAssertTrue(rules.contains { rule in
            guard let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (trigger["url-filter"] as? String) == "scoped\\.example"
                && (trigger["resource-type"] as? [String]) == ["script"]
                && (trigger["load-type"] as? [String]) == ["third-party"]
                && ((trigger["if-domain"] as? [String])?.contains("*example.com") == true)
                && trigger["unless-domain"] == nil
        })

        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any],
                  let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (action["type"] as? String) == "css-display-none"
                && (action["selector"] as? String) == ".site-ad"
                && ((trigger["if-domain"] as? [String])?.contains("*example.com") == true)
                && trigger["unless-domain"] == nil
        })

        for rule in rules {
            guard let trigger = rule["trigger"] as? [String: Any] else { continue }
            let domainConditionCount = ["if-domain", "unless-domain", "if-top-url", "unless-top-url"]
                .filter { trigger[$0] != nil }
                .count
            XCTAssertLessThanOrEqual(domainConditionCount, 1)
        }
    }

    func testBuiltInDefaultsRetainExplicitAdPatternsAndDisableWeakNames() throws {
        let rules = AdBlockService.defaultBuiltInRules
        for id in ["pattern:cpcad", "pattern:floatad", "pattern:popupad", "selector:#float-bottom-ad"] {
            XCTAssertEqual(rules.first { $0.id == id }?.isEnabled, true)
        }
        for id in ["pattern:gudingwei", "pattern:jioeidd", "pattern:adpic", "pattern:cqlkxq1wc", "selector:.gg"] {
            XCTAssertEqual(rules.first { $0.id == id }?.isEnabled, false)
        }
    }

    func testAdHidingScriptUsesExplicitAdSelectorsWithoutGenericPopupScanning() {
        let script = AdBlockService.adHidingScript(cosmetic: true)

        XCTAssertFalse(script.contains("isLikelyFloatingAd"))
        XCTAssertFalse(script.contains("div, section, aside, iframe, a, img"))
        XCTAssertTrue(script.contains("hideAdElement"))
        XCTAssertTrue(script.contains("isProtectedPageElement"))
        XCTAssertFalse(script.contains("el.remove()"))
        XCTAssertTrue(script.contains("adpic"))
        XCTAssertTrue(script.contains("adimg"))
        XCTAssertTrue(script.contains("floatad"))
    }

    func testAdHidingScriptChecksRuntimeAllowlist() {
        let script = AdBlockService.adHidingScript(
            cosmetic: true,
            allowlistedHosts: ["example.com"]
        )

        XCTAssertTrue(script.contains("souloAllowlistedHosts"))
        XCTAssertTrue(script.contains("isSouloAllowlisted"))
        XCTAssertTrue(script.contains("example.com"))
    }

    func testPBPBWAdLoadersAreScopedAndRespectSiteAllowlist() throws {
        func loaders(_ allowlist: [String]) throws -> [[String: Any]] {
            let json = try XCTUnwrap(AdBlockService.encodedContentRuleList(allowlistedHosts: allowlist))
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            return rules.compactMap { $0["trigger"] as? [String: Any] }
                .filter { ($0["url-filter"] as? String)?.contains("/assets/chunks/site-") == true }
        }
        let rules = try loaders([])
        XCTAssertEqual(rules.count, 2)
        for rule in rules {
            XCTAssertEqual(rule["if-domain"] as? [String], ["*pbpbw.com"])
            XCTAssertEqual(rule["resource-type"] as? [String], ["script"])
            let filter = try XCTUnwrap(rule["url-filter"] as? String)
            XCTAssertNotNil("https://www.pbpbw.com/assets/chunks/\(filter.contains("site-render") ? "site-render" : "site-config").js?v=2".range(of: filter, options: .regularExpression))
        }
        XCTAssertTrue(try loaders(["www.pbpbw.com"]).isEmpty)
    }
}
