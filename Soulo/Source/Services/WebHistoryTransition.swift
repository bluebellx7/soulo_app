import UIKit
import WebKit

/// Use WebKit's own history entry for both gestures and buttons. The button
/// supplies the visual slide using public snapshot and animation APIs.
@MainActor final class WebHistoryTransition {
    private var snapshot: UIView?
    private var animator: UIViewPropertyAnimator?
    private var pending: DispatchWorkItem?

    func goBack(in webView: WKWebView) {
        cancel()
        guard webView.canGoBack else { return }
        guard !UIAccessibility.isReduceMotionEnabled, !UIAccessibility.isVoiceOverRunning,
              webView.window != nil, let parent = webView.superview,
              let image = webView.snapshotView(afterScreenUpdates: false) else {
            webView.goBack()
            return
        }
        image.frame = webView.convert(webView.bounds, to: parent)
        image.isUserInteractionEnabled = false
        image.accessibilityElementsHidden = true
        parent.addSubview(image)
        snapshot = image
        webView.goBack()
        let distance = webView.bounds.width * (webView.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1)
        let work = DispatchWorkItem { [weak self, weak image] in
            guard let self, let image, self.snapshot === image else { return }
            let animation = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut) {
                image.transform = CGAffineTransform(translationX: distance, y: 0)
            }
            animation.addCompletion { [weak self, weak image] _ in
                image?.removeFromSuperview()
                if self?.snapshot === image { self?.snapshot = nil; self?.animator = nil }
            }
            self.animator = animation
            animation.startAnimation()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func cancel() {
        pending?.cancel(); pending = nil
        animator?.stopAnimation(true); animator = nil
        snapshot?.removeFromSuperview(); snapshot = nil
    }
}
