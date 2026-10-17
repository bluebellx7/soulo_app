import WebKit

/// Keep OAuth's opener and POST context while waiting for a native decision.
final class WebDomainPopupDelegate: NSObject, WKNavigationDelegate {
    var originURL: URL?
    var userInitiatedNavigationChain = false
    private(set) var hasCommittedDocument = false
    var decide: ((WKWebView, WKNavigationAction, URL?, @escaping (WKNavigationActionPolicy) -> Void) -> Void)?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        userInitiatedNavigationChain = false
        if ["http", "https"].contains(webView.url?.scheme?.lowercased() ?? "") { hasCommittedDocument = true }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let decide else { decisionHandler(.cancel); return }
        decide(webView, action, originURL) { [weak self] policy in
            if policy == .allow, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") { self?.originURL = url }
            decisionHandler(policy)
        }
    }
}
