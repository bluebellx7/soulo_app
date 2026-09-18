import WebKit

struct AdBlockService {

    static var defaultBuiltInRules: [BuiltInAdRule] {
        let adDomains = [
            // Google Ads
            "googlesyndication\\.com", "googleadservices\\.com", "googleads\\.g\\.doubleclick\\.net",
            "pagead2\\.googlesyndication\\.com", "adservice\\.google\\.com",
            "doubleclick\\.net", "tpc\\.googlesyndication\\.com",
            // Facebook / Meta
            "facebook\\.com/tr", "connect\\.facebook\\.net.*fbevents",
            // Baidu Ads
            "cpro\\.baidustatic\\.com", "pos\\.baidu\\.com", "hm\\.baidu\\.com",
            "cpro\\.baidu\\.com", "eclick\\.baidu\\.com", "baidustatic\\.com/cpro",
            // Alibaba Ads
            "tanx\\.com", "mmstat\\.com", "atanx\\.alicdn\\.com",
            // Sina / Weibo
            "ad\\.sina\\.com\\.cn", "beacon\\.sina\\.com\\.cn",
            // Amazon
            "mads\\.amazon\\.com", "aax-.*\\.amazon\\.com",
            // Yahoo
            "ads\\.yahoo\\.com", "adtech\\.de",
            // Major ad networks
            "adnxs\\.com", "adsrvr\\.org", "serving-sys\\.com",
            "moatads\\.com", "outbrain\\.com", "taboola\\.com",
            "criteo\\.com", "pubmatic\\.com", "rubiconproject\\.com",
            "openx\\.net", "carbonads\\.com", "buysellads\\.com",
            "adroll\\.com", "googletag\\.cmd", "securepubads",
            // Analytics / Tracking
            "analytics\\.tiktok\\.com", "ads-api\\.tiktok\\.com",
            "hotjar\\.com", "clarity\\.ms", "mouseflow\\.com",
            // Chinese ad networks
            "union\\.bytedance\\.com", "ad\\.oceanengine\\.com",
            "e\\.qq\\.com", "gdt\\.qq\\.com", "mi\\.gdt\\.qq\\.com",
            "c\\.cnzz\\.com", "s\\.cnzz\\.com",
            // Popup / overlay ads
            "popads\\.net", "popcash\\.net", "propellerads\\.com",
            "adform\\.net", "adzerk\\.net", "adition\\.com", "yieldmo\\.com",
            "media\\.net", "lijit\\.com", "sovrn\\.com", "sharethrough\\.com",
            "smartadserver\\.com", "adsafeprotected\\.com", "zedo\\.com",
            "scorecardresearch\\.com", "quantserve\\.com", "amazon-adsystem\\.com",
            "ads-twitter\\.com", "ads\\.linkedin\\.com", "bat\\.bing\\.com",
            "ad\\.doubleclick\\.net", "partner\\.googleadservices\\.com",
            "imasdk\\.googleapis\\.com", "google-analytics\\.com", "googletagmanager\\.com/gtag/js",
            "static\\.doubleclick\\.net", "fls\\.doubleclick\\.net", "adservice\\.google\\.",
            "ads\\.pubmatic\\.com", "pixel\\.rubiconproject\\.com", "fastlane\\.rubiconproject\\.com",
            "ib\\.adnxs\\.com", "secure\\.adnxs\\.com", "sync\\.outbrain\\.com",
            "trc\\.taboola\\.com", "cdn\\.taboola\\.com", "analytics\\.google\\.com",
        ]
        let adPatterns = [
            "/ads/", "/adserver", "/adclick", "/adview",
            "adsense", "adsbygoogle", "/pagead/",
            "doubleclick\\.net", "/ad\\.js", "/ads\\.js",
            "/advert/", "/advertising/", "/sponsor/", "/sponsored/",
            "\\?ad=", "&ad=", "\\?ads=", "&ads=",
            "\\?adid=", "&adid=", "\\?adunit=", "&adunit=",
            "\\?adslot=", "&adslot=",
            "/prebid", "prebid\\.js", "gpt\\.js", "pubads_impl",
            "/cpcad", "cpcad", "gudingwei", "jioeidd", "cqlkxq1wc",
            "/union/", "/tuiguang/", "/gg/", "/gg\\.js", "/adver",
            "/adpic", "adpic", "adimg", "/adimg/", "/adsimg/", "/adv/",
            "/adfile/", "/ad_code/", "/adcode/", "/adstatic/", "/adverts/",
            "/adsystem/", "adbanner", "ad_banner", "floatad", "float_ad",
            "popupad", "popup_ad", "rightad", "leftad", "topad", "bottomad",
        ]
        let resources = ["script", "image", "style-sheet", "font", "media", "raw", "popup"]
        var rules = adDomains.map { BuiltInAdRule(id: "domain:" + $0, kind: .network, pattern: $0, resourceTypes: resources) }
        rules += adPatterns.map { BuiltInAdRule(id: "pattern:" + $0, kind: .network, pattern: $0, resourceTypes: ["script", "image", "raw"]) }
        for name in ["site-render", "site-config"] {
            rules.append(BuiltInAdRule(id: "pbpbw:" + name, kind: .network,
                pattern: "^https?://[^/]+/assets/chunks/\(name)\\.js([?].*)?$", domains: ["pbpbw.com"], resourceTypes: ["script"]))
        }
        let selectors = [
            ".adsbygoogle",
            "ins.adsbygoogle",
            "[id^='div-gpt-ad']",
            "[id*='google_ads']",
            "[data-ad-slot]",
            "[data-ad-position]",
            "[class*='taboola']",
            "[class*='outbrain']",
            "iframe[src*='doubleclick']",
            "iframe[src*='googlesyndication']",
            "[aria-label*='advertisement' i]",
            "[aria-label*='广告']",
            "[class*='banner-ad']",
            "[class*='sticky-ad']",
            "[class*='popup-ad']",
            ".cpcad",
            ".pcad",
            ".adpic",
            ".adpicbox",
            ".gg",
            "[class*=' cpcad']",
            "[class*='gudingwei']",
            "[id*='gudingwei']",
            "[class*='jioeidd']",
            "[id*='jioeidd']",
            "[class*='cqlkxq1wc']",
            "[id*='cqlkxq1wc']",
            "#float-bottom-ad",
            "[class*='floatad']",
            "[id*='floatad']",
            "[class*='popupad']",
            "[id*='popupad']",
            "div[id^=\"div-gpt-ad\"]",
            "iframe[src*=\"doubleclick\"]",
            "iframe[src*=\"googlesyndication\"]",
            "iframe[src*=\"ads.\"]",
            "[id*=\"google_ads\"]",
            "div[class*=\"ad-container\"]",
            "div[class*=\"ad-wrapper\"]",
            "[class*=\"outbrain-widget\"]",
            "[class*=\"taboola\"]",
            "div[id*=\"ad-\"]",
            "div[data-ad]",
            "#content_right .result-op[data-click]",
            ".ec_tuiguang_pplink",
            "[class*=\" cpcad\"]",
            "[class^=\"gg-\"]",
            "[class*=\"-gg\"]",
            "[id^=\"gg\"]",
            "[class*=\"广告\"]",
            "[id*=\"广告\"]",
            "[class*=\"gudingwei\"]",
            "[id*=\"gudingwei\"]",
            "[class*=\"jioeidd\"]",
            "[id*=\"jioeidd\"]",
            "[class*=\"cqlkxq1wc\"]",
            "[id*=\"cqlkxq1wc\"]",
            "[class*=\"tuiguang\"]",
            "[id*=\"tuiguang\"]",
            "[class*=\"floatad\"]",
            "[id*=\"floatad\"]",
            "[class*=\"popupad\"]",
            "[id*=\"popupad\"]",
            "[class*=\"adpic\"]",
            "[id*=\"adpic\"]",
            "[class*=\"adimg\"]",
            "[id*=\"adimg\"]",
            "[class*=\"adsbygoogle\"]",
            "[id*=\"div-gpt-ad\"]",
            "div[data-ad-slot]",
            "iframe[src*=\"adserver\"]",
            ".ec_tuiguang_pptitle",
            "[class*=\"s_side_ad\"]",
            "[class*=\"ec_wise_ad\"]",
            "#ec_im_container",
            ".ec-result-container",
            "[class*=\"outbrain\"]",
            "[aria-label*=\"advertisement\" i]",
            "[aria-label*=\"广告\"]",
            "[class*=\"popup-ad\"]",
            "[class*=\"overlay-ad\"]",
            "[id*=\"popup-ad\"]",
            "[class*=\"floating-ad\"]",
            "[class*=\"sticky-ad\"]",

        ]
        rules += selectors.map { BuiltInAdRule(id: "selector:" + $0, kind: .cosmetic, pattern: $0) }
        rules.append(BuiltInAdRule(id: "tiled-bottom-banner", kind: .tiledBanner, pattern: ""))
        rules.append(BuiltInAdRule(id: "paired-image-banner", kind: .cosmetic, pattern: ManualAdBlockRuntime.imageBannerSelector))
        return rules.map(conservativeDefault)
    }

