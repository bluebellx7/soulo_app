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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(urlFilter, forKey: .urlFilter)
        if !resourceTypes.isEmpty { try c.encode(resourceTypes, forKey: .resourceTypes) }
        if !loadTypes.isEmpty { try c.encode(loadTypes, forKey: .loadTypes) }
        if !ifDomains.isEmpty { try c.encode(ifDomains, forKey: .ifDomains) }
        if !unlessDomains.isEmpty { try c.encode(unlessDomains, forKey: .unlessDomains) }
        if isException { try c.encode(true, forKey: .isException) }
        if caseSensitive { try c.encode(true, forKey: .caseSensitive) }
        if exceptionScope != "network" { try c.encode(exceptionScope, forKey: .exceptionScope) }
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
    enum CodingKeys: String, CodingKey { case selector, ifDomains, unlessDomains }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selector = try c.decode(String.self, forKey: .selector)
        ifDomains = try c.decodeIfPresent([String].self, forKey: .ifDomains) ?? []
        unlessDomains = try c.decodeIfPresent([String].self, forKey: .unlessDomains) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selector, forKey: .selector)
        if !ifDomains.isEmpty { try c.encode(ifDomains, forKey: .ifDomains) }
        if !unlessDomains.isEmpty { try c.encode(unlessDomains, forKey: .unlessDomains) }
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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(networkRules, forKey: .networkRules)
        try c.encode(cosmeticRules, forKey: .cosmeticRules)
        if !cosmeticExceptions.isEmpty { try c.encode(cosmeticExceptions, forKey: .cosmeticExceptions) }
        try c.encode(parserVersion, forKey: .parserVersion)
        // Legacy projections are derived, not a second full copy of every rule.
        let network = Array(Set(networkRules.filter { !$0.isException }.map(\.urlFilter))).sorted()
        let cosmetic = Array(Set(cosmeticRules.filter { $0.ifDomains.isEmpty && $0.unlessDomains.isEmpty }.map(\.selector))).sorted()
        if networkURLFilters != network { try c.encode(networkURLFilters, forKey: .networkURLFilters) }
        if cosmeticSelectors != cosmetic { try c.encode(cosmeticSelectors, forKey: .cosmeticSelectors) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkURLFilters = try container.decodeIfPresent([String].self, forKey: .networkURLFilters) ?? []
        cosmeticSelectors = try container.decodeIfPresent([String].self, forKey: .cosmeticSelectors) ?? []
        networkRules = try container.decodeIfPresent([AdBlockNetworkRule].self, forKey: .networkRules) ?? []
        cosmeticRules = try container.decodeIfPresent([AdBlockCosmeticRule].self, forKey: .cosmeticRules) ?? []

        cosmeticExceptions = try container.decodeIfPresent([AdBlockCosmeticRule].self, forKey: .cosmeticExceptions) ?? []
        parserVersion = try container.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 0

        if !container.contains(.networkURLFilters) {
            networkURLFilters = Array(Set(networkRules.filter { !$0.isException }.map(\.urlFilter))).sorted()
        }
        if !container.contains(.cosmeticSelectors) {
            cosmeticSelectors = Array(Set(cosmeticRules.filter { $0.ifDomains.isEmpty && $0.unlessDomains.isEmpty }.map(\.selector))).sorted()
        }
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
        let lines = text.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("!#if ") { conditionalDepth += 1; return nil }
            if line.hasPrefix("!#endif") { conditionalDepth = max(0, conditionalDepth - 1); return nil }
            // Unknown platform conditions must not activate either branch.
            guard conditionalDepth == 0, !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return nil }
            return line
        }
        // badfilter cancels the exact rule, irrespective of ordering in a list.
        let disabled = Set(lines.compactMap { line -> String? in
            guard !line.contains("#"), let split = line.firstIndex(of: "$") else { return nil }
            let modifiers = line[line.index(after: split)...].components(separatedBy: ",")
            let retained = modifiers.filter { $0.lowercased() != "badfilter" }
            guard retained.count < modifiers.count else { return nil }
            return String(line[..<split]) + (retained.isEmpty ? "" : "$" + retained.joined(separator: ","))
        })
        for line in lines where !disabled.contains(line) {
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
    enum SubscriptionInputError: Error, Equatable {
        case invalidInput
        case duplicateURL
    }

    // Opening the app must not decode the entire subscription archive on the
    // main actor. The merged rules remain available to WebKit independently.
    static let shared = AdBlockSubscriptionService(loadStoredRulesAtInitialization: false)

    @Published private(set) var subscriptions: [AdBlockSubscription] = []
    @Published private(set) var isUpdating = false
    @Published private(set) var completedUpdates = 0
    @Published private(set) var totalUpdates = 0
    @Published private(set) var lastError = ""

    private let subscriptionsKey: String
    private let cachedRulesKey: String
    private let versionKey: String
    private let autoUpdateCheckKey: String
    private let userDefaults: UserDefaults
    private let session: URLSession
    private let rulesArchiveURL: URL?
    private let autoUpdateInterval: TimeInterval = 24 * 60 * 60
    private var pendingSubscriptionIDs = Set<String>()

    init(
        subscriptionsKey: String = "soulo_ad_block_subscriptions",
        cachedRulesKey: String = "soulo_ad_block_subscription_rules",
        versionKey: String = "soulo_ad_block_subscription_rules_version",
        autoUpdateCheckKey: String = "soulo_ad_block_subscription_auto_update_check",
        userDefaults: UserDefaults = .standard,
        session: URLSession = .shared,
        rulesArchiveURL: URL? = nil,
        loadStoredRulesAtInitialization: Bool = true
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
        let storedRules = loadStoredRulesAtInitialization ? storedParsedRulesByID() : [:]
        load(rebuildForNewSubscriptions: loadStoredRulesAtInitialization,
             persistChanges: loadStoredRulesAtInitialization)
        guard loadStoredRulesAtInitialization else { return }
        repairOutdatedRuleMetadata(storedRules)
        if !storedRules.isEmpty {
            rebuildCacheFrom(parsedByID: storedRules)
        }
    }

    private func repairOutdatedRuleMetadata(_ storedRules: [String: ParsedAdBlockRules]) {
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
    }

    var enabledRuleSummary: ParsedAdBlockRules {
        Self.cachedRules(userDefaults: userDefaults, key: cachedRulesKey)
    }

    var enabledSubscriptionCount: Int {
        subscriptions.filter(\.isEnabled).count
    }

    nonisolated static func normalizedSubscriptionURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 4096,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        return components.url
    }

    func addSubscription(name: String, urlString: String) throws -> AdBlockSubscription {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              let url = Self.normalizedSubscriptionURL(urlString) else {
            throw SubscriptionInputError.invalidInput
        }
        guard !subscriptions.contains(where: { Self.normalizedSubscriptionURL($0.urlString) == url }) else {
            throw SubscriptionInputError.duplicateURL
        }
        let subscription = AdBlockSubscription(id: "custom-" + UUID().uuidString.lowercased(), name: name,
            urlString: url.absoluteString, isEnabled: true, lastUpdatedAt: nil,
            networkRuleCount: 0, cosmeticRuleCount: 0, errorMessage: "")
        subscriptions.insert(subscription, at: 0)
        userDefaults.removeObject(forKey: autoUpdateCheckKey)
        saveSubscriptions()
        return subscription
    }

    func isCustomSubscription(_ subscription: AdBlockSubscription) -> Bool {
        !Self.defaultSubscriptions().contains { $0.id == subscription.id }
    }

    func removeSubscription(_ subscription: AdBlockSubscription) {
        guard isCustomSubscription(subscription), subscriptions.contains(where: { $0.id == subscription.id }) else { return }
        var storedRules = storedParsedRulesByID()
        storedRules.removeValue(forKey: subscription.id)
        pendingSubscriptionIDs.remove(subscription.id)
        subscriptions.removeAll { $0.id == subscription.id }
        saveSubscriptions()
        if let data = try? JSONEncoder().encode(storedRules) { saveParsedRulesArchive(data) }
        rebuildCacheFrom(parsedByID: storedRules)
    }

    func setEnabled(_ enabled: Bool, for subscription: AdBlockSubscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        let storedRules = storedParsedRulesByID()
        subscriptions[index].isEnabled = enabled
        saveSubscriptions()
        rebuildCacheFrom(parsedByID: storedRules)
    }

    nonisolated static func needsAutomaticUpdateCheck() -> Bool {
        guard let archive = mergedArchiveURL(userDefaults: .standard, key: "soulo_ad_block_subscription_rules") else { return true }
        return !AdBlockAutomaticUpdateState.canSkipCheck(archive: archive)
    }

    func updateEnabledSubscriptionsIfNeeded() async {
        await compactArchivesIfNeeded()
        guard enabledSubscriptionCount > 0, !isUpdating else { return }
        let defaults = userDefaults, key = cachedRulesKey
        let rules = await Task.detached(priority: .utility) {
            Self.cachedRules(userDefaults: defaults, key: key)
        }.value
        guard !Task.isCancelled, enabledSubscriptionCount > 0, !isUpdating else { return }
        let lastCheck = userDefaults.double(forKey: autoUpdateCheckKey)
        let hasCachedRules = rules.parserVersion == AdBlockRuleParser.version && (!rules.networkRules.isEmpty || !rules.cosmeticRules.isEmpty)
        guard !hasCachedRules || Date().timeIntervalSince1970 - lastCheck >= autoUpdateInterval else { return }
        await updateEnabledSubscriptions(reportErrors: false, recordAutomaticCheck: true)
    }

    func updateEnabledSubscriptions(reportErrors: Bool = true, recordAutomaticCheck: Bool = false) async {
        await updateSubscriptions(ids: nil, reportErrors: reportErrors, recordAutomaticCheck: recordAutomaticCheck)
        await updatePendingSubscriptions()
    }

    func updateSubscription(_ subscription: AdBlockSubscription) async {
        if isUpdating {
            pendingSubscriptionIDs.insert(subscription.id)
            return
        }
        await updateSubscriptions(ids: [subscription.id], reportErrors: true, recordAutomaticCheck: false)
        await updatePendingSubscriptions()
    }

    private func updatePendingSubscriptions() async {
        while !pendingSubscriptionIDs.isEmpty, !isUpdating, !Task.isCancelled {
            let pending = pendingSubscriptionIDs
            pendingSubscriptionIDs.removeAll()
            await updateSubscriptions(ids: pending, reportErrors: true, recordAutomaticCheck: false)
        }
    }

    private func updateSubscriptions(ids: Set<String>?, reportErrors: Bool, recordAutomaticCheck: Bool) async {
        guard !isUpdating else { return }
        let candidates = subscriptions.filter { $0.isEnabled && (ids?.contains($0.id) ?? true) }
        completedUpdates = 0; totalUpdates = candidates.count
        isUpdating = true
        if reportErrors {
            lastError = ""
        }
        defer { isUpdating = false }

        let archiveURL = rulesArchiveURL
        let legacy = userDefaults.data(forKey: "\(cachedRulesKey)_by_id")
        let stored = await Task.detached(priority: .utility) {
            Self.readStoredRules(archiveURL: archiveURL, legacy: legacy)
        }.value
        finishArchiveMigration(stored)
        repairOutdatedRuleMetadata(stored.rules)
        // Recover a missing/stale merged cache before waiting for the network.
        // This preserves offline filtering from the per-subscription archive.
        await saveUpdatedRulesInBackground(stored.rules, saveArchive: false)
        if recordAutomaticCheck {
            userDefaults.set(Date().timeIntervalSince1970, forKey: autoUpdateCheckKey)
        }
        var parsedByID = stored.rules
        var receivedRules = false

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            defer { completedUpdates += 1 }
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
                receivedRules = true
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

        if receivedRules {
            await saveUpdatedRulesInBackground(parsedByID, saveArchive: true)
        } else {
            saveSubscriptions()
        }
    }

    func resetToDefaults() {
        pendingSubscriptionIDs.removeAll()
        let defaultIDs = Set(Self.defaultSubscriptions().map(\.id))
        let storedRules = storedParsedRulesByID().filter { defaultIDs.contains($0.key) }
        subscriptions = Self.defaultSubscriptions()
        saveSubscriptions()
        if let data = try? JSONEncoder().encode(storedRules) { saveParsedRulesArchive(data) }
        rebuildCacheFrom(parsedByID: storedRules)
    }

    private func load(rebuildForNewSubscriptions: Bool = true, persistChanges: Bool = true) {
        if let data = userDefaults.data(forKey: subscriptionsKey),
           let decoded = try? JSONDecoder().decode([AdBlockSubscription].self, from: data),
           !decoded.isEmpty {
            subscriptions = decoded
            mergeMissingDefaultSubscriptions(rebuildRules: rebuildForNewSubscriptions, persistChanges: persistChanges)
        } else {
            subscriptions = Self.defaultSubscriptions()
            if persistChanges { saveSubscriptions() }
        }
    }

    private var archiveCompactionTask: Task<Void, Never>?
    func compactArchivesIfNeeded() async {
        if let task = archiveCompactionTask { await task.value; return }
        let urls = [rulesArchiveURL, Self.mergedArchiveURL(userDefaults: userDefaults, key: cachedRulesKey)].compactMap { $0 }
        let task = Task { @MainActor in
            let prepared = await Task.detached(priority: .utility) {
                urls.compactMap { url -> (URL, Date, Int, Data)? in
                    guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                          values.isSymbolicLink != true, let size = values.fileSize, size > 4096,
                          let date = values.contentModificationDate, let data = try? Data(contentsOf: url),
                          !AdBlockRuleArchive.isPacked(data), let packed = try? AdBlockRuleArchive.pack(data), packed.count < data.count else { return nil }
                    return (url, date, size, packed)
                }
            }.value
            for (original, date, size, packed) in prepared {
                var url = original; url.removeAllCachedResourceValues()
                guard let current = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      current.fileSize == size, current.contentModificationDate == date else { continue }
                // Commit on the owner actor so an update cannot race this
                // atomic replacement with a newer downloaded rule archive.
                let saved = userDefaults.data(forKey: AdBlockAutomaticUpdateState.storageKey)
                    .flatMap { try? JSONDecoder().decode(AdBlockAutomaticUpdateState.self, from: $0) }
                let validated = saved.flatMap { stamp in AdBlockAutomaticUpdateState.snapshot(archive: url, defaults: userDefaults, hasRules: stamp.hasRules).map { $0 == stamp } } == true
                do {
                    try packed.write(to: url, options: .atomic)
                    if url.lastPathComponent == "merged-rules.json", validated, let saved {
                        AdBlockAutomaticUpdateState.record(archive: url, defaults: userDefaults, hasRules: saved.hasRules)
                    }
                } catch { /* Keep the readable original when compaction fails. */ }
            }
        }
        archiveCompactionTask = task
        await task.value; archiveCompactionTask = nil
    }

    private var preferencesReloadTask: Task<Void, Never>?
    /// Restoring a small settings backup must not decode and merge the entire
    /// rule archive on the UI thread. Keep compiled rules active until ready.
    func reloadFromDefaultsInBackground() {
        preferencesReloadTask?.cancel()
        load(rebuildForNewSubscriptions: false)
        let archiveURL = rulesArchiveURL
        let legacy = userDefaults.data(forKey: "\(cachedRulesKey)_by_id")
        preferencesReloadTask = Task { [weak self] in
            let stored = await Task.detached(priority: .utility) {
                Self.readStoredRules(archiveURL: archiveURL, legacy: legacy)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.finishArchiveMigration(stored)
            self.repairOutdatedRuleMetadata(stored.rules)
            await self.saveUpdatedRulesInBackground(stored.rules, saveArchive: false)
        }
    }

    func reloadFromDefaults() {
        let storedRules = storedParsedRulesByID()
        load(rebuildForNewSubscriptions: false)
        repairOutdatedRuleMetadata(storedRules)
        rebuildCacheFrom(parsedByID: storedRules)
    }

    private func mergeMissingDefaultSubscriptions(rebuildRules: Bool = true, persistChanges: Bool = true) {
        let defaults = Self.defaultSubscriptions()
        var changed = false
        for subscription in defaults where !subscriptions.contains(where: { $0.id == subscription.id }) {
            subscriptions.append(subscription)
            changed = true
        }
        if changed {
            if persistChanges { saveSubscriptions() }
            if rebuildRules { rebuildCacheFromStoredSubscriptions() }
        }
    }

    private func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            userDefaults.set(data, forKey: subscriptionsKey)
        }
    }

    private struct StoredRules {
        let rules: [String: ParsedAdBlockRules]
        let legacyToMigrate: Data?
        let archiveWasRead: Bool
    }

    nonisolated private static func readStoredRules(archiveURL: URL?, legacy: Data?) -> StoredRules {
        BrowserStartupTrace.markThread("subscription_archive_read_start")
        defer { BrowserStartupTrace.markThread("subscription_archive_read_end") }
        if let archiveURL, let data = try? Data(contentsOf: archiveURL),
           let decoded = try? JSONDecoder().decode([String: ParsedAdBlockRules].self, from: data) {
            return StoredRules(rules: decoded, legacyToMigrate: nil, archiveWasRead: true)
        }
        guard let data = legacy,
              let decoded = try? JSONDecoder().decode([String: ParsedAdBlockRules].self, from: data)
        else { return StoredRules(rules: [:], legacyToMigrate: nil, archiveWasRead: false) }
        return StoredRules(rules: decoded, legacyToMigrate: data, archiveWasRead: false)
    }

    private func finishArchiveMigration(_ stored: StoredRules) {
        let key = "\(cachedRulesKey)_by_id"
        if stored.archiveWasRead {
            userDefaults.removeObject(forKey: key)
        } else if let data = stored.legacyToMigrate, rulesArchiveURL != nil && writeRulesArchive(data) {
            userDefaults.removeObject(forKey: key)
        }
    }

    private func storedParsedRulesByID() -> [String: ParsedAdBlockRules] {
        let stored = Self.readStoredRules(archiveURL: rulesArchiveURL,
                                        legacy: userDefaults.data(forKey: "\(cachedRulesKey)_by_id"))
        finishArchiveMigration(stored)
        return stored.rules
    }

    private func saveParsedRulesArchive(_ data: Data) {
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
            try AdBlockRuleArchive.pack(data).write(to: rulesArchiveURL, options: .atomic)
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
        let merged = Self.mergeRules(parsedByID: parsedByID, subscriptions: subscriptions)
        // Starting the service must not invalidate compiled WebKit rules when
        // the enabled rule content is unchanged.
        if Self.cachedRules(userDefaults: userDefaults, key: cachedRulesKey) == merged,
           userDefaults.object(forKey: versionKey) != nil {
            recordValidatedAutomaticUpdateCache(merged)
            return
        }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        persistMergedRules(merged, data: data)
    }

    nonisolated private static func mergeRules(
        parsedByID: [String: ParsedAdBlockRules], subscriptions: [AdBlockSubscription]
    ) -> ParsedAdBlockRules {
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

        return ParsedAdBlockRules(
            networkURLFilters: network.values.sorted(),
            cosmeticSelectors: cosmetic.values.sorted(),
            networkRules: structuredNetwork.values,
            cosmeticRules: structuredCosmetic.values,
            cosmeticExceptions: cosmeticExceptions.values
        )
    }

    private func saveUpdatedRulesInBackground(_ parsedByID: [String: ParsedAdBlockRules], saveArchive: Bool) async {
        // A toggle or iCloud refresh can arrive while the worker is preparing
        // the cache. Retry with the current subscriptions before committing.
        while true {
            let snapshot = subscriptions
            let revision = userDefaults.double(forKey: versionKey)
            let hasVersion = userDefaults.object(forKey: versionKey) != nil
            let defaults = userDefaults, key = cachedRulesKey
            let prepared = await Task.detached(priority: .utility) {
                BrowserStartupTrace.markThread("subscription_merge_start")
                defer { BrowserStartupTrace.markThread("subscription_merge_end") }
                let merged = Self.mergeRules(parsedByID: parsedByID, subscriptions: snapshot)
                let unchanged = Self.cachedRules(userDefaults: defaults, key: key) == merged
                // A list may be deleted while its download/encoding is in flight.
                // Never put deleted subscriptions back into the persistent archive.
                let liveIDs = Set(snapshot.map(\.id))
                let archive = saveArchive ? (try? AdBlockRuleArchive.pack(JSONEncoder().encode(parsedByID.filter { liveIDs.contains($0.key) }))) : nil
                let encoded = unchanged && hasVersion ? nil : try? AdBlockRuleArchive.pack(JSONEncoder().encode(merged))
                return (merged, unchanged, encoded, archive)
            }.value
            guard !Task.isCancelled else { return }
            guard snapshot == subscriptions, revision == userDefaults.double(forKey: versionKey) else { continue }
            saveSubscriptions()
            if let archiveData = prepared.3 { saveParsedRulesArchive(archiveData) }
            if prepared.1, userDefaults.object(forKey: versionKey) != nil {
                recordValidatedAutomaticUpdateCache(prepared.0)
            } else if let data = prepared.2 {
                persistMergedRules(prepared.0, data: data)
            }
            return
        }
    }

    private func persistMergedRules(_ merged: ParsedAdBlockRules, data: Data) {
        if let url = Self.mergedArchiveURL(userDefaults: userDefaults, key: cachedRulesKey) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AdBlockRuleArchive.pack(data).write(to: url, options: .atomic)
                userDefaults.removeObject(forKey: cachedRulesKey)
                Self.decodedCache.setObject(RuleBox(merged), forKey: url.path as NSString, cost: data.count)
            } catch {
                lastError = error.localizedDescription
                return
            }
        } else {
            userDefaults.set(data, forKey: cachedRulesKey)
        }
        userDefaults.set(Date().timeIntervalSince1970, forKey: versionKey)
        recordValidatedAutomaticUpdateCache(merged)
    }

    private func recordValidatedAutomaticUpdateCache(_ rules: ParsedAdBlockRules) {
        guard versionKey == "soulo_ad_block_subscription_rules_version",
              let archive = Self.mergedArchiveURL(userDefaults: userDefaults, key: cachedRulesKey) else { return }
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: userDefaults,
                                          hasRules: !rules.networkRules.isEmpty || !rules.cosmeticRules.isEmpty)
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
              let decoded = try? AdBlockRuleArchive.decode(ParsedAdBlockRules.self, from: data),
              decoded.parserVersion == AdBlockRuleParser.version else { return .empty }
        decodedCache.setObject(RuleBox(decoded), forKey: cacheKey, cost: data.count)
        return decoded
    }

    nonisolated static func rulesSignature(userDefaults: UserDefaults = .standard, versionKey: String = "soulo_ad_block_subscription_rules_version") -> String {
        String(userDefaults.double(forKey: versionKey))
    }

    static func defaultSubscriptions() -> [AdBlockSubscription] {
        [
            AdBlockSubscription(
                id: "easylist",
                name: "EasyList",
                urlString: "https://easylist.to/easylist/easylist.txt",
                isEnabled: false,
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
                isEnabled: false,
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
                isEnabled: false,
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

/// Lossless local cache compression. Old JSON archives remain readable.
enum AdBlockRuleArchive {
    private static let header = Data("SouloRulesLZFSE1\n".utf8)
    static func isPacked(_ data: Data) -> Bool { data.starts(with: header) }
    static func pack(_ data: Data) throws -> Data {
        guard data.count > 4096, !isPacked(data) else { return data }
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        return compressed.count + header.count < data.count ? header + compressed : data
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let json: Data
        if data.starts(with: header) {
            json = try (data.dropFirst(header.count) as NSData).decompressed(using: .lzfse) as Data
        } else { json = data }
        return try JSONDecoder().decode(type, from: json)
    }
}
