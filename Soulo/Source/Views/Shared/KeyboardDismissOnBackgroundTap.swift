import SwiftUI
import WebKit

extension View {
    /// Keep taps on editors and embedded web content untouched. Buttons and
    /// scrolling continue to receive their own gestures after dismissing.
    func dismissKeyboardOnBackgroundTap() -> some View {
        background(KeyboardDismissAnchor()).scrollDismissesKeyboard(.interactively)
    }
}

private struct KeyboardDismissAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ uiView: Anchor, context: Context) {}
    static func dismantleUIView(_ uiView: Anchor, coordinator: ()) { uiView.detach() }

    final class Anchor: UIView, UIGestureRecognizerDelegate {
        private weak var attachedWindow: UIWindow?
        private lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard attachedWindow !== window else { return }
            detach()
            if let window { window.addGestureRecognizer(tap); attachedWindow = window }
        }
        func detach() { attachedWindow?.removeGestureRecognizer(tap); attachedWindow = nil }
        @objc private func dismissKeyboard() { attachedWindow?.endEditing(true) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window = attachedWindow, !isHidden, bounds.contains(touch.location(in: self)),
                  touch.view?.window === window else { return false }
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is WKWebView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
