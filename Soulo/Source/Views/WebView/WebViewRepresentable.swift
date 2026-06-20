import SwiftUI
import WebKit

// MARK: - WebViewRepresentable

struct WebViewRepresentable: UIViewRepresentable {

    @ObservedObject var viewModel: WebViewModel
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = true
    @AppStorage("ad_block_network_enabled") private var adBlockNetworkEnabled: Bool = true
    @AppStorage("ad_block_cosmetic_enabled") private var adBlockCosmeticEnabled: Bool = true
    @AppStorage("ad_block_popup_enabled") private var adBlockPopupEnabled: Bool = true
    @AppStorage("is_incognito") private var isIncognito: Bool = false
    @ObservedObject private var adBlockSettings = AdBlockSettingsService.shared

    // MARK: - Make View

    // Pre-compiled ad block rules (call preWarm() at app launch)
    private static var cachedAdBlockRules: WKContentRuleList?
    private static var cachedAdBlockAllowlistSignature: String?
    private static var compilingAdBlockAllowlistSignature: String?

    /// Call once at app launch to pre-compile ad blocking rules
    static func preWarm() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "ad_block_enabled") as? Bool ?? true,
              defaults.object(forKey: "ad_block_network_enabled") as? Bool ?? true else {
            return
        }

        Task(priority: .utility) {
            let allowlist = AdBlockSettingsService.shared.allowlistedHosts
            let signature = allowlistSignature(for: allowlist)
            guard compilingAdBlockAllowlistSignature != signature else { return }
            compilingAdBlockAllowlistSignature = signature
            cachedAdBlockAllowlistSignature = signature
            cachedAdBlockRules = await AdBlockService.compileRules(allowlistedHosts: allowlist)
            if compilingAdBlockAllowlistSignature == signature {
                compilingAdBlockAllowlistSignature = nil
            }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Custom user agent
        configuration.applicationNameForUserAgent = nil

        // Inline media playback
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = isIncognito ? .nonPersistent() : .default()

        // Content controller for JS message handler
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "souloAdBlocker")

        let modalScript = WKUserScript(
            source: WebViewScripts.loginOverlayRemoval,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        contentController.addUserScript(modalScript)

        // (Long-press context menus are handled natively via WKUIDelegate contextMenuConfigurationForElement)

        // Ad blocking: inject CSS/JS to hide ad elements
        let hostIsAllowlisted = adBlockSettings.isAllowlisted(viewModel.currentURL?.host)
        if adBlockEnabled && !hostIsAllowlisted && (adBlockCosmeticEnabled || adBlockPopupEnabled) {
            let adScript = WKUserScript(
                source: AdBlockService.adHidingScript(
                    cosmetic: adBlockCosmeticEnabled,
                    popups: adBlockPopupEnabled,
                    allowlistedHosts: adBlockSettings.allowlistedHosts
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
            contentController.addUserScript(adScript)

            // Apply pre-compiled content rules (non-blocking)
            if adBlockNetworkEnabled, !hostIsAllowlisted, let cached = Self.cachedAdBlockRules {
                contentController.add(cached)
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
        context.coordinator.applyAdHidingIfNeeded(
            on: uiView,
                enabled: adBlockEnabled,
                cosmetic: adBlockCosmeticEnabled,
                popups: adBlockPopupEnabled,
                allowlistedHosts: adBlockSettings.allowlistedHosts,
                host: uiView.url?.host ?? viewModel.currentURL?.host
            )
        if adBlockEnabled && adBlockNetworkEnabled {
            Self.ensureCurrentContentRules(on: uiView, allowlist: adBlockSettings.allowlistedHosts)
        } else {
            uiView.configuration.userContentController.removeAllContentRuleLists()
        }
    }

    private static func ensureCurrentContentRules(on webView: WKWebView, allowlist: [String]) {
        let signature = allowlistSignature(for: allowlist)
        guard signature != cachedAdBlockAllowlistSignature || cachedAdBlockRules == nil else { return }
        guard compilingAdBlockAllowlistSignature != signature else { return }
        cachedAdBlockAllowlistSignature = signature
        compilingAdBlockAllowlistSignature = signature
        Task {
            let ruleList = await AdBlockService.compileRules(allowlistedHosts: allowlist)
            await MainActor.run {
                if compilingAdBlockAllowlistSignature == signature {
                    compilingAdBlockAllowlistSignature = nil
                }
                guard cachedAdBlockAllowlistSignature == signature else { return }
                cachedAdBlockRules = ruleList
                webView.configuration.userContentController.removeAllContentRuleLists()
                if let ruleList, !AdBlockSettingsService.isHostAllowlisted(webView.url?.host, allowlistedHosts: allowlist) {
                    webView.configuration.userContentController.add(ruleList)
                }
            }
        }
    }

    private static func allowlistSignature(for allowlist: [String]) -> String {
        let hosts = Array(Set(allowlist.map { AdBlockSettingsService.normalizedHost($0) }.filter { !$0.isEmpty })).sorted().joined(separator: ",")
        return "\(hosts)|rules:\(AdBlockSubscriptionService.rulesSignature())"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - Cleanup

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidateObservations()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "souloAdBlocker")
        uiView.configuration.userContentController.removeAllUserScripts()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        private var lastContentOffset: CGFloat = 0

        private let viewModel: WebViewModel
        private var observations: [NSKeyValueObservation] = []
        private var downloadFileURL: URL?
        private var lastAdHidingSignature = ""
        private var httpsUpgradeFallbacks: [String: URL] = [:]
        private var oneShotHTTPFallbacks = Set<String>()

        init(viewModel: WebViewModel) {
            self.viewModel = viewModel
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "souloAdBlocker",
                  let body = message.body as? [String: Any] else { return }
            let count = body["hiddenCount"] as? Int ?? 0
            let host = (body["host"] as? String) ?? viewModel.currentURL?.host
            Task { @MainActor in
                AdBlockSettingsService.shared.recordHiddenElementCount(count, for: host)
            }
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

        func applyAdHidingIfNeeded(
            on webView: WKWebView,
            enabled: Bool,
            cosmetic: Bool,
            popups: Bool,
            allowlistedHosts: [String],
            host: String?
        ) {
            let signature = [
                host ?? "",
                enabled ? "1" : "0",
                cosmetic ? "1" : "0",
                popups ? "1" : "0",
                allowlistedHosts.joined(separator: ","),
                AdBlockSettingsService.isHostAllowlisted(host) ? "1" : "0"
            ].joined(separator: "|")
            guard signature != lastAdHidingSignature else { return }
            lastAdHidingSignature = signature

            guard enabled, !AdBlockSettingsService.isHostAllowlisted(host), cosmetic || popups else {
                return
            }
            webView.evaluateJavaScript(
                AdBlockService.adHidingScript(cosmetic: cosmetic, popups: popups, allowlistedHosts: allowlistedHosts),
                completionHandler: nil
            )
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel.errorMessage = nil
            }
            lastAdHidingSignature = ""
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                self?.viewModel.updateCurrentURL(webView.url)
            }
            applyCurrentAdHidingIfNeeded(on: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewModel.updateLoading(false)
                self.viewModel.updateCurrentURL(webView.url)
                self.viewModel.updateTitle(webView.title)
                self.applyCurrentAdHidingIfNeeded(on: webView)
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
            if retryHTTPFallbackIfNeeded(on: webView, error: error) {
                return
            }
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
            completionHandler(.performDefaultHandling, nil)
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

            switch WebNavigationPolicyService.shared.decision(for: url) {
            case .allow:
                let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
                let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
                let shouldSkipPrivacyTransform = oneShotHTTPFallbacks.remove(url.absoluteString) != nil

                if method == "GET", !shouldSkipPrivacyTransform {
                    switch PrivacyNavigationService.shared.decision(for: url, isMainFrame: isMainFrame) {
                    case .allow:
                        decisionHandler(.allow)
                    case .redirect(let transformedURL):
                        if isHTTPSUpgrade(from: url, to: transformedURL) {
                            httpsUpgradeFallbacks[transformedURL.absoluteString] = url
                        }
                        decisionHandler(.cancel)
                        webView.load(URLRequest(url: transformedURL))
                    }
                } else {
                    decisionHandler(.allow)
                }
            case .cancel:
                decisionHandler(.cancel)
            case .external(let externalURL):
                decisionHandler(.cancel)
                postExternalURLRequestIfNeeded(externalURL)
            }
        }

        private func isHTTPSUpgrade(from originalURL: URL, to transformedURL: URL) -> Bool {
            originalURL.scheme?.lowercased() == "http"
                && transformedURL.scheme?.lowercased() == "https"
                && originalURL.host?.lowercased() == transformedURL.host?.lowercased()
        }

        private func retryHTTPFallbackIfNeeded(on webView: WKWebView, error: Error) -> Bool {
            let nsError = error as NSError
            let retriableCodes: Set<Int> = [
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut,
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted
            ]
            guard retriableCodes.contains(nsError.code),
                  let failedURL = failingURL(from: nsError),
                  let originalHTTPURL = httpsUpgradeFallbacks.removeValue(forKey: failedURL.absoluteString) else {
                return false
            }

            oneShotHTTPFallbacks.insert(originalHTTPURL.absoluteString)
            webView.load(URLRequest(url: originalHTTPURL))
            return true
        }

        private func failingURL(from error: NSError) -> URL? {
            if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                return url
            }
            if let urlString = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                return URL(string: urlString)
            }
            return nil
        }

        private func postExternalURLRequestIfNeeded(_ url: URL) {
            if ExternalNavigationService.shared.shouldSilentlyBlock(url) { return }
            NotificationCenter.default.post(
                name: .webViewExternalURLRequest,
                object: nil,
                userInfo: ["url": url]
            )
        }

        private func applyCurrentAdHidingIfNeeded(on webView: WKWebView) {
            let defaults = UserDefaults.standard
            applyAdHidingIfNeeded(
                on: webView,
                enabled: defaults.object(forKey: "ad_block_enabled") as? Bool ?? true,
                cosmetic: defaults.object(forKey: "ad_block_cosmetic_enabled") as? Bool ?? true,
                popups: defaults.object(forKey: "ad_block_popup_enabled") as? Bool ?? true,
                allowlistedHosts: AdBlockSettingsService.shared.allowlistedHosts,
                host: webView.url?.host
            )
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
