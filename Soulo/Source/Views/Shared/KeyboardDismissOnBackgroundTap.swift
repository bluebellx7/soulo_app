import SwiftUI
import WebKit

extension View {
    /// Cover this window's navigation pages and sheets, retaining editor taps.
    func dismissKeyboardOnBackgroundTap() -> some View {
        background(KeyboardDismissAnchor()).scrollDismissesKeyboard(.interactively)
    }

    /// SwiftUI buttons can share a hosting view with the surrounding blank area.
    /// Keep taps inside an editor's accessory region from ending its editing session.
    func preservesKeyboardFocusOnTap() -> some View {
        background(KeyboardDismissAnchor(preservesFocus: true))
    }
}

enum AppKeyboardDismissal {
    @MainActor
    @discardableResult
    static func install(on window: UIWindow) -> BackgroundKeyboardDismissGesture {
        if let existing = window.gestureRecognizers?.first(where: { $0 is BackgroundKeyboardDismissGesture }) as? BackgroundKeyboardDismissGesture {
            return existing
        }
        let gesture = BackgroundKeyboardDismissGesture(window: window)
        window.addGestureRecognizer(gesture)
        return gesture
    }

    @MainActor
    static func acceptsBackgroundTap(on view: UIView?) -> Bool {
        guard let view else { return false }
        var candidate: UIView? = view
        while let current = candidate {
            // Preserve native controls, editor cursors and webpage interactions.
            if current is UIControl || current is UITextView || current is WKWebView
                || current.accessibilityTraits.contains(.button) { return false }
            candidate = current.superview
        }
        return true
    }
}

final class BackgroundKeyboardDismissGesture: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var ownerWindow: UIWindow?
    private weak var touchedEditor: UIView?
    private let editorAccessories = NSHashTable<UIView>.weakObjects()

    init(window: UIWindow) {
        ownerWindow = window
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(dismissKeyboard))
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    @objc private func dismissKeyboard() {
        // Let SwiftUI deliver a button/navigation action before keyboard-driven
        // sheet resizing moves its target. Never resign a newly focused field.
        let editor = touchedEditor
        DispatchQueue.main.async { [weak editor] in
            if let editor, editor.isFirstResponder { editor.resignFirstResponder() }
        }
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let editor = firstResponder(in: child) { return editor }
        }
        return nil
    }

    func preserveFocus(in region: UIView) { editorAccessories.add(region) }

    func preservesFocus(at point: CGPoint, touchedView: UIView) -> Bool {
        guard let window = ownerWindow else { return false }
        return editorAccessories.allObjects.contains {
            $0.window === window && $0.convert($0.bounds, to: window).contains(point)
                && sharesPresentation($0, with: touchedView)
        }
    }

    private func sharesPresentation(_ region: UIView, with touchedView: UIView) -> Bool {
        var responder: UIResponder? = region
        while let current = responder {
            if let view = current as? UIView, view.isHidden || view.alpha < 0.01 { return false }
            if let controller = current as? UIViewController {
                // An editor behind a presented sheet must not shield blank taps
                // in the sheet just because their screen coordinates overlap.
                return touchedView.isDescendant(of: controller.view)
            }
            responder = current.next
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = ownerWindow, let touchedView = touch.view, touchedView.window === window,
              !preservesFocus(at: touch.location(in: window), touchedView: touchedView) else { return false }
        guard AppKeyboardDismissal.acceptsBackgroundTap(on: touchedView) else { return false }
        touchedEditor = firstResponder(in: window)
        return touchedEditor != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

private struct KeyboardDismissAnchor: UIViewRepresentable {
    var preservesFocus = false
    func makeUIView(context: Context) -> Anchor { Anchor(preservesFocus: preservesFocus) }
    func updateUIView(_ uiView: Anchor, context: Context) {}

    final class Anchor: UIView {
        private let preservesFocus: Bool
        init(preservesFocus: Bool) {
            self.preservesFocus = preservesFocus
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                let gesture = AppKeyboardDismissal.install(on: window)
                if preservesFocus { gesture.preserveFocus(in: self) }
            }
        }
    }
}
