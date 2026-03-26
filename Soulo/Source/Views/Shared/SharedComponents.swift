import SwiftUI

// MARK: - Soulo Logo

struct SouloLogoView: View {
    var size: CGFloat = 72
    @State private var shimmer = false

    var body: some View {
        ZStack {
            // Ambient glow rings
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "A855F7").opacity(0.12),
                            Color(hex: "6366F1").opacity(0.04),
                            .clear
                        ],
                        center: .center,
                        startRadius: size * 0.3,
                        endRadius: size * 1.1
                    )
                )
                .frame(width: size * 2.2, height: size * 2.2)

            // Subtle ring decoration
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.08), .white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .frame(width: size * 1.3, height: size * 1.3)

            // Main circle — multi-stop gradient
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "818CF8"),
                            Color(hex: "6366F1"),
                            Color(hex: "7C3AED"),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    // Glass highlight
                    ZStack {
                        // Top highlight arc
                        Ellipse()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: size * 0.7, height: size * 0.35)
                            .offset(y: -size * 0.18)

                        // Shimmer sweep
                        if shimmer {
                            Ellipse()
                                .fill(.white.opacity(0.08))
                                .frame(width: size * 0.3, height: size * 0.8)
                                .rotationEffect(.degrees(-30))
                                .offset(x: size * 0.15, y: -size * 0.05)
                        }
                    }
                )
                .clipShape(Circle())
                .shadow(color: Color(hex: "7C3AED").opacity(0.4), radius: 20, x: 0, y: 8)
                .shadow(color: Color(hex: "6366F1").opacity(0.15), radius: 40, x: 0, y: 4)

            // Search icon — bold and crisp
            Image(systemName: "magnifyingglass")
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).delay(0.5)) {
                shimmer = true
            }
        }
    }
}

// MARK: - Capsule Tag

struct CapsuleTag: View {
    let text: String
    var icon: String?
    var color: Color = .blue
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pressEffect()
    }
}

// MARK: - Pinwheel Button

struct PinwheelButton: View {
    var action: () -> Void
    @State private var rotation: Double = 0

    private let size: CGFloat = 26
    private let colors: [Color] = [
        Color(hex: "EF4444"),
        Color(hex: "3B82F6"),
        Color(hex: "F59E0B"),
        Color(hex: "10B981")
    ]

    var body: some View {
        Button {
            withAnimation(.interpolatingSpring(stiffness: 30, damping: 4)) {
                rotation += 720
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                action()
            }
        } label: {
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let bladeLen = canvasSize.width * 0.42
                let bladeWidth = canvasSize.width * 0.2

                for i in 0..<4 {
                    let angle = Angle.degrees(Double(i) * 90 - 45)
                    let rad = angle.radians

                    // Blade tip
                    let tipX = center.x + bladeLen * CGFloat(cos(rad))
                    let tipY = center.y + bladeLen * CGFloat(sin(rad))

                    // Control points for curved blade
                    let perpRad = rad + .pi / 2
                    let cx1 = center.x + bladeLen * 0.5 * CGFloat(cos(rad)) + bladeWidth * CGFloat(cos(perpRad))
                    let cy1 = center.y + bladeLen * 0.5 * CGFloat(sin(rad)) + bladeWidth * CGFloat(sin(perpRad))

                    var path = Path()
                    path.move(to: center)
                    path.addQuadCurve(to: CGPoint(x: tipX, y: tipY),
                                      control: CGPoint(x: cx1, y: cy1))
                    path.addQuadCurve(to: center,
                                      control: CGPoint(x: center.x + bladeLen * 0.5 * CGFloat(cos(rad)),
                                                       y: center.y + bladeLen * 0.5 * CGFloat(sin(rad))))

                    context.fill(path, with: .color(colors[i]))
                }

                // Center dot
                let dotR: CGFloat = 3
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)),
                    with: .color(.white)
                )
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
    }
}

// MARK: - Blur Background

struct VisualEffectBlur: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - Dynamic Background Themes

enum DynamicTheme: String, Codable, CaseIterable, Identifiable {
    case midnight = "midnight"    // Original purple/indigo
    case ocean = "ocean"          // Blue/cyan
    case aurora = "aurora"        // Green/teal
    case sunset = "sunset"        // Orange/red/pink
    case monochrome = "monochrome" // Grey/silver

    var id: String { rawValue }

    var nameKey: String {
        switch self {
        case .midnight:   return "theme_midnight"
        case .ocean:      return "theme_ocean"
        case .aurora:     return "theme_aurora"
        case .sunset:     return "theme_sunset"
        case .monochrome: return "theme_monochrome"
        }
    }

    var baseColor: Color {
        switch self {
        case .midnight:   return Color(hex: "0A0E27")
        case .ocean:      return Color(hex: "0A1628")
        case .aurora:     return Color(hex: "071A15")
        case .sunset:     return Color(hex: "1A0A0E")
        case .monochrome: return Color(hex: "111115")
        }
    }

