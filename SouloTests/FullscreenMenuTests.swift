import XCTest
import SwiftUI
@testable import Soulo

final class FullscreenMenuTests: XCTestCase {
    @MainActor
    func testFullscreenMenuRepeatedPresentationAndZoomUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let model = WebViewModel()
        model.currentURL = URL(string: "https://example.com")
        let state = FullscreenMenuTestState()
        let host = UIHostingController(rootView: FullscreenMenuTestSurface(model: model, state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for iteration in 0..<12 {
            state.isVisible = true
            model.pageTitle = "Fullscreen test \(iteration)"
            model.increasePageZoom()
            try await Task.sleep(for: .milliseconds(30))
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.width, 0)
            state.isVisible = false
            try await Task.sleep(for: .milliseconds(20))
        }
        model.resetPageZoom()
        XCTAssertEqual(model.pageZoom, 1)
    }

    @MainActor
    func testAccentMatchesSystemBlueInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let actual = AppTheme.uiAccent.resolvedColor(with: traits)
            let expected = UIColor.systemBlue.resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0
            actual.getRed(&r, green: &g, blue: &b, alpha: nil)
            expected.getRed(&er, green: &eg, blue: &eb, alpha: nil)
            XCTAssertEqual(r, er, accuracy: 0.001)
            XCTAssertEqual(g, eg, accuracy: 0.001)
            XCTAssertEqual(b, eb, accuracy: 0.001)
            XCTAssertEqual(AppTheme.accentCSS(for: style), String(format: "#%02X%02X%02X",
                Int((er * 255).rounded()), Int((eg * 255).rounded()), Int((eb * 255).rounded())))
        }
    }
}

private final class FullscreenMenuTestState: ObservableObject {
    @Published var isVisible = false
}

private struct FullscreenMenuTestSurface: View {
    @ObservedObject var model: WebViewModel
    @ObservedObject var state: FullscreenMenuTestState
    var body: some View {
        VStack {
            if state.isVisible {
                FullscreenQuickMenu(webViewModel: model, title: model.pageTitle,
                    isBookmarked: false, isDesktopMode: false, canSwitchContentMode: true) { _ in }
            }
        }
    }
}
