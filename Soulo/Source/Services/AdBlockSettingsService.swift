import Foundation

@MainActor
final class AdBlockSettingsService: ObservableObject {
    static let shared = AdBlockSettingsService()

    @Published private(set) var allowlistedHosts: [String] = []
    @Published private(set) var hiddenElementCountByHost: [String: Int] = [:]

    private let allowlistKey: String
    private let statsKey: String
    private let userDefaults: UserDefaults

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
        saveStats()
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

    private func saveAllowlist() {
        userDefaults.set(allowlistedHosts, forKey: allowlistKey)
    }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(hiddenElementCountByHost) {
            userDefaults.set(data, forKey: statsKey)
        }
    }
}
