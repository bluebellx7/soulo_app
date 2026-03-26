import SwiftUI

struct RecommendedPlatformsView: View {
    let recommendations: [SearchPlatform]
    @Binding var selectedPlatform: SearchPlatform?
    @EnvironmentObject var languageManager: LanguageManager

    @State private var isVisible = false

    var body: some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "6366F1"))

                    Text(languageManager.localizedString("suggested_platforms"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recommendations) { platform in
                            RecommendedPlatformChip(
                                platform: platform,
                                isSelected: selectedPlatform?.id == platform.id
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedPlatform = platform
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : -8)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.05)) {
                    isVisible = true
                }
            }
            .onDisappear {
                isVisible = false
            }
        }
    }
}

// MARK: - Chip

private struct RecommendedPlatformChip: View {
    let platform: SearchPlatform
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PlatformIconView(platform: platform, size: 18)

                Text(languageManager.localizedString(platform.name))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color(hex: "6366F1") : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color(hex: "6366F1").opacity(0.12)
                    : Color.primary.opacity(0.0),
                in: Capsule()
            )
            .glassCard(cornerRadius: 20)
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color(hex: "6366F1").opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pressEffect()
    }
}
