import Foundation

struct AdBlockSubscription: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var urlString: String
    var isEnabled: Bool
    var lastUpdatedAt: Date?
    var networkRuleCount: Int
    var cosmeticRuleCount: Int
    var errorMessage: String

    var url: URL? {
        URL(string: urlString)
    }
}

struct AdBlockNetworkRule: Codable, Equatable, Hashable {
    var urlFilter: String
    var resourceTypes: [String]
    var loadTypes: [String]
    var ifDomains: [String]
    var unlessDomains: [String]

    init(
        urlFilter: String,
        resourceTypes: [String] = [],
        loadTypes: [String] = [],
        ifDomains: [String] = [],
        unlessDomains: [String] = []
    ) {
        self.urlFilter = urlFilter
        self.resourceTypes = resourceTypes
        self.loadTypes = loadTypes
        self.ifDomains = ifDomains
        self.unlessDomains = unlessDomains
    }
}

struct AdBlockCosmeticRule: Codable, Equatable, Hashable {
    var selector: String
    var ifDomains: [String]
    var unlessDomains: [String]

    init(selector: String, ifDomains: [String] = [], unlessDomains: [String] = []) {
        self.selector = selector
        self.ifDomains = ifDomains
        self.unlessDomains = unlessDomains
    }
}

struct ParsedAdBlockRules: Codable, Equatable {
    var networkURLFilters: [String]
    var cosmeticSelectors: [String]
    var networkRules: [AdBlockNetworkRule]
    var cosmeticRules: [AdBlockCosmeticRule]

    static let empty = ParsedAdBlockRules()

    init(
        networkURLFilters: [String] = [],
        cosmeticSelectors: [String] = [],
        networkRules: [AdBlockNetworkRule] = [],
        cosmeticRules: [AdBlockCosmeticRule] = []
    ) {
        self.networkURLFilters = networkURLFilters
        self.cosmeticSelectors = cosmeticSelectors
        self.networkRules = networkRules
        self.cosmeticRules = cosmeticRules
    }

    enum CodingKeys: String, CodingKey {
        case networkURLFilters, cosmeticSelectors, networkRules, cosmeticRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkURLFilters = try container.decodeIfPresent([String].self, forKey: .networkURLFilters) ?? []
        cosmeticSelectors = try container.decodeIfPresent([String].self, forKey: .cosmeticSelectors) ?? []
        networkRules = try container.decodeIfPresent([AdBlockNetworkRule].self, forKey: .networkRules) ?? []
        cosmeticRules = try container.decodeIfPresent([AdBlockCosmeticRule].self, forKey: .cosmeticRules) ?? []

        if networkRules.isEmpty {
            networkRules = networkURLFilters.map {
                AdBlockNetworkRule(urlFilter: $0, resourceTypes: ["script", "image", "raw", "popup"])
            }
        }
        if cosmeticRules.isEmpty {
            cosmeticRules = cosmeticSelectors.map { AdBlockCosmeticRule(selector: $0) }
        }
    }
}

enum AdBlockRuleParser {
    static func parse(_ text: String, maxNetworkRules: Int = 2_500, maxCosmeticRules: Int = 1_200) -> ParsedAdBlockRules {
        var networkRules = OrderedStringSet(limit: maxNetworkRules)
        var cosmeticRules = OrderedStringSet(limit: maxCosmeticRules)
        var structuredNetworkRules = OrderedNetworkRuleSet(limit: maxNetworkRules)
        var structuredCosmeticRules = OrderedCosmeticRuleSet(limit: maxCosmeticRules)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }

            if line.contains("#@#") || line.hasPrefix("@@") {
                continue
            }

            if let cosmetic = parseCosmeticRule(line) {
                structuredCosmeticRules.insert(cosmetic)
                if cosmetic.ifDomains.isEmpty && cosmetic.unlessDomains.isEmpty {
                    cosmeticRules.insert(cosmetic.selector)
                }
                continue
            }

