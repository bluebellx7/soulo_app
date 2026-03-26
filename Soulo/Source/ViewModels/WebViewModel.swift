import Foundation
import WebKit
import Combine

@MainActor
final class WebViewModel: ObservableObject {

    // MARK: - Published State

    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    /// Always-available URL string for copy-link. Never reset to empty.
    var lastURLString: String = ""
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var errorMessage: String?
    @Published var isScrollingUp: Bool = false

    deinit {
        webView = nil
    }

    // MARK: - WebView Reference

    /// Pending URL to load once webView is assigned.
    private var pendingURL: URL?

    var webView: WKWebView? {
        didSet {
            // Load any queued URL once the webView becomes available
            if let url = pendingURL, webView != nil {
                pendingURL = nil
                loadURL(url)
            }
        }
    }

    // MARK: - Navigation

    func loadURL(_ url: URL) {
        errorMessage = nil

        // Always set currentURL immediately so copy-link works even before navigation finishes
        currentURL = url
        lastURLString = url.absoluteString

        guard let webView = webView else {
            // WebView not rendered yet — queue for later
            pendingURL = url
            return
        }

        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        webView.load(request)
    }

    func goBack() {
        guard canGoBack else { return }
        webView?.goBack()
    }

    func goForward() {
        guard canGoForward else { return }
        webView?.goForward()
    }

    func reload() {
        if isLoading {
            webView?.stopLoading()
        } else {
            webView?.reload()
        }
    }

    func loadSearchURL(keyword: String, platform: SearchPlatform) {
        guard let url = platform.searchURL(for: keyword) else {
            errorMessage = "Could not construct search URL for \(platform.name)."
            return
        }
        loadURL(url)
    }

    // MARK: - Internal State Sync (called from Coordinator / KVO)

    func updateProgress(_ progress: Double) {
        estimatedProgress = progress
    }

    func updateLoading(_ loading: Bool) {
        isLoading = loading
        if !loading {
            estimatedProgress = loading ? estimatedProgress : 1.0
        }
    }

    func updateCanGoBack(_ value: Bool) {
        canGoBack = value
    }

    func updateCanGoForward(_ value: Bool) {
        canGoForward = value
    }

    func updateTitle(_ title: String?) {
        pageTitle = title ?? ""
    }

    func updateCurrentURL(_ url: URL?) {
        // Only accept non-nil URLs — prevents KVO from overwriting the URL set by loadURL()
        guard let url = url else { return }
        currentURL = url
        lastURLString = url.absoluteString
    }

    func setError(_ message: String) {
        errorMessage = message
        isLoading = false
    }
}
