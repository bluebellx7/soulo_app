import XCTest
import UIKit
import WebKit
import CryptoKit
import AVFoundation
import SwiftUI
@testable import Soulo

@MainActor final class ExtensionLifecycleTests: XCTestCase {
    func testTabsUpdateToOwnedApplicationKeepsNativeIdentityAndCanReturnToLiveSource() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native extensions") }
        let defaults = UserDefaults.standard, privacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito"); defer { defaults.set(privacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Standalone navigation","version":"1.0","permissions":["tabs"],"host_permissions":["http://127.0.0.1/*"],"action":{"default_popup":"peer.html"}}"#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        for file in ["peer.html", "downloader.html"] { try Data("<body id='ready'>Application</body>".utf8).write(to: package.appendingPathComponent(file)) }
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package); defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let fixture = try DownloadPlaybackHTTPFixture(files: ["/source": Data("<body id='ready' style='height:3000px'>Original page</body>".utf8)])
        let address = try await fixture.start(); fixture.releaseDownloads(); defer { fixture.stop() }
        let key = "extension-update-" + UUID().uuidString, manager = TabManager(storageKey: key)
        defer { defaults.removeObject(forKey: key); for tab in manager.tabs { tab.webViewModel.releaseWebViewRuntime() } }
        let sourceURL = address.appendingPathComponent("source"), source = manager.createTab(url: sourceURL)
        runtime.attach(tabManager: manager)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: source.webViewModel)); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func ready(_ web: @autoclosure () -> WKWebView?) async throws {
            for _ in 0..<200 {
                if let view = web(), (try? await view.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("No document"); throw URLError(.timedOut)
        }
        try await ready(source.webViewModel.webView)
        let original = try XCTUnwrap(source.webViewModel.webView)
        _ = try await original.evaluateJavaScript("window.unsavedForm='keep exact document';window.scrollTo(0,250);true")
        let peer = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: try XCTUnwrap(context.webViewConfiguration))
        window.rootViewController?.view.addSubview(peer)
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("peer.html"))); try await ready(peer)
        let targetURL = context.baseURL.appendingPathComponent("downloader.html")
        let response = try await peer.callAsyncJavaScript("const source=(await chrome.tabs.query({})).find(t=>t.url===sourceURL);const updated=await chrome.tabs.update(source.id,{url:targetURL});const actual=await chrome.tabs.get(source.id);return {before:source.id,after:updated.id,url:actual.url};", arguments: ["sourceURL": sourceURL.absoluteString, "targetURL": targetURL.absoluteString], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(response?["before"] as? Int, response?["after"] as? Int)
        XCTAssertEqual(response?["url"] as? String, targetURL.absoluteString)
        let target = try XCTUnwrap(manager.activeTab)
        XCTAssertNotEqual(target.id, source.id)
        XCTAssertTrue(source.webViewModel.webView === original)
        let sentinel = try await original.evaluateJavaScript("window.unsavedForm")
        XCTAssertEqual(sentinel as? String, "keep exact document")
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: target.webViewModel))
        try await ready(target.webViewModel.webView)
        XCTAssertEqual(target.webViewModel.currentURL, targetURL)
        XCTAssertTrue(target.webViewModel.canGoBack)
        let extensionView = target.webViewModel.webView
        target.webViewModel.goBack()
        XCTAssertEqual(manager.activeTab?.id, source.id)
        XCTAssertTrue(target.webViewModel.webView === extensionView, "Return must not destroy an extension save/merge")
        XCTAssertTrue(source.webViewModel.webView === original)
    }

    func testOriginalFastStreamSurvivesRealTabSwitchesWithoutFalseURLUpdates() async throws {
        try await checkOriginalFastStreamTabSwitches(forceManaged: false)
    }
    func testOriginalFastStreamManagedMediaSurvivesRealTabSwitches() async throws {
        try await checkOriginalFastStreamTabSwitches(forceManaged: true)
    }
    func testOriginalFastStreamRetainsOneBackgroundPlayerUnderMemoryPressure() async throws {
        try await checkOriginalFastStreamTabSwitches(forceManaged: false, memoryPressure: true)
    }
    private func checkOriginalFastStreamTabSwitches(forceManaged: Bool, memoryPressure: Bool = false) async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native extensions") }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = docs.appendingPathComponent("faststream-compatibility-qa.crx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: package.path), "Original FastStream CRX fixture")
        let defaults = UserDefaults.standard, previousPrivacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito"); defer { defaults.set(previousPrivacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        try Data("<body id='peer'>FastStream tab audit</body>".utf8).write(to: preview.resourceURL.appendingPathComponent("soulo-tabs-audit.html"))
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id); try? FileManager.default.removeItem(at: root) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let page = "<meta name='viewport' content='width=device-width'><body id='ready'><video src='/movie.mp4' controls muted autoplay playsinline style='width:360px;height:240px'></video>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/first": Data(page.utf8), "/second": Data(page.utf8), "/movie.mp4": Data(contentsOf: movie)])
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let key = UUID().uuidString, manager = TabManager(storageKey: key)
        defer { defaults.removeObject(forKey: key); for tab in manager.tabs { tab.webViewModel.releaseWebViewRuntime() } }
        let first = manager.createTab(url: base.appendingPathComponent("first")); runtime.attach(tabManager: manager)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        func show(_ model: WebViewModel) { window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model).frame(width: 390, height: 800)); window.makeKeyAndVisible() }
        show(first.webViewModel)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func ready(_ model: WebViewModel) async throws -> WKWebView {
            for _ in 0..<200 {
                if let web = model.webView, (try? await web.evaluateJavaScript("document.querySelector('video')?.readyState>=2")) as? Bool == true { return web }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw URLError(.timedOut)
        }
        let firstWeb = try await ready(first.webViewModel)
        _ = try await firstWeb.evaluateJavaScript("window.originalTabSentinel='retained';true")
        if forceManaged {
            firstWeb.configuration.userContentController.addUserScript(WKUserScript(source: "if(location.protocol==='webkit-extension:'&&location.pathname.endsWith('/player/index.html'))Object.defineProperty(globalThis,'MediaSource',{configurable:true,writable:true,value:undefined});", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let probe = ExtensionFrameMediaProbe()
        firstWeb.configuration.userContentController.add(probe, name: "qaExtensionFrame")
        firstWeb.configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        defer { firstWeb.configuration.userContentController.removeScriptMessageHandler(forName: "qaExtensionFrame") }
        let peer = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: try XCTUnwrap(context.webViewConfiguration))
        window.addSubview(peer); peer.isHidden = true; defer { peer.stopLoading(); peer.removeFromSuperview() }
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("soulo-tabs-audit.html")))
        for _ in 0..<100 { if (try? await peer.evaluateJavaScript("!!document.getElementById('peer')")) as? Bool == true { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(runtime.performAction(id: record.id))
        for _ in 0..<300 { if probe.latest["readyState"] as? Int ?? 0 >= 2 { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertGreaterThanOrEqual(probe.latest["readyState"] as? Int ?? 0, 2)
        let firstID = try await peer.callAsyncJavaScript("const tab=(await chrome.tabs.query({})).find(t=>t.url===address);globalThis.tabEvents=[];chrome.tabs.onUpdated.addListener((id,change)=>tabEvents.push({id,change}));chrome.tabs.onRemoved.addListener(id=>tabEvents.push({id,removed:true}));return tab.id;", arguments: ["address": base.appendingPathComponent("first").absoluteString], in: nil, contentWorld: .page) as? Int
        let second = manager.createTab(url: base.appendingPathComponent("second")); show(second.webViewModel)
        let secondWeb = try await ready(second.webViewModel)
        if forceManaged { secondWeb.configuration.userContentController.addUserScript(WKUserScript(source: "if(location.protocol==='webkit-extension:'&&location.pathname.endsWith('/player/index.html'))Object.defineProperty(globalThis,'MediaSource',{configurable:true,writable:true,value:undefined});", injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
        let secondProbe = ExtensionFrameMediaProbe()
        secondWeb.configuration.userContentController.add(secondProbe, name: "qaExtensionFrame")
        secondWeb.configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        defer { secondWeb.configuration.userContentController.removeScriptMessageHandler(forName: "qaExtensionFrame") }
        XCTAssertTrue(runtime.performAction(id: record.id))
        for _ in 0..<300 { if secondProbe.latest["readyState"] as? Int ?? 0 >= 2 { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertGreaterThanOrEqual(secondProbe.latest["readyState"] as? Int ?? 0, 2)
        for _ in 0..<3 {
            manager.switchToTab(id: first.id); show(first.webViewModel); try await Task.sleep(for: .milliseconds(300))
            manager.switchToTab(id: second.id); show(second.webViewModel); try await Task.sleep(for: .milliseconds(300))
        }
        if memoryPressure {
            manager.switchToTab(id: first.id); show(first.webViewModel)
            let plain = manager.createTab(); show(plain.webViewModel)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(first.webViewModel.mediaSession.hasLiveExtensionMedia)
            manager.releaseInactiveTabsForMemoryPressure()
            try await Task.sleep(for: .milliseconds(200))
            let retained = manager.tabs.first { $0.id == first.id }?.isAlive == true
            let checkpoint = XCTAttachment(string: String(describing: first.webViewModel.mediaSession.checkpoints))
            checkpoint.name = "extension-media-memory-pressure-checkpoints"; checkpoint.lifetime = .keepAlways; add(checkpoint)
            XCTAssertTrue(retained, "Memory pressure must preserve one recent replacement-player session instead of closing the extension")
            guard retained else { return }
            XCTAssertEqual(Set(manager.tabs.filter(\.isAlive).map(\.id)), [first.id, plain.id], "Keep one replacement player and the active page, releasing the second background replacement")
        }
        manager.switchToTab(id: first.id); show(first.webViewModel); try await Task.sleep(for: .milliseconds(400))
        let returnedFrame = try XCTUnwrap(probe.frame)
        let resume = try await firstWeb.callAsyncJavaScript("const client=globalThis.fastStream,v=client?.player?.getVideo?.();if(!v)return {error:'missing replacement'};v.muted=true;v.currentTime=.5;await client.play();const before=v.currentTime,until=performance.now()+3000;while(v.currentTime<=before&&performance.now()<until)await new Promise(r=>setTimeout(r,50));const after=v.currentTime;await client.pause();return {before,after,ready:v.readyState,error:v.error?.message??''};", arguments: [:], in: returnedFrame, contentWorld: .page) as? [String: Any]
        XCTAssertGreaterThan(resume?["after"] as? Double ?? 0, resume?["before"] as? Double ?? 0, "The retained player must still play after tab switches")
        XCTAssertEqual(resume?["error"] as? String, "")
        let events = try await peer.evaluateJavaScript("tabEvents") as? [[String: Any]] ?? []
        let state = try await firstWeb.evaluateJavaScript("({sentinel:window.originalTabSentinel,frames:document.querySelectorAll('iframe').length,url:location.href})") as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: ["forceManaged": forceManaged, "resume": resume ?? [:], "firstID": firstID ?? -1, "events": events, "state": state ?? [:], "player": probe.latest, "secondPlayer": secondProbe.latest], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: docs.appendingPathComponent("faststream-tab-switch.json"), options: .atomic)
        let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = "faststream-tab-switch"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(first.webViewModel.webView === firstWeb)
        XCTAssertEqual(state?["sentinel"] as? String, "retained")
        XCTAssertEqual(state?["frames"] as? Int, 1, "Switching tabs must not remove the original extension player")
        XCTAssertFalse(events.contains { $0["id"] as? Int == firstID && (($0["change"] as? [String: Any])?["url"] != nil || $0["removed"] as? Bool == true) }, "No URL/navigation/removal happened in the original tab")
        if memoryPressure {
            _ = try await firstWeb.evaluateJavaScript("document.querySelector('iframe').remove();true")
            for _ in 0..<50 {
                if !first.webViewModel.mediaSession.hasLiveExtensionMedia { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(first.webViewModel.mediaSession.hasLiveExtensionMedia, "Removing the player must release its media retention")
            manager.switchToTab(id: second.id)
            manager.releaseInactiveTabsForMemoryPressure()
            XCTAssertFalse(manager.tabs.first { $0.id == first.id }?.isAlive == true)
        }
    }

    private func downloadFolder(in controller: UIViewController) -> UIViewController? {
        if controller.viewIfLoaded?.accessibilityIdentifier == "extensions.downloads.folder" { return controller }
        if let presented = controller.presentedViewController, let folder = downloadFolder(in: presented) { return folder }
        return controller.children.lazy.compactMap { self.downloadFolder(in: $0) }.first
    }

    private func waitForDownloadFolder(in window: UIWindow) async throws -> UIViewController {
        for _ in 0..<150 {
            if let root = window.rootViewController, let folder = downloadFolder(in: root), !folder.isBeingPresented { return folder }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("The extension download-folder API did not present the native file browser")
        throw URLError(.timedOut)
    }

    func testPlatformSearchFromExtensionPagePreservesDownloadDocument() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let defaults = UserDefaults.standard, privacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        defer { defaults.set(privacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Extension navigation fixture","version":"1.0","action":{"default_popup":"downloader.html"}}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data("<title>Extension downloader</title><body id='extension-page'>Downloader</body>".utf8)
            .write(to: package.appendingPathComponent("downloader.html"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/search": Data("<title>Platform results</title><body id='platform-results'>Search results</body>".utf8),
            "/store": Data("<title>Extension store</title><body id='store-page'>Store reached</body>".utf8)
        ])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let storageKey = "extension-navigation-qa-" + UUID().uuidString
        let manager = TabManager(storageKey: storageKey)
        defer { defaults.removeObject(forKey: storageKey) }
        let page = context.baseURL.appendingPathComponent("downloader.html").appending(queryItems: [URLQueryItem(name: "requestId", value: "484")])
        let source = manager.createTab(url: page)
        let model = source.webViewModel
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model)); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        func waitForPage(_ marker: String, in model: WebViewModel) async throws {
            for _ in 0..<200 {
                if let web = model.webView, (try? await web.evaluateJavaScript("!!document.getElementById('\(marker)')")) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("Navigation did not reach \(marker): \(model.currentURL?.absoluteString ?? "nil"), \(model.errorMessage ?? "no error")")
            throw URLError(.timedOut)
        }
        try await waitForPage("extension-page", in: model)
        let extensionWeb = try XCTUnwrap(model.webView)
        _ = try await extensionWeb.evaluateJavaScript("window.downloadDocumentSentinel=484")
        let platform = SearchPlatform(id: UUID(), name: "Fixture", iconName: "globe", searchURLTemplate: address.appendingPathComponent("search").absoluteString + "?q=%@", homeURL: address.absoluteString, region: .international, isBuiltIn: false, isVisible: true, sortOrder: 0, usageCount: 0, isCustom: true)
        let previousCount = manager.tabCount
        let searchTab = try XCTUnwrap(manager.prepareTabForPlatformNavigation(keyword: "video example", platform: platform))
        XCTAssertNotEqual(searchTab.id, source.id)
        XCTAssertEqual(manager.tabCount, previousCount + 1)
        searchTab.webViewModel.loadSearchURL(keyword: "video example", platform: platform)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: searchTab.webViewModel))
        defer { searchTab.webViewModel.releaseWebViewRuntime() }
        try await waitForPage("platform-results", in: searchTab.webViewModel)
        XCTAssertNil(searchTab.webViewModel.errorMessage)
        XCTAssertTrue(server.receivedRequests.contains { $0.path == "/search" })
        XCTAssertTrue(model.webView === extensionWeb)
        XCTAssertEqual(model.currentURL, page)
        let sentinel = try await extensionWeb.evaluateJavaScript("window.downloadDocumentSentinel")
        XCTAssertEqual(sentinel as? Int, 484, "Platform navigation must preserve the extension's download/merge document")
        XCTAssertEqual(manager.prepareTabForPlatformNavigation(keyword: "next", platform: platform)?.id, searchTab.id,
                       "Further platform switches must reuse the ordinary search tab")
        manager.switchToTab(id: source.id)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        try await waitForPage("extension-page", in: model)
        let countBeforeStore = manager.tabCount
        let storeTab = try XCTUnwrap(manager.openURLFromBrowserControls(address.appendingPathComponent("store")))
        XCTAssertNotEqual(storeTab.id, source.id)
        XCTAssertEqual(manager.tabCount, countBeforeStore + 1)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: storeTab.webViewModel))
        defer { storeTab.webViewModel.releaseWebViewRuntime() }
        try await waitForPage("store-page", in: storeTab.webViewModel)
        XCTAssertNil(storeTab.webViewModel.errorMessage)
        XCTAssertTrue(server.receivedRequests.contains { $0.path == "/store" })
        XCTAssertEqual(manager.openURLFromBrowserControls(address.appendingPathComponent("search"))?.id, storeTab.id,
                       "Further browser links reuse the normal tab")
        let ordinaryWeb = try XCTUnwrap(storeTab.webViewModel.webView)
        _ = try await ordinaryWeb.evaluateJavaScript("window.originalStoreSentinel=484")
        let newStore = try XCTUnwrap(manager.openURLFromBrowserControls(address.appendingPathComponent("store"), inNewTab: true))
        XCTAssertNotEqual(newStore.id, storeTab.id)
        XCTAssertTrue(storeTab.webViewModel.webView === ordinaryWeb)
        let originalStoreSentinel = try await ordinaryWeb.evaluateJavaScript("window.originalStoreSentinel") as? Int
        XCTAssertEqual(originalStoreSentinel, 484)
        XCTAssertTrue(model.webView === extensionWeb)
        let preserved = try await extensionWeb.evaluateJavaScript("window.downloadDocumentSentinel")
        XCTAssertEqual(preserved as? Int, 484, "Opening the store must preserve the active extension download document")
    }

    func testGenericContentScriptStreamsExtensionBlobAndRunsNativeCommands() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let previousPrivacy = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(previousPrivacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Streaming fixture","version":"1.0","permissions":["downloads","tabs","storage"],"host_permissions":["http://127.0.0.1/*"],"commands":{"capture":{"description":"Capture fixture"}},"background":{"scripts":["background.js"],"persistent":false},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"]}]}"#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        try Data("chrome.commands.onCommand.addListener(command=>chrome.storage.local.set({command}));".utf8).write(to: package.appendingPathComponent("background.js"))
        try Data("<html><body id='ready'>Streaming fixture</body></html>".utf8).write(to: package.appendingPathComponent("page.html"))
        try Data(#"""
        chrome.runtime.onMessage.addListener((message,sender,reply)=>{
          if(message.kind!=='stream')return;
          (async()=>{try{
            const options={};if(message.abort){const controller=new AbortController();controller.abort();options.signal=controller.signal;}
            const response=await fetch(message.url,options),bytes=await response.arrayBuffer();
            const digest=await crypto.subtle.digest('SHA-256',bytes);
            reply({bytes:bytes.byteLength,sha256:Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,'0')).join(''),type:response.headers.get('Content-Type')});
          }catch(error){reply({error:error.name,message:error.message});}})();return true;
        });
        """#.utf8).write(to: package.appendingPathComponent("content.js"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let config = WKWebViewConfiguration(); runtime.apply(to: config)
        let browser = WKWebView(frame: CGRect(x:0,y:0,width:390,height:600), configuration: config)
        let peer = WKWebView(frame: browser.frame, configuration: try XCTUnwrap(context.webViewConfiguration))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(browser)
        window.rootViewController?.view.addSubview(peer); window.makeKeyAndVisible(); runtime.register(browser)
        defer { browser.stopLoading(); peer.stopLoading(); runtime.unregister(browser); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let server = try DownloadPlaybackHTTPFixture(files: ["/index.html":Data("<body id='ready'>Content script fixture</body>".utf8)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        browser.load(URLRequest(url: address.appendingPathComponent("index.html")))
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        for _ in 0..<150 {
            if (try? await browser.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true,
               (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let initialDownloads = Set(DownloadManagerService.shared.downloads.map(\.id))
        let count = 32 * 1024 * 1024 + 17
        let facts = try await peer.callAsyncJavaScript("""
        const tabs=await chrome.tabs.query({}),tab=tabs.find(value=>value.url?.startsWith(address));
        const url=URL.createObjectURL(new Blob([new Uint8Array(count).fill(91)],{type:'application/x-soulo-fixture'}));
        try{
          const stream=await chrome.tabs.sendMessage(tab.id,{kind:'stream',url});
          const aborted=await chrome.tabs.sendMessage(tab.id,{kind:'stream',url,abort:true});
          const foreign=await new Promise(resolve=>chrome.runtime.sendNativeMessage('com.dkluge.Soulo.WebExtensionCompatibility',{souloCompatibility:1,api:'blobs',operation:'open',url:'blob:webkit-extension://other-extension/secret'},()=>resolve(!!chrome.runtime.lastError)));
          return {stream,aborted,foreign};
        }finally{URL.revokeObjectURL(url);}
        """, arguments: ["address":address.absoluteString,"count":count], in: nil, contentWorld: .page) as? [String: Any]
        let streamed = facts?["stream"] as? [String: Any]
        XCTAssertEqual(streamed?["bytes"] as? Int, count, String(describing: facts))
        let expected = SHA256.hash(data: Data(repeating: 91, count: count)).map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(streamed?["sha256"] as? String, expected)
        XCTAssertEqual(streamed?["type"] as? String, "application/x-soulo-fixture")
        XCTAssertEqual((facts?["aborted"] as? [String: Any])?["error"] as? String, "AbortError")
        XCTAssertEqual(facts?["foreign"] as? Bool, true)
        XCTAssertEqual(Set(DownloadManagerService.shared.downloads.map(\.id)), initialDownloads, "Staging input must not create user download history")
        XCTAssertTrue(service.webExtensionCommands(for: record.id).contains { $0.id == "capture" && $0.title == "Capture fixture" })
        XCTAssertTrue(service.performWebExtensionCommand("capture", id: record.id))
        var command: String?
        for _ in 0..<100 {
            command = try await peer.callAsyncJavaScript("return (await chrome.storage.local.get('command')).command??null;", arguments: [:], in: nil, contentWorld: .page) as? String
            if command != nil { break }; try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(command, "capture")
        UserDefaults.standard.set(true, forKey: "is_incognito")
        XCTAssertTrue(service.webExtensionCommands(for: record.id).isEmpty)
        XCTAssertFalse(service.performWebExtensionCommand("capture", id: record.id))
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: facts ?? [:], options: [.prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "generic-content-blob-and-commands"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testCatCatchCacheCaptureAndOnlineMergeProducePlayableFiles() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = documents.appendingPathComponent("catcatch-compatibility-qa.crx")
        guard FileManager.default.fileExists(atPath: package.path) else { throw XCTSkip("Opt-in real Cat Catch package") }
        let previousPrivacy = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(previousPrivacy, forKey: "is_incognito") }
        var facts: [String: Any] = [:]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent("extension-advanced-audit.json"))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "extension-advanced-audit"; attachment.lifetime = .keepAlways; add(attachment)
                print("ADVANCED EXTENSION AUDIT",String(decoding:data,as:UTF8.self))
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        defer { service.discardWebExtensionPreview(preview) }
        try Data("<html><body id='ready'>Advanced extension fixture</body></html>".utf8).write(to: preview.resourceURL.appendingPathComponent("advanced-audit.html"))
        try Data("window.__qaScopeSeen=typeof MediaSource;throw new Error('Expected scope fixture exception');".utf8)
            .write(to: preview.resourceURL.appendingPathComponent("scope-audit.js"))
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let config = WKWebViewConfiguration(); runtime.apply(to: config)
        config.userContentController.addUserScript(WKUserScript(source: "window.__qaErrors=[];addEventListener('error',e=>__qaErrors.push(String(e.error||e.message)));addEventListener('unhandledrejection',e=>__qaErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let browser = WKWebView(frame: CGRect(x: 0,y: 0,width: 390,height: 600), configuration: config)
        let probe = ExtensionMediaDownloadProbe(directory: root.appendingPathComponent("files")); browser.navigationDelegate = probe
        let onlineConfig = WKWebViewConfiguration(); runtime.apply(to: onlineConfig)
        let onlineBrowser = WKWebView(frame: browser.frame, configuration: onlineConfig)
        onlineBrowser.navigationDelegate = probe
        onlineBrowser.configuration.userContentController.addUserScript(WKUserScript(source: "window.__qaErrors=[];addEventListener('error',e=>__qaErrors.push(String(e.error||e.message)));addEventListener('unhandledrejection',e=>__qaErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let peer = WKWebView(frame: browser.frame, configuration: try XCTUnwrap(context.webViewConfiguration))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(browser)
        peer.isHidden = true; window.rootViewController?.view.addSubview(peer); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(onlineBrowser)
        runtime.register(browser); runtime.register(onlineBrowser); runtime.activate(browser)
        defer { browser.stopLoading(); onlineBrowser.stopLoading(); peer.stopLoading(); runtime.unregister(browser); runtime.unregister(onlineBrowser); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let fragmentURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cache-muxed", withExtension: "mp4", subdirectory: "ReadingFixtures/ExtensionMedia"))
        let videoURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "video", withExtension: "mp4", subdirectory: "ReadingFixtures/ExtensionMedia"))
        let audioURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "audio", withExtension: "m4a", subdirectory: "ReadingFixtures/ExtensionMedia"))
        let fragment = try Data(contentsOf: fragmentURL)
        let html = #"""
        <meta name='viewport' content='width=device-width'><title>Source cache fixture</title>
        <video id='movie' controls muted playsinline style='width:100%'></video>
        <script>
        window.__qaRoots=[];Element.prototype.attachShadow=new Proxy(Element.prototype.attachShadow,{apply(target,self,args){const root=Reflect.apply(target,self,args);__qaRoots.push(root);return root;}});
        window.runSource=async(split=false)=>{
          const video=document.getElementById('movie');video.disableRemotePlayback=true;
          const source=new (globalThis.MediaSource||globalThis.ManagedMediaSource)();window.__source=source;video.src=URL.createObjectURL(source);
          await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('Media source did not open')),8000);source.addEventListener('sourceopen',()=>{clearTimeout(timer);resolve();},{once:true});});
          const files=split?[['/video.mp4','video/mp4;codecs="avc1.64000a"'],['/audio.m4a','audio/mp4;codecs="mp4a.40.2"']]:[['/muxed.mp4','video/mp4;codecs="avc1.64000a,mp4a.40.2"']];let bytes=0;
          for(const [url,type] of files){
            const buffer=source.addSourceBuffer(type),data=await (await fetch(url)).arrayBuffer();bytes+=data.byteLength;
            await new Promise((resolve,reject)=>{buffer.addEventListener('updateend',resolve,{once:true});buffer.addEventListener('error',reject,{once:true});buffer.appendBuffer(data);});
          }
          source.endOfStream();return {bytes,duration:video.duration};
        };
        </script><div id='ready'></div>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/index.html":Data(html.utf8),"/muxed.mp4":fragment,"/video.mp4":try Data(contentsOf:videoURL),"/audio.m4a":try Data(contentsOf:audioURL)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        browser.load(URLRequest(url: address.appendingPathComponent("index.html")))
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("advanced-audit.html")))
        for _ in 0..<150 {
            if (try? await browser.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true,
               (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        facts["capabilities"] = try await browser.evaluateJavaScript("({mediaSource:typeof MediaSource,managedMediaSource:typeof ManagedMediaSource,userAgent:navigator.userAgent,wasm:typeof WebAssembly})")
        let tabId = try await peer.callAsyncJavaScript("const tabs=await chrome.tabs.query({});return tabs.find(tab=>tab.url?.startsWith(address))?.id;", arguments: ["address":address.absoluteString], in: nil, contentWorld: .page)
        facts["tabId"] = tabId
        facts["commands"] = service.webExtensionCommands(for: record.id).map { ["id":$0.id,"title":$0.title] }
        let failedScript = try await peer.callAsyncJavaScript("return await chrome.scripting.executeScript({target:{tabId},files:['scope-audit.js'],world:'MAIN'});", arguments:["tabId":tabId], in:nil, contentWorld:.page) as? [[String: Any]]
        XCTAssertEqual(failedScript?.count, 1, "Internal scope files must not change the extension's result count")
        let afterFailure = try await browser.evaluateJavaScript("({mediaSource:typeof MediaSource,scoped:!!window.__souloMediaSourceScope,seen:window.__qaScopeSeen})") as? [String: Any]
        facts["scopeAfterThrownScript"] = afterFailure
        XCTAssertEqual(afterFailure?["mediaSource"] as? String, (facts["capabilities"] as? [String: Any])?["mediaSource"] as? String)
        XCTAssertEqual(afterFailure?["scoped"] as? Bool, false)
        XCTAssertEqual(afterFailure?["seen"] as? String, "function")
        let failedCallback = try await peer.callAsyncJavaScript("return await new Promise(resolve=>chrome.scripting.executeScript({target:{tabId:Number.MAX_SAFE_INTEGER},files:['scope-audit.js'],world:'MAIN'},value=>resolve({error:chrome.runtime.lastError?.message??'',value:value??null})));", arguments:[:], in:nil, contentWorld:.page) as? [String: Any]
        XCTAssertFalse((failedCallback?["error"] as? String ?? "").isEmpty, "Preserve the native callback lastError scope")
        facts["injection"] = try await peer.callAsyncJavaScript("return await chrome.scripting.executeScript({target:{tabId},files:['catch-script/i18n.js','catch-script/catch.js'],world:'MAIN',injectImmediately:true});", arguments: ["tabId":tabId], in: nil, contentWorld: .page)
        facts["afterInjection"] = try await browser.evaluateJavaScript("({mediaSource:typeof MediaSource,managedMediaSource:typeof ManagedMediaSource,scoped:!!window.__souloMediaSourceScope})")
        XCTAssertEqual((facts["afterInjection"] as? [String: Any])?["mediaSource"] as? String, (facts["capabilities"] as? [String: Any])?["mediaSource"] as? String)
        facts["source"] = try await browser.callAsyncJavaScript("try{return await window.runSource();}catch(error){return {error:String(error),stack:error.stack};}", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual((facts["source"] as? [String: Any])?["bytes"] as? Int, fragment.count, String(describing: facts["source"]))
        facts["capture"] = try await browser.evaluateJavaScript("({roots:__qaRoots.length,text:__qaRoots.map(root=>root.getElementById('CatCatchCatch')?.textContent).filter(Boolean),errors:__qaErrors})")
        _ = try await browser.evaluateJavaScript("__qaRoots.find(root=>root.getElementById('CatCatchCatch')).getElementById('CatCatchCatch').querySelector('#download').click();true")
        for _ in 0..<200 where probe.files.isEmpty && probe.errors.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        facts["cacheDownloadErrors"] = probe.errors
        let cached = try XCTUnwrap(probe.files.first, "The publisher's cache-capture download must create a real file")
        func inspect(_ file: URL) async throws -> [String: Any] {
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration).seconds
            let playable = try await asset.load(.isPlayable)
            let video = try await asset.loadTracks(withMediaType: .video).count, audio = try await asset.loadTracks(withMediaType: .audio).count
            XCTAssertTrue(playable); XCTAssertGreaterThan(duration, 7); XCTAssertLessThan(duration, 9)
            XCTAssertEqual(video, 1); XCTAssertEqual(audio, 1)
            return ["bytes":try Data(contentsOf: file).count,"duration":duration,"videoTracks":video,"audioTracks":audio,"playable":playable]
        }
        facts["cacheFile"] = try await inspect(cached)
        onlineBrowser.load(URLRequest(url: URL(string:"https://ffmpeg.bmmmd.com/")!))
        for _ in 0..<400 {
            if (try? await onlineBrowser.evaluateJavaScript("typeof ffmpeg==='object'&&!!document.getElementById('log')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["mergeMessage"] = try await peer.callAsyncJavaScript("""
        const make=(data,type)=>URL.createObjectURL(new Blob([Uint8Array.from(atob(data),c=>c.charCodeAt(0))],{type}));
        window.__qaMediaURLs=[make(video,'video/mp4'),make(audio,'audio/mp4')];
        return await chrome.runtime.sendMessage({Message:'catCatchFFmpeg',action:'merge',title:'qa-merged.mp4',output:'qa-merged.mp4',taskId:'soulo-qa-merge',quantity:2,tabId,autoClose:false,
          files:[{data:__qaMediaURLs[0],name:'video.mp4',type:'video'},{data:__qaMediaURLs[1],name:'audio.m4a',type:'audio'}]});
        """, arguments: ["tabId":tabId,"video":try Data(contentsOf: videoURL).base64EncodedString(),"audio":try Data(contentsOf: audioURL).base64EncodedString()], in: nil, contentWorld: .page)
        for _ in 0..<1200 {
            if probe.files.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["online"] = try? await onlineBrowser.evaluateJavaScript("({url:location.href,loaded:!!ffmpeg.loaded,loadError:ffmpegLoadError,running:ffmpegIsRunning,log:document.getElementById('log')?.innerText?.slice(-6000),errors:__qaErrors})")
        facts["onlineDownloadErrors"] = probe.errors
        let merged = try XCTUnwrap(probe.files.dropFirst().first, "The publisher's online merger must download its output")
        facts["onlineFile"] = try await inspect(merged)
        _ = try? await peer.evaluateJavaScript("__qaMediaURLs.forEach(URL.revokeObjectURL);true")
        _ = try await browser.evaluateJavaScript("__qaRoots.find(root=>root.getElementById('CatCatchCatch')).getElementById('CatCatchCatch').querySelector('#clean').click();true")
        facts["splitCapture"] = try await browser.callAsyncJavaScript("return await window.runSource(true);", arguments:[:], in:nil, contentWorld:.page)
        _ = try await browser.evaluateJavaScript("addEventListener('message',event=>{if(event.data?.action==='catCatchFFmpeg')window.__qaCacheMessage=event.data;},{capture:true});const panel=__qaRoots.find(root=>root.getElementById('CatCatchCatch')).getElementById('CatCatchCatch');panel.querySelector('#ffmpeg').click();panel.querySelector('#download').click();true")
        for _ in 0..<400 where probe.files.count < 3 { try await Task.sleep(for:.milliseconds(100)) }
        facts["cacheMergedOnline"] = try? await onlineBrowser.evaluateJavaScript("({running:ffmpegIsRunning,log:document.getElementById('log')?.innerText?.slice(-6000),errors:__qaErrors})")
        facts["cacheMergedInputs"] = try? await onlineBrowser.callAsyncJavaScript("return await Promise.all(getAllFiles().map(async file=>({name:file.name,type:file.type,size:file.size,header:Array.from(new Uint8Array((await file.arrayBuffer()).slice(0,24)))})));",arguments:[:],in:nil,contentWorld:.page)
        facts["cachePageInputs"] = try? await browser.callAsyncJavaScript("return await Promise.all((window.__qaCacheMessage?.files||[]).map(async file=>{const blob=await (await fetch(file.data)).blob();return {url:file.data,type:blob.type,size:blob.size,header:Array.from(new Uint8Array((await blob.arrayBuffer()).slice(0,24)))};}));",arguments:[:],in:nil,contentWorld:.page)
        facts["cacheMergedFile"] = try await inspect(try XCTUnwrap(probe.files.dropFirst(2).first, "The actual cache-capture FFmpeg checkbox must export a merged file"))
    }

    func testGenericBlobAndDataDownloadsKeepBytesAndNativeErrorCallbacks() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let previousPrivacy = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(previousPrivacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Binary download fixture","version":"1.0","permissions":["downloads"]}"#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        try Data("<html><body id='ready'>Download fixture</body></html>".utf8).write(to: package.appendingPathComponent("page.html"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: try XCTUnwrap(context.webViewConfiguration))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(view); window.makeKeyAndVisible()
        defer { view.stopLoading(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let initial = Set(DownloadManagerService.shared.downloads.map(\.id))
        defer {
            for item in DownloadManagerService.shared.downloads where !initial.contains(item.id) {
                DownloadManagerService.shared.delete(item); try? FileManager.default.removeItem(at: item.localURL)
            }
        }
        func load() async throws {
            view.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            for _ in 0..<100 {
                if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("The extension document did not load")
        }
        var facts: [[String: Any]] = []
        var createdIDs: [Int] = []
        for (kind,count) in [("blob",32*1024*1024+17),("data",1024*1024+7),("data-native",5),("empty",0)] {
            try await load()
            let name = "qa-\(UUID().uuidString).bin"
            let result = try await view.callAsyncJavaScript("""
            const bytes=new Uint8Array(count).fill(90);let url;
            if(kind==='data-native')url='data:application/octet-stream;base64,WlpaWlo=';
            else if(kind==='data')url=await new Promise(resolve=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.readAsDataURL(new Blob([bytes]));});
            else url=URL.createObjectURL(new Blob([bytes],{type:'application/octet-stream'}));
            if(kind==='data-native')return await new Promise((resolve,reject)=>chrome.runtime.sendNativeMessage('com.dkluge.Soulo.WebExtensionCompatibility',
              {souloCompatibility:1,api:'downloads',operation:'download',options:{url,filename:name}},reply=>chrome.runtime.lastError?reject(Error(chrome.runtime.lastError.message)):resolve(reply)));
            const id=await chrome.downloads.download({url,filename:name});
            if(url.startsWith('blob:'))URL.revokeObjectURL(url);
            return {id};
            """, arguments: ["kind":kind,"count":count,"name":name], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertNotNil(result?["id"])
            createdIDs.append(try XCTUnwrap(result?["id"] as? Int))
            view.loadHTMLString("<html><body>Source closed</body></html>", baseURL: nil)
            var item: BrowserDownloadItem?
            for _ in 0..<200 {
                item = DownloadManagerService.shared.downloads.first { $0.fileName == name }
                if item?.status == .finished || item?.status == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let downloaded = try XCTUnwrap(item)
            XCTAssertEqual(downloaded.status, .finished, downloaded.errorMessage)
            let data = try Data(contentsOf: downloaded.localURL)
            XCTAssertEqual(data.count, count)
            XCTAssertEqual(SHA256.hash(data: data), SHA256.hash(data: Data(repeating: 90, count: count)))
            facts.append(["kind":kind,"bytes":data.count,"status":downloaded.status.rawValue])
        }
        try await load()
        let folderResult = try await view.evaluateJavaScript("window.folderSentinel=484;typeof chrome.downloads.showDefaultFolder()")
        XCTAssertEqual(folderResult as? String, "undefined", "Chrome's folder API is synchronous/void")
        let folder = try await waitForDownloadFolder(in: window)
        _ = try await view.evaluateJavaScript("chrome.downloads.showDefaultFolder();true")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(downloadFolder(in: try XCTUnwrap(window.rootViewController)) === folder, "Repeated calls reuse the file browser")
        await withCheckedContinuation { continuation in folder.dismiss(animated: false) { continuation.resume() } }
        let showResult = try await view.callAsyncJavaScript("return typeof chrome.downloads.show(id);", arguments: ["id": try XCTUnwrap(createdIDs.first)], in: nil, contentWorld: .page)
        XCTAssertEqual(showResult as? String, "undefined")
        let savedFileFolder = try await waitForDownloadFolder(in: window)
        try await Task.sleep(for: .milliseconds(200))
        let folderShot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        folderShot.name = "extension-native-download-folder"; folderShot.lifetime = .keepAlways; add(folderShot)
        await withCheckedContinuation { continuation in savedFileFolder.dismiss(animated: false) { continuation.resume() } }
        let sentinel = try await view.evaluateJavaScript("window.folderSentinel")
        XCTAssertEqual(sentinel as? Int, 484, "Opening files must preserve the extension document")
        for size in [16, 32] {
            let icon = try await view.callAsyncJavaScript("return await chrome.downloads.getFileIcon(id,{size});",
                arguments: ["id": try XCTUnwrap(createdIDs.first), "size": size], in: nil, contentWorld: .page) as? String
            let encoded = try XCTUnwrap(icon?.split(separator: ",", maxSplits: 1).last)
            let data = try XCTUnwrap(Data(base64Encoded: String(encoded)))
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.size, CGSize(width: size, height: size))
        }

        let foreignPackage = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreignPackage, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Foreign folder fixture","version":"1.0","permissions":["downloads"]}"#.utf8).write(to: foreignPackage.appendingPathComponent("manifest.json"))
        try Data("<body id='foreign-ready'>Foreign fixture</body>".utf8).write(to: foreignPackage.appendingPathComponent("page.html"))
        let foreign = try await service.installWebExtension(from: foreignPackage)
        defer { service.deleteWebExtension(foreign.id) }
        let foreignContext = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == foreign.id.uuidString })
        let foreignWeb = WKWebView(frame: view.bounds, configuration: try XCTUnwrap(foreignContext.webViewConfiguration))
        window.rootViewController?.view.addSubview(foreignWeb); foreignWeb.isHidden = true
        defer { foreignWeb.stopLoading(); foreignWeb.removeFromSuperview() }
        foreignWeb.load(URLRequest(url: foreignContext.baseURL.appendingPathComponent("page.html")))
        for _ in 0..<100 {
            if (try? await foreignWeb.evaluateJavaScript("!!document.getElementById('foreign-ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let foreignResult = try await foreignWeb.callAsyncJavaScript("""
        return await new Promise(resolve=>chrome.runtime.sendNativeMessage('com.dkluge.Soulo.WebExtensionCompatibility',
          {souloCompatibility:1,api:'downloads',operation:'show',id},()=>resolve({error:chrome.runtime.lastError?.message??''})));
        """, arguments: ["id": try XCTUnwrap(createdIDs.first)], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertFalse((foreignResult?["error"] as? String ?? "").isEmpty)
        XCTAssertNil(downloadFolder(in: try XCTUnwrap(window.rootViewController)), "One extension cannot reveal another extension's downloads")
        let failure = try await view.callAsyncJavaScript("""
        return await new Promise(resolve=>chrome.downloads.download({url:'unsupported://test'},id=>resolve({id:id??null,error:chrome.runtime.lastError?.message??''})));
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertFalse((failure?["error"] as? String ?? "").isEmpty)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "generic-binary-downloads"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDynamicUserScriptsHaveIsolatedWorldsAtomicUpdatesAndRevocableAccess() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let defaults=UserDefaults.standard,privacy=defaults.object(forKey:"is_incognito")
        defaults.set(false,forKey:"is_incognito");defer { defaults.set(privacy,forKey:"is_incognito") }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),package=root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        try Data(#"{"manifest_version":3,"name":"Dynamic isolated scripts fixture","version":"1.0","permissions":["userScripts","webNavigation"],"host_permissions":["http://127.0.0.1/*"],"action":{"default_popup":"peer.html"}}"#.utf8).write(to:package.appendingPathComponent("manifest.json"))
        try Data("<body id='ready'>User scripts API</body>".utf8).write(to:package.appendingPathComponent("peer.html"))
        try Data("window.extensionOnly=88;const facts={pageSecret:typeof window.pageSecret,chrome:typeof chrome,dynamic:new Function('return 42')(),top:window===top};const mark=()=>document.documentElement.dataset.isolatedFixture=JSON.stringify(facts);if(document.documentElement)mark();else addEventListener('DOMContentLoaded',mark,{once:true});".utf8).write(to:package.appendingPathComponent("isolated.js"))
        let service=BrowserExtensionService(extensionRoot:root.appendingPathComponent("store"))
        let record=try await service.installWebExtension(from:package);defer {service.deleteWebExtension(record.id)}
        let grantedAccess=try XCTUnwrap(record.access)
        let runtime=NativeWebExtensionRuntime.shared
        let context=try XCTUnwrap(runtime.controller.extensionContexts.first {$0.uniqueIdentifier==record.id.uuidString})
        let configuration=WKWebViewConfiguration();runtime.apply(to:configuration)
        let web=WKWebView(frame:CGRect(x:0,y:0,width:390,height:600),configuration:configuration)
        let peer=WKWebView(frame:web.frame,configuration:try XCTUnwrap(context.webViewConfiguration))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap {$0 as? UIWindowScene}.first)
        let previous=scene.keyWindow,window=UIWindow(windowScene:scene)
        window.rootViewController=UIViewController();window.rootViewController?.view.addSubview(web);window.rootViewController?.view.addSubview(peer);peer.isHidden=true;window.makeKeyAndVisible();runtime.register(web)
        defer {runtime.unregister(web);web.stopLoading();peer.stopLoading();window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible()}
        peer.load(URLRequest(url:context.baseURL.appendingPathComponent("peer.html")))
        for _ in 0..<150 {if (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true {break};try await Task.sleep(for:.milliseconds(30))}
        let api=try await peer.callAsyncJavaScript("""
        const api=chrome.userScripts;
        await api.configureWorld({csp:"script-src 'unsafe-eval'; trusted-types 'none';"});
        await api.register([{id:'isolated',js:[{file:'isolated.js'}],matches:['http://127.0.0.1/page*'],excludeMatches:['http://127.0.0.1/page-excluded'],allFrames:true,runAt:'document_start'},
          {id:'restricted',worldId:'restricted',js:[{code:"try{new Function('return 1')();document.documentElement.dataset.evalBlocked='false';}catch(e){document.documentElement.dataset.evalBlocked=e.name;}addEventListener('load',()=>{try{new window.frames[0].Function('return 1')();document.documentElement.dataset.childEvalBlocked='false';}catch(e){document.documentElement.dataset.childEvalBlocked=e.name;}},{once:true});"}],matches:['http://127.0.0.1/page*'],runAt:'document_end'}]);
        const before=await api.getScripts();let rejected=false;
        try{await api.update([{id:'isolated',js:[{code:'window.replaced=true;'}]},{id:'restricted',js:[{code:'function {'}]}]);}catch(e){rejected=true;}
        let duplicate=false;try{await api.register([{id:'isolated',js:[{code:'1'}],matches:['http://127.0.0.1/*']}]);}catch(e){duplicate=true;}
        const after=await api.getScripts();return {registered:after.length,atomic:JSON.stringify(before)===JSON.stringify(after),rejected,duplicate};
        """,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(api?["registered"] as? Int,2);XCTAssertEqual(api?["atomic"] as? Bool,true);XCTAssertEqual(api?["rejected"] as? Bool,true);XCTAssertEqual(api?["duplicate"] as? Bool,true)
        let page="<body id='ready'><script>window.pageSecret=99;</script><iframe src='/page-child'></iframe><iframe src='/page-child'></iframe></body>"
        let server=try DownloadPlaybackHTTPFixture(files:["/page":Data(page.utf8),"/page-child":Data("<body id='ready'>Child</body>".utf8),"/page-excluded":Data("<body id='ready'>Excluded</body>".utf8),"/other":Data("<body id='ready'>Other</body>".utf8)])
        let base=try await server.start();server.releaseDownloads();defer {server.stop()}
        func load(_ path:String) async throws {
            web.load(URLRequest(url:base.appendingPathComponent(path)))
            for _ in 0..<200 {if web.url?.path=="/"+path,!web.isLoading,(try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true {return};try await Task.sleep(for:.milliseconds(30))}
            throw URLError(.timedOut)
        }
        try await load("page")
        let facts=try await web.evaluateJavaScript("({top:JSON.parse(document.documentElement.dataset.isolatedFixture||'null'),child:JSON.parse(document.querySelector('iframe').contentDocument.documentElement.dataset.isolatedFixture||'null'),pageSeesExtension:typeof window.extensionOnly,evalBlocked:document.documentElement.dataset.evalBlocked,childEvalBlocked:document.documentElement.dataset.childEvalBlocked})") as? [String:Any]
        let top=facts?["top"] as? [String:Any],child=facts?["child"] as? [String:Any]
        XCTAssertEqual(top?["pageSecret"] as? String,"undefined");XCTAssertEqual(top?["chrome"] as? String,"undefined");XCTAssertEqual(top?["dynamic"] as? Int,42);XCTAssertEqual(top?["top"] as? Bool,true)
        XCTAssertEqual(child?["top"] as? Bool,false);XCTAssertEqual(child?["dynamic"] as? Int,42)
        XCTAssertEqual(facts?["pageSeesExtension"] as? String,"undefined");XCTAssertEqual(facts?["evalBlocked"] as? String,"EvalError");XCTAssertEqual(facts?["childEvalBlocked"] as? String,"EvalError")
        let connectionOnlyPeer = WKWebView(frame: peer.frame, configuration: try XCTUnwrap(context.webViewConfiguration))
        window.rootViewController?.view.addSubview(connectionOnlyPeer); connectionOnlyPeer.isHidden = true
        defer { connectionOnlyPeer.stopLoading(); connectionOnlyPeer.removeFromSuperview() }
        connectionOnlyPeer.load(URLRequest(url: context.baseURL.appendingPathComponent("peer.html")))
        for _ in 0..<100 { if (try? await connectionOnlyPeer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }; try await Task.sleep(for: .milliseconds(20)) }
        _ = try await connectionOnlyPeer.evaluateJavaScript("chrome.runtime.onUserScriptConnect.addListener(()=>{});true")
        let execution = try await peer.callAsyncJavaScript("""
        const tab=(await chrome.tabs.query({})).find(tab=>tab.url===pageURL);
        if(!tab)throw Error('Actual source tab not found');
        globalThis.userScriptReceiver=(message,sender)=>new Promise(resolve=>setTimeout(()=>resolve({echo:message.value,frame:sender.frameId,document:sender.documentId,world:sender.userScriptWorldId,origin:sender.origin,tab:sender.tab.id}),40));
        chrome.runtime.onUserScriptMessage.addListener(globalThis.userScriptReceiver);
        chrome.runtime.onUserScriptConnect.addListener(port=>port.onMessage.addListener(value=>port.postMessage({echo:value,world:port.sender.userScriptWorldId})));
        const first=await chrome.userScripts.execute({target:{tabId:tab.id},js:[{code:'var souloSharedExecution=37;souloSharedExecution'}]});
        const shared=await chrome.userScripts.execute({target:{tabId:tab.id},js:[{code:'Promise.resolve(souloSharedExecution+5)'}]});
        const frames=await chrome.userScripts.execute({target:{tabId:tab.id,allFrames:true},worldId:'restricted',js:[{code:'({top:window===top,chrome:typeof chrome,evalBlocked:(()=>{try{new Function("return 1")();return false;}catch(e){return e.name;}})()})'}]});
        await chrome.userScripts.configureWorld({worldId:'messages',messaging:true});
        const message=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'messages',js:[{code:'chrome.runtime.sendMessage({value:42})'}]});
        const port=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'messages',js:[{code:'new Promise((resolve,reject)=>{const p=chrome.runtime.connect({name:"echo"});p.onMessage.addListener(value=>{p.disconnect();resolve(value);});p.onDisconnect.addListener(()=>{if(chrome.runtime.lastError)reject(Error(chrome.runtime.lastError.message));});p.postMessage(43);})'}]});
        const failure=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'restricted',js:[{code:'throw Error("original-user-error")'}]});
        const nativeFrames=await chrome.webNavigation.getAllFrames({tabId:tab.id});
        const child=frames.find(frame=>frame.frameId!==0);
        const selectedChild=await chrome.userScripts.execute({target:{tabId:tab.id,frameIds:[child.frameId]},worldId:'messages',js:[{code:'chrome.runtime.sendMessage({value:44})'}]});
        const selectedDocument=await chrome.userScripts.execute({target:{tabId:tab.id,documentIds:[child.documentId]},js:[{code:'window!==top'}]});
        const lexical=await chrome.userScripts.execute({target:{tabId:tab.id},js:[{code:'let sharedLexicalForExecute=39;Promise.resolve(sharedLexicalForExecute+3)'}]});
        const lexicalAgain=await chrome.userScripts.execute({target:{tabId:tab.id},js:[{code:'sharedLexicalForExecute+4'}]});
        await chrome.userScripts.configureWorld({worldId:'network-denied',csp:"default-src 'none'; script-src 'self' https:; connect-src 'none'; object-src 'none'"});
        const deniedFetch=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'network-denied',js:[{code:'fetch("/forbidden-network-probe").then(()=>"allowed",e=>e.name)'}]});
        await chrome.userScripts.configureWorld({worldId:'network-allowed',csp:"script-src 'self'; connect-src http://127.0.0.1:*"});
        const allowedFetch=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'network-allowed',js:[{code:'fetch("/other").then(r=>r.status)'}]});
        const main=await chrome.userScripts.execute({target:{tabId:tab.id},world:'MAIN',js:[{code:'window.fromMainExecute=42;Promise.resolve(window.pageSecret+1)'}]});
        const heldPort=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'messages',js:[{code:'new Promise(resolve=>{globalThis.portWasRevoked=false;const p=chrome.runtime.connect({name:"held"});globalThis.heldUserPort=p;p.onMessage.addListener(resolve);p.onDisconnect.addListener(()=>{globalThis.portWasRevoked=true;});p.postMessage(45);})'}]});
        chrome.runtime.onUserScriptMessage.removeListener(globalThis.userScriptReceiver);
        const noReceiver=await chrome.userScripts.execute({target:{tabId:tab.id},worldId:'messages',js:[{code:'chrome.runtime.sendMessage({value:46}).then(()=>false,e=>e.message.includes("Receiving end"))'}]});
        chrome.runtime.onUserScriptMessage.addListener(globalThis.userScriptReceiver);
        return {tab:tab.id,first,shared,frames,message,port,failure,nativeFrames,selectedChild,selectedDocument,lexical,lexicalAgain,deniedFetch,allowedFetch,main,heldPort,noReceiver};
        """, arguments: ["pageURL": base.appendingPathComponent("page").absoluteString], in: nil, contentWorld: .page) as? [String: Any]
        let executionAttachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: execution ?? [:], options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        executionAttachment.name = "generic-userscript-execution-and-messaging"; executionAttachment.lifetime = .keepAlways; add(executionAttachment)
        func injected(_ key: String) -> [[String: Any]] { execution?[key] as? [[String: Any]] ?? [] }
        XCTAssertEqual(injected("first").first?["result"] as? Int, 37)
        XCTAssertEqual(injected("shared").first?["result"] as? Int, 42)
        XCTAssertEqual(injected("frames").count, 3)
        XCTAssertEqual(injected("frames").first?["frameId"] as? Int, 0)
        XCTAssertEqual(Set(injected("frames").compactMap { $0["documentId"] as? String }).count, 3)
        for frame in injected("frames") {
            let result = frame["result"] as? [String: Any]
            XCTAssertEqual(result?["chrome"] as? String, "undefined")
            XCTAssertEqual(result?["evalBlocked"] as? String, "EvalError")
        }
        let echoed = injected("message").first?["result"] as? [String: Any]
        XCTAssertEqual(echoed?["echo"] as? Int, 42)
        XCTAssertEqual(echoed?["world"] as? String, "messages")
        var expectedOrigin = URLComponents(url: base, resolvingAgainstBaseURL: false)!; expectedOrigin.path = ""
        XCTAssertEqual(echoed?["origin"] as? String, expectedOrigin.string)
        XCTAssertEqual(echoed?["tab"] as? Int, execution?["tab"] as? Int)
        XCTAssertEqual(echoed?["frame"] as? Int, 0)
        XCTAssertEqual((injected("port").first?["result"] as? [String: Any])?["echo"] as? Int, 43)
        XCTAssertTrue((injected("failure").first?["error"] as? String ?? "").contains("original-user-error"))
        XCTAssertEqual(Set(injected("frames").compactMap { $0["frameId"] as? Int }), Set(injected("nativeFrames").compactMap { $0["frameId"] as? Int }), "Frame IDs must match the owning extension's real WebKit API")
        let childReply = injected("selectedChild").first?["result"] as? [String: Any]
        XCTAssertEqual(childReply?["frame"] as? Int, injected("selectedChild").first?["frameId"] as? Int)
        XCTAssertEqual(childReply?["echo"] as? Int, 44)
        XCTAssertEqual(injected("selectedDocument").count, 1)
        XCTAssertEqual(injected("selectedDocument").first?["result"] as? Bool, true)
        XCTAssertEqual(injected("lexical").first?["result"] as? Int, 42)
        XCTAssertEqual(injected("lexicalAgain").first?["result"] as? Int, 43)
        XCTAssertEqual(injected("deniedFetch").first?["result"] as? String, "TypeError")
        XCTAssertFalse(server.receivedRequests.contains { $0.path == "/forbidden-network-probe" })
        XCTAssertEqual(injected("allowedFetch").first?["result"] as? Int, 200)
        XCTAssertEqual(injected("main").first?["result"] as? Int, 100)
        XCTAssertEqual((injected("heldPort").first?["result"] as? [String: Any])?["echo"] as? Int, 45)
        XCTAssertEqual(injected("noReceiver").first?["result"] as? Bool, true)
        var connectionRevoked = grantedAccess; connectionRevoked.deniedSites["http://127.0.0.1/*"] = .distantFuture
        runtime.applyAccess(connectionRevoked, id: record.id)
        let messageWorld = WKContentWorld.world(name: "Soulo.UserScripts.\(record.id.uuidString).8:messages:script-src 'self' 'wasm-unsafe-eval'")
        var wasRevoked = false
        for _ in 0..<100 {
            if (try? await web.evaluateCompatibleJavaScript("globalThis.portWasRevoked===true", in: nil, contentWorld: messageWorld)) as? Bool == true { wasRevoked = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(wasRevoked, "Revoking host access must disconnect the live user-script port before navigation")
        runtime.applyAccess(grantedAccess, id: record.id)
        try await load("page-excluded")
        let excludedInjected = try await web.evaluateJavaScript("!!document.documentElement.dataset.isolatedFixture") as? Bool
        XCTAssertEqual(excludedInjected,false)
        var denied=grantedAccess;denied.deniedSites["http://127.0.0.1/*"] = .distantFuture
        runtime.applyAccess(denied,id:record.id)
        try await load("page")
        let deniedInjected = try await web.evaluateJavaScript("!!document.documentElement.dataset.isolatedFixture") as? Bool
        XCTAssertEqual(deniedInjected,false)
        runtime.applyAccess(grantedAccess,id:record.id)
        _ = try await peer.callAsyncJavaScript("await chrome.userScripts.unregister();return true;",arguments:[:],in:nil,contentWorld:.page)
        try await load("page")
        let unregisteredInjected = try await web.evaluateJavaScript("!!document.documentElement.dataset.isolatedFixture") as? Bool
        XCTAssertEqual(unregisteredInjected,false)
        let a=XCTAttachment(data:try JSONSerialization.data(withJSONObject:["api":api ?? [:],"worlds":facts ?? [:]],options:[.prettyPrinted]),uniformTypeIdentifier:"public.json");a.name="dynamic-isolated-userscripts";a.lifetime = .keepAlways;add(a)
    }

    func testGeneratedDocumentSaveDoesNotGrantNetworkOrHistoryAccess() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let defaults = UserDefaults.standard, privacy = defaults.object(forKey:"is_incognito")
        defaults.set(false,forKey:"is_incognito");defer { defaults.set(privacy,forKey:"is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data(#"{"manifest_version":3,"name":"Generated document fixture","version":"1.0","commands":{},"action":{"default_popup":"page.html"}}"#.utf8).write(to:package.appendingPathComponent("manifest.json"))
        try Data("<body id='ready'>Generated document</body>".utf8).write(to:package.appendingPathComponent("page.html"))
        let service = BrowserExtensionService(extensionRoot:root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from:package);defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:600),configuration:try XCTUnwrap(context.webViewConfiguration))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow,window = UIWindow(windowScene:scene)
        window.rootViewController = UIViewController();window.rootViewController?.view.addSubview(web);window.makeKeyAndVisible()
        defer { web.stopLoading();window.isHidden = true;window.rootViewController = nil;previous?.makeKeyAndVisible() }
        let name = "document-qa-"+UUID().uuidString+".bin"
        defer { for item in DownloadManagerService.shared.downloads where item.fileName == name { DownloadManagerService.shared.delete(item) } }
        web.load(URLRequest(url:context.baseURL.appendingPathComponent("page.html")))
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(30))
        }
        let facts = try await web.callAsyncJavaScript("""
        const data=new Uint8Array(384017).fill(73),url=URL.createObjectURL(new Blob([data]));
        const result={history:typeof chrome.downloads.search,show:typeof chrome.downloads.show};
        try{
          result.id=await chrome.downloads.download({url,filename:name});
          for(const target of ['https://example.com/video.mp4','blob:webkit-extension://foreign-owner/secret']){
            try{await chrome.downloads.download({url:target});result[target]=false;}catch(e){result[target]=true;}
          }
          return result;
        }finally{URL.revokeObjectURL(url);}
        """,arguments:["name":name],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(facts?["history"] as? String,"undefined");XCTAssertEqual(facts?["show"] as? String,"undefined")
        XCTAssertEqual(facts?["https://example.com/video.mp4"] as? Bool,true)
        XCTAssertEqual(facts?["blob:webkit-extension://foreign-owner/secret"] as? Bool,true)
        for _ in 0..<200 {
            if DownloadManagerService.shared.downloads.contains(where:{$0.fileName==name&&$0.status == .finished}) {break}
            try await Task.sleep(for:.milliseconds(30))
        }
        let saved = try XCTUnwrap(DownloadManagerService.shared.downloads.first {$0.fileName==name&&$0.status == .finished})
        XCTAssertEqual(try Data(contentsOf:saved.localURL),Data(repeating:73,count:384017))
    }

    func testTargetedMessageReachesAnExtensionDocumentInsideAWebpage() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let previousPrivacy = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito"); defer { UserDefaults.standard.set(previousPrivacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("player"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = #"{"manifest_version":3,"name":"Generic iframe messaging fixture","description":"Own extension frame messaging","version":"1.0","permissions":["tabs"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"background.mjs","type":"module"},"web_accessible_resources":[{"resources":["player/index.html"],"matches":["<all_urls>"]}]}"#
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        try Data(#"""
        chrome.runtime.onMessage.addListener((m,s,reply)=>{
          if(m.kind!=='ready')return;
          const facts={tabId:s.tab?.id??null,frameId:s.frameId??null};
          chrome.tabs.sendMessage(s.tab.id,{kind:'echo'},{frameId:s.frameId},value=>{
            facts.targeted=value??null;facts.targetedError=chrome.runtime.lastError?.message??'';
            chrome.runtime.sendMessage({kind:'echo'},value=>{facts.broadcast=value??null;facts.broadcastError=chrome.runtime.lastError?.message??'';chrome.tabs.sendMessage(s.tab.id,{kind:'promise'},{frameId:s.frameId}).then(async value=>{facts.promise=value;try{await chrome.tabs.sendMessage(s.tab.id,{kind:'reject'},{frameId:s.frameId});facts.receiverRejection='not rejected';}catch(e){facts.receiverRejection=e.message;}reply(facts);},error=>{facts.promiseError=String(error);reply(facts);});});
          });return true;
        });
        """#.utf8).write(to: package.appendingPathComponent("background.mjs"))
        try Data("<body>Frame waiting<script src='child.js'></script></body>".utf8).write(to: package.appendingPathComponent("player/index.html"))
        try Data(#"""
        const listener=(m,s,r)=>{if(m.kind==='echo'){r('iframe-echo');}else if(m.kind==='promise')return Promise.resolve('promise-echo');else if(m.kind==='reject')return Promise.reject(new Error('fixture receiver rejected'));};
        chrome.runtime.onMessage.addListener(listener);
        chrome.runtime.sendMessage({kind:'ready'},async result=>{
          window.qaFrameResult=result;const report=()=>{document.body.textContent=JSON.stringify(result);};
          result.registered=chrome.runtime.onMessage.hasListener(listener);chrome.runtime.onMessage.removeListener(listener);result.removed=!chrome.runtime.onMessage.hasListener(listener);result.hasPublicListeners=chrome.runtime.onMessage.hasListeners();
          try{
            const base=new URLSearchParams(location.search).get('base');
            result.range=await new Promise((resolve,reject)=>{const x=new XMLHttpRequest();x.open('GET',base+'/payload.bin');x.responseType='arraybuffer';x.setRequestHeader('Range','bytes=0-31');x.onload=()=>resolve({status:x.status,bytes:Array.from(new Uint8Array(x.response)),range:x.getResponseHeader('Content-Range')});x.onerror=()=>reject(new Error('range failed'));x.send();});
            result.stage='range completed';report();
            const response=await fetch(base+'/payload.bin');const bytes=new Uint8Array(await response.arrayBuffer());
            result.fetch={status:response.status,length:bytes.length,first:bytes[0],last:bytes.at(-1),url:response.url,sha256:Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('')};
            result.stage='fetch completed';report();
            result.abort=await Promise.race([new Promise(resolve=>{const x=new XMLHttpRequest();window.qaCancelable=x;x.open('GET',base+'/cancel.bin');x.onabort=()=>resolve(true);x.onerror=()=>resolve(false);x.send();setTimeout(()=>{x.abort();},500);}),new Promise(resolve=>setTimeout(()=>resolve('abort timeout'),2000))]);
          }catch(error){result.networkError=String(error?.stack??error);}
          result.complete=true;report();
        });
        """#.utf8).write(to: package.appendingPathComponent("player/child.js"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let preview = try await service.previewWebExtension(from: package)
        // Fault-inject a slow host-frame registration, while leaving the
        // publisher's first ready message and native sender identity untouched.
        try Data("setTimeout(()=>{globalThis.__souloFrameDocumentRequested=true;globalThis.__souloInstallExtensionFrameDocument?.();},100);".utf8)
            .write(to: preview.resourceURL.appendingPathComponent("__soulo_webextension_frame_document.js"))
        let record = try await service.installWebExtension(preview, access: preview.access); defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        try await WebExtensionBackgroundStartup.wait(timeout: 6) { done in context.loadBackgroundContent(completionHandler: done) }
        let payload = Data((0..<(256 * 1024 + 3)).map { UInt8($0 % 251) })
        let parent = "<script>const f=document.createElement('iframe');f.src='"+context.baseURL.appendingPathComponent("player/index.html").absoluteString+"?base='+encodeURIComponent(location.origin);document.documentElement.append(f);</script>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/index.html":Data(parent.utf8),"/payload.bin":payload,"/cancel.bin":payload],
                                                    holdAfterRequestCount:["/cancel.bin":2])
        let url = try await server.start(); defer { server.stop() }
        let configuration = WKWebViewConfiguration(); configuration.webExtensionController = runtime.controller
        let probe = ExtensionFrameMediaProbe(); configuration.userContentController.add(probe,name:"qaExtensionFrame")
        configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        defer { configuration.userContentController.removeScriptMessageHandler(forName:"qaExtensionFrame") }
        let web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:600),configuration:configuration)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene:scene)
        window.rootViewController = UIViewController();window.rootViewController?.view.addSubview(web);window.makeKeyAndVisible();runtime.register(web)
        defer { web.stopLoading();runtime.unregister(web);window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible() }
        web.load(URLRequest(url:url.appendingPathComponent("index.html")))
        var result:[String:Any]?
        for _ in 0..<300 {
            if let body=probe.latest["body"] as? String,let data=body.data(using:.utf8),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] { result=value;if value["complete"] as? Bool == true {break} }
            try await Task.sleep(for:.milliseconds(30))
        }
        let data = try JSONSerialization.data(withJSONObject: result ?? probe.latest,options:[.prettyPrinted,.sortedKeys])
        let a=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");a.name="generic-targeted-iframe-message";a.lifetime = .keepAlways;add(a)
        XCTAssertEqual(result?["broadcast"] as? String,"iframe-echo")
        XCTAssertEqual(result?["targeted"] as? String,"iframe-echo","Targeted tab messages must reach the extension's own embedded document")
        XCTAssertEqual(result?["promise"] as? String,"promise-echo")
        XCTAssertEqual(result?["receiverRejection"] as? String,"fixture receiver rejected")
        XCTAssertEqual(result?["registered"] as? Bool,true); XCTAssertEqual(result?["removed"] as? Bool,true)
        XCTAssertEqual(result?["hasPublicListeners"] as? Bool,false,"Private compatibility listeners must not look like publisher handlers")
        XCTAssertNil(result?["networkError"])
        let range = result?["range"] as? [String: Any]
        XCTAssertEqual(range?["status"] as? Int,206); XCTAssertEqual(range?["bytes"] as? [Int],Array(0..<32))
        XCTAssertEqual(range?["range"] as? String,"bytes 0-31/262147")
        let fetched = result?["fetch"] as? [String: Any]
        XCTAssertEqual(fetched?["length"] as? Int,payload.count); XCTAssertEqual(fetched?["last"] as? Int,Int(payload.last!))
        XCTAssertEqual(fetched?["sha256"] as? String,SHA256.hash(data:payload).map {String(format:"%02x",$0)}.joined())
        XCTAssertEqual(fetched?["url"] as? String,url.appendingPathComponent("payload.bin").absoluteString)
        XCTAssertEqual(result?["abort"] as? Bool,true)
        XCTAssertGreaterThanOrEqual(server.receivedRequests.filter { $0.path == "/cancel.bin" }.count,2,
                                    "Cancellation must reach a relayed request while its headers are pending")

    }

    func testModuleBackgroundTransportVariants() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let old = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito"); defer { UserDefaults.standard.set(old, forKey: "is_incognito") }
        var reports = [[String: Any]]()
        for serviceWorker in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let package = root.appendingPathComponent("package")
            try FileManager.default.createDirectory(at: package.appendingPathComponent("bg"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let background: [String: Any] = serviceWorker ? ["service_worker":"bg/worker.mjs","type":"module"] : ["scripts":["bg/worker.mjs"],"type":"module","persistent":false]
            let manifest: [String: Any] = ["manifest_version":3,"name":"Generic module transport fixture","version":"1.0","permissions":["storage"],"background":background]
            try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
            try Data("export const answer='module-pong';".utf8).write(to: package.appendingPathComponent("bg/dependency.mjs"))
            try Data("import {answer} from './dependency.mjs';chrome.runtime.onMessage.addListener((m,s,r)=>{if(m.kind==='ping'){r(answer);}});chrome.storage.local.set({moduleExecuted:true});".utf8).write(to: package.appendingPathComponent("bg/worker.mjs"))
            try Data("<body id='ready'>Module transport fixture</body>".utf8).write(to: package.appendingPathComponent("peer.html"))
            let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
            let record = try await service.installWebExtension(from: package); defer { service.deleteWebExtension(record.id) }
            let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
            var facts: [String: Any] = ["serviceWorker":serviceWorker]
            let peer = WKWebView(frame: CGRect(x:0,y:0,width:390,height:600), configuration: try XCTUnwrap(context.webViewConfiguration))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(peer); window.makeKeyAndVisible()
            defer { peer.stopLoading(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            peer.load(URLRequest(url: context.baseURL.appendingPathComponent("peer.html")))
            for _ in 0..<120 {
                if (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            facts["loaded"] = true // The normal installation must start its background.
            facts["reply"] = try? await peer.callAsyncJavaScript("return await Promise.race([new Promise(resolve=>chrome.runtime.sendMessage({kind:'ping'},r=>resolve({value:r??null,error:chrome.runtime.lastError?.message??''}))),new Promise(resolve=>setTimeout(()=>resolve({error:'timeout'}),2000))]);", arguments: [:], in: nil, contentWorld: .page)
            facts["storage"] = try? await peer.callAsyncJavaScript("return await chrome.storage.local.get('moduleExecuted');", arguments: [:], in: nil, contentWorld: .page)
            facts["errors"] = context.errors.map(\.localizedDescription); reports.append(facts)
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted,.sortedKeys])
        let a = XCTAttachment(data:data,uniformTypeIdentifier:"public.json");a.name="generic-module-transports";a.lifetime = .keepAlways;add(a)
        for report in reports { XCTAssertEqual((report["reply"] as? [String: Any])?["value"] as? String,"module-pong",String(describing:report)) }
    }

    func testOriginalFastStreamFollowsSPAEpisodeSourceChanges() async throws {
        try await exerciseFastStreamRealPackage(forceManaged: false, includeLive: false, episodeAudit: true)
    }

    func testFastStreamRealPackageStartsAndReplacesPageVideo() async throws {
        try await exerciseFastStreamRealPackage(forceManaged:false,includeLive:true)
    }

    func testFastStreamUsesNativeManagedMediaSourceWhenMediaSourceIsUnavailable() async throws {
        try await exerciseFastStreamRealPackage(forceManaged:true,includeLive:false)
    }

    func testFastStreamBilibiliKeepsIPadPlayerBounds() async throws {
        try await exerciseFastStreamRealPackage(forceManaged:false,includeLive:true,layoutAudit:true)
    }

    func testFastStreamRefreshAndToggleNeverRequireAnAppRestart() async throws {
        try await exerciseFastStreamRealPackage(forceManaged: false, includeLive: false, lifecycleAudit: true)
    }

    private func exerciseFastStreamRealPackage(forceManaged: Bool, includeLive: Bool, layoutAudit: Bool = false, lifecycleAudit: Bool = false, episodeAudit: Bool = false) async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = documents.appendingPathComponent("faststream-compatibility-qa.crx")
        guard FileManager.default.fileExists(atPath: package.path) else { throw XCTSkip("Opt-in user-supplied FastStream1.3.78") }
        let defaults = UserDefaults.standard, privacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito"); defer { defaults.set(privacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var facts = [String: Any]()
        let reportName = episodeAudit ? "faststream-spa-episodes.json" : lifecycleAudit ? "faststream-refresh-audit.json" : layoutAudit ? "faststream-ipad-layout-audit.json" : (forceManaged ? "faststream-managed-audit.json" : "faststream-audit.json")
        let downloadPrefix = "faststream-qa-" + UUID().uuidString
        defer {
            for item in DownloadManagerService.shared.downloads where item.fileName.hasPrefix(downloadPrefix) {
                DownloadManagerService.shared.delete(item)
            }
        }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent(reportName), options: .atomic)
                let a = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); a.name = forceManaged ? "faststream-native-managed-audit" : "faststream-native-audit"; a.lifetime = .keepAlways; add(a)
            }
        }
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        defer { service.discardWebExtensionPreview(preview) }
        if layoutAudit {
            let diagnostic = #"""
            chrome.runtime.onMessage.addListener((message,sender,reply)=>{
              if(message?.type!=='qa-layout-facts')return;
              reply({installed:!!globalThis.__souloExtensionMediaLayout,own:chrome.runtime.getURL(''),
                ancestors:Array.from(document.querySelectorAll('video')).flatMap(v=>Array.from((function*(e){for(let n=0;e&&n<8;e=e.parentElement,n++)yield e;})(v.parentElement),e=>{const s=getComputedStyle(e);return {class:e.className,rect:e.getBoundingClientRect().toJSON(),position:s.position,paddingTop:s.paddingTop,paddingBottom:s.paddingBottom,height:s.height,aspectRatio:s.aspectRatio};})),
                iframes:Array.from(document.querySelectorAll('iframe'),f=>({src:f.src,attribute:f.getAttribute('src'),style:f.getAttribute('style')}))});
            });
            """#
            try Data(diagnostic.utf8).write(to:preview.resourceURL.appendingPathComponent("soulo-layout-qa.js"))
            let manifestURL=preview.resourceURL.appendingPathComponent("manifest.json")
            var manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
            var scripts=try XCTUnwrap(manifest["content_scripts"] as? [[String:Any]])
            let index=try XCTUnwrap(scripts.firstIndex { ($0["matches"] as? [String])?.contains("<all_urls>")==true })
            scripts[index]["js"]=(scripts[index]["js"] as? [String] ?? [])+["soulo-layout-qa.js"]
            manifest["content_scripts"]=scripts
            try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
        }
        let publisherWorker = try Data(contentsOf:preview.resourceURL.appendingPathComponent("background/background.mjs"))
        facts["forcedManagedCapability"] = forceManaged
        facts["previewWarnings"] = preview.warnings
        try Data("<body id='ready'>FastStream audit</body>".utf8).write(to: preview.resourceURL.appendingPathComponent("soulo-audit.html"))
        try Data("self.addEventListener('message',event=>event.ports[0]?.postMessage('native-worker'));".utf8).write(to:preview.resourceURL.appendingPathComponent("soulo-qa-worker.js"))
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        let installedWorker = root.appendingPathComponent("WebExtensions/"+record.id.uuidString+"/"+record.storedResourceName+"/background/background.mjs")
        XCTAssertEqual(try Data(contentsOf:installedWorker),publisherWorker,"Generic compatibility must not rewrite the publisher's program")
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let configuration = WKWebViewConfiguration(); configuration.webExtensionController = runtime.controller
        configuration.allowsInlineMediaPlayback = true; configuration.mediaTypesRequiringUserActionForPlayback = []
        if forceManaged {
            configuration.userContentController.addUserScript(WKUserScript(source:"if(location.protocol==='webkit-extension:'&&location.pathname.endsWith('/player/index.html'))Object.defineProperty(globalThis,'MediaSource',{configurable:true,writable:true,value:undefined});",
                injectionTime:.atDocumentStart,forMainFrameOnly:false))
        }
        let mediaProbe = ExtensionFrameMediaProbe()
        configuration.userContentController.add(mediaProbe, name: "qaExtensionFrame")
        configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        defer { configuration.userContentController.removeScriptMessageHandler(forName: "qaExtensionFrame") }
        let viewport = layoutAudit ? window.bounds.size : CGSize(width:390,height:700)
        facts["viewport"] = ["width":viewport.width,"height":viewport.height]
        let browser = WKWebView(frame: CGRect(origin:.zero,size:viewport), configuration: configuration)
        let model = WebViewModel(); model.webView = browser
        let host = UIHostingController(rootView: WebViewRepresentable(viewModel: model).frame(width:viewport.width,height:viewport.height))
        window.rootViewController = host; host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { browser.stopLoading(); runtime.unregister(browser); model.webView = nil }
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let html = "<meta name='viewport' content='width=device-width'><title>FastStream fixture</title><video id='original' src='/movie.mp4' controls muted autoplay playsinline style='width:360px;height:240px'></video>"
        var mediaFiles = ["/index.html":Data(html.utf8),"/movie.mp4":try Data(contentsOf:movie)]
        if episodeAudit {
            let episodePage = html + "<div class='episode-grid'><button title='EP1' onclick=\"const v=document.querySelector('video');v.src='/movie.mp4';v.play().catch(()=>{});\">1</button><button id='next-episode' title='EP2' onclick=\"const v=document.querySelector('video');v.src='/episode-two.mp4';v.play().catch(()=>{});\">2</button></div>"
            mediaFiles["/index.html"] = Data(episodePage.utf8)
            mediaFiles["/episode-two.mp4"] = try Data(contentsOf: movie)
        }
        let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n" + (0..<4).map { "#EXTINF:2.0,\nsegment\($0).ts\n" }.joined() + "#EXT-X-ENDLIST\n"
        mediaFiles["/hls.m3u8"] = Data(playlist.utf8)
        mediaFiles["/hls.html"] = Data("<meta name='viewport' content='width=device-width'><title>HLS fixture</title><video src='/hls.m3u8' controls muted autoplay playsinline style='width:360px;height:240px'></video>".utf8)
        for index in 0..<4 {
            let part = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"segment\(index)",withExtension:"ts",subdirectory:"ReadingFixtures/HLSFragments"))
            mediaFiles["/segment\(index).ts"] = try Data(contentsOf:part)
        }
        let dashFolder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DASH", withExtension: nil, subdirectory: "ReadingFixtures/ExtensionMedia"))
        for file in try FileManager.default.contentsOfDirectory(at: dashFolder, includingPropertiesForKeys: nil) {
            mediaFiles["/" + file.lastPathComponent] = try Data(contentsOf: file)
        }
        mediaFiles["/dash.html"] = Data("<meta name='viewport' content='width=device-width'><title>DASH fixture</title><video src='/manifest.mpd' controls muted autoplay playsinline style='width:360px;height:240px'></video><script>fetch('/manifest.mpd')</script>".utf8)
        mediaFiles["/sandbox.html"] = Data("<body><script>addEventListener('message',e=>{if(e.data?.type==='sandboxResult'||e.data?.type==='sandboxError')window.sandboxResult=e.data;});</script><iframe src='/sandbox.txt' onload=\"this.contentWindow.postMessage({type:'sandboxEvaluate',body:'return left+right',argNames:['left','right'],argValues:[19,23]},location.origin)\"></iframe></body>".utf8)
        mediaFiles["/sandbox.txt"] = Data("User-agent: *\nDisallow: /".utf8)
        var mediaHeaders = ["/manifest.mpd": ["Content-Type":"application/dash+xml"], "/sandbox.txt":["Content-Type":"text/plain; charset=utf-8","Content-Security-Policy":"script-src 'none'"]]
        for path in mediaFiles.keys where path.hasSuffix(".m4s") { mediaHeaders[path] = ["Content-Type":"video/mp4"] }
        let server = try DownloadPlaybackHTTPFixture(files:mediaFiles,responseHeaders:mediaHeaders)
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let peer = WKWebView(frame: browser.frame, configuration: try XCTUnwrap(context.webViewConfiguration))
        window.rootViewController?.view.addSubview(peer); peer.isHidden = true
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("soulo-audit.html"))); defer { peer.stopLoading() }
        for _ in 0..<150 {
            if (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        facts["capabilities"] = try? await peer.evaluateJavaScript("({userScripts:typeof chrome.userScripts,mediaSource:typeof MediaSource,managedMediaSource:typeof ManagedMediaSource,serviceWorker:typeof navigator.serviceWorker,worker:typeof Worker,language:chrome.i18n.getUILanguage()})")
        facts["backgroundLoad"] = "normal installation"
        let ping = try await peer.callAsyncJavaScript("return await Promise.race([new Promise(resolve=>chrome.runtime.sendMessage({type:'PING'},reply=>resolve({reply:reply??null,error:chrome.runtime.lastError?.message??''}))),new Promise(resolve=>setTimeout(()=>resolve({error:'timeout'}),4000))]);", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        facts["ping"] = ping
        facts["nativeErrors"] = context.errors.map(\.localizedDescription)
        XCTAssertEqual(ping?["reply"] as? String, "PONG", "Real module background must answer; see faststream-native-audit")
        guard ping?["reply"] as? String == "PONG" else { return }
        browser.load(URLRequest(url: base.appendingPathComponent("index.html")))
        for _ in 0..<200 {
            if (try? await browser.evaluateJavaScript("document.querySelector('video')?.readyState>=2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        runtime.activate(browser)
        XCTAssertTrue(runtime.performAction(id: record.id))
        for _ in 0..<300 {
            if (mediaProbe.latest["readyState"] as? Int ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        facts["fixturePermission"] = context.hasAccess(to: base.appendingPathComponent("movie.mp4"))
        facts["grantedPatterns"] = context.grantedPermissionMatchPatterns.keys.map(\.string)
        facts["framesSeenFromPage"] = try? await browser.evaluateJavaScript("Array.from(document.querySelectorAll('iframe')).map(x=>x.src)")
        facts["playerFrame"] = mediaProbe.latest
        if let frame = mediaProbe.frame {
            do {
                facts["publisherUserScriptRegistration"] = try await browser.callAsyncJavaScript("return await Promise.race([chrome.runtime.sendMessage({type:'ENSURE_YT_USERSCRIPT'}),new Promise(resolve=>setTimeout(()=>resolve({success:false,reason:'timeout'}),3000))]);",arguments:[:],in:frame,contentWorld:.page)
                XCTAssertEqual((facts["publisherUserScriptRegistration"] as? [String:Any])?["success"] as? Bool,true)
                facts["frameAPIs"] = try await browser.callAsyncJavaScript("const api=globalThis.chrome;return JSON.stringify({chrome:typeof api,extension:typeof api?.extension,isExtension:!!api?.extension,tabs:typeof api?.tabs,runtime:typeof api?.runtime,getCurrent:typeof api?.tabs?.getCurrent,client:typeof window.fastStream});", arguments: [:], in: frame, contentWorld: .page)
            } catch { facts["frameAPIsError"] = String(describing: error) }
            if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent(reportName), options: .atomic)
            }
            if !browser.configuration.userContentController.userScripts.contains(where: { $0.source == ExtensionFrameMediaProbe.source }) {
                browser.configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            facts["playback"] = try? await browser.callAsyncJavaScript("const current=()=>globalThis.fastStream?.player?.getVideo?.()??document.querySelector('.mainplayer .video-container video');const deadline=performance.now()+4000;let v=current();while((!v||v.readyState<2)&&performance.now()<deadline){await new Promise(r=>setTimeout(r,30));v=current();}if(!v||v.readyState<2)return {error:'not buffered',readyState:v?.readyState??0};v.muted=true;v.currentTime=.5;const result=await Promise.race([v.play().then(()=>'',e=>String(e)),new Promise(r=>setTimeout(()=>r('play timeout'),2500))]);if(result)return {error:result};const bufferedReady=v.readyState;const until=performance.now()+3000;while(v.currentTime<=.75&&performance.now()<until)await new Promise(r=>setTimeout(r,50));const time=v.currentTime;v.pause();return {time,readyState:bufferedReady,paused:v.paused,duration:v.duration,error:v.error?.message??''};", arguments: [:], in: frame, contentWorld: .page)
        }
        if let frame = mediaProbe.frame {
            let token = try await browser.callAsyncJavaScript("const v=globalThis.fastStream?.player?.getVideo?.();if(!v)return null;let id=v.getAttribute('data-soulo-media-id');if(!id){id='qa-faststream-native';v.setAttribute('data-soulo-media-id',id);}return id;", arguments: [:], in: frame, contentWorld: .page) as? String
            let source = await WebResourceInspectionService.currentVideoResource(webView: browser, frame: frame, token: token ?? "")
            facts["nativeToolSource"] = source?.url.absoluteString ?? "missing"
            XCTAssertEqual(source?.url, base.appendingPathComponent("movie.mp4"), "The video tool must resolve the original package's selected source")
            if let source {
                let asset = await WebResourceMediaService.asset(for: source, webView: browser, preferDownloadedCopy: false)
                let item = AVPlayerItem(asset: asset), output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(output)
                let native = AVPlayer(playerItem: item); native.play()
                defer { native.pause(); native.replaceCurrentItem(with: nil) }
                var decoded = false
                for _ in 0..<200 {
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if native.currentTime().seconds > 0.2 && output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { decoded = true; break }
                    if item.status == .failed { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                facts["nativeToolDecoded"] = decoded
                XCTAssertTrue(decoded, "The native video tool must decode the source owned by the actual FastStream package")
            }
        }
        facts["requests"] = server.receivedRequests.map { ["path":$0.path,"method":$0.method,"range":$0.headers["range"] ?? ""] }
        let playback = facts["playback"] as? [String: Any]
        XCTAssertGreaterThanOrEqual(playback?["readyState"] as? Int ?? 0, 2,
                                   "The publisher's actual iframe player must buffer media when played")
        XCTAssertGreaterThan(playback?["time"] as? Double ?? 0, 0.75)
        XCTAssertEqual(playback?["paused"] as? Bool, true)
        if episodeAudit {
            let address = try await browser.evaluateJavaScript("location.href") as? String
            let frame = try XCTUnwrap(mediaProbe.frame)
            facts["sourceBefore"] = try await browser.callAsyncJavaScript("return globalThis.fastStream?.source?.url??null;", arguments: [:], in: frame, contentWorld: .page)
            _ = try await browser.evaluateJavaScript("document.getElementById('next-episode').click();true")
            for _ in 0..<300 {
                if mediaProbe.latest["source"] as? String == base.appendingPathComponent("episode-two.mp4").absoluteString,
                   mediaProbe.latest["readyState"] as? Int ?? 0 >= 2 { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            facts["sourceAfter"] = mediaProbe.latest
            facts["sourceRequests"] = server.receivedRequests.map(\.path)
            XCTAssertEqual(mediaProbe.latest["source"] as? String, base.appendingPathComponent("episode-two.mp4").absoluteString,
                           "The website changed its real media source without navigating; the active replacement must follow it")
            XCTAssertGreaterThanOrEqual(mediaProbe.latest["readyState"] as? Int ?? 0, 2)
            let afterAddress = try await browser.evaluateJavaScript("location.href") as? String
            XCTAssertEqual(afterAddress, address)
            return
        }
        func saveFromPublisherUI(label: String) async throws {
            let frame = try XCTUnwrap(mediaProbe.frame)
            let name = downloadPrefix + "-" + label
            if label == "mp4" { facts["nativeExtensionWorkerRegistration"] = try? await browser.callAsyncJavaScript("if(!navigator.serviceWorker)return {available:false};return await Promise.race([(async()=>{try{const r=await navigator.serviceWorker.register(chrome.runtime.getURL('soulo-qa-worker.js'),{scope:chrome.runtime.getURL('soulo-qa-worker-scope/')});const result={scope:r.scope,active:r.active?.state??null};await r.unregister();return result;}catch(e){return {error:String(e),name:e.name};}})(),new Promise(r=>setTimeout(()=>r({error:'timeout'}),2500))]);",arguments:[:],in:frame,contentWorld:.page) }
            facts[label+"DownloadCapabilities"] = try? await browser.callAsyncJavaScript("return {registration:navigator.serviceWorker?await Promise.race([navigator.serviceWorker.getRegistration('./').then(r=>r?{scope:r.scope,active:r.active?.state??null,script:r.active?.scriptURL??null}:null,e=>({error:String(e)})),new Promise(r=>setTimeout(()=>r({error:'timeout'}),2000))]):null,controller:navigator.serviceWorker?.controller?.scriptURL??null,clientKeys:Object.keys(window.fastStream||{})};",arguments:[:],in:frame,contentWorld:.page)
            let present = try await browser.callAsyncJavaScript("const button=document.querySelector('.main_download');if(!button)return false;button.click();return true;", arguments:[:], in:frame, contentWorld:.page) as? Bool
            XCTAssertEqual(present,true)
            var confirmed = false
            for _ in 0..<160 {
                if (try? await browser.callAsyncJavaScript("const input=document.querySelector('.swal2-input');const button=document.querySelector('.swal2-confirm');if(!input||!button)return false;input.value=name;input.dispatchEvent(new Event('input',{bubbles:true}));button.click();return true;",arguments:["name":name],in:frame,contentWorld:.page)) as? Bool == true { confirmed=true;break }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(confirmed,"The real extension must present its own filename prompt")
            var saved: BrowserDownloadItem?
            for _ in 0..<600 {
                saved = DownloadManagerService.shared.downloads.first { $0.fileName == name + ".mp4" && $0.status == .finished }
                if saved != nil { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            facts[label+"DownloadState"] = DownloadManagerService.shared.downloads.filter { $0.fileName.hasPrefix(downloadPrefix) }.map { ["name":$0.fileName,"status":$0.status.rawValue,"error":$0.errorMessage,"bytes":$0.receivedBytes] as [String:Any] }
            facts[label+"DownloadPage"] = try? await browser.callAsyncJavaScript("return document.body.innerText.slice(-1600);",arguments:[:],in:frame,contentWorld:.page)
            facts[label+"DownloadErrors"] = try? await browser.callAsyncJavaScript("return {state:window.fastStream?.saveManager?.makingDownload??null,errors:globalThis.__qaMediaErrors??[],probe:document.body.innerText.slice(-600)};",arguments:[:],in:frame,contentWorld:.page)
            guard let item = saved else { XCTFail("Publisher download must produce a finished native task"); return }
            let savedAsset = AVURLAsset(url:item.localURL)
            let duration = try await savedAsset.load(.duration)
            let playable = try await savedAsset.load(.isPlayable)
            XCTAssertTrue(playable)
            let imageGenerator = AVAssetImageGenerator(asset:savedAsset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width:128,height:128)
            let (decodedFrame,_) = try await imageGenerator.image(at:CMTime(seconds:1,preferredTimescale:600))
            XCTAssertGreaterThan(decodedFrame.width,32);XCTAssertGreaterThan(decodedFrame.height,32)
            facts[label+"DecodedSavedFrame"] = ["width":decodedFrame.width,"height":decodedFrame.height]
            XCTAssertGreaterThan(CMTimeGetSeconds(duration),7)
            XCTAssertGreaterThan((try item.localURL.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0,10000)
            facts[label+"SavedDuration"] = CMTimeGetSeconds(duration)
        }
        if lifecycleAudit {
            func waitForFreshPlayer(_ label: String) async throws {
                mediaProbe.frame = nil; mediaProbe.latest = [:]
                for _ in 0..<350 {
                    if (mediaProbe.latest["readyState"] as? Int ?? 0) >= 2 { break }
                    try await Task.sleep(for: .milliseconds(40))
                }
                facts[label] = mediaProbe.latest
                XCTAssertGreaterThanOrEqual(mediaProbe.latest["readyState"] as? Int ?? 0, 2, "Fresh native document must receive resources after \(label): \(mediaProbe.latest)")
                let frame = try XCTUnwrap(mediaProbe.frame)
                let result = try await browser.callAsyncJavaScript("const p=globalThis.fastStream,v=p?.player?.getVideo?.();if(!v)return null;v.muted=true;await v.play();const before=v.currentTime;await new Promise(r=>setTimeout(r,300));v.pause();return {before,after:v.currentTime};", arguments: [:], in: frame, contentWorld: .page) as? [String: Double]
                XCTAssertGreaterThan(result?["after"] ?? 0, result?["before"] ?? 0)
            }
            for cycle in 0..<3 {
                let before = try await browser.evaluateJavaScript("performance.timeOrigin") as? Double ?? 0
                browser.reload()
                for _ in 0..<200 {
                    if (try? await browser.evaluateJavaScript("performance.timeOrigin")) as? Double != before { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                try await waitForFreshPlayer("refresh-\(cycle)")
                XCTAssertTrue(runtime.performAction(id: record.id))
                for _ in 0..<200 {
                    if (try? await browser.evaluateJavaScript("!document.querySelector('iframe')&&!!document.querySelector('video')")) as? Bool == true { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                XCTAssertTrue(runtime.performAction(id: record.id))
                try await waitForFreshPlayer("re-enable-\(cycle)")
            }
            return
        }
        if !forceManaged && !layoutAudit { try await saveFromPublisherUI(label:"mp4") }
        func replaceAndPlay(_ url: URL, label: String) async throws {
            if layoutAudit {
                XCTAssertTrue(runtime.performAction(id:record.id))
                try await Task.sleep(for:.milliseconds(400))
            }
            mediaProbe.frame = nil; mediaProbe.latest = [:]
            let previousURL = browser.url?.absoluteString ?? ""
            if !browser.configuration.userContentController.userScripts.contains(where: { $0.source == ExtensionFrameMediaProbe.source }) {
                browser.configuration.userContentController.addUserScript(WKUserScript(source: ExtensionFrameMediaProbe.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            browser.load(URLRequest(url:url))
            for _ in 0..<240 {
                if (try? await browser.callAsyncJavaScript("return location.href!==previousURL&&!!document.querySelector('video')&&(label==='dash'||document.querySelector('video').readyState>=1);", arguments:["previousURL":previousURL,"label":label], in:nil, contentWorld:.page)) as? Bool == true { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            facts[label+"Page"] = try? await browser.evaluateJavaScript("({url:location.href,title:document.title,videos:document.querySelectorAll('video').length,text:document.body.innerText.slice(0,400)})")
            mediaProbe.frame = nil; mediaProbe.latest = [:]
            _ = try? await browser.evaluateJavaScript("(()=>{const play=Array.from(document.querySelectorAll('button,span,div')).find(e=>e.childElementCount===0&&e.textContent.trim()==='立即播放'&&e.getBoundingClientRect().width>0&&!e.closest('a[href]'))||document.querySelector('.gsl-play-mask,.mplayer-cover-play-btn,.mplayer-play-btn,.bpx-player-ctrl-play');play?.click();const v=document.querySelector('video');if(v){v.muted=true;v.play().catch(()=>{});}return true;})()")
            if label == "bilibili" {
                _ = try? await browser.evaluateJavaScript("document.querySelector('.v-dialog.open-app-dialog .icon-close')?.click();true")
                for _ in 0..<100 {
                    if (try? await browser.evaluateJavaScript("(()=>{const v=document.querySelector('video');return !!v&&v.getBoundingClientRect().width>0;})()")) as? Bool == true {break}
                    try await Task.sleep(for:.milliseconds(30))
                }
            }
            facts[label+"VideoBeforeReplacement"] = try? await browser.evaluateJavaScript("Array.from(document.querySelectorAll('video')).map(v=>({src:v.currentSrc,ready:v.readyState,paused:v.paused,width:v.getBoundingClientRect().width,height:v.getBoundingClientRect().height,display:getComputedStyle(v).display,html:v.outerHTML,ancestors:Array.from((function*(e){for(let n=0;e&&n<12;e=e.parentElement,n++)yield e;})(v.parentElement),e=>({class:e.className,display:getComputedStyle(e).display,width:e.getBoundingClientRect().width,height:e.getBoundingClientRect().height}))}))")
            if layoutAudit {
                facts[label+"LayoutBefore"] = try? await peer.callAsyncJavaScript("const tab=(await chrome.tabs.query({})).find(t=>t.url?.startsWith(address));return await Promise.race([chrome.tabs.sendMessage(tab.id,{type:'qa-layout-facts'},{frameId:0}),new Promise(r=>setTimeout(()=>r({error:'timeout'}),3000))]);",arguments:["address":url.absoluteString],in:nil,contentWorld:.page)
                XCTAssertTrue(runtime.performAction(id:record.id))
            }
            if label == "bilibili" && !layoutAudit {
                // The publisher resets activation when navigating to another
                // hostname. Exercise the same explicit action a user invokes,
                // while preserving installations that auto-enable this site.
                var installed = false
                for _ in 0..<50 {
                    installed = (try? await browser.evaluateJavaScript("Array.from(document.querySelectorAll('iframe')).some(f=>/^(webkit-extension|webkit-masked-url):/.test(f.src))")) as? Bool == true
                    if installed { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if !installed { runtime.activate(browser); XCTAssertTrue(runtime.performAction(id: record.id)) }
            }
            try await Task.sleep(for:.milliseconds(400))
            // The publisher retains enabled state across same-host navigation.
            // Its action is a toggle, so do not switch it off during this flow.
            for _ in 0..<400 {
                if (mediaProbe.latest["readyState"] as? Int ?? 0)>=2 { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            if layoutAudit {
                try await Task.sleep(for:.seconds(2))
                facts[label+"LayoutAfter"] = try? await peer.callAsyncJavaScript("const tab=(await chrome.tabs.query({})).find(t=>t.url?.startsWith(address));return await Promise.race([chrome.tabs.sendMessage(tab.id,{type:'qa-layout-facts'},{frameId:0}),new Promise(r=>setTimeout(()=>r({error:'timeout'}),3000))]);",arguments:["address":url.absoluteString],in:nil,contentWorld:.page)
                facts[label+"ReplacementGeometry"] = try? await browser.evaluateJavaScript("Array.from(document.querySelectorAll('iframe')).map(e=>({src:e.src,style:e.getAttribute('style'),rect:e.getBoundingClientRect().toJSON(),parent:e.parentElement?.outerHTML.slice(0,5000)}))")
                let geometry = (facts[label+"ReplacementGeometry"] as? [[String:Any]])?.max { (($0["rect"] as? [String:Any])?["width"] as? Double ?? 0) < (($1["rect"] as? [String:Any])?["width"] as? Double ?? 0) }
                let rect = geometry?["rect"] as? [String:Any]
                let width = rect?["width"] as? Double ?? 0, height = rect?["height"] as? Double ?? 0
                XCTAssertGreaterThan(width,600,"This regression must exercise an actual wide iPad viewport")
                XCTAssertGreaterThan(height,width * 0.35,"The inline replacement must keep the original video area rather than collapse to a control strip")
                let original = (facts[label+"VideoBeforeReplacement"] as? [[String:Any]])?.max { ($0["height"] as? Double ?? 0) < ($1["height"] as? Double ?? 0) }
                XCTAssertEqual(height,original?["height"] as? Double ?? 0,accuracy:4,"Replacement must preserve the measured original video height")
            }
            facts[label+"Iframes"] = try? await browser.evaluateJavaScript("Array.from(document.querySelectorAll('iframe'),f=>({src:f.src,rect:f.getBoundingClientRect().toJSON()}))")
            facts[label+"ProbePresent"] = browser.configuration.userContentController.userScripts.contains { $0.source == ExtensionFrameMediaProbe.source }
            facts[label+"Frame"] = mediaProbe.latest
            if let frame=mediaProbe.frame {
                facts[label+"Playback"] = try? await browser.callAsyncJavaScript("const current=()=>globalThis.fastStream?.player?.getVideo?.()??document.querySelector('.mainplayer .video-container video');const deadline=performance.now()+4000;let v=current();while((!v||v.readyState<2)&&performance.now()<deadline){await new Promise(r=>setTimeout(r,30));v=current();}if(!v||v.readyState<2)return {error:'not buffered'};v.muted=true;const events=[];for(const name of ['playing','pause','waiting','stalled','error'])v.addEventListener(name,()=>events.push({name,time:v.currentTime,ready:v.readyState}),{once:true});const client=globalThis.fastStream;const result=await Promise.race([(client?.play?.()??v.play()).then(()=>'',e=>String(e)),new Promise(r=>setTimeout(()=>r('play timeout'),2500))]);if(result)return {error:result,events};const before=v.currentTime,until=performance.now()+3000;while(v.currentTime<=before&&performance.now()<until)await new Promise(r=>setTimeout(r,50));const after=v.currentTime,playing=!v.paused;await (client?.pause?.()??v.pause());v.currentTime=Math.min(2,v.duration/2);await new Promise(r=>setTimeout(r,300));return {before,after,playing,paused:v.paused,duration:v.duration,seek:v.currentTime,events};", arguments:[:], in:frame, contentWorld:.page)
            }
            XCTAssertGreaterThanOrEqual((facts[label+"Frame"] as? [String:Any])?["readyState"] as? Int ?? 0,2,label+" must buffer inside the publisher's real player")
            let playback=facts[label+"Playback"] as? [String:Any]
            XCTAssertGreaterThan(playback?["after"] as? Double ?? 0,playback?["before"] as? Double ?? 0,label+" must actually advance")
            XCTAssertEqual(playback?["paused"] as? Bool,true)
            let image=UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
            let shot=XCTAttachment(image:image);shot.name="faststream-"+label;shot.lifetime = .keepAlways;add(shot)
        }
        if layoutAudit {
            try await replaceAndPlay(URL(string:"https://m.bilibili.com/video/BV1814y1X7UJ")!,label:"bilibili")
            for width in [768.0,390.0] {
                host.rootView = WebViewRepresentable(viewModel:model).frame(width:width,height:900)
                host.view.setNeedsLayout();host.view.layoutIfNeeded()
                for _ in 0..<100 {
                    if abs((mediaProbe.latest["width"] as? Double ?? 0)-width)<2,
                       abs((mediaProbe.latest["height"] as? Double ?? 0)-width*9/16)<4 {break}
                    try await Task.sleep(for:.milliseconds(30))
                }
                facts["resized"+String(Int(width))] = mediaProbe.latest
                XCTAssertEqual(mediaProbe.latest["width"] as? Double ?? 0,width,accuracy:2)
                XCTAssertEqual(mediaProbe.latest["height"] as? Double ?? 0,width*9/16,accuracy:4)
            }
            let beforeReload = try await browser.evaluateJavaScript("performance.timeOrigin") as? Double ?? 0
            XCTAssertTrue(runtime.performAction(id:record.id))
            // The publisher deliberately reloads the original tab when its
            // action disables an active player. Wait for that real navigation.
            var afterReload = beforeReload
            for _ in 0..<300 {
                afterReload = (try? await browser.evaluateJavaScript("performance.timeOrigin")) as? Double ?? beforeReload
                if afterReload>beforeReload,
                   (try? await browser.evaluateJavaScript("!!document.querySelector('video')")) as? Bool == true {break}
                try await Task.sleep(for:.milliseconds(30))
            }
            XCTAssertGreaterThan(afterReload,beforeReload)
            _ = try? await browser.evaluateJavaScript("(()=>{const play=Array.from(document.querySelectorAll('button,span,div')).find(e=>e.childElementCount===0&&e.textContent.trim()==='立即播放'&&e.getBoundingClientRect().width>0&&!e.closest('a[href]'))||document.querySelector('.gsl-play-mask,.mplayer-cover-play-btn,.mplayer-play-btn,.bpx-player-ctrl-play');play?.click();document.querySelector('.v-dialog.open-app-dialog .icon-close')?.click();const v=document.querySelector('video');if(v){v.muted=true;v.play().catch(()=>{});}return true;})()")
            for _ in 0..<100 {
                _ = try? await browser.evaluateJavaScript("document.querySelector('.v-dialog.open-app-dialog .icon-close')?.click();true")
                if (try? await browser.evaluateJavaScript("document.querySelector('video')?.getBoundingClientRect().height>200")) as? Bool == true {break}
                try await Task.sleep(for:.milliseconds(30))
            }
            facts["originalRestored"] = try? await browser.evaluateJavaScript("({frames:document.querySelectorAll('iframe').length,video:document.querySelector('video')?.getBoundingClientRect().toJSON()??null,ancestors:Array.from((function*(e){for(let n=0;e&&n<8;e=e.parentElement,n++)yield e;})(document.querySelector('video')),e=>({class:e.className,style:e.getAttribute('style'),rect:e.getBoundingClientRect().toJSON(),display:getComputedStyle(e).display})),html:document.querySelector('.m-video-player')?.outerHTML.slice(0,12000)})")
            let restored = facts["originalRestored"] as? [String:Any]
            XCTAssertEqual(restored?["frames"] as? Int,0)
            XCTAssertEqual((restored?["video"] as? [String:Any])?["height"] as? Double ?? 0,390*9/16,accuracy:4)
            return
        }
        try await replaceAndPlay(base.appendingPathComponent("hls.html"),label:"hls")
        if !forceManaged { try await saveFromPublisherUI(label:"hls") }
        try await replaceAndPlay(base.appendingPathComponent("dash.html"),label:"dash")
        if !forceManaged { try await saveFromPublisherUI(label:"dash") }
        if includeLive { try await replaceAndPlay(URL(string:"https://m.bilibili.com/video/BV15cs96zEvi")!,label:"bilibili") }
        facts["registeredPublisherScripts"] = try await peer.callAsyncJavaScript("return await chrome.userScripts.getScripts();",arguments:[:],in:nil,contentWorld:.page)
        _ = try await peer.callAsyncJavaScript("await chrome.userScripts.register([{id:'runner-qa',js:[{file:'userscripts/yt_runner.js'}],matches:['http://127.0.0.1/sandbox.txt'],allFrames:true,runAt:'document_start'}]);return true;",arguments:[:],in:nil,contentWorld:.page)
        browser.load(URLRequest(url:base.appendingPathComponent("sandbox.html")))
        var sandbox: [String:Any]?
        for _ in 0..<200 {
            sandbox=(try? await browser.evaluateJavaScript("window.sandboxResult??null")) as? [String:Any]
            if sandbox != nil {break}
            try await Task.sleep(for:.milliseconds(30))
        }
        facts["publisherSandboxRunner"] = sandbox
        XCTAssertEqual(sandbox?["type"] as? String,"sandboxResult")
        XCTAssertEqual(sandbox?["result"] as? Int,42,"Unmodified publisher runner must evaluate in a real isolated world despite the child document's restrictive CSP")

    }

    func testCatCatchRealPackagePopupLocalizationAndMediaCapture() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = documents.appendingPathComponent("catcatch-compatibility-qa.crx")
        guard FileManager.default.fileExists(atPath: package.path) else { throw XCTSkip("Opt-in official Cat Catch package") }
        let previousDownloads = Set(DownloadManagerService.shared.downloads.map(\.id))
        defer {
            for item in DownloadManagerService.shared.downloads where !previousDownloads.contains(item.id)
                && URL(string: item.sourceURLString)?.host == "127.0.0.1" {
                DownloadManagerService.shared.delete(item)
            }
        }
        let defaults = UserDefaults.standard, previousPrivacy = UserDefaults.standard.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        defer { defaults.set(previousPrivacy, forKey: "is_incognito") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var facts: [String: Any] = [:]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent("catcatch-audit.json"), options: .atomic)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "catcatch-native-audit"; attachment.lifetime = .keepAlways; add(attachment)
                print("CATCATCH AUDIT", String(decoding: data, as: UTF8.self))
            }
        }
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        defer { service.discardWebExtensionPreview(preview) }
        facts["previewWarnings"] = preview.warnings
        try Data("<html><body id='ready'>Native extension audit</body></html>".utf8)
            .write(to: preview.resourceURL.appendingPathComponent("soulo-audit.html"))
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        facts["displayName"] = context.webExtension.displayName
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let config = WKWebViewConfiguration(); config.webExtensionController = runtime.controller
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        window.rootViewController?.view.addSubview(browser); runtime.register(browser)
        defer { browser.stopLoading(); runtime.unregister(browser) }
        let movieURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let movieBytes = try Data(contentsOf: movieURL)
        let html = "<meta name='viewport' content='width=device-width'><title>Cat Catch fixture</title><body id='ready'><video src='/movie.mp4' controls muted autoplay playsinline></video><script>fetch('/audit.m3u8').then(r=>r.text()).then(()=>document.body.dataset.fetched='yes')</script>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/index.html": Data(html.utf8), "/movie.mp4": movieBytes, "/audit.m3u8": Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)], requiredCookie: "soulo_catcatch_qa=allowed")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain:"127.0.0.1",.path:"/",.name:"soulo_catcatch_qa",.value:"allowed"]))
        let cookies = browser.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { continuation in cookies.setCookie(cookie) { continuation.resume() } }
        defer { cookies.delete(cookie) }
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        runtime.activate(browser)
        browser.load(URLRequest(url: address.appendingPathComponent("index.html")))
        let peer = WKWebView(frame: browser.frame, configuration: try XCTUnwrap(context.webViewConfiguration))
        window.rootViewController?.view.addSubview(peer); peer.isHidden = true
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("soulo-audit.html")))
        defer { peer.stopLoading() }
        for _ in 0..<100 {
            if (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        facts["api"] = try await peer.evaluateJavaScript("({message:chrome.i18n.getMessage('currentPage'),detached:(0,chrome.i18n.getMessage)('currentPage'),proxy:new Proxy(chrome.i18n.getMessage,{})('currentPage'),wrapped:new Proxy(function(...args){return chrome.i18n.getMessage(...args)},{})('currentPage'),language:chrome.i18n.getUILanguage(),downloads:typeof chrome.downloads,webRequest:typeof chrome.webRequest,locale:navigator.language})")
        do {
            try await WebExtensionBackgroundStartup.wait(timeout: 6) { completion in context.loadBackgroundContent(completionHandler: completion) }
            facts["background"] = "started"
        } catch { facts["background"] = error.localizedDescription }
        let query = """
        return await Promise.race([
          new Promise(resolve=>{chrome.runtime.sendMessage({Message:'getAllData'},reply=>resolve({reply:reply??null,error:chrome.runtime.lastError?.message??''}));}),
          new Promise(resolve=>setTimeout(()=>resolve({error:'reply timeout'}),4000))
        ]);
        """
        for _ in 0..<30 {
            let result = try await peer.callAsyncJavaScript(query, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            facts["localCapture"] = result
            let items = (result?["reply"] as? [String: [[String: Any]]])?.values.flatMap { $0 } ?? []
            if Set(items.compactMap { $0["name"] as? String }).isSuperset(of: ["movie.mp4", "audit.m3u8"]) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["localRequests"] = server.receivedRequests.map(\.path)
        facts["backgroundError"] = try? await peer.callAsyncJavaScript("return await chrome.storage.local.get('__souloCatError');", arguments: [:], in: nil, contentWorld: .page)
        facts["backgroundState"] = try? await peer.callAsyncJavaScript("""
        return await Promise.race([(async()=>{
          try { const bg=await chrome.runtime.getBackgroundPage();return {hasG:typeof bg?.G,sync:bg?.G?.initSyncComplete,local:bg?.G?.initLocalComplete,cache:bg?.cacheData,webRequestConstant:typeof chrome.webRequest.OnBeforeSendHeadersOptions}; }
          catch(e){return {error:String(e)};}
        })(),new Promise(resolve=>setTimeout(()=>resolve({error:'background page unavailable'}),2000))]);
        """, arguments: [:], in: nil, contentWorld: .page)
        let popup = try XCTUnwrap(WebExtensionPopupPresenter.contentViewController(for: try XCTUnwrap(context.action(for: nil))))
        let shown = expectation(description: "Cat Catch native popup presented")
        WebExtensionPopupPresenter.present(popup, ownerID: record.id, title: record.name) { error in XCTAssertNil(error); shown.fulfill() }
        await fulfillment(of: [shown], timeout: 5)
        defer { WebExtensionPopupPresenter.dismissPopup(ownedBy: record.id) }
        func findWeb(_ view: UIView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { findWeb($0) }.first }
        let popupWeb = try XCTUnwrap(findWeb(popup.view))
        for _ in 0..<100 {
            if (try? await popupWeb.evaluateJavaScript("document.querySelectorAll('#mediaList .panel').length>=2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300)) // Let the native popover and WebKit compositor settle.
        facts["popup"] = try await popupWeb.evaluateJavaScript("({text:document.body.innerText.slice(0,2000),message:chrome.i18n.getMessage('currentPage'),width:innerWidth,scrollWidth:document.documentElement.scrollWidth,bodyWidth:document.body.getBoundingClientRect().width,dark:matchMedia('(prefers-color-scheme: dark)').matches,background:getComputedStyle(document.body).backgroundColor,styles:[...document.styleSheets].map(s=>({href:s.href,rules:(()=>{try{return s.cssRules.length}catch(e){return String(e)}})()}))})")
        facts["popupViewport"] = try await popupWeb.evaluateJavaScript("({height:innerHeight,toolbarTop:document.getElementById('DownFile').getBoundingClientRect().top,toolbarBottom:document.getElementById('DownFile').getBoundingClientRect().bottom})")
        facts["nativePopupHeight"] = popupWeb.bounds.height
        let safe = popup.view.safeAreaLayoutGuide.layoutFrame
        XCTAssertLessThanOrEqual(popupWeb.frame.maxY, safe.maxY - 15)
        let buttons = try await popupWeb.evaluateJavaScript("[...document.querySelectorAll('#down button')].filter(button=>button.getClientRects().length).map(button=>({id:button.id,left:button.getBoundingClientRect().left,right:button.getBoundingClientRect().right,top:button.getBoundingClientRect().top,bottom:button.getBoundingClientRect().bottom,width:innerWidth,height:innerHeight}))") as? [[String: Any]] ?? []
        facts["footerButtons"] = buttons
        XCTAssertGreaterThan(buttons.count, 5)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(button["left"] as? Double), -1)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(button["top"] as? Double), 0)
            XCTAssertLessThanOrEqual(try XCTUnwrap(button["right"] as? Double), try XCTUnwrap(button["width"] as? Double) + 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(button["bottom"] as? Double), try XCTUnwrap(button["height"] as? Double) + 1)
        }
        let renderedPopup = XCTAttachment(image: try await popupWeb.takeSnapshot(configuration: nil))
        renderedPopup.name = "catcatch-webview-render"; renderedPopup.lifetime = .keepAlways; add(renderedPopup)
        if ProcessInfo.processInfo.arguments.contains("-catcatch-visual-hold") {
            let marker = documents.appendingPathComponent("catcatch-visual-ready")
            try Data().write(to: marker)
            defer { try? FileManager.default.removeItem(at: marker) }
            try await Task.sleep(for: .seconds(5))
        }
        let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        shot.name = "catcatch-native-popup"; shot.lifetime = .keepAlways; add(shot)
        facts["folderAPIs"] = try await popupWeb.evaluateJavaScript("({show:typeof chrome.downloads.show,folder:typeof chrome.downloads.showDefaultFolder})")
        _ = try await popupWeb.evaluateJavaScript("window.folderPopupSentinel=484;chrome.downloads.showDefaultFolder();true")
        let defaultFolder = try await waitForDownloadFolder(in: window)
        await withCheckedContinuation { continuation in defaultFolder.dismiss(animated: false) { continuation.resume() } }
        let retainedPopup = try await popupWeb.evaluateJavaScript("window.folderPopupSentinel")
        XCTAssertEqual(retainedPopup as? Int, 484, "The real extension popup must survive opening its download folder")
        let initialDownloads = Set(DownloadManagerService.shared.downloads.map(\.id))
        _ = try await popupWeb.evaluateJavaScript("window.__downloadChanges=[];chrome.downloads.onChanged.addListener(value=>window.__downloadChanges.push(value));")
        // Deny clipboard access in the harness: this test must not read the
        // developer's clipboard or wait for WebKit's Paste menu.
        var clicked: Any?
        do {
            try await WebExtensionBackgroundStartup.wait(timeout: 3) { completion in
                popupWeb.evaluateJavaScript("(()=>{Object.defineProperty(navigator.clipboard,'readText',{configurable:true,value:()=>Promise.reject(new DOMException('Clipboard denied in QA','NotAllowedError'))});const row=[...document.querySelectorAll('#mediaList .panel')].find(row=>row.querySelector('.name')?.textContent.includes('movie.mp4'));const button=row?.querySelector('.download');if(!button)return false;setTimeout(()=>button.click(),0);return true;})()") { value, error in clicked = value; completion(error) }
            }
            facts["directDownloadClick"] = clicked
        } catch { facts["downloadProbeError"] = error.localizedDescription }
        var added: [BrowserDownloadItem] = []
        for _ in 0..<100 {
            added = DownloadManagerService.shared.downloads.filter { !initialDownloads.contains($0.id) }
            if added.contains(where: { $0.status == .finished }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        facts["downloadEvents"] = try? await popupWeb.evaluateJavaScript("window.__downloadChanges")
        facts["nativeDownloads"] = added.map { ["name": $0.fileName,"status": $0.status.rawValue,"bytes": $0.receivedBytes] as [String: Any] }
        facts["showSavedDownload"] = try await popupWeb.callAsyncJavaScript("const items=await chrome.downloads.search({state:'complete'});const item=items.find(item=>item.url.includes('/movie.mp4'));if(!item)throw Error('Missing completed download');chrome.downloads.show(item.id);return {id:item.id};", arguments: [:], in: nil, contentWorld: .page)
        let itemFolder = try await waitForDownloadFolder(in: window)
        try await Task.sleep(for: .milliseconds(200))
        let filesShot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        filesShot.name = "catcatch-download-directory"; filesShot.lifetime = .keepAlways; add(filesShot)
        await withCheckedContinuation { continuation in itemFolder.dismiss(animated: false) { continuation.resume() } }
        XCTAssertTrue(added.contains(where: { $0.status == .finished && $0.receivedBytes == Int64(movieBytes.count) }), "The publisher's download button must save the actual media bytes and preserve the site's cookies")
        let changes = facts["downloadEvents"] as? [[String: Any]] ?? []
        XCTAssertTrue(changes.contains { ($0["state"] as? [String: Any])?["current"] as? String == "complete" })
        for item in added {
            DownloadManagerService.shared.delete(item)
            try? FileManager.default.removeItem(at: item.localURL)
        }
        // Exercise the publisher's inline preview and content-script controls.
        _ = try await popupWeb.evaluateJavaScript("(()=>{const row=[...document.querySelectorAll('#mediaList .panel')].find(row=>row.querySelector('.name')?.textContent.includes('movie.mp4'));row.querySelector('video').muted=true;row.querySelector('#play').click();return true;})()")
        for _ in 0..<50 {
            if (try? await popupWeb.evaluateJavaScript("[...document.querySelectorAll('#mediaList video')].some(video=>video.readyState>=2&&video.duration>0)")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["preview"] = try? await popupWeb.evaluateJavaScript("[...document.querySelectorAll('#mediaList video')].map(video=>({src:video.currentSrc,ready:video.readyState,duration:isFinite(video.duration)?video.duration:0}))")
        _ = try await popupWeb.evaluateJavaScript("document.getElementById('otherTab').click();true")
        for _ in 0..<50 {
            if (try? await popupWeb.evaluateJavaScript("document.getElementById('videoIndex').value==='0'&&document.getElementById('videoTabIndex').value!=='-1'&&$('#speed').data('switch')==='speed'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["mediaControlState"] = try? await popupWeb.callAsyncJavaScript("""
        const tabs=await chrome.tabs.query({windowType:'normal'});
        const replies=await Promise.all(tabs.map(tab=>Promise.race([
          new Promise(resolve=>chrome.tabs.sendMessage(tab.id,{Message:'getVideoState',index:0},{frameId:0},reply=>resolve({id:tab.id,reply:reply??null,error:chrome.runtime.lastError?.message??''}))),
          new Promise(resolve=>setTimeout(()=>resolve({id:tab.id,error:'timeout'}),1500))
        ])));
        return {tabs,replies,active:G.tabId,stored:G.mediaControl,tab:document.getElementById('videoTabIndex').innerHTML,video:document.getElementById('videoIndex').innerHTML,switch:$('#speed').data('switch')};
        """, arguments: [:], in: nil, contentWorld: .page)
        facts["zeroTabLookup"] = try? await popupWeb.callAsyncJavaScript("""
        const diagnostics={bound:!!chrome.tabs.get.__souloNativeBinding,i18n:!!chrome.i18n.getMessage.__souloNativeBinding};
        return await Promise.race([new Promise(resolve=>{
          try{chrome.tabs.get(0,tab=>resolve({...diagnostics,tab:tab??null,error:chrome.runtime.lastError?.message??null}));}
          catch(error){resolve({...diagnostics,thrown:String(error)});}
        }),new Promise(resolve=>setTimeout(()=>resolve({timeout:true}),1000))]);
        """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await popupWeb.evaluateJavaScript("document.getElementById('playbackRate').value='1.5';document.getElementById('speed').click();true")
        for _ in 0..<20 {
            if (try? await browser.evaluateJavaScript("document.querySelector('video').playbackRate")) as? Double == 1.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["mediaControlRate"] = try? await browser.evaluateJavaScript("document.querySelector('video').playbackRate")
        await withCheckedContinuation { continuation in WebExtensionPopupPresenter.dismissCurrentPopup { continuation.resume() } }
        let liveURL = URL(string: "https://m.bilibili.com/video/BV15cs96zEvi")!
        browser.load(URLRequest(url: liveURL))
        for _ in 0..<100 {
            if !browser.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        facts["livePage"] = try? await browser.evaluateJavaScript("({url:location.href,title:document.title,text:document.body?.innerText?.slice(0,400),videos:document.querySelectorAll('video').length})")
        facts["liveCapture"] = try? await peer.callAsyncJavaScript(query, arguments: [:], in: nil, contentWorld: .page)
        let livePopup = try XCTUnwrap(WebExtensionPopupPresenter.contentViewController(for: try XCTUnwrap(context.action(for: nil))))
        let liveShown = expectation(description: "Cat Catch popup above the supplied Bilibili page")
        WebExtensionPopupPresenter.present(livePopup, ownerID: record.id, title: record.name) { error in XCTAssertNil(error); liveShown.fulfill() }
        await fulfillment(of: [liveShown], timeout: 5)
        let liveWeb = try XCTUnwrap(findWeb(livePopup.view)); liveWeb.reload()
        for _ in 0..<60 {
            if (try? await liveWeb.evaluateJavaScript("document.querySelectorAll('#mediaList .panel').length>0")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await liveWeb.evaluateJavaScript("document.getElementById('currentTab').click();true")
        try await Task.sleep(for: .milliseconds(300))
        facts["livePopup"] = try? await liveWeb.evaluateJavaScript("({text:document.body.innerText.slice(0,1200),width:innerWidth,scrollWidth:document.documentElement.scrollWidth,dark:matchMedia('(prefers-color-scheme: dark)').matches})")
        let liveShot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
        liveShot.name = "catcatch-bilibili-supplied-page"; liveShot.lifetime = .keepAlways; add(liveShot)
        facts["advancedAPIs"] = try? await liveWeb.evaluateJavaScript("({screenCapture:typeof navigator.mediaDevices?.getDisplayMedia,filePicker:typeof showSaveFilePicker})")
        facts["contextErrors"] = context.errors.map(\.localizedDescription)
        let api = facts["api"] as? [String: Any]
        XCTAssertNotEqual(api?["message"] as? String, "currentPage", "Native localization must return a translated message")
        XCTAssertFalse((api?["message"] as? String ?? "").isEmpty)
        XCTAssertEqual(api?["detached"] as? String, api?["message"] as? String)
        XCTAssertEqual(api?["proxy"] as? String, api?["message"] as? String)
        let capture = facts["localCapture"] as? [String: Any]
        let captured = capture?["reply"] as? [String: Any]
        XCTAssertFalse(captured?.isEmpty ?? true, "The actual background must capture the local media requests")
        let ui = facts["popup"] as? [String: Any]
        XCTAssertFalse((ui?["text"] as? String ?? "").contains("currentPage"))
        let inlinePreviews = facts["preview"] as? [[String: Any]] ?? []
        XCTAssertTrue(inlinePreviews.contains { ($0["ready"] as? Int ?? 0) >= 2 && ($0["duration"] as? Double ?? 0) > 0 })
        let missingTab = facts["zeroTabLookup"] as? [String: Any]
        XCTAssertTrue(missingTab?["bound"] as? Bool == true)
        XCTAssertTrue(missingTab?["i18n"] as? Bool == true)
        XCTAssertFalse((missingTab?["error"] as? String ?? "").isEmpty)
        XCTAssertEqual(facts["mediaControlRate"] as? Double, 1.5)
    }

    func testTYTYRealPackageWebsiteMessagingProxyAndDownloadSwitch() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = documents.appendingPathComponent("tyty-compatibility-qa.crx")
        guard FileManager.default.fileExists(atPath: package.path) else { throw XCTSkip("Opt-in user-supplied TYTY 0.6.6 package") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        defer { service.discardWebExtensionPreview(preview) }
        XCTAssertTrue(WebExtensionTYTYAdapter.isPrepared(in: preview.resourceURL))
        let worker = preview.resourceURL.appendingPathComponent("background.min.js")
        let first = try Data(contentsOf: worker)
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: preview.resourceURL)
        XCTAssertEqual(try Data(contentsOf: worker), first)
        let library = preview.resourceURL.appendingPathComponent("lib/jsencrypt.min.js")
        let logger = "addEventListener('error',e=>chrome.storage.local.set({__souloQAError:String(e.message)}));addEventListener('unhandledrejection',e=>chrome.storage.local.set({__souloQAError:String(e.reason)}));"
        try Data((logger + String(contentsOf: library, encoding: .utf8)).utf8).write(to: library)
        try Data("<html><body id='ready'>TYTY native verification</body></html>".utf8)
            .write(to: preview.resourceURL.appendingPathComponent("peer.html"))
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let peer = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: try XCTUnwrap(context.webViewConfiguration))
        window.rootViewController?.view.addSubview(peer)
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("peer.html")))
        for _ in 0..<100 {
            if (try? await peer.evaluateJavaScript("!!document.getElementById('ready') && typeof chrome !== 'undefined'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { peer.stopLoading() }
        let backgroundLog = try await peer.callAsyncJavaScript("return await chrome.storage.local.get('__souloQAError');", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertNil(backgroundLog?["__souloQAError"], String(describing: backgroundLog))
        let server = try DownloadPlaybackHTTPFixture(files: ["/external.html": Data("<html><body id='ready'>TYTY website API</body></html>".utf8), "/echo": Data("local-fixture-ok".utf8)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        var components = try XCTUnwrap(URLComponents(url: address.appendingPathComponent("external.html"), resolvingAgainstBaseURL: false)); components.host = "localhost"
        let configuration = WKWebViewConfiguration(); configuration.webExtensionController = runtime.controller
        let bridge = try XCTUnwrap(runtime.externalMessagingCompatibilityScript)
        configuration.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        let web = WKWebView(frame: peer.frame, configuration: configuration)
        window.rootViewController?.view.addSubview(web); runtime.register(web)
        defer { web.stopLoading(); runtime.unregister(web) }
        web.load(URLRequest(url: try XCTUnwrap(components.url)))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        func send(_ action: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
            let input: [String: Any] = ["id": WebExtensionTYTYAdapter.chromeID, "message": ["action": action, "payload": payload]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            do { _ = try await web.evaluateJavaScript("""
                (()=>{window.__souloTYTYReply=null;const input=\(json);const api=chrome.runtime;
                try{api.sendMessage(input.id,input.message,reply=>{window.__souloTYTYReply={reply,error:api.lastError?.message||''};});}
                catch(e){window.__souloTYTYReply={error:String(e)};}return true;})();
                """) } catch {
                let detail = error as NSError; print("TYTY JAVASCRIPT ERROR", detail.domain, detail.code, detail.userInfo); throw error
            }
            var result: [String: Any] = [:]
            for _ in 0..<100 {
                if let text = try await web.evaluateJavaScript("JSON.stringify(window.__souloTYTYReply)") as? String,
                   let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) as? [String: Any] { result = value; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            print("TYTY FUNCTIONAL", action, result)
            return result["reply"] as? [String: Any] ?? [:]
        }
        let pong = try await send("ping")
        XCTAssertEqual((pong["data"] as? [String: Any])?["pong"] as? String, "pong")
        XCTAssertEqual((pong["data"] as? [String: Any])?["version"] as? String, "0.6.6")
        let response = try await send("proxyHttpRequest", payload: ["url": address.appendingPathComponent("echo").absoluteString])
        XCTAssertEqual((response["data"] as? [String: Any])?["status"] as? Int, 200)
        XCTAssertEqual((response["data"] as? [String: Any])?["body"] as? String, "local-fixture-ok")
        let rules = try await peer.callAsyncJavaScript("return await chrome.declarativeNetRequest.getDynamicRules();", arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        XCTAssertEqual(rules?.count, 10, String(describing: rules))
        for enabled in [false, true] {
            _ = try await peer.callAsyncJavaScript("await chrome.storage.local.set({interceptShare:enabled});", arguments: ["enabled": enabled], in: nil, contentWorld: .page)
            var ids: [Int] = []
            for _ in 0..<100 {
                ids = (try await peer.callAsyncJavaScript("return (await chrome.declarativeNetRequest.getDynamicRules()).map(r=>r.id);", arguments: [:], in: nil, contentWorld: .page) as? [Int]) ?? []
                if ids.contains(10) == enabled { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(ids.contains(10), enabled)
            XCTAssertEqual(ids.count, enabled ? 10 : 6)
        }
        service.setWebExtensionEnabled(record.id, enabled: false)
        let disabled = try await send("ping")
        XCTAssertNil(disabled["success"])
        service.setWebExtensionEnabled(record.id, enabled: true)
        for _ in 0..<100 where service.loadingWebExtensions.contains(record.id) { try await Task.sleep(for: .milliseconds(50)) }
        let restored = try await send("ping")
        XCTAssertEqual((restored["data"] as? [String: Any])?["pong"] as? String, "pong")
    }

    func testBackgroundStartupTimeoutAndCancellationIgnoreLateCallbacks() async throws {
        var completion: ((Error?) -> Void)?
        do {
            try await WebExtensionBackgroundStartup.wait(timeout: 0.02) { completion = $0 }
            XCTFail("Missing startup callback must time out")
        } catch { XCTAssertTrue(error is WebExtensionBackgroundStartupError) }
        completion?(nil); completion?(URLError(.cancelled))
        let task = Task { try await WebExtensionBackgroundStartup.wait(timeout: 5) { completion = $0 } }
        await Task.yield(); task.cancel()
        do { try await task.value; XCTFail("Cancellation must settle startup") } catch { XCTAssertTrue(error is CancellationError) }
        completion?(nil)
    }

    func testPopupHasCloseControlAndDisablingOnlyDismissesItsOwnPopup() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Popup lifecycle fixture","version":"1.0","action":{"default_popup":"popup.html"}}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data("<html><meta name='viewport' content='width=device-width'><body style='margin:0;background:white'><main style='height:70px'>Extension popup fixture</main><footer style='position:fixed;bottom:0;left:0;right:0;height:40px;background:rgb(36,104,189)'><button id='close'>Close</button></footer></body></html>".utf8)
            .write(to: package.appendingPathComponent("popup.html"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let action = try XCTUnwrap(context.action(for: nil))
        @MainActor final class AlertProbe: NSObject, WKUIDelegate {
            var message: String?
            func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
                self.message = message
                completionHandler()
            }
        }
        let alertProbe = AlertProbe()
        action.popupWebView?.uiDelegate = alertProbe
        let popup = try XCTUnwrap(WebExtensionPopupPresenter.contentViewController(for: action))
        popup.preferredContentSize = CGSize(width: 300, height: 160)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), presenter = UIViewController()
        window.rootViewController = presenter; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let shown = expectation(description: "Extension popup presented")
        WebExtensionPopupPresenter.present(popup, ownerID: record.id, title: record.name) { error in
            XCTAssertNil(error); shown.fulfill()
        }
        await fulfillment(of: [shown], timeout: 5)
        let navigation = try XCTUnwrap(presenter.presentedViewController as? UINavigationController)
        XCTAssertTrue(navigation.topViewController === popup)
        XCTAssertEqual(popup.navigationItem.rightBarButtonItem?.accessibilityIdentifier, "extensions.popup.close")
        func findWeb(_ view: UIView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap { findWeb($0) }.first }
        let firstWeb = try XCTUnwrap(findWeb(popup.view))
        for _ in 0..<100 {
            if (try? await firstWeb.evaluateJavaScript("!!document.getElementById('close')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        popup.view.layoutIfNeeded()
        let safeFrame = popup.view.safeAreaLayoutGuide.layoutFrame
        XCTAssertGreaterThanOrEqual(firstWeb.frame.minX, safeFrame.minX + 11)
        XCTAssertLessThanOrEqual(firstWeb.frame.maxX, safeFrame.maxX - 11)
        XCTAssertLessThanOrEqual(firstWeb.frame.maxY, safeFrame.maxY - 15,
                                 "The fixed footer needs blank space above the safe area and rounded corners")
        let footer = try await firstWeb.evaluateJavaScript("({bottom:document.querySelector('footer').getBoundingClientRect().bottom,height:innerHeight,hit:document.elementFromPoint(20,innerHeight-20)?.closest('footer')!==null})") as? [String: Any]
        XCTAssertLessThanOrEqual(try XCTUnwrap(footer?["bottom"] as? Double), try XCTUnwrap(footer?["height"] as? Double) + 1)
        XCTAssertEqual(footer?["hit"] as? Bool, true)
        let rendered = try await firstWeb.takeSnapshot(configuration: nil)
        let raster = try XCTUnwrap(rendered.cgImage)
        let width = raster.width, height = raster.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bluePixels: Int = bytes.withUnsafeMutableBytes { buffer in
            let drawing = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            drawing.draw(raster, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var count = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let red = abs(Int(pixels[offset]) - 36)
                let green = abs(Int(pixels[offset + 1]) - 104)
                let blue = abs(Int(pixels[offset + 2]) - 189)
                if red < 5 && green < 5 && blue < 5 { count += 1 }
            }
            return count
        }
        XCTAssertGreaterThan(bluePixels, 500, "The fixed footer must be painted, not merely present in DOM geometry")
        _ = try await firstWeb.evaluateJavaScript("window.__popupClosedMarker='old';alert('Native callback preserved');true")
        XCTAssertEqual(alertProbe.message, "Native callback preserved", "The close delegate must preserve other native UI callbacks")
        let repeated = try XCTUnwrap(WebExtensionPopupPresenter.contentViewController(for: action))
        let repeatedShown = expectation(description: "Repeated action retains the current popup")
        WebExtensionPopupPresenter.present(repeated, ownerID: record.id, title: record.name) { error in XCTAssertNil(error); repeatedShown.fulfill() }
        await fulfillment(of: [repeatedShown], timeout: 5)
        let retainedDocument = try await firstWeb.evaluateJavaScript("window.__popupClosedMarker")
        XCTAssertEqual(retainedDocument as? String, "old", "Repeated action requests must not close and reload the active popup")
        let footerShot = XCTAttachment(image: rendered); footerShot.name = "generic-extension-fixed-footer"; footerShot.lifetime = .keepAlways; add(footerShot)
        firstWeb.evaluateJavaScript("window.close()", completionHandler: nil)
        for _ in 0..<100 where presenter.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(presenter.presentedViewController, "An extension must be able to close its own popup")
        guard presenter.presentedViewController == nil else { return }
        let reopened = try XCTUnwrap(WebExtensionPopupPresenter.contentViewController(for: action))
        let reopenedShown = expectation(description: "Extension popup reopened")
        WebExtensionPopupPresenter.present(reopened, ownerID: record.id, title: record.name) { error in XCTAssertNil(error); reopenedShown.fulfill() }
        await fulfillment(of: [reopenedShown], timeout: 5)
        let secondWeb = try XCTUnwrap(findWeb(reopened.view))
        for _ in 0..<100 {
            if !secondWeb.isLoading, (try? await secondWeb.evaluateJavaScript("!!document.getElementById('close')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let freshDocument = try await secondWeb.evaluateJavaScript("window.__popupClosedMarker===undefined")
        XCTAssertTrue(freshDocument as? Bool == true, "Reopening must start a fresh popup document")
        WebExtensionPopupPresenter.dismissPopup(ownedBy: UUID())
        XCTAssertNotNil(presenter.presentedViewController)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "third-party-extension-popup-close"; attachment.lifetime = .keepAlways; add(attachment)
        service.setWebExtensionEnabled(record.id, enabled: false)
        for _ in 0..<100 where presenter.presentedViewController != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(presenter.presentedViewController)
    }

    func testLoadingExtensionCanBeDisabledAndStaleEnableDoesNotRestoreIt() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Loading switch fixture","version":"1.0","action":{"default_popup":"popup.html"}}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data("<html><body>Popup</body></html>".utf8).write(to: package.appendingPathComponent("popup.html"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(record.id) }
        service.setWebExtensionEnabled(record.id, enabled: false)
        for _ in 0..<3 {
            service.setWebExtensionEnabled(record.id, enabled: true)
            XCTAssertTrue(service.loadingWebExtensions.contains(record.id))
            XCTAssertTrue(service.canChangeWebExtensionEnabled(record.id))
            XCTAssertNil(service.webExtensionAction(for: record.id))
            XCTAssertFalse(service.performWebExtensionAction(record.id))
            service.setWebExtensionEnabled(record.id, enabled: false)
            XCTAssertFalse(service.loadingWebExtensions.contains(record.id))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(service.webExtensions.first { $0.id == record.id }?.isEnabled ?? true)
            XCTAssertFalse(NativeWebExtensionRuntime.shared.controller.extensionContexts.contains { $0.uniqueIdentifier == record.id.uuidString })
        }
        service.setWebExtensionEnabled(record.id, enabled: true)
        for _ in 0..<100 where service.loadingWebExtensions.contains(record.id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(service.webExtensions.first { $0.id == record.id }?.isEnabled == true)
        XCTAssertNotNil(service.webExtensionAction(for: record.id))
    }

    func testFailedEnableRestoresOffStateAndExplainsFailure() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(#"{"manifest_version":3,"name":"Load failure fixture","version":"1.0"}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        let service = BrowserExtensionService.shared
        let record = try await service.installWebExtension(from: source)
        defer { service.deleteWebExtension(record.id) }
        service.setWebExtensionEnabled(record.id, enabled: false)
        let installed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouloExtensions/WebExtensions/\(record.id.uuidString)")
        try FileManager.default.removeItem(at: installed)
        service.setWebExtensionEnabled(record.id, enabled: true)
        for _ in 0..<100 where service.loadingWebExtensions.contains(record.id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(service.loadingWebExtensions.contains(record.id))
        XCTAssertEqual(service.webExtensions.first { $0.id == record.id }?.isEnabled, false)
        XCTAssertNotNil(service.webExtensionErrors[record.id])
        service.deleteWebExtension(record.id)
        XCTAssertNil(service.webExtensionErrors[record.id])
    }

    func testUserScriptUpdateKeepsValuesAndOffStateThenDeleteRemovesAccess() throws {
        let service = BrowserExtensionService.shared
        let source = """
        // ==UserScript==
        // @name Lifecycle \(UUID().uuidString)
        // @namespace soulo.lifecycle
        // @version 1
        // @match https://example.com/*
        // @grant GM_getValue
        // @grant GM_setValue
        // ==/UserScript==
        """
        let record = try service.saveUserScript(id: nil, fallbackName: "Lifecycle", source: source, explicitPatterns: nil, injectionTime: nil)
        defer { service.deleteUserScript(record.id) }
        try service.setStoredValue(#"{"value":"retained"}"#, forKey: "state", scriptID: record.id)
        service.setUserScriptEnabled(record.id, enabled: false)
        let updated = try service.saveUserScript(id: nil, fallbackName: "Lifecycle", source: source.replacingOccurrences(of: "@version 1", with: "@version 2"), explicitPatterns: nil, injectionTime: nil)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.storedValues?["state"], #"{"value":"retained"}"#)
        service.deleteUserScript(record.id)
        XCTAssertNil(service.userScript(id: record.id))
        XCTAssertThrowsError(try service.setStoredValue(#"{"value":1}"#, forKey: "state", scriptID: record.id))
    }
}

@MainActor
final class ExtensionFrameMediaProbe: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    var latest = [String: Any]()
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any],
              let url = value["url"] as? String, url.hasPrefix("webkit-extension:"),
              url.contains("/player/index.html") else { return }
        frame = message.frameInfo; latest = value
    }
    static let source = #"""
    (()=>{if(location.protocol!=='webkit-extension:')return;
      const errors=[];const record=e=>{errors.push(String(e?.stack??e?.message??e));if(errors.length>8)errors.shift();};
      addEventListener('error',e=>record(e.error??e.message));addEventListener('unhandledrejection',e=>record(e.reason));
      const original=console.error;console.error=function(...a){a.forEach(record);return Reflect.apply(original,console,a);};
      const report=()=>{const v=globalThis.fastStream?.player?.getVideo?.()??document.querySelector('.mainplayer .video-container video');window.webkit.messageHandlers.qaExtensionFrame.postMessage({
        url:location.href,title:document.title,source:globalThis.fastStream?.source?.url??null,readyState:v?.readyState??0,time:v?.currentTime??0,
        duration:Number.isFinite(v?.duration)?v.duration:null,error:v?.error?.message??'',
        mediaSource:typeof MediaSource,managedMediaSource:typeof ManagedMediaSource,
        width:innerWidth,height:innerHeight,scrollWidth:document.documentElement.scrollWidth,
        videoRect:v?.getBoundingClientRect().toJSON()??null,playerRect:document.querySelector('.mainplayer')?.getBoundingClientRect().toJSON()??null,errors,
        client:typeof window.fastStream,body:document.body?.innerText.slice(0,1800)??''});};
      addEventListener('DOMContentLoaded',report);setInterval(report,100);
    })();
    """#
}
