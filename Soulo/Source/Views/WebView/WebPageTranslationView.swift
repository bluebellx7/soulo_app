import SwiftUI
import Translation
import WebKit
import NaturalLanguage
import OSLog

private let webPageTranslationLogger = Logger(
    subsystem: "com.dkluge.Soulo",
    category: "WebPageTranslation"
)

struct WebPageTranslationSheet: View {
    let webView: WKWebView?
    let pageURL: URL?
    let onOpenURL: (URL) -> Void

    var body: some View {
        if #available(iOS 18.0, *) {
            SystemWebPageTranslationView(webView: webView, pageURL: pageURL, onOpenURL: onOpenURL)
        } else {
            LegacyWebPageTranslationView(pageURL: pageURL, onOpenURL: onOpenURL)
        }
    }
}

private enum WebTranslationProvider: String, CaseIterable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    static var availableCases: [WebTranslationProvider] {
        #if targetEnvironment(simulator)
        // Apple's Translation framework exposes its API in Simulator builds,
        // but the on-device models only run on physical iOS/iPadOS devices.
        [.google]
        #else
        allCases
        #endif
    }

    static var defaultProvider: WebTranslationProvider {
        availableCases.first ?? .google
    }

    var compactTitle: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        }
    }

    var titleKey: String {
        switch self {
        case .apple: "web_translate_system"
        case .google: "web_translate_google"
        }
    }

    var descriptionKey: String {
        switch self {
        case .apple: "web_translate_system_desc"
        case .google: "web_translate_google_desc"
        }
    }

    var systemImage: String {
        switch self {
        case .apple: "character.book.closed.fill"
        case .google: "globe"
        }
    }

    var tint: Color {
        switch self {
        case .apple: .blue
        case .google: .green
        }
    }
}

private enum WebTranslationProgressPhase {
    case analyzing
    case preparingLanguagePack
    case translating
}

struct WebTranslationTarget: Identifiable {
    let id: String
    let title: String
    let flag: String
    let appleLanguage: Locale.Language?
}

