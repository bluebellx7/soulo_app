import UIKit
import WebKit

struct WebHistoryPreview {
    let url: URL
    let image: UIImage?
}

/// Keep WebKit's history semantics and reuse bounded, in-memory page previews
/// while a button-triggered traversal restores its destination document.
@MainActor final class WebHistoryTransition {
    private struct PageSnapshot {
        weak var item: WKBackForwardListItem?
        let image: UIImage
    }
    private var snapshots: [PageSnapshot] = []
    var onTraversalExhausted: (() -> Void)?
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

    func cache(_ image: UIImage, for item: WKBackForwardListItem) {
        snapshots.removeAll { $0.item == nil || $0.item === item }
        snapshots.append(PageSnapshot(item: item, image: image))
        if snapshots.count > 6 { snapshots.removeFirst(snapshots.count - 6) }
    }

    private func preview(for item: WKBackForwardListItem?) -> WebHistoryPreview? {
        guard let item else { return nil }
        return WebHistoryPreview(url: item.url, image: snapshots.last { $0.item === item }?.image)
    }

    func backPreview(in webView: WKWebView) -> WebHistoryPreview? {
        preview(for: pageTarget(in: Array(webView.backForwardList.backList.reversed())))
    }

    func preview(to url: URL, in webView: WKWebView) -> WebHistoryPreview {
        let entries = webView.backForwardList.backList
            + (webView.backForwardList.currentItem.map { [$0] } ?? [])
            + webView.backForwardList.forwardList
        let matches = entries.filter { $0.url == url }
        // Same-URL SPA entries can represent different views. Do not substitute
        // another entry's pixels when the exact destination is ambiguous.
        if matches.count == 1, let result = preview(for: matches[0]) { return result }
        return WebHistoryPreview(url: url, image: nil)
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
        if let target, target !== webView.backForwardList.backItem { webView.go(to: target) }
        else { webView.goBack() }
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
                self.onTraversalExhausted?()
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
    }

    func reset() {
        cancel()
        snapshots.removeAll()
    }
}
