import Foundation

struct GPCRequestFactory {
    static let secGPCHeader = "Sec-GPC"

    private let userDefaults: UserDefaults
    private let enabledSitesKey: String

    init(
        userDefaults: UserDefaults = .standard,
        enabledSitesKey: String = "privacy_gpc_header_enabled_sites"
    ) {
        self.userDefaults = userDefaults
        self.enabledSitesKey = enabledSitesKey
    }

    func requestForGPC(basedOn incomingRequest: URLRequest, gpcEnabled: Bool) -> URLRequest? {
        guard let url = incomingRequest.url, isGPCHeaderEligible(url: url) else {
            return removingHeader(from: incomingRequest)
        }

        guard gpcEnabled else {
            return removingHeader(from: incomingRequest)
        }

        let headers = incomingRequest.allHTTPHeaderFields ?? [:]
        guard headers[Self.secGPCHeader] == nil else { return nil }

        var request = incomingRequest
        request.addValue("1", forHTTPHeaderField: Self.secGPCHeader)
        return request
    }

    func isGPCHeaderEligible(url: URL) -> Bool {
        let enabledSites = userDefaults.stringArray(forKey: enabledSitesKey) ?? Self.defaultHeaderEnabledSites
        return enabledSites.contains { domain in
            Self.domainMatches(domain, host: url.host)
        }
    }

    private func removingHeader(from incomingRequest: URLRequest) -> URLRequest? {
        let headers = incomingRequest.allHTTPHeaderFields ?? [:]
        guard headers[Self.secGPCHeader] != nil else { return nil }

        var request = incomingRequest
        request.setValue(nil, forHTTPHeaderField: Self.secGPCHeader)
        return request
    }

    private static let defaultHeaderEnabledSites = [
        "washingtonpost.com",
        "nytimes.com",
        "global-privacy-control.glitch.me"
    ]

    private static func domainMatches(_ domain: String, host: String?) -> Bool {
        let cleanDomain = normalizedHost(domain)
        let cleanHost = normalizedHost(host ?? "")
        guard !cleanDomain.isEmpty, !cleanHost.isEmpty else { return false }
        return cleanHost == cleanDomain || cleanHost.hasSuffix(".\(cleanDomain)")
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}