    // Keep stable IDs so explicitly edited rules survive default revisions.
    // Ambiguous legacy rules remain visible/editable, but no longer run by default.
    private static func conservativeDefault(_ original: BuiltInAdRule) -> BuiltInAdRule {
        var rule = original
        if rule.id.hasPrefix("domain:") {
            let ambiguous = ["googletag\\.cmd", "securepubads", "adservice\\.google\\."]
            if ambiguous.contains(rule.pattern) {
                rule.isEnabled = false
            } else if rule.pattern == "connect\\.facebook\\.net.*fbevents" {
                rule.pattern = #"^https?://connect\.facebook\.net/[^?]*fbevents\.js([?]|$)"#
            } else {
                let parts = rule.pattern.split(separator: "/", maxSplits: 1).map(String.init)
                let host = parts[0].replacingOccurrences(of: "aax-.*", with: "aax-[a-z0-9-]+")
                rule.pattern = #"^https?://([a-z0-9-]+\.)*"# + host
                rule.pattern += parts.count == 1 ? #"(:[0-9]+)?/"# : "/" + parts[1] + #"([/?]|$)"#
            }
        } else if rule.id.hasPrefix("pattern:") {
            let ambiguous: Set<String> = [
                "/sponsor/", "/sponsored/", "/union/", "/tuiguang/", "/gg/", "/gg\\.js", "/adver",
                "/adpic", "adpic", "adimg", "/adimg/", "/adsimg/", "/adv/", "gpt\\.js",
                "gudingwei", "jioeidd", "cqlkxq1wc", "rightad", "leftad", "topad", "bottomad"
            ]
            if ambiguous.contains(rule.pattern) || rule.pattern.hasPrefix("\\?") || rule.pattern.hasPrefix("&") {
                rule.isEnabled = false
            } else if rule.pattern == "doubleclick\\.net" {
                rule.pattern = #"^https?://([a-z0-9-]+\.)*doubleclick\.net(:[0-9]+)?/"#
            } else {
                let component = rule.pattern.hasPrefix("/") ? String(rule.pattern.dropFirst()) : rule.pattern
                rule.pattern = #"^https?://[^/]+/([^?#]*/)?"# + component
                if !component.hasSuffix("/") {
                    rule.pattern += component.hasSuffix("\\.js") ? #"([?]|$)"# : #"([/._?-]|$)"#
                }
            }
        } else if rule.kind == .cosmetic {
            // "div[id*=ad-]" also matches "download-panel"; gg is a common
            // icon prefix. These need site-specific evidence before enabling.
            let ambiguous: Set<String> = [
                ".gg", ".adpic", ".adpicbox", "div[id*=\"ad-\"]", "iframe[src*=\"ads.\"]",
                "[class^=\"gg-\"]", "[class*=\"-gg\"]", "[id^=\"gg\"]"
            ]
            let weakNames = ["gudingwei", "jioeidd", "cqlkxq1wc", "tuiguang", "adpic", "adimg"]
            if ambiguous.contains(rule.pattern) || weakNames.contains(where: { rule.pattern.contains($0) && rule.pattern.contains("*=") }) {
                rule.isEnabled = false
            } else if rule.pattern.contains("[class*=") {
                // Match complete class tokens rather than substrings such as
                // "not-popup-ad" or "taboola-settings".
                rule.pattern = rule.pattern.replacingOccurrences(of: "[class*=", with: "[class~=")
                    .replacingOccurrences(of: "' cpcad'", with: "'cpcad'")
                    .replacingOccurrences(of: "\" cpcad\"", with: "\"cpcad\"")
            } else if rule.pattern.contains("[id*=") && !rule.pattern.contains("google_ads") && !rule.pattern.contains("div-gpt-ad") {
                rule.pattern = rule.pattern.replacingOccurrences(of: "[id*=", with: "[id=")
            } else if rule.pattern.contains("iframe[src*=") {
                if rule.pattern.contains("doubleclick") {
                    rule.pattern = #"iframe:is([src^="https://doubleclick.net/"],[src^="https://ad.doubleclick.net/"],[src^="https://googleads.g.doubleclick.net/"])"#
                } else if rule.pattern.contains("googlesyndication") {
                    rule.pattern = #"iframe:is([src^="https://googlesyndication.com/"],[src^="https://tpc.googlesyndication.com/"],[src^="https://pagead2.googlesyndication.com/"])"#
                } else {
                    rule.isEnabled = false
                }
            }
            if ["#content_right .result-op[data-click]", ".ec_tuiguang_pplink", ".ec_tuiguang_pptitle", "#ec_im_container", ".ec-result-container"].contains(original.pattern)
                || original.pattern.contains("s_side_ad") || original.pattern.contains("ec_wise_ad") {
                rule.domains = ["baidu.com"]
            }
        }
        return rule
    }

