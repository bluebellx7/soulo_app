import SwiftUI
import WebKit

// MARK: - WebViewRepresentable

struct WebViewRepresentable: UIViewRepresentable {

    @ObservedObject var viewModel: WebViewModel
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = false

    // MARK: - Make View

    // Shared process pool — reused across all WKWebView instances for faster creation
    private static let sharedProcessPool = WKProcessPool()
    // Pre-compiled ad block rules (call preWarm() at app launch)
    private static var cachedAdBlockRules: WKContentRuleList?

    /// Call once at app launch to pre-compile ad blocking rules
    static func preWarm() {
        Task {
            cachedAdBlockRules = await AdBlockService.compileRules()
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.sharedProcessPool

        // Custom user agent
        configuration.applicationNameForUserAgent = nil

        // Inline media playback
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Content controller for JS message handler
        let contentController = WKUserContentController()

        // --- JS: Remove login / signup modal overlays ---
        // Only targets overlays on standard search platforms, skips AI chat platforms
        let modalRemovalScript = """
        (function() {
            // Skip on AI chat platforms that need their own login UI
            var skipDomains = ['deepseek.com', 'qianwen.com', 'chatgpt.com', 'claude.ai', 'xiaohongshu.com', 'taobao.com', 'jd.com', 'yuanbao.tencent.com', 'doubao.com', 'metaso.cn'];
            var host = window.location.hostname;
            for (var i = 0; i < skipDomains.length; i++) {
                if (host.includes(skipDomains[i])) return;
            }

            const OVERLAY_SELECTORS = [
                '.login-modal',
                '.signup-dialog',
                '.login-popup',
                '.signup-popup',
                '.auth-modal',
                // Douyin / TikTok
                '[class*="login-guide"]',
                '[class*="loginGuide"]',
                '[class*="login-panel"]',
                '[class*="login-mask"]',
                '[class*="dy-account"]',
                '[class*="passport-sdk"]',
                // Weibo
                '[class*="loginLayer"]',
                '[class*="login-layer"]',
                // Generic
                '[class*="mask-login"]',
                '[class*="guide-login"]'
            ];

            function shouldRemove(el) {
                try {
                    const style = window.getComputedStyle(el);
                    const zIndex = parseInt(style.zIndex, 10);
                    const position = style.position;
                    if (
                        (position === 'fixed' || position === 'absolute') &&
                        zIndex > 999
                    ) {
                        return true;
                    }
                } catch (_) {}
                return false;
            }

            function removeOverlays() {
                OVERLAY_SELECTORS.forEach(function(selector) {
                    try {
                        document.querySelectorAll(selector).forEach(function(el) {
                            if (shouldRemove(el)) {
                                el.remove();
                            }
                        });
                    } catch (_) {}
                });

                // Also remove any high z-index fixed overlay that contains login-related text
                try {
                    document.querySelectorAll('div').forEach(function(el) {
                        var s = window.getComputedStyle(el);
                        if ((s.position === 'fixed' || s.position === 'absolute') &&
                            parseInt(s.zIndex) > 999 &&
                            el.offsetWidth > 100 && el.offsetHeight > 100) {
                            var text = (el.textContent || '').toLowerCase();
                            if (text.includes('登录') || text.includes('login') ||
                                text.includes('注册') || text.includes('sign') ||
                                text.includes('验证码') || text.includes('手机号')) {
                                el.remove();
                            }
                        }
                    });
                } catch(_) {}

                // Restore body scroll
                try {
                    document.body.style.overflow = '';
                    document.documentElement.style.overflow = '';
                } catch (_) {}
            }

            // Run immediately
            removeOverlays();

            // Observe DOM for dynamically injected overlays
            const observer = new MutationObserver(function(mutations) {
                let shouldCheck = false;
                mutations.forEach(function(m) {
                    if (m.addedNodes.length > 0) shouldCheck = true;
                });
                if (shouldCheck) removeOverlays();
            });

            observer.observe(document.body || document.documentElement, {
                childList: true,
                subtree: true
            });
        })();
        """

        let modalScript = WKUserScript(
            source: modalRemovalScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        contentController.addUserScript(modalScript)

        // --- JS: Long-press image detection ---
        let imageDetectionScript = """
        (function() {
            function interceptImages() {
                document.addEventListener('contextmenu', function(e) {
                    const target = e.target;
                    if (target && target.tagName === 'IMG') {
                        const src = target.src || target.currentSrc || '';
                        if (src && src.length > 0) {
                            try {
                                window.webkit.messageHandlers.imageLongPress.postMessage({ src: src });
                            } catch(_) {}
                        }
                    }
                }, true);

                // Also handle long-press via touch events
                let longPressTimer = null;
                document.addEventListener('touchstart', function(e) {
                    const target = e.target;
                    if (target && target.tagName === 'IMG') {
                        longPressTimer = setTimeout(function() {
                            const src = target.src || target.currentSrc || '';
                            if (src && src.length > 0) {
                                try {
                                    window.webkit.messageHandlers.imageLongPress.postMessage({ src: src });
                                } catch(_) {}
                            }
                        }, 500);
                    }
                }, { passive: true });

                document.addEventListener('touchend', function() {
                    if (longPressTimer) {
                        clearTimeout(longPressTimer);
                        longPressTimer = null;
                    }
                }, { passive: true });

                document.addEventListener('touchmove', function() {
                    if (longPressTimer) {
                        clearTimeout(longPressTimer);
                        longPressTimer = null;
                    }
                }, { passive: true });
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', interceptImages);
            } else {
                interceptImages();
            }
        })();
        """

        let imageScript = WKUserScript(
            source: imageDetectionScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        contentController.addUserScript(imageScript)
        contentController.add(context.coordinator, name: "imageLongPress")

        // Ad blocking: inject CSS/JS to hide ad elements
        if adBlockEnabled {
            let adScript = WKUserScript(
                source: AdBlockService.adHidingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
            contentController.addUserScript(adScript)

            // Apply pre-compiled content rules (non-blocking)
            if let cached = Self.cachedAdBlockRules {
                configuration.userContentController.add(cached)
            }
        }

        configuration.userContentController = contentController

        // Build the WKWebView
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .clear
        webView.isOpaque = false

        // Apply custom user agent
        webView.customUserAgent = AppConstants.webViewUserAgent

        // KVO observations
        context.coordinator.observe(webView: webView, viewModel: viewModel)

        // Hand the webView reference back to the ViewModel
        viewModel.webView = webView

        // Pull-to-refresh
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // Scroll direction detection
        webView.scrollView.delegate = context.coordinator

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // URL loading is driven imperatively via viewModel.loadURL(_:)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - Cleanup

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidateObservations()
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "imageLongPress")
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        private var lastContentOffset: CGFloat = 0

        private let viewModel: WebViewModel
        private var observations: [NSKeyValueObservation] = []

        init(viewModel: WebViewModel) {
            self.viewModel = viewModel
        }

        // MARK: KVO

        func observe(webView: WKWebView, viewModel: WebViewModel) {
            observations = [
                webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
                    Task { @MainActor in
                        self?.viewModel.updateProgress(wv.estimatedProgress)
                    }
                },
                webView.observe(\.isLoading, options: .new) { [weak self] wv, _ in
                    Task { @MainActor in
                        self?.viewModel.updateLoading(wv.isLoading)
                    }
                },
                webView.observe(\.canGoBack, options: .new) { [weak self] wv, _ in
                    Task { @MainActor in
                        self?.viewModel.updateCanGoBack(wv.canGoBack)
                    }
                },
                webView.observe(\.canGoForward, options: .new) { [weak self] wv, _ in
                    Task { @MainActor in
                        self?.viewModel.updateCanGoForward(wv.canGoForward)
                    }
                },
                webView.observe(\.title, options: .new) { [weak self] wv, _ in
                    Task { @MainActor in
                        self?.viewModel.updateTitle(wv.title)
                    }
                },
                webView.observe(\.url, options: .new) { [weak self] wv, _ in
                    Task { @MainActor in
                        self?.viewModel.updateCurrentURL(wv.url)
                    }
                }
            ]
        }

        func invalidateObservations() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.errorMessage = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.updateLoading(false)
                viewModel.updateCurrentURL(webView.url)
                viewModel.updateTitle(webView.title)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            handleNavigationError(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleNavigationError(error)
        }

        private func handleNavigationError(_ error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            Task { @MainActor in
                let message: String
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet:
                    message = LanguageManager.shared.localizedString("error_no_internet")
                case NSURLErrorTimedOut:
                    message = LanguageManager.shared.localizedString("error_timeout")
                case NSURLErrorSecureConnectionFailed,
                     NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateUntrusted:
                    message = LanguageManager.shared.localizedString("error_ssl")
                default:
                    message = error.localizedDescription
                }
                viewModel.setError(message)
            }
        }

        // MARK: HTTP Auth Challenge
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Accept server trust for HTTPS (allows self-signed certs in embedded web)
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""

            if ["http", "https", "about", "blob", "data"].contains(scheme) {
                decisionHandler(.allow)
            } else {
                // Non-HTTP schemes — ask user before leaving the app
                decisionHandler(.cancel)
                NotificationCenter.default.post(
                    name: .webViewExternalURLRequest,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }

        // MARK: WKUIDelegate — open target="_blank" links in current webView

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // If the target is a new window (e.g. target="_blank"), load in current webView
            if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? false) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // MARK: WKUIDelegate — JS alert / confirm / prompt

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            topViewController()?.present(alert, animated: true) ?? completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            topViewController()?.present(alert, animated: true) ?? completionHandler(false)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            topViewController()?.present(alert, animated: true) ?? completionHandler(nil)
        }

        private func topViewController() -> UIViewController? {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return nil }
            var vc = root
            while let presented = vc.presentedViewController { vc = presented }
            return vc
        }

        // MARK: Pull-to-Refresh

        @objc func handleRefresh(_ control: UIRefreshControl) {
            viewModel.webView?.reload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                control.endRefreshing()
            }
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let currentOffset = scrollView.contentOffset.y
            let delta = currentOffset - lastContentOffset
            if currentOffset > 50 {
                if delta > 10 {
                    Task { @MainActor in viewModel.isScrollingUp = true }
                } else if delta < -10 {
                    Task { @MainActor in viewModel.isScrollingUp = false }
                }
            } else {
                Task { @MainActor in viewModel.isScrollingUp = false }
            }
            lastContentOffset = currentOffset
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "imageLongPress",
                  let body = message.body as? [String: Any],
                  let srcString = body["src"] as? String,
                  let imageURL = URL(string: srcString)
            else { return }

            // Notify via NotificationCenter so any listener can handle (e.g. preview sheet)
            NotificationCenter.default.post(
                name: .webViewImageLongPressed,
                object: nil,
                userInfo: ["imageURL": imageURL]
            )
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let webViewImageLongPressed = Notification.Name("webViewImageLongPressed")
}
