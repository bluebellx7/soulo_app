import Foundation
import Combine

enum BrowserDomainNavigationPolicy {
    static let preferenceKey = "ad_block_confirm_cross_domain"
    static let allowlistKey = "ad_block_cross_domain_allowlist"
    static let defaultAllowlist = [
        "qq.com", "weixin.com", "bilibili.com", "b23.tv", "youku.com", "iqiyi.com",
        "mgtv.com", "sohu.com", "acfun.cn", "douyin.com", "iesdouyin.com", "ixigua.com",
        "kuaishou.com", "weibo.com", "weibo.cn", "sina.com.cn", "zhihu.com", "douban.com",
        "xiaohongshu.com", "xhslink.com", "baidu.com", "bing.com", "sogou.com", "so.com",
        "toutiao.com", "163.com", "126.com", "taobao.com", "tmall.com", "jd.com",
        "1688.com", "alipay.com", "aliyun.com", "csdn.net", "jianshu.com", "juejin.cn",
        "github.com", "apple.com", "microsoft.com", "google.com", "youtube.com", "youtu.be",
        "wikipedia.org", "amazon.com"
    ].map { "*." + $0 }.sorted()

    static func allowlist(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: allowlistKey) ?? defaultAllowlist
    }

    /// A wildcard includes the domain itself and its subdomains, never a
    /// similarly named suffix such as qq.com.evil.example or notqq.com.
    static func isAllowlisted(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        return allowlist(defaults: defaults).contains { rule in
            guard let rule = normalizedRule(rule) else { return false }
            if rule.hasPrefix("*.") {
                let suffix = String(rule.dropFirst(2))
                return host == suffix || host.hasSuffix("." + suffix)
            }
            return host == rule
        }
    }

    static func normalizedRule(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wildcard = value.hasPrefix("*.")
        if wildcard { value.removeFirst(2) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, !value.contains("*"),
              !value.contains(where: { "/:@?#\\".contains($0) || $0.isWhitespace }),
              let host = URL(string: "https://" + value)?.host?.lowercased(), host.utf8.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        if wildcard && (labels.count < 2 || labels.allSatisfy({ Int($0) != nil })) { return nil }
        return (wildcard ? "*." : "") + host
    }

    static func trustRule(for url: URL) -> String? {
        guard let host = normalizedHost(url) else { return nil }
        return normalizedRule("*." + host) ?? normalizedRule(host)
    }

    static func isExplicitNavigation(nativeRequest: Bool, destination: URL,
                                     recentGestureDestination: URL?) -> Bool {
        if nativeRequest { return true }
        guard let recentGestureDestination else { return false }
        var intended = URLComponents(url: recentGestureDestination, resolvingAgainstBaseURL: true)
        var target = URLComponents(url: destination, resolvingAgainstBaseURL: true)
        intended?.fragment = nil
        target?.fragment = nil
        return intended?.url == target?.url
    }

    static func requiresConfirmation(from source: URL?, to destination: URL,
                                     defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: preferenceKey),
              let source, ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
              ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
              let first = normalizedHost(source), let second = normalizedHost(destination),
              !isAllowlisted(destination, defaults: defaults) else { return false }
        return first != second
    }

    private static func normalizedHost(_ url: URL) -> String? {
        let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host?.isEmpty == false ? host : nil
    }
}

@MainActor
final class BrowserDomainAllowlist: ObservableObject {
    static let shared = BrowserDomainAllowlist()
    @Published private(set) var rules: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = BrowserDomainNavigationPolicy.allowlist(defaults: defaults)
    }

    @discardableResult
    func add(_ input: String) -> Bool {
        guard let rule = BrowserDomainNavigationPolicy.normalizedRule(input) else { return false }
        if !rules.contains(rule) { rules.append(rule); rules.sort(); save() }
        return true
    }

    func remove(_ rule: String) { rules.removeAll { $0 == rule }; save() }
    func reset() { rules = BrowserDomainNavigationPolicy.defaultAllowlist; save() }
    private func save() { defaults.set(rules, forKey: BrowserDomainNavigationPolicy.allowlistKey) }
}