    // MARK: - Content Rule List (blocks network requests to ad domains)

    // Each network batch carries the full exception set: an exception in one
    // WKContentRuleList cannot undo a block in another list.
    private static func contentRuleBatches(allowlistedHosts: [String], batchSize: Int) -> [[[String: Any]]] {
        let rules = contentRules(allowlistedHosts: allowlistedHosts)
        func action(_ rule: [String: Any]) -> String { (rule["action"] as? [String: Any])?["type"] as? String ?? "" }
        let exceptions = rules.filter { action($0) == "ignore-previous-rules" }
        let blocks = rules.filter { action($0) == "block" }
        let cosmetic = rules.filter { action($0) == "css-display-none" }
        var batches: [[[String: Any]]] = []
        for group in [blocks, cosmetic] {
            for start in stride(from: 0, to: group.count, by: max(1, batchSize)) {
                var batch = Array(group[start..<min(start + max(1, batchSize), group.count)])
                if action(batch[0]) == "block" {
                    batch += exceptions.filter { ($0["trigger"] as? [String: Any])?["resource-type"] as? [String] != ["document"] }
                } else {
                    batch += exceptions.filter { ($0["trigger"] as? [String: Any])?["if-top-url"] != nil }
                }
                batches.append(batch)
            }
        }
        return batches
    }

    static func encodedContentRuleLists(allowlistedHosts: [String] = [], batchSize: Int = 20_000) -> [String] {
        contentRuleBatches(allowlistedHosts: allowlistedHosts, batchSize: batchSize).compactMap(encodeRules)
    }

