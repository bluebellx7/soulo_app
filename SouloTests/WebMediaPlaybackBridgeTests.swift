import XCTest
import AVFoundation
import WebKit
import UIKit
@testable import Soulo

@MainActor final class WebMediaPlaybackBridgeTests: XCTestCase {
    func testAuxiliaryPlayUsesVideoBoxStyleFollowsScrollAndYieldsToNormalTools() async throws {
        let web = try await page("""
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>body{margin:0;height:2200px}#player{margin:120px 20px 0;width:300px;height:180px;background:#222}</style>
        <span id='v' hidden></span><div id='player'></div>
        """)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in: nil, contentWorld: WebVideoOrientationRuntime.world)
        let placed = try await web.evaluateCompatibleJavaScript("window.__souloVideoOrientation.setFallbackTarget('__soulo_configured','Play')", in: nil, contentWorld: WebVideoOrientationRuntime.world)
        XCTAssertEqual(placed as? Bool, true)
        try await Task.sleep(for: .milliseconds(250))
        let measured = try await web.evaluateJavaScript("""
        (()=>{const box=document.getElementById('player').getBoundingClientRect(),control=document.querySelector('[data-soulo-video-fallback]'),r=control.getBoundingClientRect(),s=getComputedStyle(control);
        return {top:r.top,right:r.right,boxTop:box.top,boxRight:box.right,width:r.width,height:r.height,radius:s.borderRadius,background:s.backgroundColor};})()
        """) as? [String: Any]
        let geometry = try XCTUnwrap(measured)
        XCTAssertEqual(try XCTUnwrap(geometry["width"] as? Double), 40, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(geometry["height"] as? Double), 40, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(geometry["top"] as? Double), try XCTUnwrap(geometry["boxTop"] as? Double))
        XCTAssertLessThan(try XCTUnwrap(geometry["right"] as? Double), try XCTUnwrap(geometry["boxRight"] as? Double))
        _ = try await web.evaluateJavaScript("scrollTo(0,80);null")
        try await Task.sleep(for: .milliseconds(200))
        let moved = try await web.evaluateJavaScript("document.querySelector('[data-soulo-video-fallback]').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(moved), try XCTUnwrap(geometry["top"] as? Double) - 80, accuracy: 2)
        _ = try await web.evaluateJavaScript("scrollTo(0,600);null")
        try await Task.sleep(for: .milliseconds(200))
        let hiddenDisplay = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('[data-soulo-video-fallback]')).display") as? String
        XCTAssertEqual(hiddenDisplay, "none")
        _ = try await web.evaluateJavaScript("scrollTo(0,0);document.getElementById('player').innerHTML='<video style=\"width:300px;height:180px\"></video>';null")
        try await Task.sleep(for: .milliseconds(450))
        let fallbackCount = try await web.evaluateJavaScript("document.querySelectorAll('[data-soulo-video-fallback]').length") as? Int
        XCTAssertEqual(fallbackCount, 0)
        let style = try await web.evaluateJavaScript("(()=>{const s=getComputedStyle(document.querySelector('[data-soulo-video-rotate]'));return {radius:s.borderRadius,background:s.backgroundColor}})()") as? [String: String]
        XCTAssertEqual(style?["radius"], geometry["radius"] as? String)
        XCTAssertEqual(style?["background"], geometry["background"] as? String)
        let refused = try await web.evaluateCompatibleJavaScript("window.__souloVideoOrientation.setFallbackTarget('__soulo_configured','Play')", in: nil, contentWorld: WebVideoOrientationRuntime.world)
        XCTAssertEqual(refused as? Bool, false, "Normal tools and auxiliary Play must remain mutually exclusive")
    }

    func testHoldSpeedToastRejectsInvalidRatesAndStaleReleaseAndResetsForNavigation() async throws {
        let model = WebViewModel()
        model.updateVideoHoldSpeed(.nan, token: "invalid")
        model.updateVideoHoldSpeed(100, token: "invalid")
        XCTAssertNil(model.videoHoldSpeed)
        model.updateVideoHoldSpeed(2, token: "first")
        model.updateVideoHoldSpeed(1.75, token: "second")
        model.endVideoHoldSpeed(token: "first", restoredRate: 1)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(model.videoHoldSpeed, 1.75, "A delayed release cannot dismiss a newer hold")
        model.endVideoHoldSpeed(token: "second", restoredRate: 1.25)
        XCTAssertEqual(model.videoHoldSpeed, 1.25, "The release receipt shows the actual restored rate")
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertNil(model.videoHoldSpeed)
        model.updateVideoHoldSpeed(2, token: "third")
        model.beginPageNavigation()
        XCTAssertNil(model.videoHoldSpeed)
        model.updateVideoHoldSpeed(2, token: "fourth")
        model.releaseWebViewRuntime()
        XCTAssertNil(model.videoHoldSpeed)
    }
    func testBottomVideoClearanceFollowsPlayerLayoutAndResetsAfterDismissal() async throws {
        let web = try await page("""
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <div id="player"><video id="v" controls style="width:300px;height:160px"></video></div>
        """)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let model = WebViewModel()
        model.webView = web
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        let controller = web.configuration.userContentController
        controller.add(coordinator, contentWorld: WebVideoOrientationRuntime.world, name: WebVideoOrientationRuntime.handler)
        defer {
            controller.removeScriptMessageHandler(forName: WebVideoOrientationRuntime.handler, contentWorld: WebVideoOrientationRuntime.world)
            model.releaseWebViewRuntime()
        }
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in: nil, contentWorld: WebVideoOrientationRuntime.world)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.needsVideoViewportClearance, "An ordinary inline video must not resize the page")

        func update(_ script: String, expected: Bool) async throws {
            _ = try await web.evaluateJavaScript(script + "; null")
            for _ in 0..<60 {
                if model.hasBottomVideoControls == expected { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(model.hasBottomVideoControls, expected)
        }
        try await update("document.getElementById('player').style.cssText='position:fixed;inset:0'; document.getElementById('v').style.cssText='width:100%;height:100%'", expected: true)
        // Native avoidance shortens the viewport; detection must remain stable.
        web.frame.size.height = 536
        _ = try await web.evaluateJavaScript("dispatchEvent(new Event('resize')); null")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.hasBottomVideoControls)
        try await update("document.getElementById('player').style.opacity='0'", expected: false)
        try await update("document.getElementById('player').style.opacity='1'", expected: true)
        try await update("document.getElementById('player').remove()", expected: false)

        // Players inside open shadow roots use the same geometry detection.
        try await update("const host=document.createElement('div'); host.id='shadow-player'; host.attachShadow({mode:'open'}).innerHTML='<video controls style=\"position:fixed;inset:0;width:100%;height:100%\"></video>'; document.body.append(host)", expected: true)
        try await update("document.getElementById('shadow-player').remove()", expected: false)
        model.hasBottomVideoControls = true
        model.beginPageNavigation()
        XCTAssertFalse(model.hasBottomVideoControls, "Detection must not leak into the next page")
    }

    func testVideoRotationControlsFollowDynamicVideosAndRejectSyntheticClicks() async throws {
        let web = try await page("<video id='v' style='width:300px;height:160px'></video>")
        let messages = RotationMessages()
        web.configuration.userContentController.add(messages, contentWorld: WebVideoOrientationRuntime.world,
            name: WebVideoOrientationRuntime.handler)
        defer { web.configuration.userContentController.removeScriptMessageHandler(forName: WebVideoOrientationRuntime.handler,
            contentWorld: WebVideoOrientationRuntime.world) }
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in: nil, contentWorld: WebVideoOrientationRuntime.world)
        let isolated = try await web.evaluateJavaScript("typeof window.__souloVideoOrientation")
        XCTAssertEqual(isolated as? String, "undefined")
        _ = try await web.evaluateJavaScript("document.getElementById('v').dispatchEvent(new Event('webkitbeginfullscreen')); document.querySelectorAll('[data-soulo-video-rotate] button').forEach(button => button.click()); document.body.insertAdjacentHTML('beforeend','<video id=second style=\"width:300px;height:160px\"></video>'); null")
        try await Task.sleep(for: .milliseconds(250))
        let count = try await web.evaluateJavaScript("document.querySelectorAll('[data-soulo-video-rotate]').length")
        XCTAssertEqual(count as? Int, 2)
        XCTAssertEqual(messages.count, 0, "A page cannot synthesize a trusted rotation request")
        XCTAssertEqual(messages.actions.filter { $0 == "sourceReady" }.count, 2, "Resource discovery is distinct from a privileged rotation request")
        _ = try await web.evaluateJavaScript("document.getElementById('v').remove(); null")
        try await Task.sleep(for: .milliseconds(250))
        let remaining = try await web.evaluateJavaScript("document.querySelectorAll('[data-soulo-video-rotate]').length")
        XCTAssertEqual(remaining as? Int, 1)
    }

    func testNativeFullscreenRecoversBeforeAnInlineControlIsVisible() async throws {
        let web = try await page("<video id='v' style='display:none'></video>")
        let messages = RotationMessages()
        web.configuration.userContentController.add(messages, contentWorld: WebVideoOrientationRuntime.world, name: WebVideoOrientationRuntime.handler)
        defer { web.configuration.userContentController.removeScriptMessageHandler(forName: WebVideoOrientationRuntime.handler,
            contentWorld: WebVideoOrientationRuntime.world) }
        _ = try await web.evaluateCompatibleJavaScript("Object.defineProperty(document.getElementById('v'),'webkitDisplayingFullscreen',{get:()=>true});" + WebVideoOrientationRuntime.script(),
                                            in: nil, contentWorld: WebVideoOrientationRuntime.world)
        for _ in 0..<40 where messages.count == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(messages.count, 1, "An already-fullscreen media document must recover its native toolbar")
        XCTAssertEqual(messages.actions.filter { $0 == "nativeFullscreen" }.count, 1)
        let rawToken = try await web.evaluateJavaScript("document.getElementById('v').getAttribute('data-soulo-media-id')")
        let token = try XCTUnwrap(rawToken as? String)
        XCTAssertFalse(token.isEmpty)
        let applied = try await web.callAsyncJavaScript("return await window.__souloVideoOrientation.setRate(token, 2);",
            arguments: ["token": token], in: nil, contentWorld: WebVideoOrientationRuntime.world)
        XCTAssertEqual(applied as? Bool, true, "Native video tools must work without a visible inline toolbar")
    }

    func testVideoToolsStayCompactAcrossPageViewports() async throws {
        for viewport in ["<meta name='viewport' content='width=device-width,initial-scale=1'>", "",
                         "<meta name='viewport' content='width=1280'>",
                         "<meta name='viewport' content='width=device-width,initial-scale=2'>"] {
            let web = try await page("""
            \(viewport)<style>body{margin:0}button{width:9px!important;height:9px!important}svg{width:4px!important;height:4px!important}</style>
            <video id='v' style='width:100%;height:300px'></video>
            <ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>
            """)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene:scene)
            window.rootViewController = UIViewController()
            window.rootViewController?.view.addSubview(web)
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            _ = try await web.evaluateCompatibleJavaScript(WebEpisodeRuntime.script,in:nil,contentWorld:WebEpisodeRuntime.world)
            _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(),in:nil,contentWorld:WebVideoOrientationRuntime.world)
            try await Task.sleep(for:.milliseconds(300))
            let dimensions = try await web.evaluateCompatibleJavaScript("""
            (()=>{const button=document.querySelector('[data-video-toggle]'),r=button.getBoundingClientRect(),s=visualViewport.scale;
              const icon=button.querySelector('svg').getBoundingClientRect();return {width:r.width*s,height:r.height*s,icon:icon.width*s}})()
            """,in:nil,contentWorld:WebVideoOrientationRuntime.world) as? [String:Double]
            XCTAssertEqual(try XCTUnwrap(dimensions?["width"]),40,accuracy:0.8,viewport)
            XCTAssertEqual(try XCTUnwrap(dimensions?["height"]),40,accuracy:0.8,viewport)
            XCTAssertEqual(try XCTUnwrap(dimensions?["icon"]),20,accuracy:0.8,viewport)
            _ = try await web.evaluateJavaScript("document.getElementById('v').hidden=true;null")
            try await Task.sleep(for:.milliseconds(400))
            let dockWidth = try await web.evaluateCompatibleJavaScript("document.getElementById('soulo-episode-dock').getBoundingClientRect().width*visualViewport.scale",
                in:nil,contentWorld:WebEpisodeRuntime.world) as? Double
            XCTAssertEqual(try XCTUnwrap(dockWidth),48,accuracy:0.8,viewport)
            web.frame.size = CGSize(width:760,height:390)
            try await Task.sleep(for:.milliseconds(350))
            let resizedDockWidth = try await web.evaluateCompatibleJavaScript("document.getElementById('soulo-episode-dock').getBoundingClientRect().width*visualViewport.scale",
                in:nil,contentWorld:WebEpisodeRuntime.world) as? Double
            XCTAssertEqual(try XCTUnwrap(resizedDockWidth),48,accuracy:0.8,"Wide viewport: "+viewport)
        }
    }

    func testEmbeddedVideoToolbarReceivesParentScaleAndZoomUpdates() async throws {
        let model = WebViewModel()
        let coordinator = WebViewRepresentable.Coordinator(viewModel:model)
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(coordinator,contentWorld:WebVideoOrientationRuntime.world,name:WebVideoOrientationRuntime.handler)
        controller.addUserScript(WKUserScript(source:WebVideoOrientationRuntime.script(),injectionTime:.atDocumentEnd,
            forMainFrameOnly:false,in:WebVideoOrientationRuntime.world))
        let web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:600),configuration:config)
        model.webView = web
        web.scrollView.delegate = coordinator
        web.navigationDelegate = coordinator
        coordinator.observe(webView:web,viewModel:model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer {
            controller.removeScriptMessageHandler(forName:WebVideoOrientationRuntime.handler,contentWorld:WebVideoOrientationRuntime.world)
            model.releaseWebViewRuntime();window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible()
        }
        web.loadHTMLString("<body style='margin:0'><iframe style='width:100%;height:600px;border:0' srcdoc=\"<video style='width:100%;height:300px'></video>\"></iframe></body>",baseURL:URL(string:"https://media.test/"))
        for _ in 0..<120 where model.mediaFrameInfos.isEmpty { try await Task.sleep(for:.milliseconds(25)) }
        let frame = try XCTUnwrap(model.mediaFrameInfos.first)
        for (factor,zoom) in [(1.0,1.0),(1.5,1.0),(1.0,1.5),(1.0,0.5)] {
            model.setPageZoom(zoom)
            if factor != 1 { web.scrollView.setZoomScale(web.scrollView.zoomScale*factor,animated:false) }
            coordinator.scrollViewDidZoom(web.scrollView)
            try await Task.sleep(for:.milliseconds(350))
            let values = try await web.evaluateCompatibleJavaScript("""
            (()=>{const m=window.__souloOverlayControls.metrics(),r=document.querySelector('[data-video-toggle]').getBoundingClientRect();return {scale:m.scale,width:r.width*m.scale}})()
            """,in:frame,contentWorld:WebVideoOrientationRuntime.world) as? [String:Double]
            let parentValue = try await web.evaluateJavaScript("visualViewport.scale")
            let parentScale = try XCTUnwrap(parentValue as? Double)*zoom
            XCTAssertEqual(try XCTUnwrap(values?["scale"]),parentScale,accuracy:0.01)
            XCTAssertEqual(try XCTUnwrap(values?["width"]),40,accuracy:0.8)
        }
    }

    func testVideoToolsCanHideWithoutReloadingThePageOrPausingItsVideo() async throws {
        let web = try await page("<video id='v' style='width:300px;height:160px'></video><p>Stable document</p>")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let model = WebViewModel(); model.webView = web
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in: nil, contentWorld: WebVideoOrientationRuntime.world)
        _ = try await web.evaluateJavaScript("window.pageIdentity='unchanged';window.pauses=0;document.getElementById('v').addEventListener('pause',()=>window.pauses++);null")
        try await Task.sleep(for: .milliseconds(200))
        coordinator.synchronizeVideoTools(enabled: false, on: web)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = try await web.evaluateJavaScript("(() => { const button=document.querySelector('[data-soulo-video-rotate]'); return !button || getComputedStyle(button).display === 'none'; })()")
        XCTAssertEqual(hidden as? Bool, true)
        coordinator.synchronizeVideoTools(enabled: true, on: web)
        try await Task.sleep(for: .milliseconds(100))
        let visible = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('[data-soulo-video-rotate]')).display !== 'none' && window.pageIdentity === 'unchanged' && window.pauses === 0")
        XCTAssertEqual(visible as? Bool, true)
    }

    func testAppPageZoomPreservesCompactVideoToolsAndEpisodeDock() async throws {
        let web = try await page("""
        <meta name='viewport' content='width=device-width,initial-scale=1'><video id='v' style='width:100%;height:300px'></video>
        <ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>
        """)
        let model = WebViewModel()
        model.webView = web
        let coordinator = WebViewRepresentable.Coordinator(viewModel:model)
        web.navigationDelegate = coordinator
        web.scrollView.delegate = coordinator
        coordinator.observe(webView:web,viewModel:model)
        let controller = web.configuration.userContentController
        controller.add(coordinator,contentWorld:WebVideoOrientationRuntime.world,name:WebVideoOrientationRuntime.handler)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer {
            controller.removeScriptMessageHandler(forName:WebVideoOrientationRuntime.handler,contentWorld:WebVideoOrientationRuntime.world)
            model.releaseWebViewRuntime()
            window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible()
        }
        _ = try await web.evaluateCompatibleJavaScript(WebEpisodeRuntime.script,in:nil,contentWorld:WebEpisodeRuntime.world)
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(),in:nil,contentWorld:WebVideoOrientationRuntime.world)
        for zoom in [1.0,1.5,2.0,0.5] {
            _ = try await web.evaluateJavaScript("document.getElementById('v').hidden=false;null")
            model.setPageZoom(zoom)
            try await Task.sleep(for:.milliseconds(400))
            let videoWidth = try await web.evaluateCompatibleJavaScript("document.querySelector('[data-video-toggle]').getBoundingClientRect().width*visualViewport.scale",
                in:nil,contentWorld:WebVideoOrientationRuntime.world) as? Double
            XCTAssertEqual(try XCTUnwrap(videoWidth)*zoom,40,accuracy:0.8,"Video, page zoom \(zoom)")
            _ = try await web.evaluateJavaScript("document.getElementById('v').hidden=true;null")
            try await Task.sleep(for:.milliseconds(400))
            let dockWidth = try await web.evaluateCompatibleJavaScript("document.getElementById('soulo-episode-dock').getBoundingClientRect().width*visualViewport.scale",
                in:nil,contentWorld:WebEpisodeRuntime.world) as? Double
            XCTAssertEqual(try XCTUnwrap(dockWidth)*zoom,48,accuracy:0.8,"Episodes, page zoom \(zoom)")
        }
    }

    private final class RotationMessages: NSObject, WKScriptMessageHandler {
        var actions: [String] = []
        var count: Int { actions.filter { !["ready", "viewport", "sourceReady"].contains($0) }.count }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let action = (message.body as? [String: Any])?["action"] as? String { actions.append(action) }
        }
    }

    func testToolbarHidesWhenPlayerAncestorsBecomeTransparent() async throws {
        let web = try await page("<div id='player'><video id='v' style='width:300px;height:180px'></video></div>")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in: nil, contentWorld: WebVideoOrientationRuntime.world)
        for (opacity, expected) in [("1", "flex"), ("0", "none"), ("1", "flex")] {
            _ = try await web.evaluateJavaScript("document.getElementById('player').style.opacity='\(opacity)';null")
            try await Task.sleep(for: .milliseconds(300))
            let display = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('[data-soulo-video-rotate]')).display")
            XCTAssertEqual(display as? String, expected)
        }
    }

    private func page(_ html: String = "<video id='v' src='data:video/mp4;base64,'></video>") async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        web.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: "https://media.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('v')")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ReadingToolError.invalid
    }
    private func nativeRate(_ web: WKWebView) async throws -> Double {
        let value = try await web.evaluateJavaScript("Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,'playbackRate').get.call(document.getElementById('v'))")
        return try XCTUnwrap(value as? Double)
    }

    func testIsolatedSetterBypassesPageWrapperThatPretendsToSetRate() async throws {
        let web = try await page()
        _ = try await web.evaluateJavaScript("Object.defineProperty(document.getElementById('v'), 'playbackRate', {get(){return 8},set(value){}});true")
        let rates = try await WebMediaPlaybackBridge.setRate(2, on: web)
        XCTAssertEqual(rates, [2])
        let actual = try await nativeRate(web)
        XCTAssertEqual(actual, 2)
        let state = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(state.rate, 2)
    }

    func testStartupResetIsRepairedAndReplacementInheritsSelectedRate() async throws {
        let web = try await page()
        _ = try await web.evaluateJavaScript("setTimeout(() => document.getElementById('v').playbackRate=1, 80)")
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        let repaired = try await nativeRate(web)
        XCTAssertEqual(repaired, 2)
        _ = try await web.evaluateJavaScript("const next=document.createElement('video');next.id='v';next.src='data:video/mp4;base64,';document.getElementById('v').replaceWith(next)")
        try await Task.sleep(for: .milliseconds(250))
        let replacement = try await nativeRate(web)
        XCTAssertEqual(replacement, 2)
        _ = try await web.evaluateJavaScript("const v=document.getElementById('v');v.playbackRate=1;v.dispatchEvent(new Event('loadedmetadata'));v.dispatchEvent(new Event('play'))")
        try await Task.sleep(for: .milliseconds(100))
        let restarted = try await nativeRate(web)
        XCTAssertEqual(restarted, 2)
    }

    func testPersistentSiteResetIsBoundedAndDoesNotReportSuccess() async throws {
        let web = try await page()
        _ = try await web.evaluateJavaScript("window.changes=0;const v=document.getElementById('v');v.addEventListener('ratechange',()=>{window.changes++;if(v.playbackRate!==1)v.playbackRate=1;v.dispatchEvent(new Event('play'))})")
        do { _ = try await WebMediaPlaybackBridge.setRate(2, on: web); XCTFail("Must not claim a rejected rate succeeded") }
        catch ReadingToolError.unsupported { }
        try await Task.sleep(for: .milliseconds(300))
        let changeValue = try await web.evaluateJavaScript("window.changes")
        let changes = try XCTUnwrap(changeValue as? Int)
        XCTAssertLessThan(changes, 20)
        try await Task.sleep(for: .milliseconds(200))
        let laterValue = try await web.evaluateJavaScript("window.changes")
        let later = try XCTUnwrap(laterValue as? Int)
        XCTAssertEqual(changes, later)
    }

    func testOneTimesReleasesRestorationAndNativeControlsWorkAfterStartup() async throws {
        let web = try await page()
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        try await Task.sleep(for: .milliseconds(2100))
        _ = try await web.evaluateJavaScript("document.getElementById('v').playbackRate=1.5")
        try await Task.sleep(for: .milliseconds(100))
        let nativeChoice = try await nativeRate(web)
        XCTAssertEqual(nativeChoice, 1.5)
        _ = try await WebMediaPlaybackBridge.setRate(1, on: web)
        _ = try await web.evaluateJavaScript("const v=document.getElementById('v');v.playbackRate=1.5;v.dispatchEvent(new Event('play'))")
        try await Task.sleep(for: .milliseconds(100))
        let released = try await nativeRate(web)
        XCTAssertEqual(released, 1.5)
    }

    func testVisiblePlayerDeterminesDisplayedRateInsteadOfHiddenPreload() async throws {
        let web = try await page("<video id='hidden' src='data:video/mp4;base64,' style='display:none'></video><video id='v' src='data:video/mp4;base64,' style='width:300px;height:200px'></video>")
        _ = try await web.evaluateJavaScript("document.getElementById('v').playbackRate=2")
        let state = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.rate, 2)
    }

    func testNavigationDoesNotCarryRateIntoAnotherDocument() async throws {
        let web = try await page()
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        web.loadHTMLString("<html><body><video id='next' src='data:video/mp4;base64,'></video></body></html>", baseURL: URL(string: "https://other.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('next')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let state = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(state.rate, 1)
        XCTAssertEqual(state.count, 1)
    }

    func testRealVideoTimelineAdvancesFasterAtTwoTimes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac",
            withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("video.mp4"))
        let html = root.appendingPathComponent("index.html")
        try "<html><body><video id='v' muted playsinline src='video.mp4'></video></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view.addSubview(web)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.stopLoading()
            web.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        web.loadFileURL(html, allowingReadAccessTo: root)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('v')?.readyState >= 2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.callAsyncJavaScript("await document.getElementById('v').play(); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        // play() resolves before WebKit's media clock necessarily starts. Wait
        // for observable playback, especially after the full suite has created
        // many WebKit processes; a stopped clock must still fail explicitly.
        var started = false
        for _ in 0..<100 {
            if (try await web.evaluateJavaScript("document.getElementById('v').currentTime > 0.05")) as? Bool == true {
                started = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(started, "The real video must start before measuring playback speed")
        guard started else { return }
        var deltas: [Double] = []
        for rate in [1.0, 2.0] {
            _ = try await WebMediaPlaybackBridge.setRate(rate, on: web)
            // Let WebKit finish switching the media pipeline before measuring steady-state speed.
            try await Task.sleep(for: .seconds(1))
            let before = try await web.evaluateJavaScript("JSON.stringify({time:v.currentTime,rate:v.playbackRate,ready:v.readyState,paused:v.paused,ended:v.ended})")
            print("WEB_MEDIA_BEFORE \(rate): \(String(describing: before))")
            let start = try await web.evaluateJavaScript("document.getElementById('v').currentTime") as! Double
            try await Task.sleep(for: .milliseconds(1000))
            let end = try await web.evaluateJavaScript("document.getElementById('v').currentTime") as! Double
            deltas.append(end - start)
            let after = try await web.evaluateJavaScript("JSON.stringify({time:v.currentTime,rate:v.playbackRate,ready:v.readyState,paused:v.paused,ended:v.ended})")
            print("WEB_MEDIA_AFTER \(rate): \(String(describing: after))")
        }
        XCTAssertGreaterThan(deltas[0], 0.3)
        XCTAssertGreaterThan(deltas[1], deltas[0] * 1.5)
        print("WEB_MEDIA_TIMELINE 1x=\(deltas[0]), 2x=\(deltas[1]) over 1 second")
    }

    func testVideoPausesInBackgroundAndRestoresCheckpointAfterRuntimeEviction() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("video.mp4"))
        let html = root.appendingPathComponent("index.html")
        try "<html><body><video id='v' muted playsinline src='video.mp4'></video></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let session = WebMediaSession()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func make() async throws -> WKWebView {
            let config = WKWebViewConfiguration(); config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            session.install(on: config.userContentController)
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
            session.webView = web; host.view.addSubview(web)
            web.loadFileURL(html, allowingReadAccessTo: root)
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("document.getElementById('v')?.readyState >= 1")) as? Bool == true { return web }
                try await Task.sleep(for: .milliseconds(25))
            }
            let state = try? await web.evaluateJavaScript("JSON.stringify({url:location.href,ready:document.readyState,video:!!document.getElementById('v'),media:document.getElementById('v')?.readyState,error:document.getElementById('v')?.error?.message,source:document.getElementById('v')?.currentSrc})")
            XCTFail("Media fixture failed to load: \(String(describing: state)); checkpoints \(session.checkpoints)")
            throw ReadingToolError.invalid
        }
        func number(_ script: String, in web: WKWebView) async throws -> Double {
            let result = try await web.evaluateJavaScript(script)
            return try XCTUnwrap(result as? Double)
        }
        let web = try await make()
        _ = try await web.callAsyncJavaScript("v.currentTime=4;v.playbackRate=1.5;await v.play();return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(400))
        await session.capture()
        session.setActive(false)
        try await Task.sleep(for: .milliseconds(200))
        let paused = try await number("v.currentTime", in: web)
        try await Task.sleep(for: .milliseconds(600))
        let stillPaused = try await number("v.currentTime", in: web)
        XCTAssertEqual(paused, stillPaused, accuracy: 0.15)
        session.setActive(true)
        try await Task.sleep(for: .milliseconds(700))
        let resumed = try await number("v.currentTime", in: web)
        XCTAssertGreaterThan(resumed, paused + 0.3)
        await session.capture()
        session.setActive(false)
        await session.capture()
        web.pauseAllMediaPlayback(completionHandler: nil); web.removeFromSuperview(); web.stopLoading(); session.detach()
        session.setActive(true)
        let restored = try await make()
        defer { restored.pauseAllMediaPlayback(completionHandler: nil); restored.removeFromSuperview() }
        try await Task.sleep(for: .milliseconds(400))
        let time = try await number("v.currentTime", in: restored)
        let rate = try await number("v.playbackRate", in: restored)
        XCTAssertGreaterThanOrEqual(time, resumed - 0.15, "Eviction must restore the same video position")
        XCTAssertEqual(rate, 1.5)
        let before = time
        try await Task.sleep(for: .milliseconds(600))
        let after = try await number("v.currentTime", in: restored)
        XCTAssertGreaterThan(after, before + 0.3, "Previously playing media resumes after restoring")
        _ = try await restored.evaluateJavaScript("v.pause()")
        await session.capture(); session.setActive(false); await session.capture()
        restored.removeFromSuperview(); restored.stopLoading(); session.detach(); session.setActive(true)
        let pausedRestore = try await make()
        defer { pausedRestore.pauseAllMediaPlayback(completionHandler: nil); pausedRestore.removeFromSuperview() }
        try await Task.sleep(for: .milliseconds(400))
        let staysPaused = try await pausedRestore.evaluateJavaScript("v.paused")
        XCTAssertEqual(staysPaused as? Bool, true, "A user-paused video must not autoplay when restored")

        // A checkpoint belongs to runtime restoration, not future explicit loads.
        session.reset()
        pausedRestore.loadFileURL(html, allowingReadAccessTo: root)
        for _ in 0..<200 {
            if (try? await pausedRestore.evaluateJavaScript("v.readyState >= 1 && v.currentTime < 0.1")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let freshTime = try await number("v.currentTime", in: pausedRestore)
        let freshRate = try await number("v.playbackRate", in: pausedRestore)
        XCTAssertLessThan(freshTime, 0.1, "A fresh load must not replay an embedded old checkpoint")
        XCTAssertEqual(freshRate, 1)

    }

}

extension WebMediaPlaybackBridgeTests {
    func testLiveMovieDirectoryCompatibilityAudit() async throws {
        guard let raw = ProcessInfo.processInfo.environment["SOULO_SITE_AUDIT_JSON"],
              let data = raw.data(using: .utf8), let sites = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw XCTSkip("Opt-in public movie directory compatibility audit")
        }
        let defaults = UserDefaults.standard, oldPrivate = defaults.object(forKey: "is_incognito")
        defaults.set(true, forKey: "is_incognito")
        let session = MediaSession.shared
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { session.stop(); defaults.set(oldPrivate, forKey: "is_incognito"); window.isHidden = true; previous?.makeKeyAndVisible() }
        var rows: [[String: Any]] = []
        for site in sites {
            guard let address = site["url"], let url = URL(string: address) else { continue }
            let model = WebViewModel()
            let desktop = ProcessInfo.processInfo.environment["SOULO_SITE_AUDIT_DESKTOP"] != "0"
            model.setDesktopModeEnabled(desktop)
            let representation = WebViewRepresentable(viewModel: model)
            let (web, coordinator) = representation.makeCompatibilityAuditWebView()
            defer { withExtendedLifetime(coordinator) {} }
            host.view.addSubview(web); web.frame = host.view.bounds
            model.loadURL(url)
            var row: [String: Any] = ["id": site["id"] ?? "", "name": site["name"] ?? "", "category": site["category"] ?? "", "entry": address]
            var snapshot = WebResourceSnapshot.empty
            var selectedResource: WebMediaResource?
            var visited = Set<String>()
            let isVideoCategory = ["streaming", "series", "anime", "documentary"].contains(site["category"] ?? "")
            for depth in 0..<(isVideoCategory ? 3 : 1) {
                for tick in 0..<24 {
                    try await Task.sleep(for: .milliseconds(250))
                    let minimumTicks = Int(ProcessInfo.processInfo.environment["SOULO_SITE_AUDIT_MIN_WAIT_TICKS"] ?? "7") ?? 7
                    if tick >= minimumTicks, !web.isLoading { break }
                }
                if let value = try? await WebResourceInspectionService.inspect(webView: web, frames: model.mediaFrameInfos) { snapshot = value }
                let resources = snapshot.videos + snapshot.configuredVideos
                selectedResource = resources.first { ["http", "https"].contains($0.url.scheme ?? "") }
                row["profile"] = "iPad " + (desktop ? "desktop" : "mobile") + ", private website data, normal app blockers and bridges"
                row["loadError"] = model.errorMessage ?? ""
                var controlsAvailable = false
                for frame: WKFrameInfo? in [nil] + model.mediaFrameInfos.map({ Optional($0) }) {
                    let count = (try? await web.evaluateCompatibleJavaScript("document.querySelectorAll('[data-soulo-video-rotate]').length", in: frame, contentWorld: .page)) as? Int ?? 0
                    if count > 0 { controlsAvailable = true; break }
                }
                row["videoControlsAvailable"] = controlsAvailable
                row["title"] = snapshot.pageTitle
                row["page"] = web.url?.absoluteString ?? address
                row["videoResources"] = resources.count
                row["fallbackPlayAvailable"] = model.configuredVideo != nil
                row["viewport"] = ["webWidth":web.bounds.width,"webHeight":web.bounds.height,"hostWidth":host.view.bounds.width,"hostHeight":host.view.bounds.height,"windowWidth":window.bounds.width,"windowHeight":window.bounds.height]
                if ProcessInfo.processInfo.environment["SOULO_SITE_AUDIT_DIAGNOSTICS"] == "1" {
                    var diagnostics: [[String: Any]] = []
                    let script = """
                    (()=>({url:location.href,state:document.readyState,videoCount:document.querySelectorAll('video').length,
                    videos:Array.from(document.querySelectorAll('video'),v=>({src:v.currentSrc,token:v.getAttribute('data-soulo-media-id'),rect:{w:v.getBoundingClientRect().width,h:v.getBoundingClientRect().height}})),
                    configs:Object.fromEntries(['player_aaaa','player_bbbb','player_data','player_config','__PLAYER_CONFIG__','videoInfo'].map(k=>[k,JSON.stringify(window[k])||''])),
                    observed:Array.from(window.__souloObservedResourceURLs||[]).filter(x=>/\\.(m3u8|mp4)/i.test(x)),
                    responses:window.__souloObservedMediaResponses||[],
                    timing:performance.getEntriesByType('resource').map(x=>x.name).filter(x=>/\\.(m3u8|mp4)/i.test(x)),
                    frames:Array.from(document.querySelectorAll('iframe'),f=>f.src)}))()
                    """
                    for frame: WKFrameInfo? in [nil] + model.mediaFrameInfos.prefix(8).map({ Optional($0) }) {
                        if let value = try? await web.evaluateCompatibleJavaScript(script, in: frame, contentWorld: .page) as? [String: Any] {
                            var item = value
                            if let target = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: frame) {
                                item["resolvedFallbackToken"] = target.token
                            }
                            diagnostics.append(item)
                        }
                    }
                    row["mediaDiagnostics"] = diagnostics
                    row["resourceSources"] = snapshot.videos.map { ["url":$0.url.absoluteString,"page":$0.sourcePageURL?.absoluteString ?? ""] }
                    row["configuredResources"] = snapshot.configuredVideos.count
                }
                row["sampleSources"] = model.episodeList?.sources.prefix(3).map { source in
                    ["title": source.title, "firstEpisode": source.episodes.first?.url.absoluteString ?? ""]
                } ?? []
                row["episodeSources"] = model.episodeList?.sources.count ?? 0
                row["episodes"] = model.episodeList?.sources.reduce(0, { $0 + $1.episodes.count }) ?? 0
                let text = ((try? await web.evaluateJavaScript("document.body?.innerText.slice(0,2000) || ''")) as? String) ?? ""
                if text.localizedCaseInsensitiveContains("verify you are human") || text.contains("Just a moment") || text.localizedCaseInsensitiveContains("access denied") {
                    row["restriction"] = "verification-or-access-denied"; break
                }
                if selectedResource != nil || !isVideoCategory { break }
                if let episode = model.episodeList?.currentSource?.episodes.first(where: { ["http", "https"].contains($0.url.scheme ?? "") && $0.url != web.url && !visited.contains($0.url.absoluteString) }) {
                    visited.insert(episode.url.absoluteString)
                    let ext = episode.url.pathExtension.lowercased()
                    if ["mp4", "m3u8", "mov", "m4v", "webm", "mkv", "mpd"].contains(ext) {
                        selectedResource = WebMediaResource(kind: .video, url: episode.url, title: episode.title, posterURL: nil,
                            delivery: ext == "m3u8" ? .hls : (ext == "mpd" ? .dash : .direct), sourcePageURL: web.url)
                        row["mediaSelectedFromEpisodes"] = true
                        break
                    }
                    model.loadURL(episode.url); continue
                }
                if depth == 0, let target = site["representative"], let next = URL(string: target), !target.contains("/cdn-cgi/") {
                    visited.insert(target); model.loadURL(next); continue
                }
                let candidates = (try? await web.evaluateJavaScript("Array.from(document.querySelectorAll('a[href]'),a=>a.href).filter(x=>/^https?:/.test(x))")) as? [String] ?? []
                let ranked = candidates.filter { URL(string: $0)?.host == web.url?.host && !visited.contains($0) && !$0.contains("/cdn-cgi/") }
                let next = ranked.first { $0.range(of: "/(vod/)?(play|vodplay|watch|player)[/-]", options: .regularExpression) != nil }
                    ?? ranked.first { $0.range(of: "/(movie|voddetail|detail|video|bangumi|view|vod|v|content|mov|anime|ju|tv|yingpian)[/-]", options: .regularExpression) != nil }
                guard let next, let target = URL(string: next) else { break }
                visited.insert(next); model.loadURL(target)
            }
            if let resource = selectedResource, isVideoCategory {
                let page = web.url
                for frame in model.mediaFrameInfos {
                    _ = try? await web.evaluateCompatibleJavaScript("document.querySelectorAll('video,audio').forEach(v=>v.pause());null", in: frame, contentWorld: .page)
                }
                let asset = await WebResourceMediaService.asset(for: resource, webView: web, preferDownloadedCopy: false)
                let attachment = UUID(), surface = session.pictureInPicture.attach(id: attachment, primary: true)
                if let surface { host.view.addSubview(surface); surface.frame = host.view.bounds }
                session.playerSurfaces += 1
                session.open(url: resource.url, pageURL: page, asset: asset, webView: web, persistPosition: false)
                let playbackTicks = Int(ProcessInfo.processInfo.environment["SOULO_SITE_AUDIT_PLAY_TICKS"] ?? "24") ?? 24
                var native = false
                for _ in 0..<playbackTicks {
                    try await Task.sleep(for: .milliseconds(250))
                    if session.hasVideo && session.pictureInPicture.surface?.playerLayer.isReadyForDisplay == true { native = true; break }
                    if session.error != nil { break }
                }
                row["nativeFirstFrame"] = native
                row["nativeError"] = session.error ?? session.startupWarning ?? ""
                session.stop(); session.pictureInPicture.detach(id: attachment); session.playerSurfaces -= 1
                surface?.removeFromSuperview()
                let playback = MatroskaPlayback()
                playback.attach(host.view)
                let context = await VideoPlaybackRequestContext.load(url: resource.url, pageURL: resource.sourcePageURL ?? page, webView: web)
                playback.open(resource.url, persistPosition: false, requestContext: context)
                var soulo = false
                for _ in 0..<playbackTicks {
                    try await Task.sleep(for: .milliseconds(250))
                    if (playback.player?.media?.statistics.displayedPictures ?? 0) > 0 { soulo = true; break }
                    if playback.error != nil { break }
                }
                row["souloFirstFrame"] = soulo; row["souloError"] = playback.error ?? playback.startupWarning ?? ""
                playback.stop(); session.stop()
                var safe = URLComponents(url: resource.url, resolvingAgainstBaseURL: false); safe?.query = nil; safe?.fragment = nil
                row["media"] = safe?.string ?? resource.url.host ?? ""
                row["delivery"] = resource.delivery.rawValue
            } else {
                row["status"] = isVideoCategory ? "no-direct-media-on-inspected-pages" : "directory-download-or-utility-entry"
            }
            rows.append(row)
            let json = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            print("SOULO_SITE_AUDIT_ROWS:" + String(decoding: json, as: UTF8.self))
            let note = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            note.name = "movie-audit-" + (site["id"] ?? "site"); note.lifetime = .keepAlways; add(note)
            model.releaseWebViewRuntime(); web.stopLoading(); web.removeFromSuperview()
        }
        XCTAssertEqual(rows.count, sites.count)
    }
}

