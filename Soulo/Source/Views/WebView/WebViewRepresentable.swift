import SwiftUI
import UIKit
import WebKit

enum WebExtensionInstallBrandAssets {
    static let logoDataURL: String = {
        guard let image = UIImage(named: "SouloLogo"),
              let data = image.pngData() else { return "" }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }()
}

@MainActor
private enum BrowserDownloadResumeClaims {
    private static var ids = Set<UUID>()
    static func claim(_ id: UUID) -> Bool { ids.insert(id).inserted }
    static func release(_ id: UUID) { ids.remove(id) }
}

enum WebNavigationErrorClassifier {
    static func isExpectedInterruption(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }

        let webKitDomains: Set<String> = [WKError.errorDomain, "WebKitErrorDomain", "WKErrorDomain"]
        // WebKit's long-standing policy-change interruption code is 102. Some
        // SDK overlays do not expose a named Swift enum case for it.
        return webKitDomains.contains(nsError.domain) && nsError.code == 102
    }
}

enum BrowserAutomaticNavigationPolicy {
    static let preferenceKey = "ad_block_allow_automatic_navigation"
    static let world = WKContentWorld.world(name: "SouloNavigationGesture")
    static let handler = "souloNavigationGesture"
    static let script = """
    (() => {
      if (window.__souloNavigationGestureInstalled) return;
      window.__souloNavigationGestureInstalled = true;
      function interacted(event) {
        if (!event.isTrusted) return;
        if (event.type === 'keydown' && !['Enter', ' '].includes(event.key)) return;
        window.webkit.messageHandlers.souloNavigationGesture.postMessage({url: location.href});
      }
      window.addEventListener('click', interacted, true);
      window.addEventListener('keydown', interacted, true);
    })();
    """
}

enum BrowserPopupPolicy {
    private static let authenticationHostSuffixes = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "auth0.com",
        "okta.com"
    ]

    private static let authenticationURLMarkers = [
        "/oauth", "/authorize", "/authorization", "/auth/",
        "/login", "/signin", "/sign-in", "/sso/"
    ]

    static func shouldPreserveJavaScriptContext(
        navigationType: WKNavigationType,
        url: URL
    ) -> Bool {
        if url.scheme?.lowercased() == "about" {
            return true
        }
        guard navigationType == .other || navigationType == .linkActivated,
              let host = url.host?.lowercased() else {
            return false
        }
        if authenticationHostSuffixes.contains(where: {
            host == $0 || host.hasSuffix(".\($0)")
        }) {
            return true
        }
        let normalizedURL = url.absoluteString.lowercased()
        return authenticationURLMarkers.contains { normalizedURL.contains($0) }
    }
}

private enum EmbeddedBrowserPopupTag {
    static let container = 0x534F554C
}

enum WebMediaCapturePermissionPolicy {
    /// Web media capture is allowed to reach WebKit's site permission prompt
    /// only from secure origins. Soulo never grants camera or microphone
    /// access on a site's behalf.
    static func decision(forScheme scheme: String?) -> WKPermissionDecision {
        scheme?.lowercased() == "https" ? .prompt : .deny
    }
}

enum WebMotionPermissionPolicy {
    static func decision(forScheme scheme: String?) -> WKPermissionDecision {
        scheme?.lowercased() == "https" ? .prompt : .deny
    }
}

enum BrowserDownloadPolicy {
    private static let downloadableMIMEPrefixes = [
        "application/pdf",
        "application/zip",
        "application/x-zip-compressed",
        "application/x-chrome-extension",
        "application/x-xpinstall",
        "application/octet-stream",
        "application/msword",
        "application/vnd.openxmlformats-officedocument",
        "application/x-tar",
        "application/gzip",
        "text/csv",
    ]

    static func shouldDownloadNavigationAction(
        requestedByPage: Bool,
        nativeRequest: Bool
    ) -> Bool {
        requestedByPage && !nativeRequest
    }

    static func shouldDownload(
        requestedByPage: Bool = false,
        canShowMIMEType: Bool = true,
        mimeType: String? = nil,
        contentDisposition: String? = nil,
        responseURL: URL? = nil
    ) -> Bool {
        if requestedByPage {
            return true
        }

        if contentDisposition?.lowercased().contains("attachment") == true {
            return true
        }

        let normalizedMIMEType = mimeType?.lowercased() ?? ""
        // A web page remains a navigation even if WebKit temporarily reports
        // that it cannot display the response while a process is starting.
        if normalizedMIMEType.hasPrefix("text/html")
            || normalizedMIMEType.hasPrefix("application/xhtml+xml") {
            return false
        }
        // Install package URLs are downloaded only after seeing a non-page
        // response. A site may use one of these paths for an HTML landing page.
        if responseURL.map(BrowserExtensionInstallCandidate.recognizedDownloadURL) == true {
            return true
        }
        if !canShowMIMEType { return true }
        return downloadableMIMEPrefixes.contains { normalizedMIMEType.hasPrefix($0) }
    }
}

enum AccessibilityPlatformPagingDirection {
    case previous
    case next
}

enum WebAccessibilityPaging {
    enum VerticalDirection {
        case backward
        case forward
    }

    static func targetOffset(
        current: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        viewportHeight: CGFloat,
        direction: VerticalDirection
    ) -> CGFloat? {
        guard maximum > minimum, viewportHeight > 1 else { return nil }
        let distance = max(viewportHeight * 0.82, 1)
        let proposed = current + (direction == .forward ? distance : -distance)
        let target = min(max(proposed, minimum), maximum)
        guard abs(target - current) > 1 else { return nil }
        return target
    }

    static func pagePosition(
        offset: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        viewportHeight: CGFloat
    ) -> (current: Int, total: Int) {
        let distance = max(viewportHeight * 0.82, 1)
        let scrollableDistance = max(maximum - minimum, 0)
        let total = max(Int(ceil(scrollableDistance / distance)) + 1, 1)
        let progress = min(max(offset - minimum, 0), scrollableDistance)
        let current = min(max(Int(round(progress / distance)) + 1, 1), total)
        return (current, total)
    }
}

@MainActor
private final class UserScriptTabStore {
    static let shared = UserScriptTabStore()

    private var values: [UUID: [String: String]] = [:]

    func save(_ encodedValue: String, scriptID: UUID, tabID: String) throws {
        guard encodedValue.utf8.count <= BrowserExtensionService.maximumStoredValueSize,
              let data = encodedValue.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw BrowserExtensionError.invalidStorageValue
        }
        values[scriptID, default: [:]][tabID] = encodedValue
    }

    func value(scriptID: UUID, tabID: String) -> Any {
        decode(values[scriptID]?[tabID]) ?? [:]
    }

    func allValues(scriptID: UUID) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: (values[scriptID] ?? [:]).compactMap { key, value in
            decode(value).map { (key, $0) }
        })
    }

    private func decode(_ encodedValue: String?) -> Any? {
        guard let encodedValue,
              let data = encodedValue.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// WKWebView already exposes semantic HTML to VoiceOver. This subclass adds
/// deterministic page scrolling and horizontal platform paging when a site or
/// custom browser gesture does not respond to VoiceOver's three-finger swipe.
final class AccessibleWebView: WKWebView {
    private var nativeNavigationRequests: [URL: TimeInterval] = [:]

    private func recordNativeNavigation(to url: URL?) {
        let now = ProcessInfo.processInfo.systemUptime
        nativeNavigationRequests = nativeNavigationRequests.filter { now - $0.value < 5 }
        if let url { nativeNavigationRequests[url] = now }
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        recordNativeNavigation(to: request.url)
        return super.load(request)
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        recordNativeNavigation(to: baseURL ?? URL(string: "about:blank"))
        return super.loadHTMLString(string, baseURL: baseURL)
    }

    override func loadFileURL(_ URL: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        recordNativeNavigation(to: URL)
        return super.loadFileURL(URL, allowingReadAccessTo: readAccessURL)
    }

    func consumeNativeNavigation(to url: URL) -> Bool {
        guard let time = nativeNavigationRequests.removeValue(forKey: url) else { return false }
        return ProcessInfo.processInfo.systemUptime - time < 5
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        SelectionWebSearch.replace(in: builder) { [weak self] in
            if let self { SelectionWebSearch.search(in: self) }
        }
        if let editing = builder.menu(for: .standardEdit) {
            let rows = editing.replacingChildren(editing.children)
            rows.preferredElementSize = .large
            builder.replace(menu: .standardEdit, with: rows)
        }
    }

    var onAccessibilityPlatformPage: ((AccessibilityPlatformPagingDirection) -> Bool)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard UIAccessibility.isVoiceOverRunning else {
            return super.accessibilityScroll(direction)
        }

        switch direction {
        case .left:
            let pagingDirection: AccessibilityPlatformPagingDirection =
                effectiveUserInterfaceLayoutDirection == .rightToLeft ? .previous : .next
            return onAccessibilityPlatformPage?(pagingDirection) ?? false
        case .right:
            let pagingDirection: AccessibilityPlatformPagingDirection =
                effectiveUserInterfaceLayoutDirection == .rightToLeft ? .next : .previous
            return onAccessibilityPlatformPage?(pagingDirection) ?? false
        case .next:
            return onAccessibilityPlatformPage?(.next) ?? false
        case .previous:
            return onAccessibilityPlatformPage?(.previous) ?? false
        case .up:
            return scrollVertically(.forward)
        case .down:
            return scrollVertically(.backward)
        @unknown default:
            return super.accessibilityScroll(direction)
        }
    }

    private func scrollVertically(_ direction: WebAccessibilityPaging.VerticalDirection) -> Bool {
        let scrollView = scrollView
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(
            minimum,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )

        guard let target = WebAccessibilityPaging.targetOffset(
            current: scrollView.contentOffset.y,
            minimum: minimum,
            maximum: maximum,
            viewportHeight: scrollView.bounds.height,
            direction: direction
        ) else {
            let key = direction == .forward
                ? "accessibility_page_bottom"
                : "accessibility_page_top"
            AppAccessibility.announce(LanguageManager.shared.localizedString(key))
            return true
        }

        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: target),
            animated: true
        )
        let position = WebAccessibilityPaging.pagePosition(
            offset: target,
            minimum: minimum,
            maximum: maximum,
            viewportHeight: scrollView.bounds.height
        )
        AppAccessibility.announce(
            AppAccessibility.formatted(
                "accessibility_page_position",
                position.current,
                position.total
            ),
            after: 0.3
        )
        return true
    }
}

// MARK: - WebViewRepresentable

struct WebViewRepresentable: UIViewRepresentable {

    @ObservedObject var viewModel: WebViewModel
    var onAccessibilityPlatformPage: ((AccessibilityPlatformPagingDirection) -> Bool)?
    var obscuredBottomInset: CGFloat = 0
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = true
    @AppStorage("is_incognito") private var isIncognito: Bool = false
    @AppStorage("privacy_gpc_enabled") private var gpcEnabled = PrivacyFeatureDefaults.gpcEnabled
    @AppStorage("privacy_cookie_banner_enabled")
    private var cookieBannerEnabled = PrivacyFeatureDefaults.cookieBannerHandling
    @ObservedObject private var adBlockSettings = AdBlockSettingsService.shared
    @ObservedObject private var manualAdRules = ManualAdBlockService.shared
    @ObservedObject private var privacyService = PrivacyProtectionService.shared
    @ObservedObject private var webAppearance = WebAppearanceService.shared

    // MARK: - Make View

    // Pre-compiled ad block rules (call preWarm() at app launch)
    private static var cachedAdBlockRules: [WKContentRuleList]?
    private static var cachedAdBlockAllowlistSignature: String?
    private static var compilingAdBlockAllowlistSignature: String?
    private static var installedContentRuleSignatures: [ObjectIdentifier: String] = [:]

    /// Call once at app launch to pre-compile ad blocking rules
    static func preWarm() {
        Task(priority: .utility) {
            _ = TrackerRadarService.shared
        }

        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "ad_block_enabled") as? Bool ?? true else {
            return
        }

        Task(priority: .utility) {
            let allowlist = AdBlockSettingsService.shared.allowlistedHosts
            let signature = allowlistSignature(for: allowlist)
            guard compilingAdBlockAllowlistSignature != signature else { return }
            compilingAdBlockAllowlistSignature = signature
            cachedAdBlockAllowlistSignature = signature
            cachedAdBlockRules = nil
            let rules = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
            // A newer allowlist may have started compiling while this task waited.
            if cachedAdBlockAllowlistSignature == signature {
                cachedAdBlockRules = rules
            }
            if compilingAdBlockAllowlistSignature == signature {
                compilingAdBlockAllowlistSignature = nil
            }
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        if let existingWebView = viewModel.webView {
            installRuntimeIfNeeded(on: existingWebView.configuration.userContentController, context: context)
            configureWebView(existingWebView, context: context)
            if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
               !isIncognito, #available(iOS 18.4, *) {
                NativeWebExtensionRuntime.shared.register(existingWebView)
            }
            return existingWebView
        }

