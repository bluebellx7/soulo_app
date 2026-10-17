import XCTest
import WebKit
import UIKit
@testable import Soulo

@MainActor
final class WebEpisodeTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var bodies: [[String: Any]] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { bodies.append(body) }
        }
    }

    private func page(_ html: String, url: String = "https://www.pbpbw.com/player/68351-1-2.html") async throws -> (WKWebView, Capture) {
        let capture = Capture()
        let config = WKWebViewConfiguration()
        config.userContentController.add(capture, contentWorld: WebEpisodeRuntime.world, name: WebEpisodeRuntime.handler)
        config.userContentController.addUserScript(WKUserScript(source: WebEpisodeRuntime.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: WebEpisodeRuntime.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        web.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: url))
        for _ in 0..<100 {
            if !capture.bodies.isEmpty { return (web, capture) }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw ReadingToolError.invalid
    }

    func testMacCMSPlaylistsKeepSourcesAndRealEpisodeURLs() async throws {
        // Same structure and line lengths as pbpbw's detail page. Episode
        // numbers need not equal the URL's index (specials can shift it).
        let first = (1...197).map { "<li><a href='/player/68351-2-\($0).html'>第\($0)集</a></li>" }.joined()
        let second = (1...196).map { "<li><a href='/player/68351-1-\($0).html'>第\($0 + 1)集</a></li>" }.joined()
        let (web, capture) = try await page("""
        <div><h3>线路①</h3></div><ul class='stui-content__playlist'>\(first)</ul>
        <div><h3>线路②</h3></div><ul class='stui-content__playlist' style='display:none'>\(second)</ul>
        <a href='/html/900.html'>第900集</a>
        """)
        let url = try XCTUnwrap(web.url)
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: url))
        XCTAssertEqual(list.sources.map(\.title), ["线路①", "线路②"])
        XCTAssertEqual(list.sources.map { $0.episodes.count }, [197, 196])
        XCTAssertEqual(list.currentSource?.title, "线路②")
        XCTAssertEqual(list.currentSource?.episodes[1].title, "第3集")
        XCTAssertEqual(list.currentSource?.episodes[1].url.path, "/player/68351-1-2.html")
        let exposed = try await web.evaluateJavaScript("typeof window.__souloEpisodes")
        XCTAssertEqual(exposed as? String, "undefined")
    }

    func testDynamicPlaylistsNormalizeOrderAndRejectUnrelatedOrUnsafeLinks() async throws {
        let (web, capture) = try await page("<div id='root'></div>")
        _ = try await web.evaluateJavaScript(#"""
        document.getElementById('root').innerHTML=`<ul class='episode-list'>
        <li><a href='/player/68351-1-10.html'>第10集</a></li>
        <li><a href='/player/68351-1-2.html'>第2集</a></li>
        <li><a href='/player/68351-1-2.html#same'>第2集</a></li>
        <li><a href='/player/999-1-1.html'>第1集</a></li>
        <li><a href='https://ads.example/1'>第1集</a></li>
        <li><a href='javascript:alert(1)'>第1集</a></li></ul>`; null
        """#)
        for _ in 0..<100 where capture.bodies.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.first?.episodes.map(\.title), ["第2集", "第10集"])
        _ = try await web.evaluateJavaScript("document.getElementById('root').remove(); null")
        for _ in 0..<100 where capture.bodies.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
    }

    func testPlayerPageKeepsLineNamesAndExcludesPreviousNextLinks() async throws {
        let (web, capture) = try await page("""
        <div><a href='/player/68351-1-1.html'>上一集</a><a href='/player/68351-1-3.html'>下一集</a></div>
        <div class='tab-content' id='play-box'>
          <ul class='play-tab'><li><a>线路①</a></li><li><a>线路②</a></li></ul>
          <div class='play-content'>
            <div class='play-item'><ul class='stui-play__list'><li><a href='/player/68351-2-1.html'>第1集</a></li></ul></div>
            <div class='play-item active'><ul class='stui-play__list'>
              <li><a href='/player/68351-1-1.html'>第1集</a></li><li><a href='/player/68351-1-2.html'>第2集</a></li>
              <li><a href='/player/68351-1-3.html'>第3集</a></li>
            </ul></div>
          </div>
        </div>
        """)
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.map(\.title), ["线路①", "线路②"])
        XCTAssertEqual(list.sources.map { $0.episodes.count }, [1, 3])
        XCTAssertEqual(list.currentSource?.title, "线路②")
    }

    func testFallbackGroupsPlaybackLinksAndIgnoresCatalogPages() async throws {
        let (web, capture) = try await page("<ul><li><a href='/play/68351-1-1.html'>EP1</a></li><li><a href='/play/68351-1-2.html'>EP2</a></li></ul>")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.first?.episodes.count, 2)
        let (_, catalog) = try await page("<ul><li><a href='/html/68351.html'>第195集</a></li></ul>", url: "https://www.pbpbw.com/show/4.html")
        XCTAssertEqual((catalog.bodies.first?["sources"] as? [Any])?.count, 0)
    }

    func testStaleResultsAndOldPageStateAreDiscarded() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/play/1-1-1.html"))
        let body: [String: Any] = ["pageURL": url.absoluteString,
            "sources": [["title":"Line", "episodes":[["title":"EP1", "url":url.absoluteString]]]]]
        let model = WebViewModel()
        model.episodeList = try XCTUnwrap(WebEpisodeList.parse(body, pageURL: url))
        XCTAssertNil(WebEpisodeList.parse(body, pageURL: URL(string: "https://example.com/other")!))
        model.beginPageNavigation()
        XCTAssertNil(model.episodeList)
    }

    func testGenericEpisodeLinksDoNotDependOnSiteClassesOrURLTemplates() async throws {
        let cases: [(String, [String])] = [
            ("<video></video><div class='custom-buttons'><a href='/watch?show=7&ep=10'>Episode 10</a><a href='/watch?show=7&ep=2'>Episode 2</a></div>", ["Episode 2", "Episode 10"]),
            ("<h2>播放列表</h2><div><button data-url='/items/uuid-a'>第十二集</button><button data-href='/items/uuid-b'>第十一集</button></div>", ["第十一集", "第十二集"]),
            ("<h2>Season 1</h2><ul><li><a href='/items/a'>S01E03</a></li><li><a href='/items/b'>S01E02</a></li></ul>", ["S01E02", "S01E03"]),
            ("<video></video><div><a href='/parts/a'>Episodio 12</a><a href='/parts/b'>Episodio 2</a></div>", ["Episodio 2", "Episodio 12"]),
            ("<video></video><div><a href='/parts/a'>الحلقة ١٢</a><a href='/parts/b'>الحلقة ٢</a></div>", ["الحلقة ٢", "الحلقة ١٢"])
        ]
        for (html, expected) in cases {
            let (web, capture) = try await page(html, url: "https://generic-media.example/series/test")
            let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)), html)
            XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title), expected)
        }
    }

    func testGenericDetectionRejectsPaginationRecommendationsAndCatalogCards() async throws {
        let (web, capture) = try await page("""
        <video></video>
        <nav><ul><li><a href='/watch?page=1'>1</a></li><li><a href='/watch?page=2'>2</a></li></ul></nav>
        <ul class='related'><li><a href='/watch/100'>Episode 1</a></li><li><a href='/watch/200'>Episode 2</a></li></ul>
        <ul><li><a href='/detail/100'>Show A — 第10集</a></li><li><a href='/detail/200'>Show B — 第20集</a></li></ul>
        """, url: "https://generic-media.example/series/test")
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
    }

    func testBilibiliPartsAndCollectionsUsePageIDsAndRealTitles() async throws {
        let (web, _) = try await page("""
        <script>window.__INITIAL_STATE__={videoData:{title:'课程',pages:[{page:1,part:'起步'},{page:2,part:'实践'}],ugc_season:{title:'合集',sections:[{title:'后续',episodes:[{bvid:'BV1NextA',title:'附录甲'},{bvid:'BV1NextB',title:'附录乙'}]}]}}}</script>
        """,url:"https://m.bilibili.com/video/BV1Current/")
        let value = try await web.evaluateJavaScript(WebEpisodeSiteData.script)
        let body = try XCTUnwrap(value as? [String:Any])
        let list = try XCTUnwrap(WebEpisodeList.parse(body,pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.map { $0.episodes.count },[2,2])
        XCTAssertEqual(list.sources[0].episodes.map(\.title),["P1 起步","P2 实践"])
        XCTAssertEqual(list.sources[0].episodes[1].url.query,"p=2")
        XCTAssertTrue(WebEpisodeList.matches(list.sources[0].episodes[0].url,try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources[1].episodes[1].url.path,"/video/BV1NextB")
    }

    func testYoukuAndGenericStructuredListsExcludeRecommendationsAndUnsafeURLs() async throws {
        let (web, _) = try await page("""
        <script>window.__INITIAL_DATA__={episodes:[{videoId:'XExampleA',title:'第1集'},{videoId:'XExampleB',title:'第2集'},{title:'Invalid'}],recommendations:{episodes:[{url:'/v_show/id_XAd1.html',title:'Ad1'},{url:'/v_show/id_XAd2.html',title:'Ad2'}]}}</script>
        """,url:"https://v.youku.com/v_show/id_XExampleA.html")
        let value = try await web.evaluateJavaScript(WebEpisodeSiteData.script)
        let body = try XCTUnwrap(value as? [String:Any])
        let list = try XCTUnwrap(WebEpisodeList.parse(body,pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.count,1)
        XCTAssertEqual(list.sources[0].episodes.map(\.title),["第1集","第2集"])
        XCTAssertEqual(list.sources[0].episodes[1].url.path,"/v_show/id_XExampleB.html")
        let (generic, _) = try await page("""
        <script type='application/ld+json'>{"@type":"TVSeries","name":"Drama","episode":[{"name":"Opening","url":"/watch/a"},{"name":"Ending","url":"/watch/b"},{"name":"Unsafe","url":"javascript:alert(1)"}]}</script>
        """,url:"https://generic.example/series/a")
        let genericValue = try await generic.evaluateJavaScript(WebEpisodeSiteData.script)
        let genericBody = try XCTUnwrap(genericValue as? [String:Any])
        XCTAssertEqual(WebEpisodeList.parse(genericBody,pageURL:try XCTUnwrap(generic.url))?.sources[0].episodes.count,2)
    }

    func testBilibiliNavigationRejectsStateFromThePreviousVideo() async throws {
        let (web, _) = try await page("""
        <script>window.__INITIAL_STATE__={videoData:{bvid:'BV1OldVideo',pages:[{page:1,part:'Old A'},{page:2,part:'Old B'}],
        ugc_season:{sections:[{episodes:[{bvid:'BV1OldVideo',title:'Old A'},{bvid:'BV1OtherOld',title:'Old B'}]}]}}}</script>
        """, url:"https://m.bilibili.com/video/BV1Current/")
        let stale=try await web.evaluateJavaScript(WebEpisodeSiteData.script)
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(stale as? [String:Any]), pageURL:try XCTUnwrap(web.url)))
        _ = try await web.evaluateJavaScript("window.__INITIAL_STATE__.videoData.bvid='BV1Current';null")
        let current=try await web.evaluateJavaScript(WebEpisodeSiteData.script)
        let list=try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(current as? [String:Any]),pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.first?.episodes.map(\.title),["P1 Old A","P2 Old B"])
    }

    func testFallbackDockOnlyAppearsWithoutAVisiblePlayerAndRejectsSyntheticInput() async throws {
        let (web, capture) = try await page("<ul class='episode-list'><li><a href='/play/68351-1-1.html'>EP1</a></li><li><a href='/play/68351-1-2.html'>EP2</a></li></ul>")
        let dockVisible = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockVisible as? Bool,true)
        _ = try await web.evaluateJavaScript("document.getElementById('soulo-episode-dock').click();null")
        XCTAssertFalse(capture.bodies.contains { $0["action"] != nil })
        _ = try await web.evaluateJavaScript("const v=document.createElement('video');v.style.cssText='position:fixed;top:0;left:0;width:300px;height:180px';document.body.append(v);null")
        try await Task.sleep(for:.milliseconds(500))
        let dockHidden = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockHidden as? Bool,false)
        _ = try await web.evaluateJavaScript("document.querySelector('video').remove();null")
        try await Task.sleep(for:.milliseconds(500))
        let dockRestored = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockRestored as? Bool,true)
    }

    func testInvisiblePlayerDoesNotHideDockAndStyleChangesUpdateIt() async throws {
        let (web, _) = try await page("""
        <div id='player' style='opacity:0'><video style='width:300px;height:180px'></video></div>
        <ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>
        """)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let initial = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(initial as? Bool, true)
        for (opacity, expected) in [("1", false), ("0", true)] {
            _ = try await web.evaluateJavaScript("document.getElementById('player').style.opacity='\(opacity)';null")
            try await Task.sleep(for: .milliseconds(400))
            let present = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
            XCTAssertEqual(present as? Bool, expected)
        }
    }

    func testStructuredEpisodesRefreshAndClearWithoutReloadingThePage() async throws {
        let model = WebViewModel()
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, contentWorld: WebEpisodeRuntime.world, name: WebEpisodeRuntime.handler)
        config.userContentController.addUserScript(WKUserScript(source: WebEpisodeRuntime.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: WebEpisodeRuntime.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        model.webView = web
        defer {
            config.userContentController.removeScriptMessageHandler(forName: WebEpisodeRuntime.handler, contentWorld: WebEpisodeRuntime.world)
            model.releaseWebViewRuntime()
        }
        web.loadHTMLString(#"""
        <html><body><script id="series" type="application/ld+json">
        {"@type":"TVSeries","episode":[{"name":"Opening","url":"/watch/a"},{"name":"Ending","url":"/watch/b"}]}
        </script></body></html>
        """#, baseURL: URL(string: "https://generic.example/series/current"))
        func waitForTitles(_ expected: [String]) async throws {
            for _ in 0..<160 {
                if (model.episodeList?.sources.flatMap(\.episodes).map(\.title) ?? []) == expected { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Expected \(expected); got \(model.episodeList?.sources.flatMap(\.episodes).map(\.title) ?? [])")
        }
        try await waitForTitles(["Opening", "Ending"])
        _ = try await web.evaluateJavaScript(#"""
        document.getElementById('series').textContent=JSON.stringify({'@type':'TVSeries',episode:[
          {name:'New A',url:'/watch/a'},{name:'New B',url:'/watch/b'},{name:'New C',url:'/watch/c'}]});null
        """#)
        try await waitForTitles(["New A", "New B", "New C"])
        _ = try await web.evaluateJavaScript("document.getElementById('series').remove();document.body.insertAdjacentHTML('beforeend',\"<ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>\");null")
        try await waitForTitles(["EP1", "EP2"])
        _ = try await web.evaluateJavaScript("document.querySelector('.episode-list').remove();null")
        try await waitForTitles([])
        XCTAssertNil(model.episodeList)
    }

    func testShadowPlayerToolbarReplacesFallbackDockAndRestoresItWhenHidden() async throws {
        let (web, _) = try await page(#"""
        <div id="player"></div><script>document.getElementById('player').attachShadow({mode:'open'}).innerHTML='<video style="width:300px;height:180px"></video>'</script>
        <ul class="episode-list"><li><a href="/watch/1">EP1</a></li><li><a href="/watch/2">EP2</a></li></ul>
        """#)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        _ = try await web.evaluateJavaScript(WebVideoOrientationRuntime.script(), in:nil, contentWorld:WebVideoOrientationRuntime.world)
        for (opacity, expected) in [("1", false), ("0", true), ("1", false)] {
            _ = try await web.evaluateJavaScript("document.getElementById('player').style.opacity='\(opacity)';null")
            try await Task.sleep(for:.milliseconds(400))
            let present = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
            XCTAssertEqual(present as? Bool,expected)
        }
        _ = try await web.evaluateJavaScript("document.getElementById('player').shadowRoot.querySelector('video').remove();null")
        try await Task.sleep(for:.milliseconds(400))
        let restored=try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(restored as? Bool,true)
    }
}