    var blobColors: [(Color, Double)] { // (color, opacity)
        switch self {
        case .midnight:
            return [
                (Color(hex: "4F46E5"), 0.25), (Color(hex: "7C3AED"), 0.20),
                (Color(hex: "EC4899"), 0.15), (Color(hex: "06B6D4"), 0.10)
            ]
        case .ocean:
            return [
                (Color(hex: "0EA5E9"), 0.25), (Color(hex: "06B6D4"), 0.22),
                (Color(hex: "3B82F6"), 0.18), (Color(hex: "8B5CF6"), 0.10)
            ]
        case .aurora:
            return [
                (Color(hex: "10B981"), 0.25), (Color(hex: "06B6D4"), 0.20),
                (Color(hex: "34D399"), 0.15), (Color(hex: "3B82F6"), 0.10)
            ]
        case .sunset:
            return [
                (Color(hex: "F97316"), 0.25), (Color(hex: "EF4444"), 0.20),
                (Color(hex: "EC4899"), 0.18), (Color(hex: "F59E0B"), 0.12)
            ]
        case .monochrome:
            return [
                (Color(hex: "6B7280"), 0.20), (Color(hex: "9CA3AF"), 0.15),
                (Color(hex: "4B5563"), 0.18), (Color(hex: "D1D5DB"), 0.08)
            ]
        }
    }
}

// MARK: - Animated Gradient Background

struct AnimatedMeshBackground: View {
    var theme: DynamicTheme = .midnight

    // Blob definitions: normalized position offsets, speed multipliers, and colors
    private struct BlobSpec {
        let anchorX: Double      // rest position X (0-1)
        let anchorY: Double      // rest position Y (0-1)
        let driftX: Double       // horizontal drift amplitude
        let driftY: Double       // vertical drift amplitude
        let freqX: Double        // sine frequency X
        let freqY: Double        // sine frequency Y
        let phase: Double        // phase offset
        let radiusFrac: Double   // radius as fraction of min(w,h)
        let color: Color
    }

    private var blobs: [BlobSpec] {
        let anchors: [(x: Double, y: Double, dx: Double, dy: Double, fx: Double, fy: Double, ph: Double, r: Double)] = [
            (0.25, 0.22, 0.08, 0.06, 0.18, 0.14, 0.0, 0.45),
            (0.72, 0.38, 0.07, 0.09, 0.14, 0.18, 1.2, 0.42),
            (0.48, 0.72, 0.10, 0.07, 0.16, 0.12, 2.5, 0.48),
            (0.20, 0.60, 0.06, 0.08, 0.20, 0.15, 3.8, 0.40),
        ]
        let colors = theme.blobColors
        return anchors.enumerated().map { i, a in
            let (c, o) = colors[i % colors.count]
            return BlobSpec(anchorX: a.x, anchorY: a.y, driftX: a.dx, driftY: a.dy,
                           freqX: a.fx, freqY: a.fy, phase: a.ph, radiusFrac: a.r,
                           color: c.opacity(o))
        }
    }

    var body: some View {
        ZStack {
            theme.baseColor

            // Animated gradient blobs at 30 fps
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let w = size.width
                    let h = size.height
                    let minDim = min(w, h)

                    for blob in blobs {
                        // Slow sine-wave drift around the anchor position
                        let x = (blob.anchorX + blob.driftX * sin(time * blob.freqX + blob.phase)) * w
                        let y = (blob.anchorY + blob.driftY * cos(time * blob.freqY + blob.phase * 0.7)) * h
                        let center = CGPoint(x: x, y: y)
                        let radius = minDim * blob.radiusFrac

                        let ellipse = Path(ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        ))

                        context.fill(
                            ellipse,
                            with: .radialGradient(
                                Gradient(colors: [blob.color, blob.color.opacity(0), .clear]),
                                center: center,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                }
            }

            // Subtle noise / grain texture overlay
            Canvas { context, size in
                // Draw a sparse field of tiny semi-transparent white dots to emulate film grain
                let step: CGFloat = 4
                var y: CGFloat = 0
                // Use a simple deterministic hash to vary opacity per cell
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        let hash = (Int(x) &* 2654435761) ^ (Int(y) &* 2246822519)
                        let norm = Double(abs(hash) % 1000) / 1000.0
                        if norm > 0.55 { // ~45 % of cells get a dot
                            let opacity = 0.018 + norm * 0.022 // range ~0.018 - 0.040
                            context.fill(
                                Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                                with: .color(.white.opacity(opacity))
                            )
                        }
                        x += step
                    }
                    y += step
                }
            }
            .blendMode(.screen)

            // Very faint top-edge highlight for depth
            LinearGradient(
                colors: [.white.opacity(0.03), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    var message: String = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)

                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
            }
            .padding(32)
            .glassCard(cornerRadius: 16)
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }
}