            if let rule = parseNetworkRule(line) {
                structuredNetworkRules.insert(rule)
                networkRules.insert(rule.urlFilter)
            }
        }

        return ParsedAdBlockRules(
            networkURLFilters: networkRules.values,
            cosmeticSelectors: cosmeticRules.values,
            networkRules: structuredNetworkRules.values,
            cosmeticRules: structuredCosmeticRules.values
        )
    }

    private static func parseCosmeticRule(_ line: String) -> AdBlockCosmeticRule? {
        guard let range = line.range(of: "##") else { return nil }
        let domainPrefix = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeSelector(selector) else { return nil }

        let domains = parseDomainList(domainPrefix)
        return AdBlockCosmeticRule(
            selector: selector,
            ifDomains: domains.included,
            unlessDomains: domains.excluded
        )
    }

    private static func parseNetworkRule(_ line: String) -> AdBlockNetworkRule? {
        var rule = line
        var resourceTypes: [String] = []
        var loadTypes: [String] = []
        var ifDomains: [String] = []
        var unlessDomains: [String] = []

        if let optionRange = rule.range(of: "$") {
            let options = String(rule[optionRange.upperBound...]).lowercased()
            if options.contains("elemhide") ||
                options.contains("generichide") ||
                options.contains("document") ||
                options.contains("csp") ||
                options.contains("redirect") ||
                options.contains("removeparam") ||
                options.contains("badfilter") {
                return nil
            }
            let parsedOptions = parseNetworkOptions(options)
            resourceTypes = parsedOptions.resourceTypes
            loadTypes = parsedOptions.loadTypes
            ifDomains = parsedOptions.ifDomains
            unlessDomains = parsedOptions.unlessDomains
            rule = String(rule[..<optionRange.lowerBound])
        }

        rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty,
              !rule.contains("##"),
              !rule.contains("#?#"),
              !rule.contains("#$#"),
              rule.count <= 180
        else { return nil }

        if rule.hasPrefix("||") {
            let domain = rule.dropFirst(2)
                .prefix { char in
                    char != "^" && char != "/" && char != "$" && char != "*"
                }
            let cleanDomain = String(domain)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            guard isLikelyDomain(cleanDomain) else { return nil }
            return AdBlockNetworkRule(
                urlFilter: NSRegularExpression.escapedPattern(for: cleanDomain).replacingOccurrences(of: "\\.", with: "\\."),
                resourceTypes: resourceTypes,
                loadTypes: loadTypes,
                ifDomains: ifDomains,
                unlessDomains: unlessDomains
            )
        }

        if rule.hasPrefix("|http://") || rule.hasPrefix("|https://") {
            rule.removeFirst()
        } else if rule.hasPrefix("|") {
            rule.removeFirst()
        }

        let converted = convertABPPatternToRegex(rule)
        guard converted.count >= 4, converted.count <= 220 else { return nil }
        return AdBlockNetworkRule(
            urlFilter: converted,
            resourceTypes: resourceTypes,
            loadTypes: loadTypes,
            ifDomains: ifDomains,
            unlessDomains: unlessDomains
        )
    }

    private static func parseNetworkOptions(_ options: String) -> (resourceTypes: [String], loadTypes: [String], ifDomains: [String], unlessDomains: [String]) {
        var resourceTypes = OrderedStringSet(limit: 12)
        var loadTypes = OrderedStringSet(limit: 2)
        var ifDomains = OrderedStringSet(limit: 80)
        var unlessDomains = OrderedStringSet(limit: 80)

        for option in options.components(separatedBy: ",") {
            let clean = option.trimmingCharacters(in: .whitespacesAndNewlines)
            switch clean {
            case "script":
                resourceTypes.insert("script")
            case "image":
                resourceTypes.insert("image")
            case "stylesheet":
                resourceTypes.insert("style-sheet")
            case "font":
                resourceTypes.insert("font")
            case "media":
                resourceTypes.insert("media")
            case "popup":
                resourceTypes.insert("popup")
            case "xmlhttprequest", "xhr", "websocket", "ping", "other":
                resourceTypes.insert("raw")
            case "subdocument":
                resourceTypes.insert("document")
            case "third-party":
                loadTypes.insert("third-party")
            case "~third-party":
                loadTypes.insert("first-party")
            default:
                if clean.hasPrefix("domain=") {
                    let domains = parseDomainList(String(clean.dropFirst("domain=".count)), separator: "|")
                    domains.included.forEach { ifDomains.insert($0) }
                    domains.excluded.forEach { unlessDomains.insert($0) }
                }
            }
        }

        return (resourceTypes.values, loadTypes.values, ifDomains.values, unlessDomains.values)
    }

    private static func parseDomainList(_ value: String, separator: Character = ",") -> (included: [String], excluded: [String]) {
        guard !value.isEmpty else { return ([], []) }
        var included = OrderedStringSet(limit: 80)
        var excluded = OrderedStringSet(limit: 80)

        for rawDomain in value.split(separator: separator) {
            var domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            let isExcluded = domain.hasPrefix("~")
            if isExcluded {
                domain.removeFirst()
            }
            domain = domain
                .lowercased()
                .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard isLikelyDomain(domain) else { continue }
            let webKitDomain = "*\(domain)"
            if isExcluded {
                excluded.insert(webKitDomain)
                excluded.insert(domain)
            } else {
                included.insert(webKitDomain)
                included.insert(domain)
            }
        }

        return (included.values, excluded.values)
    }

    private static func convertABPPatternToRegex(_ rule: String) -> String {
        var output = ""
        for char in rule {
            switch char {
            case "*":
                output += ".*"
            case "^":
                output += "[\\\\/:?&=]"
            case ".":
                output += "\\."
            case "?":
                output += "\\?"
            case "+":
                output += "\\+"
            case "[":
                output += "\\["
            case "]":
                output += "\\]"
            case "(":
                output += "\\("
            case ")":
                output += "\\)"
            case "{":
                output += "\\{"
            case "}":
                output += "\\}"
            case "|":
                output += ""
            default:
                output.append(char)
            }
        }
        return output
    }

    private static func isLikelyDomain(_ value: String) -> Bool {
        value.contains(".")
            && !value.contains("/")
            && !value.contains(" ")
            && value.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil
    }

    private static func isSafeSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty,
              selector.count <= 240,
              !selector.contains("{"),
              !selector.contains("}"),
              !selector.contains("<"),
              !selector.contains(">"),
              !selector.contains("`"),
              !selector.localizedCaseInsensitiveContains(":-abp-"),
              !selector.localizedCaseInsensitiveContains(":contains"),
              !selector.localizedCaseInsensitiveContains(":matches-css"),
              !selector.localizedCaseInsensitiveContains(":xpath"),
              !selector.localizedCaseInsensitiveContains(":upward"),
              !selector.localizedCaseInsensitiveContains(":remove"),
              !selector.localizedCaseInsensitiveContains("+js(")
        else { return false }
        return true
    }
}