extension WebMediaPlaybackBridgeTests {
    func testConfiguredVideoCanStartBeforeDOMVideoWithoutAcceptingArbitraryURLs() async throws {
        let source = "https://media.example/movie.m3u8?quality=hd"
        let encoded = Data(source.utf8).base64EncodedString()
        let web = try await page("<div id='v'></div><script>var player_aaaa={encrypt:2,url:'\(encoded)'};</script>")
        let resolved = await WebResourceInspectionService.currentVideoResource(webView: web, frame: nil, token: "__soulo_configured")
        let resource = try XCTUnwrap(resolved)
        XCTAssertEqual(resource.url.absoluteString, source)
        XCTAssertEqual(resource.delivery, .hls)
        let arbitraryToken = await WebResourceInspectionService.currentVideoResource(webView: web, frame: nil, token: "missing-video")
        XCTAssertNil(arbitraryToken)
        _ = try await web.evaluateJavaScript("player_aaaa={url:'https://account.example/login'};null")
        let notMedia = await WebResourceInspectionService.currentVideoResource(webView: web, frame: nil, token: "__soulo_configured")
        XCTAssertNil(notMedia)
    }
    func testEmptyMediaSourceNeverBecomesTheHTMLDocument() async throws {
        let web = try await page("<video id='v' src=''><source src=''></video><audio src=''><source src=''></audio>")
        let snapshot = try await WebResourceInspectionService.inspect(webView: web)
        XCTAssertTrue(snapshot.videos.isEmpty)
        XCTAssertTrue(snapshot.audio.isEmpty)
    }
}

