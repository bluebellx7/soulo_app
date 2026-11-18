import SwiftUI

struct ReadingToolsLicensesView: View {
    @State private var notices = ""
    @State private var sections: [String] = []
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections.indices, id: \.self) { index in
                    Text(sections[index])
                        .font(.footnote).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20)
        }
        .navigationTitle(ToolText.text("licenses"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = notices
                    HapticsManager.success()
                } label: {
                    Label(LanguageManager.shared.localizedString("copy_all"), systemImage: "doc.on.doc")
                }.disabled(notices.isEmpty)
            }
        }
        .task {
            guard notices.isEmpty else { return }
            let content = await Task.detached(priority: .utility) {
                let text = ["ReadingToolsThirdPartyNotices", "TorrentThirdPartyNotices", "MediaPlaybackThirdPartyNotices", "ED2KThirdPartyNotices", "WebExtensionThirdPartyNotices"].compactMap { name in
                    Bundle.main.url(forResource: name, withExtension: "txt")
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                }.joined(separator: "\n\n")
                // SwiftUI eagerly lays out one long Text even in a ScrollView.
                // Keep paragraph boundaries and let only visible chunks render.
                var chunks: [String] = [], start = text.startIndex
                while start < text.endIndex {
                    var end = text.index(start, offsetBy: 2_400, limitedBy: text.endIndex) ?? text.endIndex
                    if end < text.endIndex, let newline = text[start..<end].lastIndex(of: "\n") {
                        end = text.index(after: newline)
                    }
                    chunks.append(String(text[start..<end])); start = end
                }
                return (text, chunks)
            }.value
            guard !Task.isCancelled else { return }
            notices = content.0; sections = content.1
        }
    }
}
