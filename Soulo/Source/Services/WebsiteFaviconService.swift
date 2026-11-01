import Foundation
import UIKit
import ImageIO

/// Small, recreatable site icons shared by history, bookmarks and custom platforms.
@MainActor final class WebsiteFaviconService {
    static let shared = WebsiteFaviconService()
    nonisolated static let responseCache = URLCache(memoryCapacity: 2 * 1024 * 1024,
        diskCapacity: 20 * 1024 * 1024, diskPath: "SouloFavicons")
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private final class Entry {
        let image: UIImage
        let expires: Date
        init(_ image: UIImage, expires: Date) { self.image = image; self.expires = expires }
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
               let stamp = response.value(forHTTPHeaderField: "X-Soulo-Icon-Date").flatMap(Double.init),
               now().timeIntervalSince1970 - stamp < Self.lifetime,
               let image = await Self.decode(cached.data) {
                guard !Task.isCancelled, generation == epoch else { return nil }
                images.setObject(Entry(image, expires: Date(timeIntervalSince1970: stamp + Self.lifetime)), forKey: key as NSURL, cost: 64 * 64 * 4)
                pending[key] = nil
                return image
            }
            var sources = [key]
            var visited = Set<URL>()
            var discovered = false
            // Keep the existing bookmark fallbacks for public domains only.
            if let host = key.host, host.contains("."), !host.contains(":"),
               !host.split(separator: ".").allSatisfy({ Int($0) != nil }),
               !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), key.port == nil {
                if let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") { sources.append(url) }
                var google = URLComponents(string: "https://www.google.com/s2/favicons")!
                google.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
                if let url = google.url { sources.append(url) }
            }
            while !sources.isEmpty {
                let url = sources.removeFirst()
                guard visited.insert(url).inserted else { continue }
                guard !Task.isCancelled, generation == epoch else { return nil }
                do {
                    let (data, _) = try await Self.download(url, session: session)
                    guard let image = await Self.decode(data),
                          !Task.isCancelled, generation == epoch else { throw URLError(.cannotDecodeContentData) }
                    let timestamp = now()
                    images.setObject(Entry(image, expires: timestamp.addingTimeInterval(Self.lifetime)), forKey: key as NSURL, cost: 64 * 64 * 4)
                    if let png = image.pngData(), let storedResponse = HTTPURLResponse(url: key, statusCode: 200,
                        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png",
                            "Cache-Control": "max-age=604800", "X-Soulo-Icon-Date": String(timestamp.timeIntervalSince1970)]) {
                        cache.storeCachedResponse(CachedURLResponse(response: storedResponse, data: png), for: request)
                    }
                    pending[key] = nil
                    return image
                } catch { if Task.isCancelled { return nil } }
                if !discovered {
                    discovered = true
                    // A site's declared icon may live anywhere, including a CDN.
                    // Inspect only the public origin, never a bookmark's query or path.
                    let origin = key.deletingLastPathComponent()
                    if let (html, response) = try? await Self.download(origin, session: session, maximumBytes: 512 * 1024),
                       response.mimeType?.lowercased() == "text/html" {
                        let pageURL = response.url ?? origin
                        let declared = await Task.detached(priority: .utility) {
                            Self.declaredIconURLs(in: html, pageURL: pageURL)
                        }.value
                        sources.insert(contentsOf: declared, at: 0)
                    }
                }
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

    /// Bounded HTML metadata parsing; no WebKit instance or page scripts are needed.
    nonisolated static func declaredIconURLs(in data: Data, pageURL: URL) -> [URL] {
        guard data.count <= 512 * 1024,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252),
              let tags = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?</script\s*>|<style\b[^>]*>[\s\S]*?</style\s*>|<(?:base|link)\b(?:"[^"]*"|'[^']*'|[^'">])*>|</head\s*>"#, options: [.caseInsensitive]),
              let attrs = try? NSRegularExpression(pattern: #"([a-zA-Z_][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        var base = pageURL
        var usedBase = false
        var icons: [(URL, Bool)] = []
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
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") else { continue }
            guard !icons.contains(where: { $0.0 == url }) else { continue }
            let vector = values["type"]?.lowercased() == "image/svg+xml" || url.pathExtension.lowercased() == "svg"
            icons.append((url, vector))
            if icons.count == 8 { break }
        }
        // ImageIO supports raster icons; prefer them over SVG-only declarations.
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