enum WebTranslationLanguageCatalog {
    // Google Cloud Translation's published NMT target-language list. The
    // translated-page URL uses the same BCP-47/ISO language identifiers.
    private static let googleLanguageCodes: [String] = """
    ab ace ach af sq alz am ar hy as awa ay az ban bm ba eu btx bts bbc be bem bn bew bho bik bs br bg bua yue ca ceb ny zh-CN zh-TW cv co crh hr cs da din dv doi dov nl dz en eo et ee fj fil fi fr fr-FR fr-CA fy ff gaa gl lg ka de el gn gu ht cnh ha haw he hil hi hmn hu hrx is ig ilo id ga it ja jv pam kk km cgg rw ktu gom kn ko kri ku ckb ky lo ltg la lv lij li ln lt lmo luo lb mk mai mak mg ms ms-Arab ml mt mi mr chm mni-Mtei min lus mn my nr new ne nso no nus oc or om pag pap ps fa pl pt pt-PT pt-BR pa pa-Arab qu rom ro rn ru sm sg sa gd sr st crs shn sn scn szl sd si sk sl so es su sw ss sv tg ta tt te tet th ti ts tn tr tk ak uk ur ug uz vi cy xh yi yo yua zu
    """
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)

    static var preferredIdentifier: String {
        let current = UserDefaults.standard.string(forKey: AppConstants.StorageKeys.selectedLanguage)
            ?? Locale.preferredLanguages.first
            ?? "en"
        let canonical = AppConstants.canonicalLanguageCode(current)
        switch canonical {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default: return canonical
        }
    }

    @MainActor
    static func googleTargets() -> [WebTranslationTarget] {
        makeTargets(googleLanguageCodes.map { ($0, nil) })
    }

    @MainActor
    static func appleTargets(from languages: [Locale.Language]) -> [WebTranslationTarget] {
        let values = languages.map { language in
            (identifier(for: language), Optional(language))
        }
        return makeTargets(values)
    }

    static func identifier(for language: Locale.Language) -> String {
        language.minimalIdentifier.replacingOccurrences(of: "_", with: "-")
    }

    static func bestMatch(for preferred: String, in targets: [WebTranslationTarget]) -> String? {
        guard !targets.isEmpty else { return nil }
        if let exact = targets.first(where: { $0.id.caseInsensitiveCompare(preferred) == .orderedSame }) {
            return exact.id
        }

        let preferredLanguage = Locale.Language(identifier: preferred)
        let preferredCode = preferredLanguage.languageCode?.identifier
        let preferredScript = scriptIdentifier(for: preferred)
        let preferredRegion = preferredLanguage.region?.identifier

        let scored = targets.compactMap { target -> (target: WebTranslationTarget, score: Int)? in
            let language = target.appleLanguage ?? Locale.Language(identifier: target.id)
            guard language.languageCode?.identifier == preferredCode else { return nil }
            var score = 1
            let targetScript = scriptIdentifier(for: target.id)
            if let preferredScript {
                score += targetScript == preferredScript ? 20 : 0
            } else if targetScript == nil {
                score += 4
            }
            if let preferredRegion {
                score += language.region?.identifier == preferredRegion ? 10 : 0
            } else if language.region == nil {
                score += 2
            }
            return (target, score)
        }
        return scored.max(by: { $0.score < $1.score })?.target.id
    }

    private static func scriptIdentifier(for identifier: String) -> String? {
        switch identifier.lowercased() {
        case "zh-cn", "zh-hans": return "Hans"
        case "zh-tw", "zh-hant", "zh-hk": return "Hant"
        default: return Locale.Language(identifier: identifier).script?.identifier
        }
    }

    @MainActor
    private static func makeTargets(
        _ values: [(identifier: String, appleLanguage: Locale.Language?)]
    ) -> [WebTranslationTarget] {
        let displayLocale = Locale(identifier: LanguageManager.shared.selectedLanguage)
        var seen = Set<String>()
        return values.compactMap { value -> WebTranslationTarget? in
            let normalized = value.identifier.replacingOccurrences(of: "_", with: "-")
            let key = normalized.lowercased()
            guard !normalized.isEmpty, seen.insert(key).inserted else { return nil }
            let title = displayLocale.localizedString(forIdentifier: normalized)
                ?? Locale(identifier: "en").localizedString(forIdentifier: normalized)
                ?? normalized
            return WebTranslationTarget(
                id: normalized,
                title: title.capitalized(with: displayLocale),
                flag: flag(for: normalized),
                appleLanguage: value.appleLanguage
            )
        }
        .sorted { lhs, rhs in
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func flag(for identifier: String) -> String {
        let language = Locale.Language(identifier: identifier)
        let maximizedLanguage = Locale.Language(identifier: language.maximalIdentifier)
        guard let region = language.region?.identifier ?? maximizedLanguage.region?.identifier else {
            return "🌐"
        }
        let letters = region.uppercased().unicodeScalars
        guard letters.count == 2,
              letters.allSatisfy({ (65...90).contains($0.value) }) else {
            return "🌐"
        }
        return String(String.UnicodeScalarView(letters.compactMap {
            UnicodeScalar(127_397 + $0.value)
        }))
    }
}

struct PageTranslationFragment {
    let id: String
    let text: String
}

struct PageTranslationSnapshot {
    let token: String
    let pageURL: String
    let fragments: [PageTranslationFragment]
    let wasLimited: Bool
}

enum WebTranslationSourceDetector {
    private static let maximumSampleLength = 24_000
    private static let minimumFragmentLetterCount = 12
    private static let confidentMismatchThreshold = 0.72

    static func dominantLanguage(in fragments: [PageTranslationFragment]) -> Locale.Language? {
        var sample = ""
        sample.reserveCapacity(maximumSampleLength)
        for fragment in fragments {
            let remaining = maximumSampleLength - sample.count
            guard remaining > 0 else { break }
            if !sample.isEmpty { sample.append("\n") }
            sample.append(contentsOf: fragment.text.prefix(remaining))
        }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: sample),
              language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    static func matchingFragments(
        _ fragments: [PageTranslationFragment],
        source: Locale.Language
    ) -> [PageTranslationFragment] {
        guard let sourceCode = source.languageCode?.identifier else { return fragments }
        return fragments.filter { fragment in
            let letterCount = fragment.text.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.letters.contains(scalar) { count += 1 }
            }
            // Short labels don't provide enough context for reliable language
            // recognition, so keep them with the dominant page language.
            guard letterCount >= minimumFragmentLetterCount else { return true }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString(fragment.text)
            guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
                  hypothesis.key != .undetermined,
                  hypothesis.value >= confidentMismatchThreshold else { return true }
            let fragmentLanguage = Locale.Language(identifier: hypothesis.key.rawValue)
            return fragmentLanguage.languageCode?.identifier == sourceCode
        }
    }
}

enum WebPageTranslationError: LocalizedError {
    case unavailable
    case noText
    case stalePage

    var errorDescription: String? {
        switch self {
        case .noText:
            AppLocalization.string("web_translate_no_text")
        case .unavailable, .stalePage:
            AppLocalization.string("web_translate_failed")
        }
    }
}

enum WebPageLanguageMatcher {
    static func shouldOfferTranslation(
        pageIdentifier: String?,
        appIdentifier: String
    ) -> Bool {
        guard let pageIdentifier,
              !pageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !representsSameLanguage(pageIdentifier, appIdentifier)
    }

    static func representsSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let left = Locale.Language(identifier: lhs.replacingOccurrences(of: "_", with: "-"))
        let right = Locale.Language(identifier: rhs.replacingOccurrences(of: "_", with: "-"))
        guard let leftCode = left.languageCode?.identifier,
              let rightCode = right.languageCode?.identifier,
              leftCode.caseInsensitiveCompare(rightCode) == .orderedSame else {
            return false
        }

