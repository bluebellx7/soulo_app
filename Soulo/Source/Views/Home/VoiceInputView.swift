import SwiftUI

// Custom alignment to align circle centers across different sized buttons
private extension VerticalAlignment {
    struct CircleCenters: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    static let circleCenters = VerticalAlignment(CircleCenters.self)
}

struct VoiceInputView: View {
    @ObservedObject var speechService: SpeechRecognitionService
    @EnvironmentObject var languageManager: LanguageManager
    var onConfirm: (String) -> Void
    var onDismiss: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var wavePhase: CGFloat = 0
    @State private var appeared = false

    var body: some View {
        ZStack {
            // Semi-transparent dark background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)

                // Title
                Text(languageManager.localizedString("voice_listening"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                    .opacity(speechService.isRecording && speechService.recognizedText.isEmpty ? 1 : 0)

                Spacer()

                // Recognized text area
                textArea
                    .padding(.horizontal, 24)

                Spacer()

                // Wave visualizer
                waveVisualizer
                    .frame(height: 40)
                    .padding(.bottom, 16)

                // Error message
                if let error = speechService.errorMessage, !error.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.1), in: Capsule())
                    .padding(.bottom, 8)
                }

                // Action buttons
                actionButtons
                    .padding(.bottom, 50)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .onAppear {
            speechService.recognizedText = ""
            speechService.startRecording(locale: languageManager.speechLocaleIdentifier)
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
        }
        .onDisappear {
            if speechService.isRecording { speechService.stopRecording() }
        }
    }

    // MARK: - Text Area

    private var textArea: some View {
        Group {
            if speechService.recognizedText.isEmpty {
                // Placeholder with animated dots
                HStack(spacing: 6) {
                    if speechService.isRecording {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color(hex: "7C3AED"))
                                .frame(width: 8, height: 8)
                                .scaleEffect(wavePhase == CGFloat(i) ? 1.3 : 0.7)
                                .opacity(wavePhase == CGFloat(i) ? 1 : 0.4)
                                .animation(
                                    .easeInOut(duration: 0.4)
                                    .delay(Double(i) * 0.15)
                                    .repeatForever(autoreverses: true),
                                    value: wavePhase
                                )
                        }
                    } else {
                        Image(systemName: "mic")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(languageManager.localizedString("voice_tap_to_speak"))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 60)
                .onAppear { wavePhase = 2 }
            } else {
                // Editable recognized text in a glass card
                TextField("", text: $speechService.recognizedText, axis: .vertical)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1...5)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
                            )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: speechService.recognizedText.isEmpty)
            }
        }
    }

    // MARK: - Wave Visualizer

    private var waveVisualizer: some View {
        HStack(spacing: 3) {
            ForEach(0..<9, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "6366F1").opacity(speechService.isRecording ? 0.8 : 0.2),
                                Color(hex: "A855F7").opacity(speechService.isRecording ? 0.6 : 0.15)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: barHeight(for: i))
                    .animation(
                        speechService.isRecording
                            ? .easeInOut(duration: 0.25 + Double(i % 3) * 0.08).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.3),
                        value: speechService.isRecording
                    )
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if !speechService.isRecording { return 4 }
        let heights: [CGFloat] = [12, 22, 32, 18, 36, 18, 32, 22, 12]
        return heights[index % heights.count]
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(alignment: .circleCenters, spacing: 36) {
            // Cancel
            Button {
                speechService.stopRecording()
                onDismiss()
            } label: {
                VStack(spacing: 6) {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 52, height: 52)
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                        .overlay(
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        )
                        .alignmentGuide(.circleCenters) { d in d[VerticalAlignment.center] }
                    Text(languageManager.localizedString("cancel"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // Record / Stop — large center button
            Button {
                if speechService.isRecording {
                    speechService.stopRecording()
                } else {
                    speechService.recognizedText = ""
                    speechService.startRecording(locale: languageManager.speechLocaleIdentifier)
                }
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        if speechService.isRecording {
                            Circle()
                                .stroke(Color(hex: "7C3AED").opacity(0.15), lineWidth: 2)
                                .frame(width: 96, height: 96)
                                .scaleEffect(pulseScale)
                                .opacity(2 - Double(pulseScale))
                                .animation(
                                    .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                                    value: pulseScale
                                )
                        }

                        Circle()
                            .fill(
                                speechService.isRecording
                                    ? LinearGradient(colors: [Color(hex: "EF4444"), Color(hex: "DC2626")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "7C3AED")], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 72, height: 72)
                            .shadow(
                                color: speechService.isRecording ? Color.red.opacity(0.25) : Color(hex: "7C3AED").opacity(0.3),
                                radius: 16, y: 6
                            )

                        Image(systemName: speechService.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .alignmentGuide(.circleCenters) { d in d[VerticalAlignment.center] }
                    Text(speechService.isRecording
                         ? languageManager.localizedString("voice_stop")
                         : languageManager.localizedString("voice_record"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .onAppear { pulseScale = 1.5 }

            // Confirm / Search
            Button {
                speechService.stopRecording()
                if !speechService.recognizedText.isEmpty {
                    onConfirm(speechService.recognizedText)
                }
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        if speechService.recognizedText.isEmpty {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 52, height: 52)
                                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                        } else {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "6366F1"), Color(hex: "7C3AED")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 52, height: 52)
                                .shadow(color: Color(hex: "7C3AED").opacity(0.3), radius: 8, y: 3)
                        }
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(speechService.recognizedText.isEmpty ? .white.opacity(0.4) : .white)
                    }
                    .alignmentGuide(.circleCenters) { d in d[VerticalAlignment.center] }
                    Text(languageManager.localizedString("search"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(speechService.recognizedText.isEmpty ? .white.opacity(0.3) : .white.opacity(0.7))
                }
            }
            .disabled(speechService.recognizedText.isEmpty)
        }
    }
}
