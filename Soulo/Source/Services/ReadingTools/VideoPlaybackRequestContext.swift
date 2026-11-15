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
    var manifests: [URL: String] = [:]
    var omitsReferrer = false

    static func load(url: URL, pageURL: URL?, webView: WKWebView?) async -> Self {
        let cookies: [HTTPCookie]
        if let webView {
            cookies = await WebKitCookieAccess.cookies(for: url, in: webView.configuration.websiteDataStore.httpCookieStore)
        } else { cookies = [] }
        var result = Self(url: url, referrer: pageURL, userAgent: webView?.customUserAgent ?? AppConstants.mobileWebViewUserAgent,
                    cookies: WebResourceDownloadService.matchingCookies(from: cookies, for: url))
        if let webView {
            result.manifests = WebMediaManifestCache.snapshot(webView: webView)
            result.omitsReferrer = WebMediaManifestCache.omitsReferrer(for: url, webView: webView)
        }
        return result
    }

    func resourceRequest(for target: URL, referrer: URL?) -> URLRequest {
        var request = URLRequest(url: target)
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !omitsReferrer, let referrer, let value = WebResourceDownloadService.referrerHeader(pageURL: referrer, resourceURL: target) {
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

    func download(for target: URL, referrer: URL, range: String?, session: URLSession) async throws -> (URL, URLResponse) {
        var request = resourceRequest(for: target, referrer: referrer)
        request.setValue(range, forHTTPHeaderField: "Range")
        let delegate = VideoResourceRedirectDelegate(context: self, referrer: referrer, range: range)
        return try await session.download(for: request, delegate: delegate)
    }

    func boundedData(for target: URL, referrer: URL, maximumBytes: Int, session: URLSession) async throws -> (Data, URLResponse) {
        if let text = manifests[target] {
            let data = Data(text.utf8)
            guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return (data, HTTPURLResponse(url: target, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!)
        }
        let delegate = VideoResourceRedirectDelegate(context: self, referrer: referrer)
        return try await BoundedMediaHTTP.read(resourceRequest(for: target, referrer: referrer), session: session, delegate: delegate, limit: maximumBytes)
    }

    func apply(to media: VLCMedia) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        media.addOption(":http-user-agent=" + userAgent.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))
        if !omitsReferrer, let referrer { media.addOption(":http-referrer=" + referrer.absoluteString) }
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

private enum BoundedMediaHTTP {
    static func read(_ request: URLRequest, session: URLSession, delegate: any URLSessionTaskDelegate, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(limit) || response.expectedContentLength < 0 else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data(); data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            if data.count % 8192 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return (data, response)
    }
}

/// Rebuild headers for every destination; a manually attached Cookie header
/// must never follow a redirect to an unrelated host or path.
private final class VideoResourceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let context: VideoPlaybackRequestContext
    let referrer: URL
    let range: String?

    init(context: VideoPlaybackRequestContext, referrer: URL, range: String? = nil) {
        self.context = context
        self.referrer = referrer
        self.range = range
    }

    #if SOULO_ACCEPTANCE
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        NSLog("[SouloHLSBridge] request proxied:%d", metrics.transactionMetrics.contains { $0.isProxyConnection })
    }
    #endif

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
            completionHandler(nil)
            return
        }
        Task { @MainActor in
            var scoped = context.resourceRequest(for: target, referrer: referrer)
            scoped.setValue(range, forHTTPHeaderField: "Range")
            completionHandler(scoped)
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
        // AVPlayer requires HTTP for local HLS manifests as well as movpkg
        // exports. Serve only the validated bundle's regular media files.
        guard temporaryDirectory != nil || (url.isFileURL && url.pathExtension.lowercased() == "m3u8") else { return native.asset }
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

/// Playlists contain temporary credentials, so they remain in memory and
/// follow the originating web view. They never enter backups or download history.
@MainActor enum WebMediaManifestCache {
    private final class Entries: NSObject { var values: [URL: String] = [:]; var order: [URL] = []; var noReferrer: Set<URL> = [] }
    private static let pages = NSMapTable<WKWebView, Entries>.weakToStrongObjects()
    static func snapshot(webView: WKWebView) -> [URL: String] { pages.object(forKey: webView)?.values ?? [:] }
    static func omitsReferrer(for url: URL, webView: WKWebView) -> Bool {
        pages.object(forKey: webView)?.noReferrer.contains(url) == true
    }
    static func rememberPolicy(_ policy: String?, urls: [URL], webView: WKWebView) {
        guard let policy, !urls.isEmpty else { return }
        let entry = pages.object(forKey: webView) ?? Entries()
        for url in urls {
            if policy.lowercased() == "no-referrer" { entry.noReferrer.insert(url) }
            else { entry.noReferrer.remove(url) }
        }
        // Only media currently observed in this page can add policy entries.
        if entry.noReferrer.count > 128 { entry.noReferrer = Set(entry.noReferrer.prefix(128)) }
        pages.setObject(entry, forKey: webView)
    }
    static func capture(webView: WKWebView, frame: WKFrameInfo?) async {
        guard let values = try? await webView.callAsyncJavaScript("return window.__souloObservedHLSManifests || {};", arguments: [:], in: frame, contentWorld: .page) as? [String: String] else { return }
        remember(values, webView: webView)
    }
    static func remember(_ values: [String: String], webView: WKWebView) {
        let entry = pages.object(forKey: webView) ?? Entries()
        for (raw, text) in values.prefix(8) {
            guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  text.utf8.count <= 1024 * 1024, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { continue }
            entry.values[url] = text; entry.order.removeAll { $0 == url }; entry.order.append(url)
        }
        while entry.order.count > 8 || entry.values.values.reduce(0, { $0 + $1.utf8.count }) > 1024 * 1024 {
            guard !entry.order.isEmpty else { break }; entry.values.removeValue(forKey: entry.order.removeFirst())
        }
        pages.setObject(entry, forKey: webView)
    }
    static func copy(from source: WKWebView, to destination: WKWebView) {
        remember(Dictionary(uniqueKeysWithValues: snapshot(webView: source).map { ($0.key.absoluteString, $0.value) }), webView: destination)
        if let policies = pages.object(forKey: source)?.noReferrer {
            rememberPolicy("no-referrer", urls: Array(policies), webView: destination)
        }
    }
}

/// Some HLS publishers prepend a small image before otherwise valid TS packets.
/// Require a recognized image and five consecutive valid packet headers. HTML,
/// encrypted payloads and ordinary images are never accepted as video.
enum HLSTransportPrefix {
    static func offset(in data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(65_536))
        let image = bytes.starts(with: [137,80,78,71,13,10,26,10])
            || bytes.starts(with: [255,216,255]) || bytes.starts(with: Array("GIF8".utf8))
        guard image, bytes.count >= 188 * 4 + 4 else { return nil }
        for start in 1..<(bytes.count - 188 * 4 - 3) where bytes[start] == 0x47 {
            if (0..<5).allSatisfy({ index in
                let p = start + index * 188
                return bytes[p] == 0x47 && bytes[p+1] & 0x80 == 0 && bytes[p+3] & 0x30 != 0
            }) { return start }
        }
        return nil
    }
    @discardableResult static func normalizeFile(_ file: URL) throws -> Bool {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        guard let header = try input.read(upToCount: 65_536), let offset = offset(in: header) else { return false }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > offset, (size - offset) % 188 == 0 else { throw URLError(.cannotDecodeContentData) }
        let output = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try FileHandle(forWritingTo: output)
        do {
            try input.seek(toOffset: UInt64(offset))
            while let part = try input.read(upToCount: 128 * 1024), !part.isEmpty {
                try Task.checkCancellation(); try writer.write(contentsOf: part)
            }
            try writer.close()
            _ = try FileManager.default.replaceItemAt(file, withItemAt: output)
            return true
        } catch { try? writer.close(); throw error }
    }
}

