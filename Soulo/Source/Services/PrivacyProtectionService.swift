import Foundation

@MainActor
final class PrivacyProtectionService: ObservableObject {
    static let shared = PrivacyProtectionService()

    @Published private(set) var summariesByHost: [String: SitePrivacySummary] = [:]
    @Published private(set) var protectionDisabledHosts: [String] = []

    private let userDefaults: UserDefaults
    private let summariesKey: String
    private let disabledHostsKey: String

    init(
        userDefaults: UserDefaults = .standard,
        summariesKey: String = "soulo_privacy_summaries",
        disabledHostsKey: String = "soulo_privacy_disabled_hosts"
    ) {
        self.userDefaults = userDefaults
        self.summariesKey = summariesKey
        self.disabledHostsKey = disabledHostsKey
        load()
    }

    func summary(for host: String?) -> SitePrivacySummary {
        let cleanHost = Self.normalizedHost(host)
        guard !cleanHost.isEmpty else { return .empty(host: "") }
        return summariesByHost[cleanHost] ?? .empty(host: cleanHost)
    }

    func isProtectionDisabled(for host: String?) -> Bool {
        Self.isProtectionDisabled(host, disabledHosts: protectionDisabledHosts)
    }

    func setProtectionEnabled(_ enabled: Bool, for host: String?) {
        let cleanHost = Self.normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        if enabled {
            protectionDisabledHosts.removeAll { $0 == cleanHost }
        } else if !protectionDisabledHosts.contains(cleanHost) {
            protectionDisabledHosts.append(cleanHost)
            protectionDisabledHosts.sort()
        }
        saveDisabledHosts()
    }

    func recordHiddenElementCount(_ count: Int, for host: String?) {
        guard count > 0 else { return }
        updateSummary(for: host) { summary in
            summary.hiddenElementCount += count
        }
    }

    func recordTrackerHosts(_ hosts: [String], for pageHost: String?) {
        let cleanHosts = Array(Set(hosts.map(Self.normalizedHost).filter { !$0.isEmpty }))
        guard !cleanHosts.isEmpty else { return }
        updateSummary(for: pageHost) { summary in
            for host in cleanHosts where !Self.domainMatches(host, pageHost: summary.host) {
                let classification = Self.classify(host: host)
                let observation = ResourceObservation(
                    urlString: "https://\(host)",
                    resourceType: "unknown",
                    pageURLString: "https://\(summary.host)",
                    potentiallyBlocked: true
                )
                if let request = TrackerRadarService.shared.classify(
                    observation: observation,
                    protectionEnabled: !Self.isProtectionDisabled(summary.host, disabledHosts: protectionDisabledHosts)
                ) {
                    summary.trackerRequests.insert(request)
                }
                var set = summary.trackerHostsByCategory[classification.category] ?? []
                set.insert(classification.host)
                summary.trackerHostsByCategory[classification.category] = set
                summary.trackerCompanies.insert(classification.company)
            }
        }
    }

    func recordResourceObservations(_ observations: [ResourceObservation], for pageURL: URL?) {
        guard !observations.isEmpty else { return }
        let pageHost = pageURL?.host ?? observations.first.flatMap { URL(string: $0.pageURLString)?.host }
        let protectionEnabled = !isProtectionDisabled(for: pageHost)
        updateSummary(for: pageHost) { summary in
            for observation in observations {
                guard let request = TrackerRadarService.shared.classify(
                    observation: observation,
                    protectionEnabled: protectionEnabled
                ) else {
                    continue
                }
                summary.trackerRequests.insert(request)
                if request.state != .allowedOtherThirdPartyRequest {
                    var set = summary.trackerHostsByCategory[request.category] ?? []
                    set.insert(request.host)
                    summary.trackerHostsByCategory[request.category] = set
                    summary.trackerCompanies.insert(request.networkNameForDisplay)
                }
            }
        }
    }

    func recordHTTPSUpgrade(for host: String?) {
        updateSummary(for: host) { summary in
            summary.httpsUpgradeCount += 1
        }
    }

    func recordTrackingParametersStripped(_ count: Int, for host: String?) {
        guard count > 0 else { return }
        updateSummary(for: host) { summary in
            summary.strippedTrackingParameterCount += count
        }
    }