@MainActor
final class AdBlockSubscriptionService: ObservableObject {
    static let shared = AdBlockSubscriptionService()

    @Published private(set) var subscriptions: [AdBlockSubscription] = []
    @Published private(set) var isUpdating = false
    @Published private(set) var lastError = ""

    private let subscriptionsKey: String
    private let cachedRulesKey: String
    private let versionKey: String
    private let autoUpdateCheckKey: String
    private let userDefaults: UserDefaults
    private let session: URLSession
    private let autoUpdateInterval: TimeInterval = 24 * 60 * 60

    init(
        subscriptionsKey: String = "soulo_ad_block_subscriptions",
        cachedRulesKey: String = "soulo_ad_block_subscription_rules",
        versionKey: String = "soulo_ad_block_subscription_rules_version",
        autoUpdateCheckKey: String = "soulo_ad_block_subscription_auto_update_check",
        userDefaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.subscriptionsKey = subscriptionsKey
        self.cachedRulesKey = cachedRulesKey
        self.versionKey = versionKey
        self.autoUpdateCheckKey = autoUpdateCheckKey
        self.userDefaults = userDefaults
        self.session = session
        load()
        let storedRules = storedParsedRulesByID()
        if !storedRules.isEmpty {
            rebuildCacheFrom(parsedByID: storedRules)
        }
    }

    var enabledRuleSummary: ParsedAdBlockRules {
        Self.cachedRules(userDefaults: userDefaults, key: cachedRulesKey)
    }

    var enabledSubscriptionCount: Int {
        subscriptions.filter(\.isEnabled).count
    }

    func setEnabled(_ enabled: Bool, for subscription: AdBlockSubscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[index].isEnabled = enabled
        saveSubscriptions()
        rebuildCacheFromStoredSubscriptions()
    }

