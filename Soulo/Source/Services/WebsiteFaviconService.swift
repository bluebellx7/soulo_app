import Foundation
import UIKit
import ImageIO
import WebKit

/// Small, recreatable site icons shared by history, bookmarks and custom platforms.
@MainActor final class WebsiteFaviconService {
    static let shared = WebsiteFaviconService()
    nonisolated static let responseCache = URLCache(memoryCapacity: 2 * 1024 * 1024,
        diskCapacity: 20 * 1024 * 1024, diskPath: "SouloFavicons")
    // Retry older placeholders now that HTML icon responses and SVG are supported.
    nonisolated static let cacheVersion = "3"
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private final class Entry {
        let image: UIImage
        let expires: Date
        init(_ image: UIImage, expires: Date) { self.image = image; self.expires = expires }
    }
    private enum Source: Hashable {
        case image(URL)
        case manifest(URL)
        case page(URL)
    }
    private let images = NSCache<NSURL, Entry>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]
    private var failures: [URL: Date] = [:]
    private var generation = 0
    private let session: URLSession
    private let cache: URLCache
    private let now: () -> Date

    init(session: URLSession? = nil, cache: URLCache = WebsiteFaviconService.responseCache,
         now: @escaping () -> Date = Date.init) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        self.session = session ?? URLSession(configuration: config)
        self.cache = cache
        self.now = now
        images.countLimit = 256
        images.totalCostLimit = 4 * 1024 * 1024
    }

    nonisolated static func iconURL(for value: String) -> URL? {
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme; parts.host = host
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        return parts.url
    }

    func image(for value: String) async -> UIImage? {
        guard let key = Self.iconURL(for: value) else { return nil }
        if let entry = images.object(forKey: key as NSURL), entry.expires > now() { return entry.image }
        if let until = failures[key], until > now() { return nil }
        if let task = pending[key] { return await task.value }
        let epoch = generation
        let request = URLRequest(url: key)
        let task = Task<UIImage?, Never> { [self] in
            if let cached = cache.cachedResponse(for: request),
               let response = cached.response as? HTTPURLResponse,
               response.value(forHTTPHeaderField: "X-Soulo-Icon-Version") == Self.cacheVersion,
               let stamp = response.value(forHTTPHeaderField: "X-Soulo-Icon-Date").flatMap(Double.init),
               now().timeIntervalSince1970 - stamp < Self.lifetime,
               let image = await Self.decode(cached.data) {
                guard !Task.isCancelled, generation == epoch else { return nil }
                images.setObject(Entry(image, expires: Date(timeIntervalSince1970: stamp + Self.lifetime)), forKey: key as NSURL, cost: 64 * 64 * 4)
                pending[key] = nil
                return image
            }
            // Inspect only the public origin, never a bookmark's query or path.
            var sources = [Source.image(key), .page(key.deletingLastPathComponent())]
            var visited = Set<Source>()
            var htmlIconResponses = 0
            var providerURLs = Set<URL>()
            // Keep the existing bookmark fallbacks for public domains only.
            if let host = key.host, host.contains("."), !host.contains(":"),
               !host.split(separator: ".").allSatisfy({ Int($0) != nil }),
               !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), key.port == nil {
                if let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") {
                    sources.append(.image(url)); providerURLs.insert(url)
                }
                var google = URLComponents(string: "https://www.google.com/s2/favicons")!
                google.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
                if let url = google.url { sources.append(.image(url)); providerURLs.insert(url) }
            }
            while !sources.isEmpty, visited.count < 24 {
                let source = sources.removeFirst()
                guard visited.insert(source).inserted else { continue }
                guard !Task.isCancelled, generation == epoch else { return nil }
                if case let .manifest(url) = source {
                    if let (data, response) = try? await Self.download(url, session: session, maximumBytes: 128 * 1024) {
                        let manifestURL = response.url ?? url
                        let icons = await Task.detached(priority: .utility) {
                            Self.manifestIconURLs(in: data, manifestURL: manifestURL)
                        }.value
                        sources.insert(contentsOf: icons.map(Source.image), at: 0)
                    }
                    continue
                }
                if case let .page(url) = source {
                    if let (html, response) = try? await Self.download(url, session: session, maximumBytes: 512 * 1024) {
                        let declared = await Self.resources(in: html, response: response, requestedURL: url)
                        sources.insert(contentsOf: declared, at: 0)
                    }
                    continue
                }
                guard case let .image(url) = source else { continue }
                do {
                    let (data, response) = try await Self.download(url, session: session)
                    var image = await Self.decode(data)
                    if image == nil { image = await FaviconSVGRenderer.image(from: data) }
                    guard !Task.isCancelled, generation == epoch else { return nil }
                    guard let image else {
                        // SPA fallbacks and redirects can return HTML for favicon.ico.
                        // Its declarations are as useful as those on the origin page.
                        if htmlIconResponses < 3, !providerURLs.contains(url) {
                            let declared = await Self.resources(in: data, response: response, requestedURL: url)
                            if !declared.isEmpty { htmlIconResponses += 1 }
                            sources.insert(contentsOf: declared, at: 0)
                        }
                        continue
                    }
                    let timestamp = now()
                    images.setObject(Entry(image, expires: timestamp.addingTimeInterval(Self.lifetime)), forKey: key as NSURL, cost: 64 * 64 * 4)
                    if let png = image.pngData(), let storedResponse = HTTPURLResponse(url: key, statusCode: 200,
                        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png",
                            "Cache-Control": "max-age=604800", "X-Soulo-Icon-Date": String(timestamp.timeIntervalSince1970),
                            "X-Soulo-Icon-Version": Self.cacheVersion]) {
                        cache.storeCachedResponse(CachedURLResponse(response: storedResponse, data: png), for: request)
                    }
                    pending[key] = nil
                    return image
                } catch { if Task.isCancelled { return nil } }
            }
            guard generation == epoch else { return nil }
            failures = failures.filter { $0.value > now() }
            if failures.count >= 256 { failures.removeAll(keepingCapacity: true) }
            failures[key] = now().addingTimeInterval(5 * 60)
            pending[key] = nil
            return nil
        }
        pending[key] = task
        return await task.value
    }

    nonisolated private static func resources(in data: Data, response: HTTPURLResponse, requestedURL: URL) async -> [Source] {
        guard data.count <= 512 * 1024 else { return [] }
        let mime = response.mimeType?.lowercased() ?? ""
        // Some servers label their HTML fallback image/x-icon or application/octet-stream.
        let prefix = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["text/html", "application/xhtml+xml"].contains(mime)
                || ["<!doctype html", "<html", "<head", "<link"].contains(where: prefix.hasPrefix) else { return [] }
        return await Task.detached(priority: .utility) {
            let declared = Self.declaredResources(in: data, pageURL: response.url ?? requestedURL)
            return declared.icons.map(Source.image) + declared.manifests.map(Source.manifest)
        }.value
    }

    /// Bounded HTML metadata parsing; no WebKit instance or page scripts are needed.
    nonisolated static func declaredIconURLs(in data: Data, pageURL: URL) -> [URL] {
        declaredResources(in: data, pageURL: pageURL).icons
    }

    nonisolated private static func declaredResources(in data: Data, pageURL: URL) -> (icons: [URL], manifests: [URL]) {
        guard data.count <= 512 * 1024,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252),
              let tags = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?</script\s*>|<style\b[^>]*>[\s\S]*?</style\s*>|<(?:base|link)\b(?:"[^"]*"|'[^']*'|[^'">])*>|</head\s*>"#, options: [.caseInsensitive]),
              let attrs = try? NSRegularExpression(pattern: #"([a-zA-Z_][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return ([], []) }
        var base = pageURL
        var usedBase = false
        var icons: [(URL, Bool)] = []
        var manifests: [URL] = []
        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            let lower = tag.lowercased()
            if lower.hasPrefix("</head") { break }
            guard lower.hasPrefix("<link") || lower.hasPrefix("<base") else { continue }
            var values: [String: String] = [:]
            for attr in attrs.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let name = Range(attr.range(at: 1), in: tag) else { continue }
                for index in 2...4 {
                    if let value = Range(attr.range(at: index), in: tag) {
                        values[tag[name].lowercased()] = decodeEntities(String(tag[value]))
                        break
                    }
                }
            }
            guard let href = values["href"],
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { continue }
            if lower.hasPrefix("<base") {
                if !usedBase { base = url; usedBase = true }
                continue
            }
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            if rel.contains("manifest"), manifests.count < 2, !manifests.contains(url) {
                manifests.append(url)
            }
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") else { continue }
            guard icons.count < 8, !icons.contains(where: { $0.0 == url }) else { continue }
            let vector = values["type"]?.lowercased() == "image/svg+xml" || url.pathExtension.lowercased() == "svg"
            icons.append((url, vector))
        }
        // Prefer the lightweight raster decoder before starting an SVG renderer.
        return (icons.filter { !$0.1 }.map(\.0) + icons.filter { $0.1 }.map(\.0), manifests)
    }

    /// Manifest icon paths resolve against the manifest response URL, not the page.
    nonisolated static func manifestIconURLs(in data: Data, manifestURL: URL) -> [URL] {
        guard data.count <= 128 * 1024,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = manifest["icons"] as? [[String: Any]] else { return [] }
        var icons: [(URL, Bool)] = []
        for entry in entries.prefix(32) {
            guard let src = entry["src"] as? String,
                  !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = URL(string: src, relativeTo: manifestURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil,
                  !icons.contains(where: { $0.0 == url }) else { continue }
            let vector = (entry["type"] as? String)?.lowercased() == "image/svg+xml" || url.pathExtension.lowercased() == "svg"
            icons.append((url, vector))
            if icons.count == 8 { break }
        }
        return icons.filter { !$0.1 }.map(\.0) + icons.filter { $0.1 }.map(\.0)
    }

    nonisolated private static func decodeEntities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#\d+|amp|quot|apos|lt|gt);"#, options: [.caseInsensitive]) else { return value }
        let names = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let range = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: value) else { continue }
            let entity = value[inner].lowercased()
            var decoded = names[entity]
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                if let code = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(code), code != 0 { decoded = String(scalar) }
            }
            if let decoded { result.replaceSubrange(range, with: decoded) }
        }
        return result
    }

    func clear() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll(); failures.removeAll(); images.removeAllObjects()
        cache.removeAllCachedResponses()
    }

    nonisolated private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }

    /// Byte iteration must not monopolize the UI actor on a fast/cached response.
    nonisolated private static func download(_ url: URL, session: URLSession, maximumBytes: Int = 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= maximumBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        try Task.checkCancellation()
        return (data, response)
    }
}

