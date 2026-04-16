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

        // (Long-press context menus are handled natively via WKUIDelegate contextMenuConfigurationForElement)

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
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WKDownloadDelegate {
        private var lastContentOffset: CGFloat = 0

        private let viewModel: WebViewModel
        private var observations: [NSKeyValueObservation] = []
        private var downloadFileURL: URL?

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewModel.updateLoading(false)
                self.viewModel.updateCurrentURL(webView.url)
                self.viewModel.updateTitle(webView.title)
                // Capture snapshot for tab preview (slight delay for render)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.viewModel.takeSnapshot()
                }
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
            let host = url.host?.lowercased() ?? ""

            // Block all non-web schemes
            let webSchemes: Set<String> = ["http", "https", "about", "blob", "data"]
            guard webSchemes.contains(scheme) else {
                decisionHandler(.cancel)
                NotificationCenter.default.post(
                    name: .webViewExternalURLRequest,
                    object: nil,
                    userInfo: ["url": url]
                )
                return
            }

            // Block known universal link domains that would open external apps
            let externalDomains: [String] = [
                "apps.apple.com", "itunes.apple.com",
                "music.apple.com", "podcasts.apple.com", "books.apple.com",
                "maps.apple.com", "tv.apple.com",
                "open.spotify.com",
                "play.google.com",
                "t.me", "telegram.me",
                "line.me",
                "wa.me", "api.whatsapp.com",
            ]
            if externalDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                decisionHandler(.cancel)
                NotificationCenter.default.post(
                    name: .webViewExternalURLRequest,
                    object: nil,
                    userInfo: ["url": url]
                )
                return
            }

            decisionHandler(.allow)
        }

        // MARK: Download detection — handle non-displayable responses

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            let response = navigationResponse.response
            let mimeType = response.mimeType ?? ""

            // Detect files that should be downloaded, not displayed
            let downloadMIME = [
                "application/pdf", "application/zip", "application/x-zip-compressed",
                "application/octet-stream", "application/msword",
                "application/vnd.openxmlformats-officedocument", "application/x-tar",
                "application/gzip", "text/csv",
            ]
            let isDownload = downloadMIME.contains(where: { mimeType.hasPrefix($0) })
                || (response.suggestedFilename?.contains(".") == true
                    && !["html", "htm", "php", "asp", "jsp"].contains(
                        (response.suggestedFilename as? NSString)?.pathExtension.lowercased() ?? ""
                    )
                    && mimeType == "application/octet-stream")

            if isDownload {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        // MARK: Navigation becomes download

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: WKUIDelegate — open target="_blank" links in new tab

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? false) {
                if let url = navigationAction.request.url {
                    // Open in a new tab via notification
                    NotificationCenter.default.post(
                        name: .openInNewTab,
                        object: nil,
                        userInfo: ["url": url]
                    )
                } else {
                    // Fallback: load in current webView
                    webView.load(navigationAction.request)
                }
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

        // MARK: Native Context Menu (replaces custom JS long-press)

        func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
        ) {
            // Only customize for links — images use the default WKWebView menu
            // which already has "Save to Photos", "Copy", "Share"
            guard let linkURL = elementInfo.linkURL else {
                completionHandler(nil) // default behavior for images, text, etc.
                return
            }

            let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                let openInNewTab = UIAction(
                    title: LanguageManager.shared.localizedString("tab_open_new"),
                    image: UIImage(systemName: "plus.square.on.square")
                ) { _ in
                    NotificationCenter.default.post(
                        name: .openInNewTab,
                        object: nil,
                        userInfo: ["url": linkURL]
                    )
                }

                let copyLink = UIAction(
                    title: LanguageManager.shared.localizedString("copy_link"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.url = linkURL
                }

                let share = UIAction(
                    title: LanguageManager.shared.localizedString("share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in
                    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                          let root = scene.keyWindow?.rootViewController else { return }
                    var vc = root
                    while let presented = vc.presentedViewController { vc = presented }
                    let activityVC = UIActivityViewController(activityItems: [linkURL], applicationActivities: nil)
                    vc.present(activityVC, animated: true)
                }

                return UIMenu(children: [openInNewTab, copyLink, share])
            }
            completionHandler(config)
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent(suggestedFilename)
            // Remove if already exists
            try? FileManager.default.removeItem(at: fileURL)
            downloadFileURL = fileURL

            Task { @MainActor in
                viewModel.isDownloading = true
                viewModel.downloadFileName = suggestedFilename
            }

            completionHandler(fileURL)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let fileURL = downloadFileURL else { return }
            Task { @MainActor in
                viewModel.isDownloading = false

                // Present system share sheet to let user decide where to save
                guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let root = scene.keyWindow?.rootViewController else { return }
                var vc = root
                while let presented = vc.presentedViewController { vc = presented }

                let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                activityVC.completionWithItemsHandler = { _, _, _, _ in
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: fileURL)
                }
                vc.present(activityVC, animated: true)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            Task { @MainActor in
                viewModel.isDownloading = false
                viewModel.setError(LanguageManager.shared.localizedString("save_failed"))
            }
            if let fileURL = downloadFileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}

// MARK: - Notification Name

// (webViewImageLongPressed / webViewLinkLongPressed removed — using native WKUIDelegate context menus)
