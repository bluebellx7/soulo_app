import Foundation

enum WebNavigationDecision: Equatable {
    case allow
    case cancel
    case external(URL)
}

struct WebNavigationPolicyService {
    static let shared = WebNavigationPolicyService()

    private let webSchemes: Set<String> = [
        "http", "https", "about", "blob", "data",
        // WKWebExtension uses this internal origin for popup, options, and
        // extension-created tabs. Sending it to UIApplication produces an
        // incorrect “open external app” prompt and breaks extension flows.
        "webkit-extension"
    ]
    private let appStoreDomains: Set<String> = ["apps.apple.com", "itunes.apple.com"]
    private let externalDomains: [String] = [
        "apps.apple.com", "itunes.apple.com",
        "music.apple.com", "podcasts.apple.com", "books.apple.com",
        "maps.apple.com", "tv.apple.com",
        "open.spotify.com",
        "play.google.com",
        "t.me", "telegram.me",
        "line.me",
        "wa.me", "api.whatsapp.com",
    ]

    func decision(for url: URL) -> WebNavigationDecision {
        if let appURL = bilibiliAppHandoffURL(for: url) { return .external(appURL) }
        if let appURL = baiduAppHandoffURL(for: url) {
            return .external(appURL)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""

        guard webSchemes.contains(scheme) else {
            return .external(url)
        }

        if externalDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return .external(url)
        }

        return .allow
    }

    private func bilibiliAppHandoffURL(for url: URL) -> URL? {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.lowercased() == "d.bilibili.com",
              url.path == "/download_app.html", url.port == nil || url.port == (url.scheme == "https" ? 443 : 80),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = components.queryItems?.filter { $0.name == "schema" } ?? []
        guard values.count == 1, let text = values.first?.value, let target = URL(string: text),
              target.scheme?.lowercased() == "bilibili" else { return nil }
        return target
    }

    func browserFallbackURL(for url: URL) -> URL? {
        guard bilibiliAppHandoffURL(for: url) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let values = components.queryItems?.filter { $0.name == "preUrl" } ?? []
        guard values.count == 1, let text = values.first?.value, let fallback = URL(string: text),
              ["http", "https"].contains(fallback.scheme?.lowercased() ?? ""), fallback.user == nil, fallback.password == nil,
              let host = fallback.host?.lowercased(), host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
              ["/bangumi/play/", "/video/"].contains(where: { fallback.path.hasPrefix($0) }) else { return nil }
        return fallback
    }

    /// Bilibili associates even its homepage with the native app. Open ordinary
    /// links from other sites as browser requests so the homepage stays in Soulo.
    func prefersBrowserForBilibiliHomepage(_ url: URL, from source: URL?) -> Bool {
        let hosts: Set<String> = ["bilibili.com", "www.bilibili.com", "m.bilibili.com"]
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              hosts.contains(url.host?.lowercased() ?? ""),
              url.path.isEmpty || url.path == "/",
              let sourceHost = source?.host?.lowercased() else { return false }
        return sourceHost != "bilibili.com" && !sourceHost.hasSuffix(".bilibili.com")
    }

    /// A normal HTTPS navigation can itself invoke an installed app, without
    /// passing through a custom-scheme policy action. Keep this list narrow.
    func universalAppScheme(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        if host == "b23.tv" { return "bilibili" }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
            if ["/video/", "/bangumi/", "/festival/"].contains(where: { url.path.hasPrefix($0) }) { return "bilibili" }
        }
        return nil
    }

    /// Baidu's share-page SDK wraps its app scheme in an HTTPS Universal Link.
    /// Resolve only that specific SDK link shape, so ordinary cross-site pages
    /// continue through the browser's normal navigation confirmation flow.
    private func baiduAppHandoffURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "boxer.baidu.com",
              url.path == "/scheme", url.port == nil || url.port == 443,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let schemes = components.queryItems?.filter { $0.name == "scheme" } ?? []
        guard schemes.count == 1, let value = schemes.first?.value,
              let appURL = URL(string: value),
              appURL.scheme?.lowercased() == "baiduboxapp" else { return nil }
        return appURL
    }

    func isAppleAppStoreURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "itms-apps",
              let host = url.host?.lowercased() else {
            return false
        }
        return appStoreDomains.contains(host)
    }

    func canUseSafariCompatibilityMode(for url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    /// A user-facing destination for external navigation prompts. Custom URL
    /// hosts such as `v1` are internal routes, so prefer the owning app scheme.
    func externalDestinationName(for url: URL) -> String {
        if universalAppScheme(for: url) == "bilibili" { return "Bilibili" }
        let scheme = url.scheme?.lowercased() ?? ""
        let knownApps: [String: String] = [
            "baiduboxapp": "百度 App",
            "baiduboxlite": "百度 App",
            "weixin": "微信",
            "mqqapi": "QQ",
            "sinaweibo": "微博",
            "snssdk1128": "抖音",
            "douyin": "抖音",
            "xhsdiscover": "小红书",
            "xiaohongshu": "小红书",
            "bilibili": "B站",
            "taobao": "淘宝",
            "openapp.jdmobile": "京东",
            "alipays": "支付宝",
            "itms-apps": "App Store",
            "spotify": "Spotify",
            "tg": "Telegram",
            "whatsapp": "WhatsApp",
            "line": "LINE"
        ]

        if let appName = knownApps[scheme] {
            return appName
        }
        if webSchemes.contains(scheme), let host = url.host, !host.isEmpty {
            return host
        }
        return scheme.isEmpty ? url.absoluteString : scheme
    }
}
