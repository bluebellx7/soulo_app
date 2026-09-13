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
            // Keep the existing bookmark fallbacks for public domains only.
            if let host = key.host, host.contains("."), !host.contains(":"),
               !host.split(separator: ".").allSatisfy({ Int($0) != nil }),
               !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), key.port == nil {
                if let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") { sources.append(url) }
                var google = URLComponents(string: "https://www.google.com/s2/favicons")!
                google.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
                if let url = google.url { sources.append(url) }
            }
            for url in sources {
                guard !Task.isCancelled, generation == epoch else { return nil }
                do {
                    let data = try await Self.download(url, session: session)
                    guard let image = await Self.decode(data),
                          !Task.isCancelled, generation == epoch else { continue }
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
    nonisolated private static func download(_ url: URL, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= 1024 * 1024 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 1024 * 1024 { throw URLError(.dataLengthExceedsMaximum) }
        }
        try Task.checkCancellation()
        return data
    }
}
