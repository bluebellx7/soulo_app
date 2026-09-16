import SwiftUI
import SwiftData

struct ClipboardPromptView: View {
    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.colorScheme) private var colorScheme

    @State private var offset: CGFloat = -100
    @State private var opacity: Double = 0

    private var previewText: String {
        guard let content = searchVM.clipboardContent else {
            return languageManager.localizedString("clipboard_tap_to_search")
        }
        let prefix = content.prefix(240)
        let compact = prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact + (prefix.endIndex < content.endIndex ? "…" : "")
    }

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(languageManager.localizedString("clipboard_detected"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(previewText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(searchVM.clipboardContent == nil ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("clipboard.preview")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Search button
                Button {
                    searchVM.searchFromClipboard(context: modelContext)
                } label: {
                    Text(languageManager.localizedString("search"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .background(Color(uiColor: .label).opacity(colorScheme == .dark ? 0.9 : 0.82), in: Capsule())
                }
                .buttonStyle(.plain)

                // Dismiss
                Button {
                    searchVM.dismissClipboard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(languageManager.localizedString("cancel"))
            }
            .padding(14)
            .glassCard(cornerRadius: 20)
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .offset(y: offset)
            .opacity(opacity)

            Spacer()
        }
        .task(id: searchVM.clipboardContent) {
            AppAccessibility.announce(
                "\(languageManager.localizedString("clipboard_detected")), \(previewText)"
            )
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                offset = 0
                opacity = 1
            }
            guard !voiceOverEnabled else { return }
            do {
                try await Task.sleep(for: .seconds(8))
                try Task.checkCancellation()
                withAnimation(.easeOut(duration: 0.3)) {
                    offset = -100
                    opacity = 0
                }
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                searchVM.dismissClipboard()
            } catch {
                // Disappearance or new clipboard content cancels this timer.
            }
        }
    }
}
