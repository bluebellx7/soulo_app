import Foundation
import AVFoundation
import MobileVLCKit
import WebKit

/// Web playback credentials stay with this playback session in memory.
@MainActor struct VideoPlaybackRequestContext {
    let url: URL
    let referrer: URL?
    let userAgent: String
    let cookies: [HTTPCookie]

    static func load(url: URL, pageURL: URL?, webView: WKWebView?) async -> Self {
        let cookies: [HTTPCookie]
        if let webView {
            cookies = await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
        } else { cookies = [] }
        return Self(url: url, referrer: pageURL, userAgent: webView?.customUserAgent ?? AppConstants.mobileWebViewUserAgent,
                    cookies: WebResourceDownloadService.matchingCookies(from: cookies, for: url))
    }

    func apply(to media: VLCMedia) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        media.addOption(":http-user-agent=" + userAgent.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))
        if let referrer { media.addOption(":http-referrer=" + referrer.absoluteString) }
        guard let host = url.host else { return }
        for cookie in cookies {
            var value = "\(cookie.name)=\(cookie.value); Path=\(cookie.path)"
            if cookie.domain.hasPrefix(".") { value += "; Domain=" + cookie.domain }
            if cookie.isSecure { value += "; Secure" }
            if let expiry = cookie.expiresDate { value += "; Max-Age=\(max(0, Int(expiry.timeIntervalSinceNow)))" }
            guard media.storeCookie(value, forHost: host, path: cookie.path) == 0 else {
                throw URLError(.userAuthenticationRequired)
            }
        }
    }
}

/// A lightweight playback view retains the system download and its credentials.
@MainActor final class SouloMediaPlaybackSource {
    let url: URL
    let native: DownloadPlaybackSource
    private let temporaryDirectory: URL?

    private init(url: URL, native: DownloadPlaybackSource, temporaryDirectory: URL? = nil) {
        self.url = url; self.native = native; self.temporaryDirectory = temporaryDirectory
    }

    static func prepare(native: DownloadPlaybackSource, originalURL: URL) async throws -> SouloMediaPlaybackSource {
        // AVFoundation also labels ordinary AES-128 HLS as protected. VLC
        // supports those streams; hasProtectedContent is not a DRM capability
        // check and must not reject a handoff before the decoder tries it.
        try Task.checkCancellation()
        let url = native.asset.url
        guard url.isFileURL, url.pathExtension.lowercased() == "movpkg" else {
            return SouloMediaPlaybackSource(url: url, native: native)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SouloPlayback-\(UUID())", isDirectory: true)
        let sourceURL = originalURL.pathExtension.lowercased() == OfflineHLSReference.fileExtension
            ? OfflineHLSReference.sourceURL(for: originalURL) : originalURL
        do {
            let task = Task.detached(priority: .userInitiated) {
                try await PortableHLSBundle.export(packageURL: url, name: "Playback", into: directory,
                                                   sourceURL: sourceURL, linkFragments: true)
            }
            let bundle = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return SouloMediaPlaybackSource(url: bundle.appendingPathComponent("index.m3u8"), native: native,
                                           temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        if let temporaryDirectory {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }
}