    private static func encodeRules(_ rules: [[String: Any]]) -> String? {
        (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func compileRuleLists(allowlistedHosts: [String] = []) async -> [WKContentRuleList]? {
        var compiled: [WKContentRuleList] = []
        // Encode only the current batch; do not retain every large JSON string.
        for batch in contentRuleBatches(allowlistedHosts: allowlistedHosts, batchSize: 20_000) {
            guard let json = encodeRules(batch) else { return nil }
            let identifier = "SouloAdBlockV6-\(stableIdentifierHash(json))"
            guard let list = await compileContentRules(identifier: identifier, json: json) else { return nil }
            compiled.append(list)
        }
        return compiled
    }

    @MainActor
    private static func compileContentRules(identifier: String, json: String) async -> WKContentRuleList? {
        // WebKit parses CSS selectors synchronously before dispatching compilation.
        // Keep its initialization on the main actor; JSON preparation stays off it.
        let cached: WKContentRuleList? = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
        if let cached { return cached }
        return await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { ruleList, error in
                if let error { NSLog("Ad block compilation failed: %@", error.localizedDescription) }
                continuation.resume(returning: ruleList)
            }
        }
    }

    static func encodedContentRuleList(allowlistedHosts: [String] = []) -> String? {
        encodeRules(contentRules(allowlistedHosts: allowlistedHosts))
    }

    private static func contentRules(allowlistedHosts: [String]) -> [[String: Any]] {
        let excludedDomains = normalizedAllowlist(allowlistedHosts)
            .flatMap { ["*\($0)", $0] }
        let defaultBlockedResourceTypes = ["script", "image", "style-sheet", "font", "media", "raw", "popup"]

        func trigger(_ urlFilter: String, resourceTypes: [String]? = nil) -> [String: Any] {
            var value: [String: Any] = ["url-filter": urlFilter]
            if let resourceTypes {
                value["resource-type"] = resourceTypes
            }
            if !excludedDomains.isEmpty {
                value["unless-domain"] = excludedDomains
            }
            return value
        }

        func overlapsGlobalExclusion(_ domain: String) -> Bool {
            let root = domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "*."))
                .lowercased()
            guard !root.isEmpty else { return true }
            return excludedDomains.contains { excluded in
                let excludedRoot = excluded
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*."))
                    .lowercased()
                return root == excludedRoot
                    || root.hasSuffix(".\(excludedRoot)")
                    || excludedRoot.hasSuffix(".\(root)")
            }
        }

        func trigger(for rule: AdBlockNetworkRule) -> [String: Any]? {
            guard let urlFilter = sanitizedContentBlockerURLFilter(rule.urlFilter) else { return nil }
            if rule.isException && rule.exceptionScope != "network" {
                guard rule.exceptionScope != "generichide" else { return nil }
                var value: [String: Any] = ["url-filter": ".*", "if-top-url": [urlFilter]]
                if rule.exceptionScope == "elemhide" { value["resource-type"] = ["document"] }
                return value
            }
            let resourceTypes = rule.resourceTypes.filter { $0 != "document" }
            // WebKit permits only one domain/top-URL condition. Retain positive
            // branches only when their full subtree is outside every exclusion;
            // never broaden a mixed condition by dropping its exclusions.
            var value: [String: Any] = [
                "url-filter": urlFilter,
                "resource-type": resourceTypes.isEmpty ? defaultBlockedResourceTypes : resourceTypes
            ]
            if rule.caseSensitive { value["url-filter-is-case-sensitive"] = true }
            if !rule.loadTypes.isEmpty {
                value["load-type"] = rule.loadTypes
            }
            if !rule.ifDomains.isEmpty {
                let filteredDomains = rule.ifDomains.filter { domain in
                    guard !overlapsGlobalExclusion(domain) else { return false }
                    let root = domain.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
                    return !rule.unlessDomains.contains { excluded in
                        let other = excluded.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
                        return root == other || root.hasSuffix("." + other) || other.hasSuffix("." + root)
                    }
                }
                guard !filteredDomains.isEmpty else { return nil }
                value["if-domain"] = filteredDomains
            } else {
                let domains = Set(excludedDomains).union(rule.unlessDomains)
                if !domains.isEmpty {
                    value["unless-domain"] = Array(domains).sorted()
                }
            }
            return value
        }

        let builtInRules = BuiltInAdRuleStore.effectiveRules().filter(\.isEnabled)
        var rulesArray: [[String: Any]] = []
        for rule in builtInRules where rule.kind == .network {
            if let value = trigger(for: rule.networkRule) {
                rulesArray.append(["trigger": value, "action": ["type": "block"]])
            }
        }

        let cachedRules = AdBlockSubscriptionService.cachedRules()
        let structuredNetworkRules = cachedRules.networkRules.isEmpty
            ? cachedRules.networkURLFilters.map {
                AdBlockNetworkRule(urlFilter: $0, resourceTypes: ["script", "image", "raw", "popup"])
            }
            : cachedRules.networkRules

