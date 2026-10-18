import XCTest
import WebKit
import UIKit
@testable import Soulo
#if SOULO_LOCAL_AI && canImport(SouloLocalAI)
import SouloLocalAI

@MainActor final class LocalAIIntegrationTests: XCTestCase {
    private typealias Fixture = (WebViewModel, WKWebView, UIWindow, UIWindow?)
    private func fixture(model existing: WebViewModel? = nil) async throws -> Fixture {
        let model = existing ?? WebViewModel()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible(); model.webView = web
        web.loadHTMLString("""
        <html><head><title>Local AI article</title><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body><main><article><h1>Weekend reading</h1><p>Read twelve pages in the morning and twelve in the afternoon.
        This article describes reading habits, careful note taking and keeping track of completed pages.</p></article></main>
        <div class="ad" id="sponsor" style="display:flex!important;height:80px">Advertisement: buy a subscription</div>
        <aside id="login" class="ad"><form><input aria-label="Password" type="password"><button>Log in</button></form></aside>
        <div class="ad" id="player"><video controls></video></div>
        <div class="ad" id="main-wrapper"><article><h1>Protected article</h1></article></div>
        <aside id="contents">Table of contents: introduction, examples and references</aside>
        <aside class="toc banner">Article navigation</aside>
        <nav><span class="banner">Site navigation</span></nav>
        </body></html>
        """, baseURL: URL(string: "https://local-ai.example/article"))
        for _ in 0..<100 {
            if !web.isLoading, web.url?.host == "local-ai.example", (try? await web.evaluateJavaScript("!!document.getElementById('sponsor')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        model.updateCurrentURL(web.url)
        return (model, web, window, previous)
    }
    private func close(_ fixture: Fixture) {
        fixture.0.releaseWebViewRuntime(); fixture.1.removeFromSuperview(); fixture.2.isHidden = true
        fixture.2.rootViewController = nil; fixture.3?.makeKeyAndVisible()
    }
    private func isolated(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    func testNoPageScriptIsInstalledUntilAssistantReadsThePage() async throws {
        let f = try await fixture(); defer { close(f) }
        let source = BrowserLocalAIPageSource(model: f.0)
        let before = try await isolated(f.1, "return typeof window.__souloLocalAI;") as? String
        XCTAssertEqual(before, "undefined")
        let page = try await source.read()
        XCTAssertEqual(page.title, "Local AI article")
        XCTAssertTrue(page.text.contains("twelve pages"))
        XCTAssertFalse(page.revision.isEmpty)
        let after = try await isolated(f.1, "return typeof window.__souloLocalAI;") as? String
        XCTAssertEqual(after, "object")
    }
    func testImageOnlyPageKeepsMetadataAndScreenshotForVisualTasks() async throws {
        let f = try await fixture(); defer { close(f) }
        _ = try await f.1.evaluateJavaScript("document.body.innerHTML='<img alt=\"\" width=300 height=200 src=\"data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22300%22 height=%22200%22%3E%3Crect width=%22300%22 height=%22200%22 fill=%22blue%22/%3E%3C/svg%3E\">';null")
        let source = BrowserLocalAIPageSource(model: f.0)
        let page = try await source.read()
        XCTAssertEqual(page.title, "Local AI article")
        XCTAssertTrue(page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let screenshot = try await source.screenshot()
        XCTAssertNotNil(UIImage(data: screenshot))
    }
    func testCleanupProtectsFormsMediaAndArticleContainersAndRestoresStyles() async throws {
        let f = try await fixture(); defer { close(f) }
        let source = BrowserLocalAIPageSource(model: f.0)
        let page = try await source.read()
        XCTAssertEqual(page.elements.count, 1, "Only the promotional block is eligible; login, playback and main content remain protected")
        let candidate = try XCTUnwrap(page.elements.first)
        XCTAssertTrue(candidate.text.contains("Advertisement"))
        let applied = try await source.apply(ids: [candidate.id], revision: page.revision)
        XCTAssertEqual(applied, 1)
        let hidden = try await f.1.evaluateJavaScript("getComputedStyle(document.getElementById('sponsor')).display") as? String
        XCTAssertEqual(hidden, "none")
        try await source.undo()
        let restored = try await f.1.evaluateJavaScript("document.getElementById('sponsor').style.getPropertyValue('display')+'|'+document.getElementById('sponsor').style.getPropertyPriority('display')") as? String
        XCTAssertEqual(restored, "flex|important")
    }
    func testCandidateCannotBeAppliedAfterItsTextChanges() async throws {
        let f = try await fixture(); defer { close(f) }
        let source = BrowserLocalAIPageSource(model: f.0)
        let page = try await source.read()
        let id = try XCTUnwrap(page.elements.first?.id)
        _ = try await f.1.evaluateJavaScript("document.getElementById('sponsor').textContent='Changed into useful content'")
        let applied = try await source.apply(ids: [id], revision: page.revision)
        XCTAssertEqual(applied, 0)
        let display = try await f.1.evaluateJavaScript("getComputedStyle(document.getElementById('sponsor')).display") as? String
        XCTAssertNotEqual(display, "none")
    }
    func testNewInspectionInvalidatesAnOldProposalAndUndoSurvivesReopening() async throws {
        let f = try await fixture(); defer { close(f) }
        let source = BrowserLocalAIPageSource(model: f.0)
        let old = try await source.read()
        let page = try await source.read()
        let id = try XCTUnwrap(page.elements.first?.id)
        do { _ = try await source.apply(ids: [id], revision: old.revision); XCTFail("Old proposals must be rejected") }
        catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
        _ = try await source.apply(ids: [id], revision: page.revision)
        let reopened = BrowserLocalAIPageSource(model: f.0)
        let restored = try await reopened.read()
        XCTAssertTrue(restored.canUndo)
        try await reopened.undo()
        let display = try await f.1.evaluateJavaScript("getComputedStyle(document.getElementById('sponsor')).display") as? String
        XCTAssertEqual(display, "flex")
    }
    func testNavigationInvalidatesProposalsAndImageCaptureHasContent() async throws {
        let f = try await fixture(); defer { close(f) }
        let source = BrowserLocalAIPageSource(model: f.0)
        let page = try await source.read()
        let image = try await source.screenshot()
        XCTAssertNotNil(UIImage(data: image))
        _ = try await f.1.evaluateJavaScript("history.pushState({},'', '/different')")
        do { _ = try await source.apply(ids: page.elements.map(\.id), revision: page.revision); XCTFail("Navigation must invalidate a proposal") }
        catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
    }
    func testPagePreviewSurvivesPushingChatAndRejectsNavigation() async throws {
        let f = try await fixture(); defer { close(f) }
        let source = BrowserLocalAIPageSource(model: f.0)
        let preview = try await source.screenshot()
        f.1.removeFromSuperview()
        XCTAssertNil(f.1.window)
        let retained = try await source.screenshot()
        XCTAssertEqual(retained, preview)
        let page = try await source.read()
        XCTAssertTrue(page.text.contains("twelve pages"))
        _ = try await f.1.evaluateJavaScript("history.pushState({},'', '/different')")
        do { _ = try await source.screenshot(); XCTFail("A different page must not reuse the previous screenshot") }
        catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
    }
    func testSwitchingTabsDuringExtractionCannotReturnThePreviousPage() async throws {
        let first = try await fixture(), second = try await fixture()
        defer { close(second); close(first) }
        var reads = 0
        let source = BrowserLocalAIPageSource(model: first.0, modelProvider: {
            reads += 1; return reads == 1 ? first.0 : second.0
        })
        do { _ = try await source.read(); XCTFail("Extraction must recheck the active tab after awaiting WebKit") }
        catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
    }
    func testUndoCannotRestoreADifferentTabAndStillWorksOnTheOriginal() async throws {
        let first = try await fixture(), second = try await fixture()
        defer { close(second); close(first) }
        var current = first.0
        let source = BrowserLocalAIPageSource(model: first.0, modelProvider: { current })
        let page = try await source.read()
        _ = try await source.apply(ids: page.elements.map(\.id), revision: page.revision)
        current = second.0
        do { try await source.undo(); XCTFail("Undo must remain associated with the edited tab") }
        catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
        let hidden = try await first.1.evaluateJavaScript("getComputedStyle(document.getElementById('sponsor')).display") as? String
        XCTAssertEqual(hidden, "none")
        current = first.0
        try await source.undo()
        let restored = try await first.1.evaluateJavaScript("getComputedStyle(document.getElementById('sponsor')).display") as? String
        XCTAssertEqual(restored, "flex")
    }
    private func withTools(reveal: @escaping () -> Void = {}, features: [String: () -> Void] = [:], _ body: (TabManager, LocalAITools) async throws -> Void) async throws {
        let key = "local-ai-tools-" + UUID().uuidString
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        let tabs = TabManager(storageKey: key)
        defer {
            tabs.tabs.forEach { $0.webViewModel.releaseWebViewRuntime(); $0.webViewModel.deletePersistedSnapshot() }
            tabs.saveToDisk(); UserDefaults.standard.removeObject(forKey: key)
        }
        tabs.tabs = (0..<4).map { i in
            let tab = BrowserTab(); tab.webViewModel.loadCachedURL(URL(string: "https://example.com/\(i)")!); return tab
        }
        tabs.activeTabIndex = 0
        let adapter = BrowserLocalAITools(search: SearchViewModel(), tabs: tabs, reveal: reveal, features: features)
        try await body(tabs, adapter.tools)
    }
    func testAReviewedBatchClosesTheIntendedTabsAfterIndicesChange() async throws {
        try await withTools { tabs, tools in
            let originalIDs = tabs.tabs.map(\.id)
            let calls = [LocalAIToolCall(tool: "tab_close", value: "1"), LocalAIToolCall(tool: "tab_close", value: "2")]
            for call in calls { _ = try await tools.preview(call) }
            for call in calls { _ = try await tools.perform(call) }
            XCTAssertEqual(tabs.tabs.map(\.id), Array(originalIDs.suffix(2)))
            XCTAssertEqual(Set(tabs.recentlyClosed.map(\.id)), Set(originalIDs.prefix(2)))
        }
    }
    func testRegisteredToolCatalogKeepsParameterContractsAndScopesDistinct() async throws {
        try await withTools(features: ["网页图片 / Page images": {}, "阅读原文 / Read original": {}, "设置 / Settings": {}]) { _, tools in
            XCTAssertEqual(Set(tools.catalog.map(\.id)).count, tools.catalog.count)
            XCTAssertEqual(tools.catalog.first(where: { $0.id == "set:appearance" })?.category, .appearance)
            XCTAssertEqual(tools.catalog.first(where: { $0.id == "set:reader.theme" })?.category, .reader)
            XCTAssertEqual(tools.catalog.first(where: { $0.id == "set:web_force_dark_pages" })?.category, .webAppearance)
            XCTAssertEqual(tools.catalog.first(where: { $0.id == "page_count_text" })?.verbatim, true)
            let attachment = XCTAttachment(data: try JSONEncoder().encode(tools.catalog), uniformTypeIdentifier: "public.json")
            attachment.name = "local-ai-browser-tools.json"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testEnhancedAgentExportsItsActualCatalog() async throws {
        let store = LocalAIModelStore.shared, previous = LocalAIModelStore.shared.selectedProfile
        store.select(.enhanced); defer { store.select(previous) }
        try await withTools(features: ["网页图片 / Page images": {}, "阅读原文 / Read original": {}, "设置 / Settings": {}]) { _, tools in
            XCTAssertTrue(tools.catalog.contains { $0.id == "page_read" })
            let attachment = XCTAttachment(data: try JSONEncoder().encode(tools.catalog), uniformTypeIdentifier: "public.json")
            attachment.name = "local-ai-enhanced-browser-tools.json"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testAgentKeepsAnalysisInChatUntilItChoosesToShowThePage() async throws {
        let store = LocalAIModelStore.shared, previous = LocalAIModelStore.shared.selectedProfile
        store.select(.enhanced); defer { store.select(previous) }
        var revealed = 0
        try await withTools(reveal: { revealed += 1 }) { _, tools in
            XCTAssertTrue(tools.catalog.contains { $0.id == "page_show" })
            tools.finishAgent([.init(tool: "page_scroll", value: "bottom"), .init(tool: "page_read")])
            XCTAssertEqual(revealed, 0, "Analysis must remain visible in the conversation")
            let show = LocalAIToolCall(tool: "page_show")
            _ = try await tools.preview(show); _ = try await tools.perform(show)
            XCTAssertEqual(revealed, 0, "Do not dismiss the conversation before recording the result")
            let continues = try await tools.checkpoint(show)
            XCTAssertFalse(continues)
            tools.finishAgent([show]); XCTAssertEqual(revealed, 1)
            tools.finish([.init(tool: "page_scroll", value: "top")])
            XCTAssertEqual(revealed, 2, "The lightweight model retains its single-step navigation behavior")
        }
    }
    func testAgentNavigationWaitsForRealPageBeforeReading() async throws {
        let store = LocalAIModelStore.shared, previous = LocalAIModelStore.shared.selectedProfile
        store.select(.enhanced); defer { store.select(previous) }
        try await withTools { tabs, tools in
            let model = try XCTUnwrap(tabs.activeWebViewModel)
            let f = try await fixture(model: model); defer { close(f) }
            let call = LocalAIToolCall(tool: "open_url", value: "https://www.swift.org/documentation/")
            _ = try await tools.preview(call); _ = try await tools.perform(call)
            let ready = try await tools.checkpoint(call)
            XCTAssertTrue(ready)
            XCTAssertTrue(f.1.url?.host?.hasSuffix("swift.org") == true)
            let read = LocalAIToolCall(tool: "page_read")
            _ = try await tools.preview(read)
            let observation = try await tools.perform(read)
            XCTAssertTrue(observation.contains("Swift"), String(observation.prefix(1800)))
            XCTAssertFalse(observation.contains("twelve pages in the morning"))
            tools.finishAgent([call, read])
        }
    }
    func testUndoRestoresTheReviewedClosedTabRatherThanTheMostRecentClose() async throws {
        try await withTools { tabs, tools in
            let requested = tabs.tabs[0].webViewModel.currentURL, unrelatedID = tabs.tabs[1].id
            let call = LocalAIToolCall(tool: "tab_close", value: "1")
            _ = try await tools.preview(call); _ = try await tools.perform(call)
            tabs.closeTab(id: unrelatedID)
            _ = try await tools.undo()
            XCTAssertEqual(tabs.activeWebViewModel?.currentURL, requested)
            XCTAssertTrue(tabs.recentlyClosed.contains(where: { $0.id == unrelatedID }))
        }
    }
    func testReviewedZoomRejectsSwitchingToAnotherTabBeforeConfirmation() async throws {
        try await withTools { tabs, tools in
            let call = LocalAIToolCall(tool: "set:page_zoom", value: "150")
            _ = try await tools.preview(call)
            tabs.switchToTab(at: 1)
            do { _ = try await tools.perform(call); XCTFail("The new active tab must not receive the previous tab's setting") }
            catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
            XCTAssertEqual(tabs.tabs[1].webViewModel.pageZoom, 1)
        }
    }
    func testExactCountReadsTheWholeRenderedPageWithoutHiddenTextOrInputValues() async throws {
        try await withTools { tabs, tools in
            let model = try XCTUnwrap(tabs.activeWebViewModel)
            model.updateCurrentURL(nil)
            let f = try await fixture(model: model); defer { close(f) }
            _ = try await f.1.evaluateJavaScript("document.body.innerHTML='<header>雞蛋 雞蛋</header><article>雞蛋</article><footer>雞蛋 雞蛋 雞蛋 雞蛋</footer><input value=雞蛋><div hidden>雞蛋 雞蛋</div>';null")
            let call = LocalAIToolCall(tool: "page_count_text", value: "雞蛋")
            _ = try await tools.preview(call)
            let receipt = try await tools.perform(call)
            XCTAssertTrue(receipt.contains("**7**"), receipt)
            let literal = LocalAIToolCall(tool: "page_count_text", value: "');alert(1);//")
            _ = try await tools.preview(literal)
            let zero = try await tools.perform(literal)
            XCTAssertTrue(zero.contains("**0**"), zero)
        }
    }
    func testFilteredLinksReadDestinationMetadataDeduplicateAndRejectSpoofedDomains() async throws {
        try await withTools { tabs, tools in
            let model = try XCTUnwrap(tabs.activeWebViewModel)
            model.updateCurrentURL(nil)
            let f = try await fixture(model: model); defer { close(f) }
            _ = try await f.1.callAsyncJavaScript("document.body.innerHTML=html;", arguments: ["html": """
            <a href="https://weibo.com/first">First</a><a href="https://weibo.com/first">Duplicate</a>
            <div class="result" data-log='{"mu":"https://m.weibo.com/second"}'><a href="https://www.baidu.com/link?url=tracking">Second</a></div>
            <a href="https://weibo.com.evil.example/spoof">Spoof</a><a hidden href="https://weibo.com/hidden">Hidden</a>
            <a href="javascript:alert(1)">Executable</a><a href="https://example.com">Unrelated</a>
            """], in: nil, contentWorld: .page)
            let call = LocalAIToolCall(tool: "page_links", value: "weibo.com")
            _ = try await tools.preview(call); _ = try await tools.perform(call)
            let result = try XCTUnwrap(tools.linkResult())
            XCTAssertEqual(result.links.map(\.url.absoluteString), ["https://weibo.com/first", "https://m.weibo.com/second"])
            XCTAssertEqual(result.sourceURL, f.1.url)
            let open = LocalAIToolCall(tool: "page_open_link", value: "2")
            _ = try await tools.preview(open)
            _ = try await f.1.evaluateJavaScript("document.querySelector('.result').remove();null")
            do { _ = try await tools.perform(open); XCTFail("A removed reviewed destination must not open another link") }
            catch { XCTAssertEqual(error as? LocalAIError, .pageChanged) }
        }
    }
    func testDomainFilteringScansBeyondInitialLinksAndDisclosesResultLimit() async throws {
        try await withTools { tabs, tools in
            let f = try await fixture(model: XCTUnwrap(tabs.activeWebViewModel)); defer { close(f) }
            _ = try await f.1.evaluateJavaScript("document.body.innerHTML=Array.from({length:220},(_,i)=>'<p><a href=\"https://example.com/'+i+'\">Item '+i+'</a></p>').join('')+'<a href=\"https://weibo.com/late\">Last post</a>';null")
            let filtered = LocalAIToolCall(tool: "page_links", value: "weibo.com")
            _ = try await tools.preview(filtered); _ = try await tools.perform(filtered)
            XCTAssertEqual(tools.linkResult()?.links.first?.url.absoluteString, "https://weibo.com/late")
            let all = LocalAIToolCall(tool: "page_links", value: "")
            _ = try await tools.preview(all); _ = try await tools.perform(all)
            XCTAssertEqual(tools.linkResult()?.links.count, 100)
            XCTAssertEqual(tools.linkResult()?.limited, true)
            for value in ["{\"filter\":\"weibo.com\"}", "https://user:password@weibo.com"] {
                do { _ = try await tools.preview(.init(tool: "page_links", value: value)); XCTFail("Malformed filter arguments must be rejected before execution") }
                catch { XCTAssertEqual(error as? LocalAIError, .invalidToolCall) }
            }
        }
    }
}
#endif
