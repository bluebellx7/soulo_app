import SwiftUI
import Translation
import WebKit

// NEXT VERSION: The page-translation entry points are intentionally hidden in
// 1.1.0 while webpage extraction, language-pack availability, and mixed-content
// restoration are hardened. Keep this implementation for the follow-up release.
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

private struct TranslationTarget: Identifiable, Hashable {
    let id: String
    let title: String

    static let common: [TranslationTarget] = [
        .init(id: "zh-Hans", title: "简体中文"),
        .init(id: "en", title: "English"),
        .init(id: "ja", title: "日本語"),
        .init(id: "ko", title: "한국어"),
        .init(id: "es", title: "Español"),
        .init(id: "fr", title: "Français"),
        .init(id: "de", title: "Deutsch")
    ]

    static var preferred: TranslationTarget {
        let current = UserDefaults.standard.string(forKey: AppConstants.StorageKeys.selectedLanguage)
            ?? Locale.preferredLanguages.first
            ?? "zh-Hans"
        return common.first { current.hasPrefix($0.id) || $0.id.hasPrefix(current) }
            ?? common[0]
    }
}

private struct PageTranslationFragment {
    let id: String
    let text: String
}

private enum WebPageTranslationBridge {
    static let extractionScript = #"""
    (function() {
        window.__souloTranslationOriginals = window.__souloTranslationOriginals || {};
        window.__souloTranslationCounter = window.__souloTranslationCounter || 0;
        var blocked = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'CODE', 'PRE']);
        var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
        var nodes = [];
        var total = 0;
        var node;
        while ((node = walker.nextNode()) && nodes.length < 80 && total < 12000) {
            var parent = node.parentElement;
            if (!parent || blocked.has(parent.tagName) || parent.closest('[contenteditable="true"]')) continue;
            var text = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
            if (text.length < 2 || text.length > 600) continue;
            var style = getComputedStyle(parent);
            if (style.display === 'none' || style.visibility === 'hidden') continue;
            nodes.push({ node: node, text: text });
            total += text.length;
        }
        return nodes.map(function(item) {
            var parent = item.node.parentElement;
            var id;
            if (parent && parent.dataset && parent.dataset.souloTranslationId && parent.childNodes.length === 1) {
                id = parent.dataset.souloTranslationId;
            } else {
                id = 'soulo-' + (++window.__souloTranslationCounter);
                var span = document.createElement('span');
                span.dataset.souloTranslationId = id;
                item.node.parentNode.replaceChild(span, item.node);
                span.appendChild(item.node);
            }
            window.__souloTranslationOriginals[id] = window.__souloTranslationOriginals[id] || item.text;
            return { id: id, text: window.__souloTranslationOriginals[id] };
        });
    })();
    """#

    static let restoreScript = #"""
    (function() {
        var originals = window.__souloTranslationOriginals || {};
        Object.keys(originals).forEach(function(id) {
            var element = document.querySelector('[data-soulo-translation-id="' + id + '"]');
            if (element) element.textContent = originals[id];
        });
        return Object.keys(originals).length;
    })();
    """#

    @MainActor
    static func extract(from webView: WKWebView?) async throws -> [PageTranslationFragment] {
        guard let webView else { throw WebPageCaptureError.unavailable }
        let value = try await webView.evaluateJavaScript(extractionScript)
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let text = row["text"] as? String,
                  !text.isEmpty else { return nil }
            return PageTranslationFragment(id: id, text: text)
        }
    }

    @MainActor
    static func apply(_ translations: [(id: String, text: String)], to webView: WKWebView?) async throws {
        guard let webView else { throw WebPageCaptureError.unavailable }
        let dictionary = Dictionary(uniqueKeysWithValues: translations.map { ($0.id, $0.text) })
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let script = """
        (function(values) {
            Object.keys(values).forEach(function(id) {
                var element = document.querySelector('[data-soulo-translation-id="' + id + '"]');
                if (element) element.textContent = values[id];
            });
            return Object.keys(values).length;
        })(\(json));
        """
        _ = try await webView.evaluateJavaScript(script)
    }

    @MainActor
    static func restore(on webView: WKWebView?) async throws {
        guard let webView else { throw WebPageCaptureError.unavailable }
        _ = try await webView.evaluateJavaScript(restoreScript)
    }
}

@available(iOS 18.0, *)
private struct SystemWebPageTranslationView: View {
    let webView: WKWebView?
    let pageURL: URL?
    let onOpenURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target = TranslationTarget.preferred
    @State private var fragments: [PageTranslationFragment] = []
    @State private var configuration: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var didTranslate = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(LanguageManager.shared.localizedString("web_translate_target"), selection: $target) {
                        ForEach(TranslationTarget.common) { language in
                            Text(language.title).tag(language)
                        }
                    }
                } footer: {
                    Text(LanguageManager.shared.localizedString("web_translate_target_desc"))
                }

                Section {
                    Button {
                        beginSystemTranslation()
                    } label: {
                        translationRow(
                            titleKey: "web_translate_system",
                            descriptionKey: "web_translate_system_desc",
                            systemImage: "character.book.closed.fill",
                            tint: .blue,
                            trailingProgress: isTranslating
                        )
                    }
                    .disabled(isTranslating || pageURL == nil)

                    Button {
                        openGoogleTranslation()
                    } label: {
                        translationRow(
                            titleKey: "web_translate_google",
                            descriptionKey: "web_translate_google_desc",
                            systemImage: "globe",
                            tint: .green
                        )
                    }
                    .disabled(pageURL == nil)
                }

                if didTranslate {
                    Section {
                        Button {
                            restoreOriginalPage()
                        } label: {
                            Label(LanguageManager.shared.localizedString("web_translate_restore"), systemImage: "arrow.uturn.backward")
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
            .translationTask(configuration) { session in
                await translate(using: session)
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
        titleKey: String,
        descriptionKey: String,
        systemImage: String,
        tint: Color,
        trailingProgress: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(LanguageManager.shared.localizedString(titleKey))
                    .foregroundStyle(.primary)
                Text(LanguageManager.shared.localizedString(descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if trailingProgress { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func beginSystemTranslation() {
        guard !isTranslating else { return }
        isTranslating = true
        Task { @MainActor in
            do {
                fragments = try await WebPageTranslationBridge.extract(from: webView)
                guard !fragments.isEmpty else {
                    throw NSError(
                        domain: "Soulo.WebTranslation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: LanguageManager.shared.localizedString("web_translate_no_text")]
                    )
                }
                let targetLanguage = Locale.Language(identifier: target.id)
                configuration = TranslationSession.Configuration(source: nil, target: targetLanguage)
            } catch {
                isTranslating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func translate(using session: TranslationSession) async {
        guard isTranslating, !fragments.isEmpty else { return }
        do {
            let requests = fragments.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
            }
            let responses = try await session.translations(from: requests)
            let translated = zip(fragments, responses).map { fragment, response in
                (id: response.clientIdentifier ?? fragment.id, text: response.targetText)
            }
            try await WebPageTranslationBridge.apply(translated, to: webView)
            await MainActor.run {
                isTranslating = false
                didTranslate = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            await MainActor.run {
                isTranslating = false
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func restoreOriginalPage() {
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
        guard let url = googleTranslationURL(pageURL: pageURL, target: target.id) else { return }
        onOpenURL(url)
        dismiss()
    }
}

private struct LegacyWebPageTranslationView: View {
    let pageURL: URL?
    let onOpenURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target = TranslationTarget.preferred

    var body: some View {
        NavigationStack {
            List {
                Picker(LanguageManager.shared.localizedString("web_translate_target"), selection: $target) {
                    ForEach(TranslationTarget.common) { language in
                        Text(language.title).tag(language)
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
                        guard let url = googleTranslationURL(pageURL: pageURL, target: target.id) else { return }
                        onOpenURL(url)
                        dismiss()
                    } label: {
                        Label(LanguageManager.shared.localizedString("web_translate_google"), systemImage: "globe")
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
        }
    }
}

func googleTranslationURL(pageURL: URL?, target: String) -> URL? {
    guard let pageURL,
          var components = URLComponents(string: "https://translate.google.com/translate") else { return nil }
    let googleTarget = target == "zh-Hans" ? "zh-CN" : target
    components.queryItems = [
        URLQueryItem(name: "sl", value: "auto"),
        URLQueryItem(name: "tl", value: googleTarget),
        URLQueryItem(name: "u", value: pageURL.absoluteString)
    ]
    return components.url
}