/// On-demand playback bridge, used only after a small probe confirms decorated
/// TS. Segments go to a bounded temporary disk cache, never a whole-video Blob.
private actor DecoratedHLSResources {
    struct Resource { let url: URL; let playlist: Bool; let key: Bool }
    let context: VideoPlaybackRequestContext
    let session: URLSession
    let directory: URL
    var resources: [String: Resource] = [:]
    var names: [URL: String] = [:]
    var ready: [String: URL] = [:]
    var pending: [String: Task<URL, Error>] = [:]
    var order: [String] = []
    var cachedBytes = 0
    var stopped = false
    init(context: VideoPlaybackRequestContext) {
        self.context = context
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SouloHLSPlayback/" + UUID().uuidString)
    }
    func prepare(url: URL) async throws -> Bool {
        #if SOULO_ACCEPTANCE
        NSLog("[SouloHLSBridge] probe start")
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        resources["index.m3u8"] = Resource(url: url, playlist: true, key: false); names[url] = "index.m3u8"
        var probe = url
        for _ in 0..<4 {
            let (data, response) = try await context.boundedData(for: probe, referrer: context.referrer ?? url, maximumBytes: 2 * 1024 * 1024, session: session)
            #if SOULO_ACCEPTANCE
            NSLog("[SouloHLSBridge] manifest status:%d length:%d prefix:%@", (response as? HTTPURLResponse)?.statusCode ?? -1,
                data.count, data.prefix(12).map { String(format: "%02x", $0) }.joined())
            #endif
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return false }
            #if SOULO_ACCEPTANCE
            NSLog("[SouloHLSBridge] manifest bytes:%d", data.count)
            #endif
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !lines.contains(where: { $0.hasPrefix("#EXT-X-BYTERANGE:") }) else { return false }
            let base = http.url ?? probe
            if let i = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }), i+1 < lines.count {
                let name = name(for: probe, playlist: true, key: false)
                try rewrite(text, base: base).write(to: directory.appendingPathComponent(name), options: .atomic)
                ready[name] = directory.appendingPathComponent(name)
                guard let child = resolve(lines[i+1], base: base) else { return false }; probe = child; continue
            }
            // The decoder owns encrypted data. Only normalize clear TS.
            guard !lines.contains(where: { $0.hasPrefix("#EXT-X-KEY:") && !$0.contains("METHOD=NONE") }),
                  let line = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let segment = resolve(line, base: base) else { return false }
            guard lines.contains("#EXT-X-ENDLIST") else { return false }
            let signed = URLComponents(url: probe, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                ["time", "timestamp", "expires", "deadline", "token", "sign", "signature", "auth_key", "auth"].contains($0.name.lowercased())
            } == true
            if context.manifests[probe] != nil, signed {
                let name = name(for: probe, playlist: true, key: false)
                try rewrite(text, base: base).write(to: directory.appendingPathComponent(name), options: .atomic)
                ready[name] = directory.appendingPathComponent(name)
                return true
            }
            var request = await context.resourceRequest(for: segment, referrer: context.referrer ?? url)
            request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            let delegate = await VideoResourceRedirectDelegate(context: context, referrer: context.referrer ?? url, range: "bytes=0-2047")
            let (stream, head) = try await session.bytes(for: request, delegate: delegate)
            defer { stream.task.cancel() }
            #if SOULO_ACCEPTANCE
            NSLog("[SouloHLSBridge] segment status:%d", (head as? HTTPURLResponse)?.statusCode ?? -1)
            #endif
            guard let status = head as? HTTPURLResponse, (200...299).contains(status.statusCode) else { return false }
            var prefix = Data()
            for try await byte in stream { prefix.append(byte); if prefix.count >= 2048 { break } }
            #if SOULO_ACCEPTANCE
            NSLog("[SouloHLSBridge] prefix count:%d offset:%d", prefix.count, HLSTransportPrefix.offset(in: prefix) ?? -1)
            #endif
            guard HLSTransportPrefix.offset(in: prefix) != nil else { return false }
            let name = name(for: probe, playlist: true, key: false)
            try rewrite(text, base: base).write(to: directory.appendingPathComponent(name), options: .atomic)
            ready[name] = directory.appendingPathComponent(name)
            return true
        }
        return false
    }
    private func resolve(_ raw: String, base: URL) -> URL? {
        guard let value = URL(string: raw, relativeTo: base)?.absoluteURL,
              ["http","https"].contains(value.scheme?.lowercased() ?? ""), value.user == nil, value.password == nil else { return nil }
        return value
    }
    private func name(for url: URL, playlist: Bool, key: Bool) -> String {
        if let old = names[url] { return old }
        let ext = playlist ? "m3u8" : key ? "key" : ["mp4","m4s","m4a","cmfv","cmfa"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "ts"
        let name = "r\(resources.count).\(ext)"
        names[url] = name; resources[name] = Resource(url: url, playlist: playlist, key: key)
        return name
    }
    private func rewrite(_ text: String, base: URL) throws -> Data {
        guard resources.count < 10_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let regex = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        var expectsPlaylist = false, output: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            guard resources.count < 10_000 else { throw URLError(.dataLengthExceedsMaximum) }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                var rewritten = line
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let range = Range(match.range(at: 1), in: line), let target = resolve(String(line[range]), base: base) else { continue }
                    let playlist = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                    let key = line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:")
                    rewritten.replaceSubrange(range, with: name(for: target, playlist: playlist, key: key))
                }
                output.append(rewritten); if line.hasPrefix("#EXT-X-STREAM-INF:") { expectsPlaylist = true }
            } else if !line.isEmpty {
                guard let target = resolve(line, base: base) else { throw URLError(.badURL) }
                output.append(name(for: target, playlist: expectsPlaylist, key: false)); expectsPlaylist = false
            } else { output.append(line) }
        }
        return Data(output.joined(separator: "\n").utf8)
    }
    func file(_ name: String) async throws -> URL? {
        guard !stopped, let resource = resources[name] else { return nil }
        if let file = ready[name], FileManager.default.fileExists(atPath: file.path) { return file }
        if let task = pending[name] { return try await task.value }
        let task = Task { try await materialize(resource, name: name) }
        pending[name] = task
        defer { pending[name] = nil }
        return try await task.value
    }
    private func materialize(_ resource: Resource, name: String) async throws -> URL {
        let target = directory.appendingPathComponent(name)
        if resource.playlist {
            let (data, response) = try await context.boundedData(for: resource.url, referrer: context.referrer ?? context.url, maximumBytes: 2 * 1024 * 1024, session: session)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw URLError(.cannotParseResponse) }
            try rewrite(text, base: http.url ?? resource.url).write(to: target, options: .atomic)
        } else {
            let (temporary, response) = try await context.download(for: resource.url, referrer: context.referrer ?? context.url, range: nil, session: session)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  !["text/html","application/json"].contains(http.mimeType?.lowercased() ?? "") else { throw URLError(.badServerResponse) }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 32 * 1024 * 1024, !resource.key || size == 16 else { throw URLError(.dataLengthExceedsMaximum) }
            if !resource.key { _ = try HLSTransportPrefix.normalizeFile(temporary) }
            try FileManager.default.moveItem(at: temporary, to: target)
            cachedBytes += size; order.append(name)
            while (cachedBytes > 64 * 1024 * 1024 || order.count > 16), let old = order.first {
                order.removeFirst()
                if let file = ready.removeValue(forKey: old) {
                    cachedBytes -= (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
        ready[name] = target
        return target
    }
    func stop() {
        stopped = true; pending.values.forEach { $0.cancel() }; pending.removeAll()
        session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory)
    }
}

private final class DecoratedHLSLease: @unchecked Sendable {
    let resources: DecoratedHLSResources
    let server: TorrentStreamServer
    init(resources: DecoratedHLSResources, server: TorrentStreamServer) { self.resources = resources; self.server = server }
    deinit { server.stop(); let resources = resources; Task { await resources.stop() } }
}

@MainActor enum HLSPlaybackBridge {
    private static var leaseKey: UInt8 = 0
    static func requiresSegmentNormalization(resource: WebMediaResource, webView: WKWebView?) async -> Bool {
        guard resource.delivery == .hls else { return false }
        let context = await VideoPlaybackRequestContext.load(url: resource.url, pageURL: resource.sourcePageURL, webView: webView)
        let resources = DecoratedHLSResources(context: context)
        let needed = (try? await resources.prepare(url: resource.url)) == true
        await resources.stop()
        return needed
    }
    static func assetIfNeeded(resource: WebMediaResource, webView: WKWebView?) async -> AVURLAsset? {
        #if SOULO_ACCEPTANCE
        NSLog("[SouloHLSBridge] asset delivery:%@", resource.delivery.rawValue)
        #endif
        guard resource.delivery == .hls, ["http","https"].contains(resource.url.scheme?.lowercased() ?? "") else { return nil }
        let context = await VideoPlaybackRequestContext.load(url: resource.url, pageURL: resource.sourcePageURL, webView: webView)
        let resources = DecoratedHLSResources(context: context)
        do {
            guard try await resources.prepare(url: resource.url) else { await resources.stop(); return nil }
            try Task.checkCancellation()
            let server = try await TorrentStreamServer.startHLSResources { [weak resources] name in try await resources?.file(name) }
            let asset = AVURLAsset(url: server.url)
            objc_setAssociatedObject(asset, &leaseKey, DecoratedHLSLease(resources: resources, server: server), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return asset
        } catch {
            #if SOULO_ACCEPTANCE
            NSLog("[SouloHLSBridge] probe error:%@", String(describing: error))
            #endif
            await resources.stop(); return nil
        }
    }
}
