import SwiftUI

struct CrossLanguageBanner: View {
    let translatedKeyword: String
    let targetLanguage: String
    var onTap: () -> Void

    @State private var appeared = false

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }) {
            HStack(spacing: 10) {
                // Globe icon
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "7C3AED"))

                // Label
                HStack(spacing: 4) {
                    Text("Also search in")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)

                    Text(targetLanguage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("·")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.tertiary)

                    Text("\"\(translatedKeyword)\"")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: "6366F1"))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Arrow
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "7C3AED").opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .pressEffect()
        .offset(y: appeared ? 0 : 12)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }
}
