import UIKit
import WebKit
import Combine
import NaturalLanguage
import SwiftUI

struct UserScriptMenuCommand: Identifiable, Equatable {
    let id: String
    let scriptID: UUID
    let scriptName: String
    let title: String
}

struct FollowLinkTranslation: Equatable {
    let sourceIdentifier: String
    let targetIdentifier: String
    let startAfterPageRevision: Int
}

struct WebDomainNavigationConfirmation: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let destinationURL: URL
    var originalRequest: URLRequest? = nil
    /// Opening an address in a new tab must remain available for every prompt.
    /// Keep ordinary GET context, but do not replay a form or consume its stream.
    var requestForNewTab: URLRequest {
        if let originalRequest,
           (originalRequest.httpMethod ?? "GET").uppercased() == "GET",
           originalRequest.httpBody == nil, originalRequest.httpBodyStream == nil {
            return originalRequest
        }
        return URLRequest(url: destinationURL)
    }
}

@MainActor
final class WebViewModel: ObservableObject {

    // MARK: - Published State

    @Published var currentURL: URL?
    @Published private(set) var userAgentOverride: String?
    @Published var pageTitle: String = ""
    var lastURLString: String = ""
    @Published var isLoading: Bool = false
    @Published private(set) var hasVisibleContent = false
    @Published private(set) var hasPresentedContent = false
    var currentDocumentHasUserInteraction = false
    @Published var estimatedProgress: Double = 0.0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var failedNavigationURL: URL?
    private(set) var requestedNavigationURL: URL?
    var errorPageURL: URL? { failedNavigationURL ?? requestedNavigationURL ?? currentURL }
    @Published var isScrollingUp: Bool = false
    @Published var hasBottomVideoControls = false
    @Published private(set) var videoHoldSpeed: Double?
    private var videoHoldSpeedToken: String?
    private var videoHoldSpeedDismissal: Task<Void, Never>?
    @Published var episodeList: WebEpisodeList?
    @Published var showEpisodes = false
    @Published private(set) var domainNavigationConfirmation: WebDomainNavigationConfirmation?
    private var domainNavigationDecision: ((Bool) -> Void)?

    var needsVideoViewportClearance: Bool {
        hasBottomVideoControls || WebCompatibilityService.isDouyinVideoSurface(currentURL)
    }
    @Published var snapshot: UIImage?
    @Published var showSnapshotWhileRestoring: Bool = false
    @Published private(set) var pageZoom: CGFloat = 1
    @Published private(set) var pageLanguageIdentifier: String?
    @Published private(set) var isPageTranslationApplied = false
    @Published private(set) var pageRevision = 0
    @Published private(set) var followLinkTranslation: FollowLinkTranslation?
    @Published private(set) var googleFollowLinkTarget: String?
    @Published private(set) var runtimeRevision = UUID()
    @Published private(set) var userScriptMenuCommands: [UserScriptMenuCommand] = []
    @Published var manualAdSelection: ManualAdSelection?
    @Published var manualAdBusy = false
    @Published var manualAdError = false
    @Published var manualAdSavedRuleID: UUID?
    @Published var videoOrientationError: String?
    @Published var imagePreview: WebImagePreviewRequest?
    @Published var showMediaDownloads = false
    let mediaSession = WebMediaSession()
    var isWebViewRuntimeInstalled: Bool = false
    var hasInstalledWebViewScripts = false
    var lastAdHidingSignature = ""
    var installedPrivacyProtectionSource = ""
    var adHidingNeedsBootstrap = false
    var nativeCosmeticDocumentReady = false
    var lastManualAdSignature = ""
    var installedManualAdScriptSignature = ""
    private var hasAppliedCustomPageZoom = false
    let userScriptBridgeToken = UUID().uuidString
    var isStreamingDownloadHandlerInstalled: Bool = false
    var isDesktopModeEnabled: Bool = false
    private(set) var mediaFrameInfos: [WKFrameInfo] = []
    private var snapshotPersistenceID: String?
    private var snapshotGeneration = UUID()
    @Published private(set) var snapshotRevision = 0
    private var isLoadingSnapshot = false
    private var isCapturingSnapshot = false
    private var snapshotNeedsRefresh = false
    private var scheduledSnapshotTask: Task<Void, Never>?
    private var snapshotCompletions: [() -> Void] = []
    private var snapshotDocumentGeneration = UUID()
    private var allowsSnapshotPersistence = false
    private var memorySnapshotData: Data?
    private var pageLanguageDetectionID = UUID()