        for networkRule in structuredNetworkRules {
            guard let networkTrigger = trigger(for: networkRule) else { continue }
            rulesArray.append([
                "trigger": networkTrigger,
                "action": ["type": networkRule.isException ? "ignore-previous-rules" : "block"]
            ])
        }
        // Exceptions must follow every block, including blocks from later subscriptions.
        let exceptions = rulesArray.filter { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" }
        rulesArray.removeAll { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" }

        // Selectors with exceptions are resolved by the DOM layer per frame.
        // A blanket native hide would defeat that exception before JS can act.
        let exceptionSelectors = Set(cachedRules.cosmeticExceptions.map(\.selector))
        let hasGenericExceptions = cachedRules.networkRules.contains { $0.exceptionScope == "generichide" }
        let cosmeticRules = (cachedRules.cosmeticRules + builtInRules.filter { $0.kind == .cosmetic }.map(\.cosmeticRule))
            .filter { !exceptionSelectors.contains($0.selector) && !(hasGenericExceptions && $0.ifDomains.isEmpty) }
        var hideSelectors: [String] = []

        hideSelectors.append(
            contentsOf: cosmeticRules
                .filter { $0.ifDomains.isEmpty && $0.unlessDomains.isEmpty }
                .compactMap { sanitizedContentBlockerSelector($0.selector) }
        )
        hideSelectors = hideSelectors.compactMap { sanitizedContentBlockerSelector($0) }
        for selectorGroup in chunkedSelectors(hideSelectors) {
            rulesArray.append([
                "trigger": trigger(".*"),
                "action": ["type": "css-display-none", "selector": selectorGroup.joined(separator: ",")]
            ])
        }

        for cosmeticRule in cosmeticRules where !cosmeticRule.ifDomains.isEmpty || !cosmeticRule.unlessDomains.isEmpty {
            guard let selector = sanitizedContentBlockerSelector(cosmeticRule.selector) else { continue }
            // As above, leave mixed positive/negative domain rules to the JS
            // cosmetic engine so one unsupported trigger cannot disable all rules.
            guard cosmeticRule.ifDomains.isEmpty || cosmeticRule.unlessDomains.isEmpty else { continue }
            var cosmeticTrigger: [String: Any] = ["url-filter": ".*"]
            if !cosmeticRule.ifDomains.isEmpty {
                let filteredDomains = cosmeticRule.ifDomains.filter { !overlapsGlobalExclusion($0) }
                guard !filteredDomains.isEmpty else { continue }
                cosmeticTrigger["if-domain"] = filteredDomains
            } else {
                let domains = Set(excludedDomains).union(cosmeticRule.unlessDomains)
                if !domains.isEmpty {
                    cosmeticTrigger["unless-domain"] = Array(domains).sorted()
                }
            }
            rulesArray.append([
                "trigger": cosmeticTrigger,
                "action": ["type": "css-display-none", "selector": selector]
            ])
        }

        rulesArray += exceptions
        return rulesArray
    }

    private static func normalizedAllowlist(_ hosts: [String]) -> [String] {
        WebCompatibilityService.protectionBypassHosts(adding: hosts)
    }

    static func sanitizedContentBlockerURLFilter(_ value: String) -> String? {
        let filter = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !filter.isEmpty,
              filter.count <= 1_024,
              filter.unicodeScalars.allSatisfy({ $0.isASCII }),
              !filter.contains("|"),
              !filter.contains("(?"),
              !filter.contains("(?<"),
              !filter.contains("\\1"),
              !filter.contains("\\2")
        else {
            return nil
        }
        return filter
    }

    static func sanitizedContentBlockerSelector(_ value: String) -> String? {
        let selector = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = selector.lowercased()
        guard !selector.isEmpty,
              selector.count <= 240,
              !selector.contains("{"),
              !selector.contains("}"),
              !selector.contains("<"),
              !selector.contains(">"),
              !selector.contains("`"),
              !lowercased.contains(":-abp-"),
              !lowercased.contains(":contains"),
              !lowercased.contains(":matches-css"),
              !lowercased.contains(":xpath"),
              !lowercased.contains(":upward"),
              !lowercased.contains(":remove"),
              !lowercased.contains("+js(")
        else {
            return nil
        }

        let rootPatterns = [
            #"(?i)^\s*(html|body|main|article)\b"#,
            #"(?i)^\s*#(app|root|__next|__nuxt|main|content|page|container)\b"#,
            #"(?i)^\s*\[role=['"]?main['"]?\]"#
        ]
        guard !rootPatterns.contains(where: { selector.range(of: $0, options: .regularExpression) != nil }) else {
            return nil
        }
        return selector
    }

    private static func stableIdentifierHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func chunkedSelectors(_ selectors: [String], chunkSize: Int = 80) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []

        for selector in selectors where !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.append(selector)
            if current.count >= chunkSize {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    // MARK: - CSS + JS injection to hide ad elements

    private static let hidingScriptCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2
        return cache
    }()

    static func adHidingScript(cosmetic: Bool = true, allowlistedHosts: [String] = []) -> String {
        // Legacy/in-memory rule overrides have no file revision; do not cache them.
        let usesArchive = UserDefaults.standard.data(forKey: "soulo_ad_block_subscription_rules") == nil
        let cacheKey = "\(cosmetic)|\(normalizedAllowlist(allowlistedHosts).joined(separator: ","))|\(AdBlockSubscriptionService.rulesSignature())|\(BuiltInAdRuleStore.signature())" as NSString
        if usesArchive, let cached = hidingScriptCache.object(forKey: cacheKey) { return cached as String }
        let cachedRules = AdBlockSubscriptionService.cachedRules()
        let builtInRules = BuiltInAdRuleStore.effectiveRules().filter(\.isEnabled)
        let subscriptionRules = cachedRules.cosmeticRules.isEmpty
            ? cachedRules.cosmeticSelectors.map { AdBlockCosmeticRule(selector: $0) }
            : cachedRules.cosmeticRules
        let cosmeticRules = subscriptionRules + builtInRules.filter { $0.kind == .cosmetic }.map(\.cosmeticRule)
        let cosmeticPayload = cosmeticRules.map { rule in
            [
                "selector": rule.selector,
                "ifDomains": rule.ifDomains,
                "unlessDomains": rule.unlessDomains
            ] as [String: Any]
        }
        let subscriptionCosmeticRulesJSON = (try? JSONSerialization.data(withJSONObject: cosmeticPayload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let pageExceptionsJSON = (try? JSONEncoder().encode(cachedRules.networkRules.filter { $0.isException && $0.exceptionScope != "network" }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let cosmeticExceptionsJSON = (try? JSONEncoder().encode(cachedRules.cosmeticExceptions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let allowlistJSON = (try? JSONSerialization.data(withJSONObject: normalizedAllowlist(allowlistedHosts)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let script = ManualAdBlockRuntime.tiledBannerDetection + "\n" + """
        (function() {
            var souloCosmeticEnabled = \(cosmetic ? "true" : "false");
            var souloAllowlistedHosts = \(allowlistJSON);
            var souloSubscriptionCosmeticRules = \(subscriptionCosmeticRulesJSON);
            window.__souloAdBlockConfig = {
                cosmeticEnabled: souloCosmeticEnabled,
                tiledBanners: \(builtInRules.contains { $0.kind == .tiledBanner } ? "true" : "false"),
                allowlistedHosts: souloAllowlistedHosts,
                subscriptionCosmeticRules: souloSubscriptionCosmeticRules,
                cosmeticExceptions: \(cosmeticExceptionsJSON),
                pageExceptions: \(pageExceptionsJSON)
            };

            function normalizedHost(value) {
                return String(value || '').toLowerCase();
            }

            function domainMatches(pattern, host) {
                pattern = normalizedHost(String(pattern || '').replace(/^\\*/, ''));
                host = normalizedHost(host);
                if (!pattern) return false;
                return host === pattern || host.endsWith('.' + pattern);
            }

            function adBlockConfig() {
                return window.__souloAdBlockConfig || {
                    cosmeticEnabled: souloCosmeticEnabled,
                    allowlistedHosts: souloAllowlistedHosts,
                    subscriptionCosmeticRules: souloSubscriptionCosmeticRules
                };
            }

            function isSensitiveChallengePage() {
                return /(^|[\\/?&#_=.-])(captcha|wappoc|verify|verification|challenge|security|passport|login|auth)([\\/?&#_=.-]|$)/.test(String(location.href || '').toLowerCase());
            }

            function isSouloAllowlisted() {
                var host = normalizedHost(location.hostname);
                return (adBlockConfig().allowlistedHosts || []).some(function(domain) { return domainMatches(domain, host); });
            }

            function pageExceptionMatches(scopes) {
                return (adBlockConfig().pageExceptions || []).some(function(rule) {
                    if (scopes.indexOf(rule.exceptionScope) < 0) return false;
                    try { return new RegExp(rule.urlFilter, 'i').test(location.href); } catch (_) { return false; }
                });
            }

            function shouldDisableAdBlock() {
                return isSensitiveChallengePage() || isSouloAllowlisted() || pageExceptionMatches(['document']);
            }

            if (window.__souloAdBlockInstalled) {
                if (typeof window.__souloAdBlockRemoveAds === 'function') {
                    window.__souloAdBlockRemoveAds();
                }
                return;
            }

            if (shouldDisableAdBlock()) return;
            window.__souloAdBlockInstalled = true;

            var matchedConfig = null, matchedHost = '', matchedURL = '', matchedSelectors = [], matchedCSS = '', selectorGroups = [];
            function matchingSubscriptionSelectors() {
                var host = normalizedHost(location.hostname);
                var config = adBlockConfig();
                if (config === matchedConfig && host === matchedHost && matchedURL === location.href) return matchedSelectors;
                var selectors = [];
                var hideDisabled = pageExceptionMatches(['document', 'elemhide']);
                var genericDisabled = pageExceptionMatches(['generichide']);
                var excepted = new Set((adBlockConfig().cosmeticExceptions || []).filter(function(rule) {
                    return (!(rule.ifDomains || []).length || rule.ifDomains.some(function(domain) { return domainMatches(domain, host); }))
                        && !(rule.unlessDomains || []).some(function(domain) { return domainMatches(domain, host); });
                }).map(function(rule) { return rule.selector; }));
                (adBlockConfig().subscriptionCosmeticRules || []).forEach(function(rule) {
                    var selector = rule.selector || '';
                    if (!selector || hideDisabled || excepted.has(selector)) return;
                    if (genericDisabled && !(rule.ifDomains || []).length) return;
                    if (isUnsafeSelector(selector)) return;
                    var ifDomains = rule.ifDomains || [];
                    var unlessDomains = rule.unlessDomains || [];
                    var included = ifDomains.length === 0 || ifDomains.some(function(domain) { return domainMatches(domain, host); });
                    var excluded = unlessDomains.some(function(domain) { return domainMatches(domain, host); });
                    if (included && !excluded) selectors.push(selector);
                });
                matchedConfig = config;
                matchedHost = host;
                matchedSelectors = Array.from(new Set(selectors));
                matchedURL = location.href;
                matchedCSS = matchedSelectors.map(function(selector) { return selector + ' { display:none !important; }'; }).join('\\n');
                selectorGroups = [];
                var inlineSelectors = matchedSelectors.filter(function(sel) { return sel !== '\(ManualAdBlockRuntime.imageBannerSelector)'; });
                for (var i = 0; i < inlineSelectors.length; i += 80) selectorGroups.push(inlineSelectors.slice(i, i + 80));
                return matchedSelectors;
            }

            function applyStaticStyles() {
                var existingStyle = document.getElementById('soulo-ad-hiding-style');
                if (!adBlockConfig().cosmeticEnabled || shouldDisableAdBlock()) {
                    if (existingStyle) existingStyle.remove();
                    return;
                }
                if (!document.documentElement) return;
                var souloSubscriptionSelectors = matchingSubscriptionSelectors();
                var style = existingStyle;
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'soulo-ad-hiding-style';
                    (document.head || document.documentElement).appendChild(style);
                }
                if (style.textContent !== matchedCSS) style.textContent = matchedCSS;
            }
            applyStaticStyles();

            function normalizedTrackerHost(value) {
                return String(value || '').toLowerCase().replace(/^www\\./, '');
            }

            function hostFromElement(el) {
                try {
                    var value = el.src || el.href || '';
                    if (!value && el.querySelector) {
                        var child = el.querySelector('[src], [href]');
                        value = (child && (child.src || child.href)) || '';
                    }
                    if (!value) {
                        var html = String(el.outerHTML || '');
                        var match = html.match(/https?:\\/\\/([^\\/"'\\s>]+)/i);
                        value = match ? match[0] : '';
                    }
                    return normalizedTrackerHost(new URL(value, location.href).hostname);
                } catch(e) {
                    return '';
                }
            }

            function looksLikeTrackerHost(host) {
                host = normalizedTrackerHost(host);
                if (!host || domainMatches(host, location.hostname)) return false;
                return /doubleclick|googlesyndication|googleadservices|google-analytics|googletagmanager|facebook|connect\\.facebook|tiktok|bytedance|oceanengine|hm\\.baidu|cnzz|umeng|clarity\\.ms|hotjar|mouseflow|taboola|outbrain|criteo|adnxs|rubiconproject|pubmatic|openx|scorecardresearch|quantserve|amazon-adsystem|ads-twitter|linkedin|adservice|ads?\\./i.test(host);
            }

            function isUnsafeSelector(selector) {
                selector = String(selector || '').trim().toLowerCase();
                if (!selector || selector.length > 240) return true;
                if (/(:-abp-|:contains|:matches-css|:xpath|:upward|:remove|\\+js\\()/i.test(selector)) return true;
                return /^(html|body|main|article|#app|#root|#__next|#__nuxt|\\[role=["']?main)/i.test(selector);
            }

            function hasAdLikeResource(el) {
                try {
                    var html = (el.outerHTML || '').toLowerCase();
                    var bg = window.getComputedStyle(el).backgroundImage || '';
                    return /cpcad|gudingwei|jioeidd|cqlkxq1wc|adpic|adimg|floatad|popupad|\\/ads?\\/|adserver|doubleclick|googlesyndication|tuiguang|广告|推广|sponsor/.test(html + ' ' + bg);
                } catch(e) {
                    return false;
                }
            }

            function isAuthenticationElement(el) {
                try {
                    if (!el) return false;
                    var identity = [
                        el.id || '',
                        typeof el.className === 'string' ? el.className : '',
                        el.getAttribute && (el.getAttribute('role') || ''),
                        el.getAttribute && (el.getAttribute('aria-label') || '')
                    ].join(' ').toLowerCase();
                    if (/(^|[\\s_-])(login|log-in|signin|sign-in|signup|sign-up|register|auth|passport)([\\s_-]|$)/.test(identity)) {
                        return true;
                    }
                    if (el.matches && el.matches('input[type="tel"], input[type="password"], input[autocomplete*="one-time-code"]')) {
                        return true;
                    }
                    if (el.querySelector && el.querySelector('input[type="tel"], input[type="password"], input[autocomplete*="one-time-code"], input[name*="captcha" i], input[name*="verify" i]')) {
                        return true;
                    }
                } catch(e) {}
                return false;
            }

            function isProtectedPageElement(el) {
                try {
                    if (!el || el === document.body || el === document.documentElement) return true;
                    var tag = String(el.tagName || '').toLowerCase();
                    if (tag === 'main' || tag === 'article') return true;

                    var id = String(el.id || '').toLowerCase();
                    var role = String(el.getAttribute('role') || '').toLowerCase();
                    if (/^(app|root|__next|__nuxt|main|content|page|container)$/.test(id) || role === 'main') return true;

                    var rect = el.getBoundingClientRect();
                    var textLength = String(el.innerText || el.textContent || '').replace(/\\s+/g, '').length;
                    var coversViewport = rect.width > window.innerWidth * 0.88 && rect.height > window.innerHeight * 0.62;
                    var topLevelContent = el.parentElement === document.body && rect.width > window.innerWidth * 0.7 && rect.height > window.innerHeight * 0.35;
                    if ((coversViewport || topLevelContent) && textLength > 80 && !hasAdLikeResource(el)) return true;
                } catch(e) {}
                return false;
            }

            function hideAdElement(el) {
                try {
                    if (!el || isProtectedPageElement(el) || isAuthenticationElement(el) || el.hasAttribute('data-soulo-hidden-ad')) return false;
                    el.setAttribute('data-soulo-hidden-ad', 'true');
                    el.style.setProperty('display', 'none', 'important');
                    el.style.setProperty('height', '0', 'important');
                    el.style.setProperty('max-height', '0', 'important');
                    el.style.setProperty('overflow', 'hidden', 'important');
                    el.style.setProperty('visibility', 'hidden', 'important');
                    el.style.setProperty('pointer-events', 'none', 'important');
                    return true;
                } catch(e) {
                    return false;
                }
            }

            var mosaicSheet = null, mosaicCSS = '', mosaicSeen = new WeakSet(), pendingMosaicCount = 0;
            function maskMosaics(groups) {
                if (!mosaicSheet) {
                    mosaicSheet = new CSSStyleSheet();
                    document.adoptedStyleSheets = document.adoptedStyleSheets.concat([mosaicSheet]);
                }
                var selectors = [];
                groups.forEach(function(group) {
                    window.__souloBannerInteractions.remember(group);
                    group.elements.forEach(function(el) {
                        // Match only the inline styles of a confirmed mosaic.
                        // Leave its DOM, display and measured size untouched:
                        // anti-block scripts otherwise rebuild it and cause flashes.
                        if (!mosaicSeen.has(el)) { mosaicSeen.add(el); pendingMosaicCount++; }
                        var parent = el.parentElement;
                        var scope = parent === document.body ? 'body' : (parent && parent.id ? '#' + CSS.escape(parent.id) : null);
                        if (!scope && parent) {
                            var parts = [], node = parent;
                            while (node && node !== document.documentElement) {
                                var siblings = Array.from(node.parentElement?.children || []).filter(function(sibling) { return sibling.localName === node.localName; });
                                parts.unshift(CSS.escape(node.localName) + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')');
                                node = node.parentElement;
                            }
                            if (node) scope = 'html > ' + parts.join(' > ');
                        }
                        if (scope && el.getAttribute('style')) selectors.push(scope + ' > ' + CSS.escape(el.localName)
                            + '[style="' + CSS.escape(el.getAttribute('style')) + '"]');
                    });
                });
                var css = selectors.length ? selectors.join(',') + ' { clip-path:inset(50%) !important; pointer-events:none !important; }' : '';
                if (css !== mosaicCSS) { mosaicSheet.replaceSync(css); mosaicCSS = css; }
            }
            function refreshMosaics() {
                window.__souloImageBanners.all().forEach(window.__souloImageBanners.mark);
                if (!adBlockConfig().cosmeticEnabled || !adBlockConfig().tiledBanners || shouldDisableAdBlock() || pageExceptionMatches(['elemhide'])) {
                    if (mosaicSheet) { mosaicSheet.replaceSync(''); mosaicCSS = ''; }
                    return;
                }
                maskMosaics(window.__souloTiledBanners.all());
            }
            document.addEventListener('soulo-ad-picker-started', refreshMosaics);
            document.addEventListener('load', function(event) {
                if (event.target instanceof Element && event.target.matches('link[rel=stylesheet]')) refreshMosaics();
            }, true);

            function removeAds() {
                applyStaticStyles();
                refreshMosaics();
                if (shouldDisableAdBlock()) return;
                // Keep visible targets stable while the user marks them. The
                // explicit picker-end event resumes normal filtering after exit.
                if (document.documentElement.hasAttribute('data-soulo-ad-picker-active')) return;
                var hiddenCount = pendingMosaicCount;
                pendingMosaicCount = 0;
                var trackerHosts = [];
                if (adBlockConfig().cosmeticEnabled) {
                    matchingSubscriptionSelectors();
                    // Reuse compiled selector groups across DOM mutations.
                    function hideMatches(selector) {
                        document.querySelectorAll(selector).forEach(function(el) {
                            var host = hostFromElement(el);
                            if (hideAdElement(el)) {
                                hiddenCount++;
                                if (looksLikeTrackerHost(host)) trackerHosts.push(host);
                            }
                        });
                    }
                    for (var i = 0; i < selectorGroups.length; i++) {
                        var group = selectorGroups[i];
                        try { hideMatches(group.join(',')); }
                        catch (_) { group.forEach(function(sel) { try { hideMatches(sel); } catch (_) {} }); }
                    }
                }

                if (hiddenCount > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.souloAdBlocker) {
                    try {
                        window.webkit.messageHandlers.souloAdBlocker.postMessage({
                            host: location.hostname,
                            hiddenCount: hiddenCount,
                            trackerHosts: Array.from(new Set(trackerHosts)).slice(0, 80)
                        });
                    } catch(e) {}
                }
            }

            document.addEventListener('soulo-ad-picker-ended', removeAds);
            window.__souloAdBlockRemoveAds = removeAds;
            window.__souloAdBlockRemoveAds();

            function installAdBlockObserver() {
                if (window.__souloAdBlockObserver) return;
                window.__souloAdBlockObserver = new MutationObserver(function(mutations) {
                    var needsClean = false;
                    mutations.forEach(function(m) {
                        // Clocks, subtitles and counters only replace text. They
                        // cannot insert an ad element and need no full DOM scan.
                        if (Array.from(m.addedNodes).some(function(n) { return n.nodeType === 1; }) ||
                            (m.target.nodeName === 'STYLE' && m.target.id !== 'soulo-ad-hiding-style')) needsClean = true;
                    });
                    if (needsClean) {
                        // Mutation callbacks run before paint. Mask new tiles
                        // immediately; ordinary cosmetic work stays debounced.
                        refreshMosaics();
                        clearTimeout(window.__souloAdBlockTimer);
                        window.__souloAdBlockTimer = setTimeout(function() {
                            if (typeof window.__souloAdBlockRemoveAds === 'function') {
                                window.__souloAdBlockRemoveAds();
                            }
                        }, 100);
                    }
                });
                window.__souloAdBlockObserver.observe(document, { childList: true, subtree: true });
            }

            installAdBlockObserver();

        })();
        """
        if usesArchive { hidingScriptCache.setObject(script as NSString, forKey: cacheKey) }
        return script
    }
}
