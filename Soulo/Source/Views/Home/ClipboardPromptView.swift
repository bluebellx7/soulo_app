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

                    Text(searchVM.clipboardContent ?? languageManager.localizedString("clipboard_tap_to_search"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(searchVM.clipboardContent == nil ? .secondary : .primary)
                        .lineLimit(1)
                }

                Spacer()

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
        .onAppear {
            AppAccessibility.announce(
                "\(languageManager.localizedString("clipboard_detected")), \(searchVM.clipboardContent ?? languageManager.localizedString("clipboard_tap_to_search"))"
            )
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                offset = 0
                opacity = 1
            }
            // Auto dismiss after 8 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if searchVM.showClipboardPrompt && !voiceOverEnabled {
                    withAnimation(.easeOut(duration: 0.3)) {
                        offset = -100
                        opacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        searchVM.dismissClipboard()
                    }
                }
            }
        }
    }
}