extension WebMediaPlaybackBridgeTests {
    func testShadowRootVideoInspectionAndTakeoverKeepTheSelectedSource() async throws {
        let web = try await page("<div id='v'></div><video preload='none' src='https://ads.example/other.mp4'></video>")
        _ = try await web.evaluateJavaScript("document.getElementById('v').attachShadow({mode:'open'}).innerHTML=\"<video preload='none' data-soulo-media-id='shadow-main'><source src='https://media.example/main.m3u8'></video>\";null")
        let resource = await WebResourceInspectionService.currentVideoResource(webView: web, frame: nil, token: "shadow-main")
        XCTAssertEqual(resource?.url.absoluteString, "https://media.example/main.m3u8")
        let snapshot = try await WebResourceInspectionService.inspect(webView: web)
        XCTAssertTrue(snapshot.videos.contains { $0.url.absoluteString == "https://media.example/main.m3u8" })
    }
}


extension WebMediaPlaybackBridgeTests {
    func testFallbackRejectsRenderedPlayersAndOffscreenVideosBeforeControlsReportAvailability() async throws {
        let web = try await page("<video id='v' data-soulo-media-id='inline-main' preload='none' style='width:300px;height:160px' src='https://media.example/main.mp4'></video><script>var player_aaaa={url:'https://media.example/configured.m3u8'};</script>")
        let initial = await WebResourceInspectionService.inspectVideoFallback(webView: web, frame: nil)
        XCTAssertTrue(initial.hasInlineVideo)
        XCTAssertNil(initial.target, "A normal inline player must not also create a page-corner play button")
        _ = try await web.evaluateJavaScript("v.style.marginTop='2000px';null")
        let offscreen = await WebResourceInspectionService.inspectVideoFallback(webView: web, frame: nil)
        XCTAssertTrue(offscreen.hasInlineVideo)
        XCTAssertNil(offscreen.target, "Scrolling a player offscreen must not promote its URL into a floating entry")
        _ = try await web.evaluateJavaScript("v.style.display='none';null")
        let hidden = await WebResourceInspectionService.inspectVideoFallback(webView: web, frame: nil)
        XCTAssertFalse(hidden.hasInlineVideo)
        XCTAssertEqual(hidden.target?.token, "__soulo_configured", "A loading or hidden configured player retains its deliberate fallback")
    }

