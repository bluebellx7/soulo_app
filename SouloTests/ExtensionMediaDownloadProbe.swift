import WebKit
@testable import Soulo

@MainActor
final class ExtensionMediaDownloadProbe: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    let directory: URL
    private var active: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    var files: [URL] = []
    var errors: [String] = []

    init(directory: URL) { self.directory = directory; super.init() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(BrowserDownloadPolicy.shouldDownloadNavigationAction(requestedByPage: action.shouldPerformDownload, nativeRequest: false) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { attach(download) }

    private func attach(_ download: WKDownload) { active[ObjectIdentifier(download)] = download; download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let file = directory.appendingPathComponent(UUID().uuidString + "-" + DownloadFilenameSanitizer.sanitize(suggestedFilename))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destinations[ObjectIdentifier(download)] = file
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        if let file = destinations.removeValue(forKey: key) { files.append(file) }
        active.removeValue(forKey: key)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        errors.append(error.localizedDescription)
        if let file = destinations.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }
        active.removeValue(forKey: key)
    }
}
