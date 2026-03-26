import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    var isCompact: Bool = false
    var isRecording: Bool = false
    var onSubmit: () -> Void
    var onMicTap: () -> Void
    var onClear: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var animateGlow = false

    // Adaptive colors based on mode
    private var iconColor: Color {
        isCompact ? Color(UIColor.secondaryLabel) : .white.opacity(0.5)
    }
    private var iconActiveColor: Color {
        isCompact ? Color(UIColor.label) : .white.opacity(0.9)
    }
    private var textColor: Color {
        isCompact ? Color(UIColor.label) : .white
    }
    private var placeholderColor: Color {
        isCompact ? Color(UIColor.tertiaryLabel) : .white.opacity(0.35)
    }
    private var clearColor: Color {
        isCompact ? Color(UIColor.tertiaryLabel) : .white.opacity(0.4)
    }
    private var dividerColor: Color {
        isCompact ? Color(UIColor.separator) : .white.opacity(0.15)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? iconActiveColor : iconColor)

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
            }

            Rectangle()
                .fill(dividerColor)
                .frame(width: 1, height: 16)

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

        }
        .padding(.horizontal, 14)
        .padding(.vertical, isCompact ? 6 : 10)
        .background {
            if isCompact {
                Capsule()
                    .fill(Color(UIColor.secondarySystemFill))
            } else {
                ZStack {
                    Capsule().fill(.ultraThinMaterial.opacity(0.6))
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().stroke(.white.opacity(isFocused ? 0.3 : 0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