        let configuration: WKWebViewConfiguration
        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
           !isIncognito, #available(iOS 18.4, *),
           let extensionConfiguration = NativeWebExtensionRuntime.shared
            .webViewConfiguration(for: viewModel.currentURL) {
            configuration = extensionConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
               !isIncognito, #available(iOS 18.4, *) {
                NativeWebExtensionRuntime.shared.apply(to: configuration)
            }
        }

        // Custom user agent
        configuration.applicationNameForUserAgent = nil

        // Inline media playback
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = isIncognito ? .nonPersistent() : .default()

        // Content controller for JS message handler
        let contentController = WKUserContentController()
        installRuntimeIfNeeded(on: contentController, context: context)
        configuration.userContentController = contentController

        // Build the WKWebView
        let webView = AccessibleWebView(frame: .zero, configuration: configuration)
        configureWebView(webView, context: context)
        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
           !isIncognito, #available(iOS 18.4, *) {
            NativeWebExtensionRuntime.shared.register(webView)
        }

        // Hand the webView reference back to the ViewModel. This triggers any pending initial load.
        viewModel.webView = webView

        return webView
    }

    private func installRuntimeIfNeeded(on contentController: WKUserContentController, context: Context) {
        // Streaming transfers continue inside the retained page even when SwiftUI
        // temporarily dismantles this wrapper. Keep their page-world bridge alive
        // for the lifetime of that WKWebView instead of tying it to the wrapper.
        if !viewModel.isStreamingDownloadHandlerInstalled {
            contentController.addScriptMessageHandler(
                StreamingMediaDownloadService.shared,
                contentWorld: .page,
                name: StreamingMediaDownloadService.messageHandlerName
            )
            viewModel.isStreamingDownloadHandlerInstalled = true
        }

        // A rapid A → B → A switch can mount a new wrapper before the old
        // wrapper's transition finishes. Always bind bridges to the new owner.
        Self.removeRuntimeMessageHandlers(from: contentController)
        contentController.add(context.coordinator, name: "souloAdBlocker")
        contentController.add(context.coordinator, name: "souloPrivacy")
        contentController.add(context.coordinator, contentWorld: .defaultClient, name: "souloContextResource")
        contentController.add(context.coordinator, contentWorld: .defaultClient, name: "souloPageReady")
        contentController.add(context.coordinator, contentWorld: .defaultClient, name: "souloWebLink")
        contentController.add(context.coordinator, contentWorld: BrowserAutomaticNavigationPolicy.world, name: BrowserAutomaticNavigationPolicy.handler)
        contentController.add(context.coordinator, contentWorld: WebVideoOrientationRuntime.world, name: WebVideoOrientationRuntime.handler)
        contentController.add(context.coordinator, contentWorld: ManualAdBlockRuntime.world, name: ManualAdBlockRuntime.handler)
        if !isIncognito {
            contentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "souloUserScriptXHR")
            contentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "souloUserScriptAPI")
        }
        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled {
            contentController.add(context.coordinator, name: "souloExtensionInstaller")
        }
        contentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "souloDownload")
        viewModel.isWebViewRuntimeInstalled = true
        // Warm tab remounts only reconnect delegates. Keep scripts, their bridge
        // identity and compiled filters attached to the retained page.
        guard !viewModel.hasInstalledWebViewScripts else { return }
        viewModel.hasInstalledWebViewScripts = true
        viewModel.mediaSession.install(on: contentController)
        contentController.addUserScript(WKUserScript(source: WebViewScripts.pageContentReady,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        contentController.addUserScript(WKUserScript(source: WebViewScripts.bingAppPromptSuppression,
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        contentController.addUserScript(WKUserScript(source: WebViewScripts.internalWebLinkNavigation,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))

        contentController.addUserScript(WKUserScript(source: WebViewScripts.textSelection,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        contentController.addUserScript(WKUserScript(source: BrowserAutomaticNavigationPolicy.script,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: BrowserAutomaticNavigationPolicy.world))
        contentController.addUserScript(WKUserScript(
            source: WebVideoOrientationRuntime.script(), injectionTime: .atDocumentEnd,
            forMainFrameOnly: false, in: WebVideoOrientationRuntime.world
        ))
        contentController.addUserScript(WKUserScript(
            source: ManualAdBlockRuntime.configuredScript(enabled: adBlockEnabled,
                allowlistedHosts: adBlockSettings.allowlistedHosts, rules: manualAdRules.rules),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: ManualAdBlockRuntime.world
        ))
        if !isIncognito {
            for script in BrowserExtensionService.shared.userScripts where script.isEnabled {
                let injectionTime: WKUserScriptInjectionTime = script.injectionTime == .documentStart
                    ? .atDocumentStart
                    : .atDocumentEnd
                contentController.addUserScript(
                    WKUserScript(
                        source: UserScriptRuntime.wrappedSource(
                            for: script,
                            bridgeToken: context.coordinator.userScriptBridgeToken
                        ),
                        injectionTime: injectionTime,
                        forMainFrameOnly: true
                    )
                )
            }
        }
        contentController.addUserScript(
            WKUserScript(
                source: WebViewScripts.applyWebAppearance(
                    warmColorShift: webAppearance.warmColorShift,
                    forceDark: webAppearance.forceDarkPages,
                    reduceMotion: webAppearance.reducePageMotion,
                    underlineLinks: webAppearance.underlineLinks
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled {
            contentController.addUserScript(
                WKUserScript(
                    source: WebViewScripts.extensionInstallBridge(
                        title: LanguageManager.shared.localizedString("extension_page_banner_title"),
                        message: LanguageManager.shared.localizedString("extension_page_banner_desc"),
                        installButton: LanguageManager.shared.localizedString("install"),
                        installingButton: LanguageManager.shared.localizedString("extension_installing_short"),
                        logoDataURL: WebExtensionInstallBrandAssets.logoDataURL
                    ),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        contentController.addUserScript(
            WKUserScript(
                source: WebViewScripts.downloadBridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        contentController.addUserScript(
            WKUserScript(
                source: WebViewScripts.contextMenuResourceTracking,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .defaultClient
            )
        )

        contentController.addUserScript(
            WKUserScript(
                source: WebViewScripts.mediaResourceTracking,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        contentController.addUserScript(
            WKUserScript(
                source: WebViewScripts.accessibilityEnhancements,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        contentController.addUserScript(
            WKUserScript(
                source: WebViewScripts.privacyProtection(
                    gpcEnabled: gpcEnabled,
                    cookieBannerHandling: cookieBannerEnabled,
                    disabledHosts: WebCompatibilityService.protectionBypassHosts(
                        adding: privacyService.protectionDisabledHosts
                    )
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        // Long-press context menus are handled natively via WKUIDelegate contextMenuConfigurationForElement.

        // Ad blocking: inject CSS/JS to hide ad elements.
        let protectionBypassHosts = WebCompatibilityService.protectionBypassHosts(
            adding: adBlockSettings.allowlistedHosts
        )
        let shouldBypassWebProtection = WebCompatibilityService.shouldBypassWebProtection(
            for: viewModel.currentURL,
            fallbackHost: viewModel.currentURL?.host
        )
        let hostIsAllowlisted = shouldBypassWebProtection
            || adBlockSettings.isAllowlisted(viewModel.currentURL?.host)
        if adBlockEnabled && !hostIsAllowlisted {
            let adScript = WKUserScript(
                source: AdBlockService.adHidingScript(
                    cosmetic: true,
                    allowlistedHosts: protectionBypassHosts
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            contentController.addUserScript(adScript)
        }

        // Apply pre-compiled content rules before the first navigation whenever possible.
        if adBlockEnabled && !hostIsAllowlisted, let cached = Self.cachedAdBlockRules {
            cached.forEach { contentController.add($0) }
        }

        viewModel.isWebViewRuntimeInstalled = true
    }

    private func configureWebView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateManualAdTap(on: webView)
        context.coordinator.installImageLongPress(on: webView)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // The native navigation policy applies the live user preference to pop-ups.
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            webView.obscuredContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: obscuredBottomInset, right: 0)
            webView.scrollView.bottomEdgeEffect.isHidden = obscuredBottomInset > 0
        }
        webView.backgroundColor = UIColor.systemBackground
        webView.scrollView.backgroundColor = UIColor.systemBackground
        webView.isOpaque = true
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = false
        webView.scrollView.isAccessibilityElement = false
        webView.scrollView.accessibilityElementsHidden = false
        if let accessibleWebView = webView as? AccessibleWebView {
            accessibleWebView.onAccessibilityPlatformPage = onAccessibilityPlatformPage
        }

        // Apply per-tab UA/content-mode preferences before each navigation or restore.
        viewModel.applyWebPreferences(to: webView)
        // Offscreen navigation can replace the document without a coordinator
        // receiving didCommit/didFinish. Recheck once on mount; the page script
        // still skips DOM work when its own configuration is unchanged.
        webAppearance.apply(to: webView, force: true)

        if webView.url != nil, !viewModel.hasVisibleContent {
            webView.evaluateJavaScript("window.__souloPageHasVisibleContent === true", in: nil, in: .defaultClient) { [weak webView, weak model = viewModel] result in
                guard let webView, let model, model.webView === webView,
                      case .success(let value) = result, value as? Bool == true else { return }
                model.markPageContentVisible()
            }
        }

        // KVO observations
        context.coordinator.observe(webView: webView, viewModel: viewModel)

        // Pull-to-refresh
        let refreshControl = BrowserRefreshControl()
        refreshControl.addTarget(context.coordinator, action: #selector(Coordinator.handleRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl

        // Scroll direction detection
        webView.scrollView.delegate = context.coordinator
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if #available(iOS 26.0, *) {
            uiView.obscuredContentInsets = UIEdgeInsets(top: 0, left: 0, bottom: obscuredBottomInset, right: 0)
            uiView.scrollView.bottomEdgeEffect.isHidden = obscuredBottomInset > 0
        }
        context.coordinator.updateManualAdTap(on: uiView)
        context.coordinator.synchronizeManualAdRules(on: uiView)
        // URL loading is driven imperatively via viewModel.loadURL(_:)
        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
           !isIncognito, #available(iOS 18.4, *) {
            NativeWebExtensionRuntime.shared.activate(uiView)
        }
        let host = uiView.url?.host ?? viewModel.currentURL?.host
        if let accessibleWebView = uiView as? AccessibleWebView {
            accessibleWebView.onAccessibilityPlatformPage = onAccessibilityPlatformPage
        }
        webAppearance.apply(to: uiView)
        let shouldBypassWebProtection = WebCompatibilityService.shouldBypassWebProtection(
            for: uiView.url ?? viewModel.currentURL,
            fallbackHost: host
        )
        let adBlockAllowlist = WebCompatibilityService.protectionBypassHosts(
            adding: adBlockSettings.allowlistedHosts
        )
        context.coordinator.applyAdHidingIfNeeded(
            on: uiView,
            enabled: adBlockEnabled && !shouldBypassWebProtection,
            cosmetic: true,
            allowlistedHosts: adBlockAllowlist,
            host: host
        )
        if adBlockEnabled && !shouldBypassWebProtection {
            Self.ensureCurrentContentRules(on: uiView, allowlist: adBlockAllowlist, model: viewModel)
        } else {
            uiView.configuration.userContentController.removeAllContentRuleLists()
            Self.installedContentRuleSignatures.removeValue(forKey: ObjectIdentifier(uiView))
        }
    }

    private static func ensureCurrentContentRules(on webView: WKWebView, allowlist: [String], model: WebViewModel) {
        let signature = allowlistSignature(for: allowlist)
        let webViewID = ObjectIdentifier(webView)
        if signature == cachedAdBlockAllowlistSignature, let cachedAdBlockRules {
            guard installedContentRuleSignatures[webViewID] != signature else { return }
            applyContentRules(cachedAdBlockRules, on: webView, allowlist: allowlist)
            return
        }
        guard compilingAdBlockAllowlistSignature != signature else { return }
        cachedAdBlockAllowlistSignature = signature
        cachedAdBlockRules = nil
        compilingAdBlockAllowlistSignature = signature
        Task { [weak webView, weak model] in
            let ruleList = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
            if compilingAdBlockAllowlistSignature == signature {
                compilingAdBlockAllowlistSignature = nil
            }
            guard cachedAdBlockAllowlistSignature == signature else { return }
            cachedAdBlockRules = ruleList
            // Do not restore rules into a closed or suspended tab. A remounted
            // instance of the same live WebView can use the current rules.
            guard let webView, let model, model.isWebViewRuntimeInstalled,
                  model.webView === webView else { return }
            applyContentRules(ruleList, on: webView, allowlist: allowlist)
        }
    }

    /// Recheck current preferences when asynchronous compilation completes.
    static func applyContentRules(_ rules: WKContentRuleList?, on webView: WKWebView, allowlist: [String]) {
        applyContentRules(rules.map { [$0] }, on: webView, allowlist: allowlist)
    }

    static func applyContentRules(_ rules: [WKContentRuleList]?, on webView: WKWebView, allowlist: [String]) {
        let enabled = (UserDefaults.standard.object(forKey: "ad_block_enabled") as? Bool ?? true)
            && !WebCompatibilityService.shouldBypassWebProtection(for: webView.url)
            && !AdBlockSettingsService.isHostAllowlisted(webView.url?.host, allowlistedHosts: allowlist)
        // Preserve working rules on update failure, but always honor disabling.
        if enabled && rules == nil { return }
        let id = ObjectIdentifier(webView)
        webView.configuration.userContentController.removeAllContentRuleLists()
        installedContentRuleSignatures.removeValue(forKey: id)
        guard enabled, let rules else { return }
        rules.forEach { webView.configuration.userContentController.add($0) }
        installedContentRuleSignatures[id] = allowlistSignature(for: allowlist)
    }

    private static func allowlistSignature(for allowlist: [String]) -> String {
        let hosts = Array(Set(allowlist.map { AdBlockSettingsService.normalizedHost($0) }.filter { !$0.isEmpty })).sorted().joined(separator: ",")
        return "\(hosts)|rules:\(AdBlockSubscriptionService.rulesSignature())|builtIn:\(BuiltInAdRuleStore.signature())"
    }

    static func reloadWithCurrentAdRules(_ model: WebViewModel) {
        guard let webView = model.webView else { return }
        let allowlist = AdBlockSettingsService.shared.allowlistedHosts
        let signature = allowlistSignature(for: allowlist)
        Task { @MainActor [weak webView, weak model] in
            let rules = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
            guard let webView, let model, model.webView === webView,
                  signature == allowlistSignature(for: AdBlockSettingsService.shared.allowlistedHosts) else { return }
            cachedAdBlockAllowlistSignature = signature
            cachedAdBlockRules = rules
            applyContentRules(rules, on: webView, allowlist: allowlist)
            let controller = webView.configuration.userContentController
            let others = controller.userScripts.filter { !$0.source.contains("window.__souloAdBlockConfig") }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            let enabled = UserDefaults.standard.object(forKey: "ad_block_enabled") as? Bool ?? true
            controller.addUserScript(WKUserScript(source: AdBlockService.adHidingScript(cosmetic: enabled, allowlistedHosts: allowlist),
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            webView.reloadFromOrigin()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    static func forgetContentRules(on webView: WKWebView?) {
        if let webView { installedContentRuleSignatures.removeValue(forKey: ObjectIdentifier(webView)) }
    }

    // MARK: - Cleanup

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // A SwiftUI tab switch dismantles this wrapper even though TabManager keeps the
        // WKWebView alive. Keep the native extension tab registered until the browser tab
        // is actually closed or suspended so extensions can still enumerate all tabs.
        coordinator.invalidateObservations()
        coordinator.removeManualAdTap()
        coordinator.removeImageLongPress()
        guard uiView.navigationDelegate === coordinator else { return }
        removeRuntimeMessageHandlers(from: uiView.configuration.userContentController)
        coordinator.dismissEmbeddedPopups(in: uiView)
        coordinator.cancelManualAdPicker()
        coordinator.markRuntimeDismantled()
    }

    private static func removeRuntimeMessageHandlers(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: "souloPageReady", contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: "souloContextResource", contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: "souloWebLink", contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(
            forName: BrowserAutomaticNavigationPolicy.handler, contentWorld: BrowserAutomaticNavigationPolicy.world)
        controller.removeScriptMessageHandler(forName: "souloAdBlocker")
        controller.removeScriptMessageHandler(forName: WebVideoOrientationRuntime.handler, contentWorld: WebVideoOrientationRuntime.world)
        controller.removeScriptMessageHandler(forName: ManualAdBlockRuntime.handler, contentWorld: ManualAdBlockRuntime.world)
        controller.removeScriptMessageHandler(forName: "souloPrivacy")
        controller.removeScriptMessageHandler(forName: "souloExtensionInstaller")
        controller.removeScriptMessageHandler(forName: "souloDownload", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "souloUserScriptXHR", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "souloUserScriptAPI", contentWorld: .page)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, UIGestureRecognizerDelegate {
        private var imageLongPress: UILongPressGestureRecognizer?
        private var contextResource: (resource: WebContextResource?, frame: WKFrameInfo, time: TimeInterval, linkURL: URL?)?

        private struct PageDownloadTransfer {
            let itemID: UUID
            let fileURL: URL
            let fileName: String
            let fileHandle: FileHandle
            var nextChunkIndex: Int
            var isPaused = false
            var pendingChunkReply: ((Any?, String?) -> Void)?
        }

        private weak var manualAdTapRecognizer: UITapGestureRecognizer?
        private let videoFullscreenOrientation = WebVideoFullscreenOrientation()
        private var navigationGesture: (webView: ObjectIdentifier, frameURL: URL, time: TimeInterval)?
        private var provisionalNavigation: WKNavigation?
        private var lastContentOffset: CGFloat = 0
        private var lastReportedScrollingUp: Bool?
        private var isUserZooming = false
        private var accumulatedScrollDelta: CGFloat = 0

        private let viewModel: WebViewModel
        var userScriptBridgeToken: String { viewModel.userScriptBridgeToken }
        private var observations: [NSKeyValueObservation] = []
        private var downloadIDs: [ObjectIdentifier: UUID] = [:]
        private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
        private var activeDownloadNames: [ObjectIdentifier: String] = [:]
        private var downloadProgressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
        private var pageDownloadTransfers: [String: PageDownloadTransfer] = [:]
        private var downloadCancelObserver: NSObjectProtocol?
        private var individualDownloadCancelObserver: NSObjectProtocol?
        private var downloadPauseObserver: NSObjectProtocol?
        private var downloadResumeObserver: NSObjectProtocol?
        private var lastAdHidingSignature: String {
            get { viewModel.lastAdHidingSignature }
            set { viewModel.lastAdHidingSignature = newValue }
        }
        private var lastManualAdSignature: String {
            get { viewModel.lastManualAdSignature }
            set { viewModel.lastManualAdSignature = newValue }
        }
        private var httpsUpgradeFallbacks: [String: URL] = [:]
        private var oneShotHTTPFallbacks = Set<String>()
        private var privacyHeaderBypassURLs = Set<String>()
        private var blankPageRecoveryAttempts: [String: Int] = [:]
        private var terminatedProcessRecoveryURLs = Set<String>()
        private var navigationGeneration = UUID()
        init(viewModel: WebViewModel) {
            self.viewModel = viewModel
            super.init()
            downloadCancelObserver = NotificationCenter.default.addObserver(
                forName: .cancelActiveDownloads,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelActiveDownloads()
            }
            individualDownloadCancelObserver = NotificationCenter.default.addObserver(
                forName: .cancelBrowserDownload,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let id = notification.userInfo?["id"] as? UUID else { return }
                self?.cancelDownload(id: id)
            }
            downloadPauseObserver = NotificationCenter.default.addObserver(
                forName: .pauseBrowserDownload,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let id = notification.userInfo?["id"] as? UUID else { return }
                self?.pauseDownload(id: id)
            }
            downloadResumeObserver = NotificationCenter.default.addObserver(
                forName: .resumeBrowserDownload,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let id = notification.userInfo?["id"] as? UUID else { return }
                self?.resumeDownload(id: id)
            }
        }

        func updateManualAdTap(on webView: WKWebView) {
            if manualAdTapRecognizer?.view !== webView {
                removeManualAdTap()
                let tap = UITapGestureRecognizer(target: self, action: #selector(markAdvertisementTapped(_:)))
                tap.name = "SouloManualAdSelection"
                tap.delegate = self
                tap.cancelsTouchesInView = true
                tap.delaysTouchesBegan = true
                webView.addGestureRecognizer(tap)
                manualAdTapRecognizer = tap
            }
            manualAdTapRecognizer?.isEnabled = viewModel.manualAdSelection != nil
        }

        func removeManualAdTap() {
            if let tap = manualAdTapRecognizer { tap.view?.removeGestureRecognizer(tap) }
            manualAdTapRecognizer = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === imageLongPress { return viewModel.manualAdSelection == nil }
            return viewModel.manualAdSelection != nil && !viewModel.manualAdBusy
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === imageLongPress else { return true }
            return contextResource?.resource?.kind == .image &&
                ProcessInfo.processInfo.systemUptime - (contextResource?.time ?? 0) < 2
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === imageLongPress || otherGestureRecognizer === imageLongPress
        }

        func installImageLongPress(on webView: WKWebView) {
            guard imageLongPress?.view !== webView else { return }
            removeImageLongPress()
            let press = UILongPressGestureRecognizer(target: self, action: #selector(imageLongPressed(_:)))
            press.minimumPressDuration = 0.5; press.allowableMovement = 10
            press.delegate = self; press.cancelsTouchesInView = true
            webView.addGestureRecognizer(press); imageLongPress = press
        }

        func removeImageLongPress() {
            if let press = imageLongPress { press.view?.removeGestureRecognizer(press) }
            imageLongPress = nil
        }

        @objc private func imageLongPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let webView = gesture.view as? WKWebView,
                  let contextResource, let resource = contextResource.resource,
                  resource.kind == .image, let host = topViewController(for: webView) else { return }
            let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            menu.addAction(UIAlertAction(title: ToolText.text("image_view_full"), style: .default) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.viewModel.imagePreview = WebImagePreviewRequest(url: resource.url, webView: webView, frame: contextResource.frame)
            })
            menu.addAction(UIAlertAction(title: LanguageManager.shared.localizedString("image_extract_text"), style: .default) { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.extractText(from: resource, webView: webView, frame: contextResource.frame)
            })
            if ["http", "https"].contains(resource.url.scheme ?? "") {
                menu.addAction(UIAlertAction(title: LanguageManager.shared.localizedString("save_to_photos"), style: .default) { [weak self, weak webView] _ in
                    guard let self, let webView else { return }
                    self.downloadContextResource(resource, webView: webView, saveToPhotos: true, pageURL: contextResource.frame.request.url)
                })
            }
            if let linkURL = contextResource.linkURL {
                menu.addAction(UIAlertAction(title: LanguageManager.shared.localizedString("tab_open_new"), style: .default) { _ in
                    NotificationCenter.default.post(name: .openInNewTab, object: nil, userInfo: ["url": linkURL])
                })
            }
            if ["http", "https"].contains(resource.url.scheme ?? "") {
                menu.addAction(UIAlertAction(title: LanguageManager.shared.localizedString("download"), style: .default) { [weak self, weak webView] _ in
                    guard let self, let webView else { return }
                    self.downloadContextResource(resource, webView: webView, saveToPhotos: false, pageURL: contextResource.frame.request.url)
                })
            }
            menu.addAction(UIAlertAction(title: LanguageManager.shared.localizedString("resource_copy_url"), style: .default) { _ in UIPasteboard.general.url = resource.url })
            menu.addAction(UIAlertAction(title: ToolText.text("cancel"), style: .cancel))
            menu.popoverPresentationController?.sourceView = webView
            menu.popoverPresentationController?.sourceRect = CGRect(origin: gesture.location(in: webView), size: CGSize(width: 1, height: 1))
            host.present(menu, animated: true)
        }

        @objc private func markAdvertisementTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let webView = gesture.view as? WKWebView else { return }
            let point = gesture.location(in: webView)
            Task { @MainActor [weak self] in await self?.viewModel.pickAdvertisement(at: point) }
        }

        func markRuntimeDismantled() {
            viewModel.isWebViewRuntimeInstalled = false
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }

            if message.name == "souloWebLink" {
                guard message.world.name == WKContentWorld.defaultClient.name,
                      let webView = message.webView, webView === viewModel.webView,
                      let raw = body["url"] as? String, let url = URL(string: raw),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                switch WebNavigationPolicyService.shared.decision(for: url) {
                case .allow:
                    DispatchQueue.main.async { [weak self, weak webView] in
                        guard let self, let webView, self.viewModel.webView === webView else { return }
                        self.viewModel.loadURL(url)
                    }
                case .external(let externalURL):
                    routeExternalURL(externalURL, userInitiated: true)
                case .cancel:
                    break
                }
                return
            }

            if message.name == "souloPageReady" {
                guard message.webView === viewModel.webView, message.frameInfo.isMainFrame,
                      message.world == .defaultClient, body["visible"] as? Bool == true else { return }
                viewModel.markPageContentVisible()
                return
            }

            if message.name == "souloContextResource" {
                guard message.webView === viewModel.webView, message.world == .defaultClient else { return }
                let link = (body["linkURL"] as? String).flatMap(URL.init(string:))
                contextResource = (WebContextResource(dictionary: body), message.frameInfo, ProcessInfo.processInfo.systemUptime,
                    ["http", "https"].contains(link?.scheme ?? "") ? link : nil)
                return
            }

            if message.name == BrowserAutomaticNavigationPolicy.handler {
                guard message.world.name == BrowserAutomaticNavigationPolicy.world.name,
                      let webView = message.webView, let parent = viewModel.webView,
                      webView === parent || webView.isDescendant(of: parent),
                      let url = message.frameInfo.request.url,
                      body["url"] as? String == url.absoluteString else { return }
                navigationGesture = (ObjectIdentifier(webView), url, ProcessInfo.processInfo.systemUptime)
                return
            }

            if message.name == WebVideoOrientationRuntime.handler {
                guard message.webView === viewModel.webView,
                      message.world.name == WebVideoOrientationRuntime.world.name,
                      let action = body["action"] as? String,
                      let token = body["token"] as? String, token.count <= 80 else { return }
                switch action {
                case "speed":
                    guard let webView = message.webView, let host = topViewController(for: webView) else { return }
                    let currentRate = body["rate"] as? Double ?? 1
                    let title = ToolText.text("web_media_speed") + " · " + String(format: "%g×", currentRate.isFinite ? currentRate : 1)
                    let menu = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
                    for rate in [0.5, 1.0, 1.5, 2.0, 4.0, 8.0, 16.0] {
                        let title = String(format: "%g×", rate)
                        menu.addAction(UIAlertAction(title: title, style: .default) { [weak self, weak webView] _ in
                            guard let webView else { return }
                            Task { @MainActor in
                                let applied = try? await webView.callAsyncJavaScript("return window.__souloVideoOrientation?.setRate(token, rate);",
                                    arguments: ["token": token, "rate": rate], in: message.frameInfo, contentWorld: WebVideoOrientationRuntime.world)
                                if applied as? Bool != true { self?.viewModel.videoOrientationError = ToolText.text("media_rate_unavailable") }
                            }
                        })
                    }
                    menu.addAction(UIAlertAction(title: ToolText.text("cancel"), style: .cancel))
                    menu.popoverPresentationController?.sourceView = webView
                    menu.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
                    host.present(menu, animated: true)
                case "download":
                    guard let source = body["url"] as? String, let url = URL(string: source),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        viewModel.showMediaDownloads = true
                        return
                    }
                    guard viewModel.beginMediaDownload(url: url, name: viewModel.pageTitle) else { return }
                    let delivery: WebMediaResource.Delivery = url.pathExtension.lowercased() == "m3u8" ? .hls : .direct
                    let resource = WebMediaResource(kind: .video, url: url, title: viewModel.pageTitle, posterURL: nil, delivery: delivery)
                    Task { @MainActor [self, webView = message.webView] in
                        do {
                            let file = try await WebResourceDownloadService.shared.download(resource,
                                pageURL: message.frameInfo.request.url ?? webView?.url, webView: webView)
                            self.viewModel.finishMediaDownload(url: url)
                            self.presentDownloadedFile(file, sourceURL: url)
                        } catch {
                            self.viewModel.finishMediaDownload(url: url)
                            NotificationCenter.default.post(name: .browserDownloadFailed, object: self.viewModel)
                        }
                    }
                case "prepare":
                    if let scene = message.webView?.window?.windowScene {
                        videoFullscreenOrientation.prepare(
                            token: token,
                            scene: scene,
                            prefersLandscape: body["landscape"] as? Bool ?? true
                        )
                    }
                case "begin":
                    videoFullscreenOrientation.begin(token: token) { [weak self] error in
                        self?.viewModel.videoOrientationError = error.localizedDescription
                    }
                case "end", "failed":
                    videoFullscreenOrientation.end(token: token)
                    if action == "failed" { viewModel.videoOrientationError = ToolText.text("media_fullscreen_unavailable") }
                default: break
                }
                return
            }

            if message.name == ManualAdBlockRuntime.handler {
                guard message.frameInfo.isMainFrame, message.webView === viewModel.webView,
                      message.world.name == ManualAdBlockRuntime.world.name else { return }
                viewModel.receiveManualAdSelection(body)
                return
            }

            if message.name == "souloExtensionInstaller" {
                handleExtensionInstallRequest(body, webView: message.webView)
                return
            }

            if message.name == "souloAdBlocker" {
                let count = body["hiddenCount"] as? Int ?? 0
                let host = (body["host"] as? String) ?? viewModel.currentURL?.host
                let trackerHosts = body["trackerHosts"] as? [String] ?? []
                Task { @MainActor in
                    AdBlockSettingsService.shared.recordHiddenElementCount(count, for: host)
                    PrivacyProtectionService.shared.recordHiddenElementCount(count, for: host)
                    PrivacyProtectionService.shared.recordTrackerHosts(trackerHosts, for: host)
                }
                return
            }

            guard message.name == "souloPrivacy" else { return }
            let type = body["type"] as? String ?? ""
            let host = (body["host"] as? String) ?? viewModel.currentURL?.host
            Task { @MainActor in
                switch type {
                case "trackerScan", "resourceObserved":
                    let observations = self.resourceObservations(from: body["observations"])
                    PrivacyProtectionService.shared.recordResourceObservations(observations, for: viewModel.currentURL)
                    PrivacyProtectionService.shared.recordTrackerHosts(body["trackerHosts"] as? [String] ?? [], for: host)
                case "cookieBanner":
                    PrivacyProtectionService.shared.recordCookieBannerActions(body["actionCount"] as? Int ?? 0, for: host)
                default:
                    break
                }
            }
        }

        private func handleExtensionInstallRequest(_ body: [String: Any], webView: WKWebView?) {
            let value = (body["pageURL"] as? String) ?? webView?.url?.absoluteString
            guard let value,
                  let url = URL(string: value),
                  WebExtensionStoreLinkResolver.canInstall(from: url) else {
                return
            }
            NotificationCenter.default.post(
                name: .webExtensionStoreInstallRequested,
                object: viewModel,
                userInfo: ["url": value]
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            if ["souloUserScriptXHR", "souloUserScriptAPI"].contains(message.name),
               let body = message.body as? [String: Any],
               let script = authorizedUserScript(for: body, pageURL: message.webView?.url) {
                if message.name == "souloUserScriptAPI" {
                    Task { @MainActor in
                        await self.handleUserScriptAPI(
                            body,
                            script: script,
                            webView: message.webView,
                            replyHandler: replyHandler
                        )
                    }
                    return
                }
                guard script.allowsXMLHTTPRequests else {
                    replyHandler(nil, "Unauthorized UserScript request")
                    return
                }
                Task {
                    do {
                        replyHandler(
                            try await UserScriptHTTPBridge.response(
                                for: body,
                                script: script,
                                pageURL: message.webView?.url
                            ),
                            nil
                        )
                    } catch {
                        replyHandler(nil, error.localizedDescription)
                    }
                }
                return
            }
            if ["souloUserScriptXHR", "souloUserScriptAPI"].contains(message.name) {
                replyHandler(nil, "Unauthorized UserScript request")
                return
            }
            guard message.name == "souloDownload",
                  let body = message.body as? [String: Any] else {
                replyHandler(nil, "Invalid download message")
                return
            }
            Task { @MainActor [weak self] in
                self?.handlePageDownloadMessage(body, replyHandler: replyHandler)
            }
        }

        @MainActor
        private func authorizedUserScript(
            for body: [String: Any],
            pageURL: URL?
        ) -> UserScriptRecord? {
            guard body["__souloToken"] as? String == userScriptBridgeToken,
                  let rawScriptID = body["__souloScriptID"] as? String,
                  let scriptID = UUID(uuidString: rawScriptID),
                  let script = BrowserExtensionService.shared.userScript(id: scriptID),
                  script.isEnabled,
                  let pageURL,
                  UserScriptURLMatcher.matches(url: pageURL, patterns: script.matchPatterns),
                  !UserScriptURLMatcher.matches(url: pageURL, patterns: script.excludePatterns ?? []) else {
                return nil
            }
            return script
        }

        @MainActor
        private func handleUserScriptAPI(
            _ body: [String: Any],
            script: UserScriptRecord,
            webView: WKWebView?,
            replyHandler: @escaping (Any?, String?) -> Void
        ) async {
            do {
                switch body["action"] as? String {
                case "setValue" where script.hasGrant("GM_setValue", "GM.setValue"):
                    guard let key = body["key"] as? String,
                          let value = body["value"] as? String else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    try BrowserExtensionService.shared.setStoredValue(value, forKey: key, scriptID: script.id)
                case "deleteValue" where script.hasGrant("GM_deleteValue", "GM.deleteValue"):
                    guard let key = body["key"] as? String else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    BrowserExtensionService.shared.deleteStoredValue(forKey: key, scriptID: script.id)
                case "setValues" where script.hasGrant("GM_setValues", "GM.setValues"):
                    guard let values = body["values"] as? [String: String] else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    try BrowserExtensionService.shared.setStoredValues(values, scriptID: script.id)
                case "deleteValues" where script.hasGrant("GM_deleteValues", "GM.deleteValues"):
                    guard let keys = body["keys"] as? [String] else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    BrowserExtensionService.shared.deleteStoredValues(forKeys: keys, scriptID: script.id)
                case "setClipboard" where script.hasGrant("GM_setClipboard", "GM.setClipboard"):
                    guard let value = body["value"] as? String else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    UIPasteboard.general.string = value
                case "registerMenuCommand" where script.hasGrant(
                    "GM_registerMenuCommand", "GM.registerMenuCommand"
                ):
                    guard let id = (body["id"] as? String)?.prefix(180),
                          let title = (body["title"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .prefix(120),
                          !id.isEmpty, !title.isEmpty else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    viewModel.registerUserScriptMenuCommand(
                        id: String(id),
                        scriptID: script.id,
                        scriptName: script.name,
                        title: String(title)
                    )
                case "unregisterMenuCommand" where script.hasGrant(
                    "GM_unregisterMenuCommand", "GM.unregisterMenuCommand"
                ):
                    guard let id = body["id"] as? String else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    viewModel.unregisterUserScriptMenuCommand(id: id, scriptID: script.id)
                case "openInTab" where script.hasGrant("GM_openInTab", "GM.openInTab"):
                    guard let url = resolvedUserScriptURL(body["url"], relativeTo: webView?.url),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        throw WebResourceDownloadError.invalidResponse
                    }
                    NotificationCenter.default.post(
                        name: .openInNewTab,
                        object: nil,
                        userInfo: [
                            "url": url,
                            "switchTo": body["active"] as? Bool ?? true,
                            "userScriptTabID": body["id"] as? String ?? ""
                        ]
                    )
                case "closeTab" where script.hasGrant("GM_openInTab", "GM.openInTab"):
                    guard let id = body["id"] as? String, !id.isEmpty else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    NotificationCenter.default.post(
                        name: .closeUserScriptTab,
                        object: nil,
                        userInfo: ["userScriptTabID": id]
                    )
                case "closeCurrentTab" where script.hasGrant("GM_closeTab", "GM.closeTab"):
                    NotificationCenter.default.post(
                        name: .closeUserScriptCurrentTab,
                        object: viewModel
                    )
                case "focusCurrentTab" where script.hasGrant("GM_focusTab", "GM.focusTab"):
                    NotificationCenter.default.post(
                        name: .focusUserScriptCurrentTab,
                        object: viewModel
                    )
                case "download" where script.hasGrant("GM_download", "GM.download"):
                    guard let url = resolvedUserScriptURL(body["url"], relativeTo: webView?.url),
                          UserScriptHTTPBridge.isAllowedTarget(
                            url,
                            script: script,
                            pageURL: webView?.url
                          ) else {
                        throw WebResourceDownloadError.invalidResponse
                    }
                    let rawPreferredName = (body["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let preferredName = rawPreferredName.isEmpty ? nil : rawPreferredName
                    let fileURL = try await WebResourceDownloadService.shared.download(
                        url,
                        preferredFilename: preferredName,
                        pageURL: webView?.url,
                        webView: webView,
                        fallbackBaseName: script.name
                    )
                    replyHandler(["success": true, "name": fileURL.lastPathComponent], nil)
                    return
                case "getResource" where script.hasGrant(
                    "GM_getResourceText", "GM.getResourceText",
                    "GM_getResourceURL", "GM.getResourceUrl", "GM.getResourceURL"
                ):
                    guard let name = body["name"] as? String,
                          let resourceURL = script.resources?[name] else {
                        throw WebResourceDownloadError.invalidResponse
                    }
                    let response = try await UserScriptHTTPBridge.response(
                        for: [
                            "url": resourceURL,
                            "method": "GET",
                            "timeout": 30_000,
                            "responseType": "arraybuffer"
                        ],
                        script: script,
                        pageURL: webView?.url
                    )
                    replyHandler(response, nil)
                    return
                case "saveTab" where script.hasGrant("GM_saveTab", "GM.saveTab"):
                    guard let value = body["value"] as? String else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    try UserScriptTabStore.shared.save(
                        value,
                        scriptID: script.id,
                        tabID: userScriptTabIdentifier
                    )
                case "getTab" where script.hasGrant("GM_getTab", "GM.getTab"):
                    replyHandler(
                        UserScriptTabStore.shared.value(
                            scriptID: script.id,
                            tabID: userScriptTabIdentifier
                        ),
                        nil
                    )
                    return
                case "getTabs" where script.hasGrant("GM_getTabs", "GM.getTabs"):
                    replyHandler(UserScriptTabStore.shared.allValues(scriptID: script.id), nil)
                    return
                case "cookieList" where script.hasGrant("GM_cookie", "GM.cookie"):
                    guard let webView else { throw WebResourceDownloadError.invalidResponse }
                    let cookies = await allCookies(in: webView)
                    let details = body["details"] as? [String: Any] ?? [:]
                    replyHandler(
                        cookies
                            .filter { matchesCookie($0, details: details, pageURL: webView.url) }
                            .map(cookieDictionary),
                        nil
                    )
                    return
                case "cookieSet" where script.hasGrant("GM_cookie", "GM.cookie"):
                    guard let webView,
                          let details = body["details"] as? [String: Any],
                          let cookie = makeCookie(from: details, pageURL: webView.url) else {
                        throw BrowserExtensionError.invalidStorageValue
                    }
                    await setCookie(cookie, in: webView)
                case "cookieDelete" where script.hasGrant("GM_cookie", "GM.cookie"):
                    guard let webView else { throw WebResourceDownloadError.invalidResponse }
                    let details = body["details"] as? [String: Any] ?? [:]
                    for candidate in await allCookies(in: webView)
                    where matchesCookie(candidate, details: details, pageURL: webView.url) {
                        await deleteCookie(candidate, in: webView)
                    }
                default:
                    replyHandler(nil, "Unsupported or unauthorized UserScript API")
                    return
                }
                replyHandler(true, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }

        @MainActor
        private var userScriptTabIdentifier: String {
            String(describing: ObjectIdentifier(viewModel))
        }

        private func resolvedUserScriptURL(_ value: Any?, relativeTo baseURL: URL?) -> URL? {
            guard let rawValue = value as? String,
                  let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL else { return nil }
            return url
        }

        private func allCookies(in webView: WKWebView) async -> [HTTPCookie] {
            await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                    continuation.resume(returning: $0)
                }
            }
        }

        private func setCookie(_ cookie: HTTPCookie, in webView: WKWebView) async {
            await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }

        private func deleteCookie(_ cookie: HTTPCookie, in webView: WKWebView) async {
            await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }

        private func matchesCookie(
            _ cookie: HTTPCookie,
            details: [String: Any],
            pageURL: URL?
        ) -> Bool {
            guard let host = pageURL?.host?.lowercased() else { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
            guard host == domain || host.hasSuffix(".\(domain)") else { return false }
            if let name = details["name"] as? String, cookie.name != name { return false }
            if let path = details["path"] as? String, cookie.path != path { return false }
            if let requestedDomain = (details["domain"] as? String)?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")),
               domain != requestedDomain { return false }
            return true
        }

        private func makeCookie(from details: [String: Any], pageURL: URL?) -> HTTPCookie? {
            guard let pageURL,
                  let host = pageURL.host?.lowercased(),
                  let rawName = details["name"] as? String,
                  !rawName.isEmpty,
                  let value = details["value"] as? String else { return nil }
            let requestedDomain = ((details["domain"] as? String) ?? host)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host == requestedDomain || host.hasSuffix(".\(requestedDomain)") else { return nil }
            let rawPath = details["path"] as? String ?? ""
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: rawName,
                .value: value,
                .domain: requestedDomain,
                .path: rawPath.isEmpty ? "/" : rawPath
            ]
            if details["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            if let expiration = details["expirationDate"] as? Double {
                properties[.expires] = Date(timeIntervalSince1970: expiration)
            }
            return HTTPCookie(properties: properties)
        }

        private func cookieDictionary(_ cookie: HTTPCookie) -> [String: Any] {
            var result: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure,
                "session": cookie.isSessionOnly,
                "httpOnly": cookie.isHTTPOnly
            ]
            if let expiration = cookie.expiresDate {
                result["expirationDate"] = expiration.timeIntervalSince1970
            }
            return result
        }

        @MainActor
        private func handlePageDownloadMessage(
            _ body: [String: Any],
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let type = body["type"] as? String ?? ""
            guard let transferID = body["downloadID"] as? String,
                  !transferID.isEmpty else {
                replyHandler(nil, "Missing download identifier")
                return
            }
            let suggestedFilename = (body["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = suggestedFilename.flatMap { $0.isEmpty ? nil : $0 } ?? "Download"
            let manager = DownloadManagerService.shared

            switch type {
            case "started":
                if let existing = pageDownloadTransfers.removeValue(forKey: transferID) {
                    try? existing.fileHandle.close()
                    manager.markCanceled(id: existing.itemID)
                }
                let sourceURL = (body["sourceURL"] as? String).flatMap(URL.init(string:))
                let (item, fileURL) = manager.beginDownload(
                    suggestedFilename: filename,
                    sourceURL: sourceURL
                )
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    let error = CocoaError(.fileWriteUnknown)
                    manager.markFailed(id: item.id, error: error)
                    finishPageDownloadWithError()
                    replyHandler(nil, error.localizedDescription)
                    return
                }
                do {
                    let fileHandle = try FileHandle(forWritingTo: fileURL)
                    pageDownloadTransfers[transferID] = PageDownloadTransfer(
                        itemID: item.id,
                        fileURL: fileURL,
                        fileName: item.fileName,
                        fileHandle: fileHandle,
                        nextChunkIndex: 0,
                        isPaused: false,
                        pendingChunkReply: nil
                    )
                    refreshDownloadPresentation(preferredFilename: item.fileName)
                    replyHandler(["accepted": true], nil)
                } catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    manager.markFailed(id: item.id, error: error)
                    finishPageDownloadWithError()
                    replyHandler(nil, error.localizedDescription)
                }

            case "chunk":
                guard var transfer = pageDownloadTransfers[transferID],
                      let encodedChunk = body["base64"] as? String,
                      let chunk = Data(base64Encoded: encodedChunk),
                      let chunkIndex = numericMessageValue(body["index"]),
                      chunkIndex == transfer.nextChunkIndex else {
                    replyHandler(nil, "Invalid or out-of-order download chunk")
                    return
                }
                do {
                    try transfer.fileHandle.write(contentsOf: chunk)
                    transfer.nextChunkIndex += 1
                    if transfer.isPaused {
                        transfer.pendingChunkReply = replyHandler
                    }
                    pageDownloadTransfers[transferID] = transfer
                    if !transfer.isPaused {
                        replyHandler(["received": chunkIndex], nil)
                    }
                } catch {
                    pageDownloadTransfers.removeValue(forKey: transferID)
                    try? transfer.fileHandle.close()
                    try? FileManager.default.removeItem(at: transfer.fileURL)
                    manager.markFailed(id: transfer.itemID, error: error)
                    refreshDownloadPresentation()
                    finishPageDownloadWithError()
                    replyHandler(nil, error.localizedDescription)
                }

            case "finished":
                guard let transfer = pageDownloadTransfers.removeValue(forKey: transferID) else {
                    replyHandler(nil, "Download was canceled")
                    return
                }
                do {
                    try transfer.fileHandle.close()
                    manager.markFinished(id: transfer.itemID)
                    refreshDownloadPresentation()
                    replyHandler(["finished": true], nil)
                    let sourceURL = manager.downloads
                        .first(where: { $0.id == transfer.itemID })
                        .flatMap { URL(string: $0.sourceURLString) }
                    presentDownloadedFile(transfer.fileURL, sourceURL: sourceURL)
                } catch {
                    try? FileManager.default.removeItem(at: transfer.fileURL)
                    manager.markFailed(id: transfer.itemID, error: error)
                    refreshDownloadPresentation()
                    finishPageDownloadWithError()
                    replyHandler(nil, error.localizedDescription)
                }

            case "failed":
                let message = body["message"] as? String ?? ""
                if let transfer = pageDownloadTransfers.removeValue(forKey: transferID) {
                    try? transfer.fileHandle.close()
                    try? FileManager.default.removeItem(at: transfer.fileURL)
                    if message.localizedCaseInsensitiveContains("canceled") {
                        manager.markCanceled(id: transfer.itemID)
                    } else {
                        let error = NSError(
                            domain: "Soulo.PageDownload",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                        manager.markFailed(id: transfer.itemID, error: error)
                        finishPageDownloadWithError()
                    }
                }
                refreshDownloadPresentation()
                replyHandler(["failed": true], nil)

            default:
                replyHandler(nil, "Unknown download message")
            }
        }

        private func numericMessageValue(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }

        @MainActor
        private func refreshDownloadPresentation(preferredFilename: String? = nil) {
            let activeCount = activeDownloads.count + pageDownloadTransfers.count
            let fallbackFilename = pageDownloadTransfers.values.first?.fileName
                ?? activeDownloadNames.values.first
            viewModel.updateDownloadState(
                activeCount: activeCount,
                fileName: preferredFilename ?? fallbackFilename
            )
        }

        private func finishPageDownloadWithError() {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .browserDownloadFailed,
                    object: viewModel
                )
            }
        }

        private func resourceObservations(from value: Any?) -> [ResourceObservation] {
            guard let rawObservations = value as? [[String: Any]] else { return [] }
            return rawObservations.compactMap { raw in
                guard let urlString = raw["url"] as? String,
                      !urlString.isEmpty else {
                    return nil
                }
                return ResourceObservation(
                    urlString: urlString,
                    resourceType: raw["resourceType"] as? String ?? "raw",
                    pageURLString: raw["pageUrl"] as? String ?? viewModel.currentURL?.absoluteString ?? "",
                    potentiallyBlocked: raw["potentiallyBlocked"] as? Bool ?? false
                )
            }
        }

        // MARK: KVO

        func observe(webView: WKWebView, viewModel: WebViewModel) {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            observations = [
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in
                        guard wv.navigationDelegate === self,
                              self?.viewModel.webView === wv else { return }
                        self?.viewModel.updateProgress(wv.estimatedProgress)
                    }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in
                        guard wv.navigationDelegate === self,
                              self?.viewModel.webView === wv else { return }
                        self?.viewModel.updateLoading(wv.isLoading)
                    }
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in
                        guard wv.navigationDelegate === self,
                              self?.viewModel.webView === wv else { return }
                        self?.viewModel.updateCanGoBack(wv.canGoBack)
                    }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in
                        guard wv.navigationDelegate === self,
                              self?.viewModel.webView === wv else { return }
                        self?.viewModel.updateCanGoForward(wv.canGoForward)
                    }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in
                        guard wv.navigationDelegate === self,
                              self?.viewModel.webView === wv else { return }
                        self?.viewModel.updateTitle(wv.title)
                    }
                },
                webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                    Task { @MainActor in
                        guard let self, wv.navigationDelegate === self,
                              self.viewModel.webView === wv else { return }
                        let previousURL = self.viewModel.currentURL
                        self.viewModel.updateCurrentURL(wv.url)
                        if previousURL != wv.url, !wv.isLoading {
                            if self.viewModel.followLinkTranslation != nil,
                               let previousURL, let nextURL = wv.url,
                               previousURL.absoluteString.split(separator: "#", maxSplits: 1).first
                                != nextURL.absoluteString.split(separator: "#", maxSplits: 1).first {
                                self.viewModel.resetPageTranslationState()
                                self.viewModel.pageDidFinishLoading()
                            }
                            await self.viewModel.refreshPageTranslationState()
                        }
                    }
                }
            ]
        }

        func invalidateObservations() {
            videoFullscreenOrientation.end()
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            if let downloadCancelObserver {
                NotificationCenter.default.removeObserver(downloadCancelObserver)
                self.downloadCancelObserver = nil
            }
            if let individualDownloadCancelObserver {
                NotificationCenter.default.removeObserver(individualDownloadCancelObserver)
                self.individualDownloadCancelObserver = nil
            }
            if let downloadPauseObserver {
                NotificationCenter.default.removeObserver(downloadPauseObserver)
                self.downloadPauseObserver = nil
            }
            if let downloadResumeObserver {
                NotificationCenter.default.removeObserver(downloadResumeObserver)
                self.downloadResumeObserver = nil
            }
            downloadProgressObservations.values.forEach { $0.invalidate() }
            downloadProgressObservations.removeAll()
        }

        func applyAdHidingIfNeeded(
            on webView: WKWebView,
            enabled: Bool,
            cosmetic: Bool,
            allowlistedHosts: [String],
            host: String?
        ) {
            let signature = [
                host ?? "",
                enabled ? "1" : "0",
                cosmetic ? "1" : "0",
                allowlistedHosts.joined(separator: ","),
                AdBlockSettingsService.isHostAllowlisted(host) ? "1" : "0",
                BuiltInAdRuleStore.signature(),
                AdBlockSubscriptionService.rulesSignature()
            ].joined(separator: "|")
            guard signature != lastAdHidingSignature else { return }
            lastAdHidingSignature = signature

            guard enabled,
                  !AdBlockSettingsService.isHostAllowlisted(host),
                  cosmetic else {
                return
            }
            webView.evaluateJavaScript(
                AdBlockService.adHidingScript(cosmetic: cosmetic, allowlistedHosts: allowlistedHosts),
                completionHandler: nil
            )
        }

        func applyPrivacyProtectionIfNeeded(on webView: WKWebView) {
            let defaults = UserDefaults.standard
            webView.evaluateJavaScript(
                WebViewScripts.privacyProtection(
                    gpcEnabled: defaults.object(forKey: "privacy_gpc_enabled") as? Bool
                        ?? PrivacyFeatureDefaults.gpcEnabled,
                    cookieBannerHandling: defaults.object(forKey: "privacy_cookie_banner_enabled") as? Bool
                        ?? PrivacyFeatureDefaults.cookieBannerHandling,
                    disabledHosts: WebCompatibilityService.protectionBypassHosts(
                        adding: defaults.stringArray(forKey: "soulo_privacy_disabled_hosts") ?? []
                    )
                ),
                completionHandler: nil
            )
        }

        // MARK: WKNavigationDelegate

        func cancelManualAdPicker() { viewModel.cancelMarkingAdvertisement() }

        func synchronizeManualAdRules(on webView: WKWebView) {
            let enabled = UserDefaults.standard.object(forKey: "ad_block_enabled") as? Bool ?? true
            let service = ManualAdBlockService.shared
            let allowlist = AdBlockSettingsService.shared.allowlistedHosts
            let signature = "\(enabled)|\(service.revision)|\(allowlist.joined(separator: ","))|\(webView.url?.absoluteString ?? "")"
            guard signature != lastManualAdSignature else { return }
            lastManualAdSignature = signature
            if let selection = viewModel.manualAdSelection,
               selection.url != webView.url || !ManualAdBlockService.canUse(on: webView.url, enabled: enabled, allowlistedHosts: allowlist) {
                Task { @MainActor [weak self] in
                    guard let self, self.viewModel.manualAdSelection?.token == selection.token else { return }
                    self.viewModel.cancelMarkingAdvertisement()
                }
            }
            let source = ManualAdBlockRuntime.configuredScript(enabled: enabled, allowlistedHosts: allowlist, rules: service.rules)
            let controller = webView.configuration.userContentController
            // WebKit has no remove-one-user-script API. Preserve every unrelated
            // runtime and handler when updating the rules used by future loads.
            let others = controller.userScripts.filter { !$0.source.hasPrefix(ManualAdBlockRuntime.prefix) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: ManualAdBlockRuntime.world))
            webView.evaluateJavaScript(source, in: nil, in: ManualAdBlockRuntime.world, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            provisionalNavigation = navigation
            if webView === viewModel.webView {
                viewModel.beginPageNavigation()
                videoFullscreenOrientation.end()
                viewModel.cancelMarkingAdvertisement()
                dismissEmbeddedPopups(in: webView)
            }
            navigationGeneration = UUID()
            resetScrollChromeState()
            Task { @MainActor in
                viewModel.errorMessage = nil
                viewModel.clearUserScriptMenuCommands()
                viewModel.resetPageTranslationState()
            }
            lastAdHidingSignature = ""
            lastManualAdSignature = ""
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            provisionalNavigation = nil
            navigationGesture = nil
            if viewModel.manualAdSelection != nil { viewModel.cancelMarkingAdvertisement() }
            synchronizeManualAdRules(on: webView)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewModel.updateCurrentURL(webView.url)
                self.viewModel.applyPageZoom(to: webView)
            }
            applyCurrentAdHidingIfNeeded(on: webView)
            Task { @MainActor in
                WebAppearanceService.shared.apply(to: webView, force: true)
            }
            scheduleVideoViewportSynchronization(on: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewModel.updateLoading(false)
                self.viewModel.updateCurrentURL(webView.url)
                self.viewModel.updateTitle(webView.title)
                self.viewModel.pageDidFinishLoading()
                self.viewModel.applyPageZoom(to: webView)
                self.applyCurrentAdHidingIfNeeded(on: webView)
                self.applyPrivacyProtectionIfNeeded(on: webView)
                WebAppearanceService.shared.apply(to: webView, force: true)
                self.scheduleBlankPageRecovery(on: webView)
                // Capture snapshot for tab preview (slight delay for render)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.viewModel.takeSnapshot()
                }
                self.focusAccessibilityOnLoadedPage(webView)
                self.scheduleVideoViewportSynchronization(on: webView)
                await self.viewModel.refreshPageTranslationState()
            }
        }

        private func scheduleVideoViewportSynchronization(on webView: WKWebView) {
            guard WebCompatibilityService.isDouyinVideoSurface(webView.url) else { return }
            let generation = navigationGeneration
            let urlString = webView.url?.absoluteString
            for delay in [0.05, 0.25, 0.7, 1.4, 2.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self,
                          let webView,
                          self.navigationGeneration == generation,
                          webView.url?.absoluteString == urlString else { return }
                    self.viewModel.synchronizePageViewport()
                }
            }
        }

        @MainActor
        private func focusAccessibilityOnLoadedPage(_ webView: WKWebView) {
            guard UIAccessibility.isVoiceOverRunning else { return }
            let fallback = webView.url?.host ?? LanguageManager.shared.localizedString("accessibility_search_results")
            let pageName = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let announcement = AppAccessibility.formatted(
                "accessibility_page_loaded",
                pageName?.isEmpty == false ? pageName! : fallback
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak webView] in
                guard let webView, UIAccessibility.isVoiceOverRunning else { return }
                UIAccessibility.post(notification: .screenChanged, argument: webView)
                AppAccessibility.announce(announcement, after: 0.35)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            if provisionalNavigation === navigation { provisionalNavigation = nil }
            handleNavigationError(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            if provisionalNavigation === navigation { provisionalNavigation = nil }
            if retryHTTPFallbackIfNeeded(on: webView, error: error) {
                return
            }
            handleNavigationError(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            provisionalNavigation = nil
            guard let url = webView.url, isRecoverableWebPageURL(url) else { return }
            let key = url.absoluteString
            guard !terminatedProcessRecoveryURLs.contains(key) else {
                Task { @MainActor in
                    viewModel.setError(LanguageManager.shared.localizedString("load_error"))
                }
                return
            }

            terminatedProcessRecoveryURLs.insert(key)
            navigationGeneration = UUID()
            Task { @MainActor in
                viewModel.errorMessage = nil
                viewModel.updateLoading(true)
            }
            webView.reload()
        }

        private func handleNavigationError(_ error: Error) {
            guard !WebNavigationErrorClassifier.isExpectedInterruption(error) else { return }
            viewModel.webView?.scrollView.refreshControl?.endRefreshing()
            let nsError = error as NSError
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

        private func scheduleBlankPageRecovery(on webView: WKWebView) {
            guard let url = webView.url, isRecoverableWebPageURL(url) else { return }
            let urlString = url.absoluteString
            let generation = navigationGeneration

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.navigationGeneration == generation,
                      webView.url?.absoluteString == urlString,
                      !webView.isLoading else {
                    return
                }

                webView.evaluateJavaScript(WebViewScripts.blankPageProbe) { [weak self, weak webView] result, error in
                    guard let self,
                          let webView,
                          error == nil,
                          self.navigationGeneration == generation,
                          webView.url?.absoluteString == urlString,
                          !webView.isLoading else {
                        return
                    }

                    guard self.shouldRecoverBlankPage(from: result) else {
                        self.blankPageRecoveryAttempts.removeValue(forKey: urlString)
                        return
                    }

                    self.recoverBlankPage(on: webView, url: url, urlString: urlString)
                }
            }
        }

        private func recoverBlankPage(on webView: WKWebView, url: URL, urlString: String) {
            let attempt = blankPageRecoveryAttempts[urlString, default: 0]
            guard attempt < 2 else {
                Task { @MainActor in
                    viewModel.setError(LanguageManager.shared.localizedString("load_error"))
                }
                return
            }

            blankPageRecoveryAttempts[urlString] = attempt + 1
            navigationGeneration = UUID()
            Task { @MainActor in
                viewModel.errorMessage = nil
                viewModel.updateLoading(true)
            }

            if attempt == 0 {
                webView.reload()
            } else {
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            }
        }

        private func shouldRecoverBlankPage(from value: Any?) -> Bool {
            guard let probe = value as? [String: Any],
                  (probe["readyState"] as? String) == "complete" else {
                return false
            }

            let titleLength = numericProbeValue(probe["titleLength"])
            let textLength = numericProbeValue(probe["textLength"])
            let bodyChildCount = numericProbeValue(probe["bodyChildCount"])
            let bodyHTMLLength = numericProbeValue(probe["bodyHTMLLength"])
            let visibleElementCount = numericProbeValue(probe["visibleElementCount"])

            guard titleLength == 0,
                  textLength == 0,
                  visibleElementCount == 0 else {
                return false
            }

            return bodyChildCount == 0 || bodyHTMLLength < 240
        }

        private func numericProbeValue(_ value: Any?) -> Int {
            if let intValue = value as? Int { return intValue }
            if let doubleValue = value as? Double { return Int(doubleValue) }
            if let numberValue = value as? NSNumber { return numberValue.intValue }
            if let stringValue = value as? String { return Int(stringValue) ?? 0 }
            return 0
        }

        private func isRecoverableWebPageURL(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        }

        // MARK: HTTP Auth Challenge
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.performDefaultHandling, nil)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            preferences.preferredContentMode = viewModel.isDesktopModeEnabled ? .desktop : .mobile
            let decide: (WKNavigationActionPolicy) -> Void = { policy in
                decisionHandler(policy, preferences)
            }
            guard let url = navigationAction.request.url else {
                decide(.cancel)
                return
            }

            let nativeRequest = (webView as? AccessibleWebView)?.consumeNativeNavigation(to: url) == true
            guard allowsNavigation(navigationAction, in: webView, nativeRequest: nativeRequest) else {
                decide(.cancel)
                return
            }

            // An address typed in Soulo must reach the response policy first.
            // WebKit may flag an action as a download before its HTML MIME type
            // is known; honor that flag only for navigation initiated by a page.
            if BrowserDownloadPolicy.shouldDownloadNavigationAction(
                requestedByPage: navigationAction.shouldPerformDownload,
                nativeRequest: nativeRequest
            ) {
                decide(.download)
                return
            }

            switch WebNavigationPolicyService.shared.decision(for: url) {
            case .allow:
                let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
                let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
                let shouldSkipPrivacyTransform = oneShotHTTPFallbacks.remove(url.absoluteString) != nil

                if isMainFrame, method == "GET",
                   navigationAction.navigationType == .linkActivated,
                   let target = viewModel.googleFollowLinkTarget,
                   isGoogleTranslationPageURL(webView.url),
                   !isGoogleTranslationPageURL(url),
                   let translatedURL = googleTranslationURL(pageURL: url, target: target) {
                    decide(.cancel)
                    webView.load(URLRequest(url: translatedURL))
                    return
                }

                if method == "GET", !shouldSkipPrivacyTransform {
                    switch PrivacyNavigationService.shared.decision(for: url, isMainFrame: isMainFrame) {
                    case .allow:
                        break
                    case .redirect(let transformedURL):
                        if isHTTPSUpgrade(from: url, to: transformedURL) {
                            httpsUpgradeFallbacks[transformedURL.absoluteString] = url
                        }
                        let strippedCount = PrivacyNavigationService.shared.strippedTrackingParameterCount(from: url, to: transformedURL)
                        Task { @MainActor in
                            if self.isHTTPSUpgrade(from: url, to: transformedURL) {
                                PrivacyProtectionService.shared.recordHTTPSUpgrade(for: transformedURL.host ?? url.host)
                            }
                            PrivacyProtectionService.shared.recordTrackingParametersStripped(strippedCount, for: transformedURL.host ?? url.host)
                        }
                        var transformedRequest = navigationAction.request
                        transformedRequest.url = transformedURL
                        if let privacyHeaderRequest = privacyHeaderRequestIfNeeded(for: transformedRequest) {
                            transformedRequest = privacyHeaderRequest
                            privacyHeaderBypassURLs.insert(privacyHeaderRequest.url?.absoluteString ?? transformedURL.absoluteString)
                        }
                        decide(.cancel)
                        webView.load(transformedRequest)
                        return
                    }
                }

                // Loading a rewritten request on WKWebView always navigates its
                // main frame. Leave iframe requests and new-window contexts to
                // WebKit instead of replacing the page that contains them.
                if isMainFrame, method == "GET",
                   let privacyHeaderRequest = privacyHeaderRequestIfNeeded(for: navigationAction.request) {
                    privacyHeaderBypassURLs.insert(privacyHeaderRequest.url?.absoluteString ?? url.absoluteString)
                    decide(.cancel)
                    webView.load(privacyHeaderRequest)
                    return
                }

                let sourceURL = navigationAction.sourceFrame.request.url
                let recentGesture = navigationGesture.map { gesture in
                    gesture.webView == ObjectIdentifier(webView)
                        && gesture.frameURL == sourceURL
                        && ProcessInfo.processInfo.systemUptime - gesture.time <= 3
                } ?? false
                let crossSite = sourceURL?.host.map {
                    $0.caseInsensitiveCompare(url.host ?? "") != .orderedSame
                } ?? false
                var sourceWithoutFragment = sourceURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                var destinationWithoutFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)
                sourceWithoutFragment?.fragment = nil
                destinationWithoutFragment?.fragment = nil
                let sameDocument = sourceWithoutFragment?.url == destinationWithoutFragment?.url
                let shouldStartInBrowser = navigationAction.navigationType == .linkActivated
                    ? !sameDocument
                    : crossSite && (navigationAction.navigationType == .formSubmitted
                        || (navigationAction.navigationType == .other && recentGesture))
                if isMainFrame, method == "GET", !nativeRequest,
                   shouldStartInBrowser,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   !BrowserPopupPolicy.shouldPreserveJavaScriptContext(
                    navigationType: navigationAction.navigationType, url: url
                   ) {
                    // Start ordinary links in this browser, including same-site
                    // search redirects that may lead to an app's Universal Link.
                    decide(.cancel)
                    let request = navigationAction.request
                    DispatchQueue.main.async { [weak webView] in
                        webView?.load(request)
                    }
                    return
                }

                decide(.allow)
            case .cancel:
                decide(.cancel)
            case .external(let externalURL):
                decide(.cancel)
                routeExternalURL(
                    externalURL,
                    userInitiated: navigationAction.navigationType == .linkActivated
                )
            }
        }

        private func allowsNavigation(
            _ action: WKNavigationAction,
            in webView: WKWebView,
            nativeRequest: Bool
        ) -> Bool {
            guard let destination = action.request.url else { return false }
            if viewModel.manualAdSelection != nil && !nativeRequest { return false }
            if UserDefaults.standard.object(forKey: BrowserAutomaticNavigationPolicy.preferenceKey) as? Bool ?? true { return true }
            if nativeRequest || action.navigationType == .backForward || action.navigationType == .reload { return true }
            // HTTP redirects belong to the already-approved provisional load.
            // A new document cannot run redirect scripts until it commits.
            if provisionalNavigation != nil && action.targetFrame?.isMainFrame == true { return true }
            // Embedded document loads must not break players or other page content.
            if let target = action.targetFrame, !target.isMainFrame { return true }
            if webView.url == nil && action.targetFrame != nil { return true }
            if let source = action.sourceFrame.request.url,
               let gesture = navigationGesture,
               gesture.webView == ObjectIdentifier(webView), gesture.frameURL == source,
               ProcessInfo.processInfo.systemUptime - gesture.time <= 3 { return true }
            return false
        }

        private func privacyHeaderRequestIfNeeded(for request: URLRequest) -> URLRequest? {
            guard let url = request.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !WebCompatibilityService.shouldBypassWebProtection(for: url, fallbackHost: url.host),
                  !PrivacyProtectionService.isProtectionDisabled(url.host) else {
                return nil
            }

            if privacyHeaderBypassURLs.remove(url.absoluteString) != nil {
                return nil
            }

            let defaults = UserDefaults.standard
            let gpcEnabled = defaults.object(forKey: "privacy_gpc_enabled") as? Bool
                ?? PrivacyFeatureDefaults.gpcEnabled
            return GPCRequestFactory(userDefaults: defaults).requestForGPC(basedOn: request, gpcEnabled: gpcEnabled)
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
            PrivacyNavigationService.shared.recordHTTPSUpgradeFailure(for: originalHTTPURL.host)
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

        private func postExternalURLRequestIfNeeded(
            _ url: URL,
            explicitUserAction: Bool = false
        ) {
            NotificationCenter.default.post(
                name: .webViewExternalURLRequest,
                object: nil,
                userInfo: [
                    "url": url,
                    "explicitUserAction": explicitUserAction
                ]
            )
        }

        private func routeExternalURL(_ url: URL, userInitiated _: Bool) {
            if WebNavigationPolicyService.shared.isAppleAppStoreURL(url) {
                // Explicit downloads always ask before leaving Soulo. They are not
                // swallowed by the setting that blocks unsolicited app jumps.
                postExternalURLRequestIfNeeded(url, explicitUserAction: true)
                return
            }
            postExternalURLRequestIfNeeded(url)
        }

        private func applyCurrentAdHidingIfNeeded(on webView: WKWebView) {
            let defaults = UserDefaults.standard
            applyAdHidingIfNeeded(
                on: webView,
                enabled: defaults.object(forKey: "ad_block_enabled") as? Bool ?? true,
                cosmetic: true,
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
            let contentDisposition = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")
            if BrowserDownloadPolicy.shouldDownload(
                canShowMIMEType: navigationResponse.canShowMIMEType,
                mimeType: response.mimeType,
                contentDisposition: contentDisposition,
                responseURL: response.url
            ) {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        // MARK: Navigation becomes download

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            webView.scrollView.refreshControl?.endRefreshing()
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            webView.scrollView.refreshControl?.endRefreshing()
            download.delegate = self
        }

        // MARK: WKUIDelegate — route target="_blank" links

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let nativeRequest = navigationAction.request.url.flatMap {
                (webView as? AccessibleWebView)?.consumeNativeNavigation(to: $0)
            } == true
            guard allowsNavigation(navigationAction, in: webView, nativeRequest: nativeRequest) else { return nil }
            if navigationAction.targetFrame == nil || !(navigationAction.targetFrame?.isMainFrame ?? false) {
                if let url = navigationAction.request.url {
                    switch WebNavigationPolicyService.shared.decision(for: url) {
                    case .allow:
                        if BrowserPopupPolicy.shouldPreserveJavaScriptContext(
                            navigationType: navigationAction.navigationType,
                            url: url
                        ) {
                            return makeEmbeddedPopup(
                                in: webView,
                                configuration: configuration
                            )
                        } else {
                            // Regular target="_blank" and script-created links do
                            // not need a separate browser surface. Keep navigation
                            // in the current Soulo tab; explicit context-menu actions
                            // can still create a real new tab.
                            // Loading synchronously from the click callback can
                            // preserve WebKit's user gesture and let iOS hand an
                            // HTTPS Universal Link to an installed native app.
                            // Start our own navigation on the next turn instead.
                            let request = navigationAction.request
                            DispatchQueue.main.async { [weak webView] in
                                webView?.load(request)
                            }
                        }
                    case .cancel:
                        break
                    case .external(let externalURL):
                        // New-window requests do not pass through the navigation
                        // delegate, so route them through the same confirmation UI.
                        routeExternalURL(
                            externalURL,
                            userInitiated: true
                        )
                    }
                } else {
                    // Fallback: load in current webView
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        private func makeEmbeddedPopup(
            in parentWebView: WKWebView,
            configuration: WKWebViewConfiguration
        ) -> WKWebView {
            // WebKit supplies a new-window configuration, but per-view settings
            // such as the custom user agent are not copied automatically. Match
            // the parent tab so iPad does not silently promote a mobile popup to
            // desktop mode.
            configuration.defaultWebpagePreferences.preferredContentMode = viewModel.isDesktopModeEnabled
                ? .desktop
                : .mobile

            let container = UIView(frame: parentWebView.bounds)
            container.tag = EmbeddedBrowserPopupTag.container
            container.backgroundColor = .systemBackground
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            let popupWebView = WKWebView(frame: container.bounds, configuration: configuration)
            popupWebView.customUserAgent = parentWebView.customUserAgent
            popupWebView.pageZoom = parentWebView.pageZoom
            popupWebView.uiDelegate = self
            popupWebView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(popupWebView)

            var openConfiguration = UIButton.Configuration.filled()
            openConfiguration.image = UIImage(systemName: "arrow.right.square")
            openConfiguration.imagePadding = 6
            openConfiguration.title = LanguageManager.shared.localizedString("popup_open_current_tab")
            openConfiguration.baseForegroundColor = .label
            openConfiguration.baseBackgroundColor = .secondarySystemBackground
            openConfiguration.cornerStyle = .capsule
            let openInCurrentTabButton = UIButton(configuration: openConfiguration)
            openInCurrentTabButton.translatesAutoresizingMaskIntoConstraints = false
            openInCurrentTabButton.titleLabel?.lineBreakMode = .byTruncatingTail
            openInCurrentTabButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            openInCurrentTabButton.accessibilityLabel = LanguageManager.shared.localizedString("popup_open_current_tab")
            openInCurrentTabButton.addTarget(
                self,
                action: #selector(openEmbeddedPopupInCurrentTab(_:)),
                for: .touchUpInside
            )
            container.addSubview(openInCurrentTabButton)

            var buttonConfiguration = UIButton.Configuration.filled()
            buttonConfiguration.image = UIImage(systemName: "xmark")
            buttonConfiguration.baseForegroundColor = .label
            buttonConfiguration.baseBackgroundColor = .secondarySystemBackground
            buttonConfiguration.cornerStyle = .capsule
            let closeButton = UIButton(configuration: buttonConfiguration)
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.accessibilityLabel = LanguageManager.shared.localizedString("cancel")
            closeButton.addTarget(self, action: #selector(closeEmbeddedPopup(_:)), for: .touchUpInside)
            container.addSubview(closeButton)

            NSLayoutConstraint.activate([
                openInCurrentTabButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
                openInCurrentTabButton.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                openInCurrentTabButton.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
                openInCurrentTabButton.heightAnchor.constraint(equalToConstant: 44),
                closeButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
                closeButton.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 44)
            ])
            parentWebView.addSubview(container)
            return popupWebView
        }

        @objc private func openEmbeddedPopupInCurrentTab(_ sender: UIButton) {
            guard let container = sender.superview,
                  let popupWebView = container.subviews.compactMap({ $0 as? WKWebView }).first,
                  let url = popupWebView.url else {
                return
            }
            container.removeFromSuperview()
            viewModel.loadURL(url)
        }

        @objc private func closeEmbeddedPopup(_ sender: UIButton) {
            sender.superview?.removeFromSuperview()
        }

        func dismissEmbeddedPopups(in webView: WKWebView) {
            webView.subviews
                .filter { $0.tag == EmbeddedBrowserPopupTag.container }
                .forEach { $0.removeFromSuperview() }
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard webView !== viewModel.webView else { return }
            webView.superview?.removeFromSuperview()
        }

        // MARK: WKUIDelegate — device permissions

        func webView(
            _ webView: WKWebView,
            requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            // WebKit presents the requesting site's permission dialog. Never
            // grant sensors implicitly, including requests from embedded frames.
            decisionHandler(WebMotionPermissionPolicy.decision(forScheme: origin.protocol))
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(
                WebMediaCapturePermissionPolicy.decision(forScheme: origin.protocol)
            )
        }

        // MARK: WKUIDelegate — JS alert / confirm / prompt

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            topViewController(for: webView)?.present(alert, animated: true) ?? completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            topViewController(for: webView)?.present(alert, animated: true) ?? completionHandler(false)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            topViewController(for: webView)?.present(alert, animated: true) ?? completionHandler(nil)
        }

        private func topViewController(for sourceView: UIView? = nil) -> UIViewController? {
            let sourceScene = sourceView?.window?.windowScene
            let activeScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            guard let scene = sourceScene ?? activeScene,
                  let root = scene.keyWindow?.rootViewController else { return nil }
            return visibleViewController(from: root)
        }

        private func visibleViewController(from root: UIViewController) -> UIViewController {
            if let presented = root.presentedViewController {
                return visibleViewController(from: presented)
            }
            if let navigation = root as? UINavigationController,
               let visible = navigation.visibleViewController {
                return visibleViewController(from: visible)
            }
            if let tabs = root as? UITabBarController,
               let selected = tabs.selectedViewController {
                return visibleViewController(from: selected)
            }
            return root
        }

        private func presentActivityController(items: [Any], sourceView: UIView?) {
            guard let viewController = topViewController(for: sourceView) else { return }
            let activityController = UIActivityViewController(
                activityItems: items,
                applicationActivities: nil
            )
            if let popover = activityController.popoverPresentationController {
                guard let anchorView = sourceView ?? viewController.view else { return }
                popover.sourceView = anchorView
                popover.sourceRect = CGRect(
                    x: anchorView.bounds.midX,
                    y: anchorView.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            viewController.present(activityController, animated: true)
        }

        // MARK: Pull-to-Refresh

        @objc func handleRefresh(_ control: UIRefreshControl) {
            guard let webView = viewModel.webView,
                  let url = webView.url ?? viewModel.currentURL else {
                control.endRefreshing()
                return
            }
            webView.stopLoading()
            // WKWebView can still use cached subresources when only the main
            // URLRequest asks to ignore cache. Origin reload refreshes both.
            if webView.url != nil {
                webView.reloadFromOrigin()
            } else {
                viewModel.loadURL(url, cachePolicy: .reloadIgnoringLocalCacheData)
            }

            // Completion normally ends the control in didFinish/didFail. Keep a
            // defensive timeout so a stalled WebKit process never leaves it spinning.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak control] in
                control?.endRefreshing()
            }
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let currentOffset = scrollView.contentOffset.y
            (scrollView.refreshControl as? BrowserRefreshControl)?.updatePull(
                distance: -(currentOffset + scrollView.adjustedContentInset.top)
            )

            guard !UIAccessibility.isVoiceOverRunning else {
                setScrollingUpIfNeeded(false)
                accumulatedScrollDelta = 0
                lastContentOffset = currentOffset
                return
            }

            guard !isUserZooming,
                  !scrollView.isZooming,
                  !scrollView.isZoomBouncing else {
                lastContentOffset = currentOffset
                return
            }

            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else {
                lastContentOffset = currentOffset
                return
            }

            let minOffset = -scrollView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let scrollableRange = maxOffset - minOffset

            guard scrollableRange > max(180, scrollView.bounds.height * 0.35) else {
                setScrollingUpIfNeeded(false)
                accumulatedScrollDelta = 0
                lastContentOffset = currentOffset
                return
            }

            if currentOffset <= minOffset + 72 {
                setScrollingUpIfNeeded(false)
                accumulatedScrollDelta = 0
                lastContentOffset = currentOffset
                return
            }

            guard currentOffset <= maxOffset + 24 else {
                lastContentOffset = currentOffset
                return
            }

            let delta = currentOffset - lastContentOffset
            lastContentOffset = currentOffset
            guard abs(delta) >= 1 else { return }

            if (accumulatedScrollDelta > 0 && delta < 0) || (accumulatedScrollDelta < 0 && delta > 0) {
                accumulatedScrollDelta = 0
            }
            accumulatedScrollDelta += delta

            if accumulatedScrollDelta >= 56, currentOffset > minOffset + 120 {
                setScrollingUpIfNeeded(true)
                accumulatedScrollDelta = 0
            } else if accumulatedScrollDelta <= -40 {
                setScrollingUpIfNeeded(false)
                accumulatedScrollDelta = 0
            }
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            isUserZooming = true
            lastContentOffset = scrollView.contentOffset.y
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            lastContentOffset = scrollView.contentOffset.y
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            isUserZooming = false
            lastContentOffset = scrollView.contentOffset.y
            accumulatedScrollDelta = 0
        }

        private func setScrollingUpIfNeeded(_ scrollingUp: Bool) {
            guard lastReportedScrollingUp != scrollingUp else { return }
            lastReportedScrollingUp = scrollingUp
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.isScrollingUp != scrollingUp else { return }
                self.viewModel.isScrollingUp = scrollingUp
            }
        }

        private func resetScrollChromeState() {
            lastContentOffset = 0
            accumulatedScrollDelta = 0
            lastReportedScrollingUp = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewModel.isScrollingUp = false
            }
        }

        // MARK: Native Context Menu (replaces custom JS long-press)

        func webView(
            _ webView: WKWebView,
            contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
            completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
        ) {
            if let contextResource, ProcessInfo.processInfo.systemUptime - contextResource.time < 3 {
                guard elementInfo.linkURL != nil || contextResource.resource != nil else {
                    completionHandler(nil); return
                }
                completionHandler(contextMenuConfiguration(linkURL: elementInfo.linkURL,
                    resource: contextResource.resource, webView: webView, frame: contextResource.frame))
                return
            }
            webView.evaluateJavaScript(
                "window.__souloContextResourceInfo ? window.__souloContextResourceInfo() : null",
                in: nil, in: .defaultClient
            ) { [weak self, weak webView] result in
                let value = try? result.get()
                guard let self, let webView else {
                    completionHandler(nil)
                    return
                }
                let resource = (value as? [String: Any]).flatMap(WebContextResource.init(dictionary:))
                guard elementInfo.linkURL != nil || resource != nil else {
                    completionHandler(nil)
                    return
                }
                completionHandler(
                    self.contextMenuConfiguration(
                        linkURL: elementInfo.linkURL,
                        resource: resource,
                        webView: webView
                    )
                )
            }
        }

        private func contextMenuConfiguration(
            linkURL: URL?,
            resource: WebContextResource?,
            webView: WKWebView,
            frame: WKFrameInfo? = nil
        ) -> UIContextMenuConfiguration {
            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                var actions: [UIMenuElement] = []

                if let linkURL {
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
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    NotificationCenter.default.post(name: .linkCopied, object: nil)
                }

                let share = UIAction(
                    title: LanguageManager.shared.localizedString("share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in
                    self.presentActivityController(items: [linkURL], sourceView: webView)
                }

                    actions.append(contentsOf: [openInNewTab, copyLink, share])
                }

                if let resource {
                    if resource.kind == .image {
                        actions.append(UIAction(title: ToolText.text("image_view_full"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in
                            self.viewModel.imagePreview = WebImagePreviewRequest(url: resource.url, webView: webView, frame: frame)
                        })
                        actions.append(UIAction(
                            title: LanguageManager.shared.localizedString("image_extract_text"),
                            image: UIImage(systemName: "text.viewfinder")
                        ) { _ in
                            self.extractText(from: resource, webView: webView, frame: frame)
                        })
                        if ["http", "https"].contains(resource.url.scheme ?? "") {
                            actions.append(UIAction(
                                title: LanguageManager.shared.localizedString("save_to_photos"),
                                image: UIImage(systemName: "photo.badge.arrow.down")
                            ) { _ in
                                self.downloadContextResource(resource, webView: webView, saveToPhotos: true, pageURL: frame?.request.url)
                            })
                        }
                    }

                    if resource.kind.allowsDirectDownload && ["http", "https"].contains(resource.url.scheme ?? "") {
                        actions.append(UIAction(
                            title: LanguageManager.shared.localizedString("download"),
                            image: UIImage(systemName: "arrow.down.circle")
                        ) { _ in
                            self.downloadContextResource(resource, webView: webView, saveToPhotos: false, pageURL: frame?.request.url)
                        })
                    }

                    if resource.url != linkURL {
                        actions.append(UIAction(
                            title: LanguageManager.shared.localizedString("resource_copy_url"),
                            image: UIImage(systemName: "doc.on.doc")
                        ) { _ in
                            UIPasteboard.general.url = resource.url
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            NotificationCenter.default.post(name: .linkCopied, object: nil)
                        })
                    }
                }

                return UIMenu(children: actions)
            }
        }

        private func extractText(from resource: WebContextResource, webView: WKWebView, frame: WKFrameInfo? = nil) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let image = try await WebResourceDownloadService.shared.loadImage(
                        resource.url,
                        pageURL: frame?.request.url ?? webView.url,
                        webView: webView, frame: frame
                    )
                    let result = try await ImageTextRecognitionService.recognize(image, sourceURL: resource.url)
                    NotificationCenter.default.post(
                        name: .imageTextRecognitionCompleted,
                        object: self.viewModel,
                        userInfo: ["result": result]
                    )
                } catch {
                    NotificationCenter.default.post(
                        name: .imageTextRecognitionFailed,
                        object: self.viewModel,
                        userInfo: ["error": error]
                    )
                }
            }
        }

        private func downloadContextResource(
            _ resource: WebContextResource,
            webView: WKWebView,
            saveToPhotos: Bool,
            pageURL: URL? = nil
        ) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    if saveToPhotos {
                        try await WebResourceDownloadService.shared.saveImageToPhotos(
                            resource.url,
                            preferredFilename: resource.suggestedFilename,
                            pageURL: pageURL ?? webView.url,
                            webView: webView
                        )
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } else {
                        let fileURL = try await WebResourceDownloadService.shared.download(
                            resource.url,
                            preferredFilename: resource.suggestedFilename,
                            pageURL: pageURL ?? webView.url,
                            webView: webView
                        )
                        self.presentDownloadedFile(fileURL, sourceURL: resource.url)
                    }
                } catch {
                    NotificationCenter.default.post(
                        name: .browserDownloadFailed,
                        object: self.viewModel
                    )
                }
            }
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let identifier = ObjectIdentifier(download)
            if let existingID = downloadIDs[identifier],
               let existing = DownloadManagerService.shared.downloads.first(where: { $0.id == existingID }) {
                activeDownloads[identifier] = download
                activeDownloadNames[identifier] = existing.fileName
                completionHandler(existing.localURL)
                return
            }
            let (item, fileURL) = DownloadManagerService.shared.beginDownload(
                suggestedFilename: suggestedFilename,
                sourceURL: viewModel.currentURL ?? response.url
            )
            downloadIDs[identifier] = item.id
            activeDownloads[identifier] = download
            activeDownloadNames[identifier] = item.fileName
            downloadProgressObservations[identifier] = download.progress.observe(
                \.fractionCompleted,
                options: [.initial, .new]
            ) { progress, _ in
                Task { @MainActor in
                    DownloadManagerService.shared.updateProgress(
                        id: item.id,
                        completed: progress.completedUnitCount,
                        total: progress.totalUnitCount
                    )
                }
            }

            Task { @MainActor in
                refreshDownloadPresentation(preferredFilename: item.fileName)
            }

            completionHandler(fileURL)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let identifier = ObjectIdentifier(download)
            activeDownloads.removeValue(forKey: identifier)
            downloadProgressObservations.removeValue(forKey: identifier)?.invalidate()
            activeDownloadNames.removeValue(forKey: identifier)
            let downloadID = downloadIDs.removeValue(forKey: identifier)
            let downloadedItem = downloadID.flatMap { id in
                DownloadManagerService.shared.downloads.first(where: { $0.id == id })
            }
            let fileURL = downloadedItem?.localURL
            let sourceURL = downloadedItem.flatMap { URL(string: $0.sourceURLString) }
            if let downloadID {
                DownloadManagerService.shared.markFinished(id: downloadID)
                BrowserDownloadResumeClaims.release(downloadID)
            }
            Task { @MainActor in
                refreshDownloadPresentation()
                guard let fileURL else { return }
                presentDownloadedFile(fileURL, sourceURL: sourceURL)
            }
        }

        private func presentDownloadedFile(_ fileURL: URL, sourceURL: URL? = nil) {
            if let candidate = BrowserExtensionInstallCandidate.detect(
                fileURL: fileURL,
                sourceURL: sourceURL
            ) {
                NotificationCenter.default.post(
                    name: .browserExtensionInstallCandidate,
                    object: viewModel,
                    userInfo: ["candidate": candidate]
                )
                return
            }
            // Completed files remain available in Library > Downloads. Sharing
            // is explicit there, so completion never interrupts navigation or reading.
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let identifier = ObjectIdentifier(download)
            activeDownloads.removeValue(forKey: identifier)
            downloadProgressObservations.removeValue(forKey: identifier)?.invalidate()
            activeDownloadNames.removeValue(forKey: identifier)
            let downloadID = downloadIDs.removeValue(forKey: identifier)
            Task { @MainActor in
                refreshDownloadPresentation()
                guard let downloadID else { return }
                if let resumeData, !resumeData.isEmpty {
                    DownloadManagerService.shared.markPaused(id: downloadID, resumeData: resumeData)
                } else {
                    DownloadManagerService.shared.markFailed(id: downloadID, error: error)
                }
                BrowserDownloadResumeClaims.release(downloadID)
                finishPageDownloadWithError()
            }
        }

        private func pauseDownload(id: UUID) {
            if let transferEntry = pageDownloadTransfers.first(where: { $0.value.itemID == id }) {
                var transfer = transferEntry.value
                guard !transfer.isPaused else { return }
                transfer.isPaused = true
                pageDownloadTransfers[transferEntry.key] = transfer
                DownloadManagerService.shared.markPaused(id: id)
                refreshDownloadPresentation()
                return
            }
            guard let pair = downloadIDs.first(where: { $0.value == id }),
                  let download = activeDownloads[pair.key] else { return }
            activeDownloads.removeValue(forKey: pair.key)
            activeDownloadNames.removeValue(forKey: pair.key)
            downloadIDs.removeValue(forKey: pair.key)
            downloadProgressObservations.removeValue(forKey: pair.key)?.invalidate()
            download.cancel { resumeData in
                Task { @MainActor in
                    if let resumeData, !resumeData.isEmpty {
                        DownloadManagerService.shared.markPaused(id: id, resumeData: resumeData)
                    } else {
                        DownloadManagerService.shared.markCanceled(id: id)
                    }
                    BrowserDownloadResumeClaims.release(id)
                    self.refreshDownloadPresentation()
                }
            }
        }

        private func resumeDownload(id: UUID) {
            if let transferEntry = pageDownloadTransfers.first(where: { $0.value.itemID == id }) {
                var transfer = transferEntry.value
                guard transfer.isPaused else { return }
                transfer.isPaused = false
                let pendingReply = transfer.pendingChunkReply
                transfer.pendingChunkReply = nil
                pageDownloadTransfers[transferEntry.key] = transfer
                DownloadManagerService.shared.markResumed(id: id)
                pendingReply?(["resumed": true], nil)
                refreshDownloadPresentation()
                return
            }
            guard let webView = viewModel.webView,
                  let resumeData = DownloadManagerService.shared.resumeData(id: id),
                  BrowserDownloadResumeClaims.claim(id) else { return }
            webView.resumeDownload(fromResumeData: resumeData) { [weak self] download in
                guard let self else { return }
                DownloadManagerService.shared.removeResumeData(id: id)
                DownloadManagerService.shared.markResumed(id: id)
                let identifier = ObjectIdentifier(download)
                self.downloadIDs[identifier] = id
                self.activeDownloads[identifier] = download
                self.activeDownloadNames[identifier] = DownloadManagerService.shared.downloads
                    .first(where: { $0.id == id })?.fileName ?? ""
                download.delegate = self
                self.downloadProgressObservations[identifier] = download.progress.observe(
                    \.fractionCompleted,
                    options: [.initial, .new]
                ) { progress, _ in
                    Task { @MainActor in
                        DownloadManagerService.shared.updateProgress(
                            id: id,
                            completed: progress.completedUnitCount,
                            total: progress.totalUnitCount
                        )
                    }
                }
                self.refreshDownloadPresentation()
            }
        }

        private func cancelActiveDownloads() {
            let downloadsToCancel = activeDownloads
            activeDownloads.removeAll()
            activeDownloadNames.removeAll()
            for (identifier, download) in downloadsToCancel {
                downloadProgressObservations.removeValue(forKey: identifier)?.invalidate()
                if let downloadID = downloadIDs.removeValue(forKey: identifier) {
                    DownloadManagerService.shared.markCanceled(id: downloadID)
                }
                download.cancel { _ in }
            }
            let pageTransfersToCancel = pageDownloadTransfers
            pageDownloadTransfers.removeAll()
            for transfer in pageTransfersToCancel.values {
                transfer.pendingChunkReply?(nil, "Download canceled")
                try? transfer.fileHandle.close()
                DownloadManagerService.shared.markCanceled(id: transfer.itemID)
            }
            viewModel.webView?.evaluateJavaScript("window.__souloCancelDownloads && window.__souloCancelDownloads();")
            Task { @MainActor in
                refreshDownloadPresentation()
            }
        }

        private func cancelDownload(id: UUID) {
            if let entry = downloadIDs.first(where: { $0.value == id }),
               let download = activeDownloads.removeValue(forKey: entry.key) {
                activeDownloadNames.removeValue(forKey: entry.key)
                downloadProgressObservations.removeValue(forKey: entry.key)?.invalidate()
                downloadIDs.removeValue(forKey: entry.key)
                download.cancel { _ in }
            }

            if let transferEntry = pageDownloadTransfers.first(where: { $0.value.itemID == id }) {
                pageDownloadTransfers.removeValue(forKey: transferEntry.key)
                transferEntry.value.pendingChunkReply?(nil, "Download canceled")
                try? transferEntry.value.fileHandle.close()
                viewModel.webView?.evaluateJavaScript(
                    "window.__souloCancelDownload && window.__souloCancelDownload(\(Self.javascriptString(transferEntry.key)));"
                )
            }
            refreshDownloadPresentation()
        }

        private static func javascriptString(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return encoded
        }
    }
}

// MARK: - Notification Name

// (webViewImageLongPressed / webViewLinkLongPressed removed — using native WKUIDelegate context menus)
