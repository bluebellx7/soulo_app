import Foundation

enum WebCompatibilityService {
    static let authenticationContentSelector = #"input[type="password"],input[type="tel"],input[autocomplete*="one-time-code"],input[name*="captcha" i],input[name*="verify" i],[name="cf-turnstile-response"],[name="g-recaptcha-response"],[name="h-captcha-response"],.cf-turnstile,.g-recaptcha,.h-captcha,.grecaptcha-badge,[id^="cf-chl-widget-"],iframe[src^="https://challenges.cloudflare.com/"],iframe[src^="//challenges.cloudflare.com/"],iframe[src^="https://www.google.com/recaptcha/"],iframe[src^="https://www.recaptcha.net/recaptcha/"],iframe[src^="https://newassets.hcaptcha.com/"]"#
    static let authenticationContentSelectorJSON = (try? JSONEncoder().encode(authenticationContentSelector))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "\"input[type=password]\""
    // Challenge resources are functional authentication dependencies. Keep this
    // exception narrower than Cloudflare's CDN and analytics domains.
    static let cloudflareChallengeURLFilters = [
        #"^https?://([a-z0-9-]+\.)*challenges\.cloudflare\.com(:[0-9]+)?/"#,
        #"^https?://[^/]+/cdn-cgi/challenge-platform/"#
    ]
    static let verificationResourceURLFilters = cloudflareChallengeURLFilters + [
        #"^https?://(www\.)?google\.com(:[0-9]+)?/recaptcha/"#,
        #"^https?://(www\.)?recaptcha\.net(:[0-9]+)?/recaptcha/"#,
        #"^https?://(www\.)?gstatic\.com(:[0-9]+)?/recaptcha/"#,
        #"^https?://([a-z0-9-]+\.)*hcaptcha\.com(:[0-9]+)?/"#
    ]

    static func isVerificationResourceURL(_ url: URL?) -> Bool {
        if isCloudflareChallengeURL(url) { return true }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        return host == "hcaptcha.com" || host.hasSuffix(".hcaptcha.com")
            || (["google.com", "www.google.com", "recaptcha.net", "www.recaptcha.net", "gstatic.com", "www.gstatic.com"].contains(host)
                && url.path.lowercased().hasPrefix("/recaptcha/"))
    }

    static let verificationContextDetectionScript = #"""
    function isVerificationResourceContext() {
      let address=new URL(location.href);
      if(['about:','blob:','data:'].includes(address.protocol)&&document.referrer){try{address=new URL(document.referrer)}catch{}}
      const host=address.hostname.toLowerCase(),path=address.pathname.toLowerCase();
      return host==='challenges.cloudflare.com'||host.endsWith('.challenges.cloudflare.com')
        || path.startsWith('/cdn-cgi/challenge-platform/')
        || /^\/mp\/wappoc_appmsgcaptcha(?:\/|$)/i.test(path)
        || host==='hcaptcha.com'||host.endsWith('.hcaptcha.com')
        || (['google.com','www.google.com','recaptcha.net','www.recaptcha.net','gstatic.com','www.gstatic.com'].includes(host)&&path.startsWith('/recaptcha/'));
    }
    """#

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
    \#(verificationContextDetectionScript)
    function isSensitiveChallengePage() {
      return isVerificationResourceContext()
        || ['__cf_chl_tk','__cf_chl_rt_tk'].some(key=>!!new URL(location.href).searchParams.get(key))
        || !!document.documentElement?.hasAttribute('data-soulo-cloudflare-challenge')
        || !!document.querySelector('script[src*="/cdn-cgi/challenge-platform/"][src*="/orchestrate/chl_page/"]');
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
        if isVerificationResourceURL(url) { return true }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return false }
        let path = url.path.lowercased()
        if path == "/mp/wappoc_appmsgcaptcha" || path.hasPrefix("/mp/wappoc_appmsgcaptcha/") { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            ["__cf_chl_tk", "__cf_chl_rt_tk"].contains($0.name) && !($0.value ?? "").isEmpty
        } == true
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
