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

@MainActor
final class AdBlockSettingsService: ObservableObject {
    static let shared = AdBlockSettingsService()

    @Published private(set) var allowlistedHosts: [String] = []
    @Published private(set) var hiddenElementCountByHost: [String: Int] = [:]

    private let allowlistKey: String
    private let statsKey: String
    private let userDefaults: UserDefaults
    private let statisticsPersistence = DeferredPersistence()

    init(
        allowlistKey: String = "soulo_ad_block_allowlisted_hosts",
        statsKey: String = "soulo_ad_block_hidden_counts",
        userDefaults: UserDefaults = .standard
    ) {
        self.allowlistKey = allowlistKey
        self.statsKey = statsKey
        self.userDefaults = userDefaults
        load()
    }

    func isAllowlisted(_ host: String?) -> Bool {
        Self.isHostAllowlisted(host, allowlistedHosts: allowlistedHosts)
    }

    func addAllowlistedHost(_ host: String) {
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty, !allowlistedHosts.contains(cleanHost) else { return }
        allowlistedHosts.append(cleanHost)
        allowlistedHosts.sort()
        saveAllowlist()
    }

    func removeAllowlistedHost(_ host: String) {
        let cleanHost = normalizedHost(host)
        allowlistedHosts.removeAll { $0 == cleanHost }
        saveAllowlist()
    }

    func toggleAllowlist(for host: String?) {
        guard let host else { return }
        if isAllowlisted(host) {
            removeAllowlistedHost(host)
        } else {
            addAllowlistedHost(host)
        }
    }

    func recordHiddenElementCount(_ count: Int, for host: String?) {
        guard count > 0, let host else { return }
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        hiddenElementCountByHost[cleanHost, default: 0] += count
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
        isHostAllowlisted(host, allowlistedHosts: userDefaults.stringArray(forKey: "soulo_ad_block_allowlisted_hosts") ?? [])
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

    private func load() {
        allowlistedHosts = userDefaults.stringArray(forKey: allowlistKey) ?? []
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
        userDefaults.set(allowlistedHosts, forKey: allowlistKey)
    }

    private func saveStats() {
        statisticsPersistence.cancel()
        if let data = try? JSONEncoder().encode(hiddenElementCountByHost) {
            userDefaults.set(data, forKey: statsKey)
        }
    }
}