/// SVG is loaded as an image, never as an active document. The renderer has no
/// cookies, page scripts or network access; only our isolated canvas code runs.
@MainActor private final class FaviconSVGRenderer: NSObject, WKNavigationDelegate {
    private static let shared = FaviconSVGRenderer()
    private static var pending: (id: UUID, task: Task<UIImage?, Never>)?
    private var webView: WKWebView?
    private var ready = false
    private var jobID: UUID?
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var timeout: Task<Void, Never>?
    private var idleRelease: Task<Void, Never>?
    private var source = ""

    static func image(from data: Data) async -> UIImage? {
        guard data.count <= 256 * 1024 else { return nil }
        let prefix = String(decoding: data.prefix(2048), as: UTF8.self)
        guard prefix.range(of: #"<svg(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        // Render a list of SVG-only sites one at a time rather than per row in parallel.
        let previous = pending?.task
        let id = UUID()
        let task = Task<UIImage?, Never> {
            if let previous { _ = await previous.value }
            guard !Task.isCancelled else { return nil }
            return await shared.render(data)
        }
        pending = (id, task)
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if pending?.id == id { pending = nil }
        return image
    }

    private func render(_ data: Data) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                idleRelease?.cancel(); idleRelease = nil
                self.continuation = continuation
                jobID = id
                source = "data:image/svg+xml;base64," + data.base64EncodedString()
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, self.jobID == id else { return }
                    self.finish(nil, reset: true)
                }
                if let webView, ready {
                    rasterize(in: webView)
                    return
                }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
                view.navigationDelegate = self
                webView = view
                view.loadHTMLString("""
                    <!doctype html><html><head>
                    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
                    </head><body></body></html>
                    """, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor in
                guard self.jobID == id else { return }
                self.finish(nil, reset: true)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, continuation != nil else { return }
        ready = true
        rasterize(in: webView)
    }

