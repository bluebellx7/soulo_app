import Foundation
import WebKit

struct BuiltInAdRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case network, cosmetic, tiledBanner }
    let id: String
    let kind: Kind
    var pattern: String
    var domains: [String] = []
    var resourceTypes: [String] = []
    var isEnabled = true

    var networkRule: AdBlockNetworkRule {
        AdBlockNetworkRule(urlFilter: pattern, resourceTypes: resourceTypes, ifDomains: domains.map { "*" + $0 })
    }
    var cosmeticRule: AdBlockCosmeticRule { AdBlockCosmeticRule(selector: pattern, ifDomains: domains) }
}

@MainActor
final class BuiltInAdRuleStore: ObservableObject {
    static let shared = BuiltInAdRuleStore()
    nonisolated static let storageKey = "soulo_builtin_ad_rule_overrides_v1"
    nonisolated static let versionKey = "soulo_builtin_ad_rule_revision"
    @Published private(set) var revision = UUID()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var rules: [BuiltInAdRule] { Self.effectiveRules(defaults: defaults) }

    nonisolated static func effectiveRules(defaults: UserDefaults = .standard) -> [BuiltInAdRule] {
        let overrides = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: BuiltInAdRule].self, from: $0) } ?? [:]
        return AdBlockService.defaultBuiltInRules.map { original in
            guard var changed = overrides[original.id], changed.id == original.id, changed.kind == original.kind else { return original }
            if changed.id == "paired-image-banner",
               changed.pattern == ":root:not([data-soulo-ad-picker-active]) [data-soulo-image-banner]" {
                changed.pattern = ManualAdBlockRuntime.imageBannerSelector
            }
            return changed
        }
    }
    nonisolated static func signature(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: versionKey) ?? "default"
    }

    func save(_ rule: BuiltInAdRule) async -> Bool {
        guard AdBlockService.defaultBuiltInRules.contains(where: { $0.id == rule.id && $0.kind == rule.kind }),
              rule.domains.allSatisfy({ !$0.isEmpty && $0.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil }) else { return false }
        if rule.kind != .tiledBanner {
            guard !rule.pattern.isEmpty, rule.pattern.count <= 220 else { return false }
            if rule.kind == .network {
                guard AdBlockService.sanitizedContentBlockerURLFilter(rule.pattern) == rule.pattern,
                      !rule.resourceTypes.isEmpty,
                      Set(rule.resourceTypes).isSubset(of: ["script", "image", "style-sheet", "font", "media", "raw", "popup"]) else { return false }
            } else if AdBlockService.sanitizedContentBlockerSelector(rule.pattern) != rule.pattern { return false }
            var trigger: [String: Any] = ["url-filter": rule.kind == .network ? rule.pattern : ".*"]
            if !rule.domains.isEmpty { trigger["if-domain"] = rule.domains.map { "*" + $0 } }
            if rule.kind == .network { trigger["resource-type"] = rule.resourceTypes }
            let action: [String: Any] = rule.kind == .network ? ["type": "block"] : ["type": "css-display-none", "selector": rule.pattern]
            if rule.kind == .cosmetic && !ManualAdBlockService.validSelector(rule.pattern) { return false }
            guard let data = try? JSONSerialization.data(withJSONObject: [["trigger": trigger, "action": action]]),
                  let json = String(data: data, encoding: .utf8) else { return false }
            let valid = await withCheckedContinuation { continuation in
                let identifier = "SouloRuleValidation-\(UUID())"
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { result, _ in
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
                    continuation.resume(returning: result != nil)
                }
            }
            guard valid else { return false }
        }
        var overrides = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: BuiltInAdRule].self, from: $0) } ?? [:]
        overrides[rule.id] = rule
        defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.storageKey)
        changed()
        return true
    }

    func reset(_ id: String? = nil) {
        if let id {
            var overrides = defaults.data(forKey: Self.storageKey)
                .flatMap { try? JSONDecoder().decode([String: BuiltInAdRule].self, from: $0) } ?? [:]
            overrides.removeValue(forKey: id)
            defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.storageKey)
        } else { defaults.removeObject(forKey: Self.storageKey) }
        changed()
    }
    private func changed() {
        revision = UUID()
        defaults.set(revision.uuidString, forKey: Self.versionKey)
    }
}

