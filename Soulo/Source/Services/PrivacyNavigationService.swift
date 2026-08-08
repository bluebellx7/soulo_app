import Foundation

enum PrivacyNavigationDecision: Equatable {
    case allow
    case redirect(URL)
}

struct PrivacyNavigationService {
    static let shared = PrivacyNavigationService()

    private let userDefaults: UserDefaults
    private let httpsUpgradeKey: String
    private let stripTrackingParametersKey: String
    private let httpsUpgradeExcludedHostsKey: String

    private let trackingParameterPrefixes: Set<String> = [
        "utm_", "ga_", "pk_", "mtm_"
    ]

    private let trackingParameterNames: Set<String> = [
        "_branch_match_id",
        "_branch_referrer",
        "_hsenc",
        "_hsmi",
        "dclid",
        "fb_action_ids",
        "fb_action_types",
        "fb_ref",
        "fb_source",
        "fbclid",
        "gbraid",
        "gclid",
        "igshid",
        "li_fat_id",
        "mc_cid",
        "mc_eid",
        "mibextid",
        "mkt_tok",
        "msclkid",
        "oly_anon_id",
        "oly_enc_id",
        "rb_clickid",
        "s_cid",
        "scid",
        "ttclid",
        "twclid",
        "vero_id",
        "wbraid",
        "wickedid",
        "yclid",
        "zanpid"
    ]

    init(
        userDefaults: UserDefaults = .standard,
        httpsUpgradeKey: String = "privacy_https_upgrade_enabled",
        stripTrackingParametersKey: String = "privacy_strip_tracking_parameters",
        httpsUpgradeExcludedHostsKey: String = "privacy_https_upgrade_excluded_hosts"
    ) {
        self.userDefaults = userDefaults
        self.httpsUpgradeKey = httpsUpgradeKey
        self.stripTrackingParametersKey = stripTrackingParametersKey
        self.httpsUpgradeExcludedHostsKey = httpsUpgradeExcludedHostsKey
    }

    func decision(for url: URL, isMainFrame: Bool = true) -> PrivacyNavigationDecision {
        guard isMainFrame, let transformed = transformedURL(for: url) else {
            return .allow
        }
        return .redirect(transformed)
    }

    func transformedURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard !WebCompatibilityService.shouldBypassWebProtection(for: url, fallbackHost: url.host),
              !PrivacyProtectionService.isProtectionDisabled(url.host, userDefaults: userDefaults) else {
            return nil
        }

        var transformed = url

        if isHTTPSUpgradeEnabled,
           let upgraded = httpsUpgradedURL(from: transformed) {
            transformed = upgraded
        }

        if isTrackingParameterStrippingEnabled,
           let stripped = strippedTrackingParametersURL(from: transformed) {
            transformed = stripped
        }

        return transformed.absoluteString == url.absoluteString ? nil : transformed
    }

    private var isHTTPSUpgradeEnabled: Bool {
        userDefaults.object(forKey: httpsUpgradeKey) as? Bool ?? true
    }

    private var isTrackingParameterStrippingEnabled: Bool {
        userDefaults.object(forKey: stripTrackingParametersKey) as? Bool ?? true
    }

    func strippedTrackingParameterCount(from originalURL: URL, to transformedURL: URL) -> Int {
        let originalNames = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        let transformedNames = Set(URLComponents(url: transformedURL, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        return originalNames.filter { isTrackingParameter($0) && !transformedNames.contains($0) }.count
    }

    func recordHTTPSUpgradeFailure(for host: String?) {
        let cleanHost = PrivacyProtectionService.normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        var hosts = userDefaults.stringArray(forKey: httpsUpgradeExcludedHostsKey) ?? []
        guard !hosts.contains(cleanHost) else { return }
        hosts.append(cleanHost)
        hosts.sort()
        userDefaults.set(hosts, forKey: httpsUpgradeExcludedHostsKey)
    }

    private func httpsUpgradedURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http",
              let host = url.host,
              !isLocalOrPrivateHost(host),
              !isHTTPSUpgradeExcluded(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.scheme = "https"
        if components.port == 80 {
            components.port = nil
        }
        return components.url
    }

    private func isHTTPSUpgradeExcluded(_ host: String) -> Bool {
        let cleanHost = PrivacyProtectionService.normalizedHost(host)
        let excludedHosts = userDefaults.stringArray(forKey: httpsUpgradeExcludedHostsKey) ?? []
        return excludedHosts.contains { cleanHost == $0 || cleanHost.hasSuffix(".\($0)") }
    }

    private func strippedTrackingParametersURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return nil
        }

        let filteredItems = queryItems.filter { !isTrackingParameter($0.name) }
        guard filteredItems.count != queryItems.count else {
            return nil
        }

        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        return components.url
    }

    private func isTrackingParameter(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        if trackingParameterNames.contains(lowercased) {
            return true
        }
        return trackingParameterPrefixes.contains { lowercased.hasPrefix($0) }
    }

    private func isLocalOrPrivateHost(_ host: String) -> Bool {
        let cleanHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if cleanHost == "localhost"
            || cleanHost == "::1"
            || cleanHost.hasSuffix(".local")
            || cleanHost.hasPrefix("127.")
            || cleanHost.hasPrefix("10.")
            || cleanHost.hasPrefix("192.168.") {
            return true
        }

        let parts = cleanHost.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4,
           parts[0] == 172,
           (16...31).contains(parts[1]) {
            return true
        }

        return false
    }
}
