import SwiftUI

struct PlatformTrialSearch: View {
    let template: String
    @State private var keyword = "Soulo"
    @State private var previewURL: URL?

    private var searchURL: URL? {
        guard let template = SearchPlatformURLInput.searchTemplate(template),
              let encoded = SearchQueryEncoding.encode(keyword.trimmingCharacters(in: .whitespacesAndNewlines)), !encoded.isEmpty else { return nil }
        return SearchPlatformURLInput.webURL(from: template.replacingOccurrences(of: "%@", with: encoded))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(FeatureText.text("Test keyword"), text: $keyword)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button { previewURL = searchURL } label: {
                Label(FeatureText.text("Try search"), systemImage: "magnifyingglass")
            }.disabled(searchURL == nil)
            if let searchURL {
                Text(searchURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            NavigationStack {
                Group { if let previewURL { TrialSearchWebView(url: previewURL) } }
                    .navigationTitle(FeatureText.text("Try search"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button(LanguageManager.shared.localizedString("done")) { previewURL = nil }
                    } }
            }
        }
    }
}

import WebKit

private struct TrialSearchWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}
