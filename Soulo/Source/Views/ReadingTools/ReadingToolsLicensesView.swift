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
                guard let url = Bundle.main.url(forResource: "ReadingToolsThirdPartyNotices", withExtension: "txt")
                else { return "" }
                return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }.value
        }
    }
}
