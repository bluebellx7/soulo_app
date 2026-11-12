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

    func resourceRequest(for target: URL, referrer: URL?) -> URLRequest {
        var request = URLRequest(url: target)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referrer, let value = WebResourceDownloadService.referrerHeader(pageURL: referrer, resourceURL: target) {
            request.setValue(value, forHTTPHeaderField: "Referer")
        }
        let matching = WebResourceDownloadService.matchingCookies(from: cookies, for: target)
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    func data(for target: URL, referrer: URL, session: URLSession) async throws -> (Data, URLResponse) {
        let delegate = VideoResourceRedirectDelegate(context: self, referrer: referrer)
        return try await session.data(for: resourceRequest(for: target, referrer: referrer), delegate: delegate)
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

/// Rebuild headers for every destination; a manually attached Cookie header
/// must never follow a redirect to an unrelated host or path.
private final class VideoResourceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let context: VideoPlaybackRequestContext
    let referrer: URL

    init(context: VideoPlaybackRequestContext, referrer: URL) {
        self.context = context
        self.referrer = referrer
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
            completionHandler(nil)
            return
        }
        Task { @MainActor in
            completionHandler(context.resourceRequest(for: target, referrer: referrer))
        }
    }
}

/// AVFoundation may omit asset cookies when loading an ordinary AES-128 key.
/// Retry those small HTTP key requests with the playback-scoped credentials.
@MainActor
final class HLSKeyResourceLoader: NSObject, @preconcurrency AVAssetResourceLoaderDelegate {
    private let context: VideoPlaybackRequestContext
    private let session: URLSession
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(context: VideoPlaybackRequestContext) {
        self.context = context
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let id = ObjectIdentifier(loadingRequest)
        requests[id] = Task {
            defer { requests.removeValue(forKey: id) }
            do {
                let (data, response) = try await context.data(for: url, referrer: context.url, session: session)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode), data.count == 16 else {
                    throw WebResourceDownloadError.invalidResponse
                }
                guard !loadingRequest.isCancelled else { return }
                loadingRequest.contentInformationRequest?.contentLength = Int64(data.count)
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true
                if let dataRequest = loadingRequest.dataRequest {
                    let offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
                    guard offset >= 0, offset <= Int64(data.count) else { throw URLError(.badServerResponse) }
                    let end = dataRequest.requestsAllDataToEndOfResource ? data.count
                        : Int(offset) + max(0, min(dataRequest.requestedLength, data.count - Int(offset)))
                    dataRequest.respond(with: data.subdata(in: Int(offset)..<end))
                }
                loadingRequest.finishLoading()
            } catch {
                if !loadingRequest.isCancelled { loadingRequest.finishLoading(with: error) }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    deinit { session.invalidateAndCancel() }
}

/// A lightweight playback view retains the system download and its credentials.
@MainActor final class SouloMediaPlaybackSource {
    let url: URL
    let native: DownloadPlaybackSource
    private let temporaryDirectory: URL?
    private var systemServer: TorrentStreamServer?

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
                let reference = originalURL.pathExtension.lowercased() == OfflineHLSReference.fileExtension ? originalURL : nil
                var encryption = try reference.flatMap { try OfflineHLSReference.encryptionMaterial(for: $0) }
                if let reference, encryption == nil {
                    encryption = try await PortableHLSBundle.encryptionMaterial(packageURL: url, sourceURL: sourceURL)
                    if let encryption { try OfflineHLSReference.storeEncryption(encryption, for: reference) }
                }
                return try await PortableHLSBundle.export(packageURL: url, name: "Playback", into: directory,
                    sourceURL: sourceURL, linkFragments: true, encryption: encryption)
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

    func systemAsset() async throws -> AVURLAsset {
        guard temporaryDirectory != nil else { return native.asset }
        if systemServer == nil {
            systemServer = try await TorrentStreamServer.startHLS(directory: url.deletingLastPathComponent(),
                                                                 playlist: url.lastPathComponent)
        }
        return AVURLAsset(url: systemServer!.url)
    }

    deinit {
        systemServer?.stop()
        if let temporaryDirectory {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }
    }
}