    func recordCookieBannerActions(_ count: Int, for host: String?) {
        guard count > 0 else { return }
        updateSummary(for: host) { summary in
            summary.cookieBannerActionCount += count
        }
    }

    func resetSummary(for host: String?) {
        let cleanHost = Self.normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        summariesByHost.removeValue(forKey: cleanHost)
        saveSummaries()
    }

    func resetAllSummaries() {
        summariesByHost = [:]
        saveSummaries()
    }

    private func updateSummary(for host: String?, _ update: (inout SitePrivacySummary) -> Void) {
        let cleanHost = Self.normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        var summary = summariesByHost[cleanHost] ?? .empty(host: cleanHost)
        update(&summary)
        summariesByHost[cleanHost] = summary
        saveSummaries()
    }

    private func load() {
        if let data = userDefaults.data(forKey: summariesKey),
           let decoded = try? JSONDecoder().decode([String: SitePrivacySummary].self, from: data) {
            summariesByHost = decoded
        }
        protectionDisabledHosts = userDefaults.stringArray(forKey: disabledHostsKey) ?? []
    }

    private func saveSummaries() {
        if let data = try? JSONEncoder().encode(summariesByHost) {
            userDefaults.set(data, forKey: summariesKey)
        }
    }

    private func saveDisabledHosts() {
        userDefaults.set(protectionDisabledHosts, forKey: disabledHostsKey)
    }

    nonisolated static func isProtectionDisabled(_ host: String?, userDefaults: UserDefaults = .standard) -> Bool {
        isProtectionDisabled(host, disabledHosts: userDefaults.stringArray(forKey: "soulo_privacy_disabled_hosts") ?? [])
    }

    nonisolated static func isProtectionDisabled(_ host: String?, disabledHosts: [String]) -> Bool {
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty else { return false }
        return disabledHosts.contains { cleanHost == $0 || cleanHost.hasSuffix(".\($0)") }
    }

    nonisolated static func normalizedHost(_ host: String?) -> String {
        (host ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    nonisolated static func classify(host: String) -> TrackerClassification {
        let cleanHost = normalizedHost(host)

        let rules: [(tokens: [String], company: String, category: TrackerCategory)] = [
            (["doubleclick", "googlesyndication", "googleadservices", "adservice.google", "googleads"], "Google Ads", .advertising),
            (["google-analytics", "googletagmanager", "analytics.google"], "Google Analytics", .analytics),
            (["facebook.com", "connect.facebook", "fbcdn", "instagram"], "Meta", .social),
            (["tiktok", "byteoversea", "bytedance", "oceanengine"], "ByteDance", .social),
            (["baidu", "hm.baidu", "cnzz", "umeng"], "Baidu", .analytics),
            (["clarity.ms", "bat.bing", "bing.com"], "Microsoft", .analytics),
            (["hotjar", "mouseflow"], "Behavior Analytics", .analytics),
            (["taboola", "outbrain"], "Content Recommendation", .content),
            (["criteo", "adnxs", "rubiconproject", "pubmatic", "openx", "smartadserver"], "Ad Exchange", .advertising),
            (["scorecardresearch", "quantserve"], "Measurement", .analytics),
            (["twitter", "x.com", "ads-twitter"], "X", .social),
            (["linkedin"], "LinkedIn", .social),
            (["amazon-adsystem", "mads.amazon"], "Amazon Ads", .advertising)
        ]

        if let match = rules.first(where: { rule in
            rule.tokens.contains { cleanHost.contains($0) }
        }) {
            return TrackerClassification(host: cleanHost, company: match.company, category: match.category)
        }

        if cleanHost.contains("ad") || cleanHost.contains("ads") {
            return TrackerClassification(host: cleanHost, company: "Advertising Network", category: .advertising)
        }

        return TrackerClassification(host: cleanHost, company: cleanHost, category: .unknown)
    }

    private nonisolated static func domainMatches(_ host: String, pageHost: String) -> Bool {
        let cleanHost = normalizedHost(host)
        let cleanPageHost = normalizedHost(pageHost)
        guard !cleanHost.isEmpty, !cleanPageHost.isEmpty else { return false }
        return cleanHost == cleanPageHost || cleanHost.hasSuffix(".\(cleanPageHost)")
    }
}