/// Nonisolated filtering queries can read session exceptions without accessing
/// the main-actor settings object. Each service owns only its own contribution.
private final class TemporaryAdBlockExceptions: @unchecked Sendable {
    struct Context: Hashable, Sendable {
        let defaults: ObjectIdentifier
        let key: String
    }
    private let lock = NSLock()
    private var entries: [Context: [UUID: [String]]] = [:]

    func replace(_ hosts: [String], owner: UUID, context: Context) {
        lock.lock(); defer { lock.unlock() }
        if hosts.isEmpty {
            entries[context]?[owner] = nil
            if entries[context]?.isEmpty == true { entries[context] = nil }
        } else { entries[context, default: [:]][owner] = hosts }
    }

    func hosts(in context: Context) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries[context]?.values.flatMap { $0 } ?? []
    }
}

@MainActor
final class AdBlockSettingsService: ObservableObject {
    static let shared = AdBlockSettingsService()
    nonisolated private static let temporaryExceptions = TemporaryAdBlockExceptions()

    /// Match AppStorage/UserDefaults boolean semantics, including argument-domain
    /// strings. Casting "NO" to Bool would incorrectly fall back to enabled.
    nonisolated static func filteringEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "ad_block_enabled") == nil ? true : defaults.bool(forKey: "ad_block_enabled")
    }

    @Published private(set) var allowlistedHosts: [String] = []
    @Published private(set) var temporaryAllowlistedHosts: [String] = []
    @Published private(set) var hiddenElementCountByHost: [String: Int] = [:]
    var permanentAllowlistedHosts: [String] { persistentHosts }

    private var persistentHosts: [String] = []
    private let allowlistKey: String
    private let statsKey: String
    private let userDefaults: UserDefaults
    private let temporaryOwner = UUID()
    private let temporaryContext: TemporaryAdBlockExceptions.Context
    private let statisticsPersistence = DeferredPersistence()

    init(
        allowlistKey: String = "soulo_ad_block_allowlisted_hosts",
        statsKey: String = "soulo_ad_block_hidden_counts",
        userDefaults: UserDefaults = .standard
    ) {
        self.allowlistKey = allowlistKey
        self.statsKey = statsKey
        self.userDefaults = userDefaults
        self.temporaryContext = .init(defaults: ObjectIdentifier(userDefaults), key: allowlistKey)
        load()
    }

    deinit { Self.temporaryExceptions.replace([], owner: temporaryOwner, context: temporaryContext) }

    func isAllowlisted(_ host: String?) -> Bool {
        Self.isHostAllowlisted(host, allowlistedHosts: allowlistedHosts)
    }

    func addAllowlistedHost(_ host: String) {
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        if !persistentHosts.contains(cleanHost) { persistentHosts.append(cleanHost); persistentHosts.sort() }
        temporaryAllowlistedHosts.removeAll { Self.isHostAllowlisted($0, allowlistedHosts: [cleanHost]) }
        saveAllowlist()
    }

    func removeAllowlistedHost(_ host: String) {
        let cleanHost = normalizedHost(host)
        persistentHosts.removeAll { $0 == cleanHost }
        temporaryAllowlistedHosts.removeAll { $0 == cleanHost }
        saveAllowlist()
    }

    func setFilteringEnabled(_ enabled: Bool, for host: String) {
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        if enabled {
            // Restore the matching site exception, including one inherited
            // from its parent domain, so the switch can actually turn on.
            persistentHosts.removeAll { Self.isHostAllowlisted(cleanHost, allowlistedHosts: [$0]) }
            temporaryAllowlistedHosts.removeAll { Self.isHostAllowlisted(cleanHost, allowlistedHosts: [$0]) }
            saveAllowlist()
        } else {
            addAllowlistedHost(cleanHost)
        }
    }

    /// Applies across this app session, including background/foreground moves.
    /// Nothing is written to preferences, settings backups or iCloud.
    func temporarilyDisableFiltering(for host: String) {
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty,
              !Self.isHostAllowlisted(cleanHost, allowlistedHosts: persistentHosts),
              !temporaryAllowlistedHosts.contains(cleanHost) else { return }
        temporaryAllowlistedHosts.append(cleanHost)
        temporaryAllowlistedHosts.sort()
        publishAllowlist()
    }

    func isTemporarilyAllowlisted(_ host: String?) -> Bool {
        !Self.isHostAllowlisted(host, allowlistedHosts: persistentHosts)
            && Self.isHostAllowlisted(host, allowlistedHosts: temporaryAllowlistedHosts)
    }

    func clearTemporaryException(for host: String) {
        let cleanHost = normalizedHost(host)
        temporaryAllowlistedHosts.removeAll { Self.isHostAllowlisted(cleanHost, allowlistedHosts: [$0]) }
        publishAllowlist()
    }

    func clearTemporaryExceptions() {
        temporaryAllowlistedHosts = []
        publishAllowlist()
    }

    func toggleAllowlist(for host: String?) {
        guard let host else { return }
        if isAllowlisted(host) {
            setFilteringEnabled(true, for: host)
        } else {
            addAllowlistedHost(host)
        }
    }

    func recordHiddenElementCount(_ count: Int, for host: String?) {
        guard !userDefaults.bool(forKey: "is_incognito"),
              (1...SafeNumericValue.maximumEventCount).contains(count), let host else { return }
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        hiddenElementCountByHost[cleanHost] = SafeNumericValue.addingCounts(hiddenElementCountByHost[cleanHost, default: 0], count)
        statisticsPersistence.schedule { [weak self] in self?.saveStats() }
    }

    func hiddenElementCount(for host: String?) -> Int {
        guard let host else { return 0 }
        let cleanHost = normalizedHost(host)
        return hiddenElementCountByHost[cleanHost] ?? 0
    }

    func resetStats() {
        hiddenElementCountByHost = [:]
        saveStats()
    }

    func resetStats(for host: String?) {
        guard let host else { return }
        let cleanHost = normalizedHost(host)
        hiddenElementCountByHost.removeValue(forKey: cleanHost)
        saveStats()
    }

    private func normalizedHost(_ host: String) -> String {
        Self.normalizedHost(host)
    }

    nonisolated static func isHostAllowlisted(_ host: String?, userDefaults: UserDefaults = .standard) -> Bool {
        let key = "soulo_ad_block_allowlisted_hosts"
        let temporary = temporaryExceptions.hosts(in: .init(defaults: ObjectIdentifier(userDefaults), key: key))
        return isHostAllowlisted(host, allowlistedHosts: normalizedAllowlistedHosts(
            (userDefaults.stringArray(forKey: key) ?? []) + temporary))
    }

    nonisolated static func isHostAllowlisted(_ host: String?, allowlistedHosts: [String]) -> Bool {
        guard let host else { return false }
        let cleanHost = normalizedHost(host)
        return allowlistedHosts.contains { cleanHost == $0 || cleanHost.hasSuffix(".\($0)") }
    }

    nonisolated static func normalizedHost(_ host: String) -> String {
        host.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    nonisolated static func normalizedAllowlistedHosts(_ hosts: [String]) -> [String] {
        Array(Set(hosts.map(normalizedHost).filter { !$0.isEmpty })).sorted()
    }

    private func load() {
        persistentHosts = Self.normalizedAllowlistedHosts(userDefaults.stringArray(forKey: allowlistKey) ?? [])
        publishAllowlist()
        if let data = userDefaults.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            hiddenElementCountByHost = decoded
        }
    }

    func reloadFromDefaults() {
        flushPendingStatistics()
        load()
    }

    func flushPendingStatistics() { statisticsPersistence.flush() }

    private func saveAllowlist() {
        publishAllowlist()
        userDefaults.set(persistentHosts, forKey: allowlistKey)
    }

    private func publishAllowlist() {
        Self.temporaryExceptions.replace(temporaryAllowlistedHosts, owner: temporaryOwner, context: temporaryContext)
        allowlistedHosts = Self.normalizedAllowlistedHosts(persistentHosts + temporaryAllowlistedHosts)
    }

    private func saveStats() {
        statisticsPersistence.cancel()
        if let data = try? JSONEncoder().encode(hiddenElementCountByHost) {
            userDefaults.set(data, forKey: statsKey)
        }
    }
}
