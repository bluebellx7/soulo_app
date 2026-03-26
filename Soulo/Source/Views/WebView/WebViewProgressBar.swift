import SwiftUI

// MARK: - WebViewProgressBar

/// A beautiful animated progress bar with gradient fill and glow effect.
struct WebViewProgressBar: View {

    // MARK: - Bindings

    let progress: Double
    let isLoading: Bool

    // MARK: - Private State

    @State private var opacity: Double = 0
    @State private var shimmerOffset: CGFloat = -200

    // MARK: - Constants

    private let barHeight: CGFloat = 2.5
    private let gradientColors: [Color] = [
        Color(red: 0.27, green: 0.53, blue: 1.00),   // vivid blue
        Color(red: 0.55, green: 0.33, blue: 0.98),   // deep purple
        Color(red: 0.84, green: 0.37, blue: 0.95)    // magenta accent
    ]

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track (transparent)
                Color.clear
                    .frame(height: barHeight)

                // Filled bar
                let filledWidth = geometry.size.width * min(max(progress, 0), 1)

                ZStack(alignment: .leading) {
                    // Gradient fill
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: filledWidth, height: barHeight)
                    .clipShape(Capsule())

                    // Shimmer overlay
                    if isLoading {
                        shimmerView(parentWidth: geometry.size.width)
                            .frame(width: filledWidth, height: barHeight)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .frame(height: barHeight)
        .opacity(opacity)
        .onChange(of: isLoading) { _, loading in
            if loading {
                // Appear instantly
                withAnimation(.easeIn(duration: 0.15)) {
                    opacity = 1
                }
                startShimmer()
            } else {
                // Delay fade-out so the bar reaches 100% visually
                withAnimation(.easeOut(duration: 0.35).delay(0.30)) {
                    opacity = 0
                }
            }
        }
        .onChange(of: progress) { _, _ in
            if isLoading && opacity < 1 {
                withAnimation(.easeIn(duration: 0.15)) {
                    opacity = 1
                }
            }
        }
    }

    // MARK: - Shimmer

    @ViewBuilder
    private func shimmerView(parentWidth: CGFloat) -> some View {
        let shimmerWidth: CGFloat = 80
        LinearGradient(
            colors: [
                Color.white.opacity(0),
                Color.white.opacity(0.45),
                Color.white.opacity(0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: shimmerWidth, height: barHeight)
        .offset(x: shimmerOffset)
        .animation(
            Animation.linear(duration: 1.1)
                .repeatForever(autoreverses: false),
            value: shimmerOffset
        )
    }

    private func startShimmer() {
        shimmerOffset = -200
        withAnimation(
            Animation.linear(duration: 1.1)
                .repeatForever(autoreverses: false)
        ) {
            shimmerOffset = UIScreen.main.bounds.width + 200
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Progress Bar") {
    VStack(spacing: 32) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loading — 40%").font(.caption).foregroundStyle(.secondary)
            WebViewProgressBar(progress: 0.4, isLoading: true)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Loading — 75%").font(.caption).foregroundStyle(.secondary)
            WebViewProgressBar(progress: 0.75, isLoading: true)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Complete — hidden").font(.caption).foregroundStyle(.secondary)
            WebViewProgressBar(progress: 1.0, isLoading: false)
        }
    }
    .padding(24)
    .background(Color(.systemBackground))
}
#endif
