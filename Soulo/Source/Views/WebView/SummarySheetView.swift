import SwiftUI

struct PageSummaryView: View {
    @ObservedObject var viewModel: WebViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var summary = ""
    @State private var loading = true

    var body: some View {
        SummarySheetView(summary: summary, pageTitle: viewModel.pageTitle, isLoading: loading, onDismiss: { dismiss() })
        .task(id: viewModel.currentURL) {
            loading = true; summary = ""
            let sourceURL = viewModel.currentURL
            do {
                guard let webView = viewModel.webView else { loading = false; return }
                let text = try await webView.evaluateCompatibleJavaScript("(document.querySelector('article') || document.querySelector('main') || document.body)?.innerText?.slice(0,120000) || ''") as? String ?? ""
                let result = try await PageSummaryService.summarizeLocally(text: text, locale: LanguageManager.shared.locale)
                try Task.checkCancellation()
                guard viewModel.currentURL == sourceURL else { return }
                summary = result; loading = false
            } catch {
                guard !Task.isCancelled, viewModel.currentURL == sourceURL else { return }
                summary = error.localizedDescription; loading = false
            }
        }
    }
}

struct SummarySheetView: View {
    let summary: String
    let pageTitle: String
    let isLoading: Bool
    var onDismiss: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(pageTitle).font(.headline)
                    if isLoading {
                        ProgressView(LanguageManager.shared.localizedString("summarizing"))
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        Text(summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(LanguageManager.shared.localizedString("summary_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { UIPasteboard.general.string = summary } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel(LanguageManager.shared.localizedString("copy_summary"))
                        .disabled(isLoading || summary.isEmpty)
                }
            }
        }
    }
}
