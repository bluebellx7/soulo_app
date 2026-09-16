import Foundation

struct ManualAdRule: Codable, Identifiable, Equatable {
    var id = UUID()
    let host: String
    /// Encoded path only: never retain query strings, tokens, or page text.
    let path: String?
    let selector: String
    let createdAt: Date
}

@MainActor
final class ManualAdBlockService: ObservableObject {
    static let shared = ManualAdBlockService()
    static let storageKey = "soulo_manual_ad_rules_v1"
    @Published private(set) var rules: [ManualAdRule] = []
    @Published private(set) var revision = UUID()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([ManualAdRule].self, from: data) {
            rules = Array(saved.filter {
                !$0.host.isEmpty && Self.validSelector($0.selector)
            }.prefix(500))
        }
    }

    static func canUse(on url: URL?, enabled: Bool, allowlistedHosts: [String]) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, enabled else { return false }
        return !AdBlockSettingsService.isHostAllowlisted(url.host, allowlistedHosts: allowlistedHosts)
            && !WebCompatibilityService.shouldBypassWebProtection(for: url)
    }

    static func pagePath(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        return path.isEmpty ? "/" : path
    }

    static func validSelector(_ value: String) -> Bool {
        // Only the app's selector generator supplies selectors. Do not accept CSS
        // declarations or selector lists through persistence or a bridge message.
        !value.isEmpty && value.utf8.count <= 1024
            && value.rangeOfCharacter(from: CharacterSet(charactersIn: "{},;\n\r")) == nil
            && !["html", "body", "*", ":root", "main", "article", "form"].contains(value.lowercased())
    }

    @discardableResult
    func save(url: URL, selector: String, wholeSite: Bool) -> ManualAdRule? {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme ?? ""),
              Self.validSelector(selector) else { return nil }
        let path = wholeSite ? nil : Self.pagePath(url)
        if let existing = rules.first(where: { $0.host == host && $0.path == path && $0.selector == selector }) {
            return existing
        }
        guard rules.count < 500 else { return nil }
        let rule = ManualAdRule(host: host, path: path, selector: selector, createdAt: Date())
        rules.append(rule)
        persist()
        return rule
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func restore(_ rule: ManualAdRule) -> Bool {
        if rules.contains(where: { $0.id == rule.id }) { return true }
        guard rules.count < 500, !rule.host.isEmpty, Self.validSelector(rule.selector) else { return false }
        // A newly saved equivalent rule already restores the same behavior.
        if rules.contains(where: { $0.host == rule.host && $0.path == rule.path && $0.selector == rule.selector }) {
            return true
        }
        rules.append(rule)
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Self.storageKey)
        }
        revision = UUID()
    }
}
