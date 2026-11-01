import Combine
import Foundation
import WebKit

/// Each bundled website rule has its own JavaScript file, preferences and isolated world.
struct SiteOptimizationRule: Codable, Identifiable, Sendable {
    let id: String
    let recordID: UUID
    let version: String
    let platformNames: [String]
    let resourceFile: String
    let nameKey: String
    let iconName: String
    let descriptionKey: String
    let preferenceKey: String
    let enabledByDefault: Bool
    var hosts: [String]
    let pathSuffixes: [String]
    let queryKeys: [String]

    var worldName: String { "Soulo.SiteOptimization." + id }
    var scriptPrefix: String { "/* Soulo site optimization: \(id) */\n" }
    @MainActor var world: WKContentWorld { .world(name: worldName) }

    func matches(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), hosts.contains(host),
              pathSuffixes.isEmpty || pathSuffixes.contains(where: { url.path.hasSuffix($0) }) else { return false }
        return queryKeys.isEmpty || URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            queryKeys.contains($0.name) && $0.value?.isEmpty == false
        } == true
    }

    func navigationRequest(to destination: URL, from source: URL) -> URLRequest? {
        guard matches(source), destination.absoluteString.utf8.count <= 8192,
              ["http", "https"].contains(destination.scheme?.lowercased() ?? ""),
              destination.host?.isEmpty == false, destination.user == nil, destination.password == nil else { return nil }
        var request = URLRequest(url: destination)
        // Match the browser's origin-only cross-site referrer, including HTTPS downgrade handling.
        if !(source.scheme == "https" && destination.scheme == "http"),
           var origin = URLComponents(url: source, resolvingAgainstBaseURL: false) {
            origin.path = "/"; origin.query = nil; origin.fragment = nil
            origin.user = nil; origin.password = nil
            request.setValue(origin.url?.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    @MainActor var scriptRecord: UserScriptRecord {
        let matches = hosts.map { "*://\($0)/*" }
        let header = "// ==UserScript==\n// @name \(LanguageManager.shared.localizedString(nameKey))\n// @namespace com.dkluge.soulo.site.\(id)\n// @version \(version)\n"
            + matches.map { "// @match \($0)\n" }.joined()
            + "// @run-at document-start\n// @grant none\n// ==/UserScript==\n\n"
        return UserScriptRecord(id: recordID, name: LanguageManager.shared.localizedString(nameKey),
            source: header + configuredScript(enabled: true, navigationEnabled: true), matchPatterns: matches,
            namespace: "com.dkluge.soulo.site." + id, version: version,
            scriptDescription: LanguageManager.shared.localizedString(descriptionKey), isBuiltIn: true,
            injectionTime: .documentStart, isEnabled: SiteOptimizationSettings.shared.isEnabled(self),
            installedAt: Date(timeIntervalSince1970: 0))
    }

    @MainActor private func configuration(enabled: Bool, navigationEnabled: Bool) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "enabled": enabled, "navigationEnabled": navigationEnabled, "hosts": hosts,
            "pathSuffixes": pathSuffixes, "queryKeys": queryKeys,
            "loadingText": LanguageManager.shared.localizedString("loading")
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    @MainActor func configurationCall(enabled: Bool, navigationEnabled: Bool) -> String {
        "globalThis.__souloSiteOptimization?.configure(\(configuration(enabled: enabled, navigationEnabled: navigationEnabled)));"
    }
    @MainActor func configuredScript(enabled: Bool, navigationEnabled: Bool) -> String {
        guard let source = SiteOptimizationRules.sources[resourceFile], !source.isEmpty else { return "" }
        let config = configuration(enabled: enabled, navigationEnabled: navigationEnabled)
        return scriptPrefix + """
        (() => {
          const config = \(config);
          let matches = false;
          try {
            const page = new URL(location.href);
            matches = window === window.top && /^https?:$/.test(page.protocol) && config.hosts.includes(page.hostname)
              && (!config.pathSuffixes.length || config.pathSuffixes.some(path => page.pathname.endsWith(path)))
              && (!config.queryKeys.length || config.queryKeys.some(key => page.searchParams.get(key)));
          } catch (_) {}
          if (!globalThis.__souloSiteOptimization && !matches) return;
          \(source)
          globalThis.__souloSiteOptimization?.configure(config);
        })();
        """
    }

}

enum SiteOptimizationRules {
    static let all: [SiteOptimizationRule] = {
        guard let url = Bundle.main.url(forResource: "site-optimizations", withExtension: "json", subdirectory: "UserScripts"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([SiteOptimizationRule].self, from: data) else { return [] }
        var ids = Set<String>()
        return rules.filter {
            !$0.id.isEmpty && $0.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && ids.insert($0.id).inserted && !$0.hosts.isEmpty
                && !$0.resourceFile.contains("/") && !$0.resourceFile.contains("\\") && $0.resourceFile.hasSuffix(".js")
                && !$0.preferenceKey.isEmpty
        }
    }()
    static let sources: [String: String] = {
        var result: [String: String] = [:]
        for rule in all {
            if let url = Bundle.main.url(forResource: rule.resourceFile, withExtension: nil, subdirectory: "UserScripts"),
               let source = try? String(contentsOf: url, encoding: .utf8) { result[rule.resourceFile] = source }
        }
        return result
    }()
    static var preferenceDefaults: [String: Any] {
        Dictionary(all.map { ($0.preferenceKey, $0.enabledByDefault as Any) }, uniquingKeysWith: { _, last in last })
    }
}

@MainActor
final class SiteOptimizationSettings: ObservableObject {
    static let shared = SiteOptimizationSettings()
    @Published private(set) var values: [String: Bool] = [:]
    private let defaults: UserDefaults
    private let rules: [SiteOptimizationRule]
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, rules: [SiteOptimizationRule] = SiteOptimizationRules.all) {
        self.defaults = defaults; self.rules = rules
        reload()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func isEnabled(_ rule: SiteOptimizationRule) -> Bool {
        defaults.object(forKey: rule.preferenceKey) == nil ? rule.enabledByDefault : defaults.bool(forKey: rule.preferenceKey)
    }
    func setEnabled(_ enabled: Bool, for rule: SiteOptimizationRule) {
        defaults.set(enabled, forKey: rule.preferenceKey); reload()
    }
    func reload() {
        let next = Dictionary(rules.map { ($0.id, isEnabled($0)) }, uniquingKeysWith: { _, last in last })
        if values != next { values = next }
    }
}

@MainActor
final class SiteOptimizationController: NSObject, WKScriptMessageHandler {
    static let handler = "souloSiteOptimizationNavigate"
    private let rules: [SiteOptimizationRule]
    private let settings: SiteOptimizationSettings
    private weak var webView: WKWebView?
    private var applied: [String: String] = [:]
    private var pending = Set<String>()
    private var navigationEnabled = true
    private var navigate: ((URLRequest) -> Bool)?

    init(rules: [SiteOptimizationRule] = SiteOptimizationRules.all, settings: SiteOptimizationSettings = .shared) {
        self.rules = rules; self.settings = settings
    }
    func synchronize(on webView: WKWebView, navigationEnabled: Bool, navigate: @escaping (URLRequest) -> Bool) {
        if self.webView !== webView { detach(); self.webView = webView }
        self.navigationEnabled = navigationEnabled; self.navigate = navigate
        let controller = webView.configuration.userContentController
        for rule in rules {
            let signature = "\(settings.isEnabled(rule))|\(navigationEnabled)|\(LanguageManager.shared.localizedString("loading"))"
            guard applied[rule.id] != signature else { continue }
            controller.removeScriptMessageHandler(forName: Self.handler, contentWorld: rule.world)
            controller.add(self, contentWorld: rule.world, name: Self.handler)
            let source = rule.configuredScript(enabled: settings.isEnabled(rule), navigationEnabled: navigationEnabled)
            let existing = controller.userScripts.filter { $0.source.hasPrefix(rule.scriptPrefix) }
            if existing.count != 1 || existing.first?.source != source {
                let replacement = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: rule.world)
                var replaced = false
                let scripts = controller.userScripts.compactMap { script -> WKUserScript? in
                    guard script.source.hasPrefix(rule.scriptPrefix) else { return script }
                    guard !replaced else { return nil }
                    replaced = true
                    return replacement
                }
                controller.removeAllUserScripts(); scripts.forEach(controller.addUserScript)
                if !replaced { controller.addUserScript(replacement) }
            }
            applied[rule.id] = signature
            if webView.url != nil {
                webView.evaluateJavaScript(source, in: nil, in: rule.world, completionHandler: nil)
            }
        }
    }
    func finishNavigation() {
        for rule in rules where pending.contains(rule.id) {
            webView?.evaluateJavaScript("globalThis.__souloSiteOptimization?.finishNavigation();", in: nil, in: rule.world, completionHandler: nil)
        }
        pending.removeAll()
    }
    func detach() {
        if let controller = webView?.configuration.userContentController {
            for rule in rules { controller.removeScriptMessageHandler(forName: Self.handler, contentWorld: rule.world) }
        }
        applied.removeAll(); pending.removeAll(); webView = nil; navigate = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let rule = rules.first(where: { $0.worldName == message.world.name }),
              let source = message.frameInfo.requestURL, rule.matches(source),
              let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "ready" {
            webView?.evaluateJavaScript(rule.configurationCall(enabled: settings.isEnabled(rule), navigationEnabled: navigationEnabled),
                in: nil, in: rule.world, completionHandler: nil)
            return
        }
        guard navigationEnabled, settings.isEnabled(rule), let raw = body["url"] as? String,
              raw.utf8.count <= 8192, let url = URL(string: raw),
              let request = rule.navigationRequest(to: url, from: source) else { return }
        pending.insert(rule.id)
        if navigate?(request) != true { finishNavigation() }
    }
}
