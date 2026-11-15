import SwiftUI

struct TelegramFeedbackView: View {
    private static let groupURL = URL(string: "https://t.me/soulobrowser")!
    private static let appURL = URL(string: "tg://resolve?domain=soulobrowser")!
    @State private var copied = false
    @State private var openFailed = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Label(ToolText.text("feedback_telegram"), systemImage: "paperplane.fill")
                        .font(.headline)
                    Text(ToolText.text("feedback_telegram_desc"))
                        .foregroundStyle(.secondary)
                    Text(Self.groupURL.absoluteString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings.telegram.link")

                    Button(action: openGroup) {
                        Label(LanguageManager.shared.localizedString("open_directly"), systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CompactActionButtonStyle(prominent: true))
                    .accessibilityIdentifier("settings.telegram.open")

                    Button {
                        UIPasteboard.general.string = Self.groupURL.absoluteString
                        copied = true
                        HapticsManager.selection()
                    } label: {
                        Label(LanguageManager.shared.localizedString(copied ? "copied" : "copy_link"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CompactActionButtonStyle(prominent: false))
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.themeGroupedBg)
        .navigationTitle(ToolText.text("feedback_telegram"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(LanguageManager.shared.localizedString("open_external_failed"), isPresented: $openFailed) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
        }
    }

    private func openGroup() {
        Task { @MainActor in
            if await UIApplication.shared.open(Self.appURL, options: [:]) { return }
            openFailed = !(await UIApplication.shared.open(Self.groupURL, options: [:]))
        }
    }
}
