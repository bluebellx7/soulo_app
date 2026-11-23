import Combine
import UIKit
import WebKit

/// WebKit owns Blob/data decoding and file I/O. No media payload crosses a
/// JavaScript/native message or remains tied to the extension popup lifetime.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionURLDownload: NSObject, WKDownloadDelegate, WKNavigationDelegate {
    let id = UUID()
    private(set) var itemID: UUID?
    private let url: URL
    private let filename: String?
    private var item: BrowserDownloadItem?
    private var helper: WKWebView?
    private var container: UIView?
    private var download: WKDownload?
    private var progress: AnyCancellable?
    private var deadline: Task<Void, Never>?
    private var accepted: ((BrowserDownloadItem) -> Void)?
    private var rejected: ((Error) -> Void)?
    private var ended: (() -> Void)?
    private var finished = false
    private var started = false
    private var expectedBytes: Int64 = -1
    private var temporaryDestination: URL?
    private var temporaryByteLimit: Int64?
    var retainedTemporaryFileURL: URL? { temporaryDestination }
    private var temporaryCompletion: ((URL, String, Int64) -> Void)?
    private var mimeType = "application/octet-stream"

    init(url: URL, filename: String?, accepted: @escaping (BrowserDownloadItem) -> Void,
         rejected: @escaping (Error) -> Void, ended: @escaping () -> Void) {
        self.url = url; self.filename = filename
        self.accepted = accepted; self.rejected = rejected; self.ended = ended
        super.init()
    }

    convenience init(temporaryDestination: URL, url: URL, byteLimit: Int64? = nil,
                     completed: @escaping (URL, String, Int64) -> Void,
                     rejected: @escaping (Error) -> Void, ended: @escaping () -> Void) {
        self.init(url: url, filename: nil, accepted: { _ in }, rejected: rejected, ended: ended)
        self.temporaryDestination = temporaryDestination
        self.temporaryByteLimit = byteLimit
        self.temporaryCompletion = completed
    }

    func start(context: WKWebExtensionContext, source: WKWebView?) {
        BrowserStartupTrace.mark("extension_download_transport", detail: "scheme=\(url.scheme ?? "");source=\(source != nil)")
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finish(error: URLError(.timedOut))
        }
        // A page-owned Blob must use that page's existing partition. Extension
        // Blobs can also originate in background/offscreen documents: a small
        // document in the same extension origin gives WebKit the right origin.
        if let source, Self.sameOrigin(source.url, blob: url) {
            BrowserStartupTrace.mark("extension_download_partition", detail: "original")
            begin(in: source)
            return
        }
        guard let configuration = context.webViewConfiguration else {
            finish(error: URLError(.cannotOpenFile)); return
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        BrowserStartupTrace.mark("extension_download_partition", detail: "helper")
        view.navigationDelegate = self
        helper = view
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) {
            let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            host.isUserInteractionEnabled = false; host.accessibilityElementsHidden = true
            host.alpha = 0.01; host.clipsToBounds = true
            host.addSubview(view); window.insertSubview(host, at: 0); container = host
        }
        view.load(URLRequest(url: context.baseURL.appendingPathComponent(WebExtensionDownloadsScript.helperFilename)))
    }

    private static func sameOrigin(_ page: URL?, blob: URL) -> Bool {
        if blob.scheme == "data" { return page != nil }
        guard blob.scheme == "blob", let origin = URL(string: String(blob.absoluteString.dropFirst(5))), let page else { return false }
        return page.scheme == origin.scheme && page.host == origin.host && page.port == origin.port
    }

    private func begin(in view: WKWebView) {
        guard !started, !finished else { return }
        started = true
        view.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self, !self.finished else { download.cancel(nil); return }
            self.download = download
            download.delegate = self
            self.progress = download.progress.publisher(for: \.completedUnitCount)
                .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in Task { @MainActor in self?.updateProgress() } }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !finished else { completionHandler(nil); return }
        expectedBytes = response.expectedContentLength
        BrowserStartupTrace.mark("extension_download_destination", detail: "bytes=\(expectedBytes)")
        if let temporaryDestination {
            if let temporaryByteLimit, expectedBytes < 0 || expectedBytes > temporaryByteLimit {
                completionHandler(nil)
                finish(error: URLError(.dataLengthExceedsMaximum))
                return
            }
            mimeType = response.mimeType ?? mimeType
            deadline?.cancel(); deadline = nil
            completionHandler(temporaryDestination)
            return
        }
        // Do not persist potentially huge data: URLs in download history.
        let historyURL = url.scheme == "data" ? URL(string: "data:" + (response.mimeType ?? "application/octet-stream")) : url
        let (created, destination) = DownloadManagerService.shared.beginDownload(
            suggestedFilename: filename.flatMap { $0.isEmpty ? nil : $0 } ?? suggestedFilename,
            sourceURL: historyURL, transport: .webKit)
        item = created; itemID = created.id
        deadline?.cancel(); deadline = nil
        let ready = accepted; accepted = nil; rejected = nil
        ready?(created)
        completionHandler(destination)
    }

    private func updateProgress() {
        guard !finished, let itemID, let download else { return }
        DownloadManagerService.shared.updateProgress(id: itemID,
            completed: max(0, download.progress.completedUnitCount),
            total: max(expectedBytes, download.progress.totalUnitCount))
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !finished else { return }
        do {
            if let temporaryDestination {
                let bytes = try temporaryDestination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard expectedBytes < 0 || Int64(bytes) == expectedBytes else { throw URLError(.cannotDecodeContentData) }
                finished = true
                temporaryCompletion?(temporaryDestination, mimeType, Int64(bytes))
                temporaryCompletion = nil; accepted = nil; rejected = nil
                cleanup(); return
            }
            guard let item else { return }
            guard DownloadManagerService.shared.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }) else {
                cancel(); return
            }
            let bytes = try item.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard expectedBytes < 0 || Int64(bytes) == expectedBytes else { throw URLError(.cannotDecodeContentData) }
            finished = true
            DownloadManagerService.shared.updateProgress(id: item.id, completed: Int64(bytes), total: Int64(bytes))
            DownloadManagerService.shared.markFinished(id: item.id)
            cleanup()
        } catch { finish(error: error) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { finish(error: error) }

    func cancel() {
        guard !finished else { return }
        finished = true
        download?.cancel(nil)
        if let item, DownloadManagerService.shared.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }) {
            DownloadManagerService.shared.markCanceled(id: item.id)
        }
        if let item { try? FileManager.default.removeItem(at: item.localURL) }
        if let temporaryDestination { try? FileManager.default.removeItem(at: temporaryDestination) }
        temporaryCompletion = nil
        let failure = rejected; accepted = nil; rejected = nil
        failure?(URLError(.cancelled))
        cleanup()
    }

    private func finish(error: Error) {
        guard !finished else { return }
        finished = true
        download?.cancel(nil)
        if let temporaryDestination { try? FileManager.default.removeItem(at: temporaryDestination) }
        temporaryCompletion = nil
        if let item, DownloadManagerService.shared.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }) {
            DownloadManagerService.shared.markFailed(id: item.id, error: error)
        }
        let failure = rejected; accepted = nil; rejected = nil
        failure?(error)
        cleanup()
    }

    private func cleanup() {
        deadline?.cancel(); deadline = nil; progress = nil
        download?.delegate = nil; download = nil
        helper?.navigationDelegate = nil; helper?.stopLoading(); helper = nil
        container?.removeFromSuperview(); container = nil
        let completion = ended; ended = nil; completion?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { begin(in: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if download == nil { finish(error: URLError(.networkConnectionLost)) }
    }
}
