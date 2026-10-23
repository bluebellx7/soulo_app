import UIKit
import WebKit

/// Use WebKit's own history entry for both gestures and buttons. The button
/// supplies the visual slide using public snapshot and animation APIs.
@MainActor final class WebHistoryTransition {
    private var snapshot: UIView?
    private var animator: UIViewPropertyAnimator?
    private var pending: DispatchWorkItem?
    private weak var backwardWebView: WKWebView?
    private var backwardDepth = 0
    private var backwardFrameURL: URL?
    private var backwardRequestID = UUID()

    func goBack(in webView: WKWebView) {
        cancel()
        guard webView.canGoBack else { return }
        backwardWebView = webView
        backwardDepth = webView.backForwardList.backList.count
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

    /// A browser Back action leaves the page, rather than stepping through a
    /// player's child-frame loads. Main-frame history (including SPA states)
    /// still stops traversal, even when its URL has not changed.
    func willNavigateHistory(in webView: WKWebView, isMainFrame: Bool, frameURL: URL?) {
        guard backwardWebView === webView else { return }
        guard !isMainFrame else { cancelBackwardTraversal(); return }
        backwardFrameURL = frameURL
    }

    func frameDidShow(in webView: WKWebView, url: URL?, isHistoryTraversal: Bool) {
        guard backwardWebView === webView, let url else { return }
        if let backwardFrameURL {
            guard backwardFrameURL == url else { return }
        } else {
            guard isHistoryTraversal else { return }
        }
        self.backwardFrameURL = nil
        let sourceDepth = backwardDepth
        backwardRequestID = UUID()
        let requestID = backwardRequestID
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView,
                  self.backwardWebView === webView, self.backwardRequestID == requestID else { return }
            // Wait for pageshow before traversing again. Advancing while a child
            // is restoring can leave the native cursor and SPA state out of sync.
            guard webView.canGoBack, webView.backForwardList.backList.count < sourceDepth else {
                self.cancelBackwardTraversal()
                return
            }
            self.backwardDepth = webView.backForwardList.backList.count
            webView.goBack()
        }
    }

    func cancelBackwardTraversal() {
        backwardWebView = nil
        backwardDepth = 0
        backwardFrameURL = nil
        backwardRequestID = UUID()
    }

    func cancel() {
        cancelBackwardTraversal()
        pending?.cancel(); pending = nil
        animator?.stopAnimation(true); animator = nil
        snapshot?.removeFromSuperview(); snapshot = nil
    }
}
