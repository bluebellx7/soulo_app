import XCTest
import SwiftUI
import WebKit
import QuickLook
@testable import Soulo

final class BrowsingRefinementTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("refinement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor func testExtensionlessAndMisnamedImagesGetPreviewableAliasesWithoutChangingOriginals() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        for (name, data, ext) in [("extensionless", image.jpegData(compressionQuality: 0.8)!, "jpeg"),
                                  ("wrong.txt", image.pngData()!, "png"),
                                  (String(repeating: "a", count: 250), image.pngData()!, "png")] {
            let url = root.appendingPathComponent(name); try data.write(to: url)
            let info = FilePresentation.inspect(url)
            XCTAssertEqual(info.kind, .image); XCTAssertEqual(info.fileExtension, ext)
            let prepared = try PreparedFilePreview.prepare(url)
            XCTAssertEqual(prepared.url.pathExtension, ext)
            XCTAssertTrue(QLPreviewController.canPreview(prepared.url as NSURL))
            XCTAssertNotNil(UIImage(contentsOfFile: prepared.url.path))
            prepared.removeTemporaryFile()
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
        }
    }
    func testFileTypesAndOriginalPreviewLifetime() throws {
        for (ext,kind) in [("mp4",FilePresentation.Kind.video),("mp3",.audio),("pdf",.pdf),("epub",.book),("7z",.archive),("txt",.text),("bin",.other)] {
            let url = root.appendingPathComponent("sample." + ext); try Data().write(to: url)
            XCTAssertEqual(FilePresentation.inspect(url).kind, kind)
            let preview = try PreparedFilePreview.prepare(url); XCTAssertNil(preview.temporaryDirectory)
            preview.removeTemporaryFile(); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testDeletionPreflightRejectsOutsideFilesDirectoriesAndSymlinks() throws {
        let file = root.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: file)
        let child = root.appendingPathComponent("child"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let outside = child.appendingPathComponent("outside.txt"); try Data().write(to: outside)
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for invalid in [outside, child, link] {
            XCTAssertThrowsError(try LibraryFileActions.delete([file, invalid], in: root))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        try LibraryFileActions.delete([file], in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
    func testReviewRequestAfterSevenDaysOnlyOnceAndNeverRewritesFirstUse() throws {
        let suite = "review-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(ReviewPromptPolicy.consumeIfEligible(defaults: defaults, now: date))
        ReviewPromptPolicy.recordUse(defaults: defaults, now: date)
        ReviewPromptPolicy.recordUse(defaults: defaults, now: date.addingTimeInterval(100))
        XCTAssertEqual(defaults.object(forKey: ReviewPromptPolicy.firstUseKey) as? Date, date)
        XCTAssertFalse(ReviewPromptPolicy.consumeIfEligible(defaults: defaults, now: date.addingTimeInterval(-1)))
        XCTAssertFalse(ReviewPromptPolicy.consumeIfEligible(defaults: defaults, now: date.addingTimeInterval(ReviewPromptPolicy.delay - 1)))
        XCTAssertTrue(ReviewPromptPolicy.consumeIfEligible(defaults: defaults, now: date.addingTimeInterval(ReviewPromptPolicy.delay)))
        XCTAssertFalse(ReviewPromptPolicy.consumeIfEligible(defaults: defaults, now: date.addingTimeInterval(ReviewPromptPolicy.delay * 2)))
    }
    func testDockingBoundariesAndVerticalClamping() {
        XCTAssertTrue(MiniPlayerDocking.shouldDock(center: 20, width: 390))
        XCTAssertTrue(MiniPlayerDocking.shouldDock(center: 370, width: 390))
        XCTAssertFalse(MiniPlayerDocking.shouldDock(center: 195, width: 390))
        XCTAssertEqual(MiniPlayerDocking.verticalPosition(offset: -2000, height: 844), 40)
        XCTAssertEqual(MiniPlayerDocking.verticalPosition(offset: 2000, height: 844), 744)
    }
    @MainActor func testNovelExtractionRetainsBreaksRemovesControlsAndIsolatesPageGlobals() async throws {
        let web = WKWebView()
        let paragraph = String(repeating: "这是一段原创的小说正文，雨后的巷子里，一盏灯慢慢亮了起来。", count: 10)
        let html = """
        <html><head><title>第一章 · 测试小说</title></head><body><nav>首页 分类 排行</nav><h1>第一章 雨后</h1>
        <div id='chaptercontent'>\(paragraph)<br><br>\(paragraph)<div class='ads'>广告测试应移除</div>
        <a href='/prev'>上一章</a><a href='/contents'>目录</a><img data-src='/cover.png' src='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///w==' onerror='alert(1)'>
        <iframe src='/ad'></iframe></div><a href='/chapter2'>下一章 »</a>
        <script>window.Readability = function(){throw Error('Page must not override the reader')};</script></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://novel.test/chapter1"))
        for _ in 0..<120 {
            if (try? await web.evaluateJavaScript("document.querySelector('#chaptercontent') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let article = try await ArticleReader.extract(web)
        XCTAssertEqual(article.title, "第一章 雨后")
        XCTAssertEqual(article.next?.absoluteString, "https://novel.test/chapter2")
        XCTAssertTrue(article.text.contains(paragraph)); XCTAssertTrue(article.html.contains("<br>"))
        XCTAssertTrue(article.html.contains("https://novel.test/cover.png"))
        for removed in ["广告测试应移除", "onerror", "<iframe", "上一章", "目录"] { XCTAssertFalse(article.html.contains(removed), removed) }
        let originalAd = try await web.evaluateJavaScript("document.querySelector('.ads').textContent") as? String
        XCTAssertEqual(originalAd, "广告测试应移除")
    }
    @MainActor func testSplitChapterMarkupAndShortNextLabel() async throws {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        let paragraph = String(repeating: "这是原创章节正文，测试同一章分成多个网页时的衔接。", count: 15)
        web.loadHTMLString("<h1 id='chaptername'>第一章</h1><div id='txt'><a href='javascript:report()'>『如果章节错误，点此举报』</a><br>第(1/3)页<br>" + paragraph + "<br>(本章未完,请翻页)<script>location.href='https://ads.test'</script></div><a id='pt_next' href='/chapter_2.html'>下章</a>", baseURL: URL(string: "https://novel.test/chapter.html"))
        for _ in 0..<120 {
            if (try? await web.evaluateJavaScript("document.querySelector('#txt') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let article = try await ArticleReader.extract(web)
        XCTAssertEqual(article.next?.absoluteString, "https://novel.test/chapter_2.html")
        XCTAssertEqual(article.title, "第一章")
        XCTAssertEqual(article.text.trimmingCharacters(in: .whitespacesAndNewlines), paragraph)
        XCTAssertFalse(article.html.contains("本章未完")); XCTAssertFalse(article.html.contains("点此举报"))
    }
    @MainActor func testReaderAppearanceUpdatesWithoutReloadingOrRepeatingChapterTitle() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let body = String(repeating: "<p>这是一段用于验证阅读字号调整和页面位置的原创内容。</p>", count: 60)
        let pages = [ReaderArticle(title: "同一章", html: body, text: "page one", url: URL(string: "https://reader.test/1")!, next: nil),
                     ReaderArticle(title: "同一章", html: body, text: "page two", url: URL(string: "https://reader.test/2")!, next: nil)]
        let host = UIHostingController(rootView: ArticleSurface(articles: pages, size: 18, line: 1.6, theme: "paper"))
        window.rootViewController = host; window.makeKeyAndVisible()
        func findWeb(_ view: UIView) -> WKWebView? { if let web = view as? WKWebView { return web }; return view.subviews.lazy.compactMap { findWeb($0) }.first }
        var web: WKWebView?
        for _ in 0..<120 {
            web = findWeb(host.view)
            if let web, (try? await web.evaluateJavaScript("document.querySelectorAll('article').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let surface = try XCTUnwrap(web)
        let headings = try await surface.evaluateJavaScript("document.querySelectorAll('h1').length") as? Int
        XCTAssertEqual(headings, 1)
        _ = try await surface.evaluateJavaScript("window.souloRetained=42;window.scrollTo(0,800)")
        host.rootView = ArticleSurface(articles: pages, size: 24, line: 2, theme: "dark")
        try await Task.sleep(for: .milliseconds(250))
        let retained = try await surface.evaluateJavaScript("window.souloRetained") as? Int
        let size = try await surface.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String
        let line = try await surface.evaluateJavaScript("getComputedStyle(document.body).lineHeight") as? String
        XCTAssertEqual(retained, 42); XCTAssertEqual(size, "24px"); XCTAssertEqual(line, "48px")
        XCTAssertGreaterThan(surface.scrollView.contentOffset.y, 400)
    }
    func testPasswordFreeTransferStillUsesSessionAndReportsSuccessfulTransfers() async throws {
        let server = WiFiTransferServer(directory: root, requiresPairing: false)
        let ready = expectation(description: "ready"), received = expectation(description: "received"), sent = expectation(description: "sent")
        let box = RefinementPortBox()
        server.onState = { port, _ in if let port { box.set(port); ready.fulfill() } }
        server.onTransfer = { event in
            XCTAssertEqual(event.name, "hello.txt"); XCTAssertEqual(event.kind, .text); XCTAssertEqual(event.size, 5)
            if event.direction == .received { received.fulfill() } else { sent.fulfill() }
        }
        try server.start(wifiOnly: false); defer { server.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", body: Data? = nil, cookie: String? = nil, origin: String? = nil, host: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(box.get())" + path)!)
            req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 5
            if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
            if let host { req.setValue(host, forHTTPHeaderField: "Host") }
            let (data,response) = try await session.data(for: req)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let info = try await request("/session")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: info.0) as? [String: Bool])?["requiresPairing"], false)
        let blocked = try await request("/files"); XCTAssertEqual(blocked.1.statusCode, 401)
        let crossOrigin = try await request("/pair", method: "POST", body: Data(), origin: "https://unrelated.test")
        XCTAssertEqual(crossOrigin.1.statusCode, 403)
        let rebound = try await request("/pair", method: "POST", body: Data(), origin: "http://unrelated.test:\(box.get())", host: "unrelated.test:\(box.get())")
        XCTAssertEqual(rebound.1.statusCode, 403)
        let pair = try await request("/pair", method: "POST", body: Data())
        XCTAssertEqual(pair.1.statusCode, 200)
        let cookie = try XCTUnwrap(pair.1.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
        let upload = try await request("/file?name=hello.txt", method: "PUT", body: Data("hello".utf8), cookie: cookie)
        XCTAssertEqual(upload.1.statusCode, 201)
        let downloaded = try await request("/file?name=hello.txt", cookie: cookie)
        XCTAssertEqual(downloaded.0, Data("hello".utf8))
        let list = try await request("/files", cookie: cookie)
        let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: list.0) as? [[String: Any]])
        XCTAssertEqual(files.first?["kind"] as? String, "text")
        XCTAssertEqual(files.first?["extension"] as? String, "txt")
        await fulfillment(of: [received, sent], timeout: 5)
    }
}
private final class RefinementPortBox: @unchecked Sendable {
    private let lock = NSLock(); private var port: UInt16 = 0
    func set(_ value: UInt16) { lock.lock(); defer { lock.unlock() }; port = value }
    func get() -> UInt16 { lock.lock(); defer { lock.unlock() }; return port }
}
