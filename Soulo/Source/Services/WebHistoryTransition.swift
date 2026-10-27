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
    private let automaticRedirectEntries = NSHashTable<WKBackForwardListItem>.weakObjects()

    func recordAutomaticRedirect(in webView: WKWebView) {
        // Keep an initial entry when there is no earlier page to return to.
        guard webView.canGoBack, let entry = webView.backForwardList.currentItem else { return }
        automaticRedirectEntries.add(entry)
    }

    func recordInteraction(in webView: WKWebView) {
        if let entry = webView.backForwardList.currentItem { automaticRedirectEntries.remove(entry) }
    }

    private func pageTarget(in entries: [WKBackForwardListItem]) -> WKBackForwardListItem? {
        entries.first { !automaticRedirectEntries.contains($0) }
    }

    /// Also handles WebKit's own Back/Forward gestures. Identify the exact
    /// recorded entry conservatively; equal-URL SPA states remain untouched.
    func targetSkippingAutomaticRedirects(to url: URL, from source: URL?, in webView: WKWebView) -> WKBackForwardListItem? {
        guard let current = webView.backForwardList.currentItem, let source else { return nil }
        let entries = webView.backForwardList.backList + [current] + webView.backForwardList.forwardList
        let sources = entries.indices.filter { entries[$0].url == source }
        let targets = entries.indices.filter { entries[$0].url == url && automaticRedirectEntries.contains(entries[$0]) }
        guard sources.count == 1, targets.count == 1, let origin = sources.first, let target = targets.first else { return nil }
        if target < origin { return pageTarget(in: Array(entries[...target].reversed())) }
        if target > origin { return pageTarget(in: Array(entries[target...])) }
        return nil
    }

    func goForward(in webView: WKWebView) {
        cancel()
        if let target = pageTarget(in: webView.backForwardList.forwardList), target !== webView.backForwardList.forwardItem { webView.go(to: target) }
        else { webView.goForward() }
    }

    func goBack(in webView: WKWebView) {
        cancel()
        guard webView.canGoBack else { return }
        backwardWebView = webView
        backwardDepth = webView.backForwardList.backList.count
        let target = pageTarget(in: Array(webView.backForwardList.backList.reversed()))
        let navigate = {
            if let target, target !== webView.backForwardList.backItem { webView.go(to: target) }
            else { webView.goBack() }
        }
        guard !UIAccessibility.isReduceMotionEnabled, !UIAccessibility.isVoiceOverRunning,
              webView.window != nil, let parent = webView.superview,
              let image = webView.snapshotView(afterScreenUpdates: false) else {
            navigate()
            return
        }
        image.frame = webView.convert(webView.bounds, to: parent)
        image.isUserInteractionEnabled = false
        image.accessibilityElementsHidden = true
        parent.addSubview(image)
        snapshot = image
        navigate()
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
