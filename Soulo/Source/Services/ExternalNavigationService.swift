import Foundation

@MainActor
final class ExternalNavigationService: ObservableObject {
    static let shared = ExternalNavigationService()
    nonisolated static let promptEnabledKey = "soulo_external_navigation_prompt_enabled"

    @Published var promptEnabled: Bool {
        didSet { userDefaults.set(promptEnabled, forKey: promptEnabledKey) }
    }

    @Published private(set) var blockedHosts: Set<String> = []
    @Published var suppressPrompts: Bool {
        didSet { userDefaults.set(suppressPrompts, forKey: suppressPromptsKey) }
    }

    private let blockedHostsKey: String
    private let suppressPromptsKey: String
    private let promptEnabledKey: String
    private let userDefaults: UserDefaults

    init(
        blockedHostsKey: String = "soulo_external_navigation_blocked_hosts",
        suppressPromptsKey: String = "soulo_external_navigation_suppress_prompts",
        promptEnabledKey: String = ExternalNavigationService.promptEnabledKey,
        userDefaults: UserDefaults = .standard
    ) {
        self.blockedHostsKey = blockedHostsKey
        self.suppressPromptsKey = suppressPromptsKey
        self.promptEnabledKey = promptEnabledKey
        self.userDefaults = userDefaults
        blockedHosts = Set(userDefaults.stringArray(forKey: blockedHostsKey) ?? [])
        suppressPrompts = userDefaults.bool(forKey: suppressPromptsKey)
        promptEnabled = userDefaults.object(forKey: promptEnabledKey) == nil
            || userDefaults.bool(forKey: promptEnabledKey)
    }

    func shouldSilentlyBlock(_ url: URL) -> Bool {
        guard suppressPrompts else { return false }
        guard let host = normalizedHost(from: url) else { return true }
        return blockedHosts.isEmpty || blockedHosts.contains(host)
    }

    func rememberBlock(for url: URL) {
        if let host = normalizedHost(from: url) {
            blockedHosts.insert(host)
            userDefaults.set(Array(blockedHosts), forKey: blockedHostsKey)
        }
        suppressPrompts = true
    }

    func removeHost(_ host: String) {
        blockedHosts.remove(normalizedHost(host))
        userDefaults.set(Array(blockedHosts), forKey: blockedHostsKey)
        if blockedHosts.isEmpty {
            suppressPrompts = false
        }
    }

    func clear() {
        blockedHosts.removeAll()
        userDefaults.removeObject(forKey: blockedHostsKey)
    }

    func reloadFromDefaults() {
        promptEnabled = userDefaults.object(forKey: promptEnabledKey) == nil
            || userDefaults.bool(forKey: promptEnabledKey)
        blockedHosts = Set(userDefaults.stringArray(forKey: blockedHostsKey) ?? [])
        suppressPrompts = userDefaults.bool(forKey: suppressPromptsKey)
    }

    private func normalizedHost(from url: URL) -> String? {
        if let host = url.host {
            return normalizedHost(host)
        }
        return url.scheme?.lowercased()
    }

    private func normalizedHost(_ host: String) -> String {
        host.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}
