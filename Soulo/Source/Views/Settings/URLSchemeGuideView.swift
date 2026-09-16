import SwiftUI

struct URLSchemeGuideView: View {
    private struct Example: Identifiable {
        let titleKey: String
        let url: String
        var id: String { url }
    }
    private let examples: [Example] = [
        .init(titleKey: "scheme_home", url: "soulo://"),
        .init(titleKey: "scheme_focus", url: "soulo://search"),
        .init(titleKey: "scheme_search", url: "soulo://search?q=Soulo"),
        .init(titleKey: "scheme_open", url: "soulo://open?url=https%3A%2F%2Fexample.com%2F"),
        .init(titleKey: "scheme_download", url: "soulo://download?url=https%3A%2F%2Fexample.com%2Fbook.epub"),
        .init(titleKey: "scheme_scan", url: "soulo://qrcode"),
        .init(titleKey: "scheme_files", url: "soulo://files"),
        .init(titleKey: "scheme_bookmarks", url: "soulo://bookmarks"),
        .init(titleKey: "scheme_history", url: "soulo://history"),
        .init(titleKey: "scheme_downloads", url: "soulo://downloads")
    ]
    @State private var copiedURL: String?

    var body: some View {
        List {
            Section {
                Text(ToolText.text("scheme_intro"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                ForEach(examples) { example in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ToolText.text(example.titleKey)).font(.subheadline.weight(.semibold))
                            Text(example.url).font(.caption.monospaced())
                                .foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            UIPasteboard.general.string = example.url
                            copiedURL = example.url
                            HapticsManager.selection()
                        } label: {
                            Image(systemName: copiedURL == example.url ? "checkmark" : "doc.on.doc")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(ToolText.text(copiedURL == example.url ? "copied" : "copy") + " · " + ToolText.text(example.titleKey))
                        .accessibilityIdentifier("scheme.copy." + example.titleKey)
                    }.padding(.vertical, 4)
                }
            } header: { Text(ToolText.text("scheme_examples")) }
            Section {
                Text(ToolText.text("scheme_encoding"))
                Text("https://example.com/?a=1&b=2\n↓\nsoulo://open?url=https%3A%2F%2Fexample.com%2F%3Fa%3D1%26b%3D2")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(ToolText.text("scheme_download_note"))
            } header: { Text(ToolText.text("scheme_usage")) }
            Section {
                Text(ToolText.text("scheme_aliases"))
                Text("soulo://https://example.com/\nsoulo://download/https://example.com/book.epub\nsoulo://Search\nsoulo://QRCode\nsoulo://Books")
                    .font(.caption.monospaced()).textSelection(.enabled)
            } header: { Text(ToolText.text("scheme_shortcuts")) }
        }
        .navigationTitle(ToolText.text("scheme_title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("scheme.guide")
        .task(id: copiedURL) {
            guard copiedURL != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedURL = nil
        }
    }
}
