import Foundation

enum WebCompatibilityService {
    // Challenge resources are functional authentication dependencies. Keep this
    // exception narrower than Cloudflare's CDN and analytics domains.
    static let cloudflareChallengeURLFilters = [
        #"^https?://([a-z0-9-]+\.)*challenges\.cloudflare\.com(:[0-9]+)?/"#,
        #"^https?://[^/]+/cdn-cgi/challenge-platform/"#
    ]

    static func isCloudflareChallengeURL(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return host == "challenges.cloudflare.com" || host.hasSuffix(".challenges.cloudflare.com")
            || url.path.lowercased().hasPrefix("/cdn-cgi/challenge-platform/")
    }

    static func isCloudflareChallengeResponse(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "cf-mitigated")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "challenge"
    }

    /// Challenge interstitials retain the requested URL. Recognize their DOM,
    /// too, without treating ordinary Cloudflare analytics/JSD as a bypass.
    static let sensitiveChallengeDetectionScript = #"""
    function isSensitiveChallengePage() {
      const host=location.hostname.toLowerCase();
      return host==='challenges.cloudflare.com'||host.endsWith('.challenges.cloudflare.com')
        || location.pathname.toLowerCase().startsWith('/cdn-cgi/challenge-platform/')
        || /(^|[\/?&#_=.-])(captcha|wappoc|verify|verification|challenge|security|passport|login|auth)([\/?&#_=.-]|$)/i.test(location.href)
        || /[?&]__cf_chl_(?:rt_)?tk=/i.test(location.search)
        || !!document.documentElement?.hasAttribute('data-soulo-cloudflare-challenge')
        || !!document.querySelector('#challenge-form,#challenge-stage,#cf-challenge-running,script[src*="/cdn-cgi/challenge-platform/"][src*="/orchestrate/chl_page/"]');
    }
    """#
    private static let desktopModeHosts = ["xiaohongshu.com"]
    private static let xiaohongshuAuthenticationCookieNames: Set<String> = [
        "web_session",
        "web_session_v2",
    ]

    static let defaultProtectionBypassHosts = [
        "xiaohongshu.com",
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

    static func requiresDesktopMode(for url: URL?, fallbackHost: String? = nil) -> Bool {
        let host = normalizedHost(url?.host ?? fallbackHost)
        return desktopModeHosts.contains { domainMatches(host: host, pattern: $0) }
    }

    /// Native viewport resizing is intentionally limited to known Douyin video
    /// surfaces. Ordinary pages retain their edge-to-edge WebView geometry.
    static func isDouyinVideoSurface(_ url: URL?) -> Bool {
        guard let url else { return false }

        let host = normalizedHost(url.host)
        guard domainMatches(host: host, pattern: "douyin.com") else { return false }

        let path = url.path.lowercased()
        if path == "/video/detail"
            || path.hasPrefix("/video/")
            || path.hasPrefix("/share/video/") {
            return true
        }

        let videoQueryNames: Set<String> = ["actv_aid", "aweme_id", "modal_id"]
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains { item in
                videoQueryNames.contains(item.name.lowercased())
                    && !(item.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } == true
    }

    static func hasAuthenticatedXiaohongshuSession(in cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            domainMatches(host: normalizedHost(cookie.domain), pattern: "xiaohongshu.com")
                && xiaohongshuAuthenticationCookieNames.contains(cookie.name.lowercased())
                && !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func isSensitiveChallengeURL(_ url: URL?) -> Bool {
        if isCloudflareChallengeURL(url) { return true }
        guard let value = url?.absoluteString.lowercased(), !value.isEmpty else { return false }
        if value.range(of: #"[?&]__cf_chl_(?:rt_)?tk="#, options: .regularExpression) != nil { return true }
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
