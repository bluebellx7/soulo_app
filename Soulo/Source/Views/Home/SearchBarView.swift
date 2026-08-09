import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    var isCompact: Bool = false
    var isRecording: Bool = false
    var onSubmit: () -> Void
    var onMicTap: () -> Void
    var onClear: (() -> Void)?

    @ObservedObject var wallpaperManager = WallpaperManager.shared

    @FocusState private var isFocused: Bool
    @State private var animateGlow = false

    private var isLight: Bool {
        !isCompact && wallpaperManager.isCurrentWallpaperLight
    }

    // Adaptive colors based on mode
    private var iconColor: Color {
        isCompact ? Color(UIColor.secondaryLabel) : (isLight ? Color(hex: "2E2A47").opacity(0.5) : .white.opacity(0.5))
    }
    private var iconActiveColor: Color {
        isCompact ? Color(UIColor.label) : (isLight ? Color(hex: "2E2A47").opacity(0.85) : .white.opacity(0.9))
    }
    private var textColor: Color {
        isCompact ? Color(UIColor.label) : (isLight ? Color(hex: "2E2A47") : .white)
    }
    private var placeholderColor: Color {
        isCompact ? Color(UIColor.tertiaryLabel) : (isLight ? Color(hex: "2E2A47").opacity(0.35) : .white.opacity(0.35))
    }
    private var clearColor: Color {
        isCompact ? Color(UIColor.tertiaryLabel) : (isLight ? Color(hex: "2E2A47").opacity(0.4) : .white.opacity(0.4))
    }
    private var dividerColor: Color {
        isCompact ? Color(UIColor.separator) : (isLight ? Color(hex: "2E2A47").opacity(0.15) : .white.opacity(0.15))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? iconActiveColor : iconColor)
                .accessibilityHidden(true)

            TextField(
                "",
                text: $text,
                prompt: Text(LanguageManager.shared.localizedString("search_placeholder"))
                    .foregroundStyle(placeholderColor)
            )
            .font(.system(size: isCompact ? 14 : 15))
            .foregroundStyle(textColor)
            .focused($isFocused)
            .submitLabel(.search)
            .onSubmit(onSubmit)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityLabel(LanguageManager.shared.localizedString("search_placeholder"))

            if !text.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { text = "" }
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(clearColor)
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_clear_search"))
            }

            Rectangle()
                .fill(dividerColor)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            Button(action: onMicTap) {
                ZStack {
                    if isRecording {
                        Circle()
                            .fill(Color.red.opacity(0.2))
                            .frame(width: 26, height: 26)
                            .scaleEffect(animateGlow ? 1.4 : 1.0)
                            .opacity(animateGlow ? 0 : 0.8)
                    }
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isRecording ? .red : iconColor)
                }
                .frame(width: 26, height: 26)
            }
            .onChange(of: isRecording) { _, recording in
                if recording {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: false)) {
                        animateGlow = true
                    }
                } else {
                    animateGlow = false
                }
            }
            .accessibilityLabel(
                LanguageManager.shared.localizedString(isRecording ? "voice_stop" : "voice_record")
            )
            .accessibilityValue(
                LanguageManager.shared.localizedString(
                    isRecording ? "accessibility_voice_recording" : "accessibility_voice_idle"
                )
            )
            .accessibilityHint(LanguageManager.shared.localizedString("accessibility_voice_search_hint"))

        }
        .padding(.horizontal, 14)
        .padding(.vertical, isCompact ? 6 : 10)
        .background {
            if isCompact {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            } else {
                ZStack {
                    if isLight {
                        Capsule().fill(.white.opacity(0.75))
                        Capsule().stroke(Color(hex: "2E2A47").opacity(isFocused ? 0.35 : 0.15), lineWidth: 0.5)
                    } else {
                        Capsule().fill(.ultraThinMaterial.opacity(0.6))
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().stroke(.white.opacity(isFocused ? 0.3 : 0.12), lineWidth: 0.5)
                    }
                }
                .shadow(color: isLight ? .black.opacity(0.04) : .black.opacity(0.2), radius: 16, x: 0, y: 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
