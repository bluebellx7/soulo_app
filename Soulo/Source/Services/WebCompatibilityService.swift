import Foundation

enum WebCompatibilityService {
    static let defaultProtectionBypassHosts = [
        "weixin.qq.com",
        "wx.qq.com"
    ]

    static func protectionBypassHosts(adding hosts: [String] = []) -> [String] {
        Array(Set((defaultProtectionBypassHosts + hosts).map(normalizedHost).filter { !$0.isEmpty })).sorted()
    }

    static func shouldBypassWebProtection(for url: URL?, fallbackHost: String? = nil) -> Bool {
        let host = normalizedHost(url?.host ?? fallbackHost)
        if defaultProtectionBypassHosts.contains(where: { domainMatches(host: host, pattern: $0) }) {
            return true
        }
        return isSensitiveChallengeURL(url)
    }

    static func isSensitiveChallengeURL(_ url: URL?) -> Bool {
        guard let value = url?.absoluteString.lowercased(), !value.isEmpty else { return false }
        return value.range(
            of: #"(^|[\/?&#_=.\-])(captcha|wappoc|verify|verification|challenge|security|passport|login|auth)([\/?&#_=.\-]|$)"#,
            options: .regularExpression
        ) != nil
    }

    static func normalizedHost(_ host: String?) -> String {
        (host ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    private static func domainMatches(host: String, pattern: String) -> Bool {
        let cleanPattern = normalizedHost(pattern)
        guard !host.isEmpty, !cleanPattern.isEmpty else { return false }
        return host == cleanPattern || host.hasSuffix(".\(cleanPattern)")
    }
}
