import XCTest
import UIKit
import SwiftUI
import CoreData
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
        let container = try LibraryStore(inMemory: true)
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
                    "X-Soulo-Icon-Date": String(Date().timeIntervalSince1970),
                    "X-Soulo-Icon-Version": WebsiteFaviconService.cacheVersion]))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: icon), for: URLRequest(url: key))
            container.mainContext.insert(SearchHistoryRecord(keyword: index == 0 ? "Soulo · 网站图标示例" : "Nature · 阅读记录",
                visitedURLString: url))
        }
        defer {
            for url in urls {
                cache.removeCachedResponse(for: URLRequest(url: WebsiteFaviconService.iconURL(for: url)!))
            }
        }
        let platform = PlatformDataStore.shared.platforms.first { UIImage(named: $0.iconName) != nil }
        XCTAssertNotNil(platform)
        container.mainContext.insert(SearchHistoryRecord(keyword: "旅行计划", platformID: platform?.id))
        container.mainContext.insert(SearchHistoryRecord(keyword: "普通关键词"))
        try container.mainContext.save()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for scheme in [ColorScheme.light, .dark] {
            let content = NavigationStack {
                SearchHistoryContentView(searchVM: SearchViewModel())
                    .navigationTitle("搜索历史").navigationBarTitleDisplayMode(.inline)
            }.environment(\.managedObjectContext, (container).mainContext).preferredColorScheme(scheme)
            let host = UIHostingController(rootView: content)
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
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
        XCTAssertEqual(requests, 5)
        date = date.addingTimeInterval(301)
        let third = await service.image(for: "http://localhost/three")
        XCTAssertNil(third)
        XCTAssertEqual(requests, 10)
    }

    func testBlankRasterDoesNotHideInlineSiteIconOrLeakPrivateURL() async throws {
        for blank in [UIColor.clear, UIColor.white] {
            cache.removeAllCachedResponses()
            let empty = UIGraphicsImageRenderer(size:CGSize(width:64,height:64)).pngData { context in
                blank.setFill(); context.fill(CGRect(x:0,y:0,width:64,height:64))
            }
            let html = Data("<link rel='icon' href='data:image/png;base64,\(png.base64EncodedString())'>".utf8)
            var urls = [String]()
            FaviconTestProtocol.handler = { request in
                Task { @MainActor in
                    let url = request.request.url!; urls.append(url.absoluteString)
                    request.respond(data:url.path == "/favicon.ico" ? empty : html,
                                    mimeType:url.path == "/favicon.ico" ? "image/png" : "text/html")
                }
            }
            let image = await WebsiteFaviconService(session:session,cache:cache).image(for:"https://example.com/private?q=secret")
            XCTAssertNotNil(image)
            XCTAssertEqual(urls,["https://example.com/favicon.ico","https://example.com/"])
            XCTAssertGreaterThan(pixel(try XCTUnwrap(image),x:32,y:32)[2],128)
        }
    }

    func testAllBlankResponsesLeaveFallbackAvailable() async {
        let empty = UIGraphicsImageRenderer(size:CGSize(width:64,height:64)).pngData { _ in }
        FaviconTestProtocol.handler = { $0.respond(data:empty) }
        let image = await WebsiteFaviconService(session:session,cache:cache).image(for:"http://localhost/private")
        XCTAssertNil(image,"An empty but decodable PNG must not replace the row's visible globe placeholder")
    }

    func testTransparentMonochromeIconsChooseContrastingBackplates() {
        let renderer = UIGraphicsImageRenderer(size:CGSize(width:64,height:64))
        let white = renderer.image { _ in UIColor.white.setFill(); UIBezierPath(ovalIn:CGRect(x:10,y:10,width:44,height:44)).fill() }
        let black = renderer.image { _ in UIColor.black.setFill(); UIBezierPath(ovalIn:CGRect(x:10,y:10,width:44,height:44)).fill() }
        if case .dark = WebsiteFaviconService.backplate(for:white) {} else { XCTFail("White glyph needs dark backing even in a light list") }
        if case .light = WebsiteFaviconService.backplate(for:black) {} else { XCTFail("Black glyph needs light backing even in a dark list") }
    }

    func testIconsCachedBeforeSVGSupportAreRefreshedOnce() async throws {
        let key = try XCTUnwrap(WebsiteFaviconService.iconURL(for: "http://localhost/page"))
        let response = try XCTUnwrap(HTTPURLResponse(url: key, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "X-Soulo-Icon-Date": String(Date().timeIntervalSince1970),
                "X-Soulo-Icon-Version": "2"]))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: png), for: URLRequest(url: key))
        var requests = 0
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in requests += 1; request.respond(data: data) }
        }
        let refreshed = await WebsiteFaviconService(session: session, cache: cache).image(for: "http://localhost/page")
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(requests, 1, "An old provider icon must not hide a newly discoverable site icon for seven days")
        let reused = await WebsiteFaviconService(session: session, cache: cache).image(for: "http://localhost/other")
        XCTAssertNotNil(reused)
        XCTAssertEqual(requests, 1, "The replacement still persists across service instances")
    }

    func testPublicSiteFallbackAndCacheUseOriginalOrigin() async throws {
        var urls: [URL] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                urls.append(request.request.url!)
                request.respond(data: data, status: request.request.url?.host == "icons.duckduckgo.com" ? 200 : 404)
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        let result = await service.image(for: "https://example.com/private?q=secret")
        XCTAssertNotNil(result)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/favicon.ico", "https://example.com/", "https://example.com/favicon.svg", "https://example.com/favicon.png", "https://example.com/apple-touch-icon.png", "https://icons.duckduckgo.com/ip3/example.com.ico"])
        let cached = await service.image(for: "https://example.com/another")
        XCTAssertNotNil(cached)
        XCTAssertEqual(urls.count, 6)
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
        XCTAssertEqual(requests, 12)
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

    func testDeclaredTouchIconWorksWithoutRootICOOrThirdPartyService() async throws {
        var urls: [URL] = []
        let data = png!
        let home = Data("""
            <head><link rel="icon" type="image/svg+xml" href="favicon.svg?v=20261030">
            <link rel="apple-touch-icon" href="app-icon.png?v=1.1.4"></head>
            """.utf8)
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let url = request.request.url!; urls.append(url)
                switch url.path {
                case "/favicon.ico": request.respond(data: Data(), status: 404)
                case "/": request.respond(data: home, mimeType: "text/html")
                case "/app-icon.png": request.respond(data: data)
                default: request.respond(data: Data(), status: 404)
                }
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        let image = await service.image(for: "https://soulo.dkluge.com/sources.html?q=private")
        XCTAssertEqual(try XCTUnwrap(image).size.width, 64)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://soulo.dkluge.com/favicon.ico", "https://soulo.dkluge.com/", "https://soulo.dkluge.com/app-icon.png?v=1.1.4"])
        let reused = await service.image(for: "https://soulo.dkluge.com/movies.html")
        XCTAssertTrue(reused === image)
        XCTAssertEqual(urls.count, 3)
    }

    func testMetadataResolvesBaseEntitiesAndSkipsUnusableOrExecutableDeclarations() throws {
        let html = Data("""
            <!-- <link rel="icon" href="/comment.png"> -->
            <script>var fake = '<link rel="icon" href="/script.png">';</script>
            <BASE HREF="https://cdn.example.com/assets/">
            <link rel="ICON" href="mark.svg" type="image/svg+xml">
            <link rel="alternate shortcut ICON" HREF='logo.png?v=1&amp;size=64'>
            <link rel="apple-touch-icon-precomposed" href=touch.png>
            <link rel="icon" href="javascript:alert(1)">
            <link rel="icon" href="https://user:secret@example.com/icon.png">
            <link rel="stylesheet" href="style.css">
            <link rel="icon" href="logo.png?v=1&#38;size=64">
            </head><link rel="icon" href="/body.png">
            """.utf8)
        let urls = WebsiteFaviconService.declaredIconURLs(in: html, pageURL: URL(string: "https://example.com/redirected/")!)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://cdn.example.com/assets/logo.png?v=1&size=64", "https://cdn.example.com/assets/touch.png", "https://cdn.example.com/assets/mark.svg"])
    }

    func testInvalidDeclaredImageContinuesToNextSiteIcon() async throws {
        var urls: [URL] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let url = request.request.url!; urls.append(url)
                switch url.path {
                case "/favicon.ico": request.respond(data: Data(), status: 404)
                case "/": request.respond(data: Data("<link rel='icon' href='bad.png'><link rel='apple-touch-icon' href='good.png'>".utf8), mimeType: "text/html")
                case "/good.png": request.respond(data: data)
                default: request.respond(data: Data("not an image".utf8))
                }
            }
        }
        let image = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://example.com/article")
        XCTAssertNotNil(image)
        XCTAssertEqual(urls.map(\.path), ["/favicon.ico", "/", "/bad.png", "/good.png"])
    }

    func testHTMLFaviconResponseFindsSVGAndPersistsRasterWithoutFetchingPrivatePage() async throws {
        var urls: [URL] = []
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let url = request.request.url!; urls.append(url)
                switch url.path {
                case "/favicon.ico":
                    // A SPA can return HTML with an incorrect icon MIME type.
                    request.respond(data: Data("<head><link rel='icon' type='image/x-icon' href='https://cdn.example.com/mark.svg'></head>".utf8), mimeType: "image/x-icon")
                case "/mark.svg":
                    request.respond(data: Data("<svg xmlns='http://www.w3.org/2000/svg' width='50' height='50'><rect width='50' height='50' fill='#00ff00'/></svg>".utf8), mimeType: "image/svg+xml")
                default: request.respond(data: Data(), status: 403)
                }
            }
        }
        let result = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://app.example.com/usage?private=secret")
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(pixel(image, x: 32, y: 32), [0, 255, 0, 255])
        XCTAssertEqual(urls.map(\.absoluteString), ["https://app.example.com/favicon.ico", "https://cdn.example.com/mark.svg"])
        let restored = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://app.example.com/other")
        XCTAssertNotNil(restored)
        XCTAssertEqual(urls.count, 2, "The SVG is stored as a small PNG, with no repeated WebKit rendering")
    }

    func testRedirectedFaviconHTMLResolvesRelativeTouchIconWithoutDependingOnOrigin() async throws {
        var urls: [URL] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let url = request.request.url!; urls.append(url)
                if url.path == "/favicon.ico" {
                    request.respond(data: Data("<head><link rel='apple-touch-icon-precomposed' href='../touch.png'></head>".utf8),
                        mimeType: "text/html", responseURL: URL(string: "https://mobile.example.com/errors/page"))
                } else if url.absoluteString == "https://mobile.example.com/touch.png" {
                    request.respond(data: data)
                } else {
                    request.respond(data: Data("<head><title>Legacy home without icons</title></head>".utf8), mimeType: "text/html")
                }
            }
        }
        let image = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://search.example.com/from=123/s?word=private")
        XCTAssertNotNil(image)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://search.example.com/favicon.ico", "https://mobile.example.com/touch.png"])
    }

    func testCyclicHTMLIconsContinueToOriginAndDoNotRepeatRequests() async throws {
        var paths: [String] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let path = request.request.url!.path; paths.append(path)
                switch path {
                case "/favicon.ico": request.respond(data: Data("<link rel='icon' href='/again.ico'>".utf8), mimeType: "text/html")
                case "/again.ico": request.respond(data: Data("<link rel='icon' href='/favicon.ico'><link rel='icon' href='/again.ico'>".utf8), mimeType: "text/html")
                case "/": request.respond(data: Data("<link rel='icon' href='/good.png'>".utf8), mimeType: "text/html")
                case "/good.png": request.respond(data: data)
                default: request.respond(data: Data(), status: 404)
                }
            }
        }
        let image = await WebsiteFaviconService(session: session, cache: cache).image(for: "http://localhost/private")
        XCTAssertNotNil(image)
        XCTAssertEqual(paths, ["/favicon.ico", "/again.ico", "/", "/good.png"])
    }

    func testSVGRenderingFitsAspectRatioAndCannotRunScriptsOrFetchExternalResources() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/external.png": png!])
        let base = try await server.start()
        defer { server.stop() }
        let svg = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="80" height="40">
            <style>@import url('\(base)/external.css'); rect { fill: #00ff00; }</style>
            <rect width="80" height="40"/>
            <script>document.querySelector('rect').setAttribute('fill','#ff0000'); fetch('\(base)/script');</script>
            <image href="\(base)/external.png" width="80" height="40"/>
            </svg>
            """.utf8)
        FaviconTestProtocol.handler = { $0.respond(data: svg, mimeType: "image/svg+xml") }
        let result = await WebsiteFaviconService(session: session, cache: cache).image(for: "http://localhost/page")
        let image = try XCTUnwrap(result)
        XCTAssertEqual(pixel(image, x: 32, y: 32), [0, 255, 0, 255])
        XCTAssertEqual(pixel(image, x: 32, y: 2), [0, 0, 0, 0], "A non-square icon keeps its proportions and transparency")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(server.receivedRequests.isEmpty, "SVG scripts and external resources must stay disabled")
    }

    func testMultipleOriginsCanLoadSVGIconsConcurrently() async throws {
        var requests = 0
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                requests += 1
                let fill = request.request.url!.host == "green.local" ? "#00ff00" : "#0000ff"
                request.respond(data: Data("<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'><rect width='64' height='64' fill='\(fill)'/></svg>".utf8), mimeType: "image/svg+xml")
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        async let green = service.image(for: "http://green.local/private")
        async let blue = service.image(for: "http://blue.local/private")
        let images = await [green, blue]
        XCTAssertEqual(pixel(try XCTUnwrap(images[0]), x: 32, y: 32), [0, 255, 0, 255])
        XCTAssertEqual(pixel(try XCTUnwrap(images[1]), x: 32, y: 32), [0, 0, 255, 255])
        XCTAssertEqual(requests, 2)
    }

    func testProviderHTMLDoesNotSupplyTheProvidersOwnBrandIcon() async {
        var urls: [URL] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let url = request.request.url!; urls.append(url)
                if url.host == "icons.duckduckgo.com" {
                    request.respond(data: Data("<link rel='icon' href='/provider-brand.png'>".utf8), mimeType: "text/html")
                } else if url.host == "www.google.com" {
                    request.respond(data: data)
                } else { request.respond(data: Data(), status: 404) }
            }
        }
        let image = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://example.com/private")
        XCTAssertNotNil(image)
        XCTAssertEqual(urls.count, 7)
        XCTAssertFalse(urls.contains { $0.path == "/provider-brand.png" })
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = CGContext(data: &bytes, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return Array(bytes[((y * 64 + x) * 4)..<((y * 64 + x) * 4 + 4)])
    }

    func testLiveSouloWebsiteIcon() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_QA"] != "1", "Live network QA is opt-in")
        let image = await WebsiteFaviconService(cache: cache).image(for: "https://soulo.dkluge.com/sources.html")
        XCTAssertEqual(try XCTUnwrap(image).size.width, 64)
    }

    func testManifestIconWorksWithMissingICOAndBrokenSVGPageDeclaration() async throws {
        var urls: [URL] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let url = request.request.url!; urls.append(url)
                switch url.path {
                case "/": request.respond(data: Data("""
                    <head><link rel="manifest" href="/stockclaw.webmanifest">
                    <link rel="icon" href="/icon.svg?v=1" type="image/svg+xml"></head>
                    """.utf8), mimeType: "text/html")
                case "/icon.svg": request.respond(data: Data("<svg xmlns='http://www.w3.org/2000/svg'><path".utf8), mimeType: "image/svg+xml")
                case "/stockclaw.webmanifest": request.respond(data: Data(#"{"icons":[{"src":"/images/stockclaw-logo.png","sizes":"1024x1024","type":"image/png"}]}"#.utf8), mimeType: "application/manifest+json")
                case "/images/stockclaw-logo.png": request.respond(data: data)
                default: request.respond(data: Data(), status: 404)
                }
            }
        }
        let service = WebsiteFaviconService(session: session, cache: cache)
        let image = await service.image(for: "https://stockclaw.dkluge.com/private?q=secret")
        XCTAssertEqual(try XCTUnwrap(image).size.width, 64)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://stockclaw.dkluge.com/favicon.ico",
            "https://stockclaw.dkluge.com/", "https://stockclaw.dkluge.com/icon.svg?v=1",
            "https://stockclaw.dkluge.com/stockclaw.webmanifest", "https://stockclaw.dkluge.com/images/stockclaw-logo.png"])
        let restored = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://stockclaw.dkluge.com/another")
        XCTAssertNotNil(restored)
        XCTAssertEqual(urls.count, 5, "Manifest icons use the existing origin cache")
    }

    func testInvalidManifestAndIconContinueToTheNextDeclaredCandidate() async throws {
        var paths: [String] = []
        let data = png!
        FaviconTestProtocol.handler = { request in
            Task { @MainActor in
                let path = request.request.url!.path; paths.append(path)
                switch path {
                case "/": request.respond(data: Data("<head><base href='/assets/'><link rel='manifest' href='broken.json'><link rel='manifest' href='app.webmanifest'></head>".utf8), mimeType: "text/html")
                case "/assets/app.webmanifest": request.respond(data: Data(#"{"icons":[{"src":"bad.png"},{"src":"good.png"}]}"#.utf8), mimeType: "application/manifest+json")
                case "/assets/good.png": request.respond(data: data)
                case "/favicon.ico": request.respond(data: Data(), status: 404)
                default: request.respond(data: Data("invalid content".utf8))
                }
            }
        }
        let image = await WebsiteFaviconService(session: session, cache: cache).image(for: "https://example.com/page")
        XCTAssertNotNil(image)
        XCTAssertEqual(paths, ["/favicon.ico", "/", "/assets/broken.json", "/assets/app.webmanifest", "/assets/bad.png", "/assets/good.png"])
    }

    func testManifestURLsResolveAgainstManifestLocationAndStayBounded() throws {
        let base = try XCTUnwrap(URL(string: "https://cdn.example.com/app/manifest.json"))
        let data = Data(#"{"icons":[{"src":"vector.svg","type":"image/svg+xml"},{"src":"../logo.png?v=2"},{"src":"//images.example.com/icon.png"},{"src":"../logo.png?v=2"},{"src":"javascript:alert(1)"},{"src":"data:image/png;base64,abc"},{"src":"https://user:secret@example.com/icon.png"},{"src":""}]}"#.utf8)
        XCTAssertEqual(WebsiteFaviconService.manifestIconURLs(in: data, manifestURL: base).map(\.absoluteString),
            ["https://cdn.example.com/logo.png?v=2", "https://images.example.com/icon.png", "https://cdn.example.com/app/vector.svg"])
        XCTAssertTrue(WebsiteFaviconService.manifestIconURLs(in: Data(repeating: 32, count: 128 * 1024 + 1), manifestURL: base).isEmpty)
        XCTAssertTrue(WebsiteFaviconService.manifestIconURLs(in: Data("not JSON".utf8), manifestURL: base).isEmpty)
        let many = try JSONSerialization.data(withJSONObject: ["icons": (0..<40).map { ["src": "icon-\($0).png"] }])
        XCTAssertEqual(WebsiteFaviconService.manifestIconURLs(in: many, manifestURL: base).count, 8)
    }

    func testLiveStockClawWebsiteIcon() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_QA"] != "1", "Live network QA is opt-in")
        let image = await WebsiteFaviconService(cache: cache).image(for: "https://stockclaw.dkluge.com/")
        XCTAssertEqual(try XCTUnwrap(image).size.width, 64)
        let attachment = XCTAttachment(image: try XCTUnwrap(image))
        attachment.name = "StockClaw live website icon"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLiveDeepSeekSVGIcon() async throws {
        try await checkLiveIcon("https://platform.deepseek.com/usage", name: "DeepSeek")
    }

    func testLiveBaiduSearchIcon() async throws {
        try await checkLiveIcon("https://mc.baidu.com/from=1020712e/ssid=0/s?word=dentist&sa=brs_2&rq=desert&rsf=102631151&pqid=8955314148125297612&rfqid=8955314148125297612&is_rec_s=0&rqid=8955314148125297612&params_ssrt=node-san", name: "Baidu")
    }

    private func checkLiveIcon(_ value: String, name: String) async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_QA"] != "1", "Live network QA is opt-in")
        let recorder = FaviconNetworkRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        let liveSession = URLSession(configuration: config, delegate: recorder, delegateQueue: nil)
        defer { liveSession.invalidateAndCancel() }
        let result = await WebsiteFaviconService(session: liveSession, cache: cache).image(for: value)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.size, CGSize(width: 64, height: 64))
        XCTAssertFalse(recorder.urls.isEmpty, "Live validation must include an actual network request trace")
        XCTAssertFalse(recorder.urls.contains { ["icons.duckduckgo.com", "www.google.com"].contains($0.host ?? "") },
            "A provider placeholder must not count as a working site icon: \(recorder.urls)")
        XCTAssertFalse(recorder.urls.contains { $0.query != nil && $0.host == URL(string: value)?.host }, "Never request the private page to find an icon")
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name) live website icon"; attachment.lifetime = .keepAlways; add(attachment)
        let requests = XCTAttachment(string: recorder.urls.map(\.absoluteString).joined(separator: "\n"))
        requests.name = "\(name) icon request URLs"; requests.lifetime = .keepAlways; add(requests)
    }
}

private final class FaviconNetworkRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { recorded.append(contentsOf: metrics.transactionMetrics.compactMap { $0.request.url }) }
    }
}

private final class FaviconTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((FaviconTestProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func respond(data: Data, status: Int = 200, mimeType: String = "image/png", responseURL: URL? = nil) {
        let response = HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mimeType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
