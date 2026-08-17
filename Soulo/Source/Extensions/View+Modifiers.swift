import SwiftUI
import UIKit

// MARK: - Accessibility Support

@MainActor
enum AppAccessibility {
    static var isVoiceOverRunning: Bool {
        UIAccessibility.isVoiceOverRunning
    }

    static func announce(_ message: String, after delay: TimeInterval = 0) {
        guard !message.isEmpty else { return }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard UIAccessibility.isVoiceOverRunning else { return }
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        } else {
            guard UIAccessibility.isVoiceOverRunning else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    static func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        let format = LanguageManager.shared.localizedString(key)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}

// MARK: - Card Style

struct CardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var shadowRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: shadowRadius, x: 0, y: 2)
    }
}

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let isLight = WallpaperManager.shared.isCurrentWallpaperLight
        content
            .background {
                if isLight {
                    Color.clear.background(.ultraThinMaterial.opacity(0.8))
                } else {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isLight ? Color(hex: "2E2A47").opacity(0.12) : .white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: isLight ? .black.opacity(0.04) : .black.opacity(0.1), radius: 10, x: 0, y: 4)
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 16, shadowRadius: CGFloat = 8) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius))
    }

    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    func shimmer(isActive: Bool = true) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }

    @ViewBuilder
    func browserToolbarButtonGlass(tint: Color? = nil) -> some View {
        modifier(BrowserToolbarButtonGlassModifier(tint: tint))
    }

    @ViewBuilder
    func browserToolbarCapsuleGlass(tint: Color? = nil) -> some View {
        modifier(BrowserToolbarCapsuleGlassModifier(tint: tint))
    }
}

private struct BrowserToolbarButtonGlassModifier: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: Circle())
        } else {
            content.background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        if let tint {
                            Circle().fill(tint)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            }
        }
    }
}

private struct BrowserToolbarCapsuleGlassModifier: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        } else {
            content.background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        if let tint {
                            Capsule().fill(tint)
                        }
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.6)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            }
        }
    }
}

// MARK: - Shimmer Loading

struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.3), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: -geo.size.width * 0.3 + phase * (geo.size.width * 1.6))
                    }
                    .mask(content)
                )
                .onAppear {
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Press Effect

struct PressEffectModifier: ViewModifier {
    @State private var isPressed = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !voiceOverEnabled else { return }
                        isPressed = true
                    }
                    .onEnded { _ in
                        guard !voiceOverEnabled else { return }
                        isPressed = false
                    }
            )
    }
}

extension View {
    func pressEffect() -> some View {
        modifier(PressEffectModifier())
    }
}

// MARK: - UserDefaults Codable helpers (from DKlugeCore)
// DKlugeCore provides setCodable/getCodable; this shim keeps the local `codable` call-site name.
import DKlugeCore
extension UserDefaults {
    func codable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        getCodable(type, forKey: key)
    }
}
