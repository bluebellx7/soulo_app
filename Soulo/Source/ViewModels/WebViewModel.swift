import UIKit
import WebKit
import Combine
import NaturalLanguage

struct UserScriptMenuCommand: Identifiable, Equatable {
    let id: String
    let scriptID: UUID
    let scriptName: String
    let title: String
}

@MainActor
final class WebViewModel: ObservableObject {

    // MARK: - Published State

    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    var lastURLString: String = ""
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var errorMessage: String?
    @Published var isScrollingUp: Bool = false
    @Published var snapshot: UIImage?
    @Published var showSnapshotWhileRestoring: Bool = false
    @Published private(set) var pageZoom: CGFloat = 1
    @Published private(set) var pageLanguageIdentifier: String?
    @Published private(set) var isPageTranslationApplied = false
    @Published private(set) var runtimeRevision = UUID()
    @Published private(set) var userScriptMenuCommands: [UserScriptMenuCommand] = []
    var isWebViewRuntimeInstalled: Bool = false
    var isStreamingDownloadHandlerInstalled: Bool = false
    var isDesktopModeEnabled: Bool = false
    private var snapshotPersistenceID: String?
    private var pageLanguageDetectionID = UUID()

    // Download state
    @Published var isDownloading: Bool = false
    @Published var downloadFileName: String = ""
    @Published var activeDownloadCount: Int = 0

    deinit {
        webView = nil
    }

    // MARK: - WebView Reference

    private var pendingRequest: URLRequest?

    var webView: WKWebView? {
        didSet {
            guard oldValue !== webView else { return }
            if webView == nil {
                isStreamingDownloadHandlerInstalled = false
            }
            guard let webView else { return }
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
        errorMessage = nil
        currentURL = url
        lastURLString = url.absoluteString
        isLoading = true
        estimatedProgress = 0.0
        showSnapshotWhileRestoring = keepSnapshotUntilLoaded && snapshot != nil
        let request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: 30)

        guard let webView = webView else {
            pendingRequest = request
            return
        }

        webView.load(request)
    }

    func setDesktopModeEnabled(_ enabled: Bool) {
        isDesktopModeEnabled = enabled
        if let webView {
            applyWebPreferences(to: webView)
        }
    }

    func applyWebPreferences(to webView: WKWebView) {
        webView.customUserAgent = isDesktopModeEnabled
            ? AppConstants.desktopWebViewUserAgent
            : AppConstants.mobileWebViewUserAgent
        webView.configuration.defaultWebpagePreferences.preferredContentMode = isDesktopModeEnabled
            ? .desktop
            : .mobile
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
        webView.pageZoom = pageZoom
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

    func synchronizePageViewport() {
        guard let webView else { return }
        webView.setNeedsLayout()
        webView.scrollView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.scrollView.layoutIfNeeded()
        webView.evaluateJavaScript(WebViewScripts.synchronizeViewport, completionHandler: nil)
    }

    func retryCurrentPage() {
        guard let currentURL else { return }
        loadURL(currentURL, cachePolicy: .reloadRevalidatingCacheData)
    }

    /// Releases the expensive WebKit runtime while preserving the tab URL and snapshot.
    /// The view is recreated lazily the next time the tab becomes active.
    func releaseWebViewRuntime() {
        webView?.stopLoading()
        webView = nil
        pendingRequest = nil
        isWebViewRuntimeInstalled = false
        isLoading = false
        estimatedProgress = currentURL == nil ? 0 : 1
        showSnapshotWhileRestoring = false
    }

    /// Recreates WebKit so document-start UserScripts and their permissions are
    /// rebuilt before the next navigation, while preserving the current page.
    func rebuildWebViewRuntime() {
        webView?.stopLoading()
        webView = nil
        pendingRequest = nil
        isWebViewRuntimeInstalled = false
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
        estimatedProgress = progress
        if progress >= 0.999, isLoading {
            updateLoading(false)
        }
    }

    func updateLoading(_ loading: Bool) {
        isLoading = loading
        if !loading {
            estimatedProgress = 1.0
            showSnapshotWhileRestoring = false
        }
    }

    func updateCanGoBack(_ value: Bool) { canGoBack = value }
    func updateCanGoForward(_ value: Bool) { canGoForward = value }

    func updateDownloadState(activeCount: Int, fileName: String? = nil) {
        let normalizedCount = max(0, activeCount)
        activeDownloadCount = normalizedCount
        isDownloading = normalizedCount > 0
        if normalizedCount == 0 {
            downloadFileName = ""
        } else if let fileName, !fileName.isEmpty {
            downloadFileName = fileName
        }
    }

    func updateTitle(_ title: String?) {
        pageTitle = title ?? ""
    }

    func updateCurrentURL(_ url: URL?) {
        guard let url = url else { return }
        currentURL = url
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

    func setError(_ message: String) {
        errorMessage = message
        isLoading = false
        showSnapshotWhileRestoring = false
    }

    // MARK: - Snapshot

    func configureSnapshotPersistence(id: UUID) {
        snapshotPersistenceID = id.uuidString
        if snapshot == nil {
            snapshot = Self.loadSnapshot(id: id.uuidString)
        }
    }

    func takeSnapshot(completion: (() -> Void)? = nil) {
        guard let webView = webView else {
            completion?()
            return
        }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 430)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                if let image {
                    self?.snapshot = image
                    self?.persistSnapshot(image)
                }
                completion?()
            }
        }
    }

    func deletePersistedSnapshot() {
        guard let snapshotPersistenceID else { return }
        try? FileManager.default.removeItem(at: Self.snapshotURL(id: snapshotPersistenceID))
    }

    static func deleteAllPersistedSnapshots() {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }

    private func persistSnapshot(_ image: UIImage) {
        guard let snapshotPersistenceID,
              let data = image.jpegData(compressionQuality: 0.82) else { return }
        let directory = Self.snapshotDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.snapshotURL(id: snapshotPersistenceID), options: .atomic)
    }

    private static func loadSnapshot(id: String) -> UIImage? {
        UIImage(contentsOfFile: snapshotURL(id: id).path)
    }

    private static var snapshotDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SouloTabSnapshots", isDirectory: true)
    }

    private static func snapshotURL(id: String) -> URL {
        snapshotDirectory.appendingPathComponent("\(id).jpg")
    }
}