    func updateEnabledSubscriptionsIfNeeded() async {
        guard enabledSubscriptionCount > 0, !isUpdating else { return }
        let lastCheck = userDefaults.double(forKey: autoUpdateCheckKey)
        let rules = enabledRuleSummary
        let hasCachedRules = !rules.networkRules.isEmpty || !rules.cosmeticRules.isEmpty
        guard !hasCachedRules || Date().timeIntervalSince1970 - lastCheck >= autoUpdateInterval else { return }
        userDefaults.set(Date().timeIntervalSince1970, forKey: autoUpdateCheckKey)
        await updateEnabledSubscriptions(reportErrors: false)
    }

    func updateEnabledSubscriptions(reportErrors: Bool = true) async {
        guard !isUpdating else { return }
        isUpdating = true
        if reportErrors {
            lastError = ""
        }
        defer { isUpdating = false }

        var parsedByID = storedParsedRulesByID()
        let candidates = subscriptions.filter(\.isEnabled)

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            guard let current = subscriptions.first(where: { $0.id == candidate.id }),
                  current.isEnabled, current.urlString == candidate.urlString else { continue }

            do {
                guard let url = current.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    throw URLError(.cannotDecodeContentData)
                }
                let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100).lowercased()
                guard response.mimeType?.lowercased() != "text/html",
                      !prefix.hasPrefix("<!doctype html"), !prefix.hasPrefix("<html") else {
                    throw URLError(.cannotParseResponse)
                }
                let parsed = AdBlockRuleParser.parse(text)
                // Re-find the live record after suspension. A user can toggle
                // subscriptions while a network request is in flight.
                guard let index = subscriptions.firstIndex(where: {
                    $0.id == candidate.id && $0.urlString == candidate.urlString
                }) else { continue }
                parsedByID[candidate.id] = parsed
                subscriptions[index].networkRuleCount = parsed.networkRules.count
                subscriptions[index].cosmeticRuleCount = parsed.cosmeticRules.count
                subscriptions[index].lastUpdatedAt = Date()
                subscriptions[index].errorMessage = ""
            } catch {
                if Task.isCancelled { break }
                guard let index = subscriptions.firstIndex(where: {
                    $0.id == candidate.id && $0.urlString == candidate.urlString
                }) else { continue }
                subscriptions[index].errorMessage = error.localizedDescription
                if reportErrors {
                    lastError = error.localizedDescription
                }
            }
        }

        saveSubscriptions()
        saveParsedRulesByID(parsedByID)
        rebuildCacheFrom(parsedByID: parsedByID)
    }

    func resetToDefaults() {
        subscriptions = Self.defaultSubscriptions()
        saveSubscriptions()
        rebuildCacheFromStoredSubscriptions()
    }

    private func load() {
        if let data = userDefaults.data(forKey: subscriptionsKey),
           let decoded = try? JSONDecoder().decode([AdBlockSubscription].self, from: data),
           !decoded.isEmpty {
            subscriptions = decoded
            mergeMissingDefaultSubscriptions()
        } else {
            subscriptions = Self.defaultSubscriptions()
            saveSubscriptions()
        }
    }

    func reloadFromDefaults() {
        load()
        rebuildCacheFromStoredSubscriptions()
    }

    private func mergeMissingDefaultSubscriptions() {
        let defaults = Self.defaultSubscriptions()
        var changed = false
        for subscription in defaults where !subscriptions.contains(where: { $0.id == subscription.id }) {
            subscriptions.append(subscription)
            changed = true
        }
        if changed {
            saveSubscriptions()
            rebuildCacheFromStoredSubscriptions()
        }
    }

    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(data, forKey: subscriptionsKey)
        }
    }

    private func storedParsedRulesByID() -> [String: ParsedAdBlockRules] {
        let key = "\(cachedRulesKey)_by_id"
        guard let data = userDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ParsedAdBlockRules].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveParsedRulesByID(_ rules: [String: ParsedAdBlockRules]) {
        let key = "\(cachedRulesKey)_by_id"
        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: key)
        }
    }

    private func rebuildCacheFromStoredSubscriptions() {
        rebuildCacheFrom(parsedByID: storedParsedRulesByID())
    }

    private func rebuildCacheFrom(parsedByID: [String: ParsedAdBlockRules]) {
        var network = OrderedStringSet(limit: 4_000)
        var cosmetic = OrderedStringSet(limit: 2_000)
        var structuredNetwork = OrderedNetworkRuleSet(limit: 4_000)
        var structuredCosmetic = OrderedCosmeticRuleSet(limit: 2_000)

        for subscription in subscriptions where subscription.isEnabled {
            guard let parsed = parsedByID[subscription.id] else { continue }
            parsed.networkURLFilters.forEach { network.insert($0) }
            parsed.cosmeticSelectors.forEach { cosmetic.insert($0) }
            parsed.networkRules.forEach { structuredNetwork.insert($0) }
            parsed.cosmeticRules.forEach { structuredCosmetic.insert($0) }
        }

        let merged = ParsedAdBlockRules(
            networkURLFilters: network.values,
            cosmeticSelectors: cosmetic.values,
            networkRules: structuredNetwork.values,
            cosmeticRules: structuredCosmetic.values
        )
        // Starting the service must not invalidate compiled WebKit rules when
        // the enabled rule content is unchanged.
        if let data = userDefaults.data(forKey: cachedRulesKey),
           let previous = try? JSONDecoder().decode(ParsedAdBlockRules.self, from: data),
           previous == merged {
            return
        }
        if let data = try? JSONEncoder().encode(merged) {
            userDefaults.set(data, forKey: cachedRulesKey)
        }
        userDefaults.set(Date().timeIntervalSince1970, forKey: versionKey)
    }

    nonisolated static func cachedRules(userDefaults: UserDefaults = .standard, key: String = "soulo_ad_block_subscription_rules") -> ParsedAdBlockRules {
        guard let data = userDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ParsedAdBlockRules.self, from: data)
        else { return .empty }
        return decoded
    }

    nonisolated static func rulesSignature(userDefaults: UserDefaults = .standard, versionKey: String = "soulo_ad_block_subscription_rules_version") -> String {
        String(userDefaults.double(forKey: versionKey))
    }

    private static func defaultSubscriptions() -> [AdBlockSubscription] {
        [
            AdBlockSubscription(
                id: "easylist",
                name: "EasyList",
                urlString: "https://easylist.to/easylist/easylist.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            ),
            AdBlockSubscription(
                id: "easyprivacy",
                name: "EasyPrivacy",
                urlString: "https://easylist.to/easylist/easyprivacy.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            ),
            AdBlockSubscription(
                id: "easylist-china",
                name: "EasyList China",
                urlString: "https://easylist-downloads.adblockplus.org/easylistchina.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            ),
            AdBlockSubscription(
                id: "adguard-base",
                name: "AdGuard Base Filter",
                urlString: "https://filters.adtidy.org/extension/chromium/filters/2.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            ),
            AdBlockSubscription(
                id: "adguard-chinese",
                name: "AdGuard Chinese Filter",
                urlString: "https://filters.adtidy.org/extension/chromium/filters/224.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            ),
            AdBlockSubscription(
                id: "adguard-mobile",
                name: "AdGuard Mobile Ads Filter",
                urlString: "https://filters.adtidy.org/extension/chromium/filters/11.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            ),
            AdBlockSubscription(
                id: "adguard-annoyances",
                name: "AdGuard Annoyances Filter",
                urlString: "https://filters.adtidy.org/extension/chromium/filters/14.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 0,
                cosmeticRuleCount: 0,
                errorMessage: ""
            )
        ]
    }
}

private struct OrderedStringSet {
    private(set) var values: [String] = []
    private var seen = Set<String>()
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func insert(_ value: String) {
        guard values.count < limit, !value.isEmpty, !seen.contains(value) else { return }
        seen.insert(value)
        values.append(value)
    }
}

private struct OrderedNetworkRuleSet {
    private(set) var values: [AdBlockNetworkRule] = []
    private var seen = Set<AdBlockNetworkRule>()
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func insert(_ value: AdBlockNetworkRule) {
        guard values.count < limit, !value.urlFilter.isEmpty, !seen.contains(value) else { return }
        seen.insert(value)
        values.append(value)
    }
}

private struct OrderedCosmeticRuleSet {
    private(set) var values: [AdBlockCosmeticRule] = []
    private var seen = Set<AdBlockCosmeticRule>()
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    mutating func insert(_ value: AdBlockCosmeticRule) {
        guard values.count < limit, !value.selector.isEmpty, !seen.contains(value) else { return }
        seen.insert(value)
        values.append(value)
    }
}
