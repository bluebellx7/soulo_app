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
    var isException: Bool = false
    var caseSensitive: Bool = false
    var exceptionScope: String = "network"

    init(
        urlFilter: String,
        resourceTypes: [String] = [],
        loadTypes: [String] = [],
        ifDomains: [String] = [],
        unlessDomains: [String] = [],
        isException: Bool = false,
        caseSensitive: Bool = false,
        exceptionScope: String = "network"
    ) {
        self.urlFilter = urlFilter
        self.resourceTypes = resourceTypes
        self.loadTypes = loadTypes
        self.ifDomains = ifDomains
        self.unlessDomains = unlessDomains
        self.isException = isException
        self.caseSensitive = caseSensitive
        self.exceptionScope = exceptionScope
    }

    enum CodingKeys: String, CodingKey {
        case urlFilter, resourceTypes, loadTypes, ifDomains, unlessDomains, isException, caseSensitive, exceptionScope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlFilter = try c.decode(String.self, forKey: .urlFilter)
        resourceTypes = try c.decodeIfPresent([String].self, forKey: .resourceTypes) ?? []
        loadTypes = try c.decodeIfPresent([String].self, forKey: .loadTypes) ?? []
        ifDomains = try c.decodeIfPresent([String].self, forKey: .ifDomains) ?? []
        unlessDomains = try c.decodeIfPresent([String].self, forKey: .unlessDomains) ?? []
        isException = try c.decodeIfPresent(Bool.self, forKey: .isException) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        exceptionScope = try c.decodeIfPresent(String.self, forKey: .exceptionScope) ?? "network"
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
    var cosmeticExceptions: [AdBlockCosmeticRule]
    var parserVersion: Int

    static let empty = ParsedAdBlockRules()

    init(
        networkURLFilters: [String] = [],
        cosmeticSelectors: [String] = [],
        networkRules: [AdBlockNetworkRule] = [],
        cosmeticRules: [AdBlockCosmeticRule] = [],
        cosmeticExceptions: [AdBlockCosmeticRule] = [],
        parserVersion: Int = AdBlockRuleParser.version
    ) {
        self.networkURLFilters = networkURLFilters
        self.cosmeticSelectors = cosmeticSelectors
        self.networkRules = networkRules
        self.cosmeticRules = cosmeticRules
        self.cosmeticExceptions = cosmeticExceptions
        self.parserVersion = parserVersion
    }

    enum CodingKeys: String, CodingKey {
        case networkURLFilters, cosmeticSelectors, networkRules, cosmeticRules, cosmeticExceptions, parserVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkURLFilters = try container.decodeIfPresent([String].self, forKey: .networkURLFilters) ?? []
        cosmeticSelectors = try container.decodeIfPresent([String].self, forKey: .cosmeticSelectors) ?? []
        networkRules = try container.decodeIfPresent([AdBlockNetworkRule].self, forKey: .networkRules) ?? []
        cosmeticRules = try container.decodeIfPresent([AdBlockCosmeticRule].self, forKey: .cosmeticRules) ?? []

        cosmeticExceptions = try container.decodeIfPresent([AdBlockCosmeticRule].self, forKey: .cosmeticExceptions) ?? []
        parserVersion = try container.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 0

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
    static let version = 3
    static let resourceTypes = ["script", "image", "style-sheet", "font", "media", "raw", "popup", "svg-document"]

    // Limits are injectable for callers/tests; production keeps every supported rule.
    static func parse(_ text: String, maxNetworkRules: Int = .max, maxCosmeticRules: Int = .max) -> ParsedAdBlockRules {
        var network = OrderedNetworkRuleSet(limit: maxNetworkRules)
        var cosmetic = OrderedCosmeticRuleSet(limit: maxCosmeticRules)
        var exceptions = OrderedCosmeticRuleSet(limit: .max)
        var conditionalDepth = 0
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // badfilter cancels the exact rule, irrespective of ordering in a list.
        let disabled = Set(lines.compactMap { line -> String? in
            guard line.hasSuffix(",badfilter") else { return nil }
            return String(line.dropLast(",badfilter".count))
        })
        for line in lines {
            if line.hasPrefix("!#if ") { conditionalDepth += 1; continue }
            if line.hasPrefix("!#endif") { conditionalDepth = max(0, conditionalDepth - 1); continue }
            // Unknown platform conditions must not activate mutually exclusive branches.
            guard conditionalDepth == 0, !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !disabled.contains(line) else { continue }
            if let range = line.range(of: "#@#") {
                if let rule = parseCosmeticRule(line, range: range) { exceptions.insert(rule) }
            } else if let range = line.range(of: "##") {
                if let rule = parseCosmeticRule(line, range: range) { cosmetic.insert(rule) }
            } else {
                parseNetworkRules(line).forEach { network.insert($0) }
            }
        }
        return ParsedAdBlockRules(
            networkURLFilters: Array(Set(network.values.filter { !$0.isException }.map(\.urlFilter))).sorted(),
            cosmeticSelectors: Array(Set(cosmetic.values.filter { $0.ifDomains.isEmpty && $0.unlessDomains.isEmpty }.map(\.selector))).sorted(),
            networkRules: network.values, cosmeticRules: cosmetic.values, cosmeticExceptions: exceptions.values)
    }

    private static func parseCosmeticRule(_ line: String, range: Range<String.Index>) -> AdBlockCosmeticRule? {
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeSelector(selector), let domains = parseDomainList(String(line[..<range.lowerBound])) else { return nil }
        return AdBlockCosmeticRule(selector: selector, ifDomains: domains.included, unlessDomains: domains.excluded)
    }

    private static func parseNetworkRules(_ line: String) -> [AdBlockNetworkRule] {
        var pattern = line
        let exception = pattern.hasPrefix("@@")
        if exception { pattern.removeFirst(2) }
        var includedTypes = Set<String>(), excludedTypes = Set<String>()
        var loadTypes: [String] = [], includedDomains: [String] = [], excludedDomains: [String] = []
        var caseSensitive = false
        var exceptionScope = "network"
        if let split = pattern.firstIndex(of: "$") {
            let options = pattern[pattern.index(after: split)...].components(separatedBy: ",")
            pattern = String(pattern[..<split])
            let typeMap = ["script":"script", "image":"image", "stylesheet":"style-sheet", "font":"font", "media":"media", "popup":"popup"]
            for raw in options {
                let option = raw.lowercased()
                let negated = option.hasPrefix("~")
                let name = negated ? String(option.dropFirst()) : option
                if let type = typeMap[name] {
                    if negated { excludedTypes.insert(type) } else { includedTypes.insert(type) }
                } else if option == "third-party" || option == "~third-party" {
                    let type = negated ? "first-party" : "third-party"
                    guard loadTypes.isEmpty || loadTypes == [type] else { return [] }
                    loadTypes = [type]
                } else if ["document", "elemhide", "generichide"].contains(option), exception {
                    guard exceptionScope == "network" else { return [] }
                    exceptionScope = option
                } else if option == "match-case" { caseSensitive = true
                } else if option.hasPrefix("domain=") {
                    guard includedDomains.isEmpty && excludedDomains.isEmpty,
                          let domains = parseDomainList(String(option.dropFirst(7)), separator: "|"),
                          !domains.included.isEmpty || !domains.excluded.isEmpty else { return [] }
                    includedDomains = domains.included; excludedDomains = domains.excluded
                } else {
                    // Do not discard an unknown constraint and accidentally broaden it.
                    // document/elemhide, scriptlets, redirects and raw request subtypes
                    // need separate execution support before they can be enabled.
                    return []
                }
            }
        }
        if exceptionScope != "network" {
            guard includedTypes.isEmpty, excludedTypes.isEmpty, loadTypes.isEmpty,
                  includedDomains.isEmpty, excludedDomains.isEmpty, !caseSensitive else { return [] }
        }
        let types = (includedTypes.isEmpty ? Set(resourceTypes) : includedTypes).subtracting(excludedTypes).sorted()
        guard !types.isEmpty, !pattern.isEmpty, pattern.utf8.count <= 512,
              pattern.unicodeScalars.allSatisfy({ $0.isASCII }),
              !pattern.contains("#"), !(pattern.hasPrefix("/") && pattern.hasSuffix("/")),
              !pattern.contains(" ") else { return [] }
        var prefix = "", suffix = ""
        if pattern.hasPrefix("||") {
            pattern.removeFirst(2)
            let host = String(pattern.prefix { !"/^*|:".contains($0) })
            guard isLikelyDomain(host) else { return [] }
            prefix = #"^https?://([a-z0-9-]+\.)*"#
        } else if pattern.hasPrefix("|") { pattern.removeFirst(); prefix = "^" }
        if pattern.hasSuffix("|") { pattern.removeLast(); suffix = "$" }
        guard !pattern.contains("|") else { return [] }
        if suffix.isEmpty { while pattern.hasSuffix("*") { pattern.removeLast() } }
        // WebKit disallows alternation. Expand the separator-at-end case into
        // two equivalent rules instead of losing the end-of-URL alternative.
        let terminalSeparator = pattern.hasSuffix("^")
        if terminalSeparator { pattern.removeLast() }
        var regex = prefix
        for char in pattern {
            switch char {
            case "*": regex += ".*"
            case "^": regex += #"[^a-zA-Z0-9_.%\-]"#
            default: regex += NSRegularExpression.escapedPattern(for: String(char))
            }
        }
        guard !regex.isEmpty else { return [] }
        // Canonical HTTP URLs always contain a slash after the authority, so
        // a host-only filter needs no impossible end-before-slash alternative.
        let hostOnly = !prefix.isEmpty && prefix != "^" && !pattern.contains("/") && !pattern.contains(":") && !pattern.contains("*") && !pattern.contains("^")
        let filters = terminalSeparator
            ? (hostOnly ? [regex + #"[^a-zA-Z0-9_.%\-]"# + suffix]
                        : [regex + #"[^a-zA-Z0-9_.%\-]"# + suffix, regex + "$"])
            : [regex + suffix]
        return filters.map { AdBlockNetworkRule(urlFilter: $0, resourceTypes: types,
            loadTypes: loadTypes, ifDomains: includedDomains, unlessDomains: excludedDomains,
            isException: exception, caseSensitive: caseSensitive, exceptionScope: exceptionScope) }
    }

    private static func parseDomainList(_ value: String, separator: Character = ",") -> (included: [String], excluded: [String])? {
        guard !value.isEmpty else { return ([], []) }
        var included = Set<String>(), excluded = Set<String>()
        for raw in value.split(separator: separator, omittingEmptySubsequences: false) {
            var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard isLikelyDomain(domain) else { return nil }
            if negated { excluded.insert("*" + domain) } else { included.insert("*" + domain) }
        }
        return (included.sorted(), excluded.sorted())
    }

    private static func isLikelyDomain(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"#, options: .regularExpression) != nil
    }

    private static func isSafeSelector(_ selector: String) -> Bool {
        AdBlockService.sanitizedContentBlockerSelector(selector) != nil
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
    private let rulesArchiveURL: URL?
    private let autoUpdateInterval: TimeInterval = 24 * 60 * 60

    init(
        subscriptionsKey: String = "soulo_ad_block_subscriptions",
        cachedRulesKey: String = "soulo_ad_block_subscription_rules",
        versionKey: String = "soulo_ad_block_subscription_rules_version",
        autoUpdateCheckKey: String = "soulo_ad_block_subscription_auto_update_check",
        userDefaults: UserDefaults = .standard,
        session: URLSession = .shared,
        rulesArchiveURL: URL? = nil
    ) {
        self.subscriptionsKey = subscriptionsKey
        self.cachedRulesKey = cachedRulesKey
        self.versionKey = versionKey
        self.autoUpdateCheckKey = autoUpdateCheckKey
        self.userDefaults = userDefaults
        self.session = session
        self.rulesArchiveURL = rulesArchiveURL ?? (userDefaults === UserDefaults.standard && cachedRulesKey == "soulo_ad_block_subscription_rules"
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("AdBlock/subscription-rules.json") : nil)
        // Move the large per-subscription archive before any preference writes.
        // Keeping several MB here exceeds CFPreferences' supported size and can
        // lose unrelated settings or freshly saved manual advertisement rules.
        let storedRules = storedParsedRulesByID()
        load()
        if storedRules.values.contains(where: { $0.parserVersion != AdBlockRuleParser.version }) {
            userDefaults.removeObject(forKey: autoUpdateCheckKey)
            for index in subscriptions.indices {
                if let old = storedRules[subscriptions[index].id], old.parserVersion != AdBlockRuleParser.version {
                    subscriptions[index].networkRuleCount = 0
                    subscriptions[index].cosmeticRuleCount = 0
                    subscriptions[index].lastUpdatedAt = nil
                }
            }
            saveSubscriptions()
        }
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
        let hasCachedRules = rules.parserVersion == AdBlockRuleParser.version && (!rules.networkRules.isEmpty || !rules.cosmeticRules.isEmpty)
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
                let parsed = await Task.detached(priority: .utility) { AdBlockRuleParser.parse(text) }.value
                try Task.checkCancellation()
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
        if let rulesArchiveURL, let data = try? Data(contentsOf: rulesArchiveURL),
           let decoded = try? JSONDecoder().decode([String: ParsedAdBlockRules].self, from: data) {
            userDefaults.removeObject(forKey: key)
            return decoded
        }
        guard let data = userDefaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ParsedAdBlockRules].self, from: data)
        else { return [:] }
        if rulesArchiveURL != nil && writeRulesArchive(data) {
            userDefaults.removeObject(forKey: key)
        }
        return decoded
    }

    private func saveParsedRulesByID(_ rules: [String: ParsedAdBlockRules]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        let key = "\(cachedRulesKey)_by_id"
        if rulesArchiveURL != nil {
            if writeRulesArchive(data) { userDefaults.removeObject(forKey: key) }
        } else {
            userDefaults.set(data, forKey: key)
        }
    }

    private func writeRulesArchive(_ data: Data) -> Bool {
        guard let rulesArchiveURL else { return false }
        do {
            try FileManager.default.createDirectory(at: rulesArchiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: rulesArchiveURL, options: .atomic)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func rebuildCacheFromStoredSubscriptions() {
        rebuildCacheFrom(parsedByID: storedParsedRulesByID())
    }

    private func rebuildCacheFrom(parsedByID: [String: ParsedAdBlockRules]) {
        var network = OrderedStringSet(limit: .max)
        var cosmetic = OrderedStringSet(limit: .max)
        var structuredNetwork = OrderedNetworkRuleSet(limit: .max)
        var structuredCosmetic = OrderedCosmeticRuleSet(limit: .max)
        var cosmeticExceptions = OrderedCosmeticRuleSet(limit: .max)

        for subscription in subscriptions where subscription.isEnabled {
            guard let parsed = parsedByID[subscription.id], parsed.parserVersion == AdBlockRuleParser.version else { continue }
            parsed.networkURLFilters.forEach { network.insert($0) }
            parsed.cosmeticSelectors.forEach { cosmetic.insert($0) }
            parsed.networkRules.forEach { structuredNetwork.insert($0) }
            parsed.cosmeticRules.forEach { structuredCosmetic.insert($0) }
            parsed.cosmeticExceptions.forEach { cosmeticExceptions.insert($0) }
        }

        let merged = ParsedAdBlockRules(
            networkURLFilters: network.values,
            cosmeticSelectors: cosmetic.values,
            networkRules: structuredNetwork.values,
            cosmeticRules: structuredCosmetic.values,
            cosmeticExceptions: cosmeticExceptions.values
        )
        // Starting the service must not invalidate compiled WebKit rules when
        // the enabled rule content is unchanged.
        if Self.cachedRules(userDefaults: userDefaults, key: cachedRulesKey) == merged,
           userDefaults.object(forKey: versionKey) != nil { return }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        if let url = Self.mergedArchiveURL(userDefaults: userDefaults, key: cachedRulesKey) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                userDefaults.removeObject(forKey: cachedRulesKey)
                Self.decodedCache.removeAllObjects()
            } catch {
                lastError = error.localizedDescription
                return
            }
        } else {
            userDefaults.set(data, forKey: cachedRulesKey)
        }
        userDefaults.set(Date().timeIntervalSince1970, forKey: versionKey)
    }

    private final class RuleBox: NSObject {
        let rules: ParsedAdBlockRules
        init(_ rules: ParsedAdBlockRules) { self.rules = rules }
    }
    nonisolated(unsafe) private static let decodedCache = NSCache<NSString, RuleBox>()

    nonisolated private static func mergedArchiveURL(userDefaults: UserDefaults, key: String) -> URL? {
        guard userDefaults === UserDefaults.standard, key == "soulo_ad_block_subscription_rules" else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AdBlock/merged-rules.json")
    }

    nonisolated static func cachedRules(userDefaults: UserDefaults = .standard, key: String = "soulo_ad_block_subscription_rules") -> ParsedAdBlockRules {
        // Explicit preferences also support isolated test fixtures and legacy migration.
        if let data = userDefaults.data(forKey: key) {
            guard let parsed = try? JSONDecoder().decode(ParsedAdBlockRules.self, from: data),
                  parsed.parserVersion == AdBlockRuleParser.version else { return .empty }
            return parsed
        }
        guard let url = mergedArchiveURL(userDefaults: userDefaults, key: key) else { return .empty }
        let cacheKey = url.path as NSString
        if let box = decodedCache.object(forKey: cacheKey) { return box.rules }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ParsedAdBlockRules.self, from: data),
              decoded.parserVersion == AdBlockRuleParser.version else { return .empty }
        decodedCache.setObject(RuleBox(decoded), forKey: cacheKey, cost: data.count)
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
