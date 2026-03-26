import SwiftUI

struct SpellSuggestionBanner: View {
    let suggestion: String
    let onTap: () -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var languageManager: LanguageManager

    @State private var offset: CGFloat = -60
    @State private var opacity: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(hex: "6366F1"))

            // "Did you mean: suggestion?" — suggestion is tappable and bold
            Button(action: onTap) {
                HStack(spacing: 0) {
                    Text(languageManager.localizedString("did_you_mean") + " ")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)

                    Text(suggestion)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "6366F1"))

                    Text("?")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                Color(hex: "6366F1").opacity(0.06)
            }
        )
        .glassCard(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: "6366F1").opacity(0.18), lineWidth: 0.5)
        )
        .offset(y: offset)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                offset = 0
                opacity = 1
            }
        }
    }
}
