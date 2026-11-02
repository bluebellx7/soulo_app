import XCTest
import SwiftUI
import WebKit
@testable import Soulo

@MainActor
final class SearchVideoNavigationTests: XCTestCase {
    func testExportBrowserScriptsForIsolation() throws {
        guard ProcessInfo.processInfo.environment["SOULO_EXPORT_ISOLATION_SCRIPTS"] == "1" else { throw XCTSkip("Opt-in source export for the isolated baseline app") }
        let scripts: [[String: Any]] = [
            ["name":"selection","source":WebViewScripts.textSelection,"world":"defaultClient","end":false],
            ["name":"resources","source":WebViewScripts.mediaResourceTracking,"world":"page","end":false],
            ["name":"video","source":WebVideoOrientationRuntime.script(),"world":WebVideoOrientationRuntime.world.name!,"end":true],
            ["name":"session","source":WebMediaSession.source,"world":WebMediaSession.world.name!,"end":false],
            ["name":"ads","source":AdBlockService.adHidingScript(allowlistedHosts: []),"world":"page","end":false],
            ["name":"privacy","source":WebViewScripts.privacyProtection(gpcEnabled:true,cookieBannerHandling:true,disabledHosts:[]),"world":"page","end":false],
            ["name":"navigation","source":BrowserNavigationGesture.script,"world":BrowserNavigationGesture.world.name!,"end":false]
        ]
        let path=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("isolation-scripts.json")
        try JSONSerialization.data(withJSONObject:scripts,options:[.sortedKeys]).write(to:path,options:.atomic)
        print("ISOLATION_SCRIPT_EXPORT count=\(scripts.count) file=\(path.lastPathComponent)")
    }

