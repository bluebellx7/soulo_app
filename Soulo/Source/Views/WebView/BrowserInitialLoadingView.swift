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
            VStack(spacing: 9) {
                LoadingBrandMark()
                Text(LanguageManager.shared.localizedString("loading"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color(hex: "E9D6AA") : Color(hex: "B18B4D"))
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

/// Rotate the AppIcon's brushwork as a highlight travels through it.
/// The white matte is removed only when rendering this view; the source asset
/// and other uses of the app logo remain unchanged.
private struct LoadingBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var flowing = false
    @State private var rotating = false
    @State private var breathing = false

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
                .init(color: (colorScheme == .dark ? Color(hex: "FFF0CC") : Color(hex: "D4B57D")).opacity(0.9), location: 0.78),
                .init(color: .clear, location: 1)
            ], center: .center)
            .rotationEffect(.degrees(flowing ? 360 : 0))
            .animation(shouldAnimate ? .linear(duration: 3).repeatForever(autoreverses: false) : nil, value: flowing)
            .mask { markMask }
        }
        .frame(width: 128, height: 128)
        .rotationEffect(.degrees(rotating ? 360 : 0))
        .animation(shouldAnimate ? .linear(duration: 1.5).repeatForever(autoreverses: false) : nil, value: rotating)
        .scaleEffect(shouldAnimate ? (breathing ? 1.01 : 0.99) : 1)
        .animation(shouldAnimate ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true) : nil, value: breathing)
        .frame(width: 76, height: 76)
        .clipped()
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: shouldAnimate, initial: true) { _, animate in
            flowing = animate
            rotating = animate
            breathing = animate
        }
    }
}
