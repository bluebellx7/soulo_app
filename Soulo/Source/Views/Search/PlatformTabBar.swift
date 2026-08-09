import SwiftUI

enum PlatformAccessibilityNavigation {
    static func adjacentIndex(
        currentIndex: Int,
        count: Int,
        direction: AccessibilityPlatformPagingDirection
    ) -> Int? {
        guard count > 0, currentIndex >= 0, currentIndex < count else { return nil }
        let target = currentIndex + (direction == .next ? 1 : -1)
        guard target >= 0, target < count else { return nil }
        return target
    }
}

struct PlatformTabBar: View {
    let platforms: [SearchPlatform]
    @Binding var selectedPlatform: SearchPlatform?
    let onEnterFullscreen: () -> Void
    var usesContrastingControlSurface: Bool = false
    @EnvironmentObject var languageManager: LanguageManager
    @Namespace private var platformNamespace

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(platforms) { platform in
                            let index = platforms.firstIndex(where: { $0.id == platform.id }) ?? 0
                            PlatformTab(
                                platform: platform,
                                isSelected: selectedPlatform?.id == platform.id,
                                namespace: platformNamespace,
                                position: index + 1,
                                total: platforms.count,
                                onPrevious: { selectAdjacentPlatform(.previous) },
                                onNext: { selectAdjacentPlatform(.next) }
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedPlatform = platform
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .id(platform.id)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedPlatform) { _, newValue in
                    if let id = newValue?.id {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Button(action: onEnterFullscreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        usesContrastingControlSurface
                            ? Color(uiColor: .systemGray).opacity(0.88)
                            : Color.primary.opacity(0.58)
                    )
                    .frame(width: 32, height: 32)
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("enter_fullscreen"))
            .padding(.trailing, 4)
        }
    }

    @discardableResult
    private func selectAdjacentPlatform(
        _ direction: AccessibilityPlatformPagingDirection
    ) -> Bool {
        guard let selectedPlatform,
              let currentIndex = platforms.firstIndex(where: { $0.id == selectedPlatform.id }),
              let targetIndex = PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: currentIndex,
                count: platforms.count,
                direction: direction
              ) else {
            let key = direction == .next
                ? "accessibility_last_platform"
                : "accessibility_first_platform"
            AppAccessibility.announce(languageManager.localizedString(key))
            return false
        }

        let target = platforms[targetIndex]
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            self.selectedPlatform = target
        }
        AppAccessibility.announce(
            AppAccessibility.formatted(
                "accessibility_platform_position",
                languageManager.localizedString(target.name),
                targetIndex + 1,
                platforms.count
            )
        )
        return true
    }
}

private struct PlatformTab: View {
    let platform: SearchPlatform
    let isSelected: Bool
    let namespace: Namespace.ID
    let position: Int
    let total: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let action: () -> Void

    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Button(action: action) {
            PlatformIconView(platform: platform, size: 18)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .saturation(isSelected ? 1.0 : 0.0)
                .opacity(isSelected ? 1.0 : 0.48)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Color(hex: "6366F1"))
                            .frame(height: 2)
                            .offset(y: 4)
                            .matchedGeometryEffect(id: "platformTab", in: namespace)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(languageManager.localizedString(platform.name))
        .accessibilityValue(
            isSelected
                ? AppAccessibility.formatted("accessibility_selected_position", position, total)
                : AppAccessibility.formatted("accessibility_item_position", position, total)
        )
        .accessibilityHint(languageManager.localizedString("accessibility_platform_hint"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onNext()
            case .decrement:
                onPrevious()
            @unknown default:
                break
            }
        }
        .accessibilityAction(
            named: Text(languageManager.localizedString("accessibility_previous_platform")),
            onPrevious
        )
        .accessibilityAction(
            named: Text(languageManager.localizedString("accessibility_next_platform")),
            onNext
        )
    }
}
