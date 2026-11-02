import SwiftUI

struct ReadingToolsLicensesView: View {
    @State private var notices = ""
    var body: some View {
        ScrollView {
            Text(notices).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle(ToolText.text("licenses"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notices = await Task.detached {
                ["ReadingToolsThirdPartyNotices", "TorrentThirdPartyNotices", "MediaPlaybackThirdPartyNotices", "ED2KThirdPartyNotices"].compactMap { name in
                    Bundle.main.url(forResource: name, withExtension: "txt")
                        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                }.joined(separator: "\n\n")
            }.value
        }
    }
}
