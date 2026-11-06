import SwiftUI

/// An app-themed canvas for the first document. Existing documents keep their
/// native preview until the next page is ready.
struct BrowserInitialLoadingView: View {
    let url: URL
    var contentBottomInset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()
            VStack(spacing: 6) {
                LoadingBrandMark()
                Text(LanguageManager.shared.localizedString("loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, contentBottomInset)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LanguageManager.shared.localizedString("loading")) + Text(" ") + Text(url.host ?? url.absoluteString))
        .accessibilityIdentifier("browser.initial-loading")
    }
}

/// A compact brushwork spinner with a soft highlight and one rotation animation.
/// The white matte is removed only when rendering this view; the source asset
/// and other uses of the app logo remain unchanged.
private struct LoadingBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var rotating = false

    private var shouldAnimate: Bool { isVisible && scenePhase == .active && !reduceMotion }

    private var mark: some View {
        Image("LoadingLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private var markMask: some View {
        mark.colorInvert().brightness(0.35).contrast(8).luminanceToAlpha()
    }

    var body: some View {
        ZStack {
            mark
                .colorMultiply(colorScheme == .dark ? .white : Color(hex: "F5E6C8"))
                .brightness(colorScheme == .dark ? 0.10 : 0.03)
                .mask { markMask }

            AngularGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.55),
                .init(color: (colorScheme == .dark ? Color(hex: "FFF0CC") : Color(hex: "D4B57D")).opacity(0.55), location: 0.78),
                .init(color: .clear, location: 1)
            ], center: .center)
            .mask { markMask }
        }
        .frame(width: 108, height: 108)
        .opacity(0.9)
        .rotationEffect(.degrees(rotating ? 360 : 0))
        .animation(shouldAnimate ? .linear(duration: 0.8).repeatForever(autoreverses: false) : nil, value: rotating)
        .frame(width: 64, height: 64)
        .clipped()
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: shouldAnimate, initial: true) { _, animate in
            rotating = animate
        }
    }
}
