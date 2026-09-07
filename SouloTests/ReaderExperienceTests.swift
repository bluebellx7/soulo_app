import XCTest
import SwiftUI
import WebKit
@testable import Soulo

final class ReaderExperienceTests: XCTestCase {
    @MainActor private func page(_ body: String) async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        web.loadHTMLString("<html><head><title>第一章 雨后的城市</title></head><body data-fixture='ready'>" + body + "</body></html>", baseURL: URL(string: "https://reading.test/chapter1"))
        for _ in 0..<120 {
            if (try? await web.evaluateJavaScript("document.body?.dataset.fixture === 'ready' && document.readyState === 'complete'")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Fixture did not load")
        return web
    }
    private var prose: String { String(repeating: "雨后的城市渐渐安静下来。她推开书店的门，看见窗边摆着一本旧书。故事从这里开始，每一页都记录着不同的相遇。", count: 8) }

    @MainActor func testUnnamedNovelAndDelayedContentPreserveParagraphs() async throws {
        let body = prose
        let web = try await page("<div id='story'></div>")
        let quoted = String(data: try JSONSerialization.data(withJSONObject: [body]), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("setTimeout(() => {document.getElementById('story').innerHTML = " + quoted + "[0] + '<br><br>' + " + quoted + "[0]}, 500)")
        let article = try await ArticleReader.extractWhenReady(web)
        XCTAssertTrue(article.text.contains(body))
        XCTAssertGreaterThanOrEqual(article.html.components(separatedBy: "<p>").count - 1, 2)
        XCTAssertFalse(article.html.contains("<script"))
        let capability = await WebPageToolsAvailability.inspect(web)
        // The conservative hint must never determine whether manual extraction is allowed.
        XCTAssertEqual(capability.mediaCount, 0)
    }

    @MainActor func testEmbeddedArticleAndDynamicMediaAvailability() async throws {
        let web = try await page("<iframe></iframe>")
        let emptyMedia = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(emptyMedia, WebMediaPlaybackState())
        let body = prose
        let quoted = String(data: try JSONSerialization.data(withJSONObject: ["<article><h1>Embedded story</h1><p>" + body + "</p></article><video src='/movie.mp4'></video>"]), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("const d=document.querySelector('iframe').contentDocument;d.open();d.write(" + quoted + "[0]);d.close()")
        let article = try await ArticleReader.extract(web)
        XCTAssertTrue(article.text.contains(body))
        let available = await WebPageToolsAvailability.inspect(web)
        XCTAssertTrue(available.likelyReadable)
        XCTAssertEqual(available.mediaCount, 1)
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        let playback = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(playback, WebMediaPlaybackState(count: 1, rate: 2))
        let updatedMenu = await WebPageToolsAvailability.inspect(web)
        XCTAssertEqual(updatedMenu.mediaRate, 2)
        _ = try await web.evaluateJavaScript("document.querySelector('iframe').contentDocument.querySelector('video').remove()")
        let after = await WebPageToolsAvailability.inspect(web)
        XCTAssertEqual(after.mediaCount, 0)
        let removedMedia = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(removedMedia, WebMediaPlaybackState())
    }

    @MainActor func testNavigationOnlyPageDoesNotProduceAnArticle() async throws {
        let links = (0..<120).map { "<a href='/chapter\($0)'>第 \($0) 章 小说章节目录</a><br>" }.joined()
        let web = try await page("<nav>" + links + "</nav><main><h1>目录</h1>" + links + "</main>")
        do { _ = try await ArticleReader.extract(web); XCTFail("A table of contents is not an article") }
        catch { }
        let available = await WebPageToolsAvailability.inspect(web)
        XCTAssertFalse(available.likelyReadable)
    }

    func testExplicitDouyinVideoKeepsSpeedEntryDuringPlayerLoading() {
        let empty = WebPageToolsAvailability()
        for link in [
            "https://so.douyin.com/s?pd=video&actv_aid=7632605205065977151&keyword=test",
            "https://www.douyin.com/video/7632605205065977151",
            "https://m.douyin.com/share/video/7632605205065977151/"
        ] {
            XCTAssertTrue(empty.shouldShowMediaRate(for: URL(string: link)), link)
        }
        for link in [
            "https://so.douyin.com/s?keyword=test&pd=video",
            "https://so.douyin.com/s?pd=video&actv_aid=",
            "https://www.douyin.com/", "https://www.douyin.com/video/",
            "https://www.douyin.com/video/search",
            "https://fake-douyin.com/video/123", "https://douyin.com.example.com/video/123",
            "https://example.com/article"
        ] {
            XCTAssertFalse(empty.shouldShowMediaRate(for: URL(string: link)), link)
        }
        XCTAssertFalse(empty.shouldShowMediaRate(for: nil))
        XCTAssertTrue(WebPageToolsAvailability(mediaCount: 1).shouldShowMediaRate(for: URL(string: "https://example.com/article")))
    }

    @MainActor func testReadabilityFailureDoesNotHideDetectedVideo() async throws {
        let web = try await page("<video src='/movie.mp4'></video>")
        _ = try await web.callAsyncJavaScript(#"""
            const original = document.querySelectorAll.bind(document);
            document.querySelectorAll = selector => {
                if (selector.startsWith('article,')) throw new Error('Readability unavailable');
                return original(selector);
            };
            """#, arguments: [:], in: nil, contentWorld: .defaultClient)
        let result = await WebPageToolsAvailability.inspect(web)
        XCTAssertFalse(result.likelyReadable)
        XCTAssertEqual(result.mediaCount, 1)
        XCTAssertTrue(result.shouldShowMediaRate(for: web.url))
    }

    @MainActor func testPreformattedNovelAndCSSHiddenNoise() async throws {
        let web = try await page("<style>.invisible{display:none}</style><div id='chaptercontent'><pre>" + prose + "\n\n" + prose + "</pre><div class='invisible'>HIDDEN SHOULD NOT APPEAR</div></div>")
        let article = try await ArticleReader.extract(web)
        XCTAssertTrue(article.isNovel)
        XCTAssertFalse(article.html.contains("<pre"))
        XCTAssertFalse(article.text.contains("HIDDEN SHOULD NOT APPEAR"))
        XCTAssertGreaterThanOrEqual(article.html.components(separatedBy: "<p>").count - 1, 2)
    }

    @MainActor func testUserAgentOverrideIsIsolatedValidatedAndReversible() {
        let first = WebViewModel(), second = WebViewModel()
        first.webView = WKWebView(); second.webView = WKWebView()
        let original = second.webView?.customUserAgent
        XCTAssertTrue(first.setUserAgentOverride("SouloReader/1.0"))
        XCTAssertEqual(first.webView?.customUserAgent, "SouloReader/1.0")
        XCTAssertEqual(second.webView?.customUserAgent, original)
        for invalid in ["", "   ", "hello\r\nInjected: true", String(repeating: "a", count: 1025), "bad\u{0}agent"] {
            XCTAssertFalse(first.setUserAgentOverride(invalid))
            XCTAssertEqual(first.webView?.customUserAgent, "SouloReader/1.0")
        }
        first.setDesktopModeEnabled(true)
        XCTAssertTrue(first.setUserAgentOverride(nil))
        XCTAssertEqual(first.webView?.customUserAgent, AppConstants.desktopWebViewUserAgent)
        XCTAssertNil(first.userAgentOverride)
    }

    @MainActor func testBookLayoutFontProgressAndChapterJump() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let text = String(repeating: "<p>" + prose + "</p>", count: 5)
        let first = ReaderArticle(title: "第一章 雨后的城市", html: text, text: prose, url: URL(string: "https://reading.test/1")!, next: nil, isNovel: true)
        let second = ReaderArticle(title: "第二章 窗边的书", html: text, text: prose, url: URL(string: "https://reading.test/2")!, next: nil, isNovel: true)
        var progress = 0.0
        let host = UIHostingController(rootView: ArticleSurface(articles: [first, second], size: 18, line: 1.6, theme: "paper", onProgress: { progress = $0 }))
        window.rootViewController = host; window.makeKeyAndVisible()
        func findWeb(_ view: UIView) -> WKWebView? { if let web = view as? WKWebView { return web }; return view.subviews.lazy.compactMap { findWeb($0) }.first }
        var web: WKWebView?
        for _ in 0..<160 {
            web = findWeb(host.view)
            if let web, (try? await web.evaluateJavaScript("document.querySelectorAll('article').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let surface = try XCTUnwrap(web)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThan(progress, 0.05, "Initial layout should report the start, not a completed book")
        let indent = try await surface.evaluateJavaScript("getComputedStyle(document.querySelector('article > p')).textIndent") as? String
        XCTAssertEqual(indent, "36px")
        let screenshot = try await surface.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: screenshot); attachment.name = "reader-book-paper"; attachment.lifetime = .keepAlways; add(attachment)
        host.rootView = ArticleSurface(articles: [first, second], size: 20, line: 1.8, theme: "dark", font: "sans", targetChapter: second.id, onProgress: { progress = $0 })
        try await Task.sleep(for: .milliseconds(500))
        let chapterTop = try await surface.evaluateJavaScript("document.querySelectorAll('article')[1].getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(chapterTop), 0, accuracy: 2)
        XCTAssertGreaterThan(progress, 0.3)
        let family = try await surface.evaluateJavaScript("getComputedStyle(document.body).fontFamily") as? String
        XCTAssertTrue(family?.contains("system") == true)
        let dark = XCTAttachment(image: try await surface.takeSnapshot(configuration: nil)); dark.name = "reader-book-dark"; dark.lifetime = .keepAlways; add(dark)
    }
}