        let leftScript = left.script?.identifier
            ?? Locale.Language(identifier: left.maximalIdentifier).script?.identifier
        let rightScript = right.script?.identifier
            ?? Locale.Language(identifier: right.maximalIdentifier).script?.identifier
        if let leftScript, let rightScript {
            return leftScript.caseInsensitiveCompare(rightScript) == .orderedSame
        }
        return true
    }
}

@MainActor
enum WebPageTranslationBridge {
    static let maximumNodeCount = 1_500
    static let maximumCharacterCount = 120_000
    static let maximumScannedNodeCount = 10_000
    static let maximumFragmentLength = 4_000

    private static var extractionScript: String {
        #"""
        (function() {
            var existing = window.__souloPageTranslation;
            if (existing && existing.url === location.href && existing.entries) {
                Object.keys(existing.entries).forEach(function(id) {
                    var entry = existing.entries[id];
                    if (entry && entry.node && entry.node.isConnected &&
                        typeof entry.translated === 'string' && entry.node.nodeValue === entry.translated) {
                        entry.node.nodeValue = entry.original;
                    }
                });
            }

            var root = document.body || document.documentElement;
            if (!root) return { token: '', url: location.href, limited: false, fragments: [] };

            var blockedSelector = 'script,style,noscript,textarea,input,select,option,code,pre,svg,canvas,[aria-hidden="true"],[translate="no"],[contenteditable="true"]';
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            var candidates = [];
            var scanned = 0;
            var node;
            var visibilityCache = new WeakMap();

            function isVisible(element) {
                var current = element;
                var visited = [];
                var visible = true;
                while (current && current !== document.documentElement) {
                    if (visibilityCache.has(current)) {
                        visible = visibilityCache.get(current);
                        break;
                    }
                    visited.push(current);
                    var style = getComputedStyle(current);
                    if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) {
                        visible = false;
                        break;
                    }
                    current = current.parentElement;
                }
                visited.forEach(function(item) { visibilityCache.set(item, visible); });
                return visible;
            }

            while ((node = walker.nextNode()) && scanned < (\#(maximumScannedNodeCount))) {
                scanned += 1;
                var parent = node.parentElement;
                if (!parent || parent.isContentEditable || parent.closest(blockedSelector) || !isVisible(parent)) continue;
                var raw = node.nodeValue || '';
                var text = raw.trim();
                if (text.length < 2 || text.length > (\#(maximumFragmentLength))) continue;
                var rect = parent.getBoundingClientRect();
                var inViewport = rect.bottom >= 0 && rect.top <= window.innerHeight && rect.right >= 0 && rect.left <= window.innerWidth;
                candidates.push({ node: node, text: text, priority: inViewport ? 0 : 1, order: scanned });
            }

            candidates.sort(function(a, b) {
                return a.priority === b.priority ? a.order - b.order : a.priority - b.priority;
            });

            var token = (window.crypto && typeof window.crypto.randomUUID === 'function')
                ? window.crypto.randomUUID()
                : 'soulo-' + Date.now() + '-' + Math.random().toString(36).slice(2);
            var registry = { token: token, url: location.href, entries: {} };
            var fragments = [];
            var total = 0;

            for (var index = 0; index < candidates.length && fragments.length < (\#(maximumNodeCount)); index += 1) {
                var candidate = candidates[index];
                if (total + candidate.text.length > (\#(maximumCharacterCount))) break;
                var id = 'soulo-' + (fragments.length + 1);
                registry.entries[id] = { node: candidate.node, original: candidate.node.nodeValue || '' };
                fragments.push({ id: id, text: candidate.text });
                total += candidate.text.length;
            }

            window.__souloPageTranslation = registry;
            return {
                token: token,
                url: location.href,
                limited: scanned >= (\#(maximumScannedNodeCount)) || fragments.length < candidates.length,
                fragments: fragments
            };
        })();
        """#
    }

    static func extract(from webView: WKWebView?) async throws -> PageTranslationSnapshot {
        guard let webView else { throw WebPageTranslationError.unavailable }
        let value = try await webView.evaluateJavaScript(extractionScript)
        guard let result = value as? [String: Any],
              let token = result["token"] as? String,
              !token.isEmpty,
              let pageURL = result["url"] as? String,
              let rows = result["fragments"] as? [[String: Any]] else {
            throw WebPageTranslationError.unavailable
        }
        let fragments = rows.compactMap { row -> PageTranslationFragment? in
            guard let id = row["id"] as? String,
                  let text = row["text"] as? String,
                  !text.isEmpty else { return nil }
            return PageTranslationFragment(id: id, text: text)
        }
        guard !fragments.isEmpty else { throw WebPageTranslationError.noText }
        return PageTranslationSnapshot(
            token: token,
            pageURL: pageURL,
            fragments: fragments,
            wasLimited: (result["limited"] as? Bool) ?? false
        )
    }

    static func apply(
        _ translations: [(id: String, text: String)],
        snapshot: PageTranslationSnapshot,
        to webView: WKWebView?
    ) async throws {
        guard let webView else { throw WebPageTranslationError.unavailable }
        let values = Dictionary(uniqueKeysWithValues: translations.map { ($0.id, $0.text) })
        let payload: [String: Any] = [
            "token": snapshot.token,
            "url": snapshot.pageURL,
            "values": values
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WebPageTranslationError.unavailable
        }
        let script = #"""
        (function(payload) {
            var registry = window.__souloPageTranslation;
            if (!registry || registry.token !== payload.token || registry.url !== payload.url || location.href !== payload.url) {
                return { stale: true, applied: 0 };
            }
            var applied = 0;
            Object.keys(payload.values).forEach(function(id) {
                var entry = registry.entries[id];
                if (!entry || !entry.node || !entry.node.isConnected) return;
                // A live page may update text while translation is running.
                // Only replace the exact text captured for this request.
                if (entry.node.nodeValue !== entry.original ||
                    (entry.node.parentElement && entry.node.parentElement.isContentEditable)) return;
                var original = entry.original || '';
                var leading = (original.match(/^\s*/) || [''])[0];
                var trailing = (original.match(/\s*$/) || [''])[0];
                entry.translated = leading + payload.values[id] + trailing;
                entry.node.nodeValue = entry.translated;
                applied += 1;
            });
            registry.isTranslated = applied > 0;
            return { stale: false, applied: applied };
        })(\#(json));
        """#
        let value = try await webView.evaluateJavaScript(script)
        guard let result = value as? [String: Any],
              (result["stale"] as? Bool) == false,
              (result["applied"] as? Int ?? 0) > 0 else {
            throw WebPageTranslationError.stalePage
        }
    }

    static func restore(on webView: WKWebView?) async throws {
        guard let webView else { throw WebPageTranslationError.unavailable }
        let value = try await webView.evaluateJavaScript(#"""
        (function() {
            var registry = window.__souloPageTranslation;
            if (!registry || registry.url !== location.href || !registry.entries) return false;
            Object.keys(registry.entries).forEach(function(id) {
                var entry = registry.entries[id];
                if (!entry || !entry.node || !entry.node.isConnected) return;
                if (typeof entry.translated !== 'string' || entry.node.nodeValue !== entry.translated ||
                    (entry.node.parentElement && entry.node.parentElement.isContentEditable)) return;
                entry.node.nodeValue = entry.original;
            });
            delete window.__souloPageTranslation;
            return true;
        })();
        """#)
        guard (value as? Bool) == true else { throw WebPageTranslationError.stalePage }
    }

    static func hasAppliedTranslation(on webView: WKWebView?) async -> Bool {
        guard let webView,
              let value = try? await webView.evaluateJavaScript(
                "Boolean(window.__souloPageTranslation && window.__souloPageTranslation.isTranslated)"
              ) else { return false }
        return (value as? Bool) ?? false
    }
}

private struct TranslationLanguagePicker: View {
    let targets: [WebTranslationTarget]
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredTargets: [WebTranslationTarget] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return targets }
        return targets.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.id.localizedCaseInsensitiveContains(normalized)
        }
    }

    var body: some View {
        List(filteredTargets) { target in
            Button {
                selection = target.id
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(target.flag)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.title)
                            .foregroundStyle(.primary)
                        Text(target.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if target.id == selection {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(LanguageManager.shared.localizedString("web_translate_target"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            prompt: LanguageManager.shared.localizedString("search")
        )
    }
}

@available(iOS 18.0, *)
private struct SystemWebPageTranslationView: View {
    let webView: WKWebView?
    let pageURL: URL?
    let onOpenURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var provider = WebTranslationProvider.defaultProvider
    @State private var appleTargets: [WebTranslationTarget] = []
    @State private var googleTargets: [WebTranslationTarget] = []
    @AppStorage("web_translation_apple_target") private var selectedAppleTargetID = ""
    @AppStorage("web_translation_google_target") private var selectedGoogleTargetID = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var pendingSnapshot: PageTranslationSnapshot?
    @State private var activeRequestID: UUID?
    @State private var executingRequestID: UUID?
    @State private var activeSession: TranslationSession?
    @State private var isLoadingAppleLanguages = true
    @State private var isTranslating = false
    @State private var didTranslate = false
    @State private var translatedFragmentCount = 0
    @State private var totalFragmentCount = 0
    @State private var translationPhase = WebTranslationProgressPhase.analyzing
    @State private var languagePackRequiresDownload = false
    @State private var languagePackPrepared = false
    @State private var errorMessage: String?

    private var currentTargets: [WebTranslationTarget] {
        provider == .apple ? appleTargets : googleTargets
    }

    private var selectedTargetID: Binding<String> {
        Binding(
            get: { provider == .apple ? selectedAppleTargetID : selectedGoogleTargetID },
            set: { value in
                if provider == .apple {
                    selectedAppleTargetID = value
                } else {
                    selectedGoogleTargetID = value
                }
            }
        )
    }

    private var selectedTarget: WebTranslationTarget? {
        currentTargets.first { $0.id == selectedTargetID.wrappedValue }
    }

    private var canTranslateCurrentPage: Bool {
        guard let selectedTarget else { return false }
        switch provider {
        case .apple:
            return webView != nil && selectedTarget.appleLanguage != nil
        case .google:
            return googleTranslationURL(pageURL: pageURL, target: selectedTarget.id) != nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Text(LanguageManager.shared.localizedString("web_translate"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        Menu {
                            Picker("", selection: $provider) {
                                ForEach(WebTranslationProvider.availableCases) { item in
                                    Label(item.compactTitle, systemImage: item.systemImage)
                                        .tag(item)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: provider.systemImage)
                                Text(provider.compactTitle)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .disabled(isTranslating)

                    if isLoadingAppleLanguages && provider == .apple {
                        HStack {
                            Text(LanguageManager.shared.localizedString("web_translate_target"))
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    } else if !currentTargets.isEmpty {
                        NavigationLink {
                            if provider == .apple {
                                TranslationLanguagePicker(
                                    targets: appleTargets,
                                    selection: $selectedAppleTargetID
                                )
                            } else {
                                TranslationLanguagePicker(
                                    targets: googleTargets,
                                    selection: $selectedGoogleTargetID
                                )
                            }
                        } label: {
                            HStack {
                                Text(LanguageManager.shared.localizedString("web_translate_target"))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)
                                    .layoutPriority(1)
                                Spacer(minLength: 12)
                                HStack(spacing: 5) {
                                    if let selectedTarget {
                                        Text(selectedTarget.flag)
                                            .accessibilityHidden(true)
                                    }
                                    Text(selectedTarget?.title ?? selectedTargetID.wrappedValue)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isTranslating)
                    }
                } footer: {
                    Text(LanguageManager.shared.localizedString("web_translate_target_desc"))
                }

                Section {
                    Button {
                        performTranslation()
                    } label: {
                        translationRow(provider: provider)
                    }
                    .disabled(
                        isTranslating
                            || !canTranslateCurrentPage
                    )
                    .buttonStyle(.plain)
                    .opacity((isTranslating || !canTranslateCurrentPage) ? 0.52 : 1)

                    if isTranslating {
                        VStack(alignment: .leading, spacing: 14) {
                            if translationPhase == .analyzing {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text(LanguageManager.shared.localizedString("web_translate_target_desc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if languagePackRequiresDownload {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "character.book.closed")
                                            .foregroundStyle(.blue)
                                        Text(
                                            "\(LanguageManager.shared.localizedString("download")) · "
                                                + (selectedTarget?.title ?? selectedTargetID.wrappedValue)
                                        )
                                        .font(.subheadline.weight(.medium))
                                        Spacer()
                                        if languagePackPrepared {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        } else {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                    Text(LanguageManager.shared.localizedString("web_translate_system_desc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }

                            if totalFragmentCount > 0 {
                                VStack(alignment: .leading, spacing: 7) {
                                    ProgressView(
                                        value: Double(translatedFragmentCount),
                                        total: Double(max(totalFragmentCount, 1))
                                    )
                                    .tint(translationPhase == .translating ? provider.tint : .secondary)
                                    HStack {
                                        Text(LanguageManager.shared.localizedString("web_translate"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(translatedFragmentCount) / \(totalFragmentCount)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, 2)

                        Button(role: .cancel) {
                            cancelTranslation()
                        } label: {
                            Label(LanguageManager.shared.localizedString("cancel"), systemImage: "xmark.circle")
                        }
                    }
                }

                if didTranslate {
                    Section {
                        Button {
                            restoreOriginalPage()
                        } label: {
                            Label(LanguageManager.shared.localizedString("web_translate_restore"), systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isTranslating)
                    }
                }
            }
            .navigationTitle(LanguageManager.shared.localizedString("web_translate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        cancelTranslation()
                        dismiss()
                    }
                }
            }
            // Apple's language-pack confirmation temporarily covers this view
            // and can trigger onDisappear. Cancellation therefore belongs only
            // to explicit Done/Cancel actions; cancelling on disappearance
            // closes the system sheet and creates a presentation loop.
            .interactiveDismissDisabled(isTranslating)
            .translationTask(configuration) { session in
                await translate(using: session)
            }
            .task {
                googleTargets = WebTranslationLanguageCatalog.googleTargets()
                selectedGoogleTargetID = validTargetID(
                    selectedGoogleTargetID,
                    in: googleTargets
                )
                let hasAppliedSystemTranslation = await WebPageTranslationBridge
                    .hasAppliedTranslation(on: webView)
                didTranslate = isGoogleTranslationPageURL(pageURL)
                    || hasAppliedSystemTranslation
                if WebTranslationProvider.availableCases.contains(.apple) {
                    await loadAppleLanguages()
                } else {
                    isLoadingAppleLanguages = false
                }
            }
            .onChange(of: selectedAppleTargetID) { _, _ in
                guard !isTranslating else { return }
                configuration = nil
                activeSession = nil
            }
            .alert(
                LanguageManager.shared.localizedString("web_translate_failed"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func translationRow(
        provider: WebTranslationProvider
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: provider.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(provider.tint)
                .frame(width: 34, height: 34)
                .background(provider.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(LanguageManager.shared.localizedString(provider.titleKey))
                    .foregroundStyle(.primary)
                Text(LanguageManager.shared.localizedString(provider.descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func loadAppleLanguages() async {
        let languages = await LanguageAvailability().supportedLanguages
        guard !Task.isCancelled else { return }
        appleTargets = WebTranslationLanguageCatalog.appleTargets(from: languages)
        selectedAppleTargetID = validTargetID(selectedAppleTargetID, in: appleTargets)
        isLoadingAppleLanguages = false
    }

    private func validTargetID(
        _ savedTargetID: String,
        in targets: [WebTranslationTarget]
    ) -> String {
        if !savedTargetID.isEmpty,
           let saved = WebTranslationLanguageCatalog.bestMatch(
            for: savedTargetID,
            in: targets
           ) {
            return saved
        }
        return WebTranslationLanguageCatalog.bestMatch(
            for: WebTranslationLanguageCatalog.preferredIdentifier,
            in: targets
        ) ?? targets.first?.id ?? ""
    }

    private func performTranslation() {
        switch provider {
        case .apple:
            beginSystemTranslation()
        case .google:
            openGoogleTranslation()
        }
    }

    private func beginSystemTranslation() {
        guard !isTranslating,
              let target = selectedTarget?.appleLanguage else { return }
        let requestID = UUID()
        activeRequestID = requestID
        executingRequestID = nil
        isTranslating = true
        translatedFragmentCount = 0
        totalFragmentCount = 0
        translationPhase = .analyzing
        languagePackRequiresDownload = false
        languagePackPrepared = false

        Task { @MainActor in
            do {
                let snapshot = try await WebPageTranslationBridge.extract(from: webView)
                guard activeRequestID == requestID, !Task.isCancelled else { return }
                didTranslate = false

                guard let source = WebTranslationSourceDetector.dominantLanguage(in: snapshot.fragments) else {
                    throw TranslationError.unableToIdentifyLanguage
                }
                let status = await LanguageAvailability().status(from: source, to: target)
                guard status != .unsupported else {
                    throw TranslationError.unsupportedLanguagePairing
                }
                guard activeRequestID == requestID, !Task.isCancelled else { return }
                languagePackRequiresDownload = status == .supported
                languagePackPrepared = status == .installed
                translationPhase = languagePackRequiresDownload
                    ? .preparingLanguagePack
                    : .translating

                let fragments = WebTranslationSourceDetector.matchingFragments(
                    snapshot.fragments,
                    source: source
                )
                guard !fragments.isEmpty else { throw TranslationError.nothingToTranslate }

                let preparedSnapshot = PageTranslationSnapshot(
                    token: snapshot.token,
                    pageURL: snapshot.pageURL,
                    fragments: fragments,
                    wasLimited: snapshot.wasLimited
                )
                webPageTranslationLogger.debug(
                    "Prepared webpage translation source=\(source.minimalIdentifier, privacy: .public) fragments=\(fragments.count, privacy: .public) extracted=\(snapshot.fragments.count, privacy: .public)"
                )

                pendingSnapshot = preparedSnapshot
                totalFragmentCount = fragments.count
                var nextConfiguration = TranslationSession.Configuration(source: source, target: target)
                if var currentConfiguration = configuration,
                   currentConfiguration.source == nextConfiguration.source,
                   currentConfiguration.target == nextConfiguration.target {
                    currentConfiguration.invalidate()
                    nextConfiguration = currentConfiguration
                }
                configuration = nextConfiguration
            } catch is CancellationError {
                finishCancelledTranslation(requestID: requestID)
            } catch {
                finishFailedTranslation(error, requestID: requestID)
            }
        }
    }

    @MainActor
    private func translate(using session: TranslationSession) async {
        guard let requestID = activeRequestID,
              let snapshot = pendingSnapshot,
              session.targetLanguage == configuration?.target,
              isTranslating,
              executingRequestID != requestID else { return }
        executingRequestID = requestID
        activeSession = session

        do {
            var isWaitingForLanguagePack = languagePackRequiresDownload
            if #available(iOS 26.0, *) {
                isWaitingForLanguagePack = !(await session.isReady)
                languagePackRequiresDownload = isWaitingForLanguagePack
            }
            if isWaitingForLanguagePack {
                translationPhase = .preparingLanguagePack
                languagePackPrepared = false
            } else {
                languagePackPrepared = true
                translationPhase = .translating
            }

            // Translation calls request missing language models themselves.
            // Avoid prepareTranslation() here: it is intended for prefetching
            // before translation and creates a second system-presentation
            // lifecycle when the person has already started translating.

            var translated: [(id: String, text: String)] = []
            var processedCount = 0
            for batch in batches(from: snapshot.fragments) {
                guard activeRequestID == requestID, !Task.isCancelled else {
                    throw CancellationError()
                }
                translated.append(contentsOf: try await translateBatch(batch, using: session))
                if isWaitingForLanguagePack {
                    isWaitingForLanguagePack = false
                    languagePackPrepared = true
                    translationPhase = .translating
                }
                processedCount += batch.count
                translatedFragmentCount = min(processedCount, snapshot.fragments.count)
            }

            guard activeRequestID == requestID,
                  !translated.isEmpty,
                  !Task.isCancelled else {
                throw CancellationError()
            }
            try await WebPageTranslationBridge.apply(translated, snapshot: snapshot, to: webView)
            guard activeRequestID == requestID else { return }

            isTranslating = false
            didTranslate = true
            activeRequestID = nil
            executingRequestID = nil
            pendingSnapshot = nil
            activeSession = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch is CancellationError {
            finishCancelledTranslation(requestID: requestID)
        } catch {
            finishFailedTranslation(error, requestID: requestID)
        }
    }

    private func batches(from fragments: [PageTranslationFragment]) -> [[PageTranslationFragment]] {
        var result: [[PageTranslationFragment]] = []
        var current: [PageTranslationFragment] = []
        var characters = 0

        for fragment in fragments {
            if !current.isEmpty && (current.count >= 24 || characters + fragment.text.count > 8_000) {
                result.append(current)
                current = []
                characters = 0
            }
            current.append(fragment)
            characters += fragment.text.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func translateBatch(
        _ batch: [PageTranslationFragment],
        using session: TranslationSession
    ) async throws -> [(id: String, text: String)] {
        let requests = batch.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        do {
            let responses = try await session.translations(from: requests)
            return responses.enumerated().compactMap { index, response in
                let identifier = response.clientIdentifier
                    ?? (batch.indices.contains(index) ? batch[index].id : nil)
                return identifier.map { (id: $0, text: response.targetText) }
            }
        } catch {
            guard !isTranslationCancellation(error) else { throw error }

            // Do not retry every fragment while the system is still waiting
            // for language assets or the person declined the download. Doing
            // so can request the same system confirmation many times.
            if languagePackRequiresDownload && !languagePackPrepared {
                guard let source = session.sourceLanguage,
                      let target = session.targetLanguage,
                      await LanguageAvailability().status(from: source, to: target) == .installed else {
                    throw error
                }
                languagePackPrepared = true
                translationPhase = .translating
            }

            // Real webpages occasionally contain an isolated label in another
            // language. One such node must not make the whole page fail.
            var recovered: [(id: String, text: String)] = []
            var firstError: Error?
            for fragment in batch {
                guard !Task.isCancelled else { throw CancellationError() }
                do {
                    let response = try await session.translate(fragment.text)
                    recovered.append((id: fragment.id, text: response.targetText))
                } catch {
                    if isTranslationCancellation(error) { throw error }
                    firstError = firstError ?? error
                }
            }
            guard !recovered.isEmpty else { throw firstError ?? error }
            return recovered
        }
    }

    private func isTranslationCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.userCancelled.rawValue { return true }
        if #available(iOS 26.0, *), TranslationError.alreadyCancelled ~= error { return true }
        return false
    }

    private func cancelTranslation() {
        guard isTranslating || activeRequestID != nil else { return }
        if #available(iOS 26.0, *) {
            activeSession?.cancel()
        }
        activeRequestID = nil
        executingRequestID = nil
        pendingSnapshot = nil
        activeSession = nil
        configuration = nil
        isTranslating = false
        translatedFragmentCount = 0
        totalFragmentCount = 0
        translationPhase = .analyzing
        languagePackRequiresDownload = false
        languagePackPrepared = false
    }

    private func finishCancelledTranslation(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        executingRequestID = nil
        pendingSnapshot = nil
        activeSession = nil
        configuration = nil
        isTranslating = false
        translationPhase = .analyzing
        languagePackRequiresDownload = false
        languagePackPrepared = false
    }

    private func finishFailedTranslation(_ error: Error, requestID: UUID) {
        guard activeRequestID == requestID else { return }
        activeRequestID = nil
        executingRequestID = nil
        pendingSnapshot = nil
        activeSession = nil
        configuration = nil
        isTranslating = false
        translatedFragmentCount = 0
        totalFragmentCount = 0
        translationPhase = .analyzing
        languagePackRequiresDownload = false
        languagePackPrepared = false
        let nsError = error as NSError
        webPageTranslationLogger.error(
            "Translation failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
        )
        errorMessage = translationErrorMessage(error)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func translationErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        var details = [error.localizedDescription]
        if let reason = nsError.localizedFailureReason,
           !reason.isEmpty,
           !details.contains(reason) {
            details.append(reason)
        }
        if let suggestion = nsError.localizedRecoverySuggestion,
           !suggestion.isEmpty,
           !details.contains(suggestion) {
            details.append(suggestion)
        }
        return details.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func restoreOriginalPage() {
        if let pageURL,
           isGoogleTranslationPageURL(pageURL),
           let sourceURL = googleTranslationSourcePageURL(from: pageURL) {
            onOpenURL(sourceURL)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            return
        }

        Task { @MainActor in
            do {
                try await WebPageTranslationBridge.restore(on: webView)
                didTranslate = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openGoogleTranslation() {
        guard let target = selectedTarget,
              let url = googleTranslationURL(pageURL: pageURL, target: target.id) else { return }
        onOpenURL(url)
        dismiss()
    }
}

private struct LegacyWebPageTranslationView: View {
    let pageURL: URL?
    let onOpenURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targets: [WebTranslationTarget] = []
    @AppStorage("web_translation_google_target") private var selectedTargetID = ""

    private var canOpenGoogleTranslation: Bool {
        googleTranslationURL(pageURL: pageURL, target: selectedTargetID) != nil
    }

    private var isTranslatedPage: Bool {
        isGoogleTranslationPageURL(pageURL)
    }

    var body: some View {
        NavigationStack {
            List {
                if !targets.isEmpty {
                    NavigationLink {
                        TranslationLanguagePicker(targets: targets, selection: $selectedTargetID)
                    } label: {
                        HStack {
                            Text(LanguageManager.shared.localizedString("web_translate_target"))
                            Spacer(minLength: 12)
                            let selectedTarget = targets.first { $0.id == selectedTargetID }
                            HStack(spacing: 5) {
                                if let selectedTarget {
                                    Text(selectedTarget.flag)
                                        .accessibilityHidden(true)
                                }
                                Text(selectedTarget?.title ?? selectedTargetID)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Label {
                        Text(LanguageManager.shared.localizedString("web_translate_system_requires_ios18"))
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "character.book.closed.fill").foregroundStyle(.secondary)
                    }

                    Button {
                        guard let url = googleTranslationURL(pageURL: pageURL, target: selectedTargetID) else { return }
                        onOpenURL(url)
                        dismiss()
                    } label: {
                        Label(LanguageManager.shared.localizedString("web_translate_google"), systemImage: "globe")
                    }
                    .disabled(!canOpenGoogleTranslation)
                }

                if isTranslatedPage {
                    Section {
                        Button {
                            guard let pageURL,
                                  let sourceURL = googleTranslationSourcePageURL(from: pageURL) else {
                                return
                            }
                            onOpenURL(sourceURL)
                            dismiss()
                        } label: {
                            Label(
                                LanguageManager.shared.localizedString("web_translate_restore"),
                                systemImage: "arrow.uturn.backward"
                            )
                        }
                    }
                }
            }
            .navigationTitle(LanguageManager.shared.localizedString("web_translate"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
            .task {
                targets = WebTranslationLanguageCatalog.googleTargets()
                let requestedTargetID = selectedTargetID.isEmpty
                    ? WebTranslationLanguageCatalog.preferredIdentifier
                    : selectedTargetID
                selectedTargetID = WebTranslationLanguageCatalog.bestMatch(
                    for: requestedTargetID,
                    in: targets
                ) ?? targets.first?.id ?? "en"
            }
        }
    }
}

func googleTranslationURL(pageURL: URL?, target: String) -> URL? {
    guard let pageURL,
          ["http", "https"].contains(pageURL.scheme?.lowercased() ?? ""),
          let sourcePageURL = googleTranslationSourcePageURL(from: pageURL),
          var components = URLComponents(string: "https://translate.google.com/translate") else { return nil }
    let googleTarget: String
    switch target.lowercased() {
    case "zh-hans", "zh-cn", "zh": googleTarget = "zh-CN"
    case "zh-hant", "zh-tw", "zh-hk": googleTarget = "zh-TW"
    default: googleTarget = target
    }
    components.queryItems = [
        URLQueryItem(name: "sl", value: "auto"),
        URLQueryItem(name: "tl", value: googleTarget),
        URLQueryItem(name: "u", value: sourcePageURL.absoluteString)
    ]
    return components.url
}

func isGoogleTranslationPageURL(_ pageURL: URL?) -> Bool {
    guard let host = pageURL?.host?.lowercased() else { return false }
    return host == "translate.google.com"
        || host == "translate.googleusercontent.com"
        || host.hasSuffix(".translate.goog")
}

func googleTranslationSourcePageURL(from pageURL: URL) -> URL? {
    guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
          let host = components.host?.lowercased() else { return nil }

    if host == "translate.google.com" || host == "translate.googleusercontent.com" {
        guard let source = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let sourceURL = URL(string: source),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              sourceURL.host != nil else { return nil }
        return sourceURL
    }

    if host.hasSuffix(".translate.goog") {
        let encodedHost = String(host.dropLast(".translate.goog".count))
        var decodedHost = ""
        var index = encodedHost.startIndex
        while index < encodedHost.endIndex {
            if encodedHost[index] == "-" {
                let next = encodedHost.index(after: index)
                if next < encodedHost.endIndex, encodedHost[next] == "-" {
                    decodedHost.append("-")
                    index = encodedHost.index(after: next)
                } else {
                    decodedHost.append(".")
                    index = next
                }
            } else {
                decodedHost.append(encodedHost[index])
                index = encodedHost.index(after: index)
            }
        }
        guard decodedHost.contains(".") else { return nil }
        components.host = decodedHost
        components.queryItems = components.queryItems?.filter {
            !$0.name.hasPrefix("_x_tr_")
        }
        return components.url
    }

    return pageURL
}
