import UIKit
import WebKit
import Combine

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
    private var snapshotPersistenceID: String?

    // Download state
    @Published var isDownloading: Bool = false
    @Published var downloadFileName: String = ""

    deinit {
        webView = nil
    }

    // MARK: - WebView Reference

    private var pendingRequest: URLRequest?

    var webView: WKWebView? {
        didSet {
            guard webView != nil else { return }
            if let request = pendingRequest {
                pendingRequest = nil
                webView?.load(request)
            } else if let url = currentURL {
                isLoading = true
                estimatedProgress = 0.0
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
                webView?.load(request)
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

    func updateTitle(_ title: String?) {
        pageTitle = title ?? ""
    }

    func updateCurrentURL(_ url: URL?) {
        guard let url = url else { return }
        currentURL = url
        lastURLString = url.absoluteString
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