    private let keys = ["ad_block_enabled", "privacy_https_upgrade_enabled", "is_incognito", BrowserDomainNavigationPolicy.preferenceKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: "ad_block_enabled")
        UserDefaults.standard.set(false, forKey: "privacy_https_upgrade_enabled")
        UserDefaults.standard.set(true, forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: BrowserDomainNavigationPolicy.preferenceKey)
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        saved.removeAll()
        super.tearDown()
    }

    func testBaiduPreviewNavigationOnlyAcceptsTheDeclaredVideoLandingPage() throws {
        let source = URL(string: "https://www.baidu.com/s?wd=movie")!
        let target = URL(string: "https://m.baidu.com/video/page?nid=15578681846704204263&sign=4568578763597138977")!
        XCTAssertEqual(BaiduSearchVideoNavigation.destination(from: source, to: target), target)
        for page in ["https://example.com/s", "https://baidu.com.evil.test/s", "https://m.baidu.com/video/page", "file:///s"] {
            XCTAssertNil(BaiduSearchVideoNavigation.destination(from: try XCTUnwrap(URL(string: page)), to: target), page)
        }
        for page in ["https://evil.test/video/page?nid=1", "https://m.baidu.com.evil.test/video/page?nid=1", "http://m.baidu.com/video/page?nid=1", "https://m.baidu.com/video/page?nid=abc", "https://m.baidu.com/s?nid=1"] {
            XCTAssertNil(BaiduSearchVideoNavigation.destination(from: source, to: try XCTUnwrap(URL(string: page))), page)
        }
    }

    func testBaiduPreviewPictureResolverPreservesPlaybackAndBrowserControls() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <div class="c-result" tpl="vid_recommend"><article rl-link-data-url="https://m.baidu.com/video/page?nid=123">
        <div data-module="top_title" id="heading"><h3><span id="title">Video title</span></h3></div>
        <div class="cos-rich-video-player" id="picture"><div id="poster"></div><video id="native"></video>
        <div class="cos-rich-video-player-controls"><div class="cos-rich-video-player-controls-btn-group"><span id="pause">Pause</span></div></div>
        <div class="cos-rich-video-player-progress"><span id="seek">Seek</span></div>
        <button id="mute">Mute</button><span role="slider" id="slider">Volume</span>
        <span data-soulo-video-rotate id="rotate">Rotate</span><a id="source" href="https://m.bilibili.com/">Source</a>
        </div></article></div>
        """, baseURL: nil)
        try await wait(web, for: "!!document.getElementById('poster') && document.readyState==='complete'")
        for id in ["heading", "title", "picture", "poster", "native", "pause", "seek", "mute", "slider", "rotate", "source"] {
            let result = try await web.callAsyncJavaScript("""
            const path=[];for(let node=document.getElementById(id);node;node=node.parentElement)path.push(node);
            return (\(BaiduSearchVideoNavigation.resolver))('https://www.baidu.com/s?wd=movie',path);
            """, arguments: ["id": id], in: nil, contentWorld: .defaultClient)
            if ["heading", "title", "picture", "poster", "native"].contains(id) {
                XCTAssertEqual(result as? String, "https://m.baidu.com/video/page?nid=123", id)
            } else { XCTAssertNil(result as? String, id) }
        }
        _ = try await web.evaluateJavaScript("document.getElementById('native').controls=true; null")
        let native = try await web.callAsyncJavaScript("""
        const path=[];for(let node=document.getElementById('native');node;node=node.parentElement)path.push(node);
        return (\(BaiduSearchVideoNavigation.resolver))('https://www.baidu.com/s',path);
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertNil(native as? String, "Native player controls must remain usable")
        let intent = try await web.callAsyncJavaScript("""
        document.getElementById('native').muted=true;
        return (\(BaiduSearchVideoNavigation.playbackIntent))(document.querySelector('article'));
        """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(intent?["muted"] as? Bool, false, "An automatically muted preview must not mute explicit detail playback")
        XCTAssertEqual(intent?["playing"] as? Bool, true, "An unloaded or paused preview must not suppress explicit playback")
        XCTAssertEqual(intent?["time"] as? Double, 0)
    }

    private func host(_ model: WebViewModel) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        return (window, previous)
    }

    private func wait(_ web: WKWebView, for expression: String) async throws {
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Video condition timed out: \(expression), URL: \(String(describing: web.url))")
        throw URLError(.timedOut)
    }

    private func fixture(crossOrigin: Bool = false, destinationAutoplay: Bool = true, pauseAfterStartup: Bool = false) throws -> DownloadPlaybackHTTPFixture {
        let video = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures")))
        let player = "<video id='v' muted autoplay loop playsinline src='/clip.mp4' style='width:280px;height:160px'></video>"
        let detailPlayer = destinationAutoplay ? player : player.replacingOccurrences(of: "muted autoplay", with: "muted")
        let preview = crossOrigin ? """
            <script>addEventListener('message',e=>{if(typeof e.data.oldPaused==='boolean')window.__oldPaused=e.data.oldPaused;});</script>
            <iframe id='frame'></iframe><script>frame.src=location.origin.replace('127.0.0.1','localhost')+'/child.html';</script>
            """ : player + "<iframe id='frame' src='/empty.html'></iframe>"
        return try DownloadPlaybackHTTPFixture(files: [
            "/preview.html":Data(("<meta name='viewport' content='width=device-width,initial-scale=1'>" + preview + "<a id='next' href='/detail.html'>Video detail</a><a id='anchor' href='#section'>Section</a>").utf8),
            "/child.html":Data((player + "<script>setInterval(()=>parent.postMessage({oldPaused:v.paused},'*'),50);</script>").utf8),
            "/empty.html":Data("<p>Embedded page</p>".utf8),
            "/detail.html":Data(("<h1 id='detail'>Video detail</h1>" + detailPlayer + (pauseAfterStartup ? "<script>v.addEventListener('canplay',()=>setTimeout(()=>v.pause(),0),{once:true});</script>" : "")).utf8),
            "/clip.mp4":video
        ], heldPaths:["/detail.html"])
    }

    func testConsentInspectionDoesNotCreateHiddenAudiblePlayers() async throws {
        let video = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures")))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <div style="position:fixed;z-index:999;width:320px;height:220px;top:0;left:0">
        <video id="v" autoplay loop playsinline src="/clip.mp4" style="width:320px;height:180px"></video>
        <span>Video player with runtime mute state</span></div>
        <script>v.muted=true;window.clonedMedia=[];
        const clone=Node.prototype.cloneNode;
        Node.prototype.cloneNode=function(deep){
          const result=clone.call(this,deep);
          const media=[...(result.querySelectorAll?.('video,audio')||[])];
          if(result.matches?.('video,audio'))media.push(result);
          clonedMedia.push(...media);return result;
        };</script>
        """
        let server = try DownloadPlaybackHTTPFixture(files:["/index.html":Data(html.utf8),"/clip.mp4":video])
        let root = try await server.start(); defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:650),configuration:configuration)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene:scene), host = UIViewController()
        window.rootViewController=host;window.makeKeyAndVisible();host.view.addSubview(web)
        defer { web.setAllMediaPlaybackSuspended(true,completionHandler:nil);window.isHidden=true;previous?.makeKeyAndVisible() }
        web.load(URLRequest(url:root.appendingPathComponent("index.html")))
        try await wait(web,for:"window.v?.currentTime > 0.1 && !v.paused && v.muted")
        _ = try await web.evaluateJavaScript(WebViewScripts.privacyProtection(gpcEnabled:true,cookieBannerHandling:true,disabledHosts:[]))
        try await Task.sleep(for:.seconds(4))
        _ = try await web.evaluateJavaScript("v.pause()")
        try await Task.sleep(for:.seconds(1))
        let result = try await web.evaluateJavaScript("({original:{paused:v.paused,muted:v.muted,time:v.currentTime},clones:clonedMedia.map(m=>({connected:m.isConnected,paused:m.paused,muted:m.muted,time:m.currentTime,ready:m.readyState}))})") as? [String:Any]
        print("CONSENT_MEDIA_CLONES \(result ?? [:])")
        let clones = result?["clones"] as? [[String:Any]] ?? []
        XCTAssertFalse(clones.contains { $0["paused"] as? Bool == false && $0["muted"] as? Bool == false }, "Consent inspection must not create detached audible media: \(result ?? [:])")
        let nativeState = await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { continuation.resume(returning:$0) }
        }
        XCTAssertEqual(nativeState,.paused,"Pausing the visible player must leave no hidden playback")
        _ = try await web.evaluateJavaScript("clonedMedia.forEach(m=>{m.pause();m.removeAttribute('src');m.load()})")
    }

    func testNativeAndPageLinkNavigationPausePreviewBeforeTheDestinationLoads() async throws {
        for native in [false,true] { try await checkNavigation(native:native,crossOrigin:false) }
    }

    func testNavigationPausesCrossOriginPreviewAndDestinationCanStillAutoplay() async throws {
        try await checkNavigation(native:false,crossOrigin:true)
    }

    func testOutgoingPreviewCannotRestartWhileTheDestinationIsPending() async throws {
        try await checkNavigation(native: false, crossOrigin: false, restartPreview: true)
    }

    func testHistoryNavigationPreservesNativePlaybackAndInactiveTabSuspension() async throws {
        let server = try fixture(), root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel(), (window, previous) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(root.appendingPathComponent("preview.html"))
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        try await wait(web, for: "v.currentTime > 0.1 && !v.paused")
        model.mediaSession.beginNavigation(to: root.appendingPathComponent("detail.html"), navigationType: .backForward)
        let active: WKMediaPlaybackState = await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { continuation.resume(returning: $0) }
        }
        XCTAssertNotEqual(active, .suspended, "Interactive Back must not add a global media hold")
        model.mediaSession.setActive(false)
        model.mediaSession.beginNavigation(to: root.appendingPathComponent("detail.html"), navigationType: .backForward)
        let inactive: WKMediaPlaybackState = await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(inactive, .suspended, "History navigation must preserve an inactive tab's suspension")
    }

    func testNavigationSuspensionBalancesWithTabSwitchesAndCancellation() async throws {
        let server = try fixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(root.appendingPathComponent("preview.html"))
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        try await wait(web, for: "document.getElementById('v')?.currentTime > 0.1 && !v.paused")
        let destination = root.appendingPathComponent("detail.html")
        model.loadURL(destination)
        try await wait(web, for: "v.paused")
        for _ in 0..<3 {
            model.mediaSession.beginNavigation(to: destination)
            model.mediaSession.setActive(false)
            model.mediaSession.setActive(true)
        }
        model.reload() // While loading this is the toolbar's Stop action.
        _ = try await web.evaluateJavaScript("v.play().catch(()=>{}); null")
        try await wait(web, for: "!v.paused")
        model.loadURL(destination)
        try await wait(web, for: "v.paused")
        model.mediaSession.setActive(false)
        server.releaseDownloads()
        try await wait(web, for: "!!document.getElementById('detail') && v.readyState>=2")
        try await Task.sleep(for: .milliseconds(200))
        let start = try await web.evaluateJavaScript("v.currentTime") as? Double
        try await Task.sleep(for: .milliseconds(300))
        let end = try await web.evaluateJavaScript("v.currentTime") as? Double
        XCTAssertEqual(try XCTUnwrap(start), try XCTUnwrap(end), accuracy: 0.1, "A commit must not resume an inactive tab")
        model.mediaSession.setActive(true)
        let state: WKMediaPlaybackState = await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { continuation.resume(returning: $0) }
        }
        XCTAssertNotEqual(state, .suspended, "Tab activation must release the one shared suspension")
        // A document first loaded in an inactive tab may require a fresh play
        // request. It must be playable once active, without a leaked suspend.
        _ = try await web.evaluateJavaScript("v.play().catch(()=>{}); null")
        try await wait(web, for: "!v.paused && v.currentTime > 0.2")
    }

    private func checkNavigation(native: Bool, crossOrigin: Bool, restartPreview: Bool = false) async throws {
        let server = try fixture(crossOrigin:crossOrigin)
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window,previous) = try host(model)
        defer { window.isHidden=true; window.rootViewController=nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(root.appendingPathComponent("preview.html"))
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for:.milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        try await wait(web,for:crossOrigin ? "window.__oldPaused===false" : "document.getElementById('v')?.paused===false")
        if restartPreview {
            _ = try await web.evaluateJavaScript("v.addEventListener('pause',()=>setTimeout(()=>v.play().catch(()=>{}),40)); null")
        }
        if native { model.loadURL(root.appendingPathComponent("detail.html")) }
        else { _ = try await web.evaluateJavaScript("document.getElementById('next').click()") }
        // The held response keeps the outgoing document alive. Its player must
        // already be paused, including media in a different-origin iframe.
        try await wait(web,for:crossOrigin ? "window.__oldPaused===true" : "document.getElementById('v')?.paused===true")
        if restartPreview {
            try await Task.sleep(for: .milliseconds(400))
            let paused = try await web.evaluateJavaScript("v.paused") as? Bool
            XCTAssertEqual(paused, true, "The outgoing page restarted its preview during navigation")
        }
        XCTAssertTrue(model.mediaSession.isActive, "Navigation must not suspend the next document")
        server.releaseDownloads()
        try await wait(web,for:"!!document.getElementById('detail') && document.getElementById('v')?.paused===false")
        XCTAssertNil(model.errorMessage)
    }

    func testHashLinksSubframesAndBlockedPopupsDoNotStopTheCurrentVideo() async throws {
        let server = try fixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window,previous) = try host(model)
        defer { window.isHidden=true; window.rootViewController=nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(root.appendingPathComponent("preview.html"))
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for:.milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        try await wait(web,for:"document.getElementById('v')?.paused===false && !!document.getElementById('anchor')")
        _ = try await web.evaluateJavaScript("document.getElementById('anchor').click(); null")
        try await wait(web,for:"location.hash==='#section' && v.paused===false")
        _ = try await web.evaluateJavaScript("document.getElementById('frame').src='/empty.html?next=1'; null")
        try await Task.sleep(for:.milliseconds(300))
        let afterFrame = try await web.evaluateJavaScript("v.paused===false") as? Bool
        XCTAssertEqual(afterFrame,true,"Subframe navigation must preserve main-frame playback")
        _ = try await web.evaluateJavaScript("window.open('https://unrelated.invalid/ad','_blank'); null")
        try await Task.sleep(for:.milliseconds(300))
        let playing = try await web.evaluateJavaScript("v.paused===false") as? Bool
        XCTAssertEqual(playing,true,"Rejected popup must preserve main-frame playback")
        XCTAssertEqual(web.url?.host,root.host)
    }

    func testFragmentChangesAndAppHandoffsAreNotDocumentReplacements() {
        let page = URL(string:"https://example.com/video#first")!
        for type in [WKNavigationType.linkActivated,.other,.backForward] {
            XCTAssertFalse(WebMediaSession.replacesDocument(from:page,to:URL(string:"https://example.com/video#second")!,navigationType:type))
        }
        XCTAssertFalse(WebMediaSession.replacesDocument(from:page,to:URL(string:"baiduboxapp://video/detail")!,navigationType:.other))
        XCTAssertTrue(WebMediaSession.replacesDocument(from:page,to:page,navigationType:.reload))
        XCTAssertTrue(WebMediaSession.replacesDocument(from:page,to:URL(string:"https://example.com/next")!,navigationType:.linkActivated))
    }

    func testRemovedPreviewStopsAndMovingTheConnectedPlayerPreservesPlayback() async throws {
        let server = try fixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(root.appendingPathComponent("preview.html"))
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        try await wait(web, for: "document.getElementById('v')?.paused===false")
        _ = try await web.evaluateJavaScript("const holder=document.createElement('div');document.body.prepend(holder);holder.append(v);null")
        try await Task.sleep(for: .milliseconds(200))
        let moving = try await web.evaluateJavaScript("v.isConnected && !v.paused") as? Bool
        XCTAssertEqual(moving, true)
        _ = try await web.evaluateJavaScript("window.__removedPreview=v;v.remove();null")
        try await wait(web, for: "!__removedPreview.isConnected && __removedPreview.paused")
    }

    func testRetiredWebViewCannotKeepPlayingAfterRuntimeReleaseOrRebuild() async throws {
        for rebuild in [false, true] {
            let server = try fixture()
            let root = try await server.start()
            defer { server.stop() }
            let model = WebViewModel()
            let (window, previous) = try host(model)
            defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
            model.loadURL(root.appendingPathComponent("preview.html"))
            for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
            let old = try XCTUnwrap(model.webView)
            try await wait(old, for: "document.getElementById('v')?.currentTime > 0.1 && !v.paused")
            if rebuild { model.rebuildWebViewRuntime() }
            else { model.releaseWebViewRuntime() }
            try await Task.sleep(for: .milliseconds(200))
            let startValue = try await old.evaluateJavaScript("v.currentTime")
            let start = try XCTUnwrap(startValue as? Double)
            _ = try await old.evaluateJavaScript("v.play().catch(()=>{}); null")
            try await Task.sleep(for: .milliseconds(600))
            let endValue = try await old.evaluateJavaScript("v.currentTime")
            let end = try XCTUnwrap(endValue as? Double)
            XCTAssertEqual(end, start, accuracy: 0.1, "Retired WebView kept playing after \(rebuild ? "rebuild" : "release")")
        }
    }

    func testHandoffReleasesOldSourceAndStartsPausedDetailsWithTheChosenSoundState() async throws {
        for muted in [false, true] {
            let server = try fixture(destinationAutoplay: false, pauseAfterStartup: true)
            let root = try await server.start()
            defer { server.stop() }
            let model = WebViewModel()
            let (window, previous) = try host(model)
            defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
            for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
            let web = try XCTUnwrap(model.webView), probe = SearchMediaLifecycleProbe()
            let controller = web.configuration.userContentController
            controller.add(probe, contentWorld: WebMediaSession.world, name: "qaMediaLifecycle")
            controller.addUserScript(WKUserScript(source: SearchMediaLifecycleProbe.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: WebMediaSession.world))
            defer { controller.removeScriptMessageHandler(forName: "qaMediaLifecycle", contentWorld: WebMediaSession.world) }
            model.loadURL(root.appendingPathComponent("preview.html"))
            try await wait(web, for: "!!document.getElementById('v')")
            _ = try await web.evaluateJavaScript("v.play().catch(()=>{}); null")
            try await wait(web, for: "document.getElementById('v')?.readyState>=2 && !v.paused")
            _ = try await web.callAsyncJavaScript("v.currentTime=4;v.volume=0.65;v.muted=muted;await v.play();return true", arguments: ["muted": muted], in: nil, contentWorld: .defaultClient)
            let values = try await web.evaluateJavaScript("({time:v.currentTime,duration:v.duration,volume:v.volume,muted:v.muted,playing:!v.paused})") as? [String: Any]
            let target = root.appendingPathComponent("detail.html")
            let handoff = try XCTUnwrap(WebMediaPlaybackHandoff(target: target, values: try XCTUnwrap(values)))
            model.loadVideoDetail(target, mediaHandoff: handoff)
            try await wait(web, for: "document.getElementById('v')?.readyState===0 && v.paused && !v.getAttribute('src')")
            server.releaseDownloads()
            try await wait(web, for: "!!document.getElementById('detail') && !v.paused && v.currentTime>=4 && v.muted===\(muted)")
            let volume = try await web.evaluateJavaScript("v.volume") as? Double
            XCTAssertEqual(try XCTUnwrap(volume), handoff.volume, accuracy: 0.01)
            let hidden = probe.events.first { $0["event"] as? String == "pagehide" && ($0["url"] as? String)?.contains("preview.html") == true }
            let media = try XCTUnwrap(hidden?["media"] as? [[String: Any]])
            XCTAssertTrue(media.allSatisfy { $0["configuredSource"] as? Bool == false && $0["paused"] as? Bool == true && $0["ready"] as? Int == 0 }, "Old document kept a media resource: \(media)")
            web.goBack()
            try await wait(web, for: "location.pathname==='/preview.html' && document.getElementById('v')?.readyState>=2")
            let restoredSource = try await web.evaluateJavaScript("v.currentSrc.endsWith('/clip.mp4')") as? Bool
            XCTAssertEqual(restoredSource, true, "Back navigation must restore the released source")
        }
    }

    func testCancellingVideoDetailRestoresTheReleasedPreview() async throws {
        let server = try fixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(root.appendingPathComponent("preview.html"))
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        try await wait(web, for: "document.getElementById('v')?.readyState>=2 && !v.paused")
        let target = root.appendingPathComponent("detail.html")
        let handoff = try XCTUnwrap(WebMediaPlaybackHandoff(target: target,
            values: ["time": 0.0, "duration": 0.0, "volume": 1.0, "muted": false, "playing": true]))
        model.loadVideoDetail(target, mediaHandoff: handoff)
        try await wait(web, for: "v.readyState===0 && !v.getAttribute('src')")
        for _ in 0..<100 where !web.isLoading || model.estimatedProgress <= 0 || web.url?.path != "/detail.html" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(web.url?.path, "/detail.html")
        XCTAssertGreaterThan(model.estimatedProgress, 0)
        XCTAssertTrue(model.isLoading)
        model.reload() // Stop the held response.
        try await Task.sleep(for: .milliseconds(100))
        let playback: WKMediaPlaybackState = await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { continuation.resume(returning: $0) }
        }
        print("CANCEL_MEDIA_STATE \(playback.rawValue), \(try await web.evaluateJavaScript("({paused:v.paused,ready:v.readyState,source:!!v.getAttribute('src')})"))")
        try await wait(web, for: "v.readyState>=2 && !v.paused && !!v.getAttribute('src')")
    }

    func testLiveBaiduDocumentMediaHandoffAndSound() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_VIDEO_QA"] == "1" else { throw XCTSkip("Opt-in real media lifecycle check") }
        if ProcessInfo.processInfo.environment["SOULO_MEDIA_NORMAL_QA"] == "1" {
            UserDefaults.standard.set(false, forKey: "is_incognito")
        }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        let probe = SearchMediaLifecycleProbe()
        let controller = web.configuration.userContentController
        controller.add(probe, name: "qaMediaLifecycle")
        controller.addUserScript(WKUserScript(source: SearchMediaLifecycleProbe.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        defer { controller.removeScriptMessageHandler(forName: "qaMediaLifecycle") }
        var search = URLComponents(string: "https://www.baidu.com/s")!
        search.queryItems = [URLQueryItem(name: "wd", value: "20201年喜剧电影解说")]
        model.loadURL(try XCTUnwrap(search.url))
        func eventually(_ expression: String) async throws {
            for _ in 0..<1000 {
                if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("Live condition failed: \(expression)")
            throw URLError(.timedOut)
        }
        try await eventually("!!document.querySelector('.c-result[tpl=vid_recommend] article[rl-link-data-url]')")
        _ = try await web.evaluateJavaScript("document.querySelector('.c-result[tpl=vid_recommend] article[rl-link-data-url]').scrollIntoView({block:'center'}); null")
        try await eventually("[...document.querySelectorAll('video')].some(v=>!v.paused && v.currentTime>0.2)")
        try await Task.sleep(for: .seconds(10))
        let sourceValue = try await web.evaluateJavaScript("window.__qaMediaDocumentID")
        let sourceID = try XCTUnwrap(sourceValue as? String)
        print("LIVE_MEDIA_SOURCE \(try await web.evaluateJavaScript(SearchMediaLifecycleProbe.snapshot))")
        let sourceTimeValue = try await web.evaluateJavaScript("document.querySelector('video').currentTime")
        let sourceTime = try XCTUnwrap(sourceTimeValue as? Double)
        let sourceMuted = try await web.evaluateJavaScript("document.querySelector('video').muted") as? Bool
        XCTAssertEqual(sourceMuted, true, "Reproduce the default muted search preview")
        let eventsBeforeNavigation = probe.events.count
        // Use the production producer with the unchanged, muted preview.
        // Hardware-trusted clicking and native message routing are checked by
        // the separate title/picture UI tests, without rewriting isTrusted.
        let values = try await web.callAsyncJavaScript("""
        const card=document.querySelector('.c-result[tpl=vid_recommend] article[rl-link-data-url]');
        return {target:card.getAttribute('rl-link-data-url'),intent:(\(BaiduSearchVideoNavigation.playbackIntent))(card)};
        """, arguments: [:], in: nil, contentWorld: BrowserNavigationGesture.world) as? [String: Any]
        let target = try XCTUnwrap((values?["target"] as? String).flatMap(URL.init(string:)))
        let intent = try XCTUnwrap(values?["intent"] as? [String: Any])
        let handoff = try XCTUnwrap(WebMediaPlaybackHandoff(target: target, values: intent))
        XCTAssertFalse(handoff.muted)
        model.loadVideoDetail(target, mediaHandoff: handoff)
        try await eventually("location.hostname==='m.baidu.com' && !!document.querySelector('video') && document.querySelector('video').readyState>=2")
        try await Task.sleep(for: .seconds(2))
        print("LIVE_MEDIA_DESTINATION \(try await web.evaluateJavaScript(SearchMediaLifecycleProbe.snapshot))")
        let hasPreview = web.subviews.contains { $0.accessibilityIdentifier == "browser.navigation-preview" }
        print("LIVE_MEDIA_NATIVE active=\(model.mediaSession.isActive) player=\(MediaSession.shared.playing) preview=\(hasPreview)")
        let start = try await web.evaluateJavaScript("document.querySelector('video').currentTime") as? Double
        try await Task.sleep(for: .seconds(2))
        let end = try await web.evaluateJavaScript("document.querySelector('video').currentTime") as? Double
        let audible = try await web.evaluateJavaScript("[...document.querySelectorAll('video')].some(v=>!v.paused && !v.muted && v.volume>0)") as? Bool
        print("LIVE_MEDIA_AFTER_PLAY \(try await web.evaluateJavaScript(SearchMediaLifecycleProbe.snapshot))")
        let oldEvents = probe.events.dropFirst(eventsBeforeNavigation).filter { $0["doc"] as? String == sourceID }
        print("LIVE_MEDIA_OLD_AFTER_COMMIT \(oldEvents)")
        let report = XCTAttachment(string: String(describing: probe.events)); report.name = "document-media-events"; report.lifetime = .keepAlways; add(report)
        let activeOldMedia = oldEvents.flatMap { $0["media"] as? [[String: Any]] ?? [] }.filter {
            $0["paused"] as? Bool == false && ($0["ready"] as? Int ?? 0) >= 2
        }
        XCTAssertTrue(activeOldMedia.isEmpty, "The outgoing document actually played after resource release: \(activeOldMedia)")
        XCTAssertFalse(web.subviews.contains { $0.accessibilityIdentifier == "browser.navigation-preview" }, "Old page still covers the destination player")
        XCTAssertEqual(audible, true)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(start), sourceTime - 0.5, "The same video must retain the preview position")
        XCTAssertGreaterThan(try XCTUnwrap(end), try XCTUnwrap(start) + 0.3)
        let iconMuted = "(()=>{const icon=document.querySelector('[class*=voiceControlContainer] [class*=voiceOffSvg]');return !!icon && getComputedStyle(icon).display!=='none';})()"
        let initialIcon = try await web.evaluateJavaScript(iconMuted) as? Bool
        XCTAssertEqual(initialIcon, false, "The custom sound icon must agree with audible playback")
        for muted in [true, false, true, false] {
            _ = try await web.evaluateJavaScript("document.querySelector('[class*=voiceControlContainer]').click();null")
            try await eventually("document.querySelector('video').muted===\(muted) && (\(iconMuted))===\(muted)")
            let activeSound = try await web.evaluateJavaScript("[...document.querySelectorAll('video,audio')].some(m=>!m.paused&&!m.muted&&m.volume>0)") as? Bool
            XCTAssertEqual(activeSound, !muted, "The website's own sound button must control actual audio")
        }
        // The real UI test uses trusted touches. This programmatic control
        // click waits until the startup retry has expired before testing pause.
        try await Task.sleep(for: .seconds(2))
        _ = try await web.evaluateJavaScript("document.querySelector('[class*=playControlContainer]').click();null")
        try await eventually("document.querySelector('video').paused")
        let pausedTime = try await web.evaluateJavaScript("document.querySelector('video').currentTime") as? Double
        try await Task.sleep(for: .milliseconds(500))
        let stillTime = try await web.evaluateJavaScript("document.querySelector('video').currentTime") as? Double
        XCTAssertEqual(try XCTUnwrap(pausedTime), try XCTUnwrap(stillTime), accuracy: 0.1)
        let nativeState: WKMediaPlaybackState = await withCheckedContinuation { continuation in
            web.requestMediaPlaybackState { continuation.resume(returning: $0) }
        }
        XCTAssertNotEqual(nativeState, .playing, "Pausing the detail must leave no active WebKit playback")
        print("LIVE_MEDIA_CONTROL_CHECKS mute/unmute=4 pauseStopped=true nativeState=\(nativeState.rawValue)")
    }
}

@MainActor private final class SearchMediaLifecycleProbe: NSObject, WKScriptMessageHandler {
    var events: [[String: Any]] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? [String: Any], events.count < 1000 { events.append(value) }
    }
    static let snapshot = #"""
    JSON.stringify({doc:window.__qaMediaDocumentID,url:location.href,visibility:document.visibilityState,videos:[...document.querySelectorAll('video,audio')].map(v=>({time:v.currentTime,paused:v.paused,muted:v.muted,defaultMuted:v.defaultMuted,volume:v.volume,ready:v.readyState,connected:v.isConnected,rect:v.getBoundingClientRect().toJSON(),error:v.error?.message}))})
    """#
    static let source = #"""
    (()=>{
      const doc=crypto.randomUUID();window.__qaMediaDocumentID=doc;
      const send=event=>{try{webkit.messageHandlers.qaMediaLifecycle.postMessage({doc,event,url:location.href,time:performance.now(),media:[...document.querySelectorAll('video,audio')].map(v=>({time:v.currentTime,paused:v.paused,muted:v.muted,volume:v.volume,ready:v.readyState,hasSource:!!(v.currentSrc||v.getAttribute('src')||v.srcObject),configuredSource:!!(v.getAttribute('src')||v.srcObject||[...v.querySelectorAll('source')].some(n=>n.getAttribute('src')))}))});}catch(_){}};
      for(const name of ['play','playing','pause','ended','volumechange'])document.addEventListener(name,()=>send(name),true);
      for(const name of ['pagehide','pageshow','DOMContentLoaded'])window.addEventListener(name,()=>send(name));
      send('created');
    })();
    """#
}