    // Download state
    @Published var isDownloading: Bool = false
    @Published var downloadFileName: String = ""
    @Published var activeDownloadCount: Int = 0
    private var nativeDownloadCount = 0
    private var nativeDownloadName = ""
    private var mediaDownloads: [URL: String] = [:]

    deinit {
        webView = nil
    }

    // MARK: - WebView Reference

    private var pendingRequest: URLRequest?
    private let historyTransition = WebHistoryTransition()

    var webView: WKWebView? {
        didSet {
            guard oldValue !== webView else { return }
            if webView == nil {
                isStreamingDownloadHandlerInstalled = false
            }
            guard let webView else { mediaSession.detach(); return }
            mediaSession.webView = webView
            if !mediaSession.isActive { webView.setAllMediaPlaybackSuspended(true, completionHandler: nil) }
            applyWebPreferences(to: webView)
            if let request = pendingRequest {
                pendingRequest = nil
                webView.load(request)
            } else if let url = currentURL {
                isLoading = true
                estimatedProgress = 0.0
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
                webView.load(request)
            }
        }
    }

    // MARK: - Navigation

    func loadURL(
        _ url: URL,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        keepSnapshotUntilLoaded: Bool = false
    ) {
        loadRequest(URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 30),
                    keepSnapshotUntilLoaded: keepSnapshotUntilLoaded)
    }

    func loadRequest(_ request: URLRequest, keepSnapshotUntilLoaded: Bool = false) {
        guard let url = request.url else { return }
        recordNavigationRequest(url)
        cancelScheduledSnapshot()
        historyTransition.cancel()
        resolveDomainNavigationConfirmation(allowed: false)
        BrowserStartupTrace.mark("load_requested", detail: webView == nil ? "pending" : "attached")
        errorMessage = nil
        if !keepSnapshotUntilLoaded { mediaSession.reset() }
        currentURL = url
        lastURLString = url.absoluteString
        isLoading = true
        hasVisibleContent = false
        estimatedProgress = 0.0
        showSnapshotWhileRestoring = keepSnapshotUntilLoaded && snapshot != nil

        guard let webView = webView else {
            pendingRequest = request
            return
        }

        webView.load(request)
    }

    @discardableResult
    func requestDomainNavigationConfirmation(from source: URL, to destination: URL,
                                             originalRequest: URLRequest? = nil,
                                             decision: @escaping (Bool) -> Void) -> UUID? {
        guard domainNavigationConfirmation == nil else { return nil }
        let request = WebDomainNavigationConfirmation(sourceURL: source, destinationURL: destination, originalRequest: originalRequest)
        domainNavigationDecision = decision
        domainNavigationConfirmation = request
        return request.id
    }

    func resolveDomainNavigationConfirmation(id: UUID? = nil, allowed: Bool) {
        guard let request = domainNavigationConfirmation, id == nil || id == request.id else { return }
        let decision = domainNavigationDecision
        domainNavigationDecision = nil
        domainNavigationConfirmation = nil
        decision?(allowed)
    }

    func setDesktopModeEnabled(_ enabled: Bool) {
        isDesktopModeEnabled = enabled
        if let webView {
            applyWebPreferences(to: webView)
        }
    }

    @discardableResult
    func setUserAgentOverride(_ value: String?) -> Bool {
        if let value, !Self.isValidUserAgent(value) { return false }
        userAgentOverride = value?.trimmingCharacters(in: .whitespaces)
        if let webView { applyWebPreferences(to: webView) }
        return true
    }

    static func isValidUserAgent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty && value.utf8.count <= 1024
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    func applyWebPreferences(to webView: WKWebView) {
        let userAgent = userAgentOverride ?? (isDesktopModeEnabled
            ? AppConstants.desktopWebViewUserAgent
            : AppConstants.mobileWebViewUserAgent)
        if webView.customUserAgent != userAgent {
            webView.customUserAgent = userAgent
        }
        let contentMode: WKWebpagePreferences.ContentMode = isDesktopModeEnabled ? .desktop : .mobile
        if webView.configuration.defaultWebpagePreferences.preferredContentMode != contentMode {
            webView.configuration.defaultWebpagePreferences.preferredContentMode = contentMode
        }
        applyPageZoom(to: webView)
    }

    func decreasePageZoom() {
        setPageZoom(pageZoom - 0.1)
    }

    func increasePageZoom() {
        setPageZoom(pageZoom + 0.1)
    }

    func resetPageZoom() {
        setPageZoom(1)
    }

    func setPageZoom(_ value: CGFloat) {
        let normalized = min(max((value * 10).rounded() / 10, 0.5), 2)
        pageZoom = normalized
        if let webView {
            applyPageZoom(to: webView)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Preserve the web view's physical viewport width while scaling its
    /// contents. Native pageZoom alone can let the document root grow past the
    /// right edge on mobile pages, so compensate the root width inversely.
    func applyPageZoom(to webView: WKWebView) {
        if webView.pageZoom != pageZoom {
            webView.pageZoom = pageZoom
        }
        if pageZoom != 1 { hasAppliedCustomPageZoom = true }
        // Keep the compatibility reset after a user has zoomed, including
        // restored history documents. Ordinary 100% pages need no DOM writes.
        guard hasAppliedCustomPageZoom else { return }
        webView.evaluateJavaScript(
            WebViewScripts.compensatePageZoomWidth(scale: pageZoom),
            completionHandler: nil
        )
    }

    func loadCachedURL(_ url: URL) {
        loadURL(url, cachePolicy: .returnCacheDataElseLoad, keepSnapshotUntilLoaded: true)
    }

    func goBack() {
        guard canGoBack else { return }
        resolveDomainNavigationConfirmation(allowed: false)
        guard let webView else { return }
        errorMessage = nil
        updateCurrentURL(webView.url)
        historyTransition.goBack(in: webView)
    }

    func willNavigateHistory(in webView: WKWebView, isMainFrame: Bool, frameURL: URL?) {
        historyTransition.willNavigateHistory(in: webView, isMainFrame: isMainFrame, frameURL: frameURL)
    }

    func historyFrameDidShow(in webView: WKWebView, url: URL?, isHistoryTraversal: Bool) {
        historyTransition.frameDidShow(in: webView, url: url, isHistoryTraversal: isHistoryTraversal)
    }

    func cancelBackwardTraversal() {
        historyTransition.cancelBackwardTraversal()
    }

    func recordDocumentInteraction(in webView: WKWebView) {
        currentDocumentHasUserInteraction = true
        historyTransition.recordInteraction(in: webView)
    }

    func recordAutomaticRedirect(in webView: WKWebView) {
        historyTransition.recordAutomaticRedirect(in: webView)
    }

    func historyTargetSkippingAutomaticRedirects(to url: URL, from source: URL?, in webView: WKWebView) -> WKBackForwardListItem? {
        historyTransition.targetSkippingAutomaticRedirects(to: url, from: source, in: webView)
    }

    func goForward() {
        guard canGoForward else { return }
        resolveDomainNavigationConfirmation(allowed: false)
        guard let webView else { return }
        errorMessage = nil
        updateCurrentURL(webView.url)
        historyTransition.goForward(in: webView)
    }

    func reload() {
        if errorMessage != nil { retryCurrentPage(); return }
        historyTransition.cancel()
        resolveDomainNavigationConfirmation(allowed: false)
        if isLoading {
            pendingRequest = nil
            webView?.stopLoading()
            webView?.scrollView.refreshControl?.endRefreshing()
            // Explicit cancellation must dismiss the restoration snapshot even
            // when WebKit has no loading-state transition left to deliver.
            updateLoading(false)
        } else {
            webView?.reload()
        }
    }

    func synchronizePageViewport() {
        guard let webView else { return }
        webView.setNeedsLayout()
        webView.scrollView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.scrollView.layoutIfNeeded()
        if WebCompatibilityService.isDouyinVideoSurface(webView.url) {
            webView.evaluateJavaScript(WebViewScripts.synchronizeViewport, completionHandler: nil)
        }
    }

    func retryCurrentPage() {
        guard let destination = errorMessage != nil ? errorPageURL : currentURL else { return }
        loadURL(destination, cachePolicy: .reloadRevalidatingCacheData)
    }

    /// Releases the expensive WebKit runtime while preserving the tab URL and snapshot.
    /// The view is recreated lazily the next time the tab becomes active.
    func releaseWebViewRuntime() {
        hasPresentedContent = false
        clearVideoHoldSpeed()
        cancelScheduledSnapshot()
        historyTransition.cancel()
        resolveDomainNavigationConfirmation(allowed: false)
        hasBottomVideoControls = false
        cancelMarkingAdvertisement()
        webView?.stopLoading()
        WebViewRepresentable.forgetContentRules(on: webView)
        webView = nil
        mediaFrameInfos.removeAll()
        pendingRequest = nil
        isWebViewRuntimeInstalled = false
        hasInstalledWebViewScripts = false
        hasAppliedCustomPageZoom = false
        lastAdHidingSignature = ""
        installedPrivacyProtectionSource = ""
        adHidingNeedsBootstrap = false
        nativeCosmeticDocumentReady = false
        lastManualAdSignature = ""
        installedManualAdScriptSignature = ""
        hasVisibleContent = false
        isLoading = false
        estimatedProgress = currentURL == nil ? 0 : 1
        showSnapshotWhileRestoring = false
    }

    /// Recreates WebKit so document-start UserScripts and their permissions are
    /// rebuilt before the next navigation, while preserving the current page.
    func rebuildWebViewRuntime() {
        hasPresentedContent = false
        cancelScheduledSnapshot()
        historyTransition.cancel()
        resolveDomainNavigationConfirmation(allowed: false)
        cancelMarkingAdvertisement()
        webView?.stopLoading()
        WebViewRepresentable.forgetContentRules(on: webView)
        webView = nil
        mediaFrameInfos.removeAll()
        pendingRequest = nil
        isWebViewRuntimeInstalled = false
        hasInstalledWebViewScripts = false
        hasAppliedCustomPageZoom = false
        lastAdHidingSignature = ""
        installedPrivacyProtectionSource = ""
        adHidingNeedsBootstrap = false
        nativeCosmeticDocumentReady = false
        lastManualAdSignature = ""
        installedManualAdScriptSignature = ""
        hasVisibleContent = false
        runtimeRevision = UUID()
        if currentURL != nil {
            isLoading = true
            estimatedProgress = 0
            showSnapshotWhileRestoring = snapshot != nil
        }
    }

    func registerUserScriptMenuCommand(
        id: String,
        scriptID: UUID,
        scriptName: String,
        title: String
    ) {
        let command = UserScriptMenuCommand(
            id: id,
            scriptID: scriptID,
            scriptName: scriptName,
            title: title
        )
        if let index = userScriptMenuCommands.firstIndex(where: {
            $0.id == id && $0.scriptID == scriptID
        }) {
            userScriptMenuCommands[index] = command
        } else {
            userScriptMenuCommands.append(command)
        }
    }

    func unregisterUserScriptMenuCommand(id: String, scriptID: UUID) {
        userScriptMenuCommands.removeAll { $0.id == id && $0.scriptID == scriptID }
    }

    func clearUserScriptMenuCommands() {
        userScriptMenuCommands.removeAll()
    }

    func executeUserScriptMenuCommand(_ command: UserScriptMenuCommand) {
        guard userScriptMenuCommands.contains(command), let webView else { return }
        let commandID = command.id.escapedForJS
        webView.evaluateJavaScript(
            "window.__souloDispatchUserScriptMenuCommand && window.__souloDispatchUserScriptMenuCommand('\(commandID)')",
            completionHandler: nil
        )
    }

    func loadSearchURL(keyword: String, platform: SearchPlatform) {
        guard let url = platform.searchURL(for: keyword) else {
            errorMessage = "Could not construct search URL for \(platform.name)."
            return
        }
        loadURL(url)
    }

    // MARK: - State Sync (called from Coordinator / KVO)

    func updateProgress(_ progress: Double) {
        if estimatedProgress != progress { estimatedProgress = progress }
        if progress >= 0.999, isLoading {
            updateLoading(false)
        }
    }

    func updateLoading(_ loading: Bool) {
        if isLoading != loading { isLoading = loading }
        if !loading {
            if estimatedProgress != 1 { estimatedProgress = 1 }
            if showSnapshotWhileRestoring { showSnapshotWhileRestoring = false }
        }
    }

    func updateCanGoBack(_ value: Bool) { if canGoBack != value { canGoBack = value } }
    func updateCanGoForward(_ value: Bool) { if canGoForward != value { canGoForward = value } }

    func updateDownloadState(activeCount: Int, fileName: String? = nil) {
        nativeDownloadCount = max(0, activeCount)
        if let fileName { nativeDownloadName = fileName }
        if nativeDownloadCount == 0 { nativeDownloadName = "" }
        refreshDownloadState()
    }

    @discardableResult
    func beginMediaDownload(url: URL, name: String) -> Bool {
        guard mediaDownloads[url] == nil else { return false }
        mediaDownloads[url] = name.isEmpty ? url.lastPathComponent : name
        refreshDownloadState()
        return true
    }

    func finishMediaDownload(url: URL) {
        guard mediaDownloads.removeValue(forKey: url) != nil else { return }
        refreshDownloadState()
    }

    private func refreshDownloadState() {
        activeDownloadCount = nativeDownloadCount + mediaDownloads.count
        isDownloading = activeDownloadCount > 0
        downloadFileName = mediaDownloads.values.first ?? nativeDownloadName
    }

    func beginPageNavigation() {
        clearVideoHoldSpeed()
        cancelScheduledSnapshot()
        snapshotDocumentGeneration = UUID()
        if hasBottomVideoControls { hasBottomVideoControls = false }
        if episodeList != nil { episodeList = nil }
        if hasVisibleContent { hasVisibleContent = false }
        mediaFrameInfos.removeAll()
    }

    func registerMediaFrame(_ frame: WKFrameInfo) {
        guard !frame.isMainFrame else { return }
        if mediaFrameInfos.count >= 16 { mediaFrameInfos.removeFirst() }
        mediaFrameInfos.append(frame)
    }

    func updateVideoHoldSpeed(_ rate: Double, token: String) {
        guard rate.isFinite, (0.25...16).contains(rate), !token.isEmpty, token.count <= 80 else { return }
        videoHoldSpeedToken = token
        if videoHoldSpeed != rate { videoHoldSpeed = rate }
        scheduleVideoHoldSpeedDismissal(after: .seconds(2), token: token)
    }

    func endVideoHoldSpeed(token: String, restoredRate: Double) {
        guard videoHoldSpeedToken == token else { return }
        if restoredRate.isFinite, (0.25...16).contains(restoredRate) { videoHoldSpeed = restoredRate }
        scheduleVideoHoldSpeedDismissal(after: .milliseconds(1500), token: token)
    }

    func clearVideoHoldSpeed() {
        videoHoldSpeedDismissal?.cancel()
        videoHoldSpeedDismissal = nil
        videoHoldSpeedToken = nil
        if videoHoldSpeed != nil { videoHoldSpeed = nil }
    }

    private func scheduleVideoHoldSpeedDismissal(after delay: Duration, token: String) {
        videoHoldSpeedDismissal?.cancel()
        videoHoldSpeedDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.videoHoldSpeedToken == token else { return }
            self.clearVideoHoldSpeed()
        }
    }

    func markPageContentVisible() {
        if showSnapshotWhileRestoring { showSnapshotWhileRestoring = false }
        guard !hasVisibleContent else { return }
        if !hasPresentedContent { hasPresentedContent = true }
        BrowserStartupTrace.mark("content_visible")
        hasVisibleContent = true
        // A visible page can keep loading ads/images indefinitely. Save its
        // first painted content without waiting for WebKit's load event.
        scheduleSnapshotCapture()
    }

    func updateTitle(_ title: String?) {
        let value = title ?? ""
        if pageTitle != value { pageTitle = value }
    }

    func updateCurrentURL(_ url: URL?, fromObservation: Bool = false) {
        guard let url = url else { return }
        if errorMessage != nil, let failedNavigationURL, url != failedNavigationURL { return }
        if fromObservation, isLoading, let requestedNavigationURL, url != requestedNavigationURL { return }
        if currentURL != url { currentURL = url }
        lastURLString = url.absoluteString
        if !isLoading, errorMessage == nil {
            requestedNavigationURL = url
            if failedNavigationURL != nil { failedNavigationURL = nil }
        }
    }

    func recordNavigationRequest(_ url: URL) {
        requestedNavigationURL = url
        if failedNavigationURL != nil { failedNavigationURL = nil }
        if errorMessage != nil { errorMessage = nil }
        if currentURL != url { currentURL = url }
        lastURLString = url.absoluteString
    }

    func resetPageTranslationState() {
        pageLanguageDetectionID = UUID()
        pageLanguageIdentifier = nil
        isPageTranslationApplied = false
    }

    func updatePageTranslationApplied(_ applied: Bool) {
        isPageTranslationApplied = applied
    }

    func pageDidFinishLoading() {
        pageRevision += 1
    }

    func enableAppleFollowLinkTranslation(source: Locale.Language, target: Locale.Language) {
        followLinkTranslation = FollowLinkTranslation(
            sourceIdentifier: source.minimalIdentifier,
            targetIdentifier: target.minimalIdentifier,
            startAfterPageRevision: pageRevision
        )
        googleFollowLinkTarget = nil
        isPageTranslationApplied = true
    }

    func enableGoogleFollowLinkTranslation(target: String) {
        googleFollowLinkTarget = target
        followLinkTranslation = nil
    }

    func disableFollowLinkTranslation() {
        followLinkTranslation = nil
        googleFollowLinkTarget = nil
    }

    /// Detects the primary language from a bounded DOM text sample. Keeping the
    /// sample small avoids a full-page layout/read on large, dynamic websites.
    func refreshPageTranslationState() async {
        guard let webView,
              let pageURL = webView.url,
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else {
            resetPageTranslationState()
            return
        }

        let detectionID = UUID()
        pageLanguageDetectionID = detectionID
        let expectedURL = pageURL.absoluteString
        let script = #"""
        (function() {
            var root = document.documentElement;
            var walker = document.createTreeWalker(document.body || root, NodeFilter.SHOW_TEXT);
            var parts = [];
            var length = 0;
            var scanned = 0;
            var node;
            while ((node = walker.nextNode()) && scanned < 1200 && length < 16000) {
                scanned += 1;
                var parent = node.parentElement;
                if (!parent || parent.closest('script,style,noscript,textarea,code,pre,svg,canvas,[aria-hidden="true"]')) continue;
                var text = (node.nodeValue || '').replace(/\s+/g, ' ').trim();
                if (text.length < 2) continue;
                var remaining = 16000 - length;
                parts.push(text.slice(0, remaining));
                length += Math.min(text.length, remaining);
            }
            return {
                url: location.href,
                declaredLanguage: (root && root.lang) || '',
                sample: parts.join('\n'),
                translated: Boolean(window.__souloPageTranslation && window.__souloPageTranslation.isTranslated)
            };
        })();
        """#

        do {
            let value = try await webView.evaluateJavaScript(script)
            guard pageLanguageDetectionID == detectionID,
                  webView.url?.absoluteString == expectedURL,
                  let result = value as? [String: Any],
                  (result["url"] as? String) == expectedURL else { return }

            let sample = result["sample"] as? String ?? ""
            let declaredLanguage = (result["declaredLanguage"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let letterCount = sample.unicodeScalars.reduce(into: 0) { count, scalar in
                if CharacterSet.letters.contains(scalar) { count += 1 }
            }
            let detectedLanguage: String?
            if letterCount >= 20,
               let language = NLLanguageRecognizer.dominantLanguage(for: sample),
               language != .undetermined {
                detectedLanguage = language.rawValue
            } else if !declaredLanguage.isEmpty {
                detectedLanguage = declaredLanguage
            } else {
                detectedLanguage = nil
            }

            pageLanguageIdentifier = detectedLanguage
            isPageTranslationApplied = result["translated"] as? Bool ?? false
        } catch {
            guard pageLanguageDetectionID == detectionID else { return }
            pageLanguageIdentifier = nil
            isPageTranslationApplied = false
        }
    }

    func setError(_ message: String, failingURL: URL? = nil) {
        failedNavigationURL = failingURL ?? requestedNavigationURL ?? currentURL
        if let failedNavigationURL {
            currentURL = failedNavigationURL
            lastURLString = failedNavigationURL.absoluteString
        }
        errorMessage = message
        isLoading = false
        showSnapshotWhileRestoring = false
        takeSnapshot()
    }

    // MARK: - Snapshot

    func configureSnapshotPersistence(id: UUID) {
        snapshotPersistenceID = id.uuidString
        allowsSnapshotPersistence = !UserDefaults.standard.bool(forKey: "is_incognito")
    }

    /// Decode only the visible cards. Private tabs use compressed memory data;
    /// normal tabs keep durable previews independently of WebKit and its cache.
    func loadSnapshotIfNeeded(forRestoration: Bool = false) async {
        guard !Task.isCancelled, snapshot == nil, !isLoadingSnapshot, let id = snapshotPersistenceID else { return }
        isLoadingSnapshot = true
        let generation = snapshotGeneration
        let url = currentURL
        while true {
            let revision = snapshotRevision
            let memoryData = memorySnapshotData
            let canReadDisk = allowsSnapshotPersistence
            let image = await withCheckedContinuation { continuation in
                Self.snapshotWriteQueue.async {
                    continuation.resume(returning: memoryData.flatMap(UIImage.init(data:))
                        ?? (canReadDisk ? Self.loadSnapshot(id: id) : nil))
                }
            }
            guard snapshotGeneration == generation else { return }
            // A capture can finish while this read is still pending. Its
            // durable write is queued before the revision changes; re-read
            // instead of publishing an earlier cache miss or stale preview.
            if snapshotRevision != revision { continue }
            isLoadingSnapshot = false
            // A different preview can join this read while its initiating SwiftUI
            // task disappears during a layout switch. The generation owns eviction;
            // cancellation of one view must not discard the shared image read.
            guard snapshot == nil, snapshotPersistenceID == id else { return }
            snapshot = image
            if forRestoration, currentURL == url, isLoading, !hasVisibleContent, mediaSession.isActive {
                showSnapshotWhileRestoring = image != nil
            }
            return
        }
    }

    func releaseSnapshotMemory() {
        guard snapshot != nil || isLoadingSnapshot || isCapturingSnapshot else { return }
        snapshotGeneration = UUID()
        snapshotRevision &+= 1
        isLoadingSnapshot = false
        snapshot = nil
        showSnapshotWhileRestoring = false
        // An in-flight capture may still finish saving the compressed preview.
        // Evicting the decoded bitmap must not cancel the only copy of a tab.
    }

    func captureSnapshot() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            takeSnapshot { continuation.resume() }
        }
    }

    func scheduleSnapshotCapture() {
        cancelScheduledSnapshot()
        let document = snapshotDocumentGeneration
        let url = currentURL
        scheduledSnapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.snapshotDocumentGeneration == document, self.currentURL == url else { return }
            self.scheduledSnapshotTask = nil
            self.takeSnapshot()
        }
    }

    private func cancelScheduledSnapshot() {
        scheduledSnapshotTask?.cancel()
        scheduledSnapshotTask = nil
    }

    func takeSnapshot(completion: (() -> Void)? = nil) {
        cancelScheduledSnapshot()
        if let completion { snapshotCompletions.append(completion) }
        guard !isCapturingSnapshot else { snapshotNeedsRefresh = true; return }
        if let errorMessage, !errorMessage.isEmpty, currentURL != nil {
            let size = webView.flatMap { $0.bounds.width > 1 && $0.bounds.height > 1 ? $0.bounds.size : nil }
                ?? CGSize(width: 390, height: 700)
            let renderer = ImageRenderer(content: BrowserLoadErrorView(
                message: errorMessage, url: errorPageURL, onRetry: {}, onGoHome: nil, onOpenCompatibility: nil)
                .content
                .frame(width: size.width, height: size.height)
                .background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, webView?.traitCollection.userInterfaceStyle == .dark ? .dark : .light))
            renderer.scale = 1
            guard let image = renderer.uiImage else { finishSnapshotCapture(); return }
            isCapturingSnapshot = true
            saveCapturedSnapshot(image, from: webView, generation: snapshotGeneration, error: errorMessage, warm: false)
            return
        }
        guard let webView, webView.window != nil, webView.bounds.width > 1, webView.bounds.height > 1,
              currentURL != nil, webView.url == currentURL, !showSnapshotWhileRestoring,
              hasVisibleContent || (!hasInstalledWebViewScripts && !webView.isLoading) else {
            finishSnapshotCapture()
            return
        }
        isCapturingSnapshot = true
        let config = WKSnapshotConfiguration()
        let generation = snapshotGeneration
        let documentGeneration = snapshotDocumentGeneration
        let pageURL = currentURL
        let persistenceID = snapshotPersistenceID
        let warm = WebAppearanceService.hasWarmOverlay(on: webView)
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: 430)
        config.afterScreenUpdates = false
        // Request pixels synchronously, before switching detaches this WebView.
        webView.takeSnapshot(with: config) { [weak self, weak webView] image, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let image, let webView, self.webView === webView,
                      self.snapshotDocumentGeneration == documentGeneration,
                      self.currentURL == pageURL, self.snapshotPersistenceID == persistenceID,
                      self.errorMessage == nil else {
                    self.finishSnapshotCapture(); return
                }
                self.saveCapturedSnapshot(image, from: webView, generation: generation, error: nil, warm: warm)
            }
        }
    }

    private func saveCapturedSnapshot(_ image: UIImage, from webView: WKWebView?, generation: UUID, error: String?, warm: Bool) {
        let document = snapshotDocumentGeneration
        let url = currentURL
        let id = snapshotPersistenceID
        let canPersist = allowsSnapshotPersistence && (webView?.configuration.websiteDataStore.isPersistent ?? true)
        Task { @MainActor [weak self, weak webView] in
            let data = await withCheckedContinuation { continuation in
                Self.snapshotWriteQueue.async {
                    continuation.resume(returning: Self.previewData(image, warm: warm))
                }
            }
            guard let self else { return }
            guard let data, self.webView === webView, self.snapshotDocumentGeneration == document,
                  self.currentURL == url, self.snapshotPersistenceID == id, self.errorMessage == error else {
                self.finishSnapshotCapture(); return
            }
            if !canPersist { self.memorySnapshotData = data }
            if self.snapshotGeneration == generation { self.snapshot = UIImage(data: data) }
            if canPersist, let id { self.persistSnapshot(data, id: id) }
            if self.snapshotGeneration != generation { self.snapshotRevision &+= 1 }
            self.finishSnapshotCapture()
        }
    }

    private func finishSnapshotCapture() {
        isCapturingSnapshot = false
        if snapshotNeedsRefresh {
            snapshotNeedsRefresh = false
            takeSnapshot()
            return
        }
        let completions = snapshotCompletions
        snapshotCompletions.removeAll()
        completions.forEach { $0() }
    }

    func deletePersistedSnapshot() {
        snapshotGeneration = UUID()
        memorySnapshotData = nil
        snapshot = nil
        guard let id = snapshotPersistenceID else { return }
        snapshotPersistenceID = nil
        Self.snapshotWriteQueue.async {
            try? FileManager.default.removeItem(at: Self.snapshotURL(id: id))
            try? FileManager.default.removeItem(at: Self.legacySnapshotURL(id: id))
        }
    }

    static func deleteAllPersistedSnapshots() {
        snapshotWriteQueue.async {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            try? FileManager.default.removeItem(at: legacySnapshotDirectory)
        }
    }

    private func persistSnapshot(_ data: Data, id: String) {
        Self.snapshotWriteQueue.async {
            var directory = Self.snapshotDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            try? data.write(to: Self.snapshotURL(id: id), options: .atomic)
        }
    }

    nonisolated private static func previewData(_ image: UIImage, warm: Bool) -> Data? {
        autoreleasepool {
            let width = image.size.width * image.scale
            let height = image.size.height * image.scale
            let scale = min(1, 640 / max(1, width), 1_600 / max(1, height))
            let size = CGSize(width: width * scale, height: height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let preview = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
                if warm {
                    UIColor(red: 1, green: 154.0 / 255, blue: 61.0 / 255, alpha: 0.055).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
            }
            return preview.jpegData(compressionQuality: 0.82)
        }
    }

    private static let snapshotWriteQueue = DispatchQueue(label: "com.dkluge.Soulo.tab-snapshots", qos: .utility)

    nonisolated private static func loadSnapshot(id: String) -> UIImage? {
        let url = snapshotURL(id: id)
        if let image = UIImage(contentsOfFile: url.path) { return image }
        let legacy = legacySnapshotURL(id: id)
        guard let image = UIImage(contentsOfFile: legacy.path) else { return nil }
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: legacy, to: url)
        return image
    }

    nonisolated private static var snapshotDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SouloTabSnapshots", isDirectory: true)
    }

    nonisolated private static var legacySnapshotDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SouloTabSnapshots", isDirectory: true)
    }

    nonisolated private static func legacySnapshotURL(id: String) -> URL {
        legacySnapshotDirectory.appendingPathComponent("\(id).jpg")
    }

    nonisolated private static func snapshotURL(id: String) -> URL {
        snapshotDirectory.appendingPathComponent("\(id).jpg")
    }
}
