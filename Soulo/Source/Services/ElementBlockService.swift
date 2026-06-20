import Foundation

struct BlockedElementRule: Codable, Identifiable, Hashable {
    let id: UUID
    let host: String
    let selector: String
    let xpath: String
    let label: String
    let pageTitle: String
    let pageURL: String
    let selectorKind: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, host, selector, xpath, label, pageTitle, pageURL, selectorKind, createdAt
    }

    init(
        id: UUID = UUID(),
        host: String,
        selector: String,
        xpath: String = "",
        label: String,
        pageTitle: String = "",
        pageURL: String = "",
        selectorKind: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.selector = selector
        self.xpath = xpath
        self.label = label
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.selectorKind = selectorKind
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        host = try c.decode(String.self, forKey: .host)
        selector = try c.decode(String.self, forKey: .selector)
        xpath = try c.decodeIfPresent(String.self, forKey: .xpath) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? selector
        pageTitle = try c.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        pageURL = try c.decodeIfPresent(String.self, forKey: .pageURL) ?? ""
        selectorKind = try c.decodeIfPresent(String.self, forKey: .selectorKind) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

@MainActor
final class ElementBlockService: ObservableObject {
    static let shared = ElementBlockService()

    @Published private(set) var rules: [BlockedElementRule] = []
    @Published private(set) var disabledHosts: [String] = []

    private let storageKey: String
    private let disabledHostsKey: String
    private let userDefaults: UserDefaults

    init(
        storageKey: String = "soulo_blocked_element_rules",
        disabledHostsKey: String = "soulo_element_block_disabled_hosts",
        userDefaults: UserDefaults = .standard
    ) {
        self.storageKey = storageKey
        self.disabledHostsKey = disabledHostsKey
        self.userDefaults = userDefaults
        load()
    }

    @discardableResult
    func addRule(host: String, selector: String, xpath: String = "", label: String, pageTitle: String = "", pageURL: String = "") -> BlockedElementRule? {
        let cleanHost = normalizedHost(host)
        let cleanSelector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanXPath = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanSelector.isEmpty || !cleanXPath.isEmpty else { return nil }
        if let existing = rules.first(where: { $0.host == cleanHost && $0.selector == cleanSelector && $0.xpath == cleanXPath }) {
            return existing
        }
        let rule = BlockedElementRule(
            host: cleanHost,
            selector: cleanSelector,
            xpath: cleanXPath,
            label: label,
            pageTitle: pageTitle,
            pageURL: pageURL,
            selectorKind: selectorKind(for: cleanSelector, xpath: cleanXPath)
        )
        rules.insert(rule, at: 0)
        save()
        return rule
    }

    func removeRule(_ rule: BlockedElementRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    func removeRules(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        save()
    }

    func removeAll(for host: String) {
        let cleanHost = normalizedHost(host)
        rules.removeAll { $0.host == cleanHost }
        save()
    }

    func removeAllRules() {
        rules.removeAll()
        save()
    }

    func enableAllHosts() {
        disabledHosts.removeAll()
        saveDisabledHosts()
    }

    func isDisabled(for host: String?) -> Bool {
        guard let host else { return false }
        let cleanHost = normalizedHost(host)
        return disabledHosts.contains { cleanHost == $0 || cleanHost.hasSuffix(".\($0)") }
    }

    func setDisabled(_ disabled: Bool, for host: String?) {
        guard let host else { return }
        let cleanHost = normalizedHost(host)
        guard !cleanHost.isEmpty else { return }
        if disabled {
            if !disabledHosts.contains(cleanHost) {
                disabledHosts.append(cleanHost)
                disabledHosts.sort()
            }
        } else {
            disabledHosts.removeAll { $0 == cleanHost }
        }
        saveDisabledHosts()
    }

    func rules(for host: String?) -> [BlockedElementRule] {
        guard let host, !isDisabled(for: host) else { return [] }
        return storedRules(for: host)
    }

    func storedRules(for host: String?) -> [BlockedElementRule] {
        guard let host else { return [] }
        let cleanHost = normalizedHost(host)
        return rules.filter { cleanHost == $0.host || cleanHost.hasSuffix(".\($0.host)") }
    }

    func cssForHost(_ host: String?) -> String {
        let selectors = rules(for: host)
            .flatMap { $0.selectorCandidates }
            .filter { !$0.isEmpty }
        guard !selectors.isEmpty else { return "" }
        return selectors
            .map { "\($0){\(Self.blockedElementCSSDeclaration)}" }
            .joined(separator: "\n")
    }

    func makeApplyScript(for host: String?) -> String {
        let rulePayload = rules(for: host).map { rule in
            [
                "selectors": rule.selectorCandidates,
                "xpath": rule.xpath
            ] as [String: Any]
        }
        let rulesJSON = (try? JSONSerialization.data(withJSONObject: rulePayload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function() {
            var rules = \(rulesJSON);
            var selectors = [];
            rules.forEach(function(rule) {
                (rule.selectors || []).forEach(function(selector) {
                    if (selector) selectors.push(selector);
                });
            });
            function isUsableSelector(selector) {
                try {
                    document.querySelector(selector);
                    return true;
                } catch (_) {
                    return false;
                }
            }
            selectors = selectors.filter(isUsableSelector);
            var id = 'soulo-element-block-style';
            var style = document.getElementById(id);
            if (!style) {
                style = document.createElement('style');
                style.id = id;
                (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = selectors.length ? selectors.map(function(selector) {
                return selector + '{\(Self.blockedElementCSSDeclaration)}';
            }).join('\\n') : '';

            function elementsForXPath(xpath) {
                var elements = [];
                if (!xpath) return elements;
                try {
                    var result = document.evaluate(xpath, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                    for (var i = 0; i < result.snapshotLength; i++) {
                        var el = result.snapshotItem(i);
                        if (el && el.nodeType === 1) elements.push(el);
                    }
                } catch (_) {}
                return elements;
            }

            function hideElement(el) {
                el.setAttribute('data-soulo-blocked', 'true');
                el.style.setProperty('display', 'none', 'important');
                el.style.setProperty('visibility', 'hidden', 'important');
                el.style.setProperty('pointer-events', 'none', 'important');
                el.style.setProperty('width', '0', 'important');
                el.style.setProperty('height', '0', 'important');
                el.style.setProperty('min-width', '0', 'important');
                el.style.setProperty('min-height', '0', 'important');
                el.style.setProperty('max-width', '0', 'important');
                el.style.setProperty('max-height', '0', 'important');
                el.style.setProperty('margin', '0', 'important');
                el.style.setProperty('padding', '0', 'important');
                el.style.setProperty('border', '0', 'important');
                el.style.setProperty('opacity', '0', 'important');
                el.style.setProperty('clip-path', 'inset(50%)', 'important');
                el.style.setProperty('content-visibility', 'hidden', 'important');
                el.style.setProperty('overflow', 'hidden', 'important');
            }

            function hideBlockedElements() {
                var hiddenCount = 0;
                selectors.forEach(function(selector) {
                    try {
                        document.querySelectorAll(selector).forEach(function(el) {
                            if (el.getAttribute('data-soulo-blocked') !== 'true') hiddenCount++;
                            hideElement(el);
                        });
                    } catch (_) {}
                });
                rules.forEach(function(rule) {
                    elementsForXPath(rule.xpath).forEach(function(el) {
                        if (el.getAttribute('data-soulo-blocked') !== 'true') hiddenCount++;
                        hideElement(el);
                    });
                });
                return hiddenCount;
            }

            hideBlockedElements();
            clearTimeout(window.__souloElementBlockTimer);
            window.__souloElementBlockTimer = setTimeout(hideBlockedElements, 250);
            if (!window.__souloElementBlockObserver) {
                window.__souloElementBlockObserver = new MutationObserver(function(mutations) {
                    var changed = false;
                    mutations.forEach(function(m) {
                        if (m.addedNodes && m.addedNodes.length) changed = true;
                    });
                    if (changed) {
                        clearTimeout(window.__souloElementBlockObserverTimer);
                        window.__souloElementBlockObserverTimer = setTimeout(hideBlockedElements, 80);
                    }
                });
                window.__souloElementBlockObserver.observe(document.documentElement || document, {
                    childList: true,
                    subtree: true
                });
            }
        })();
        """
    }

    private func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    private static let blockedElementCSSDeclaration = "display:none!important;visibility:hidden!important;pointer-events:none!important;width:0!important;height:0!important;min-width:0!important;min-height:0!important;max-width:0!important;max-height:0!important;margin:0!important;padding:0!important;border:0!important;opacity:0!important;clip-path:inset(50%)!important;content-visibility:hidden!important;overflow:hidden!important;"

    private func selectorKind(for selector: String, xpath: String = "") -> String {
        if selector.isEmpty, !xpath.isEmpty { return "xpath" }
        if selector.contains("#") { return "id" }
        if selector.contains("[data-") || selector.contains("[aria-") || selector.contains("[role=") { return "attribute" }
        if selector.contains(".") { return "class" }
        if selector.contains(":nth-of-type") || selector.contains(">") || !xpath.isEmpty { return "path" }
        return "selector"
    }

    private func load() {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([BlockedElementRule].self, from: data) {
            rules = decoded
        }
        disabledHosts = userDefaults.stringArray(forKey: disabledHostsKey) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func saveDisabledHosts() {
        userDefaults.set(disabledHosts, forKey: disabledHostsKey)
    }
}

extension BlockedElementRule {
    var selectorCandidates: [String] {
        selector
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension Notification.Name {
    static let elementBlockRuleAdded = Notification.Name("soulo.elementBlockRuleAdded")
}