    private func rasterize(in webView: WKWebView) {
        guard let id = jobID else { return }
        webView.callAsyncJavaScript("""
            const image = new Image();
            image.src = source;
            await image.decode();
            if (!image.naturalWidth || !image.naturalHeight) return null;
            const canvas = document.createElement('canvas');
            canvas.width = canvas.height = 64;
            const scale = Math.min(64 / image.naturalWidth, 64 / image.naturalHeight);
            const width = image.naturalWidth * scale, height = image.naturalHeight * scale;
            canvas.getContext('2d').drawImage(image, (64 - width) / 2, (64 - height) / 2, width, height);
            return canvas.toDataURL('image/png');
            """, arguments: ["source": source], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.jobID == id else { return }
                guard case let .success(value) = result, let url = value as? String,
                      url.hasPrefix("data:image/png;base64,"), url.count < 128 * 1024,
                      let data = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))) else {
                    self.finish(nil); return
                }
                self.finish(UIImage(data: data))
            }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { finish(nil, reset: true) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { finish(nil, reset: true) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { finish(nil, reset: true) }
    }

    private func finish(_ image: UIImage?, reset: Bool = false) {
        if reset { releaseWebView() }
        guard let continuation else { return }
        self.continuation = nil
        jobID = nil
        timeout?.cancel(); timeout = nil
        if !reset {
            // Reuse a single isolated view for the visible list, then release it.
            idleRelease = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.continuation == nil else { return }
                self.releaseWebView()
            }
        }
        source = ""
        continuation.resume(returning: image)
    }

    private func releaseWebView() {
        ready = false
        webView?.navigationDelegate = nil
        webView?.stopLoading(); webView = nil
    }
}
