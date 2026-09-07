import XCTest
import UIKit
import SwiftUI
import SwiftData
@testable import Soulo

@MainActor
final class WebsiteFaviconServiceTests: XCTestCase {
    private var session: URLSession!
    private var cache: URLCache!
    private var png: Data!

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FaviconTestProtocol.self]
        session = URLSession(configuration: config)
        cache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
        png = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        cache.removeAllCachedResponses()
        FaviconTestProtocol.handler = nil
    }

    func testHistoryRendersCachedSiteAndPlatformIconsInBothAppearances() async throws {
        let container = try ModelContainer(for: SearchHistoryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let blueURL = "http://history-blue.local/article"
        let greenURL = "http://history-green.local/article"
        let cache = WebsiteFaviconService.responseCache
        let urls = [blueURL, greenURL]
        for (index, url) in urls.enumerated() {
            let key = try XCTUnwrap(WebsiteFaviconService.iconURL(for: url))
            let icon = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
                (index == 0 ? UIColor.systemBlue : UIColor.systemGreen).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                let letter = index == 0 ? "S" : "N"
                (letter as NSString).draw(at: CGPoint(x: 15, y: 7), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 42), .foregroundColor: UIColor.white
                ])
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: key, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png",
                    "X-Soulo-Icon-Date": String(Date().timeIntervalSince1970)]))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: icon), for: URLRequest(url: key))
            container.mainContext.insert(SearchHistoryItem(keyword: index == 0 ? "Soulo · 网站图标示例" : "Nature · 阅读记录",
                visitedURLString: url))
        }
        defer {
            for url in urls {
                cache.removeCachedResponse(for: URLRequest(url: WebsiteFaviconService.iconURL(for: url)!))
            }
        }
        let platform = PlatformDataStore.shared.platforms.first { UIImage(named: $0.iconName) != nil }
        XCTAssertNotNil(platform)
        container.mainContext.insert(SearchHistoryItem(keyword: "旅行计划", platformID: platform?.id))
        container.mainContext.insert(SearchHistoryItem(keyword: "普通关键词"))
        try container.mainContext.save()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for scheme in [ColorScheme.light, .dark] {
            let content = NavigationStack {
                SearchHistoryContentView(searchVM: SearchViewModel())
                    .navigationTitle("搜索历史").navigationBarTitleDisplayMode(.inline)
            }.modelContainer(container).preferredColorScheme(scheme)
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "history-favicons-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
        previous?.makeKey()
    }

    func testCacheKeyIgnoresPagePathQueryAndDefaultPortButPreservesOrigin() {
        let key = WebsiteFaviconService.iconURL(for: "HTTPS://Example.com:443/article?private=query#part")
        XCTAssertEqual(key?.absoluteString, "https://example.com/favicon.ico")
        XCTAssertEqual(key, WebsiteFaviconService.iconURL(for: "https://example.com/other"))
        XCTAssertNotEqual(key, WebsiteFaviconService.iconURL(for: "https://example.com:8443/other"))
        XCTAssertNotEqual(key, WebsiteFaviconService.iconURL(for: "http://example.com/other"))
        for invalid in ["file:///photo.png", "javascript:alert(1)", "hello world", "https://user:password@example.com"] {
            XCTAssertNil(WebsiteFaviconService.iconURL(for: invalid))
        }
    }

    func testConcurrentRowsAndSubsequentLoadsShareOneRequestAndSmallImage() async throws {
        var requests = 0
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                requests += 1
                request.respond(data: data)
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        async let first = service.image(for: "http://localhost/first?q=private")
        async let second = service.image(for: "http://localhost/second")
        let images = await [first, second]
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try XCTUnwrap(images[0]).size.width, 64)
        XCTAssertTrue(images[0] === images[1])
        let third = await service.image(for: "http://localhost/third")
        XCTAssertTrue(third === images[0])
        XCTAssertEqual(requests, 1)
    }

    func testStoredResponseIsReusedByNewServiceAndExpiresAfterSevenDays() async throws {
        var requests = 0
        var date = Date()
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in requests += 1; request.respond(data: data) }
        }
        let first = WebsiteFaviconService(session: session, cache: cache, now: { date })
        let initial = await first.image(for: "http://localhost/one")
        XCTAssertNotNil(initial)
        let restored = WebsiteFaviconService(session: session, cache: cache, now: { date })
        let reused = await restored.image(for: "http://localhost/two")
        XCTAssertNotNil(reused)
        XCTAssertEqual(requests, 1)
        date = date.addingTimeInterval(7 * 24 * 60 * 60 + 1)
        let refreshed = await restored.image(for: "http://localhost/three")
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(requests, 2)
    }

    func testInvalidImageUsesNegativeCacheThenRetries() async {
        var requests = 0
        var date = Date()
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                requests += 1
                request.respond(data: Data("<html>Not an icon</html>".utf8))
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache, now: { date })
        let first = await service.image(for: "http://localhost/one")
        let second = await service.image(for: "http://localhost/two")
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(requests, 1)
        date = date.addingTimeInterval(301)
        let third = await service.image(for: "http://localhost/three")
        XCTAssertNil(third)
        XCTAssertEqual(requests, 2)
    }

    func testPublicSiteFallbackAndCacheUseOriginalOrigin() async throws {
        var urls: [URL] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                urls.append(request.request.url!)
                request.respond(data: data, status: urls.count == 1 ? 404 : 200)
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        let result = await service.image(for: "https://example.com/private?q=secret")
        XCTAssertNotNil(result)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/favicon.ico", "https://icons.duckduckgo.com/ip3/example.com.ico"])
        let cached = await service.image(for: "https://example.com/another")
        XCTAssertNotNil(cached)
        XCTAssertEqual(urls.count, 2)
    }

    func testClearRemovesDecodedAndStoredImagesAndFailures() async {
        var requests = 0
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                requests += 1
                request.respond(data: data, status: request.request.url?.host == "127.0.0.1" ? 404 : 200)
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        _ = await service.image(for: "http://localhost/one")
        _ = await service.image(for: "http://127.0.0.1/one")
        service.clear()
        XCTAssertNil(cache.cachedResponse(for: URLRequest(url: URL(string: "http://localhost/favicon.ico")!)))
        _ = await service.image(for: "http://localhost/two")
        _ = await service.image(for: "http://127.0.0.1/two")
        XCTAssertEqual(requests, 4)
    }

    func testClearCancelsInFlightRequestAndAllowsFreshLoad() async throws {
        let started = expectation(description: "Icon request started")
        FaviconTestProtocol.handler = { _ in started.fulfill() }
        let service = WebsiteFaviconService(session: session, cache: cache)
        let pending = Task { await service.image(for: "http://localhost/one") }
        await fulfillment(of: [started], timeout: 3)
        service.clear()
        let cancelled = await pending.value
        XCTAssertNil(cancelled)
        let data = png!
        FaviconTestProtocol.handler = { $0.respond(data: data) }
        let fresh = await service.image(for: "http://localhost/two")
        XCTAssertNotNil(fresh)
    }
}

private final class FaviconTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((FaviconTestProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func respond(data: Data, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