    func testHiddenVideoFallbackRetainsElementIdentityAndRejectsAmbiguousOrProtectedMedia() async throws {
        let web = try await page("<video id='v' style='display:none' data-soulo-media-id='hidden-main' preload='none' src='https://media.example/main.m3u8'></video>")
        let target = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: nil)
        XCTAssertEqual(target?.resource.url.absoluteString, "https://media.example/main.m3u8")
        XCTAssertEqual(target?.token, "hidden-main", "Handoff must preserve the actual element's position and state")
        _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend',\"<video data-soulo-media-id='other' src='https://ads.example/other.mp4'></video>\");null")
        let ambiguous = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: nil)
        XCTAssertNil(ambiguous)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-soulo-media-id=other]').remove();Object.defineProperty(document.getElementById('v'),'mediaKeys',{value:{}});null")
        let protected = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: nil)
        XCTAssertNil(protected)
    }
}


extension WebMediaPlaybackBridgeTests {
    func testBlobVideoCanResolveObservedManifestAfterResourceTimingWasCleared() async throws {
        let web = try await page("<video id='v' data-soulo-media-id='blob-main' preload='none' src='blob:https://www.example.com/current'></video>")
        _ = try await web.evaluateJavaScript("performance.clearResourceTimings();window.__souloObservedResourceURLs=['https://media.example/main.m3u8?auth_key=keep-signature'];window.__souloObservedMediaResponses=[];null")
        let selected = await WebResourceInspectionService.currentVideoResource(webView: web, frame: nil, token: "blob-main")
        XCTAssertEqual(selected?.url.absoluteString, "https://media.example/main.m3u8?auth_key=keep-signature")
        let visibleFallback = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: nil)
        XCTAssertNil(visibleFallback)
        _ = try await web.evaluateJavaScript("document.getElementById('v').style.display='none';null")
        let fallback = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: nil)
        XCTAssertEqual(fallback?.token, "blob-main")
        XCTAssertEqual(fallback?.resource.url, selected?.url)
    }
}
