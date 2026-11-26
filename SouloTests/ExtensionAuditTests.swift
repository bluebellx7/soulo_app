import XCTest
import JavaScriptCore
import WebKit
import UIKit
import SwiftUI
@testable import Soulo

@MainActor
final class ExtensionAuditTests: XCTestCase {
    @MainActor
    func testStockTampermonkeyStartsWithoutDiagnosticPublisherEdits() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native WebExtensions") }
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let file=documents.appendingPathComponent("tampermonkey-compatibility-qa.crx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:file.path),"Opt-in official package")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("tm-stock-"+UUID().uuidString)
        let service=BrowserExtensionService(extensionRoot:root)
        defer{try? FileManager.default.removeItem(at:root)}
        let preview=try await service.previewWebExtension(from:file)
        try Data("<html><head></head><body id='stock-ready'>Stock package probe</body></html>".utf8).write(to:preview.resourceURL.appendingPathComponent("stock-probe.html"))
        let record=try await service.installWebExtension(preview,access:preview.access)
        defer{service.deleteWebExtension(record.id)}
        XCTAssertEqual(record.version,"5.5.1")
        XCTAssertTrue(record.isEnabled)
        let context=try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first{$0.uniqueIdentifier==record.id.uuidString})
        let page=WKWebView(frame:CGRect(x:0,y:0,width:390,height:600),configuration:try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url:context.baseURL.appendingPathComponent("stock-probe.html")))
        for _ in 0..<150 {
            if (try? await page.evaluateJavaScript("!!document.getElementById('stock-ready')")) as? Bool == true {break}
            try await Task.sleep(for:.milliseconds(30))
        }
        defer{page.stopLoading()}
        let code="// ==UserScript==\n// @name Stock startup probe\n// @namespace soulo.qa.stock\n// @version 1.0\n// @match https://example.com/stock/*\n// @grant none\n// ==/UserScript==\ndocument.documentElement.dataset.souloStock='ready';"
        let response=try await page.callAsyncJavaScript("return await chrome.runtime.sendMessage({method:'saveScript',uuid:'qa-stock',new_script:true,code,reload:false,origin:'options'});",arguments:["code":code],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertEqual(response?["installed"] as? Bool,true,"An actual publisher request must succeed without logging instrumentation")
        let diagnostics=XCTAttachment(string:context.errors.map(\.localizedDescription).joined(separator:";"));diagnostics.name="stock-background-capability-probes";diagnostics.lifetime = .keepAlways;add(diagnostics)
    }

    @MainActor
    func testCurrentEdgeStorePackageDownloadsThroughTheProductionTransport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_INSTALL_QA"] == "1", "Opt-in current official store transport")
        let file = try await WebExtensionStoreInstallService.shared.downloadPackage(from: "https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file)
        XCTAssertTrue(data.starts(with: Data("Cr24".utf8)))
        XCTAssertGreaterThan(data.count, 100_000)
    }

    func testCurrentEdgeSimpleGestureInstallsAndStartsFromTheOfficialLink() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native WebExtensions") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_SIMPLE_GESTURE_QA"] == "1", "Opt-in official Edge package")
        let source = "https://microsoftedge.microsoft.com/addons/detail/simple-gesture/hfhdokhgdkcaebhjdblfgafnimchimkd"
        let service = BrowserExtensionService.shared
        let preview = try await WebExtensionStoreInstallService.shared.preview(from: source)
        defer { service.discardWebExtensionPreview(preview) }
        try XCTSkipIf(preview.replacingID != nil, "Requires a simulator without an existing installation")
        XCTAssertEqual(preview.version, "8.0")
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        XCTAssertEqual(record.sourceURL, source)
        XCTAssertTrue(service.hasWebExtensionOptions(record.id))
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let address = try XCTUnwrap(context.optionsPageURL)
        let key = "official-simple-gesture-" + UUID().uuidString
        let manager = TabManager(storageKey: key)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: StorePackageAuditBrowser(manager: manager))
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            previous?.makeKeyAndVisible()
            for tab in manager.tabs { tab.webViewModel.releaseWebViewRuntime() }
            UserDefaults.standard.removeObject(forKey: key)
        }
        service.openWebExtensionOptions(record.id, in: manager)
        for _ in 0..<100 where manager.activeTab?.webViewModel.webView == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let page = try XCTUnwrap(manager.activeTab?.webViewModel.webView)
        try await waitForAuditPage(page, at: address, mainDocumentOnly: true)
        let result = try await runAuditJavaScript("""
            const browserAPI = globalThis.browser ?? globalThis.chrome;
            return [document.title, await browserAPI.runtime.sendMessage('isUserAgentSwitched')];
            """, on: page) as? [Any]
        XCTAssertEqual(result?.first as? String, "Settings - Simple Gesture")
        XCTAssertEqual(result?.last as? Bool, false)

        let initialDownloads = Set(DownloadManagerService.shared.downloads.map(\.id))
        let directory = DownloadManagerService.downloadsDirectory
        let initialFiles = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        defer {
            DownloadManagerService.shared.downloads.filter {
                !initialDownloads.contains($0.id) && $0.fileName.hasPrefix("simple-gesture")
            }.forEach { download in
                DownloadManagerService.shared.delete(download)
                if download.localURL.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
                   !initialFiles.contains(download.localURL.lastPathComponent) {
                    try? FileManager.default.removeItem(at: download.localURL)
                }
            }
        }
        _ = try await runAuditJavaScript("document.getElementById('exportSetting').click(); return true;", on: page)
        for _ in 0..<50 {
            if DownloadManagerService.shared.downloads.contains(where: {
                !initialDownloads.contains($0.id) && $0.fileName.hasPrefix("simple-gesture") && $0.status == .finished
            }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let exported = try XCTUnwrap(DownloadManagerService.shared.downloads.first {
            !initialDownloads.contains($0.id) && $0.fileName.hasPrefix("simple-gesture") && $0.status == .finished
        }, "The extension's own export button must save its JSON in Soulo")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.localURL)) as? [String: Any])
        var restored = document
        var settings = try XCTUnwrap(document["ini"] as? [String: Any])
        settings["timeout"] = 1173
        restored["ini"] = settings
        let json = String(decoding: try JSONSerialization.data(withJSONObject: restored), as: UTF8.self)
        _ = try await runAuditJavaScript("""
            setTimeout(() => {
              const input = document.getElementById('importSetting');
              const transfer = new DataTransfer();
              transfer.items.add(new File([json], 'simple-gesture.json', {type:'application/json'}));
              input.files = transfer.files;
              input.dispatchEvent(new Event('change', {bubbles:true}));
            }, 50);
            return true;
            """, on: page, arguments: ["json": json])
        var imported = false
        for _ in 0..<60 {
            if (try? await runAuditJavaScript("""
                const browserAPI = globalThis.browser ?? globalThis.chrome;
                const state = await browserAPI.storage.local.get('simple_gesture');
                return Number(state?.simple_gesture?.timeout) === 1173 && document.getElementById('timeout')?.value === '1173';
                """, on: page)) as? Bool == true { imported = true; break }
            try await Task.sleep(for: .milliseconds(120))
        }
        XCTAssertTrue(imported, "Imported JSON must restore both saved preferences and the options screen")
    }

    func testUserScriptDetectionHandlesStoreFilenamesAndRejectsErrorResponses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let generic = root.appendingPathComponent("download")
        let header = "// ==UserScript==\n// @name Source check\n// @match https://example.com/*\n// ==/UserScript==\n"
        // End the bounded read in the middle of a multibyte character.
        try Data((header + String(repeating: "中", count: 30000)).utf8).write(to: generic)
        let source = URL(string: "https://raw.githubusercontent.com/author/repo/main/example.user.js")!
        XCTAssertEqual(BrowserExtensionInstallCandidate.detect(fileURL: generic, sourceURL: source)?.kind, .userScript)
        let errorFile = root.appendingPathComponent("broken.user.js")
        for body in ["404: Not Found", "<!doctype html><html>Server error</html>", "console.log('ordinary script')"] {
            try Data(body.utf8).write(to: errorFile)
            XCTAssertNil(BrowserExtensionInstallCandidate.detect(fileURL: errorFile, sourceURL: source))
        }
    }

    func testCRLFUserScriptMetadataKeepsDeclaredScope() throws {
        let source = ["// ==UserScript==", "// @name Windows script", "// @version 1.0",
                      "// @match *://example.test/*", "// @match file://*/*.mp4", "// @exclude *://example.test/private/*",
                      "// @grant GM_setValue", "// ==/UserScript==", "void 0"].joined(separator: "\r\n")
        let metadata = BrowserExtensionService.parseMetadata(from: source)
        XCTAssertEqual(metadata.name, "Windows script")
        XCTAssertEqual(metadata.patterns, ["*://example.test/*", "file://*/*.mp4"])
        XCTAssertEqual(metadata.excludePatterns, ["*://example.test/private/*"])
        XCTAssertEqual(metadata.grants, ["GM_setValue"])
        XCTAssertTrue(UserScriptURLMatcher.matches(url: URL(string: "https://example.test/article")!, patterns: ["*://*"]))
        XCTAssertFalse(UserScriptURLMatcher.matches(url: URL(fileURLWithPath: "/tmp/a.mp4"), patterns: metadata.patterns))
        XCTAssertFalse(UserScriptURLMatcher.matches(url: URL(string: "https://unrelated.test/article")!, patterns: metadata.patterns))
    }

    func testDeclaredSidePanelUsesNativePopupAndCompatibilityScriptParses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["panel.html", "publisher.html"] {
            try Data("<html><body>Fixture</body></html>".utf8).write(to: root.appendingPathComponent(file))
        }
        let url = root.appendingPathComponent("manifest.json")
        func preparedPopup(_ action: [String: Any]) async throws -> String? {
            try JSONSerialization.data(withJSONObject: [
                "manifest_version": 3, "name": "Panel fixture", "version": "1.0",
                "action": action, "side_panel": ["default_path": "/panel.html"],
                "permissions": ["sidePanel", "downloads", "offscreen", "proxy"]
            ] as [String: Any]).write(to: url)
            try await WebExtensionPackagePreparer.installCompatibilityLayer(in: root)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            return (result["action"] as? [String: Any])?["default_popup"] as? String
        }
        let panelPopup = try await preparedPopup([:])
        let publisherPopup = try await preparedPopup(["default_popup": "publisher.html"])
        XCTAssertEqual(panelPopup, "panel.html")
        XCTAssertEqual(publisherPopup, "publisher.html")
        let javascript = try String(contentsOf: root.appendingPathComponent("__soulo_webextension_compatibility.js"), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(javascript)
        XCTAssertNil(context.exception)
    }

    func testSidePanelChangesPreserveThePublishersPopup() async throws {
        let context = try XCTUnwrap(JSContext())
        let resolve: @convention(block) (String, String) -> String = { path, base in
            URL(string: path, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? ""
        }
        context.setObject(resolve, forKeyedSubscript: "__resolve" as NSString)
        context.evaluateScript("""
        function URL(path,base){this.href=__resolve(path,base);}
        let current='default.html', opened;
        const action={async getPopup(){return current;},async setPopup({popup}){current=popup;},
          async openPopup(){opened=current;}};
        const tab={id:1,windowId:1,active:true};
        const manifest={permissions:['sidePanel'],side_panel:{default_path:'panel.html'},action:{default_popup:'default.html'}};
        var chrome={action,tabs:{get:async()=>tab,query:async()=>[tab]},
          runtime:{getManifest:()=>manifest,getURL:path=>__resolve(path,'webkit-extension://fixture/')}};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        context.evaluateScript("""
        var result, failure;
        (async()=>{
          const sidePanel=chrome.sidePanel;
          const disable=sidePanel.setPanelBehavior({openPanelOnActionClick:false});
          await action.setPopup({popup:'publisher.html'});
          await disable;
          const disabled=current;
          await sidePanel.open({tabId:1});
          const restored=current;
          await sidePanel.setPanelBehavior({openPanelOnActionClick:true});
          const enabled=current;
          const switchToPopup=sidePanel.setPanelBehavior({openPanelOnActionClick:false});
          await action.setPopup({popup:'options.html'});
          await switchToPopup;
          result=[disabled,opened,restored,enabled,current];
        })().catch(error=>failure=String(error));
        """)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("failure")?.isUndefined == true)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(result)")?.toString(),
                       #"["publisher.html","panel.html","publisher.html","panel.html","options.html"]"#)
    }

    func testNativeI18nBindingsSupportDetachedProxyAndCallbackCallsWithoutChangingResults() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var globalThis=this;
        var api={getMessage:function(key,subs){if(this!==api)return undefined;return key==='hello'?'Hello '+subs[0]:'';},
          getUILanguage:function(){return this===api?'en-US':undefined;},
          getAcceptLanguages:function(callback){if(this===api)callback(['en-US']);}};
        var chrome={i18n:api},browser=chrome;
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        XCTAssertNil(context.exception)
        context.evaluateScript("var first=api.getMessage;var detached=first('hello',['world']);var proxy=new Proxy(first,{})('hello',['proxy']);var languages;api.getAcceptLanguages(v=>languages=v);var missing=api.getMessage('absent',[]);")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("detached")?.toString(), "Hello world")
        XCTAssertEqual(context.evaluateScript("proxy")?.toString(), "Hello proxy")
        XCTAssertEqual(context.evaluateScript("languages[0]")?.toString(), "en-US")
        XCTAssertEqual(context.evaluateScript("missing")?.toString(), "")
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        XCTAssertTrue(context.evaluateScript("api.getMessage===first")!.toBool(), "Re-preparing an installed extension must not nest wrappers")
    }

    func testLegacyExtensionURLUsesNativeRuntimeAndKeepsExistingImplementations() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const runtime = {getURL(path) {
          if (this !== runtime || typeof path !== 'string') throw new TypeError('Invalid extension path');
          return 'webkit-extension://fixture/' + path;
        }};
        var chrome = {runtime};
        const existing = () => 'native';
        var browser = {runtime, extension:{getURL:existing}};
        """)
        let source = WebExtensionPackagePreparer.nativeBindingsSourceForTesting
        context.evaluateScript(source)
        XCTAssertNil(context.exception)
        context.evaluateScript("const getURL = chrome.extension.getURL;")
        context.evaluateScript(source)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("getURL('welcome.html')")?.toString(), "webkit-extension://fixture/welcome.html")
        XCTAssertTrue(context.evaluateScript("getURL === chrome.extension.getURL && browser.extension.getURL === existing")!.toBool())
        XCTAssertTrue(context.evaluateScript("(() => { try { getURL(null); return false; } catch(error) { return error instanceof TypeError; } })()")!.toBool())
    }

    func testMissingTabGroupsUseUngroupedIDInResultsAndToolbarEvents() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const subscribers=new Set();
        const clickEvent={
          addListener(listener){subscribers.add(listener);},
          removeListener(listener){subscribers.delete(listener);},
          hasListener(listener){return subscribers.has(listener);},
          hasListeners(){return subscribers.size>0;}
        };
        const tabs=[{id:1},{id:2,groupId:7}];
        var chrome={tabs:{query(options,reply){if(reply)reply(tabs);else return Promise.resolve(tabs);}},
          windows:{getAll:()=>Promise.resolve([{id:3,tabs}])},action:{onClicked:clickEvent}};
        """)
        let source = WebExtensionPackagePreparer.nativeBindingsSourceForTesting
        context.evaluateScript(source)
        context.evaluateScript(source)
        context.evaluateScript("""
        const seen=[];
        const listener=tab=>seen.push(tab.groupId);
        const event=chrome.action.onClicked;
        event.addListener(listener);
        event.addListener(listener);
        const registered=event.hasListener(listener) && event.hasListeners();
        subscribers.forEach(callback=>callback(tabs[0]));
        subscribers.forEach(callback=>callback(tabs[1]));
        event.removeListener(listener);
        const removed=!event.hasListener(listener) && !event.hasListeners();
        var callbackGroups, promiseGroups, windowGroups;
        chrome.tabs.query({},values=>callbackGroups=values.map(tab=>tab.groupId));
        chrome.tabs.query({}).then(values=>promiseGroups=values.map(tab=>tab.groupId));
        chrome.windows.getAll({populate:true}).then(values=>windowGroups=values[0].tabs.map(tab=>tab.groupId));
        """)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("registered && removed && chrome.tabGroups===undefined")?.toBool() == true)
        for expression in ["seen", "callbackGroups", "promiseGroups", "windowGroups"] {
            XCTAssertEqual(context.evaluateScript("JSON.stringify(\(expression))")?.toString(), "[-1,7]")
        }
        XCTAssertTrue(context.evaluateScript("tabs[0].groupId===undefined")?.toBool() == true)
    }

    func testCreatedNavigationTargetUsesNativeOpenerAndHonorsPermissionsAndFilters() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const callbacks=new Set(), seen=[];
        let permitted=true;
        class URL {
          constructor(value) { [, this.hostname, this.pathname] = /^https?:\\/\\/([^/]+)(.*)$/.exec(value); }
        }
        const onCreated={addListener:fn=>callbacks.add(fn),removeListener:fn=>callbacks.delete(fn)};
        var chrome={tabs:{onCreated},webNavigation:{},permissions:{contains:async()=>permitted}};
        const existing={addListener:()=>{}};
        var browser={tabs:{onCreated},webNavigation:{onCreatedNavigationTarget:existing}};
        const announce=async tab=>{for(const callback of callbacks)await callback(tab);};
        """)
        let source = WebExtensionPackagePreparer.nativeBindingsSourceForTesting
        context.evaluateScript(source)
        context.evaluateScript(source)
        context.evaluateScript("""
        var passed=false;
        (async()=>{
          const event=chrome.webNavigation.onCreatedNavigationTarget;
          const listener=details=>seen.push([details.tabId,details.sourceTabId,details.sourceFrameId,details.url]);
          event.addListener(listener,{url:[{hostEquals:'example.test',pathPrefix:'/allowed'}]});
          event.addListener(listener);
          const registered=event.hasListener(listener)&&event.hasListeners()&&callbacks.size===1;
          await announce({id:9,openerTabId:4,pendingUrl:'https://example.test/allowed',url:'about:blank'});
          await announce({id:10,openerTabId:4,url:'https://example.test/blocked'});
          await announce({id:11,url:'https://example.test/allowed'});
          await announce({id:12,openerTabId:4,url:'https://example.test/allowed',incognito:true});
          permitted=false;
          await announce({id:13,openerTabId:4,url:'https://example.test/allowed'});
          event.removeListener(listener);
          passed=registered&&!event.hasListeners()&&!callbacks.size&&browser.webNavigation.onCreatedNavigationTarget===existing;
        })();
        """)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("passed")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(seen)")?.toString(),
                       #"[[9,4,0,"https://example.test/allowed"]]"#)
    }

    func testCreatedNavigationTargetDeliversBrowserTabOpenerToWorker() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        try XCTSkipUnless(ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 18,
                          "Covers the fallback for iOS 18 WebKit")
        let defaults = UserDefaults.standard
        let previousPrivacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        let key = "extension-navigation-target-\(UUID().uuidString)"
        defaults.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        let manager = TabManager(storageKey: key)
        defer {
            defaults.set(previousPrivacy, forKey: "is_incognito")
            manager.synchronizePrivacyMode()
            manager.saveToDisk()
            defaults.removeObject(forKey: key)
        }
        let runtime = NativeWebExtensionRuntime.shared
        runtime.attach(tabManager: manager)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        let publisher = root.appendingPathComponent("publisher", isDirectory: true)
        try FileManager.default.createDirectory(at: publisher, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Navigation target audit","version":"1.0","permissions":["tabs","storage","webNavigation"],"host_permissions":["https://example.test/*"],"background":{"service_worker":"worker.js"},"options_ui":{"page":"index.html"}}"#.utf8)
            .write(to: publisher.appendingPathComponent("manifest.json"))
        try Data("""
        chrome.webNavigation.onCreatedNavigationTarget.addListener(details => {
          chrome.storage.local.set({target:details});
        }, {url:[{hostEquals:'example.test'}]});
        """.utf8).write(to: publisher.appendingPathComponent("worker.js"))
        try Data("<!doctype html><title>Navigation target audit</title>".utf8)
            .write(to: publisher.appendingPathComponent("index.html"))

        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("extensions", isDirectory: true))
        let preview = try await service.previewWebExtension(from: publisher)
        defer { service.discardWebExtensionPreview(preview) }
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let popup = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        let pageURL = context.baseURL.appendingPathComponent("index.html")
        popup.load(URLRequest(url: pageURL))
        try await waitForAuditPage(popup, at: pageURL)

        let source = manager.createTab(url: URL(string: "https://example.test/source")!, switchTo: false)
        let targetURL = URL(string: "https://example.test/destination")!
        manager.createTab(url: targetURL, switchTo: false, navigationOpenerID: source.id)
        manager.createTab(url: URL(string: "https://example.test/ordinary")!, switchTo: false)
        let result = try await runAuditJavaScript("""
        for(let attempt=0;attempt<40;attempt++){
          const {target}=await chrome.storage.local.get('target');
          if(target){
            const tabs=await chrome.tabs.query({});
            const source=tabs.find(tab=>tab.url==='https://example.test/source');
            const destination=tabs.find(tab=>tab.url==='https://example.test/destination');
            if(source&&destination)return {target,source:source.id,destination:destination.id};
          }
          await new Promise(resolve=>setTimeout(resolve,75));
        }
        return await chrome.storage.local.get('target');
        """, on: popup) as? [String: Any]
        let event = try XCTUnwrap(result?["target"] as? [String: Any], "\(String(describing: result))")
        XCTAssertEqual(event["url"] as? String, targetURL.absoluteString)
        XCTAssertEqual(event["sourceFrameId"] as? Int, 0)
        XCTAssertEqual(event["sourceTabId"] as? Int, try XCTUnwrap(result?["source"] as? Int))
        XCTAssertEqual(event["tabId"] as? Int, try XCTUnwrap(result?["destination"] as? Int))
    }

    func testGetAllFramesLeavesMissingFrameTreesEmptyAndPreservesPermissionErrors() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const runtime={};
        const queueMicrotask=fn=>Promise.resolve().then(fn);
        const webNavigation={getAllFrames({tabId},callback){
          const frames=tabId===5?[{frameId:0,url:'https://example.test/'}]:undefined;
          const message=tabId===6?'Invalid call. Permission denied.':tabId===4?'Invalid call. Main frame not found.':'Invalid call. Tab not found.';
          if(callback){
            if(!frames)runtime.lastError={message};
            try{callback(frames);}finally{delete runtime.lastError;}
            return;
          }
          return frames?Promise.resolve(frames):Promise.reject(Error(message));
        }};
        var chrome={runtime,webNavigation};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        context.evaluateScript("""
        var observed;
        const callbackResult=tabId=>new Promise(resolve=>webNavigation.getAllFrames({tabId},frames=>
          resolve({frames,error:runtime.lastError?.message})));
        (async()=>{
          const unloaded=await webNavigation.getAllFrames({tabId:4});
          const loaded=await webNavigation.getAllFrames({tabId:5});
          const denied=await webNavigation.getAllFrames({tabId:6}).catch(error=>error.message);
          const missing=await webNavigation.getAllFrames({tabId:7});
          observed={unloaded,loaded:loaded[0].frameId,denied,missing,callbackEmpty:await callbackResult(4),
            callbackMissing:await callbackResult(7),callbackDenied:await callbackResult(6)};
        })();
        """)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(observed)")?.toString(),
                       #"{"unloaded":null,"loaded":0,"denied":"Invalid call. Permission denied.","missing":null,"callbackEmpty":{"frames":null},"callbackMissing":{"frames":null},"callbackDenied":{"error":"Invalid call. Permission denied."}}"#)
    }

    func testMissingWindowsCreateUsesNativeTabsWithoutOpeningPrivateWindows() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const requests=[];
        const getCurrent=async()=>({id:7,incognito:false});
        const nativeCreate=async()=>({id:99});
        const tabs={async create(options){requests.push(options);return {...options,id:requests.length};}};
        var chrome={windows:{getCurrent},tabs};
        var browser={windows:{getCurrent,create:nativeCreate},tabs};
        """)
        let source = WebExtensionPackagePreparer.nativeBindingsSourceForTesting
        context.evaluateScript(source)
        context.evaluateScript("const create=chrome.windows.create, native=browser.windows.create;")
        context.evaluateScript(source)
        context.evaluateScript("""
        var results;
        (async()=>{
          const group=await create({url:['https://a.example','https://b.example']});
          const blank=await new Promise(resolve=>create(resolve));
          const background=await create({url:'https://c.example',focused:false});
          let privateDenied=false;
          try{await create({incognito:true});}catch(_){privateDenied=true;}
          results={groupID:group.id,ids:group.tabs.map(tab=>tab.id),blank:blank.tabs.map(tab=>tab.id),
            background:background.tabs[0].active,privateDenied,nativeID:(await browser.windows.create()).id};
        })();
        """)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("create===chrome.windows.create && browser.windows.create===native")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(results)")?.toString(),
                       #"{"groupID":7,"ids":[1,2],"blank":[3],"background":false,"privateDenied":true,"nativeID":99}"#)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(requests.map(value=>[value.windowId,value.active,value.url||null]))")?.toString(),
                       #"[[7,true,"https://a.example"],[7,false,"https://b.example"],[7,true,null],[7,false,"https://c.example"]]"#)
    }

    func testManagedOptionalPermissionIsVisibleAndRequiresApproval() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let publisher = root.appendingPathComponent("publisher", isDirectory: true)
        try FileManager.default.createDirectory(at: publisher, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = #"{"manifest_version":3,"name":"Optional downloads fixture","description":"Permission review fixture","version":"1.0","optional_permissions":["downloads"]}"#
        try Data(manifest.utf8).write(to: publisher.appendingPathComponent("manifest.json"))

        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store", isDirectory: true))
        let preview = try await service.previewWebExtension(from: publisher)
        defer { service.discardWebExtensionPreview(preview) }
        XCTAssertTrue(preview.permissions.contains("downloads"))
        XCTAssertFalse(preview.access.allowsPermission("downloads"))

        var access = preview.access
        access.setPermission("downloads", allowed: true)
        let installed = try await service.installWebExtension(preview, access: access)
        defer { service.deleteWebExtension(installed.id) }
        XCTAssertTrue(service.webExtensionDetails(installed.id).permissions.contains("downloads"))
        XCTAssertTrue(service.webExtensionAccess(installed.id).allowsPermission("downloads"))

        access.setPermission("downloads", allowed: false)
        try service.setWebExtensionAccess(access, id: installed.id)
        XCTAssertTrue(service.webExtensionDetails(installed.id).permissions.contains("downloads"))
        XCTAssertFalse(service.webExtensionAccess(installed.id).allowsPermission("downloads"))
    }

    func testExtensionsWithoutDynamicScriptsDoNotResendBrowserScripts() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        final class InstrumentedController: WKUserContentController {
            var removals = 0
            override func removeAllUserScripts() {
                removals += 1
                super.removeAllUserScripts()
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resourceDirectory = directory.appendingPathComponent("Extension")
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = #"{"manifest_version":3,"name":"Empty scripts fixture","version":"1.0"}"#
        try Data(manifest.utf8).write(to: resourceDirectory.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: resourceDirectory))
        let host = WebExtensionUserScripts()
        let controller = InstrumentedController()
        controller.addUserScript(WKUserScript(source: "true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        host.attach(controller)
        let originalCount = controller.userScripts.count
        host.restore(context: context, resourceURL: resourceDirectory, access: nil)
        host.refresh(context: context, access: .requested(permissions: [], sites: []))
        host.remove(context: context)
        XCTAssertEqual(controller.removals, 0)
        XCTAssertEqual(controller.userScripts.count, originalCount)
    }

    func testNavigationBindingReportsSameDocumentChangesAndRetainsFilters() async throws {
        let context = try XCTUnwrap(JSContext())
        let parseURL: @convention(block) (String) -> NSDictionary = { raw in
            let url = URL(string: raw)!
            return ["protocol": (url.scheme ?? "") + ":", "hostname": url.host ?? "", "origin": "\(url.scheme ?? "")://\(url.host ?? "")", "pathname": url.path, "search": url.query.map { "?" + $0 } ?? "", "port": url.port.map(String.init) ?? ""]
        }
        context.setObject(parseURL, forKeyedSubscript: "__parseURL" as NSString)
        context.evaluateScript("""
        var globalThis=this,changed,committed,removed;
        function URL(value){Object.assign(this,__parseURL(value));}
        var frame={url:'https://example.test/start',documentId:'document-one'};
        var chrome={tabs:{query:()=>Promise.resolve([{id:1}]),onUpdated:{addListener:fn=>changed=fn},onRemoved:{addListener:fn=>removed=fn}},
          webNavigation:{getFrame:()=>Promise.resolve({...frame}),onCommitted:{addListener:fn=>committed=fn}},webRequest:{}};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        XCTAssertNil(context.exception)
        context.evaluateScript("var events=[];var listener=d=>events.push(d);chrome.webNavigation.onHistoryStateUpdated.addListener(listener,{url:[{hostEquals:'example.test',pathPrefix:'/next'}]});")
        try await Task.sleep(for: .milliseconds(20))
        context.evaluateScript("frame.url='https://example.test/next/1';changed(1,{url:frame.url});")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 1)
        XCTAssertEqual(context.evaluateScript("events[0].documentId")?.toString(), "document-one")
        context.evaluateScript("frame.url='https://example.test/ignored';changed(1,{url:frame.url});")
        try await Task.sleep(for: .milliseconds(20))
        context.evaluateScript("frame={url:'https://example.test/next/2',documentId:'document-two'};changed(1,{url:frame.url});")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 1, "Filters and full document navigations must not produce false history events")
        context.evaluateScript("chrome.webNavigation.onHistoryStateUpdated.removeListener(listener);removed(1);")
        XCTAssertFalse(context.evaluateScript("chrome.webNavigation.onHistoryStateUpdated.hasListeners()")!.toBool())
        XCTAssertTrue(context.evaluateScript("chrome.webRequest.OnBeforeSendHeadersOptions.EXTRA_HEADERS===undefined")!.toBool())
        XCTAssertEqual(context.evaluateScript("chrome.webRequest.OnBeforeSendHeadersOptions.REQUEST_HEADERS")?.toString(), "requestHeaders")
    }

    func testReservedZeroTabIDUsesErrorCallbackWithoutChangingValidCallsOrValidation() async throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var globalThis=this,seen='pending',sync=true;
        var chrome={runtime:{},tabs:{get:function(id,callback){
          if(this!==chrome.tabs)throw Error('receiver');
          if(id===0)throw Error('Tab 0 does not exist');
          if(id===Number.MAX_SAFE_INTEGER){Promise.resolve().then(()=>{chrome.runtime.lastError={message:'Tab does not exist'};try{callback(undefined);}finally{delete chrome.runtime.lastError;}});return;}
          if(typeof id!=='number')throw Error('Invalid type');
          if(callback)callback({id});else return Promise.resolve({id});
        }}};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        context.evaluateScript("var first=chrome.tabs.get;chrome.tabs.get(0,value=>{seen={sync,error:chrome.runtime.lastError.message,value};});sync=false;")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(context.exception)
        XCTAssertFalse(context.evaluateScript("seen.sync")!.toBool())
        XCTAssertEqual(context.evaluateScript("seen.error")?.toString(), "Tab does not exist")
        XCTAssertTrue(context.evaluateScript("chrome.runtime.lastError===undefined&&seen.value===undefined")!.toBool())
        context.evaluateScript("var promiseError;chrome.tabs.get(0).catch(error=>promiseError=error.message);var valid;chrome.tabs.get(42,value=>valid=value.id);var invalid;try{chrome.tabs.get('wrong',()=>{});}catch(error){invalid=error.message;}")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(context.evaluateScript("promiseError")?.toString(), "Tab 0 does not exist")
        XCTAssertEqual(context.evaluateScript("valid")?.toInt32(), 42)
        XCTAssertEqual(context.evaluateScript("invalid")?.toString(), "Invalid type")
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        XCTAssertTrue(context.evaluateScript("chrome.tabs.get===first")!.toBool())
    }

    func testRequestOriginRequiresMatchingDocumentAndGrantedSite() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var globalThis=this, permitted=true, documentID='same', rows=[];
        function URL(){this.protocol='https:';this.hostname='example.test';this.origin='https://example.test:8443';}
        const event={
          callback:null,
          addListener(callback,filter,extra){this.callback=callback;this.extra=extra;},
          removeListener(callback){if(this.callback===callback)this.callback=null;},
          hasListener(callback){return this.callback===callback;}
        };
        var chrome={
          webRequest:{onResponseStarted:event},
          webNavigation:{getFrame:async()=>({documentId:documentID,url:'https://example.test:8443/one'})},
          permissions:{contains:async({origins})=>permitted&&origins[0]==='https://example.test/*'}
        };
        const listener=details=>rows.push(details);
        const request={documentId:'same',tabId:2,frameId:0,type:'media',requestHeaders:[
          {name:'Sec-Fetch-Site',value:'same-origin'},{name:'Connection',value:'Keep-Alive'},
          {name:'X-Playback-Session-Id',value:'internal'},{name:'Range',value:'bytes=0-1'}
        ]};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        context.evaluateScript("""
        event.addListener(listener,{urls:['<all_urls>']},['responseHeaders','extraHeaders']);
        const registered=event.hasListener(listener);
        event.callback(request);
        """)
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("registered")!.toBool())
        XCTAssertEqual(context.evaluateScript("event.extra.join(',')")?.toString(), "responseHeaders")
        XCTAssertEqual(context.evaluateScript("rows[0].initiator")?.toString(), "https://example.test:8443")
        XCTAssertEqual(context.evaluateScript("rows[0].requestHeaders.map(header=>header.name).join(',')")?.toString(), "Range")
        XCTAssertEqual(context.evaluateScript("request.requestHeaders.length")?.toInt32(), 4)
        context.evaluateScript("permitted=false;event.callback(request);")
        XCTAssertTrue(context.evaluateScript("!('initiator' in rows[1])")!.toBool())
        context.evaluateScript("permitted=true;documentID='stale';event.callback(request);")
        XCTAssertTrue(context.evaluateScript("!('initiator' in rows[2])")!.toBool())
        context.evaluateScript("""
        documentID='same';
        event.callback({...request,initiator:'null'});
        event.callback(request);
        event.removeListener(listener);
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("rows[3].initiator")?.toString(), "null")
        XCTAssertEqual(context.evaluateScript("rows.length")?.toInt32(), 4)
        XCTAssertFalse(context.evaluateScript("event.hasListener(listener)")!.toBool())
    }

    func testWebRequestRetainsNativeFiltersWhenAWebSocketSchemeIsRejected() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const registrations=new Map(), listener=()=>{};
        const event={
          addListener(callback,filter,extras){
            if(filter.urls.includes('ws://*/*'))throw Error('Invalid pattern: ws://*/*');
            if(filter.urls.includes('invalid'))throw Error('Invalid pattern: invalid');
            registrations.set(callback,{urls:filter.urls,types:filter.types,extras});
          },
          hasListener:callback=>registrations.has(callback),
          removeListener:callback=>registrations.delete(callback)
        };
        var chrome={webRequest:{onCompleted:event}};
        const nativeTypes={WEBTRANSPORT:'webtransport'};
        var browser={webRequest:{ResourceType:nativeTypes}};
        """)
        let source = WebExtensionPackagePreparer.nativeBindingsSourceForTesting
        context.evaluateScript(source)
        context.evaluateScript(source)
        context.evaluateScript("""
        const urls=['https://example.test/*','ws://*/*','wss://*/*'];
        event.addListener(listener,{urls,types:['xmlhttprequest']},['responseHeaders']);
        const registered=event.hasListener(listener), subscription=registrations.get(listener);
        event.removeListener(listener);
        let onlyWebSocketRejected=false, invalidRejected=false;
        try{event.addListener(listener,{urls:['ws://*/*']});}catch(_){onlyWebSocketRejected=true;}
        try{event.addListener(listener,{urls:['https://example.test/*','invalid']});}catch(_){invalidRejected=true;}
        """)
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.evaluateScript("registered && !event.hasListener(listener) && onlyWebSocketRejected && invalidRejected")?.toBool() == true)
        XCTAssertTrue(context.evaluateScript("chrome.webRequest.ResourceType.XMLHTTPREQUEST==='xmlhttprequest' && chrome.webRequest.ResourceType.WEBTRANSPORT===undefined && browser.webRequest.ResourceType===nativeTypes")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("urls.length")?.toInt32(), 3)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(subscription)")?.toString(),
                       #"{"urls":["https://example.test/*","wss://*/*"],"types":["xmlhttprequest"],"extras":["responseHeaders"]}"#)
    }

    func testSessionRulesKeepCanonicalHeadersAndIgnoreInvalidPolicyValue() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var globalThis=this, applied;
        var chrome={declarativeNetRequest:{updateSessionRules(options){applied=options;return Promise.resolve();}}};
        const remove=header=>({header,operation:'remove'});
        const frameHeader={header:'Referer',operation:'set',value:'https://example.test/'};
        const cors={header:'Access-Control-Allow-Origin',operation:'set',value:'https://example.test'};
        const replay={id:1,action:{type:'modifyHeaders',requestHeaders:[frameHeader,remove('referrer'),remove('cookie')],
          responseHeaders:[cors,remove('Same-Origin'),remove('Cross-Origin-Resource-Policy')]}};
        const customRule={id:2,action:{type:'modifyHeaders',requestHeaders:[remove('referrer')]}};
        const malformedRule={id:3,action:{type:'modifyHeaders',responseHeaders:[remove('same-origin')]}};
        const update={addRules:[replay,customRule,malformedRule],removeRuleIds:[4]};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.nativeBindingsSourceForTesting)
        context.evaluateScript("chrome.declarativeNetRequest.updateSessionRules(update);")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("applied.addRules[0].action.requestHeaders.map(h=>h.header).join(',')")?.toString(), "Referer,cookie")
        XCTAssertEqual(context.evaluateScript("applied.addRules[0].action.responseHeaders.map(h=>h.header).join(',')")?.toString(), "Access-Control-Allow-Origin,Cross-Origin-Resource-Policy")
        XCTAssertTrue(context.evaluateScript("applied.addRules[0].action.requestHeaders[0]===frameHeader")!.toBool())
        XCTAssertTrue(context.evaluateScript("applied.addRules[1]===customRule && applied.addRules[2]===malformedRule && applied.removeRuleIds===update.removeRuleIds")!.toBool())
        XCTAssertEqual(context.evaluateScript("replay.action.requestHeaders.length")?.toInt32(), 3)
        XCTAssertEqual(context.evaluateScript("replay.action.responseHeaders.length")?.toInt32(), 3)
    }

    func testBadgeTextColorRoundTripsThroughTheNativeExtensionHost() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = try package(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = source.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest.removeValue(forKey: "permissions")
        manifest.removeValue(forKey: "background")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let program = "globalThis.setFixtureBadgeColor = options => chrome.action.setBadgeTextColor(options);"
        try Data(program.utf8).write(to: source.appendingPathComponent("badge.js"))
        try Data("<!doctype html><body>Badge fixture<script src='badge.js'></script></body>".utf8)
            .write(to: source.appendingPathComponent("popup.html"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("installed"))
        let record = try await service.installWebExtension(from: source)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first {
            $0.uniqueIdentifier == record.id.uuidString
        })
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600),
                             configuration: try XCTUnwrap(context.webViewConfiguration))
        let url = context.baseURL.appendingPathComponent("popup.html")
        view.load(URLRequest(url: url))
        try await waitForAuditPage(view, at: url)
        let colors = try await runAuditJavaScript("""
            await setFixtureBadgeColor({color:[31,74,202,255]});
            const custom=await chrome.action.getBadgeTextColor();
            await new Promise(resolve=>chrome.action.setBadgeTextColor({color:'white'},resolve));
            return {custom,white:await chrome.action.getBadgeTextColor()};
            """, on: view) as? [String: [Int]]
        XCTAssertEqual(colors?["custom"], [31, 74, 202, 255])
        XCTAssertEqual(colors?["white"], [255, 255, 255, 255])
    }

    func testStaticClassicBackgroundPreservesProgramAndPermissionsWithoutVersionSpecificEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), script = "/* Initial imports */\nif(typeof Settings === 'undefined'){importScripts('/js/library.js');}\nvar result=Settings.answer;"
        try FileManager.default.createDirectory(at: source.appendingPathComponent("js"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: source.appendingPathComponent("js/worker.js"))
        try Data("var Settings={answer:42};".utf8).write(to: source.appendingPathComponent("js/library.js"))
        let manifest: [String: Any] = ["manifest_version":3,"name":"Generic background fixture","version":"1.0", "permissions":["storage"], "background":["service_worker":"js/worker.js"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("installed"), withIntermediateDirectories: true)
        let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifestURL = prepared.appendingPathComponent("manifest.json")
        let first = try Data(contentsOf: manifestURL)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let background = try XCTUnwrap(result["background"] as? [String: Any])
        XCTAssertNil(background["service_worker"])
        XCTAssertEqual((background["scripts"] as? [String])?.suffix(2), ["js/library.js","js/worker.js"])
        XCTAssertEqual(result["permissions"] as? [String], ["storage"], "Basic bindings must not add nativeMessaging access")
        XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("js/worker.js"), encoding: .utf8), script)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("js/worker.js"), encoding: .utf8), script)
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        XCTAssertEqual(try Data(contentsOf: manifestURL), first)
    }

    func testDesktopHooksAreIsolatedToDeclaredCompatibleBackgrounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let manifestURL = source.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["permissions"] = ["debugger", "declarativeNetRequest"]
        manifest["host_permissions"] = ["https://example.test/*"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let worker = source.appendingPathComponent("background/worker.js")
        let publisher = "chrome.debugger.onDetach.addListener(function(){}); globalThis.answer=chrome.declarativeNetRequest.ResourceType.MAIN_FRAME;"
        try Data(publisher.utf8).write(to: worker)
        let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let resultURL = prepared.appendingPathComponent("manifest.json")
        let first = try Data(contentsOf: resultURL)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(result["permissions"] as? [String], ["debugger", "declarativeNetRequest", "declarativeNetRequestWithHostAccess"])
        XCTAssertEqual(result["host_permissions"] as? [String], ["https://example.test/*"])
        let scripts = try XCTUnwrap((result["background"] as? [String: Any])?["scripts"] as? [String])
        XCTAssertEqual(scripts.last, "background/worker.js")
        XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("background/worker.js"), encoding: .utf8), publisher)
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("var chrome={declarativeNetRequest:{},runtime:{}};var browser={debugger:{native:true}};")
        js.evaluateScript(try String(contentsOf: prepared.appendingPathComponent(scripts[0]), encoding: .utf8))
        XCTAssertEqual(js.evaluateScript("typeof chrome.debugger")?.toString(), "undefined")
        for script in scripts.dropFirst() {
            js.evaluateScript(try String(contentsOf: prepared.appendingPathComponent(script), encoding: .utf8))
        }
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("answer")?.toString(), "main_frame")
        XCTAssertTrue(js.evaluateScript("chrome.debugger.onDetach.hasListeners() && browser.debugger.native")?.toBool() == true)
        XCTAssertTrue(js.evaluateScript("(()=>{try{chrome.debugger.attach({},'1.3',()=>{});return false}catch(e){return e.message.includes('unavailable')}})()")?.toBool() == true)
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        XCTAssertEqual(try Data(contentsOf: resultURL), first)

        try Data("self.addEventListener('push',event=>event.waitUntil(Promise.resolve()));".utf8).write(to: worker)
        let native = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let nativeManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: native.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertNotNil((nativeManifest["background"] as? [String: Any])?["service_worker"])
    }

    private func context(grants: [String], storedValues: [String: String] = [:]) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window = globalThis;
        var location = {href:'https://example.com/'};
        var console = {error:function(){},log:function(){}};
        var __reject = false;
        var __apiReplies = [];
        var lifecycleHandlers = [];
        function addEventListener(type, callback, options) {
          if(type === 'pagehide') lifecycleHandlers.push({callback:callback, once:options && options.once});
        }
        function hideDocument() {
          var handlers=lifecycleHandlers;
          lifecycleHandlers=handlers.filter(function(handler){return !handler.once;});
          handlers.forEach(function(handler){handler.callback();});
        }
        var webkit = {messageHandlers:{
          souloUserScriptAPI:{postMessage:function(payload){
            if (__reject) return Promise.reject(new Error('Storage rejected'));
            return Promise.resolve(true);
          }},
          souloUserScriptXHR:{postMessage:function(payload){
            if (__reject) return Promise.reject(new Error('Network rejected'));
            return Promise.resolve({status:200,responseText:'{"answer":42}'});
          }} }};
        """)
        XCTAssertNil(context.exception, "The JavaScript fixture must parse before testing the runtime")
        let script = UserScriptRecord(name: "Audit", source: "", grants: grants, storedValues: storedValues)
        context.evaluateScript(UserScriptRuntime.compatibilityBootstrap(bridgeToken: "test", script: script))
        XCTAssertNil(context.exception)
        return context
    }

    func testModernXMLHTTPReturnsResponsePromiseWithAbort() throws {
        let context = try context(grants: ["GM.xmlHttpRequest"])
        context.evaluateScript("var request = GM.xmlHttpRequest({url:'https://example.com/api',responseType:'json'}); var result; Promise.resolve(request).then(function(value){result=value;});")
        XCTAssertEqual(context.evaluateScript("typeof request.then")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("typeof request.abort")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("result && result.response && result.response.answer")?.toInt32(), 42)
    }

    func testDownloadAbortCancelsNativeRequestAndSettlesModernPromiseOnce() throws {
        let context = try context(grants: ["GM.download"])
        context.evaluateScript("""
        function URL(value) { this.href = String(value); }
        var messages=[], completeDownload, loaded=0, aborted=0, errors=0, failure;
        webkit.messageHandlers.souloUserScriptAPI.postMessage=function(payload){
          messages.push(payload);
          return payload.action==='download' ? new Promise(function(resolve){completeDownload=resolve;}) : Promise.resolve(true);
        };
        var pending=GM.download({url:'https://example.com/file',onload:function(){loaded++;},
          onabort:function(){aborted++;},onerror:function(){errors++;}});
        pending.catch(function(error){failure=error;});
        pending.abort(); pending.abort(); completeDownload({success:true});
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("typeof pending.then")?.toString(), "function")
        XCTAssertEqual(context.evaluateScript("messages.length")?.toInt32(), 2)
        XCTAssertEqual(context.evaluateScript("messages[1].action")?.toString(), "abortDownload")
        XCTAssertTrue(context.evaluateScript("messages[0].__souloDownloadID === messages[1].__souloDownloadID")!.toBool())
        XCTAssertEqual(context.evaluateScript("failure.error")?.toString(), "aborted")
        XCTAssertEqual(context.evaluateScript("[loaded,aborted,errors].join(',')")?.toString(), "0,1,1")
    }

    func testDownloadRegistryHandlesAbortBeforeCreationAndKeepsRequestsSeparate() {
        let requests = UserScriptDownloadRequests()
        let first = UUID(), second = UUID()
        XCTAssertTrue(requests.begin("script-a:request"))
        XCTAssertNil(requests.cancel("script-a:request"))
        XCTAssertFalse(requests.attach(first, to: "script-a:request"))
        XCTAssertFalse(requests.begin("script-a:request"), "A canceled action still owns its key until it finishes")
        XCTAssertTrue(requests.begin("script-b:request"))
        XCTAssertTrue(requests.attach(second, to: "script-b:request"))
        XCTAssertEqual(requests.cancel("script-b:request"), second)
        XCTAssertNil(requests.cancel("script-b:request"))
        requests.finish("script-a:request")
        XCTAssertTrue(requests.begin("script-a:request"))
        XCTAssertTrue(requests.attach(first, to: "script-a:request"))
        XCTAssertEqual(requests.finish("script-a:request"), first)
    }

    func testDownloadCanBeCanceledBeforeCreatingItsTransport() async throws {
        let manager = DownloadManagerService.shared
        var itemID: UUID?
        defer { if let item = manager.downloads.first(where: { $0.id == itemID }) { manager.delete(item) } }
        do {
            _ = try await WebResourceDownloadService.shared.download(
                URL(string: "https://example.com/not-requested")!, onStart: { id in
                    itemID = id
                    manager.markCanceled(id: id)
                }
            )
            XCTFail("A canceled download must not reach the transport")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(manager.downloads.first(where: { $0.id == itemID })?.status, .canceled)
    }

    func testRelativeResourceUsesScriptOriginAndKeepsConnectPermissions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditResourceProtocol.self]
        let script = UserScriptRecord(name: "Resources", source: "", connectDomains: ["scripts.example"],
            resources: ["style": "assets/style.css"], sourceURL: "https://scripts.example/tools/sample.user.js")
        let response = try await UserScriptHTTPBridge.resourceResponse(named: "style", script: script,
            pageURL: URL(string: "https://page.example/article/"), configuration: configuration)
        XCTAssertEqual(response["finalURL"] as? String, "https://scripts.example/tools/assets/style.css")
        XCTAssertEqual(response["responseText"] as? String, "body { color: purple; }")
        var denied = script; denied.connectDomains = ["page.example"]
        do {
            _ = try await UserScriptHTTPBridge.resourceResponse(named: "style", script: denied,
                pageURL: URL(string: "https://page.example/article/"), configuration: configuration)
            XCTFail("Resource resolution must not broaden @connect permissions")
        } catch { XCTAssertEqual((error as? URLError)?.code, .unsupportedURL) }
        var local = script; local.sourceURL = nil
        do {
            _ = try await UserScriptHTTPBridge.resourceResponse(named: "style", script: local,
                pageURL: URL(string: "https://scripts.example/"), configuration: configuration)
            XCTFail("A relative resource without a script origin must not use the visited page")
        } catch { XCTAssertEqual((error as? URLError)?.code, .unsupportedURL) }
    }

    func testMissingResourceDoesNotReturnAnHTTPErrorPageAsScriptData() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditResourceProtocol.self]
        let script = UserScriptRecord(name: "Missing resource", source: "", connectDomains: ["scripts.example"],
            resources: ["style": "https://scripts.example/missing.css"])
        do {
            _ = try await UserScriptHTTPBridge.resourceResponse(named: "style", script: script,
                pageURL: URL(string: "https://page.example/"), configuration: configuration)
            XCTFail("HTTP errors must reject the resource API")
        } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
    }

    func testModernXMLHTTPRejectsAndAbortIsForwardedToTheNativeTransport() throws {
        let context = try context(grants: ["GM.xmlHttpRequest"])
        context.evaluateScript("__reject=true; var failure; GM.xmlHttpRequest({url:'https://example.com/'}).catch(function(event){failure=event;});")
        XCTAssertEqual(context.evaluateScript("failure.type")?.toString(), "error")
        context.evaluateScript("""
        var messages=[];
        webkit.messageHandlers.souloUserScriptXHR.postMessage=function(payload){
          messages.push(payload);
          return payload.action==='abort' ? Promise.resolve(true) : new Promise(function(){});
        };
        var aborted; var pending=GM.xmlHttpRequest({url:'https://example.com/'});
        pending.catch(function(event){aborted=event.type;}); pending.abort();
        """)
        XCTAssertEqual(context.evaluateScript("aborted")?.toString(), "abort")
        XCTAssertEqual(context.evaluateScript("messages[1].action")?.toString(), "abort")
        XCTAssertTrue(context.evaluateScript("messages[0].__souloRequestID === messages[1].__souloRequestID")!.toBool())
    }

    func testRuntimeDoesNotReserveCommonScriptVariableNames() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var window=globalThis; window.location={href:'https://example.com/'}; var document={readyState:'complete'}; var console={error:function(){}};")
        let record = UserScriptRecord(name: "Names", source: "const request=42; const base64Blob='fixture'; window.__answer=request;", grants: ["none"])
        context.evaluateScript(UserScriptRuntime.wrappedSource(for: record))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("window.__answer")?.toInt32(), 42)
    }

    func testWildcardScriptsCannotRunOnExtensionAndLocalPages() throws {
        let script = UserScriptRecord(name: "Scope", source: "window.__ran=true;", matchPatterns: ["*"], grants: ["none"])
        for address in ["webkit-extension://fixture/popup.html", "file:///tmp/private.html", "about:blank", "data:text/html,fixture", "https://example.com/"] {
            let expected = address.hasPrefix("https://")
            XCTAssertEqual(UserScriptURLMatcher.matches(url: URL(string: address)!, patterns: ["*"]), expected)
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("var window=globalThis; var location={href:" + String(data: try JSONSerialization.data(withJSONObject: address, options: [.fragmentsAllowed]), encoding: .utf8)! + "}; var document={readyState:'complete'}; var console={error:function(){}};")
            context.evaluateScript(UserScriptRuntime.wrappedSource(for: script))
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("window.__ran===true")?.toBool(), expected)
        }
    }

    func testRejectedSingleAndBatchStorageWritesRestorePreviousValues() throws {
        let context = try context(grants: ["GM_getValue", "GM_setValue", "GM_setValues", "GM_deleteValues"], storedValues: ["answer": #"{"value":42}"#])
        context.evaluateScript("__reject=true; GM.setValue('answer',99).catch(function(){});")
        XCTAssertEqual(context.evaluateScript("GM_getValue('answer')")?.toInt32(), 42)
        context.evaluateScript("GM.setValues({answer:100,newKey:1}).catch(function(){});")
        XCTAssertEqual(context.evaluateScript("GM_getValue('answer')")?.toInt32(), 42)
        XCTAssertTrue(context.evaluateScript("GM_getValue('newKey')")!.isUndefined)
        context.evaluateScript("GM.deleteValues(['answer']).catch(function(){});")
        XCTAssertEqual(context.evaluateScript("GM_getValue('answer')")?.toInt32(), 42)
    }

    func testStorageSupportsPrototypeNamedKeysWithoutChangingOtherValues() throws {
        let context = try context(grants: ["GM_getValue", "GM_setValue", "GM_getValues"], storedValues: ["__proto__": #"{"value":"saved"}"#])
        XCTAssertEqual(context.evaluateScript("GM_getValue('__proto__')")?.toString(), "saved")
        context.evaluateScript("GM_setValue('__proto__','updated');")
        XCTAssertEqual(context.evaluateScript("GM_getValues(['__proto__'])['__proto__']")?.toString(), "updated")
    }

    func testFailedEarlierWriteCannotOverwriteALaterSuccessfulWrite() throws {
        let context = try context(grants: ["GM_setValue", "GM_getValue"])
        context.evaluateScript("""
        webkit.messageHandlers.souloUserScriptAPI.postMessage=function(){
          return new Promise(function(resolve,reject){__apiReplies.push({resolve:resolve,reject:reject});});
        };
        GM.setValue('answer',1).catch(function(){});
        GM.setValue('answer',2).catch(function(){});
        __apiReplies[1].resolve(true);
        """)
        context.evaluateScript("__apiReplies[0].reject(new Error('Rejected'));")
        XCTAssertEqual(context.evaluateScript("GM_getValue('answer')")?.toInt32(), 2)
    }

    func testNativeMessagingPromiseWaitsForCallbackOnlyImplementations() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var chrome={runtime:{sendNativeMessage:function(host,payload,callback){
          Promise.resolve().then(function(){callback({id:'native-notification'});});
        }}};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        context.evaluateScript("var result; chrome.notifications.create({title:'Fixture'}).then(function(value){result=value;});")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("result")?.toString(), "native-notification")
    }

    func testNativeMessagingCallbackErrorsRejectInsteadOfReportingSuccess() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var chrome={runtime:{sendNativeMessage:function(host,payload,callback){
          chrome.runtime.lastError={message:'Permission denied'};
          callback(undefined); delete chrome.runtime.lastError;
        }}};
        """)
        context.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        context.evaluateScript("var rejected=false, value; chrome.notifications.create({title:'Fixture'}).then(function(v){value=v;},function(error){rejected=true;value=error.message;});")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("rejected")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("value")?.toString(), "Permission denied")
    }

    func testTabDataIsRemovedOnCloseAndUninstall() throws {
        let key = "tab-data-\(UUID().uuidString)"
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        let manager = TabManager(storageKey: key)
        defer { manager.saveToDisk(); UserDefaults.standard.removeObject(forKey: key) }
        let tab = try XCTUnwrap(manager.activeTab)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root)
        let script = try service.saveUserScript(id: nil, fallbackName: "Tab data", source: "// fixture", explicitPatterns: nil, injectionTime: nil)
        try UserScriptTabStore.shared.save(#"{"answer":42}"#, scriptID: script.id, tabID: tab.webViewModel.userScriptTabID)
        manager.closeTab(id: tab.id)
        XCTAssertTrue(UserScriptTabStore.shared.allValues(scriptID: script.id).isEmpty)
        let next = try XCTUnwrap(manager.activeTab)
        XCTAssertNotEqual(tab.webViewModel.userScriptTabID, next.webViewModel.userScriptTabID)
        try UserScriptTabStore.shared.save(#"{"answer":43}"#, scriptID: script.id, tabID: next.webViewModel.userScriptTabID)
        service.deleteUserScript(script.id)
        XCTAssertTrue(UserScriptTabStore.shared.allValues(scriptID: script.id).isEmpty)
    }

    func testExistingBackgroundWrapperMigrationIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        // This regression covers migration of native worker wrappers. A worker
        // without imports retains that path rather than becoming an event page.
        try Data("globalThis.__workerAnswer=42;".utf8).write(to: source.appendingPathComponent("background/worker.js"))
        let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifestURL = prepared.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["background"] = ["service_worker":"__soulo_webextension_background_v3.js"]
        try Data(#"importScripts("__soulo_webextension_compatibility.js", "background/worker.js");"#.utf8)
            .write(to: prepared.appendingPathComponent("__soulo_webextension_background_v3.js"))
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        let first = try Data(contentsOf: manifestURL)
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        XCTAssertEqual(first, try Data(contentsOf: manifestURL))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual((result["background"] as? [String: Any])?["service_worker"] as? String, "background/__soulo_webextension_background_v4.js")
    }

    func testGMInfoReportsTheInstalledApplicationVersion() throws {
        let context = try context(grants: ["none"])
        XCTAssertEqual(context.evaluateScript("GM_info.version")?.toString(), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    func testScriptNetworkAndDownloadScopeRejectLocalAddressAliases() throws {
        let script = UserScriptRecord(name: "Network audit", source: "", connectDomains: ["*"])
        let policy = UserScriptDownloadPolicy(script: script, pageURL: URL(string: "https://example.com/"))
        for raw in ["http://2130706433/", "http://0x7f000001/", "http://127.1/", "http://[::ffff:192.168.1.1]/", "http://[::ffff:a00:1]/", "http://sub.localhost/", "http://[::]/"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(UserScriptHTTPBridge.isAllowedTarget(url, script: script, pageURL: nil), raw)
            XCTAssertFalse(policy.allows(url), raw)
        }
        XCTAssertTrue(policy.allows(URL(string: "https://public.example/file")!))
        let scoped = UserScriptDownloadPolicy(script: UserScriptRecord(name: "Scoped", source: "", connectDomains: ["allowed.example"]), pageURL: nil)
        XCTAssertTrue(scoped.allows(URL(string: "https://cdn.allowed.example/file")!))
        XCTAssertFalse(scoped.allows(URL(string: "https://other.example/file")!))
        XCTAssertEqual(try JSONDecoder().decode(UserScriptDownloadPolicy.self, from: JSONEncoder().encode(scoped)), scoped)
    }

    func testOversizeStorePackagesAreCancelledWhileDownloading() {
        let delegate = WebExtensionStoreSessionDelegate(store: .direct)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://store.example/fixture.zip")!)
        delegate.urlSession(session, downloadTask: task, didWriteData: 4096, totalBytesWritten: 4096, totalBytesExpectedToWrite: WebExtensionStoreInstallService.maximumPackageSize + 1)
        XCTAssertTrue(delegate.exceededSizeLimit)
        XCTAssertNotEqual(task.state, .suspended)
    }

    private func package(root: URL, worker: String = "background/worker.js", popup: String = "popup.html") throws -> URL {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("background"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("installed"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version":3,"name":"Audit fixture","version":"1.0","permissions":["notifications"],"background":["service_worker":worker],"action":["default_popup":popup]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        try Data("importScripts('./helper.js'); globalThis.__workerAnswer=helperAnswer;".utf8).write(to: source.appendingPathComponent("background/worker.js"))
        try Data("var helperAnswer=42;".utf8).write(to: source.appendingPathComponent("background/helper.js"))
        try Data("<html><head></head><body>Popup</body></html>".utf8).write(to: source.appendingPathComponent("popup.html"))
        return source
    }

    func testPreparedClassicWorkerKeepsItsOriginalRelativeImportDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        try Data(#"'use strict'; importScripts(`./helper.js`); importScripts('/extra.js'); globalThis.__workerAnswer=helperAnswer+extra;"#.utf8)
            .write(to: source.appendingPathComponent("background/worker.js"))
        try Data("var extra=1;".utf8).write(to: source.appendingPathComponent("extra.js"))
        let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: prepared.appendingPathComponent("manifest.json"))) as? [String: Any])
        let scripts = try XCTUnwrap((manifest["background"] as? [String: Any])?["scripts"] as? [String])
        XCTAssertEqual(Array(scripts.suffix(3)), ["background/helper.js", "extra.js", "background/worker.js"])
        let context = try XCTUnwrap(JSContext())
        let resolve: @convention(block) (String, String) -> String = { path, base in
            URL(string: path, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? ""
        }
        context.setObject(resolve, forKeyedSubscript: "__resolve" as NSString)
        context.evaluateScript("function URL(path,base){this.href=__resolve(path,base)};var chrome={runtime:{getURL:path=>'webkit-extension://fixture/'+path}};var console={error:function(){}};")
        for path in scripts { context.evaluateScript(try String(contentsOf: prepared.appendingPathComponent(path), encoding: .utf8)) }
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("globalThis.__workerAnswer")?.toInt32(), 43)
    }

    func testClassicWorkerWithDynamicImportsOrWorkerEventsKeepsItsWorkerEntry() async throws {
        for source in [
            #"importScripts('./helper.js'); globalThis['importScripts'](nextScript);"#,
            #"importScripts('./helper.js'); self.addEventListener('fetch', handler);"#
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let package = try package(root: root)
            try Data(source.utf8).write(to: package.appendingPathComponent("background/worker.js"))
            let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: package, in: root.appendingPathComponent("installed"))
            let data = try Data(contentsOf: prepared.appendingPathComponent("manifest.json"))
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let background = try XCTUnwrap(manifest["background"] as? [String: Any])
            XCTAssertNotNil(background["service_worker"])
            XCTAssertNil(background["scripts"])
        }
    }

    func testGuardedClassicImportsCanRetryAsAnEventPageWithoutChangingPublisherFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let worker = """
        'use strict';
        console.log('started ' + new Date());
        try { if (!globalThis.helperLoaded) { importScripts('helper.js'); } }
        catch (error) { console.error('Unable to load: ' + error); }
        let notice;
        function notify() {
          if (globalThis.registration) {
            return registration.showNotification('Ready');
          } else {
            notice = new Notification('Ready');
            notice.onclick = () => {};
          }
        }
        globalThis.addEventListener('notificationclick', () => {});
        globalThis.answer = helperAnswer;
        """
        let helper = "var helperLoaded = true; var helperAnswer = 42; function pageURL() { return location.href; }"
        try Data(worker.utf8).write(to: source.appendingPathComponent("background/worker.js"))
        try Data(helper.utf8).write(to: source.appendingPathComponent("background/helper.js"))
        let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifestURL = prepared.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        XCTAssertNotNil((original["background"] as? [String: Any])?["service_worker"])
        let backup = try await WebExtensionPackagePreparer.prepareClassicBackgroundRetry(in: prepared)
        XCTAssertEqual(backup, before)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let scripts = try XCTUnwrap((updated["background"] as? [String: Any])?["scripts"] as? [String])
        XCTAssertEqual(Array(scripts.suffix(2)), ["background/helper.js", "background/worker.js"])
        XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("background/worker.js"), encoding: .utf8), worker)
        XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("background/helper.js"), encoding: .utf8), helper)

        try before.write(to: manifestURL)
        for unsupported in [worker.replacingOccurrences(of: "notice.onclick = () => {};", with: ""),
                            worker + "\nself.addEventListener('fetch', () => {});",
                            worker.replacingOccurrences(of: "console.error('Unable to load: ' + error);", with: "throw error;")] {
            try Data(unsupported.utf8).write(to: prepared.appendingPathComponent("background/worker.js"))
            let rejected = try await WebExtensionPackagePreparer.prepareClassicBackgroundRetry(in: prepared)
            XCTAssertNil(rejected)
            XCTAssertEqual(try Data(contentsOf: manifestURL), before)
        }
    }

    func testClassicBackgroundRetryPreservesPublisherProgramAndWorkerEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let program = "chrome.runtime.onMessage.addListener((_message, _sender, reply) => reply(42));"
        try Data(program.utf8).write(to: source.appendingPathComponent("background/worker.js"))
        let sourceManifest = source.appendingPathComponent("manifest.json")
        var requested = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceManifest)) as? [String: Any])
        requested["optional_permissions"] = ["downloads"]
        try JSONSerialization.data(withJSONObject: requested).write(to: sourceManifest)
        let package = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifest = package.appendingPathComponent("manifest.json")
        let worker = package.appendingPathComponent("background/worker.js")
        let originalManifest = try Data(contentsOf: manifest)
        let prepared = try XCTUnwrap(JSONSerialization.jsonObject(with: originalManifest) as? [String: Any])
        let preparedBackground = try XCTUnwrap(prepared["background"] as? [String: Any])
        XCTAssertEqual(preparedBackground["service_worker"] as? String, "background/__soulo_webextension_background_v4.js")
        let folder = worker.deletingLastPathComponent()
        let wrapper = folder.appendingPathComponent("__soulo_webextension_background_v4.js")
        let current = try String(contentsOf: wrapper, encoding: .utf8)
        XCTAssertTrue(current.contains("../" + WebExtensionBlobScript.backgroundFilename))
        XCTAssertTrue(current.contains("./worker.js"))
        try Data(#"importScripts("../__soulo_blob_background.js","./worker.js");"#.utf8)
            .write(to: folder.appendingPathComponent("__soulo_blob_worker.js"))
        try Data(#"importScripts("../__soulo_webextension_compatibility.js","./__soulo_blob_worker.js");"#.utf8)
            .write(to: wrapper)
        let backup = try await WebExtensionPackagePreparer.prepareClassicBackgroundRetry(in: package)
        XCTAssertEqual(backup, originalManifest)
        let converted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let background = try XCTUnwrap(converted["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], ["background/worker.js"])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertEqual(try String(contentsOf: worker, encoding: .utf8), program)
        try originalManifest.write(to: manifest)
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: package)
        XCTAssertEqual(try String(contentsOf: wrapper, encoding: .utf8), current)
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: package)
        XCTAssertEqual(try String(contentsOf: wrapper, encoding: .utf8), current)
        let repairedManifest = try Data(contentsOf: manifest)
        try Data("self.addEventListener('push', event => event.waitUntil(Promise.resolve()));".utf8).write(to: worker)
        let unsupported = try await WebExtensionPackagePreparer.prepareClassicBackgroundRetry(in: package)
        XCTAssertNil(unsupported)
        XCTAssertEqual(try Data(contentsOf: manifest), repairedManifest)
    }

    func testManifestResourceTraversalCannotModifyFilesOutsideThePackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root, popup: "../outside.html")
        let install = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let outside = install.appendingPathComponent("outside.html")
        let original = "<html><head></head><body>Unrelated file</body></html>"
        try Data(original.utf8).write(to: outside)
        await assertExtensionPreparationThrows { try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: install) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), original)
    }

    func testDirectoryPackagesRejectSymbolicLinksOutsideTheirResourceRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let outside = root.appendingPathComponent("outside.html")
        let original = "<html><head></head><body>Outside</body></html>"
        try Data(original.utf8).write(to: outside)
        try FileManager.default.removeItem(at: source.appendingPathComponent("popup.html"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("popup.html"), withDestinationURL: outside)
        await assertExtensionPreparationThrows { try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed")) }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), original)
    }

    func testPrivateTabsAreNotExposedThroughTheNativeExtensionWindow() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        let key = "extension-privacy-\(UUID().uuidString)"
        defaults.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        let manager = TabManager(storageKey: key)
        defer {
            defaults.set(previous, forKey: "is_incognito")
            manager.synchronizePrivacyMode()
            manager.saveToDisk()
            defaults.removeObject(forKey: key)
        }
        let runtime = NativeWebExtensionRuntime.shared
        runtime.attach(tabManager: manager)
        let resource = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resource) }
        try Data(#"{"manifest_version":3,"name":"Privacy audit","version":"1.0"}"#.utf8).write(to: resource.appendingPathComponent("manifest.json"))
        let object = try await WKWebExtension(resourceBaseURL: resource)
        let context = WKWebExtensionContext(for: object)
        let window = try XCTUnwrap(runtime.webExtensionController(runtime.controller, openWindowsFor: context).first)
        XCTAssertFalse(window.tabs?(for: context).isEmpty ?? true)
        defaults.set(true, forKey: "is_incognito")
        manager.synchronizePrivacyMode()
        manager.activeWebViewModel?.loadURL(URL(string: "https://private.example/secret")!)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(window.tabs?(for: context).isEmpty ?? true)
    }

    func testConcurrentNativeLoadsUseOneContextAndUnloadCancelsPendingLoads() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Concurrent load","version":"1.0"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let runtime = NativeWebExtensionRuntime.shared
        let id = UUID()
        defer { runtime.unload(id: id) }
        async let first = runtime.load(id: id, resourceURL: root)
        async let second = runtime.load(id: id, resourceURL: root)
        let (a,b) = try await (first,second)
        XCTAssertEqual(a.name, b.name)
        XCTAssertEqual(runtime.controller.extensionContexts.filter { $0.uniqueIdentifier == id.uuidString }.count, 1)
        runtime.unload(id: id)
        XCTAssertTrue(runtime.controller.extensionContexts.filter { $0.uniqueIdentifier == id.uuidString }.isEmpty)
        var started = false
        let pending = Task { started = true; return try await runtime.load(id: id, resourceURL: root) }
        while !started { await Task.yield() }
        runtime.unload(id: id)
        _ = try? await pending.value
        XCTAssertTrue(runtime.controller.extensionContexts.filter { $0.uniqueIdentifier == id.uuidString }.isEmpty)
    }

    func testNativeCompatibilityRejectsUndeclaredPermissions() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Permission fixture","version":"1.0","permissions":["nativeMessaging"]}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let object = try await WKWebExtension(resourceBaseURL: root)
        let context = WKWebExtensionContext(for: object)
        let host = WebExtensionCompatibilityHost()
        for api in ["notifications", "audio", "downloads"] {
            var failure: Error?
            var replied = false
            XCTAssertTrue(host.handle(message: ["souloCompatibility":1,"api":api,"operation":"stop"], applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier, context: context, resourceURL: root) { _, error in replied=true; failure=error })
            XCTAssertTrue(replied)
            XCTAssertNotNil(failure)
            XCTAssertTrue(failure?.localizedDescription.contains("permission") == true)
        }
    }

    func testCaptureHandoffCanOnlyOpenItsOwnExtensionBlobs() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Capture permission fixture", "version": "8.11",
            "permissions": ["nativeMessaging"], WebExtensionGoFullPageAdapter.manifestKey: true
        ]
        let raw = try JSONSerialization.data(withJSONObject: manifest)
        try raw.write(to: manifestURL)
        let host = WebExtensionCompatibilityHost()
        let foreign = ["souloCompatibility": 1, "api": "ownedCapture", "operation": "open",
                       "url": "blob:https://outside.example/foreign"] as [String: Any]
        let enabledContext = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: root))
        var permissionError: Error?
        XCTAssertTrue(host.handle(message: foreign, applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier,
                                  context: enabledContext, resourceURL: root) { _, error in permissionError = error })
        XCTAssertEqual((permissionError as? URLError)?.code, .noPermissionsToReadFile)

        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: root, reusingInstalledResources: false)
        let prepared = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertNil(prepared[WebExtensionGoFullPageAdapter.manifestKey])
        let disabledContext = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: root))
        var unsupportedError: Error?
        XCTAssertTrue(host.handle(message: foreign, applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier,
                                  context: disabledContext, resourceURL: root) { _, error in unsupportedError = error })
        XCTAssertNotNil(unsupportedError)
        XCTAssertNil(unsupportedError as? URLError)
    }

    func testManagedPermissionStatusFollowsReviewedAccess() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"manifest_version":3,"name":"Optional download","version":"1.0","permissions":["nativeMessaging"],"optional_permissions":["downloads"]}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: root))
        let host = WebExtensionCompatibilityHost()
        var access = WebExtensionAccess.requested(permissions: [], sites: [])
        func hasPermission(_ name: String) -> Bool? {
            var allowed: Bool?
            XCTAssertTrue(host.handle(message: ["souloCompatibility": 1, "api": "permissionStatus", "name": name],
                applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier, context: context, resourceURL: root,
                access: access) { value, error in
                    XCTAssertNil(error)
                    allowed = value as? Bool
                })
            return allowed
        }
        XCTAssertEqual(hasPermission("downloads"), false)
        access.setPermission("downloads", allowed: true)
        access.setPermission("proxy", allowed: true)
        XCTAssertEqual(hasPermission("downloads"), true)
        XCTAssertEqual(hasPermission("proxy"), false)
        access.setPermission("downloads", allowed: false)
        XCTAssertEqual(hasPermission("downloads"), false)
    }
}

private final class AuditResourceProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: url.path == "/missing.css" ? 404 : 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/css; charset=utf-8"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("body { color: purple; }".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ExtensionAuditTests {
    /// Opt-in functional test using the official, freely downloaded Chrome package.
    func testTampermonkeyScriptLifecycleWithLocalPackage() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native WebExtensions require iOS 18.4") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = documents.appendingPathComponent("tampermonkey-compatibility-qa.crx")
        guard FileManager.default.fileExists(atPath: package.path) else { throw XCTSkip("Opt-in real Tampermonkey package") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tm-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        defer { service.discardWebExtensionPreview(preview) }
        let pathPrefix = "tm-" + UUID().uuidString.lowercased()
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preview.resourceURL.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertFalse((manifest["permissions"] as? [String] ?? []).contains("userScripts"))
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], ["__soulo_blob_background.js", "__soulo_webextension_compatibility.js", "background.js"])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertNil(background["service_worker"])
        XCTAssertEqual((manifest["content_scripts"] as? [[String: Any]])?.filter { $0["js"] as? [String] == ["page.js", "content.js"] }.count, 1)
        let worker = preview.resourceURL.appendingPathComponent("background.js")
        let source = try String(contentsOf: worker, encoding: .utf8)
        XCTAssertTrue(source.contains("globalThis.__souloAddInstallationListener(e)"))
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: preview.resourceURL)
        XCTAssertEqual(try String(contentsOf: worker, encoding: .utf8), source, "Preparing an installed extension again must be idempotent")
        let logger = """
        (()=>{const messages=[]; const save=(...args)=>{messages.push(args.map(x=>{try{return typeof x==='string'?x:(x?.message ? x.message+' '+(x.stack||''):JSON.stringify(x))}catch(_){return String(x)}}).join(' '));chrome.storage.local.set({__souloQALog:messages.slice(-100)});};
        for(const level of ['log','warn','error','debug']){const original=console[level];console[level]=function(...args){save(level,...args);return original.apply(console,args);};}
        addEventListener('error',e=>save('UNCAUGHT',e.message,e.filename,e.lineno));addEventListener('unhandledrejection',e=>save('REJECT',String(e.reason),e.reason?.stack));})();
        """
        try Data((logger + source).utf8).write(to: worker)
        // Use the real options origin and its normal background authorization.
        try Data("<html><head><script src='/__soulo_webextension_compatibility.js'></script></head><body id='ready'>Local lifecycle test</body></html>".utf8)
            .write(to: preview.resourceURL.appendingPathComponent("__soulo_tm_lifecycle.html"))
        var access = preview.access; access.sites = ["http://127.0.0.1/*": .distantFuture]
        let record = try await service.installWebExtension(preview, access: access)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("__soulo_tm_lifecycle.html")))
        for _ in 0..<100 {
            if (try? await page.evaluateJavaScript("!!document.getElementById('ready') && typeof chrome !== 'undefined'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer {
            // The actual log is attached below before assertions, including unsuccessful experiments.
            page.stopLoading()
        }
        try await Task.sleep(for: .seconds(3))
        let script = """
        // ==UserScript==
        // @name Soulo Tampermonkey lifecycle
        // @namespace soulo.local.qa
        // @version 1.0
        // @match http://127.0.0.1/\(pathPrefix)/*
        // @grant GM_getValue
        // @grant GM.setValue
        // @grant GM_xmlhttpRequest
        // @connect 127.0.0.1
        // @run-at document-end
        // ==/UserScript==
        (async()=>{
        const count=GM_getValue('visits',0)+1; await GM.setValue('visits',count);
        document.documentElement.setAttribute('data-tm-visits',String(count));
        try { document.documentElement.setAttribute('data-tm-xhr-type',typeof GM_xmlhttpRequest);
        GM_xmlhttpRequest({method:'GET',url:location.origin+'/data.json',onload:response=>{
          document.documentElement.setAttribute('data-tm-network',JSON.parse(response.responseText).answer);
        },onerror:error=>document.documentElement.setAttribute('data-tm-error',String(error.error||error))});
        } catch(error) { document.documentElement.setAttribute('data-tm-error',String(error)+' '+error.stack); }
        })();
        """
        let result = try await page.callAsyncJavaScript("""
        const request={method:'saveScript',uuid:'qa-new',new_script:true,code:script,reload:false,origin:'options'};
        let reply,error;
        try{reply=await Promise.race([chrome.runtime.sendMessage(request),new Promise((_,reject)=>setTimeout(()=>reject(Error('Background request timed out')),8000))]);}catch(e){error=String(e);}
        return {reply:reply||null,error:error||null,log:(await chrome.storage.local.get('__souloQALog')).__souloQALog||[]};
        """, arguments: ["script": script], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: documents.appendingPathComponent("tampermonkey-lifecycle-qa.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment)
        print("TAMPERMONKEY LIFECYCLE " + String(decoding: data, as: UTF8.self))
        XCTAssertNil(result["error"] as? String)
        XCTAssertEqual((result["reply"] as? [String: Any])?["installed"] as? Bool, true)
        guard (result["reply"] as? [String: Any])?["installed"] as? Bool == true else { return }
        let pageData = Data("<html><body>Local Tampermonkey fixture</body></html>".utf8)
        let fixture = try DownloadPlaybackHTTPFixture(files: ["/\(pathPrefix)/page.html": pageData, "/\(pathPrefix)/denied.html": pageData, "/\(pathPrefix)/restored.html": pageData, "/\(pathPrefix)/disabled.html": pageData, "/\(pathPrefix)/enabled.html": pageData,
            "/data.json": Data(#"{"answer":"network-ok"}"#.utf8)])
        let address = try await fixture.start().appendingPathComponent(pathPrefix); defer { fixture.stop() }
        let permissionsProbe = try await page.callAsyncJavaScript("""
        const result={};for(const pattern of ['*://*/*','http://127.0.0.1/*',origin+'/']) {
          try{result[pattern]=await chrome.permissions.contains({origins:[pattern]});}catch(error){result[pattern]=String(error);}
        }return result;
        """, arguments: ["origin": address.absoluteString], in: nil, contentWorld: .page)
        print("TAMPERMONKEY PERMISSIONS " + String(describing: permissionsProbe))
        _ = try await page.callAsyncJavaScript("return await chrome.runtime.sendMessage({method:'setOption',name:'logLevel',value:100,origin:'options'});", in: nil, contentWorld: .page)
        let configuration = WKWebViewConfiguration(); NativeWebExtensionRuntime.shared.apply(to: configuration)
        var tab = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration)
        NativeWebExtensionRuntime.shared.register(tab)
        defer { NativeWebExtensionRuntime.shared.unregister(tab); tab.stopLoading() }
        tab.load(URLRequest(url: address.appendingPathComponent("page.html")))
        var visits: String?
        for _ in 0..<150 {
            visits = (try? await tab.evaluateJavaScript("document.documentElement.getAttribute('data-tm-visits')")) as? String
            if visits != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let finalLog = try await page.callAsyncJavaScript("return {log:(await chrome.storage.local.get('__souloQALog')).__souloQALog||[]};", in: nil, contentWorld: .page)
        print("TAMPERMONKEY INJECTION " + String(describing: finalLog) + " visits=" + String(describing: visits))
        XCTAssertEqual(visits, "1")
        let installRules = try await page.callAsyncJavaScript("return await chrome.declarativeNetRequest.getSessionRules();", in: nil, contentWorld: .page) as? [[String: Any]]
        XCTAssertGreaterThan(installRules?.count ?? 0, 1, "The publisher's actual script-install rules must compile")
        for enabled in [false, true] {
            _ = try await page.callAsyncJavaScript("return await chrome.runtime.sendMessage({method:'setOption',name:'scriptUrlDetection',value:mode,origin:'options'});", arguments: ["mode": enabled ? "auto" : "manual"], in: nil, contentWorld: .page)
            var count = 0
            for _ in 0..<100 {
                count = (try await page.callAsyncJavaScript("return (await chrome.declarativeNetRequest.getSessionRules()).filter(r=>r.action.type==='redirect').length;", in: nil, contentWorld: .page) as? Int) ?? 0
                if (count > 0) == enabled { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(count > 0, enabled, "Changing the publisher setting must remove and restore its actual rules")
        }
        let injected = visits == "1"
        var network: String?
        for _ in 0..<100 {
            network = (try? await tab.evaluateJavaScript("document.documentElement.getAttribute('data-tm-network')")) as? String
            if network != nil { break }; try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(network, "network-ok", "Use Tampermonkey's real GM network implementation")
        let networkLog = try await page.callAsyncJavaScript("return {log:(await chrome.storage.local.get('__souloQALog')).__souloQALog||[]};", in: nil, contentWorld: .page)
        let scriptState = try await tab.evaluateJavaScript("Object.fromEntries(Array.from(document.documentElement.attributes).map(a=>[a.name,a.value]))")
        print("TAMPERMONKEY NETWORK " + String(describing: scriptState) + " log=" + String(describing: networkLog) + " paths=" + String(describing: fixture.receivedRequests.map(\.path)))
        tab.reload()
        for _ in 0..<100 {
            visits = (try? await tab.evaluateJavaScript("document.documentElement.getAttribute('data-tm-visits')")) as? String
            if visits == "2" { break }; try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(visits, "2", "GM values must survive a page reload")
        let dashboard = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: try XCTUnwrap(context.webViewConfiguration))
        dashboard.configuration.userContentController.addUserScript(WKUserScript(source: "window.__souloDashboardErrors=[];addEventListener('error',e=>__souloDashboardErrors.push(String(e.message)));addEventListener('unhandledrejection',e=>__souloDashboardErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow), dashboardWindow = UIWindow(windowScene: scene)
        dashboardWindow.rootViewController = UIViewController()
        dashboardWindow.rootViewController?.view.addSubview(dashboard); dashboardWindow.makeKeyAndVisible()
        defer { dashboardWindow.isHidden = true; dashboardWindow.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        dashboard.load(URLRequest(url: try XCTUnwrap(URL(string: "options.html#nav=dashboard", relativeTo: context.baseURL)?.absoluteURL)))
        var dashboardReady = false
        for _ in 0..<150 {
            dashboardReady = (try? await dashboard.evaluateJavaScript("document.body.innerText.includes('Soulo Tampermonkey lifecycle')")) as? Bool == true
            if dashboardReady { break }; try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(dashboardReady, "The publisher's original dashboard must list the installed script")
        let dashboardState = try await dashboard.evaluateJavaScript("({url:location.href,title:document.title,text:document.body.innerText.slice(0,6000),errors:window.__souloDashboardErrors})")
        print("TAMPERMONKEY DASHBOARD " + String(describing: dashboardState))
        dashboard.stopLoading()
        dashboardWindow.isHidden = true; dashboardWindow.rootViewController = nil; previousWindow?.makeKeyAndVisible()

        func load(_ path: String, expected: String?) async throws -> Bool {
            tab.load(URLRequest(url: address.appendingPathComponent(path)))
            for _ in 0..<150 {
                let state = try? await tab.evaluateJavaScript("({path:location.pathname,ready:document.readyState,visits:document.documentElement.getAttribute('data-tm-visits')})") as? [String: Any]
                if state?["path"] as? String == "/" + pathPrefix + "/" + path, state?["ready"] as? String == "complete",
                   expected == nil || state?["visits"] as? String == expected { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if expected == nil { try await Task.sleep(for: .milliseconds(650)) }
            let value = try await tab.evaluateJavaScript("document.documentElement.getAttribute('data-tm-visits')") as? String
            let loadedPath = try await tab.evaluateJavaScript("location.pathname") as? String
            XCTAssertEqual(loadedPath, "/" + pathPrefix + "/" + path)
            XCTAssertEqual(value, expected)
            return loadedPath == "/" + pathPrefix + "/" + path && value == expected
        }
        var withheld = access; withheld.sites = [:]; withheld.deniedSites = ["http://127.0.0.1/*": .distantFuture]
        try service.setWebExtensionAccess(withheld, id: record.id)
        let denied = try await load("denied.html", expected: nil)
        // Granting a host can inject immediately into the currently open page.
        // Navigate away so the visit counter measures the next test page only.
        tab.load(URLRequest(url: URL(string: "about:blank")!))
        for _ in 0..<100 {
            if (try? await tab.evaluateJavaScript("location.href==='about:blank' && document.readyState==='complete'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try service.setWebExtensionAccess(access, id: record.id)
        let restored = try await load("restored.html", expected: "3")
        // The manager batches its backing-store writes after acknowledging the
        // script's local value. Check the actual backing store before unload.
        let storageID = try XCTUnwrap((result["reply"] as? [String: Any])?["uuid"] as? String)
        var committed = false
        for _ in 0..<60 {
            let state = try await page.callAsyncJavaScript("""
            const values=await chrome.storage.local.get('!extdb.@st#'+id);
            const value=values['!extdb.@st#'+id];
            function containsVisit(value){
              if(typeof value==='string') {try{return containsVisit(JSON.parse(value));}catch(_){return value.includes('"visits":"n3"')||value.includes('"visits":3');}}
              if(!value||typeof value!=='object')return false;
              if(value.visits==='n3'||value.visits===3)return true;
              return Object.values(value).some(containsVisit);
            }
            return {committed:containsVisit(value),value};
            """, arguments: ["id": storageID], in: nil, contentWorld: .page) as? [String: Any]
            committed = state?["committed"] as? Bool == true
            if committed { break }
            if !committed { print("TAMPERMONKEY PERSIST " + String(describing: state)) }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(committed, "Verify the manager's backing store, not just its DOM counter")
        service.setWebExtensionEnabled(record.id, enabled: false)
        let disabled = try await load("disabled.html", expected: nil)
        NativeWebExtensionRuntime.shared.unregister(tab); tab.stopLoading()
        // WebViewContainer rebuilds loaded views after browserExtensionsChanged.
        // Recreate this unmanaged test view through the same runtime configuration.
        service.setWebExtensionEnabled(record.id, enabled: true)
        for _ in 0..<150 {
            if service.loadingWebExtensions.isEmpty,
               NativeWebExtensionRuntime.shared.controller.extensionContexts.contains(where: { $0.uniqueIdentifier == record.id.uuidString }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("TAMPERMONKEY REENABLE errors=" + String(describing: service.webExtensionErrors[record.id]) + " diagnostics=" + String(describing: service.webExtensionDiagnostics(record.id)))
        if let reopenedContext = NativeWebExtensionRuntime.shared.controller.extensionContexts.first(where: { $0.uniqueIdentifier == record.id.uuidString }) {
            print("TAMPERMONKEY REENABLE ACCESS allowed=" + String(reopenedContext.hasAccess(to: address)) + " stored=" + String(describing: service.webExtensionAccess(record.id)))
            let debugPage = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: try XCTUnwrap(reopenedContext.webViewConfiguration))
            debugPage.load(URLRequest(url: reopenedContext.baseURL.appendingPathComponent("__soulo_tm_lifecycle.html")))
            for _ in 0..<100 {
                if (try? await debugPage.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let reopenedState = try await debugPage.callAsyncJavaScript("const all=await chrome.storage.local.get(null);return {keys:Object.keys(all),config:all['#config'],log:all.__souloQALog};", in: nil, contentWorld: .page)
            print("TAMPERMONKEY REENABLE STATE " + String(describing: reopenedState))
            debugPage.stopLoading()
        }
        let reopenedConfiguration = WKWebViewConfiguration(); NativeWebExtensionRuntime.shared.apply(to: reopenedConfiguration)
        tab = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 600), configuration: reopenedConfiguration)
        NativeWebExtensionRuntime.shared.register(tab)
        let enabled = try await load("enabled.html", expected: "4")
        let verified: [String: Any] = ["package": "Tampermonkey Chrome 5.5.1", "installed": (result["reply"] as? [String: Any])?["installed"] as? Bool == true,
            "injected": injected, "gmNetwork": network == "network-ok", "gmValuesAfterPageReload": visits == "2",
            "originalDashboard": dashboardReady, "permissionRevocation": denied, "permissionRestoration": restored,
            "disabledStopsInjection": disabled, "valuesRestoredAfterContextReload": enabled, "webKitUserScriptsAPIEmulated": false]
        let verifiedData = try JSONSerialization.data(withJSONObject: verified, options: [.prettyPrinted, .sortedKeys])
        try verifiedData.write(to: documents.appendingPathComponent("tampermonkey-functional-qa.json"))
        let verifiedAttachment = XCTAttachment(data: verifiedData, uniformTypeIdentifier: "public.json"); verifiedAttachment.lifetime = .keepAlways; add(verifiedAttachment)
    }

    func testTampermonkeyDomainExclusionsKeepMethodsProvidersAndHeaderRules() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(WebExtensionTampermonkeyAdapter.javaScript)
        js.evaluateScript(#"""
        var original=[
          {id:1,priority:3,condition:{regexFilter:'^https?://.*\\.user\\.js$',excludedRequestDomains:['excluded.test','provider.test'],requestMethods:['get'],resourceTypes:['main_frame']},action:{type:'redirect',redirect:{url:'https://install.test/general'}}},
          {id:2,priority:3,condition:{regexFilter:'^https?://.*\\.user\\.js$',requestDomains:['provider.test'],requestMethods:['get'],resourceTypes:['main_frame']},action:{type:'redirect',redirect:{url:'https://install.test/provider'}}},
          {id:3,priority:1,condition:{resourceTypes:['main_frame']},action:{type:'modifyHeaders',responseHeaders:[{header:'content-security-policy',operation:'remove'}]}}
        ];
        var next=100,compiled=__souloCompileTampermonkeyRules(original,()=>next++);
        function decision(rules,url,method){
          const host=url.match(/^https?:\/\/([^/:]+)/)[1],domain=d=>host===d||host.endsWith('.'+d);
          const matching=rules.filter(r=>r.action.type!=='modifyHeaders'&&(!r.condition.regexFilter||new RegExp(r.condition.regexFilter).test(url))&&(!r.condition.requestDomains||r.condition.requestDomains.some(domain))&&(!r.condition.excludedRequestDomains||!r.condition.excludedRequestDomains.some(domain))&&(!r.condition.requestMethods||r.condition.requestMethods.includes(method))).sort((a,b)=>b.priority-a.priority);
          return matching[0]?.action.type==='redirect'?matching[0].action.redirect.url:null;
        }
        var equivalent=['custom.test','excluded.test','sub.excluded.test','provider.test','sub.provider.test'].every(host=>['get','post'].every(method=>decision(original,'https://'+host+'/a.user.js',method)===decision(compiled,'https://'+host+'/a.user.js',method)));
        var headersRemainActive=compiled.filter(r=>r.action.type==='modifyHeaders').every(r=>r.priority>Math.max(...compiled.filter(r=>r.action.type==='allow').map(r=>r.priority)));
        var prioritiesRestore=compiled.every(r=>__souloTampermonkeyRulePriority(r.priority)===(r.action.type==='modifyHeaders'?1:3));
        """#)
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("equivalent")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("headersRemainActive")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("prioritiesRestore")?.toBool(), true)
    }

    func testTampermonkeyPublisherInstallRulesPreserveMatchingAndCompileInWebKit() async throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(WebExtensionTampermonkeyAdapter.javaScript)
        js.evaluateScript(##"""
        var patterns=[
          '^https?://userscripts\\.org/scripts/(source|version)/([0-9]{1,9})\\.user\\.js(?:$|\\?|\\#)',
          '^https?://openuserjs\\.org/install/([^/]+)+/(.+?)(?:\\.min)?\\.user\\.js(?:$|\\?|\\#)',
          '^https?://gitlab\\.com/([^/]+)(?:/([^/]+))?/([^/-]{1,1}[^/]+)/?(?:-/)?(snippets/[^/]+/)?(raw|wikis)/(?:[^/]+/)?(.*?)\\.user\\.js(?:$|\\?|\\#)'
        ];
        var next=100;
        var rules=patterns.flatMap((pattern,index)=>__souloCompileTampermonkeyRules([{id:index+1,condition:{regexFilter:pattern},action:{type:'redirect',redirect:{regexSubstitution:'https://example.com/#url=\\0'}}}],()=>next++));
        var samples=['https://userscripts.org/scripts/source/1.user.js','http://userscripts.org/scripts/version/123456789.user.js?x=1','https://userscripts.org/scripts/source/1234567890.user.js','https://userscripts.org/scripts/other/12.user.js','https://userscripts.org/scripts/source/1.user.js/invalid','https://openuserjs.org/install/author/script.min.user.js#anchor','https://gitlab.com/author/project/-/raw/main/script.user.js','https://gitlab.com/author/project/-/raw/main/other.js'];
        var equivalent=samples.every(url=>patterns.some(pattern=>new RegExp(pattern).test(url))===rules.some(rule=>new RegExp(rule.condition.regexFilter).test(url)));
        """##)
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("equivalent")?.toBool(), true)
        let patterns = try XCTUnwrap(js.evaluateScript("rules.map(rule=>rule.condition.regexFilter)")?.toArray() as? [String])
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        for pattern in patterns {
            let id = "soulo-publisher-install-rule-" + UUID().uuidString
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [["trigger": ["url-filter": pattern], "action": ["type": "block"]]]), as: UTF8.self)
            _ = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: encoded)
            try await store.removeContentRuleList(forIdentifier: id)
        }
    }

    func testTampermonkeyRuleAlternativesPreserveMatchingAndCompileInWebKit() async throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(WebExtensionTampermonkeyAdapter.javaScript)
        js.evaluateScript(#"""
        var pattern='^(?:https?|ftp)://[^\\#\\?]+/[^\\#\\?]+\\.(?:user|tamper)\\.js[^/]*$';
        var next=100;
        var rules=__souloExpandTampermonkeyRules([{id:1,condition:{regexFilter:pattern},action:{type:'redirect',redirect:{regexSubstitution:'https://example.com/#url=\\0'}}}],()=>next++);
        var samples=['https://example.com/a.user.js','http://a.test/b.tamper.js?query=1','ftp://x.test/a.user.js','https://x.test/a.js','https://x.test/a.user.js/path'];
        var equivalent=samples.every(url=>new RegExp(pattern).test(url)===rules.some(rule=>new RegExp(rule.condition.regexFilter).test(url)));
        """#)
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("equivalent")?.toBool(), true)
        let patterns = try XCTUnwrap(js.evaluateScript("rules.map(rule=>rule.condition.regexFilter)")?.toArray() as? [String])
        XCTAssertEqual(patterns.count, 4)
        XCTAssertEqual(js.evaluateScript("new Set(rules.map(rule=>rule.id)).size")?.toInt32(), 4)
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        for pattern in patterns {
            let id = "soulo-extension-rule-" + UUID().uuidString
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [["trigger": ["url-filter": pattern], "action": ["type": "block"]]]), as: UTF8.self)
            _ = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: encoded)
            try await store.removeContentRuleList(forIdentifier: id)
        }
    }

    func testTampermonkeyCapabilityAuditWithLocalPackage() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native WebExtensions require iOS 18.4") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let package = documents.appendingPathComponent("tampermonkey-compatibility-qa.crx")
        guard FileManager.default.fileExists(atPath: package.path) else { throw XCTSkip("Opt-in local Tampermonkey package audit") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-capability-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root)
        let preview = try await service.previewWebExtension(from: package)
        defer { service.discardWebExtensionPreview(preview) }
        let probe = "__soulo_capability_audit.html"
        try Data("<html><head><title>Extension capability audit</title></head><body id='soulo-api-probe'>Local API probe</body></html>".utf8)
            .write(to: preview.resourceURL.appendingPathComponent(probe))
        var access = preview.access
        access.sites = ["http://127.0.0.1/*": .distantFuture]
        let record = try await service.installWebExtension(preview, access: access)
        defer { service.deleteWebExtension(record.id) }
        let context = try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        defer { web.stopLoading() }
        web.load(URLRequest(url: context.baseURL.appendingPathComponent(probe)))
        var ready = false
        for _ in 0..<100 {
            ready = (try? await web.evaluateJavaScript("!!document.getElementById('soulo-api-probe') && typeof chrome !== 'undefined'")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready, "The probe must run in a real extension origin")
        let matrix = try await web.callAsyncJavaScript("""
        const api = globalThis.chrome || globalThis.browser || {};
        return {
          runtime: typeof api.runtime?.sendMessage,
          scriptingExecute: typeof api.scripting?.executeScript,
          scriptingRegister: typeof api.scripting?.registerContentScripts,
          userScripts: typeof api.userScripts,
          userScriptsRegister: typeof api.userScripts?.register,
          userScriptsWorld: typeof api.userScripts?.configureWorld,
          offscreen: typeof api.offscreen?.createDocument,
          runtimeContexts: typeof api.runtime?.getContexts,
          webRequestBlocking: typeof api.webRequest?.onBeforeRequest?.addListener,
          storage: typeof api.storage?.local?.get,
          cookies: typeof api.cookies?.getAll,
          debugger: typeof api.debugger,
          identity: typeof api.identity,
          downloads: typeof api.downloads
        };
        """, arguments: [:], in: nil, contentWorld: .page)
        let report: [String: Any] = ["kind": "capability_probe_not_functional_certification", "name": record.name, "version": record.version,
            "system": UIDevice.current.systemVersion, "matrix": matrix, "previewWarnings": preview.warnings,
            "runtimeDiagnostics": service.webExtensionDiagnostics(record.id),
            "externalHostAccess": false, "probeIncludesCompatibilityShim": false,
            "offscreenDOMVerificationTest": "ExtensionManagementTests/testOffscreenDocumentRunsDOMMessagingAndClosesOnPermissionRevocation"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: documents.appendingPathComponent("tampermonkey-capability-audit.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "tampermonkey-capability-audit"; attachment.lifetime = .keepAlways; add(attachment)
        print("TAMPERMONKEY CAPABILITY AUDIT " + String(decoding: data, as: UTF8.self))
    }

    func testWildcardPortsAreNormalizedWithoutBroadeningFixedPortsOrChangingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let patterns = ["http://localhost:*/*", "https://192.168.0.2:*/*", "*://*.example.com:*/allowed/*",
                        "https://example.com:8443/*", "https://example.com/*", "ftp://example.com:*/*"]
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Port fixture", "version": "1.0",
                                      "permissions": ["storage"], "externally_connectable": ["matches": patterns]]
        let sourceData = try JSONSerialization.data(withJSONObject: manifest)
        let sourceManifest = source.appendingPathComponent("manifest.json")
        try sourceData.write(to: sourceManifest)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
        let prepared = try await WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("store"))
        let preparedManifest = prepared.appendingPathComponent("manifest.json")
        let first = try Data(contentsOf: preparedManifest)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual((result["externally_connectable"] as? [String: Any])?["matches"] as? [String],
                       ["http://localhost/*", "https://192.168.0.2/*", "*://*.example.com/allowed/*",
                        "https://example.com:8443/*", "https://example.com/*", "ftp://example.com:*/*"])
        XCTAssertEqual(result["permissions"] as? [String], ["storage"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("__soulo_webextension_compatibility.js").path))
        try await WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        XCTAssertEqual(try Data(contentsOf: preparedManifest), first)
        XCTAssertEqual(try Data(contentsOf: sourceManifest), sourceData)
    }

    func testNormalizedWildcardPortAllowsNativeExternalMessaging() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "External message fixture", "version": "1.0", "permissions": ["storage"],
            "host_permissions": ["http://localhost/*"],
            "background": ["service_worker": "background.js"],
            "externally_connectable": ["matches": ["http://localhost:*/*"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try Data(#"importScripts(`./reply.js`); chrome.runtime.onMessageExternal.addListener((message,sender,reply)=>{reply(makeReply(message));});chrome.storage.local.set({ready:true});"#.utf8)
            .write(to: package.appendingPathComponent("background.js"))
        try Data("function makeReply(message){return {pong:message.ping};}".utf8).write(to: package.appendingPathComponent("reply.js"))
        try Data("<html><body id='ready'>Extension peer</body></html>".utf8).write(to: package.appendingPathComponent("peer.html"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(record.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let peer = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: try XCTUnwrap(context.webViewConfiguration))
        window.rootViewController?.view.addSubview(peer)
        peer.load(URLRequest(url: context.baseURL.appendingPathComponent("peer.html")))
        defer { peer.stopLoading() }
        let started = expectation(description: "Native background starts")
        context.loadBackgroundContent { error in XCTAssertNil(error); started.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        var ready = false
        for _ in 0..<100 {
            if (try? await peer.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true,
               let state = try? await peer.callAsyncJavaScript("return (await chrome.storage.local.get('ready')).ready;", arguments: [:], in: nil, contentWorld: .page),
               state as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready, "Background listener must be installed before sending a message")

        let server = try DownloadPlaybackHTTPFixture(files: ["/external.html": Data("<html><body id='ready'>External peer</body></html>".utf8)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        var components = try XCTUnwrap(URLComponents(url: address.appendingPathComponent("external.html"), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let configuration = WKWebViewConfiguration(); configuration.webExtensionController = runtime.controller
        let external = WKWebView(frame: peer.frame, configuration: configuration)
        window.rootViewController?.view.addSubview(external)
        runtime.register(external)
        defer { external.stopLoading(); runtime.unregister(external) }
        external.load(URLRequest(url: try XCTUnwrap(components.url)))
        for _ in 0..<100 {
            if (try? await external.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let reply = try await external.callAsyncJavaScript("""
            const api=globalThis.chrome?.runtime||globalThis.browser?.runtime;
            const request=new Promise((resolve,reject)=>{
                api.sendMessage(identifier,{ping:'native-roundtrip'},reply=>{
                    if(api.lastError)reject(Error(api.lastError.message));else resolve(reply);
                });
            });
            try{return {reply:await Promise.race([request,new Promise((_,reject)=>setTimeout(()=>reject(Error('message timeout')),5000))])};}
            catch(e){return {error:String(e)};}
            """, arguments: ["identifier": context.uniqueIdentifier], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual((reply?["reply"] as? [String: Any])?["pong"] as? String, "native-roundtrip", String(describing: reply))
    }
}

private actor ScriptProgressRecorder {
    var events: [UserScriptHTTPBridge.Progress] = []
    func add(_ event: UserScriptHTTPBridge.Progress) { events.append(event) }
}

private final class ScriptTransportFixture: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [URLRequest] = []
    static func reset() { lock.lock(); captured = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); Self.lock.unlock()
        let data = Data(repeating: 0x7f, count: 64 * 1_024)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ExtensionAuditTests {
    func testNetworkProgressAndBinaryResponsesKeepExactByteCountsWithoutATextCopy() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptTransportFixture.self]
        let script = UserScriptRecord(name: "Network", source: "", grants: ["GM_xmlhttpRequest", "GM_cookie"], connectDomains: ["transport.example"])
        let progress = ScriptProgressRecorder()
        ScriptTransportFixture.reset()
        let result = try await UserScriptHTTPBridge.response(for: ["url":"https://transport.example/file", "method":"POST",
            "dataBase64":Data([1,2,3]).base64EncodedString(), "cookie":"fixture=1", "timeout":Double.nan, "responseType":"arraybuffer"],
            script: script, pageURL: URL(string:"https://page.example/"), configuration: configuration,
            onProgress: { await progress.add($0) })
        XCTAssertEqual(result["responseText"] as? String, "", "Binary replies must not allocate an extra decoded text copy")
        XCTAssertEqual(Data(base64Encoded: result["base64"] as! String)?.count, 64 * 1_024)
        let events = await progress.events
        XCTAssertEqual(events.first?.kind, .headers)
        XCTAssertEqual(events.last?.kind, .download)
        XCTAssertEqual(events.last?.loaded, 64 * 1_024)
        XCTAssertEqual(events.last?.total, 64 * 1_024)
        XCTAssertEqual(ScriptTransportFixture.requests().first?.value(forHTTPHeaderField: "Cookie"), "fixture=1")
        XCTAssertEqual(ScriptTransportFixture.requests().first?.timeoutInterval, 30)
    }

    func testExplicitCookieRequiresItsGrantAndAnonymousOverridesIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptTransportFixture.self]
        let script = UserScriptRecord(name: "Network", source: "", grants: ["GM_xmlhttpRequest"], connectDomains: ["transport.example"])
        ScriptTransportFixture.reset()
        do {
            _ = try await UserScriptHTTPBridge.response(for:["url":"https://transport.example/file","cookie":"fixture=1"],
                script:script,pageURL:nil,configuration:configuration)
            XCTFail("Explicit cookies need the GM_cookie grant")
        } catch { XCTAssertEqual((error as? URLError)?.code, .noPermissionsToReadFile) }
        XCTAssertTrue(ScriptTransportFixture.requests().isEmpty)
        _ = try await UserScriptHTTPBridge.response(for:["url":"https://transport.example/file","cookie":"fixture=1","anonymous":true],
            script:script,pageURL:nil,configuration:configuration)
        XCTAssertNil(ScriptTransportFixture.requests().first?.value(forHTTPHeaderField:"Cookie"))
    }

    func testUploadLimitAndRedirectsDoNotLeakCookieCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptTransportFixture.self]
        let script = UserScriptRecord(name:"Network",source:"",connectDomains:["transport.example"])
        ScriptTransportFixture.reset()
        do {
            _ = try await UserScriptHTTPBridge.response(for:["url":"https://transport.example/file","method":"POST",
                "dataBase64":Data(repeating:0,count:UserScriptHTTPBridge.maximumUploadSize+1).base64EncodedString()],
                script:script,pageURL:nil,configuration:configuration)
            XCTFail("Oversized uploads must stop before transport")
        } catch { XCTAssertEqual((error as? URLError)?.code,.dataLengthExceedsMaximum) }
        XCTAssertTrue(ScriptTransportFixture.requests().isEmpty)
        let origin = URL(string:"https://transport.example/")!
        XCTAssertEqual(UserScriptHTTPBridge.cookieForRedirect("fixture=1",from:origin,to:URL(string:"https://transport.example:443/next")!),"fixture=1")
        for url in ["http://transport.example/next","https://elsewhere.example/next","https://transport.example:444/next"] {
            XCTAssertNil(UserScriptHTTPBridge.cookieForRedirect("fixture=1",from:origin,to:URL(string:url)!))
        }
    }

    func testXHRProgressDispatchAndTimeoutSettleOnlyOnceAndCleanTheirReceivers() throws {
        let js = try context(grants:["GM.xmlHttpRequest"])
        js.evaluateScript("""
        var packet,finishHTTP,events=[],states=[],sent=[];
        webkit.messageHandlers.souloUserScriptXHR.postMessage=function(p){packet=p;return new Promise(function(resolve){finishHTTP=resolve;});};
        var pendingHTTP=GM.xmlHttpRequest({url:'https://transport.example/file',context:{tag:42},
          onprogress:function(e){events.push([e.loaded,e.total,e.context.tag]);},
          onreadystatechange:function(e){states.push(e.readyState);},
          upload:{onprogress:function(e){sent.push(e.loaded);}}});
        """)
        let id = try XCTUnwrap(UUID(uuidString:js.evaluateScript("packet.__souloScriptID")!.toString()))
        let requestID = try XCTUnwrap(js.evaluateScript("packet.__souloRequestID")?.toString())
        for progress in [UserScriptHTTPBridge.Progress(kind:.upload,loaded:3,total:3), .init(kind:.headers,loaded:0,total:7), .init(kind:.download,loaded:7,total:7)] {
            js.evaluateScript(try XCTUnwrap(UserScriptRuntime.networkProgressScript(progress,scriptID:id,requestID:requestID,bridgeToken:"test")))
            XCTAssertNil(js.exception)
        }
        js.evaluateScript("finishHTTP({status:200,responseText:'done'});")
        XCTAssertEqual(js.evaluateScript("JSON.stringify(events)")?.toString(),"[[7,7,42]]")
        XCTAssertEqual(js.evaluateScript("JSON.stringify(states)")?.toString(),"[2,3,4]")
        XCTAssertEqual(js.evaluateScript("JSON.stringify(sent)")?.toString(),"[3]")
        XCTAssertEqual(js.evaluateScript("Object.keys(window.__souloUserScriptNetworkReceivers).length")?.toInt32(),0)
        js.evaluateScript("""
        var timeoutCalls=0,errorCalls=0,endCalls=0,failedType;
        webkit.messageHandlers.souloUserScriptXHR.postMessage=function(){return Promise.resolve({__souloErrorType:'timeout',message:'fixture'});};
        GM.xmlHttpRequest({url:'https://transport.example/timeout',ontimeout:function(){timeoutCalls++;},
          onerror:function(){errorCalls++;},onloadend:function(){endCalls++;}}).catch(function(e){failedType=e.type;});
        """)
        XCTAssertEqual(js.evaluateScript("timeoutCalls")?.toInt32(),1)
        XCTAssertEqual(js.evaluateScript("errorCalls")?.toInt32(),0)
        XCTAssertEqual(js.evaluateScript("endCalls")?.toInt32(),1)
        XCTAssertEqual(js.evaluateScript("failedType")?.toString(),"timeout")
        XCTAssertEqual(js.evaluateScript("Object.keys(window.__souloUserScriptNetworkReceivers).length")?.toInt32(),0)

        js.evaluateScript("""
        var hideAborts=0, nativeAbortRequests=0;
        webkit.messageHandlers.souloUserScriptXHR.postMessage=function(message){
          if(message.action==='abort'){nativeAbortRequests++;return Promise.resolve(true);}
          return new Promise(function(){});
        };
        function beginRequest(){
          GM.xmlHttpRequest({url:'https://transport.example/held',onabort:function(){hideAborts++;}}).catch(function(){});
        }
        beginRequest();hideDocument();
        beginRequest();hideDocument();
        """)
        XCTAssertEqual(js.evaluateScript("hideAborts")?.toInt32(), 2)
        XCTAssertEqual(js.evaluateScript("nativeAbortRequests")?.toInt32(), 2)
        XCTAssertEqual(js.evaluateScript("Object.keys(window.__souloUserScriptNetworkReceivers).length")?.toInt32(), 0)
    }
}

extension ExtensionAuditTests {
    func testCurrentEdgeSimpleGestureInterExtensionMessaging() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_SIMPLE_GESTURE_QA"] == "1", "Opt-in official Edge package")
        let storeID = "hfhdokhgdkcaebhjdblfgafnimchimkd"
        let source = "https://microsoftedge.microsoft.com/addons/detail/simple-gesture/" + storeID
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let runtime = NativeWebExtensionRuntime.shared
        let preview = try await WebExtensionStoreInstallService.shared.preview(from: source, service: service)
        let gesture = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(gesture.id) }
        XCTAssertEqual(gesture.verifiedStoreIdentifier, storeID)
        let gestureContext = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == gesture.id.uuidString })

        let companionRoot = root.appendingPathComponent("companion")
        try FileManager.default.createDirectory(at: companionRoot, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": "Gesture messaging acceptance companion", "version": "1.0", "manifest_version": 3,
            "permissions": ["storage"], "options_ui": ["page": "options.html"],
            "background": ["scripts": ["message.js"], "persistent": false],
            "externally_connectable": ["ids": [storeID]],
            "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"]]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: companionRoot.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>Companion</title><body></body>".utf8).write(to: companionRoot.appendingPathComponent("options.html"))
        try Data("""
        chrome.runtime.onMessageExternal.addListener((message, sender, reply) => {
            chrome.storage.local.set({received:{message, sender:sender.id}})
                .then(() => reply('delivered'));
            return true;
        });
        """.utf8).write(to: companionRoot.appendingPathComponent("message.js"))
        try Data("""
        document.addEventListener('gesture-probe', async () => {
            try {
                await chrome.runtime.sendMessage('\(storeID)', {command:'register', id:'content', title:'From content script'});
                document.body.dataset.contentReply = 'delivered';
            } catch (error) { document.body.dataset.contentReply = error.message; }
        });
        """.utf8).write(to: companionRoot.appendingPathComponent("content.js"))
        let companion = try await service.installWebExtension(from: companionRoot)
        defer { service.deleteWebExtension(companion.id) }
        let companionContext = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == companion.id.uuidString })

        let html = Data("<!doctype html><meta name='viewport' content='width=device-width, initial-scale=1'><body style='min-height:4000px'>Gesture</body>".utf8)
        let server = try DownloadPlaybackHTTPFixture(files: ["/gesture.html": html])
        let address = try await server.start().appendingPathComponent("gesture.html")
        server.releaseDownloads()
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let configuration = WKWebViewConfiguration()
        runtime.apply(to: configuration)
        let browser = WKWebView(frame: window.bounds, configuration: configuration)
        let companionOptions = WKWebView(frame: window.bounds, configuration: try XCTUnwrap(companionContext.webViewConfiguration))
        let gestureOptions = WKWebView(frame: window.bounds, configuration: try XCTUnwrap(gestureContext.webViewConfiguration))
        [companionOptions, gestureOptions, browser].forEach { controller.view.addSubview($0) }
        runtime.register(browser)
        defer { [browser, gestureOptions, companionOptions].forEach { $0.stopLoading() }; runtime.unregister(browser) }
        let companionURL = try XCTUnwrap(companionContext.optionsPageURL)
        let gestureURL = try XCTUnwrap(gestureContext.optionsPageURL)
        browser.load(URLRequest(url: address))
        companionOptions.load(URLRequest(url: companionURL))
        gestureOptions.load(URLRequest(url: gestureURL))
        try await waitForAuditPage(browser, at: address, mainDocumentOnly: true)
        try await waitForAuditPage(companionOptions, at: companionURL, mainDocumentOnly: true)
        try await waitForAuditPage(gestureOptions, at: gestureURL, mainDocumentOnly: true)

        let arguments = ["destination": storeID, "companion": companion.id.uuidString]
        let fromContent = try await runAuditJavaScript("""
        for (let retry=0; retry<40 && !document.body.dataset.contentReply; retry++) {
            if (retry%8===0) document.dispatchEvent(new Event('gesture-probe'));
            await new Promise(resolve=>setTimeout(resolve,100));
        }
        return document.body.dataset.contentReply;
        """, on: browser, timeout: 5)
        XCTAssertEqual(fromContent as? String, "delivered")
        let contentRegistered = try await runAuditJavaScript("""
        const key='simple_gesture_$'+companion+'#content';
        return (await browser.storage.local.get(key))[key]?.extensionId;
        """, on: gestureOptions, arguments: arguments)
        XCTAssertEqual(contentRegistered as? String, companion.id.uuidString)
        let registered = try await runAuditJavaScript("""
        await Promise.all([
            browser.runtime.sendMessage(destination, {command:'register', id:'acceptance', title:'Acceptance gesture', message:'gesture result'}),
            browser.runtime.sendMessage(destination, {command:'register', id:'parallel', title:'Parallel gesture'})
        ]);
        return true;
        """, on: companionOptions, arguments: arguments, timeout: 12)
        XCTAssertEqual(registered as? Bool, true)
        let action = try await runAuditJavaScript("""
        const id='$'+companion+'#acceptance';
        const {simple_gesture_exdata:data}=await browser.storage.local.get('simple_gesture_exdata');
        if (data?.customGestureList?.find(action=>action.id===id)?.title!=='Acceptance gesture') throw Error('Registration missing from options: '+JSON.stringify(data));
        await chrome.runtime.sendMessage({command:id});
        return true;
        """, on: gestureOptions, arguments: arguments, timeout: 12)
        XCTAssertEqual(action as? Bool, true)
        let registeredTogether = try await runAuditJavaScript("""
        const {simple_gesture_exdata:data}=await browser.storage.local.get('simple_gesture_exdata');
        return ['content','parallel','acceptance'].every(id=>data?.customGestureList?.some(action=>action.id==='$'+companion+'#'+id));
        """, on: gestureOptions, arguments: arguments)
        XCTAssertEqual(registeredTogether as? Bool, true)
        let received = try await runAuditJavaScript("""
        const {received}=await chrome.storage.local.get('received');
        return received?.message==='gesture result' && received?.sender===destination;
        """, on: companionOptions, arguments: arguments)
        XCTAssertEqual(received as? Bool, true)

        for (command, expected) in [("disable", false), ("enable", true)] {
            _ = try await runAuditJavaScript("""
            await new Promise((resolve, reject) => chrome.runtime.sendMessage(destination, {command}, () => {
                if (chrome.runtime.lastError) reject(Error(chrome.runtime.lastError.message)); else resolve();
            }));
            return true;
            """, on: companionOptions, arguments: ["destination": storeID, "command": command], timeout: 12)
            let recognized = try await runAuditJavaScript("""
            const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
            return (await chrome.scripting.executeScript({target:{tabId:tab.id},func:async()=>{
                await new Promise(resolve=>setTimeout(resolve,250));
                const target=document.body, original=SimpleGesture.doCmd, commands=[];
                SimpleGesture.doCmd=command=>commands.push(command);
                try {
                    for(const [type,x,y] of [['start',.25,.7],['move',.72,.7],['move',.72,.25],['end',.72,.25]]){
                        const touch=new Touch({identifier:1,target,clientX:x*visualViewport.width,clientY:y*visualViewport.height});
                        target.dispatchEvent(new TouchEvent('touch'+type,{bubbles:true,cancelable:true,touches:type==='end'?[]:[touch],changedTouches:[touch]}));
                    }
                } finally { SimpleGesture.doCmd=original; }
                return commands.includes('bottom');
            }}))[0]?.result;
            """, on: gestureOptions)
            XCTAssertEqual(recognized as? Bool, expected, "The remote command must change actual gesture recognition")
        }
        _ = try await runAuditJavaScript("""
        await chrome.runtime.sendMessage(destination, {command:'delete',id:'acceptance'});
        return true;
        """, on: companionOptions, arguments: arguments, timeout: 12)
        let deleted = try await runAuditJavaScript("""
        const id='$'+companion+'#acceptance', key='simple_gesture_'+id;
        const data=await chrome.storage.local.get(['simple_gesture_exdata',key]);
        return !data[key] && !data.simple_gesture_exdata?.customGestureList?.some(action=>action.id===id);
        """, on: gestureOptions, arguments: arguments)
        XCTAssertEqual(deleted as? Bool, true)

        let absent = try await runAuditJavaScript("""
        return await new Promise(resolve => chrome.runtime.sendMessage(destination, {shouldNeverReach:true}, () => {
            resolve(chrome.runtime.lastError?.message ?? '');
        }));
        """, on: companionOptions, arguments: ["destination": UUID().uuidString], timeout: 12)
        XCTAssertTrue((absent as? String)?.contains("Receiving end does not exist.") == true, String(describing: absent))

        let outsideRoot = root.appendingPathComponent("outside")
        try FileManager.default.copyItem(at: companionRoot, to: outsideRoot)
        let outside = try await service.installWebExtension(from: outsideRoot)
        defer { service.deleteWebExtension(outside.id) }
        let outsideContext = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == outside.id.uuidString })
        let outsideOptions = WKWebView(frame: window.bounds, configuration: try XCTUnwrap(outsideContext.webViewConfiguration))
        controller.view.insertSubview(outsideOptions, belowSubview: browser)
        defer { outsideOptions.stopLoading() }
        let outsideURL = try XCTUnwrap(outsideContext.optionsPageURL)
        outsideOptions.load(URLRequest(url: outsideURL))
        try await waitForAuditPage(outsideOptions, at: outsideURL, mainDocumentOnly: true)
        let refused = try await runAuditJavaScript("""
        try { await browser.runtime.sendMessage(destination, {id:storeID, shouldNeverReach:true}); return 'delivered'; }
        catch (error) { return error.message; }
        """, on: outsideOptions, arguments: ["destination": companion.id.uuidString, "storeID": storeID])
        XCTAssertEqual(refused as? String, "Could not establish connection. Receiving end does not exist.")
    }

    func testCurrentEdgeSimpleGestureViewportControls() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_SIMPLE_GESTURE_QA"] == "1", "Opt-in official Edge package")
        let source = "https://microsoftedge.microsoft.com/addons/detail/simple-gesture/hfhdokhgdkcaebhjdblfgafnimchimkd"
        let package = try await WebExtensionStoreInstallService.shared.downloadPackage(from: source)
        defer { try? FileManager.default.removeItem(at: package) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let gesture = try await service.installWebExtension(from: package)
        defer { service.deleteWebExtension(gesture.id) }
        let runtime = NativeWebExtensionRuntime.shared
        let gestureContext = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == gesture.id.uuidString })

        let pagePath = "/gesture.html"
        let fixture = try DownloadPlaybackHTTPFixture(files: [pagePath: Data("""
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><body style="min-height:4500px">Gesture page</body>
        """.utf8)])
        let address = try await fixture.start().appendingPathComponent("gesture.html")
        fixture.releaseDownloads()
        defer { fixture.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let browserConfiguration = WKWebViewConfiguration()
        runtime.apply(to: browserConfiguration)
        let browser = WKWebView(frame: window.bounds, configuration: browserConfiguration)
        let options = WKWebView(frame: window.bounds, configuration: try XCTUnwrap(gestureContext.webViewConfiguration))
        [options, browser].forEach { controller.view.addSubview($0) }
        defer { [options, browser].forEach { $0.stopLoading() }; runtime.unregister(browser) }
        runtime.register(browser)
        browser.load(URLRequest(url: address))
        let optionsURL = try XCTUnwrap(gestureContext.optionsPageURL)
        options.load(URLRequest(url: optionsURL))
        try await waitForAuditPage(browser, at: address, mainDocumentOnly: true)
        try await waitForAuditPage(options, at: optionsURL, mainDocumentOnly: true)

        func stroke() async throws -> Bool {
            let ran = try await runAuditJavaScript("""
            const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
            return (await chrome.scripting.executeScript({target:{tabId:tab.id},func:async()=>{
                await new Promise(resolve=>setTimeout(resolve,250));
                const target=document.body;
                const run=SimpleGesture.doCmd, commands=[];
                SimpleGesture.doCmd=command=>commands.push(command);
                try {
                    for(const [type,x,y] of [['start',.25,.7],['move',.72,.7],['move',.72,.25],['end',.72,.25]]){
                        const touch=new Touch({identifier:1,target,clientX:x*visualViewport.width,clientY:y*visualViewport.height});
                        target.dispatchEvent(new TouchEvent('touch'+type,{bubbles:true,cancelable:true,touches:type==='end'?[]:[touch],changedTouches:[touch]}));
                    }
                } finally {
                    SimpleGesture.doCmd=run;
                }
                return commands.includes('bottom');
            }}))[0]?.result;
            """, on: options)
            return try XCTUnwrap(ran as? Bool)
        }
        let startsEnabled = try await stroke()
        XCTAssertTrue(startsEnabled, "The fixture must recognize the default stroke")
        _ = try await runAuditJavaScript("""
        const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
        const settings=(await chrome.storage.local.get('simple_gesture')).simple_gesture;
        await chrome.storage.local.set({simple_gesture:{...settings,disableInLandscape:true,disableWhileZoomedIn:true}});
        await chrome.scripting.executeScript({target:{tabId:tab.id},func:async()=>{
            await SimpleGesture.loadIni();
            return true;
        }});
        return true;
        """, on: options)
        browser.frame.size = CGSize(width: 700, height: 390)
        try await Task.sleep(for: .milliseconds(250))
        let landscape = try await browser.evaluateJavaScript("matchMedia('(orientation: landscape)').matches") as? Bool
        XCTAssertEqual(landscape, true)
        let landscapeStroke = try await stroke()
        XCTAssertFalse(landscapeStroke)
        browser.frame = window.bounds
        try await Task.sleep(for: .milliseconds(250))
        let portraitStroke = try await stroke()
        XCTAssertTrue(portraitStroke)

        browser.scrollView.setZoomScale(1.6, animated: false)
        var scale = 1.0
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(150))
            scale = try await browser.evaluateJavaScript("visualViewport.scale") as? Double ?? 0
            if scale > 1.1 { break }
        }
        XCTAssertGreaterThan(scale, 1.1)
        let zoomedStroke = try await stroke()
        XCTAssertFalse(zoomedStroke)
        browser.scrollView.setZoomScale(1, animated: false)
        try await Task.sleep(for: .milliseconds(250))
        let unzoomedStroke = try await stroke()
        XCTAssertTrue(unzoomedStroke)
    }

    func testCurrentEdgeSimpleGestureRepairsTabActions() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_SIMPLE_GESTURE_QA"] == "1", "Opt-in official Edge package")
        let source = "https://microsoftedge.microsoft.com/addons/detail/simple-gesture/hfhdokhgdkcaebhjdblfgafnimchimkd"
        let package = try await WebExtensionStoreInstallService.shared.downloadPackage(from: source)
        defer { try? FileManager.default.removeItem(at: package) }
        let html = Data("<!doctype html><title>Gesture QA</title><body id='gesture-qa'>Test page</body>".utf8)
        let paths = ["/library/start", "/library/deferred", "/activation-marker"]
        let server = try DownloadPlaybackHTTPFixture(
            files: Dictionary(uniqueKeysWithValues: paths.map { ($0, html) }),
            responseHeaders: ["/activation-marker": ["Access-Control-Allow-Origin": "*"]]
        )
        let page = try await server.start().appendingPathComponent("library/start")
        server.releaseDownloads()
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true; previous?.makeKeyAndVisible() }

        let assertion = #"""
        const api=globalThis.browser ?? globalThis.chrome;
        const tabs=()=>api.tabs.query({});
        const active=() => api.tabs.query({active:true,currentWindow:true}).then(tabs=>tabs[0]);
        const send=(command,options={})=>api.runtime.sendMessage({command,...options});
        const check=(value,message)=>{if(!value)throw Error(message);};
        const wait=async (predicate,message)=>{
            for(let i=0;i<80;i++){
                try{if(await predicate())return;}catch(_){}
                await new Promise(resolve=>setTimeout(resolve,50));
            }
            throw Error(message);
        };
        const source=await active(), origin=new URL(source.url);
        const address=path=>new URL(path,origin).href;
        const inject=async (tab,func)=>(await api.scripting.executeScript({target:{tabId:tab},func}))[0]?.result;
        const background=url=>api.tabs.create({url,active:false});
        const markBeforeReload=()=>inject(source.id,()=>{document.body.dataset.beforeReload='1';return true;});
        const reloaded=()=>inject(source.id,()=>!!document.getElementById('gesture-qa')&&!document.body.dataset.beforeReload);
        await markBeforeReload();
        await send('toggleUserAgent',{userAgent:'Soulo Simple Gesture Network Probe',force:true});
        await wait(reloaded,'Setting User-Agent must reload the page.');
        await markBeforeReload();
        await send('toggleUserAgent',{userAgent:'Soulo Simple Gesture Revised Probe',force:true});
        await wait(reloaded,'Replacing an active User-Agent must reload the page.');
        await markBeforeReload();
        await send('toggleUserAgent',{userAgent:null,force:true});
        await wait(reloaded,'Restoring User-Agent must reload the page again.');
        const settings=(await api.storage.local.get('simple_gesture')).simple_gesture;
        await api.storage.local.set({
            simple_gesture:{...settings,openLinkInBackgroundDiscarded:true,confirmCloseTabs:false,toastForNewTabPosition:'none'},
            'simple_gesture_$test':{type:'url',currentTab:true,url:'javascript:'+encodeURIComponent("document.body.dataset.bookmarklet='ran';")}
        });
        await send('$test');
        await wait(()=>inject(source.id,()=>document.body.dataset.bookmarklet==='ran'),'Bookmarklet must run in the original tab.');

        const destination=address('/library/deferred');
        await send('openLinkInBackground',{url:destination});
        let deferred;
        await wait(async()=>deferred=(await tabs()).find(tab=>tab.url===destination),'Deferred tab was not created.');
        await new Promise(resolve=>setTimeout(resolve,250));
        check((await active()).id===source.id&&!deferred.active,'Deferred tab must remain inactive.');
        await fetch(address('/activation-marker'));
        await send('showTab',{tabId:deferred.id});
        await wait(async()=>(await active()).url===destination&&await inject(deferred.id,()=>!!document.getElementById('gesture-qa')),
            'The original deferred tab must navigate after selection.');

        const otherRoot=await background(address('/library-archive/read'));
        const otherOrigin=new URL(address('/library/other'));otherOrigin.hostname='localhost';
        const different=await background(otherOrigin.href);
        await send('closeSameUrl',{matchType:'contextRoot'});
        await wait(async()=>!(await tabs()).some(tab=>tab.id===source.id||tab.id===deferred.id),'Both tabs under the same root must close.');
        check((await tabs()).some(tab=>tab.id===otherRoot.id),'A similar path must stay open.');
        const current=await api.tabs.create({url:source.url,active:true});
        await wait(async()=>(await active()).id===current.id,'Domain source was not selected.');
        await send('closeSameUrl',{matchType:'domain'});
        await wait(async()=>!(await tabs()).some(tab=>tab.id===current.id||tab.id===otherRoot.id),'Tabs under the same origin must close.');
        check((await tabs()).some(tab=>tab.id===different.id),'A different origin must stay open.');
        return {passed:true};
        """#
        let entry = try JSONDecoder().decode(StorePackageAuditEntry.self, from: JSONSerialization.data(withJSONObject: [
            "id": "simple-gesture-tab-actions", "filename": package.lastPathComponent, "expected": "Simple Gesture",
            "surface": "options", "mainDocumentOnly": true, "assertion": assertion,
            "assertionTimeout": 25, "grantedOptionalPermissions": ["userScripts"]
        ]))
        let report = await auditStorePackage(entry, fixtureDirectory: package.deletingLastPathComponent(), pageURL: page, window: window)
        XCTAssertEqual(report["version"] as? String, "8.0")
        XCTAssertEqual(report["featurePassed"] as? Bool, true,
                       "\(report["stage"] ?? "") \(report["javascriptError"] ?? report["error"] ?? "")")
        let requests = server.receivedRequests.map(\.path)
        let activation = try XCTUnwrap(requests.firstIndex(of: "/activation-marker"))
        let navigation = try XCTUnwrap(requests.firstIndex(of: "/library/deferred"))
        XCTAssertLessThan(activation, navigation, "A background tab must not contact the destination before activation")
        let agents = server.receivedRequests.filter { $0.path == "/library/start" }.map { $0.headers["user-agent"] }
        let changed = try XCTUnwrap(agents.firstIndex(of: "Soulo Simple Gesture Network Probe"))
        let replaced = try XCTUnwrap(agents.dropFirst(changed + 1).firstIndex(of: "Soulo Simple Gesture Revised Probe"))
        let original = try XCTUnwrap(agents.first ?? nil)
        XCTAssertNotEqual(original, "Soulo Simple Gesture Network Probe")
        XCTAssertEqual(agents.dropFirst(replaced + 1).first ?? nil, original,
                       "The first main document request after disabling the rule must use the original header")
    }

    func testOptInStorePackageCompatibilityMatrix() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixtures = documents.appendingPathComponent("store-extension-matrix", isDirectory: true)
        let input = fixtures.appendingPathComponent("input.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: input.path), "Requires store packages on an isolated simulator")
        let entries = try JSONDecoder().decode([StorePackageAuditEntry].self, from: Data(contentsOf: input))
        let results = fixtures.appendingPathComponent("results.jsonl")
        try Data().write(to: results, options: .atomic)
        let resultsFile = try FileHandle(forWritingTo: results)
        defer { try? resultsFile.close() }

        let defaults = UserDefaults.standard
        let oldPrivacy = defaults.object(forKey: "is_incognito")
        let oldAdBlocking = defaults.object(forKey: "ad_block_enabled")
        defaults.set(false, forKey: "is_incognito")
        defaults.set(false, forKey: "ad_block_enabled")
        defer {
            defaults.set(oldPrivacy, forKey: "is_incognito")
            defaults.set(oldAdBlocking, forKey: "ad_block_enabled")
        }
        let html = """
        <!doctype html><title>Soulo Extension Test</title><meta name="generator" content="WordPress 6.8.1">
        <body id="audit-page" style="margin:20px;background:white;color:black">
          <article><h1>Extension Test</h1><p>Good morning from Soulo. A browser extension can read this document.</p></article>
          <img width="64" height="64" alt="A test image" src="/image.svg">
          <input id="audit-input" aria-label="Test input"><video src="/sample.mp4" controls playsinline id="audit-video"></video>
          <a href="/article.html">Local article</a><a href="/image.svg">Local image</a>
          <div style="height:1900px"></div><p id="end-marker">End of fixture</p>
        </body>
        """
        let markup = Data(html.utf8)
        let icon = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#336699"/></svg>"##.utf8)
        let sample = (try? Data(contentsOf: fixtures.appendingPathComponent("sample.mp4"))) ?? Data()
        var fixtureFiles: [String: Data] = ["/audit.html": markup, "/article.html": markup, "/image.svg": icon, "/sample.mp4": sample,
            "/ads/banner.js": Data("window.auditAdLoaded=true".utf8),
            "/ads/cbr.js": Data("window.auditAdLoaded=true".utf8)]
        var fixtureHeaders: [String: [String: String]] = [
                "/audit.html": ["Content-Type": "text/html"], "/article.html": ["Content-Type": "text/html"],
                "/ads/banner.js": ["Content-Type": "text/javascript"], "/ads/cbr.js": ["Content-Type": "text/javascript"],
                "/image.svg": ["Content-Type": "image/svg+xml"],
                "/sample.mp4": ["Content-Type": "video/mp4", "Access-Control-Allow-Origin": "*", "Access-Control-Expose-Headers": "Accept-Ranges, Content-Range"]
            ]
        for (name, mime) in [("sample.m3u8", "application/vnd.apple.mpegurl"), ("sample-segment-0.ts", "video/mp2t")] {
            if let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)) {
                fixtureFiles["/" + name] = data
                fixtureHeaders["/" + name] = ["Content-Type": mime]
            }
        }
        let server = try DownloadPlaybackHTTPFixture(files: fixtureFiles, responseHeaders: fixtureHeaders)
        let pageURL = try await server.start().appendingPathComponent("audit.html")
        server.releaseDownloads()
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true; previousWindow?.makeKeyAndVisible() }

        for entry in entries {
            try Task.checkCancellation()
            let requestOffset = server.receivedRequests.count
            var report = await auditStorePackage(entry, fixtureDirectory: fixtures, pageURL: pageURL, window: window)
            report["fixtureRequests"] = server.receivedRequests.dropFirst(requestOffset).map {
                ["method": $0.method, "path": $0.path, "range": $0.headers["range"] ?? ""]
            }
            var line = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            line.append(0x0A)
            try resultsFile.write(contentsOf: line)
            try resultsFile.synchronize()
            print("Store matrix \(entry.expected): installed=\(report["installed"] ?? false) feature=\(report["featurePassed"] ?? "unverified") \(report["error"] ?? "")")
        }
    }

    @available(iOS 18.4, *)
    private func auditStorePackage(_ entry: StorePackageAuditEntry, fixtureDirectory: URL,
                                   pageURL: URL, window: UIWindow) async -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-audit-" + UUID().uuidString)
        let managerKey = root.lastPathComponent
        let manager = TabManager(storageKey: managerKey)
        let runtime = NativeWebExtensionRuntime.shared
        runtime.attach(tabManager: manager)
        let tab = manager.createTab()
        window.rootViewController = UIHostingController(rootView: StorePackageAuditBrowser(manager: manager))
        defer {
            window.rootViewController = nil
            for tab in manager.tabs { tab.webViewModel.releaseWebViewRuntime() }
            UserDefaults.standard.removeObject(forKey: managerKey)
            try? FileManager.default.removeItem(at: root)
        }
        var report: [String: Any] = ["id": entry.id, "name": entry.expected, "installed": false]
        let downloads = DownloadManagerService.downloadsDirectory
        let initialDownloads = Set((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
        func fileSignatures() -> [[String: String]] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
            return files.filter { !initialDownloads.contains($0) }.sorted().compactMap { name in
                let file = downloads.appendingPathComponent(name)
                guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                defer { try? handle.close() }
                guard let signature = try? handle.read(upToCount: 12) else { return nil }
                return ["file": name, "signature": signature.map { String(format: "%02x", $0) }.joined()]
            }
        }
        var stage = "preview"
        do {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: managerKey))
            defer { defaults.removePersistentDomain(forName: managerKey) }
            let service = BrowserExtensionService(extensionRoot: root, updateDefaults: defaults)
            let package = fixtureDirectory.appendingPathComponent(entry.filename)
            let preview = try await service.previewWebExtension(from: package)
            defer { service.discardWebExtensionPreview(preview) }
            report["warnings"] = preview.warnings
            report["version"] = preview.version
            report["permissions"] = preview.permissions
            stage = "install"
            var access = preview.access
            for permission in entry.grantedOptionalPermissions ?? [] {
                access.setPermission(permission, allowed: true)
            }
            for permission in entry.deniedPermissions ?? [] {
                access.setPermission(permission, allowed: false)
            }
            let record = try await service.installWebExtension(preview, access: access)
            defer { service.deleteWebExtension(record.id) }
            report["installed"] = true
            report["name"] = record.name
            report["enabled"] = record.isEnabled
            let context = try XCTUnwrap(runtime.controller.extensionContexts.first { $0.uniqueIdentifier == record.id.uuidString })
            defer { report["runtimeErrors"] = context.errors.map(\.localizedDescription) }
            report["backgroundDeclared"] = context.webExtension.hasBackgroundContent
            report["preparedBackground"] = context.webExtension.manifest["background"]
            let browser: WKWebView?
            if entry.useNewTabAction == true, entry.browserSetup == nil, entry.assertInBrowser != true {
                browser = nil
            } else {
                stage = "loadFixture"
                manager.switchToTab(id: tab.id)
                tab.webViewModel.loadURL(pageURL)
                for _ in 0..<80 where tab.webViewModel.webView == nil {
                    try await Task.sleep(for: .milliseconds(35))
                }
                let page = try XCTUnwrap(tab.webViewModel.webView)
                try await waitForAuditPage(page, at: pageURL)
                runtime.activate(page)
                if let setup = entry.browserSetup {
                    stage = "browserSetup"
                    report["browserSetup"] = try await runAuditJavaScript(
                        setup, on: page, timeout: min(max(entry.browserSetupTimeout ?? 4, 4), 45)
                    )
                }
                browser = page
            }
            let embeddedProbe = entry.embeddedAssertion.map {
                StorePackageEmbeddedProbe(expectedURL: context.baseURL.appendingPathComponent($0.path))
            }
            if let embeddedProbe, let browser {
                let controller = browser.configuration.userContentController
                controller.add(embeddedProbe, name: StorePackageEmbeddedProbe.handlerName)
                controller.addUserScript(WKUserScript(source: StorePackageEmbeddedProbe.script,
                                                      injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            }
            defer {
                if embeddedProbe != nil {
                    browser?.configuration.userContentController.removeScriptMessageHandler(forName: StorePackageEmbeddedProbe.handlerName)
                }
            }
            let manifest = context.webExtension.manifest
            let action = (manifest["action"] ?? manifest["browser_action"] ?? manifest["page_action"]) as? [String: Any]
            let candidates = ["popup": action?["default_popup"] as? String,
                              "options": ((manifest["options_ui"] as? [String: Any])?["page"] ?? manifest["options_page"]) as? String,
                              "panel": (manifest["side_panel"] as? [String: Any])?["default_path"] as? String,
                              "newtab": (manifest["chrome_url_overrides"] as? [String: Any])?["newtab"] as? String].compactMapValues { $0 }
            let preferredSurface = entry.surface ?? ["popup", "options", "panel", "newtab"].first { candidates[$0]?.isEmpty == false }
            report["windowActivation"] = window.windowScene?.activationState.rawValue
            report["windowIsKey"] = window.isKeyWindow
            var extensionPage: WKWebView?
            var openedPage: WKWebView?
            defer {
                if entry.useToolbarPopup == true {
                    window.rootViewController?.presentedViewController?.dismiss(animated: false)
                } else {
                    extensionPage?.stopLoading(); extensionPage?.removeFromSuperview()
                }
            }
            if let preferredSurface, preferredSurface != "browser" {
                stage = "extensionPage"
                guard let path = entry.path ?? candidates[preferredSurface] else { throw URLError(.resourceUnavailable) }
                let pageAddress = try XCTUnwrap(URL(string: path, relativeTo: context.baseURL)?.absoluteURL)
                guard pageAddress.host == context.baseURL.host else { throw URLError(.badURL) }
                let page: WKWebView
                if preferredSurface == "newtab", entry.useNewTabAction == true {
                    service.setNewTabExtension(record.id, enabled: true)
                    let tab = manager.openNewTab(extensionService: service)
                    report["openedFromSouloNewTab"] = tab.webViewModel.currentURL == pageAddress
                    guard tab.webViewModel.currentURL == pageAddress else { throw URLError(.resourceUnavailable) }
                    for _ in 0..<160 where tab.webViewModel.webView == nil {
                        try await Task.sleep(for: .milliseconds(35))
                    }
                    page = try XCTUnwrap(tab.webViewModel.webView)
                } else if entry.useToolbarPopup == true {
                    report["actionDispatched"] = runtime.performAction(id: record.id)
                    var popup: WKWebView?
                    let timeout = min(max(entry.actionWaitSeconds ?? 2.25, 0.1), 30)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                    while ContinuousClock.now < deadline {
                        popup = firstAuditWebView(in: window.rootViewController?.presentedViewController?.view)
                        if popup?.url?.host == context.baseURL.host { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    page = try XCTUnwrap(popup)
                } else {
                    if entry.dispatchBeforeLoadingExtensionPage == true {
                        report["actionDispatched"] = runtime.performAction(id: record.id)
                    }
                    let configuration = try XCTUnwrap(context.webViewConfiguration)
                    let diagnosticSource = """
                        globalThis.auditErrors=[];
                        addEventListener('error',event=>auditErrors.push(event.message||event.target?.src||'resource error'),true);
                        addEventListener('unhandledrejection',event=>auditErrors.push(String(event.reason)));
                        """
                    configuration.userContentController.addUserScript(WKUserScript(source: diagnosticSource, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                    page = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: configuration)
                    window.rootViewController?.view.addSubview(page)
                    page.load(URLRequest(url: pageAddress))
                }
                extensionPage = page
                // Action panels may append state to their own URL. Verify
                // the document the native action actually opened.
                let actionAddress = entry.useToolbarPopup == true ? page.url : nil
                try await waitForAuditPage(page, at: actionAddress ?? pageAddress,
                    mainDocumentOnly: entry.mainDocumentOnly == true || entry.useNewTabAction == true || entry.useToolbarPopup == true)
                report["surface"] = preferredSurface
                report["rendered"] = try await runAuditJavaScript("""
                    const snapshot=()=>({title:document.title,text:(document.body?.innerText||'').trim().slice(0,500),
                      controls:document.querySelectorAll('button,input,select,textarea,[role=button],a[href]').length});
                    let state=snapshot();
                    for(let attempt=0;attempt<10&&!state.controls&&!state.text;attempt++){
                      await new Promise(resolve=>setTimeout(resolve,80));
                      state=snapshot();
                    }
                    return state;
                    """, on: page)
            }
            var actionPopup: WKWebView?
            if entry.invokeAction == true && entry.useToolbarPopup != true && entry.dispatchBeforeLoadingExtensionPage != true {
                stage = "action"
                report["actionDispatched"] = runtime.performAction(id: record.id)
                if let probe = entry.actionPopupProbe {
                    for _ in 0..<80 {
                        let popup = firstAuditWebView(in: window.rootViewController?.presentedViewController?.view)
                        if let popup, popup.url?.host == context.baseURL.host {
                            actionPopup = popup
                            report["actionPopupResult"] = try? await runAuditJavaScript(probe, on: popup)
                            break
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
            if let javascript = entry.interaction, let extensionPage {
                stage = "interaction"
                let handled = try await runAuditJavaScript(javascript, on: extensionPage) as? Bool == true
                report["interactionHandled"] = handled
                if !handled { report["featurePassed"] = false }
            }
            if let javascript = entry.assertion {
                stage = "feature"
                let surface = try XCTUnwrap(entry.surface == "browser" || entry.assertInBrowser == true ? browser : extensionPage ?? browser)
                if entry.pollAssertion == true {
                    var passed = false
                    for _ in 0..<20 {
                        if (try? await runAuditJavaScript(javascript, on: surface)) as? Bool == true { passed = true; break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    report["featurePassed"] = passed
                } else {
                    let result = try await runAuditJavaScript(javascript, on: surface,
                                                              timeout: min(max(entry.assertionTimeout ?? 4, 4), 90))
                    report["assertionResult"] = result
                    report["featurePassed"] = (result as? [String: Any])?["passed"] as? Bool == true || result as? Bool == true
                }
            }
            if let embeddedAssertion = entry.embeddedAssertion, let embeddedProbe, let browser {
                stage = "embeddedExtension"
                for _ in 0..<50 where embeddedProbe.frame == nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let frame = try XCTUnwrap(embeddedProbe.frame)
                let result = try await runAuditJavaScript(embeddedAssertion.javascript, on: browser, frame: frame,
                                                          timeout: 20)
                report["embeddedResult"] = result
                let passed = (result as? [String: Any])?["passed"] as? Bool == true || result as? Bool == true
                report["featurePassed"] = (report["featurePassed"] as? Bool ?? true) && passed
            }
            if let expectedPath = entry.openedPath {
                stage = "openedTab"
                func findOpenedTab() -> BrowserTab? {
                    manager.tabs.first {
                        guard let url = $0.webViewModel.currentURL else { return false }
                        if let host = entry.openedHTTPSHost {
                            return url.scheme == "https" && url.host == host && url.path.hasSuffix(expectedPath)
                        }
                        return url.host == context.baseURL.host && url.path == expectedPath
                    }
                }
                var openedTab = findOpenedTab()
                let timeout = min(max(entry.actionWaitSeconds ?? 4, 0.1), 30)
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                while openedTab == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                    openedTab = findOpenedTab()
                }
                report["openedExpectedTab"] = openedTab != nil
                var openedPagePassed = openedTab != nil
                if let openedTab, let script = entry.openedAssertion {
                    let url = try XCTUnwrap(openedTab.webViewModel.currentURL)
                    manager.switchToTab(id: openedTab.id)
                    for _ in 0..<80 where openedTab.webViewModel.webView == nil {
                        try await Task.sleep(for: .milliseconds(35))
                    }
                    let openedView = try XCTUnwrap(openedTab.webViewModel.webView)
                    openedPage = openedView
                    if let actionPopup {
                        report["actionAndResultShareDataStore"] =
                            actionPopup.configuration.websiteDataStore === openedView.configuration.websiteDataStore
                    }
                    try await waitForAuditPage(openedView, at: url)
                    let value = try await runAuditJavaScript(script, on: openedView,
                                                              timeout: min(max(entry.openedAssertionTimeout ?? 4, 4), 45))
                    report["openedResult"] = value
                    openedPagePassed = (value as? [String: Any])?["passed"] as? Bool == true || value as? Bool == true
                }
                report["featurePassed"] = openedPagePassed && report["featurePassed"] as? Bool != false
            }
            if let signature = entry.expectedFileSignature, let attempts = entry.downloadWaitAttempts {
                stage = "download"
                for _ in 0..<min(max(0, attempts), 100) {
                    if fileSignatures().contains(where: { $0["signature"]?.hasPrefix(signature) == true }) { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                if !fileSignatures().contains(where: { $0["signature"]?.hasPrefix(signature) == true }) {
                    report["featurePassed"] = false
                }
            }
            if report["interactionHandled"] as? Bool == false {
                report["featurePassed"] = false
            }
            if report["featurePassed"] as? Bool == false {
                if let extensionPage {
                    report["pageErrors"] = try? await runAuditJavaScript("return globalThis.auditErrors || [];", on: extensionPage)
                }
                if let openedPage {
                    report["openedDiagnostics"] = try? await runAuditJavaScript("return globalThis.auditErrors || [];", on: openedPage)
                }
                if let browser {
                    report["browserState"] = try? await runAuditJavaScript("""
                        const video=document.querySelector('video');
                        return {url:location.href,rate:video?.playbackRate,readyState:video?.readyState,
                          speedController:!!document.querySelector('vsc-controller'),body:document.body?.innerText.slice(0,220)};
                        """, on: browser)
                }
                if let popup = firstAuditWebView(in: window.rootViewController?.presentedViewController?.view) {
                    report["actionState"] = try? await runAuditJavaScript("return document.body?.innerText.slice(0,500);", on: popup)
                }
            }
            if entry.inspectPreferences == true, let options = candidates["options"],
               let pageAddress = URL(string: options, relativeTo: context.baseURL)?.absoluteURL, pageAddress.host == context.baseURL.host {
                let page: WKWebView
                if let extensionPage, entry.useToolbarPopup != true { page = extensionPage }
                else {
                    page = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: try XCTUnwrap(context.webViewConfiguration))
                    extensionPage = page
                    window.rootViewController?.view.addSubview(page)
                }
                if page.url != pageAddress { page.load(URLRequest(url: pageAddress)); try await waitForAuditPage(page, at: pageAddress) }
                report["preference"] = try? await runAuditJavaScript("""
                    const storage=globalThis.chrome?.storage;
                    if(!storage)return null;
                    const read=async()=>JSON.stringify(await Promise.all([storage.local?.get(null),storage.sync?.get(null)]));
                    const control=[...document.querySelectorAll('input[type=checkbox]')].find(input=>
                      !input.disabled&&input.closest('label')?.getBoundingClientRect().height>0&&
                      /theme|appearance|display|toolbar|dark|hide|show|color|language|badge|icon|layout/i.test(input.id+' '+input.name));
                    if(!control)return null;
                    const original=control.checked,before=await read();
                    control.click();
                    let changed=false;
                    for(let attempt=0;attempt<8;attempt++){
                      if(control.checked!==original&&await read()!==before){changed=true;break;}
                      await new Promise(resolve=>setTimeout(resolve,80));
                    }
                    if(control.checked!==original)control.click();
                    return {control:control.id||control.name,persisted:changed};
                    """, on: page)
            }
        } catch {
            report["stage"] = stage
            report["error"] = error.localizedDescription
            if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                report["javascriptError"] = message
            }
        }
        let savedFiles = fileSignatures()
        report["savedFiles"] = savedFiles
        if let signature = entry.expectedFileSignature {
            report["featurePassed"] = report["featurePassed"] as? Bool != false
                && report["error"] == nil
                && savedFiles.contains { $0["signature"]?.hasPrefix(signature) == true }
        }
        return report
    }

    private func waitForAuditPage(_ view: WKWebView, at address: URL, mainDocumentOnly: Bool = false) async throws {
        let readyState = mainDocumentOnly ? "document.readyState!=='loading'" : "document.readyState==='complete'"
        for _ in 0..<(mainDocumentOnly ? 100 : 120) {
            if mainDocumentOnly || !view.isLoading, view.url == address, (try? await runAuditJavaScript(
                "return location.href===address && \(readyState) && !!document.body;",
                on: view, arguments: ["address": address.absoluteString])) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        throw URLError(.timedOut)
    }

    private func firstAuditWebView(in view: UIView?) -> WKWebView? {
        guard let view else { return nil }
        return (view as? WKWebView) ?? view.subviews.lazy.compactMap { self.firstAuditWebView(in: $0) }.first
    }

    private func runAuditJavaScript(_ javascript: String, on view: WKWebView, arguments: [String: Any] = [:], frame: WKFrameInfo? = nil,
                                    timeout: Double = 4) async throws -> Any? {
        var output: Any?
        try await WebExtensionBackgroundStartup.wait(timeout: timeout) { done in
            view.callAsyncJavaScript(javascript, arguments: arguments, in: frame, in: .page, completionHandler: { result in
                switch result {
                case .success(let value): output = value; done(nil)
                case .failure(let error): done(error)
                }
            })
        }
        return output
    }
}

@MainActor
private final class StorePackageEmbeddedProbe: NSObject, WKScriptMessageHandler {
    static let handlerName = "souloExtensionAuditEmbeddedFrame"
    static let script = """
    if(window!==window.top&&location.protocol==='webkit-extension:')
      window.webkit.messageHandlers.\(handlerName)?.postMessage(location.pathname);
    """
    let expectedURL: URL
    private(set) var frame: WKFrameInfo?

    init(expectedURL: URL) { self.expectedURL = expectedURL }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == expectedURL.host,
              message.body as? String == expectedURL.path else { return }
        frame = message.frameInfo
    }
}

private struct StorePackageAuditBrowser: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        if let tab = manager.activeTab {
            Document(viewModel: tab.webViewModel).id(tab.id)
        }
    }

    private struct Document: View {
        @ObservedObject var viewModel: WebViewModel

        var body: some View {
            if viewModel.currentURL != nil {
                WebViewRepresentable(viewModel: viewModel)
            }
        }
    }
}

private struct StorePackageAuditEntry: Decodable {
    struct EmbeddedAssertion: Decodable {
        let path: String
        let javascript: String
    }
    let id: String
    let filename: String
    let expected: String
    let browserSetup: String?
    let browserSetupTimeout: Double?
    let surface: String?
    let path: String?
    let assertion: String?
    let assertionTimeout: Double?
    let embeddedAssertion: EmbeddedAssertion?
    let invokeAction: Bool?
    let useToolbarPopup: Bool?
    let mainDocumentOnly: Bool?
    let actionWaitSeconds: Double?
    let actionPopupProbe: String?
    let useNewTabAction: Bool?
    let dispatchBeforeLoadingExtensionPage: Bool?
    let pollAssertion: Bool?
    let interaction: String?
    let assertInBrowser: Bool?
    let openedPath: String?
    let openedHTTPSHost: String?
    let openedAssertion: String?
    let openedAssertionTimeout: Double?
    let inspectPreferences: Bool?
    let grantedOptionalPermissions: [String]?
    let deniedPermissions: [String]?
    let expectedFileSignature: String?
    let downloadWaitAttempts: Int?
}

extension ExtensionAuditTests {
    func testOptInStoreUserscripts() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixtures = documents.appendingPathComponent("store-userscript-matrix", isDirectory: true)
        let input = fixtures.appendingPathComponent("input.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: input.path), "Requires original scripts on an isolated simulator")
        let scripts = try JSONDecoder().decode([StoreUserscriptAuditEntry].self, from: Data(contentsOf: input))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let defaults = UserDefaults.standard
        let oldPrivacy = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        defer { defaults.set(oldPrivacy, forKey: "is_incognito") }
        let service = BrowserExtensionService.shared
        var results: [[String: Any]] = []
        for script in scripts {
            let managerKey = "script-audit-" + UUID().uuidString
            let manager = TabManager(storageKey: managerKey)
            var row: [String: Any] = ["name": script.filename, "installed": false]
            do {
                let record = try await service.importUserScript(from: fixtures.appendingPathComponent(script.filename), sourceURL: script.source)
                defer { service.deleteUserScript(record.id) }
                row["installed"] = true
                row["name"] = record.name
                row["patterns"] = record.matchPatterns
                let tab = manager.createTab()
                window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: tab.webViewModel))
                for _ in 0..<80 where tab.webViewModel.webView == nil { try await Task.sleep(for: .milliseconds(35)) }
                let view = try XCTUnwrap(tab.webViewModel.webView)
                view.loadSimulatedRequest(URLRequest(url: script.page), responseHTML: script.html)
                try await waitForAuditPage(view, at: script.page)
                var commands: [String] = []
                for _ in 0..<20 {
                    commands = tab.webViewModel.userScriptMenuCommands.map(\.title)
                    if !commands.isEmpty || script.requiredMenu != true { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                row["menu"] = commands
                if let text = script.selectMenuContaining {
                    let command = try XCTUnwrap(tab.webViewModel.userScriptMenuCommands.first { $0.title.contains(text) })
                    tab.webViewModel.executeUserScriptMenuCommand(command)
                    try await Task.sleep(for: .milliseconds(200))
                }
                let pageResult = try await runAuditJavaScript(script.assertion, on: view) as? Bool == true
                row["featurePassed"] = pageResult && (script.requiredMenu != true || !commands.isEmpty)
                tab.webViewModel.releaseWebViewRuntime()
            } catch {
                row["error"] = error.localizedDescription
            }
            window.rootViewController = nil
            defaults.removeObject(forKey: managerKey)
            results.append(row)
            print("Userscript matrix \(script.filename): \(row)")
        }
        let result = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try result.write(to: fixtures.appendingPathComponent("results.json"), options: .atomic)
    }
}

private struct StoreUserscriptAuditEntry: Decodable {
    let filename: String
    let source: URL
    let page: URL
    let html: String
    let assertion: String
    let requiredMenu: Bool?
    let selectMenuContaining: String?
}
