import XCTest
import AVFoundation
import WebKit
import UIKit
import SwiftUI
@testable import Soulo

@MainActor
final class WebEpisodeTests: XCTestCase {
    func testLiveBilibiliBangumiPublishesItsWebEpisodesAndKeepsTheDockWithoutVideoTools() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_EPISODE_QA"]=="1","Live user-supplied page is opt-in")
        let defaults=UserDefaults.standard,keys=[VideoPlaybackPreferences.showsToolsKey,VideoPlaybackPreferences.showsEpisodeDockKey]
        let old=keys.map{defaults.object(forKey:$0)}
        defaults.set(false,forKey:keys[0]);defaults.set(true,forKey:keys[1])
        defer{for (key,value) in zip(keys,old){if let value{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
        let model=WebViewModel(),scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let previous=scene.keyWindow,window=UIWindow(windowScene:scene)
        window.rootViewController=UIHostingController(rootView:WebViewRepresentable(viewModel:model).frame(width:390,height:800))
        window.makeKeyAndVisible();defer{model.releaseWebViewRuntime();window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible()}
        model.loadURL(try XCTUnwrap(URL(string:"https://m.bilibili.com/bangumi/play/ep733317")))
        for _ in 0..<350 {
            if model.episodeList?.sources.flatMap(\.episodes).contains(where:{$0.url.path.contains("ep733317")}) == true {break}
            try await Task.sleep(for:.milliseconds(60))
        }
        let web=try XCTUnwrap(model.webView)
        let page=try await web.evaluateJavaScript("({url:location.href,title:document.title,hasNext:!!document.getElementById('__NEXT_DATA__'),dock:!!document.getElementById('soulo-episode-dock'),buttons:document.querySelectorAll('[data-soulo-video-rotate]').length})")
        var facts=[String:Any]();facts["page"]=page;facts["sources"]=model.episodeList?.sources.count ?? 0
        facts["episodes"]=model.episodeList?.sources.reduce(0){$0+$1.episodes.count} ?? 0
        let data=try JSONSerialization.data(withJSONObject:facts,options:[.prettyPrinted,.sortedKeys])
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name="bilibili-bangumi-live-episodes";attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertTrue(model.episodeList?.sources.flatMap(\.episodes).contains(where:{$0.url.path.contains("ep733317")}) == true)
        XCTAssertGreaterThan(model.episodeList?.sources.flatMap(\.episodes).count ?? 0,1)
        XCTAssertTrue(model.episodeList?.sources.flatMap(\.episodes).allSatisfy{["http","https"].contains($0.url.scheme ?? "")} == true)
        XCTAssertEqual((page as? [String:Any])?["dock"] as? Bool,true,"A visible video must not hide the only episode entry when video tools are disabled")
    }

    func testLiveSuppliedSPAExposesEpisodes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_EPISODE_QA"]=="1","Live user-supplied page is opt-in")
        let url=try XCTUnwrap(URL(string:"https://bpzhe5.com/player/av_40g7wcC77htD3WwsRS78SIhhvYGvU6kIkqJamfGTgP1r5yEr7wuOYVoeGIuYypiULHINMoVs6AlkhCs?from=%2F"))
        let model=WebViewModel()
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let previous=scene.keyWindow,window=UIWindow(windowScene:scene)
        window.rootViewController=UIHostingController(rootView:WebViewRepresentable(viewModel:model).frame(width:390,height:800))
        window.makeKeyAndVisible()
        defer{model.releaseWebViewRuntime();window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible()}
        model.loadURL(url)
        for _ in 0..<300 {
            if model.episodeList?.sources.isEmpty == false {break}
            try await Task.sleep(for:.milliseconds(60))
        }
        let web=try XCTUnwrap(model.webView)
        var facts=[String:Any]()
        facts["page"] = try? await web.evaluateJavaScript("({url:location.href,title:document.title,text:document.body.innerText.slice(0,18000),html:document.body.innerHTML.slice(0,160000),anchors:Array.from(document.querySelectorAll('a[href]'),e=>({text:e.textContent,href:e.href})).slice(0,500),buttons:Array.from(document.querySelectorAll('button,[role=button]'),e=>({text:e.textContent,html:e.outerHTML.slice(0,1600)})).slice(0,250)})")
        facts["pageState"] = try? await web.evaluateJavaScript(WebEpisodeSiteData.script)
        facts["detected"] = model.episodeList.map{["sources":$0.sources.count,"episodes":$0.sources.reduce(0){$0+$1.episodes.count}]} ?? [:]
        let data=try JSONSerialization.data(withJSONObject:facts,options:[.prettyPrinted,.sortedKeys])
        let report=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("bpzhe5-live-episodes.json")
        try data.write(to:report,options:.atomic)
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name="live-generic-SPA-episodes";attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertFalse(model.episodeList?.sources.isEmpty ?? true,"The supplied page's real episode controls must be recognized; inspect captured DOM before choosing the generic adapter")
    }

    func testLiveSPAEpisodeNavigationSurvivesOriginalFastStreamReplacement() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_EPISODE_QA"] == "1", "Live user-supplied page is opt-in")
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native extensions") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let crx = documents.appendingPathComponent("faststream-compatibility-qa.crx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: crx.path), "Original FastStream package fixture")
        let defaults = UserDefaults.standard, oldPrivacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito"); defer { defaults.set(oldPrivacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = BrowserExtensionService(extensionRoot: root)
        let record = try await service.installWebExtension(from: crx)
        defer { service.deleteWebExtension(record.id); try? FileManager.default.removeItem(at: root) }
        let runtime = NativeWebExtensionRuntime.shared
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let configuration = WKWebViewConfiguration(); runtime.apply(to: configuration)
        configuration.allowsInlineMediaPlayback = true; configuration.mediaTypesRequiringUserActionForPlayback = []
        let probe = ExtensionFrameMediaProbe()
        configuration.userContentController.add(probe, name: "qaExtensionFrame")
        configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 850), configuration: configuration)
        let model = WebViewModel(); model.webView = web
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model).frame(width: 390, height: 850))
        window.makeKeyAndVisible()
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: "qaExtensionFrame")
            model.releaseWebViewRuntime(); runtime.unregister(web); window.isHidden = true
            window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        var facts: [String: Any] = [:]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent("bp-faststream-episodes.json"), options: .atomic)
                let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = "bp-faststream-episodes"; a.lifetime = .keepAlways; add(a)
            }
        }
        func state() async -> Any? {
            try? await web.evaluateJavaScript("({url:location.href,text:document.body.innerText.slice(-6000),videos:Array.from(document.querySelectorAll('video'),v=>({src:v.currentSrc,attribute:v.getAttribute('src'),connected:v.isConnected,ready:v.readyState})),frames:Array.from(document.querySelectorAll('iframe'),f=>({src:f.getAttribute('src'),rect:f.getBoundingClientRect().toJSON()})),buttons:Array.from(document.querySelectorAll('.episode-grid button,[class*=episode] button'),b=>({title:b.title,class:b.className}))})")
        }
        model.loadURL(try XCTUnwrap(URL(string: "https://bpzhe5.com/player/av_40g7wcC77htD3WwsRS78SIhhvYGvU6kIkqJamfGTgP1r5yEr7wuOYVoeGIuYypiULHINMoVs6AlkhCs?from=%2F")))
        for _ in 0..<500 {
            if (model.episodeList?.sources.flatMap(\.episodes).count ?? 0) > 2,
               (try? await web.evaluateJavaScript("!!document.querySelector('video')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        facts["before"] = await state(); facts["catalog"] = model.episodeList?.sources.flatMap(\.episodes).map { ["title": $0.title, "action": $0.action != nil] }
        let firstList = try XCTUnwrap(model.episodeList)
        let second = try XCTUnwrap(firstList.sources.flatMap(\.episodes).dropFirst().first)
        try await WebEpisodeRuntime.activate(second, in: web)
        for _ in 0..<350 {
            if model.episodeList?.sources.flatMap(\.episodes).first(where: { $0.action?.isCurrent == true })?.title == second.title { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        facts["withoutExtension"] = await state()
        XCTAssertEqual(model.episodeList?.sources.flatMap(\.episodes).first(where: { $0.action?.isCurrent == true })?.title, second.title)
        _ = try? await web.evaluateJavaScript("document.querySelector('video')?.play().catch(()=>{});true")
        for _ in 0..<500 {
            if (try? await web.evaluateJavaScript("document.querySelector('video')?.readyState>=2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertTrue(runtime.performAction(id: record.id))
        for _ in 0..<500 {
            if probe.latest["readyState"] as? Int ?? 0 >= 2 { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        facts["replacement"] = await state(); facts["playerBefore"] = probe.latest
        XCTAssertNotNil(probe.frame, "The original extension must really replace this website's player")
        XCTAssertGreaterThanOrEqual(probe.latest["readyState"] as? Int ?? 0, 2, "The real replacement must be buffered before testing episode changes")
        let sourceBefore = probe.latest["source"] as? String
        let third = try XCTUnwrap(model.episodeList?.sources.flatMap(\.episodes).dropFirst(2).first)
        do { try await WebEpisodeRuntime.activate(third, in: web) }
        catch { facts["activationError"] = error.localizedDescription; throw error }
        for _ in 0..<500 {
            if model.episodeList?.sources.flatMap(\.episodes).first(where: { $0.action?.isCurrent == true })?.title == third.title,
               let source = probe.latest["source"] as? String, source != sourceBefore,
               probe.latest["readyState"] as? Int ?? 0 >= 2 { break }
            try await Task.sleep(for: .milliseconds(60))
        }
        facts["afterSelection"] = await state(); facts["playerAfter"] = probe.latest
        XCTAssertEqual(model.episodeList?.sources.flatMap(\.episodes).first(where: { $0.action?.isCurrent == true })?.title, third.title, "Selecting the next episode must reach the site's real SPA handler after replacement")
        XCTAssertNotEqual(probe.latest["source"] as? String, sourceBefore, "The actual replacement's source must change, not just the episode selection highlight")
        XCTAssertGreaterThanOrEqual(probe.latest["readyState"] as? Int ?? 0, 2)
        let image = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }); image.name = "bp-faststream-episode-selection"; image.lifetime = .keepAlways; add(image)
    }

    func testButtonOnlyCatalogBindsExplicitActionsAndRejectsStaleOrUnrelatedControls() async throws {
        let (web,capture)=try await page(#"""
        <h1>Fixture series</h1><video data-soulo-media-id="fixture" style="width:300px;height:180px"></video>
        <div class="episode-grid"><button type="button" title="EP1" class="selected" onclick="clicks.push(1)">1</button>
        <button type="button" title="EP2" onclick="clicks.push(2);history.replaceState(null,'','?episode=2');this.previousElementSibling.className='';this.className='selected'">2</button></div>
        <nav><div class="episodes"><button title="EP99">99</button><button title="EP100">100</button></div></nav>
        <div class="ad episodes"><button title="EP50">50</button><button title="EP51">51</button></div>
        <script>window.clicks=[];</script>
        """#,url:"https://generic.example/player/show")
        let list=try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
        let entries=list.sources.flatMap(\.episodes)
        XCTAssertEqual(entries.map(\.title),["EP1","EP2"])
        XCTAssertNotEqual(entries[0].id,entries[1].id)
        XCTAssertEqual(list.currentSource?.episodes.first?.action?.isCurrent,true)
        XCTAssertTrue(entries.allSatisfy{$0.action != nil && $0.directMediaResource == nil})
        let noClicks=try await web.evaluateJavaScript("JSON.stringify(clicks)") as? String
        XCTAssertEqual(noClicks,"[]","Scanning must not execute React handlers or advertisement controls")
        try await WebEpisodeRuntime.activate(entries[1],in:web)
        _ = try await web.evaluateCompatibleJavaScript("window.__souloEpisodes.refresh()",in:nil,contentWorld:WebEpisodeRuntime.world)
        let updated=try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(updated.actionScope,list.actionScope,"Episode-only SPA query changes remain in the same catalog")
        XCTAssertEqual(updated.sources[0].episodes.first(where:{$0.action?.isCurrent==true})?.title,"EP2")
        _ = try await web.evaluateJavaScript("document.querySelector('button[title=EP2]').remove();true")
        do { try await WebEpisodeRuntime.activate(entries[1],in:web);XCTFail("Removed controls must not be activated") } catch { }
        _ = try await web.evaluateJavaScript("history.replaceState(null,'','?movie=other');true")
        do { try await WebEpisodeRuntime.activate(entries[0],in:web);XCTFail("A different SPA catalog must invalidate old actions") } catch { }
        let clicks=try await web.evaluateJavaScript("JSON.stringify(clicks)") as? String
        XCTAssertEqual(clicks,"[2]")
        let model=WebViewModel();model.webView=web;defer{model.webView=nil}
        let downloads=WebEpisodeDownloadService()
        XCTAssertEqual(downloads.enqueue(entries,pageTitle:"Fixture",viewModel:model),0,"A button action is not a transferable download URL")
        XCTAssertTrue(downloads.jobs.isEmpty)
    }

    func testButtonEpisodeNativeResolverUsesTheNewRealVideoAndPausesItsWebSource() async throws {
        let file=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"playback-h264-aac",withExtension:"mp4",subdirectory:"ReadingFixtures"))
        let html=#"""
        <video data-soulo-media-id="fixture" src="/first.mp4" muted playsinline preload="auto" style="width:300px;height:180px"></video>
        <div class="episodes"><button type="button" title="EP1" class="selected">1</button>
        <button type="button" title="EP2" onclick="document.querySelector('video').src='/second.mp4';this.className='selected';this.previousElementSibling.className='';history.replaceState(null,'','?episode=2')">2</button></div>
        """#
        let server=try DownloadPlaybackHTTPFixture(files:["/index.html":Data(html.utf8),"/first.mp4":Data(contentsOf:file),"/second.mp4":Data(contentsOf:file)])
        let base=try await server.start();server.releaseDownloads();defer{server.stop()}
        let capture=Capture(),config=WKWebViewConfiguration()
        config.userContentController.add(capture,contentWorld:WebEpisodeRuntime.world,name:WebEpisodeRuntime.handler)
        config.userContentController.addUserScript(WKUserScript(source:WebEpisodeRuntime.script,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:WebEpisodeRuntime.world))
        let web=WKWebView(frame:CGRect(x:0,y:0,width:390,height:700),configuration:config)
        defer{web.stopLoading();config.userContentController.removeScriptMessageHandler(forName:WebEpisodeRuntime.handler,contentWorld:WebEpisodeRuntime.world)}
        web.load(URLRequest(url:base.appendingPathComponent("index.html")))
        for _ in 0..<100 { if !capture.bodies.isEmpty {break};try await Task.sleep(for:.milliseconds(30)) }
        let list=try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
        let media=try await WebEpisodeRuntime.resolveActionMedia(list.sources[0].episodes[1],in:web,timeout:5)
        XCTAssertEqual(media.url.path,"/second.mp4")
        let paused=try await web.evaluateJavaScript("document.querySelector('video').paused") as? Bool
        XCTAssertEqual(paused,true)
        let asset=AVURLAsset(url:media.url),playable=try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testPlaybackCatalogScopeAcceptsOnlyTheSameSPASeries() {
        let page=URL(string:"https://generic.example/player/show?episode=1")!,scope=UUID().uuidString
        func catalog(page:URL,scope:String)->WebEpisodeList {
            .init(pageURL:page,sources:[.init(title:"Series",episodes:[.init(title:"EP1",url:page,action:.init(token:UUID().uuidString,scope:scope,isCurrent:true))])])
        }
        let list=catalog(page:page,scope:scope)
        let resource=WebMediaResource(kind:.video,url:URL(string:"https://media.example/one.mp4")!,title:"EP1",posterURL:nil)
        let context=WebMediaPlaybackContext(resource:resource,pageURL:page,sourceWebView:nil,episodeList:list)
        XCTAssertTrue(context.accepts(catalog(page:URL(string:"https://generic.example/player/show?episode=2")!,scope:scope)))
        XCTAssertFalse(context.accepts(catalog(page:page,scope:UUID().uuidString)))
        XCTAssertFalse(context.accepts(catalog(page:URL(string:"https://other.example/player/show")!,scope:scope)))
    }

    func testWebVideoDownloadControlsDefaultToVisibleAndSurviveSettingsBackup() throws {
        let suite = "Soulo.VideoDownloadControls." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(VideoPlaybackPreferences.showsWebDownloadControls(in: defaults))
        defaults.set(false, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
        XCTAssertFalse(VideoPlaybackPreferences.showsWebDownloadControls(in: defaults))
        let snapshot = CloudSettingsSyncEngine.snapshot(defaults)
        let restored = try CloudSettingsSyncEngine.values(CloudSettingsSyncEngine.propertyList(snapshot))
        XCTAssertEqual(restored[VideoPlaybackPreferences.showsWebDownloadControlsKey] as? Bool, false)
        XCTAssertNotNil(try CloudSettingsSyncEngine.flattened(restored)["setting." + VideoPlaybackPreferences.showsWebDownloadControlsKey])
        defaults.set(true, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
        XCTAssertTrue(VideoPlaybackPreferences.showsWebDownloadControls(in: defaults))
    }

    func testVideoDownloadVisibilityUpdatesWithoutRemovingPlaybackOrEpisodeTools() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
        let originalTools = defaults.object(forKey: VideoPlaybackPreferences.showsToolsKey)
        defaults.set(true, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
        defaults.set(true, forKey: VideoPlaybackPreferences.showsToolsKey)
        defer {
            defaults.set(original, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
            defaults.set(originalTools, forKey: VideoPlaybackPreferences.showsToolsKey)
        }
        let (web, _) = try await page("<video style='display:block;width:300px;height:180px'></video>")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in: nil, contentWorld: WebVideoOrientationRuntime.world)
        for _ in 0..<100 {
            let ready = try await web.evaluateCompatibleJavaScript("!!document.querySelector('[data-video-download]')", in: nil, contentWorld: WebVideoOrientationRuntime.world)
            if ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateCompatibleJavaScript("""
            window.__videoBeforeToggle=document.querySelector('video');
            __videoBeforeToggle.playbackRate=1.5;
            window.__souloVideoOrientation.setEpisodesAvailable(true);
            document.querySelector('[data-video-toggle]').__souloVideoAction({isTrusted:true,preventDefault(){},stopImmediatePropagation(){}});null
            """, in: nil, contentWorld: WebVideoOrientationRuntime.world)
        for visible in [true, false, true] {
            let state = try await web.evaluateCompatibleJavaScript("""
                window.__souloVideoOrientation.setDownloadControlsVisible(\(visible));
                (()=>{
                  const button=document.querySelector('[data-video-download]'),group=button.parentElement;
                  const actions=Array.from(group.querySelectorAll('[data-video-action]'));
                  return {download:getComputedStyle(button).display!=='none',
                    episodes:getComputedStyle(group.querySelector('[data-video-episodes]')).display!=='none',
                    playback:getComputedStyle(actions[2]).display!=='none',speed:getComputedStyle(actions[1]).display!=='none',
                    sameVideo:document.querySelector('video')===window.__videoBeforeToggle,rate:document.querySelector('video').playbackRate,
                    visibleActions:actions.filter(a=>getComputedStyle(a).display!=='none').length};
                })()
                """, in: nil, contentWorld: WebVideoOrientationRuntime.world)
            let snapshot = try XCTUnwrap(state as? [String: Any])
            XCTAssertEqual(snapshot["download"] as? Bool, visible)
            XCTAssertEqual(snapshot["episodes"] as? Bool, true)
            XCTAssertEqual(snapshot["playback"] as? Bool, true)
            XCTAssertEqual(snapshot["speed"] as? Bool, true)
            XCTAssertEqual(snapshot["sameVideo"] as? Bool, true)
            XCTAssertEqual(snapshot["rate"] as? Double, 1.5)
            XCTAssertEqual(snapshot["visibleActions"] as? Int, visible ? 5 : 4)
        }
    }

    private final class Capture: NSObject, WKScriptMessageHandler {
        var bodies: [[String: Any]] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { bodies.append(body) }
        }
    }

    func testEpisodeContextSurvivesMiniPlayerAndDecoderHandoffsButNotAnotherVideo() throws {
        let mediaURL = try XCTUnwrap(URL(string: "https://example.com/episode-2.mp4"))
        let resource = WebMediaResource(kind: .video, url: mediaURL, title: "Episode 2", posterURL: nil)
        let episode = WebEpisode(title: "Episode 2", url: mediaURL)
        let list = WebEpisodeList(pageURL: mediaURL, sources: [.init(title: "Main", episodes: [episode])])
        let context = WebMediaPlaybackContext(resource: resource, pageURL: list.pageURL, sourceWebView: nil, episodeList: list)
        context.selectedEpisodeID = episode.id; context.selectedSourceID = list.sources[0].id
        context.updateEpisodeList(nil)
        context.updateEpisodeList(WebEpisodeList(pageURL: URL(string: "https://other.example/another-show")!, sources: []))
        XCTAssertEqual(context.episodeList, list, "Navigation away must not clear or replace the playing video's episodes")
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let source = DownloadPlaybackSource(asset: AVURLAsset(url: file), pageURL: nil, webView: nil, persistPosition: false)
        source.webMediaContext = context
        let session = MediaSession.shared
        defer { session.stop() }
        session.open(url: mediaURL, asset: source.asset, downloadSource: source, autoplay: false)
        let item = session.player.currentItem
        XCTAssertTrue(session.webMediaContext === context)
        XCTAssertEqual(session.webMediaContext?.selectedEpisodeID, episode.id)
        XCTAssertEqual(session.webMediaContext?.episodeList?.sources[0].episodes.count, 1)
        let transferred = try XCTUnwrap(session.playbackTransferSource())
        XCTAssertTrue(transferred.webMediaContext === context)
        XCTAssertTrue(session.player.currentItem === item, "Reading navigation metadata must not restart playback")
        session.stop(deactivateAudioSession: false)
        XCTAssertTrue(session.webMediaContext === context)
        session.adoptSoulo(MatroskaPlayback(), url: mediaURL, title: resource.title, source: transferred,
                           pageURL: list.pageURL, systemAvailable: true)
        XCTAssertTrue(session.webMediaContext === context)
        session.restoreSystemFromSoulo()
        XCTAssertTrue(session.webMediaContext === context)
        session.open(url: file, asset: AVURLAsset(url: file), autoplay: false)
        XCTAssertNil(session.webMediaContext, "An unrelated video must not inherit the previous website's episodes")
        session.open(url: mediaURL, asset: source.asset, downloadSource: source, autoplay: false)
        session.stop()
        XCTAssertNil(session.webMediaContext, "Stopping playback must release the in-memory episode context")
        let audio = WebMediaResource(kind: .audio, url: URL(string: "https://example.com/song.mp3")!, title: "Audio", posterURL: nil)
        source.webMediaContext = WebMediaPlaybackContext(resource: audio, pageURL: nil, sourceWebView: nil, episodeList: list)
        session.open(url: audio.url, asset: source.asset, downloadSource: source, autoplay: false)
        XCTAssertNil(session.webMediaContext, "Reopening audio must not enter the webpage video fullscreen flow")
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

    func testDisablingEpisodeDockStopsAutomaticScansButKeepsManualSelection() async throws {
        let (web, capture) = try await page("<ul class='episode-list'><li><a href='/player/68351-1-1.html'>EP1</a></li><li><a href='/player/68351-1-2.html'>EP2</a></li></ul>")
        _ = try await web.evaluateCompatibleJavaScript("window.__souloEpisodes.configure({dockEnabled:false,watchChanges:false});null", in: nil, contentWorld: WebEpisodeRuntime.world)
        try await Task.sleep(for: .milliseconds(100))
        let hidden = try await web.evaluateJavaScript("!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(hidden as? Bool, true)
        let count = capture.bodies.count
        _ = try await web.evaluateJavaScript("document.querySelector('ul').insertAdjacentHTML('beforeend',`<li><a href='/player/68351-1-3.html'>EP3</a></li>`);null")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(capture.bodies.count, count)
        _ = try await web.evaluateCompatibleJavaScript("window.__souloEpisodes.refresh();null", in: nil, contentWorld: WebEpisodeRuntime.world)
        try await Task.sleep(for: .milliseconds(100))
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.currentSource?.episodes.count, 3)
        _ = try await web.evaluateCompatibleJavaScript("window.__souloEpisodes.configure({dockEnabled:true,watchChanges:true});null", in: nil, contentWorld: WebEpisodeRuntime.world)
        let visible = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(visible as? Bool, true)
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

    func testResourceCatalogKeepsExternalPlayersStreamsAndSpecials() async throws {
        let (web, capture) = try await page("""
        <div class='dy-collect-video'><div class='dy-collect-video-name'><p>光速云</p></div>
        <ul class='dy-collect-list'>
        <li><input type='checkbox'><span class='c-name'>第01集</span><a href='https://cdn.example/play/first'>https://cdn.example/play/first</a><a class='report' href='https://report.example/play/report'>我要报错</a></li>
        <li><input type='checkbox'><span class='c-name'>虚天战纪上</span><a href='https://cdn.example/play/special'>https://cdn.example/play/special</a></li>
        <li><span class='c-name'>第02集</span><a href='https://cdn.example/play/second'>https://cdn.example/play/second</a></li>
        </ul><button class='copy'>复制链接</button></div>
        <div class='dy-collect-video'><div class='dy-collect-video-name'><p>光速M3U8</p></div>
        <ul class='dy-collect-list' style='display:none'>
        <li><span class='c-name'>第10集</span><a href='https://cdn.example/play/tenth/index.m3u8?token=abc'>URL</a></li>
        <li><span class='c-name'>第02集</span><a href='https://cdn.example/play/second/index.m3u8'>URL</a></li>
        <li><span class='c-name'>第02集</span><a href='https://cdn.example/play/second/index.m3u8#duplicate'>URL</a></li>
        <li><span class='c-name'>Unsafe</span><a href='javascript:alert(1)'>URL</a></li>
        <li><span class='c-name'>Unrelated</span><a href='https://ads.example/signup'>URL</a></li>
        <li><span class='c-name'>Credential</span><a href='https://user:password@cdn.example/play/hidden'>URL</a></li>
        </ul></div>
        <div class='recommendations'><ul class='dy-collect-list'><li><span class='c-name'>EP99</span><a href='https://cdn.example/play/ad'>URL</a></li></ul></div>
        <ul class='episode-list'><li><a href='https://other.example/play/foreign'>EP1</a></li></ul>
        """, url: "https://guangsuzy.com/index.php/vod/detail/id/172063.html")
        let pageURL = try XCTUnwrap(web.url)
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: pageURL))
        XCTAssertEqual(list.sources.map(\.title), ["光速云", "光速M3U8"])
        XCTAssertEqual(list.sources[0].episodes.map(\.title), ["第01集", "虚天战纪上", "第02集"])
        XCTAssertEqual(list.sources[1].episodes.map(\.title), ["第02集", "第10集"])
        XCTAssertEqual(list.sources[1].episodes.last?.url.query, "token=abc")
        XCTAssertTrue(list.sources.flatMap(\.episodes).allSatisfy { $0.resourcePageURL == pageURL })
        XCTAssertNil(list.sources[0].episodes[0].directMediaResource)
        XCTAssertEqual(list.sources[1].episodes[0].directMediaResource?.delivery, .hls)
        XCTAssertEqual(list.sources[1].episodes[0].directMediaResource?.sourcePageURL, pageURL)
        let dock = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dock as? Bool, true)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.dy-collect-video').forEach(node=>node.remove());null")
        for _ in 0..<100 where (capture.bodies.last?["sources"] as? [Any])?.isEmpty != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: pageURL))
    }

    func testWrappedResourceCatalogExtractsAllEpisodesAndSignedDirectStreams() async throws {
        // Zuidazy wraps visible "episode$stream" entries in an external player URL.
        let entries = (1...198).reversed().map { index in
            let stream = "https://media.example/episodes/\(index)/index.m3u8?token=a+b&expires=10"
            let escaped = stream.replacingOccurrences(of: "&", with: "&amp;")
            return "<li><a href='https://player.example/m3u8Player/?url=\(escaped)'>第\(index)集$\(escaped)</a></li>"
        }.joined()
        let (web, capture) = try await page("""
        <div class='vodplayinfo'>剧情简介</div>
        <div class='vodplayinfo'><div><h3>来源：zuidam3u8</h3><ul>\(entries)</ul></div>
        <div style='display:none'><h3>来源：备用</h3><ul>
        <li><a href='https://player.example/play/?url=https%3A%2F%2Fmedia.example%2Fspecial.mp4%3Fkey%3Done'>虚天战纪上$https://media.example/special.mp4?key=one</a></li>
        </ul></div></div>
        """, url: "https://www.zuidazy.co/voddetail/34868.html")
        let pageURL = try XCTUnwrap(web.url)
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: pageURL))
        XCTAssertEqual(list.sources.map(\.title), ["zuidam3u8", "备用"])
        XCTAssertEqual(list.sources.map { $0.episodes.count }, [198, 1])
        XCTAssertEqual(list.sources[0].episodes.map(\.title), (1...198).map { "第\($0)集" })
        let first = try XCTUnwrap(list.sources[0].episodes.first)
        XCTAssertEqual(first.url.absoluteString, "https://media.example/episodes/1/index.m3u8?token=a+b&expires=10")
        XCTAssertEqual(first.resourcePageURL, pageURL)
        XCTAssertEqual(first.directMediaResource?.delivery, .hls)
        XCTAssertEqual(first.directMediaResource?.sourcePageURL, pageURL)
        XCTAssertEqual(list.sources[1].episodes[0].title, "虚天战纪上")
        XCTAssertEqual(list.sources[1].episodes[0].directMediaResource?.delivery, .direct)
        let dock = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dock as? Bool, true)
    }

    func testWrappedResourceCatalogRejectsMismatchesUnsafeLinksAndRecommendations() async throws {
        let (web, capture) = try await page("""
        <div class='vodplayinfo'><h3>来源：测试</h3><ul>
        <li><a href='https://cdn.example/valid.m3u8'>第1集$https://cdn.example/valid.m3u8</a></li>
        <li><a href='https://cdn.example/valid.m3u8#duplicate'>第1集$https://cdn.example/valid.m3u8#duplicate</a></li>
        <li><a href='https://player.example/play/?url=https://ads.example/other.m3u8'>第2集$https://cdn.example/second.m3u8</a></li>
        <li><a href='javascript:alert(1)'>第3集$https://cdn.example/third.m3u8</a></li>
        <li><a href='https://player.example/play/?url=https://cdn.example/fourth.m3u8'>第4集$https://user:password@cdn.example/fourth.m3u8</a></li>
        <li><a href='https://user:password@player.example/play/?url=https://cdn.example/fifth.m3u8'>第5集$https://cdn.example/fifth.m3u8</a></li>
        <li><a href='https://player.example/play/?url=https://cdn.example/signup'>第6集$https://cdn.example/signup</a></li>
        <li><a href='https://player.example/play/?url=https://cdn.example/page.html?file=a.m3u8'>第7集$https://cdn.example/page.html?file=a.m3u8</a></li>
        <li><a href='https://player.example/play/?url=https://cdn.example/empty.m3u8'>$https://cdn.example/empty.m3u8</a></li>
        <li><a href='https://cdn.example/unlabelled.m3u8'>https://cdn.example/unlabelled.m3u8</a></li>
        <li><!--第99集$https://cdn.example/commented.m3u8--></li>
        </ul></div>
        <div class='recommendations'><div class='vodplayinfo'><ul><li><a href='https://cdn.example/recommended.m3u8'>第98集$https://cdn.example/recommended.m3u8</a></li></ul></div></div>
        <ul><li><a href='https://cdn.example/outside.m3u8'>第97集$https://cdn.example/outside.m3u8</a></li></ul>
        """, url: "https://www.zuidazy.co/voddetail/34868.html")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title), ["第1集"])
        XCTAssertEqual(list.sources[0].episodes[0].url.absoluteString, "https://cdn.example/valid.m3u8")
    }

    func testWrappedResourceCatalogAppearsAndDisappearsDynamically() async throws {
        let (web, capture) = try await page("<div class='vodplayinfo' id='catalog'></div>", url: "https://catalog.example/voddetail/1.html")
        _ = try await web.evaluateJavaScript("""
        document.getElementById('catalog').innerHTML = "<h3>来源：动态线路</h3><ul><li><a href='https://cdn.example/first.m3u8'>第01集$https://cdn.example/first.m3u8</a></li></ul>";null
        """)
        for _ in 0..<100 where capture.bodies.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.first?.title, "动态线路")
        XCTAssertEqual(list.sources.first?.episodes.first?.title, "第01集")
        _ = try await web.evaluateJavaScript("document.getElementById('catalog').replaceChildren();null")
        for _ in 0..<100 where capture.bodies.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
    }

    func testJinyingStyleCatalogKeepsCloudAndStreamLines() async throws {
        func rows(streams: Bool) -> String {
            (1...46).map { index in
                let target = "https://cdn.example/play/token\(index)" + (streams ? "/index.m3u8" : "")
                return "<li><input type='checkbox' value='\(target)'><a title='第\(index)集' href='\(target)'>第\(index)集$\(target)</a></li>"
            }.joined()
        }
        let (web, capture) = try await page("""
        <div class='vodplayinfo'><div id='play_1'><h3>播放类型：<span>金鹰云</span></h3><ul>\(rows(streams:false))</ul></div></div>
        <div class='vodplayinfo' hidden><div id='play_2'><h3>播放类型：<span>金鹰m3u8</span></h3><ul>\(rows(streams:true))</ul></div></div>
        """, url: "https://jinyingzy.com/index.php/vod/detail/id/93422.html?ac=detail")
        let url = try XCTUnwrap(web.url)
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL:url))
        XCTAssertEqual(list.sources.map(\.title),["金鹰云","金鹰m3u8"])
        XCTAssertEqual(list.sources.map { $0.episodes.count },[46,46])
        XCTAssertNil(list.sources[0].episodes[0].directMediaResource)
        XCTAssertEqual(list.sources[1].episodes[0].directMediaResource?.delivery,.hls)
        XCTAssertTrue(list.sources.flatMap(\.episodes).allSatisfy { $0.resourcePageURL == url })
    }

    func testGenericResourceCatalogsDoNotNeedKnownClassesOrHosts() async throws {
        let cases = [
            "<h3>Source: Cloud</h3><ul><li><a href='https://cdn.example/share/tokenTwo'>第2集$https://cdn.example/share/tokenTwo</a></li><li><a href='https://cdn.example/play.php?id=one'>第1集$https://cdn.example/play.php?id=one</a></li></ul>",
            "<table><caption>备用线路</caption><tbody><tr><td>第2集</td><td><a href='https://cdn.example/two.m3u8'>URL</a></td></tr><tr><td>第1集</td><td><a href='https://cdn.example/one.m3u8'>URL</a><a href='https://report.example/play/report'>我要报错</a></td></tr></tbody></table>",
            "<h3>播放列表</h3><div class='unfamiliar-grid'><div><span>第2集</span><a href='https://cdn.example/two.mp4'>https://cdn.example/two.mp4</a></div><div><span>第1集</span><a href='https://cdn.example/one.mp4'>https://cdn.example/one.mp4</a></div></div>",
            "<div><a href='https://cdn.example/two.m3u8'>第2集</a><a href='https://cdn.example/one.m3u8'>第1集</a></div>",
            "<ul><li>第2集$https://cdn.example/two.m3u8</li><li><input type='checkbox' value='https://cdn.example/one.m3u8'>第1集$https://cdn.example/one.m3u8</li></ul>"
        ]
        for html in cases {
            let (web,capture) = try await page(html,url:"https://unfamiliar.example/item/random-id")
            let url = try XCTUnwrap(web.url)
            let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:url),html)
            XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title),["第1集","第2集"],html)
            XCTAssertTrue(list.sources.flatMap(\.episodes).allSatisfy { $0.resourcePageURL == url })
        }
    }

    func testTextResourceListsKeepSourcesFragmentsAndSignedParameters() async throws {
        let (web,capture) = try await page("""
        <h3>播放地址</h3><textarea readonly>
        第2集$https://cdn.example/two.m3u8?token=a+b&amp;expires=10#video
        第1集$https://cdn.example/one.m3u8?token=c%2Bd&amp;expires=20
        $$$第1集$https://cdn.example/share/alternateOne#第2集$https://cdn.example/share/alternateTwo
        </textarea>
        """,url:"https://catalog.example/detail/1")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.map(\.title),["播放地址 1","播放地址 2"])
        XCTAssertEqual(list.sources.map { $0.episodes.count },[2,2])
        XCTAssertEqual(list.sources[0].episodes[0].url.absoluteString,"https://cdn.example/one.m3u8?token=c%2Bd&expires=20")
        XCTAssertEqual(list.sources[0].episodes[1].url.absoluteString,"https://cdn.example/two.m3u8?token=a+b&expires=10")
        XCTAssertNil(list.sources[1].episodes[0].directMediaResource)
    }

    func testUnfamiliarCopyRowsKeepNamedSpecialsAndPlainLineHeadings() async throws {
        let (web,capture) = try await page("""
        <div><p>备用云</p></div><ul>
        <li><span>第1集</span><a href='https://cdn.example/play/one'>https://cdn.example/play/one</a></li>
        <li><span>虚天战纪上</span><a href='https://cdn.example/play/special'>https://cdn.example/play/special</a></li>
        <li><span>第2集</span><a href='https://cdn.example/play/two'>https://cdn.example/play/two</a></li>
        </ul>
        """,url:"https://unfamiliar.example/detail/1")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.first?.title,"备用云")
        XCTAssertEqual(list.sources.first?.episodes.map(\.title),["第1集","虚天战纪上","第2集"])
    }

    func testGenericResourceDetectionRejectsAdsUnsafeCopiesAndQualityLists() async throws {
        let html = """
        <video></video><script>window.playlist=[{url:'/720/index.m3u8'},{url:'/1080/index.m3u8'}]</script>
        <nav><ul><li>第1集$https://cdn.example/nav1.m3u8</li><li>第2集$https://cdn.example/nav2.m3u8</li></ul></nav>
        <div class='recommendations'><ul><li><a href='https://cdn.example/ad1.m3u8'>第1集$https://cdn.example/ad1.m3u8</a></li><li><a href='https://cdn.example/ad2.m3u8'>第2集$https://cdn.example/ad2.m3u8</a></li></ul></div>
        <div class='ads'><textarea>第1集$https://cdn.example/one.m3u8#第2集$https://cdn.example/two.m3u8</textarea></div>
        <ul><li><a href='https://other.example/play/one'>EP1</a></li><li><a href='https://other.example/play/two'>EP2</a></li></ul>
        <ul><li><a href='javascript:alert(1)'>第1集$https://cdn.example/one.m3u8</a></li><li><a href='https://wrong.example/two.m3u8'>第2集$https://cdn.example/two.m3u8</a></li></ul>
        <div data-playlist><a href='javascript:alert(1)'>第1集$https://cdn.example/one.m3u8#第2集$https://cdn.example/two.m3u8</a></div>
        <ul><li>720P$https://cdn.example/720.m3u8</li><li>1080P$https://cdn.example/1080.m3u8</li></ul>
        <textarea>第1集$https://user:password@cdn.example/one.m3u8#第2集$javascript:alert(1)</textarea>
        """
        let (web,capture) = try await page(html,url:"https://catalog.example/detail/1")
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
    }

    func testGenericTextCatalogUpdatesWhenCopyFieldChanges() async throws {
        let (web,capture) = try await page("<h3>播放地址</h3><textarea id='copies' readonly></textarea>",url:"https://catalog.example/detail/1")
        _ = try await web.evaluateJavaScript("document.getElementById('copies').value='EP2$https://cdn.example/two.m3u8#EP1$https://cdn.example/one.m3u8';document.getElementById('copies').dispatchEvent(new Event('input',{bubbles:true}));null")
        for _ in 0..<100 where capture.bodies.count < 2 { try await Task.sleep(for:.milliseconds(20)) }
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.first?.episodes.map(\.title),["EP1","EP2"])
        _ = try await web.evaluateJavaScript("document.getElementById('copies').value='';document.getElementById('copies').dispatchEvent(new Event('input',{bubbles:true}));null")
        for _ in 0..<100 where capture.bodies.count < 3 { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last),pageURL:try XCTUnwrap(web.url)))
    }

    func testExternalCatalogEpisodesRequireMatchingProvenanceAndPlaybackURLs() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://catalog.example/detail/1"))
        let entries: [[String: Any]] = [
            ["title": "Valid", "url": "https://cdn.example/play/first", "resourcePageURL": pageURL.absoluteString],
            ["title": "Stream", "url": "https://media.example/show.m3u8?key=value", "resourcePageURL": pageURL.absoluteString],
            ["title": "Missing origin", "url": "https://cdn.example/play/second"],
            ["title": "Stale", "url": "https://cdn.example/play/stale", "resourcePageURL": "https://catalog.example/detail/2"],
            ["title": "Unrelated", "url": "https://ads.example/signup", "resourcePageURL": pageURL.absoluteString],
            ["title": "Unsafe", "url": "javascript:alert(1)", "resourcePageURL": pageURL.absoluteString],
            ["title": "Missing host", "url": "https:/play/invalid", "resourcePageURL": pageURL.absoluteString],
            ["title": "Credentials", "url": "https://user:password@cdn.example/play/private", "resourcePageURL": pageURL.absoluteString]
        ]
        let body: [String: Any] = ["pageURL": pageURL.absoluteString, "sources": [["title": "Catalog", "episodes": entries]]]
        let list = try XCTUnwrap(WebEpisodeList.parse(body, pageURL: pageURL))
        XCTAssertEqual(list.sources[0].episodes.map(\.title), ["Valid", "Stream"])
        XCTAssertNil(WebEpisode(title: "Not a stream", url: URL(string: "https://cdn.example/play/page.html?url=movie.m3u8")!).directMediaResource)
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

    func testRestoredDocumentRepublishesUnchangedEpisodes() async throws {
        let (web, capture) = try await page("<ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>")
        try await Task.sleep(for: .milliseconds(500))
        capture.bodies.removeAll()
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));null")
        for _ in 0..<100 where !capture.bodies.contains(where: { $0["sources"] != nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let body = try XCTUnwrap(capture.bodies.last { $0["sources"] != nil })
        let list = try XCTUnwrap(WebEpisodeList.parse(body, pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title), ["EP1", "EP2"])
    }

    func testNativeRefreshRepublishesAndReturnsTheCurrentSnapshot() async throws {
        let (web, capture) = try await page("<ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>")
        try await Task.sleep(for: .milliseconds(500))
        capture.bodies.removeAll()
        let value = try await web.evaluateCompatibleJavaScript("window.__souloEpisodes.refresh()", in: nil, contentWorld: WebEpisodeRuntime.world)
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(value as? [String: Any]), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title), ["EP1", "EP2"])
        for _ in 0..<100 where !capture.bodies.contains(where: { $0["sources"] != nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(capture.bodies.last { $0["sources"] != nil })
    }

    func testVideoEpisodeRequestRecoversMissingNativeState() async throws {
        let model = WebViewModel()
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(coordinator, contentWorld: WebEpisodeRuntime.world, name: WebEpisodeRuntime.handler)
        controller.add(coordinator, contentWorld: WebVideoOrientationRuntime.world, name: WebVideoOrientationRuntime.handler)
        controller.addUserScript(WKUserScript(source: WebEpisodeRuntime.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: WebEpisodeRuntime.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        model.webView = web
        defer {
            controller.removeScriptMessageHandler(forName: WebEpisodeRuntime.handler, contentWorld: WebEpisodeRuntime.world)
            controller.removeScriptMessageHandler(forName: WebVideoOrientationRuntime.handler, contentWorld: WebVideoOrientationRuntime.world)
            model.releaseWebViewRuntime()
        }
        web.loadHTMLString("<ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>",
            baseURL: URL(string: "https://example.com/series"))
        for _ in 0..<100 where model.episodeList == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNotNil(model.episodeList)
        try await Task.sleep(for: .milliseconds(500))
        model.beginPageNavigation()
        XCTAssertNil(model.episodeList)
        // Exercise the isolated video bridge after native state was cleared,
        // while the restored document still knows about its episode list.
        _ = try await web.evaluateCompatibleJavaScript("window.webkit.messageHandlers.souloVideoOrientation.postMessage({action:'episodes',token:'restored-player'});null",
            in: nil, contentWorld: WebVideoOrientationRuntime.world)
        for _ in 0..<100 where !model.showEpisodes { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(model.showEpisodes)
        XCTAssertEqual(model.episodeList?.sources.flatMap(\.episodes).map(\.title), ["EP1", "EP2"])
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

    func testOpaquePlaybackRoutesRecognizeNumericEpisodesAcrossSites() async throws {
        let tokens = (1...3).map { Data("show_42-episode_\($0)".utf8).base64EncodedString() }
        for (host, route) in [("first-media.example", "v_play"), ("second-video.example", "v-play")] {
            let links = tokens.enumerated().map { index, token in
                "<a href='/\(route)/\(token).html'>\(index + 1)</a>"
            }.joined()
            let (web, capture) = try await page("<iframe src='/embed/opaque'></iframe><div class='custom-items'>\(links)</div>",
                url: "https://\(host)/\(route)/\(tokens[1]).html")
            let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
            let items = list.sources.flatMap(\.episodes)
            XCTAssertEqual(items.map(\.title), ["1", "2", "3"])
            XCTAssertEqual(Set(items.map { $0.url.host }), [host])
            XCTAssertTrue(items.allSatisfy { $0.url.path.hasPrefix("/\(route)/") })
        }
    }

    func testOpaquePlaybackRoutesUseLeafCurrentMarkersWithoutAddingRecommendations() async throws {
        let (web, capture) = try await page("""
        <div><span aria-current='true'>1</span><a href='/v_play/c2.html'>2</a><a href='/v_play/c3.html'>3</a></div>
        <div class='recommendations'><a href='/v_play/c1.html'>1</a><a href='/v_play/r2.html'>2</a></div>
        <nav><a href='/v_play/c1.html'>1</a><a href='/v_play/c2.html'>2</a></nav>
        <ul><li><a href='/v-play/other1.html'>1</a></li><li><a href='/v-play/other2.html'>2</a></li></ul>
        """, url: "https://opaque-video.example/v_play/c1.html")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title), ["1", "2", "3"])
        XCTAssertEqual(list.sources.flatMap(\.episodes).map { $0.url.lastPathComponent }, ["c1.html", "c2.html", "c3.html"])
    }

    func testOpaquePlaybackRoutesRejectUnanchoredCrossOriginAndPaginationLists() async throws {
        let cases = [
            "<ul><li><a href='/v_play/r1.html'>1</a></li><li><a href='/v_play/r2.html'>2</a></li></ul>",
            "<ul><li><a href='/v_play/c1.html'>1</a></li><li><a href='/v_play/copy.html'>1</a></li></ul>",
            "<ul class='playlist'><li><a href='/v_play/c1.html'>1</a></li><li><a href='https://foreign-video.example/v_play/c2.html'>2</a></li></ul>",
            "<div><a aria-current='page' href='/v_play/c1.html?page=1'>1</a><a href='/v_play/c1.html?page=2'>2</a></div>",
            "<ul class='active'><li><a href='/v_play/r1.html'>1</a></li><li><a href='/v_play/r2.html'>2</a></li></ul>"
        ]
        for html in cases {
            let (web, capture) = try await page(html, url: "https://opaque-video.example/v_play/c1.html")
            XCTAssertNil(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)), html)
        }
    }

    func testOpaquePlaybackRoutesKeepNamedSpecialsOnlyBesideValidatedEpisodes() async throws {
        let (web, capture) = try await page("""
        <div>
          <a href='/v_play/c1.html'>1</a><a href='/v_play/c2.html'>2</a>
          <a href='/v_play/special-a.html'>Special A — Prelude</a><a href='/v_play/special-b.html'>幕后特别篇</a>
          <div><a href='/v_play/recommended.html'>Another series</a></div>
          <div class='recommendations'><a href='/v_play/related.html'>Related special</a></div>
          <a href='/v_play/c1.html?reply=1'>回复作者</a><a href='#reply'>Reply</a>
          <a href='/v_play/cancel.html#respond'>点击这里取消回复。</a>
          <a href='/v_play/poster.html'><img src='/poster.png'>Poster special</a>
          <a href='javascript:alert(1)'>Unsafe special</a><a href='https://another.example/v_play/special.html'>Foreign special</a>
        </div>
        """, url: "https://special-video.example/v_play/c1.html")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.flatMap(\.episodes).map(\.title), ["1", "2", "Special A — Prelude", "幕后特别篇"])
        XCTAssertEqual(list.sources.flatMap(\.episodes).map { $0.url.lastPathComponent }, ["c1.html", "c2.html", "special-a.html", "special-b.html"])
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

    func testEpisodeDockDoesNotInstallScrollBlockingRootTouchListeners() async throws {
        for hasEpisodes in [false, true] {
            let configuration = WKWebViewConfiguration(), capture = Capture()
            configuration.userContentController.add(capture, contentWorld: WebEpisodeRuntime.world, name: WebEpisodeRuntime.handler)
            configuration.userContentController.addUserScript(WKUserScript(source: """
            window.__rootTouchListeners=[];
            const original=EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener=function(type,handler,options){
              if((this===window||this===document||this===document.documentElement||this===document.body)
                  && ['touchstart','touchmove','wheel'].includes(type))
                __rootTouchListeners.push({type,passive:options?.passive===true});
              return original.call(this,type,handler,options);
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: WebEpisodeRuntime.world))
            configuration.userContentController.addUserScript(WKUserScript(source: WebEpisodeRuntime.script,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: WebEpisodeRuntime.world))
            let web = WKWebView(frame: .zero, configuration: configuration)
            let list = hasEpisodes ? "<ul class='episode-list'><li><a href='/watch/1'>EP1</a></li><li><a href='/watch/2'>EP2</a></li></ul>" : "<p>Ordinary search results</p>"
            web.loadHTMLString(list, baseURL: URL(string: "https://example.com/detail"))
            for _ in 0..<100 where capture.bodies.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(capture.bodies.isEmpty, "The production episode runtime must have started")
            let blockers = try await web.evaluateCompatibleJavaScript("__rootTouchListeners.filter(listener=>!listener.passive).map(listener=>listener.type)",
                in: nil, contentWorld: WebEpisodeRuntime.world) as? [String]
            XCTAssertEqual(blockers, [], "Touch scrolling must remain asynchronous, whether or not the dock is available")
            let dock = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')") as? Bool
            XCTAssertEqual(dock, hasEpisodes)
            configuration.userContentController.removeScriptMessageHandler(forName: WebEpisodeRuntime.handler, contentWorld: WebEpisodeRuntime.world)
        }
    }

    func testFallbackDockKeepsBarePlayersReachableAndRejectsSyntheticInput() async throws {
        let (web, capture) = try await page("<ul class='episode-list'><li><a href='/play/68351-1-1.html'>EP1</a></li><li><a href='/play/68351-1-2.html'>EP2</a></li></ul>")
        let dockVisible = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockVisible as? Bool,true)
        _ = try await web.evaluateJavaScript("document.getElementById('soulo-episode-dock').click();null")
        XCTAssertFalse(capture.bodies.contains { $0["action"] != nil })
        _ = try await web.evaluateJavaScript("const v=document.createElement('video');v.style.cssText='position:fixed;top:0;left:0;width:300px;height:180px';document.body.append(v);null")
        try await Task.sleep(for:.milliseconds(500))
        let dockWithBareVideo = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockWithBareVideo as? Bool,true,"A video alone is not an available Soulo episode menu")
        _ = try await web.evaluateJavaScript("const tools=document.createElement('div');tools.setAttribute('data-soulo-video-rotate','');tools.style.cssText='position:fixed;top:10px;left:10px;width:44px;height:44px';document.body.append(tools);null")
        _ = try await web.evaluateCompatibleJavaScript("window.__souloEpisodes.refresh()",in:nil,contentWorld:WebEpisodeRuntime.world)
        let dockHidden=try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockHidden as? Bool,false,"Visible native tools supply the alternate episode entry")
        _ = try await web.evaluateJavaScript("document.querySelector('[data-soulo-video-rotate]').remove();null")
        _ = try await web.evaluateJavaScript("document.querySelector('video').remove();null")
        try await Task.sleep(for:.milliseconds(500))
        let dockRestored = try await web.evaluateJavaScript("!!document.getElementById('soulo-episode-dock')")
        XCTAssertEqual(dockRestored as? Bool,true)
    }

    func testBarePlayerVisibilityNeverHidesTheOnlyEpisodeEntry() async throws {
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
        for (opacity, expected) in [("1", true), ("0", true)] {
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
        _ = try await web.evaluateCompatibleJavaScript(WebVideoOrientationRuntime.script(), in:nil, contentWorld:WebVideoOrientationRuntime.world)
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


extension WebEpisodeTests {
    func testQueryBasedPlayerKeepsCurrentSeriesAndExcludesRecommendedShows() async throws {
        let (web, capture) = try await page("""
        <ul class='episode-list'><li><a href='/video/?217629-1-0.html'>第1集</a></li><li><a href='/video/?217629-1-1.html'>第2集</a></li></ul>
        <ul class='playlist'><li><a href='/video/?217629-0-0.html'>HD</a></li></ul>
        <ul><li><a href='/detail/?4829.html'>第99集</a></li><li><a href='/video/?4829-1-0.html'>第100集</a></li></ul>
        """, url: "https://video.example/video/?217629-1-0.html")
        let list = try XCTUnwrap(WebEpisodeList.parse(try XCTUnwrap(capture.bodies.last), pageURL: try XCTUnwrap(web.url)))
        XCTAssertEqual(list.sources.count, 2)
        XCTAssertEqual(list.sources.flatMap(\.episodes).count, 3)
        XCTAssertTrue(list.sources.flatMap(\.episodes).allSatisfy { $0.url.query?.hasPrefix("217629-") == true })
    }
}
