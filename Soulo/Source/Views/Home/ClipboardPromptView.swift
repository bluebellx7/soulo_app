import SwiftUI
import SwiftData

struct ClipboardPromptView: View {
    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @Environment(\.modelContext) private var modelContext

    @State private var offset: CGFloat = -100
    @State private var opacity: Double = 0

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: "7C3AED"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(languageManager.localizedString("clipboard_detected"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(searchVM.clipboardContent ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }

                Spacer()

                // Search button
                Button {
                    searchVM.searchFromClipboard(context: modelContext)
                } label: {
                    Text(languageManager.localizedString("search"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "4F46E5"), Color(hex: "7C3AED")],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                }

                // Dismiss
                Button {
                    searchVM.dismissClipboard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
            }
            .padding(16)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .offset(y: offset)
            .opacity(opacity)

            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                offset = 0
                opacity = 1
            }
            // Auto dismiss after 8 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if searchVM.showClipboardPrompt {
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
