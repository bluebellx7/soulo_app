import SwiftUI

struct ReaderModeView: View {
    let content: ReaderContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(content.title.isEmpty ? LanguageManager.shared.localizedString("reader_mode") : content.title)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !content.byline.isEmpty {
                            Text(content.byline)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !content.urlString.isEmpty {
                            Text(content.urlString)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Divider()

                    Text(content.text)
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .lineSpacing(7)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(22)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle(LanguageManager.shared.localizedString("reader_mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
        }
    }
}
