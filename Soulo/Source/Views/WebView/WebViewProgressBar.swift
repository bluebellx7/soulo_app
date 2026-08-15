import SwiftUI

// MARK: - WebViewProgressBar

/// A quiet neutral progress indicator that adapts to light and dark browser
/// chrome without competing with page content.
struct WebViewProgressBar: View {

    // MARK: - Bindings

    let progress: Double
    let isLoading: Bool

    // MARK: - Private State

    @State private var opacity: Double = 0

    // MARK: - Constants

    private let barHeight: CGFloat = 2

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.primary.opacity(0.06)
                    .frame(height: barHeight)

                // Filled bar
                let filledWidth = geometry.size.width * min(max(progress, 0), 1)

                Color.primary
                    .opacity(0.68)
                    .frame(width: filledWidth, height: barHeight)
                    .clipShape(Capsule())
                    .shadow(color: Color.primary.opacity(0.12), radius: 1, y: 0.5)
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
