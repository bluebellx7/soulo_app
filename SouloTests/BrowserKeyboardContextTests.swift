import UIKit
import XCTest
@testable import Soulo

final class BrowserKeyboardContextTests: XCTestCase {
    @MainActor
    func testCommandsRequireTheirKeyWindowAndNoPresentedTool() async throws {
        try await wait("A foreground scene with a key window is required") {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains {
                $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow)
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) })
        let previous = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        let otherWindow = UIWindow(windowScene: scene)
        otherWindow.rootViewController = UIViewController()
        let context = BrowserKeyboardContext()
        let reader = BrowserKeyboardWindowReader.WindowView(owner: context)
        root.view.addSubview(reader)
        defer {
            root.dismiss(animated: false)
            otherWindow.isHidden = true
            otherWindow.rootViewController = nil
            window.isHidden = true
            window.rootViewController = nil
            previous.makeKeyAndVisible()
        }

        window.makeKeyAndVisible()
        try await wait("The mounted browser window must become eligible") {
            context.window === window && context.canPerform
        }
        XCTAssertTrue(context.canPerform)

        // Rebuilding the SwiftUI background can mount a new reader before the
        // old reader detaches. The old lifecycle callback must not clear it.
        let replacement = BrowserKeyboardWindowReader.WindowView(owner: context)
        root.view.addSubview(replacement)
        reader.removeFromSuperview()
        XCTAssertTrue(context.window === window)
        XCTAssertTrue(context.canPerform)

        let tool = UIViewController()
        tool.modalPresentationStyle = .overFullScreen
        root.present(tool, animated: false)
        try await wait("The tool must actually be presented in this window") {
            root.presentedViewController === tool && tool.viewIfLoaded?.window === window
        }
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(context.window === window, "Keep the underlying reader mounted to isolate the modal guard")
        XCTAssertFalse(context.canPerform)

        root.dismiss(animated: false)
        try await wait("Dismissing the tool must restore browser command eligibility") {
            root.presentedViewController == nil && context.canPerform
        }

        otherWindow.makeKeyAndVisible()
        try await wait("The other window must become key") {
            otherWindow.isKeyWindow && !window.isKeyWindow
        }
        XCTAssertTrue(context.window === window)
        XCTAssertFalse(context.canPerform)

        otherWindow.isHidden = true
        window.makeKeyAndVisible()
        try await wait("Returning to the browser window must restore its commands") { context.canPerform }
        XCTAssertTrue(context.canPerform)
    }

    @MainActor
    private func wait(_ stage: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            throw NSError(domain: "SouloKeyboardContextTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: stage])
        }
    }
}
