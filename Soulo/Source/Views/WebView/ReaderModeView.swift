import SwiftUI

struct ReaderModeView: View {
    let content: ReaderContent
    @Environment(\.dismiss) private var dismiss

    private var displayBlocks: [ReaderBlock] {
        if !content.blocks.isEmpty {
            return content.blocks
        }
        return content.text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, text in
                ReaderBlock(id: "fallback-\(index)", kind: .paragraph, text: text)
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(content.title.isEmpty ? LanguageManager.shared.localizedString("reader_mode") : content.title)
                            .font(.system(size: 30, weight: .bold, design: .serif))
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
                        .padding(.bottom, 4)

                    ForEach(displayBlocks) { block in
                        blockView(block)
                    }
                }
                .padding(22)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
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

    @ViewBuilder
    private func blockView(_ block: ReaderBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(block.text)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

        case .paragraph:
            paragraphText(block.text)

        case .quote:
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                Text(block.text)
                    .font(.system(size: 18, weight: .regular, design: .serif))
                    .italic()
                    .lineSpacing(7)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(.secondary)
                paragraphText(block.text)
            }

        case .code:
            Text(block.text)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)

        case .image:
            imageBlock(block)
        }
    }

    private func paragraphText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .regular, design: .serif))
            .lineSpacing(7)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func imageBlock(_ block: ReaderBlock) -> some View {
        if let url = URL(string: block.urlString) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        EmptyView()
                    case .empty:
                        Rectangle()
                            .fill(Color(UIColor.secondarySystemBackground))
                            .aspectRatio(16 / 9, contentMode: .fit)
                    @unknown default:
                        EmptyView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if !block.text.isEmpty {
                    Text(block.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
