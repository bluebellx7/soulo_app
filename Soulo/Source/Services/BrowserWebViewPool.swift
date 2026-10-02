import Combine
import UIKit
import WebKit

/// Owns at most one unused browser view. A claimed view belongs exclusively to
/// its tab and is never returned to the pool with history, scripts or handlers.
@MainActor
final class BrowserWebViewPool: NSObject, WKNavigationDelegate {
    static let shared = BrowserWebViewPool()

    private(set) var preparedWebView: AccessibleWebView?
    private(set) var isPreparedWebViewReady = false
    private var isIncognito = false
    private var isActive = false
    private var isSuppressedForMemoryPressure = false
    private var warmupTask: Task<Void, Never>?
    private weak var lastAcquiredWebView: WKWebView?
    private var observers: Set<AnyCancellable> = []
    private let warmupDelay: Duration
    private let refillDelay: Duration

    init(warmupDelay: Duration = .milliseconds(350), refillDelay: Duration = .seconds(2)) {
        self.warmupDelay = warmupDelay
        self.refillDelay = refillDelay
        super.init()
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in self?.handleMemoryPressure() }
            .store(in: &observers)
        // Application-level notifications avoid releasing another window's
        // spare when only one of several scenes moves to the background.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.suspend() }
            .store(in: &observers)
    }

    func activate(isIncognito: Bool) {
        BrowserStartupTrace.mark("pool_activate", detail: "disabled=\(BrowserStartupTrace.disablesWarmup)")
        guard !BrowserStartupTrace.disablesWarmup else { return }
        if !isActive { isSuppressedForMemoryPressure = false }
        isActive = true
        synchronizeMode(isIncognito)
        scheduleWarmup(after: warmupDelay)
    }

    func suspend() {
        isActive = false
        discardPreparedWebView()
    }

    func handleMemoryPressure() {
        // Do not immediately recreate the allocation we were asked to release.
        // Resume speculative work only on the next foreground activation.
        isSuppressedForMemoryPressure = true
        discardPreparedWebView()
    }

    func makeWebView(isIncognito: Bool, for url: URL?) -> AccessibleWebView {
        BrowserStartupTrace.mark("acquire_start")
        synchronizeMode(isIncognito)
        let webView: AccessibleWebView
        // Extension origins need their owning extension's configuration, even
        // when the ordinary configuration has the same extension controller.
        if url?.scheme?.lowercased() != "webkit-extension", let preparedWebView {
            BrowserStartupTrace.mark("pool_hit", detail: "ready=\(isPreparedWebViewReady)")
            webView = preparedWebView
            self.preparedWebView = nil
            isPreparedWebViewReady = false
            webView.navigationDelegate = nil
        } else {
            BrowserStartupTrace.mark("pool_miss")
            webView = AccessibleWebView(frame: .zero, configuration: Self.configuration(isIncognito: isIncognito, for: url))
        }
        BrowserStartupTrace.mark("acquire_end")
        lastAcquiredWebView = webView
        scheduleWarmup(after: refillDelay)
        return webView
    }

    private func synchronizeMode(_ isIncognito: Bool) {
        guard self.isIncognito != isIncognito else { return }
        discardPreparedWebView()
        self.isIncognito = isIncognito
    }

    private func scheduleWarmup(after delay: Duration) {
        guard isActive, !isSuppressedForMemoryPressure,
              preparedWebView == nil, warmupTask == nil else { return }
        warmupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
                // Avoid competing with the page that just claimed the spare.
                // Keep self weak across sleeps so local/test pools can deinit.
                while self?.lastAcquiredWebView?.isLoading == true {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
            } catch { return }
            guard let self else { return }
            self.warmupTask = nil
            guard self.isActive, !self.isSuppressedForMemoryPressure,
                  self.preparedWebView == nil else { return }
            BrowserStartupTrace.mark("warmup_start")
            let webView = AccessibleWebView(frame: .zero, configuration: Self.configuration(isIncognito: self.isIncognito, for: nil))
            self.preparedWebView = webView
            webView.navigationDelegate = self
            // Start WebKit without a navigation: no network request, synthetic
            // back item, page-ready callback, or tab-specific scripts/bridges.
            self.startWebKit(webView)
        }
    }

    private func startWebKit(_ webView: AccessibleWebView) {
        // Return before WebKit starts. The completion keeps the pool weak,
        // including when a local pool is discarded during process startup.
        webView.evaluateJavaScript("void 0") { [weak self, weak webView] _, error in
            guard let self, let webView, self.preparedWebView === webView else { return }
            if error != nil {
                self.discardPreparedWebView()
            } else {
                self.isPreparedWebViewReady = true
                BrowserStartupTrace.mark("warmup_ready")
            }
        }
    }

    private func discardPreparedWebView() {
        warmupTask?.cancel()
        warmupTask = nil
        preparedWebView?.navigationDelegate = nil
        preparedWebView?.stopLoading()
        preparedWebView = nil
        isPreparedWebViewReady = false
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard preparedWebView === webView else { return }
        // Fall back to a fresh instance on demand; don't loop if WebKit is
        // terminating unused content processes under resource pressure.
        discardPreparedWebView()
    }

    private static func configuration(isIncognito: Bool, for url: URL?) -> WKWebViewConfiguration {
        let configuration: WKWebViewConfiguration
        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
           !isIncognito, #available(iOS 18.4, *),
           let extensionConfiguration = NativeWebExtensionRuntime.shared.webViewConfiguration(for: url) {
            configuration = extensionConfiguration
        } else {
            configuration = WKWebViewConfiguration()
            if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
               !isIncognito, #available(iOS 18.4, *) {
                NativeWebExtensionRuntime.shared.apply(to: configuration)
            }
        }
        configuration.applicationNameForUserAgent = nil
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = isIncognito ? .nonPersistent() : .default()
        configuration.userContentController = WKUserContentController()
        return configuration
    }
}
