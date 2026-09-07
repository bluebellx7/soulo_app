import XCTest
import SwiftUI
import WebKit
@testable import Soulo

@MainActor final class TabOverviewLifecycleTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var isOverview = false
        let web = WKWebView()
        var created = 0
        var dismantled = 0
    }
    private struct Page: UIViewRepresentable {
        let state: State
        func makeCoordinator() -> State { state }
        func makeUIView(context: Context) -> WKWebView {
            state.created += 1
            return state.web
        }
        func updateUIView(_ view: WKWebView, context: Context) {}
        static func dismantleUIView(_ view: WKWebView, coordinator: State) {
            coordinator.dismantled += 1
        }
    }
    private struct Screen: View {
        @ObservedObject var state: State
        var body: some View { Page(state: state).tabOverviewScale(isActive: state.isOverview) }
    }

    private struct SafeAreaScreen: View {
        let fullscreen: Bool
        var body: some View {
            ZStack {
                Color.blue.ignoresSafeArea()
                VStack { Color.red }
                    .ignoresSafeArea(.container, edges: fullscreen ? .all : .bottom)
                    .tabOverviewScale(isActive: false)
            }
        }
    }

    func testInactiveOverviewDoesNotCropContentOutsideSafeArea() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for fullscreen in [false, true] {
            window.rootViewController = UIHostingController(rootView: SafeAreaScreen(fullscreen: fullscreen))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = fullscreen ? "safearea-fullscreen" : "safearea-bottom"
            attachment.lifetime = .keepAlways; add(attachment)
            var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let rows = fullscreen ? [10, cgImage.height - 10] : [cgImage.height - 10]
            for row in rows {
                let offset = (row * cgImage.width + cgImage.width / 2) * 4
                XCTAssertGreaterThan(pixels[offset], 200, "Safe-area content must remain visible")
                XCTAssertLessThan(pixels[offset + 2], 100, "Root clipping must not expose the blue backdrop")
            }
        }
    }

    func testOverviewAnimationKeepsWebViewMountedAndPageStateIntact() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let state = State()
        window.rootViewController = UIHostingController(rootView: Screen(state: state))
        window.makeKeyAndVisible()
        state.web.loadHTMLString("<html><body><p id='text'>Selected words</p><textarea id='input'>Unsubmitted draft</textarea></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await state.web.evaluateJavaScript("!!document.getElementById('input')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await state.web.evaluateJavaScript("const range=document.createRange();range.selectNodeContents(document.getElementById('text'));getSelection().removeAllRanges();getSelection().addRange(range);window.pageMarker=42")
        let parent = try XCTUnwrap(state.web.superview)
        for _ in 0..<3 {
            for showing in [true, false] {
                withAnimation(.easeInOut(duration: 0.05)) { state.isOverview = showing }
                try await Task.sleep(for: .milliseconds(180))
                XCTAssertEqual(state.created, 1, "Opening overview must not recreate the WebView wrapper")
                XCTAssertEqual(state.dismantled, 0, "Overview must not tear down a live page/selection responder")
                XCTAssertTrue(state.web.superview === parent)
                XCTAssertTrue(state.web.window === window)
            }
        }
        let selection = try await state.web.evaluateJavaScript("getSelection().toString()") as? String
        let draft = try await state.web.evaluateJavaScript("document.getElementById('input').value") as? String
        let marker = try await state.web.evaluateJavaScript("window.pageMarker") as? Int
        XCTAssertEqual(selection, "Selected words")
        XCTAssertEqual(draft, "Unsubmitted draft")
        XCTAssertEqual(marker, 42)
    }
}
