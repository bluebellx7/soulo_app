import XCTest
import WebKit
import JavaScriptCore
import SwiftUI
@testable import Soulo

@MainActor
final class ExtensionManagementTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func package(_ root: URL, version: String = "1.0", identity: String = "fixture@soulo.test") throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Management fixture", "version": version, "description": "Extension management regression",
            "permissions": ["storage", "tabs", "offscreen"], "optional_permissions": ["cookies"],
            "host_permissions": ["<all_urls>"], "browser_specific_settings": ["gecko": ["id": identity]],
            "options_ui": ["page": "page.html"],
            "content_scripts": [["matches": ["https://example.com/*"], "js": ["content.js"]]],
            "commands": ["test": ["description": "Test command"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("manifest.json"))
        try Data("globalThis.__fixtureLoaded=true;".utf8).write(to: url.appendingPathComponent("content.js"))
        try Data("<html><head></head><body id='ready'>Fixture</body></html>".utf8).write(to: url.appendingPathComponent("page.html"))
        return url
    }

    @available(iOS 18.4, *)
    private func context(_ id: UUID) throws -> WKWebExtensionContext {
        try XCTUnwrap(NativeWebExtensionRuntime.shared.controller.extensionContexts.first { $0.uniqueIdentifier == id.uuidString })
    }

    func testPreviewDoesNotLoadAndCancelRemovesStagedResources() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let before = NativeWebExtensionRuntime.shared.controller.extensionContexts.count
        let preview = try await service.previewWebExtension(from: package(root))
        XCTAssertTrue(preview.permissions.contains("offscreen"))
        XCTAssertTrue(preview.sites.contains("https://example.com/*"))
        XCTAssertTrue(preview.warnings.contains("commands"))
        XCTAssertTrue(service.webExtensions.isEmpty)
        XCTAssertEqual(NativeWebExtensionRuntime.shared.controller.extensionContexts.count, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.resourceURL.path))
        service.discardWebExtensionPreview(preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.resourceURL.path))
        do { _ = try await service.installWebExtension(preview, access: preview.access); XCTFail("Canceled preview must not install") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUpdateAndRollbackKeepIdentityDecisionsAndExtensionStorage() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), store = root.appendingPathComponent("store")
        let service = BrowserExtensionService(extensionRoot: store)
        let first = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(first.id) }
        var decisions = service.webExtensionAccess(first.id)
        decisions.setPermission("tabs", allowed: false)
        decisions.blockedHosts.insert("private.example")
        try service.setWebExtensionAccess(decisions, id: first.id)
        var page: WKWebView? = try await extensionPage(context(first.id))
        let commands = try await page!.evaluateJavaScript("typeof chrome.commands.onCommand.addListener")
        XCTAssertEqual(commands as? String, "function")
        _ = try await page!.callAsyncJavaScript("await browser.storage.local.set({answer:42}); return true;", in: nil, contentWorld: .page)
        let baseURL = try context(first.id).baseURL
        page?.stopLoading(); page = nil
        let preview = try await service.previewWebExtension(from: package(root, version: "2.0"))
        XCTAssertEqual(preview.replacingID, first.id)
        XCTAssertEqual(preview.access, decisions)
        let second = try await service.installWebExtension(preview, access: preview.access)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.installedAt, first.installedAt)
        XCTAssertEqual(second.previousVersion?.version, "1.0")
        XCTAssertEqual(service.webExtensions.count, 1)
        XCTAssertEqual(try context(first.id).baseURL, baseURL)
        XCTAssertFalse(try context(first.id).hasPermission(.tabs))
        page = try await extensionPage(context(first.id))
        let stored = try await page!.callAsyncJavaScript("return (await browser.storage.local.get('answer')).answer;", in: nil, contentWorld: .page)
        XCTAssertEqual(stored as? Int, 42)
        page?.stopLoading(); page = nil
        let rollback = try await service.previewPreviousWebExtension(first.id)
        let restored = try await service.installWebExtension(rollback, access: rollback.access)
        XCTAssertEqual(restored.id, first.id)
        XCTAssertEqual(restored.version, "1.0")
        XCTAssertEqual(restored.previousVersion?.version, "2.0")
        XCTAssertEqual(service.webExtensionAccess(first.id), decisions)
        // Recreating the store exercises the launch migration for versioned paths.
        NativeWebExtensionRuntime.shared.unload(id: first.id)
        let reopened = BrowserExtensionService(extensionRoot: store)
        try await eventually {
            reopened.loadingWebExtensions.isEmpty && NativeWebExtensionRuntime.shared.controller.extensionContexts.contains { $0.uniqueIdentifier == first.id.uuidString }
        }
        XCTAssertEqual(reopened.webExtensions.first?.storedResourceName, restored.storedResourceName)
        XCTAssertEqual(reopened.webExtensionAccess(first.id), decisions)
        XCTAssertFalse(try context(first.id).hasAccess(to: URL(string: "https://sub.private.example/")!))
    }

    func testFailedUpgradeRestoresWorkingContextAndStoreAndStalePreviewCannotReplaceIt() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), store = root.appendingPathComponent("store")
        let service = BrowserExtensionService(extensionRoot: store)
        let first = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(first.id) }
        let preview = try await service.previewWebExtension(from: package(root, version: "2.0"))
        let jsonURL = store.appendingPathComponent("extensions.json"), saved = try Data(contentsOf: jsonURL)
        try FileManager.default.removeItem(at: jsonURL)
        try FileManager.default.createDirectory(at: jsonURL, withIntermediateDirectories: true)
        do { _ = try await service.installWebExtension(preview, access: preview.access); XCTFail("A store write failure must fail the upgrade") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(service.webExtensions.first?.version, "1.0")
        XCTAssertEqual(try context(first.id).webExtension.version, "1.0")
        try FileManager.default.removeItem(at: jsonURL); try saved.write(to: jsonURL, options: .atomic)
        let stale = try await service.previewWebExtension(from: package(root, version: "2.0"))
        let latest = try await service.installWebExtension(from: package(root, version: "3.0"))
        do { _ = try await service.installWebExtension(stale, access: stale.access); XCTFail("Stale preview must not overwrite a later version") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        service.discardWebExtensionPreview(stale)
        XCTAssertEqual(service.webExtensions.first?.version, latest.version)
        XCTAssertEqual(try context(first.id).webExtension.version, "3.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("WebExtensions/" + first.id.uuidString + "/" + first.storedResourceName).path))
    }

    func testRevocationHostBlockingAndDynamicPermissionChangesPersist() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let first = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(first.id) }
        var access = service.webExtensionAccess(first.id)
        access.setPermission("tabs", allowed: false); access.setPermission("offscreen", allowed: false)
        access.blockedHosts = ["private.example"]
        try service.setWebExtensionAccess(access, id: first.id)
        let native = try context(first.id)
        XCTAssertFalse(native.hasPermission(.tabs))
        XCTAssertTrue(native.hasAccess(to: URL(string: "https://public.example/")!))
        for site in ["https://private.example/", "http://sub.private.example/"] {
            XCTAssertFalse(native.hasAccess(to: URL(string: site)!))
        }
        let blockedPattern = try WKWebExtension.MatchPattern(string: "https://private.example/*")
        native.setPermissionStatus(.grantedExplicitly, for: blockedPattern)
        try await eventually { !native.hasAccess(to: URL(string: "https://private.example/")!) }
        var denied: Error?
        let host = WebExtensionCompatibilityHost()
        XCTAssertTrue(host.handle(message: ["souloCompatibility": 1, "api": "audio", "operation": "stop"],
            applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier, context: native,
            resourceURL: root, access: access) { _, error in denied = error })
        XCTAssertNotNil(denied)
        native.setPermissionStatus(.grantedExplicitly, for: .cookies)
        try await eventually { service.webExtensionAccess(first.id).allowsPermission("cookies") }
        native.setPermissionStatus(.unknown, for: .cookies)
        try await eventually { !service.webExtensionAccess(first.id).allowsPermission("cookies") }
        service.setWebExtensionEnabled(first.id, enabled: false)
        service.setWebExtensionEnabled(first.id, enabled: true)
        try await eventually { !service.loadingWebExtensions.contains(first.id) }
        XCTAssertFalse(try context(first.id).hasPermission(.tabs))
        XCTAssertFalse(try context(first.id).hasAccess(to: URL(string: "https://private.example/")!))
    }

    func testStorageIsAtomicAndFailedPersistenceDoesNotBroadcast() throws {
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root)
        let script = try service.saveUserScript(id: nil, fallbackName: "Storage", source: "// @name Storage\nvoid 0;", explicitPatterns: ["*://*/*"], injectionTime: .documentStart)
        var received: [[String: Any]] = []
        let token = NotificationCenter.default.addObserver(forName: .userScriptStorageChanged, object: service, queue: .main) {
            if let snapshot = $0.userInfo as? [String: Any] { received.append(snapshot) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try service.setStoredValues(["key": #"{"value":1}"#], scriptID: script.id, origin: "tab1", mutationID: "1")
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0]["origin"] as? String, "tab1")
        let jsonURL = root.appendingPathComponent("extensions.json")
        try FileManager.default.removeItem(at: jsonURL)
        try FileManager.default.createDirectory(at: jsonURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.setStoredValues(["key": #"{"value":2}"#], scriptID: script.id))
        XCTAssertThrowsError(try service.deleteStoredValuesPersisting(forKeys: ["key"], scriptID: script.id))
        XCTAssertEqual(service.userScript(id: script.id)?.storedValues?["key"], #"{"value":1}"#)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(service.storageSnapshot(scriptID: script.id)["revision"] as? Int, 1)
    }

    func testPreviewCannotRestorePermissionsRevokedAfterReviewStarted() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let first = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(first.id) }
        let preview = try await service.previewWebExtension(from: package(root, version: "2.0"))
        defer { service.discardWebExtensionPreview(preview) }
        var access = service.webExtensionAccess(first.id)
        access.setPermission("tabs", allowed: false)
        try service.setWebExtensionAccess(access, id: first.id)
        do { _ = try await service.installWebExtension(preview, access: preview.access); XCTFail("A stale review must not restore revoked access") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(try context(first.id).hasPermission(.tabs))
        XCTAssertEqual(service.webExtensions.first?.version, "1.0")
    }

    func testScriptSaveToggleAndDeletePreserveStateWhenPersistenceFails() throws {
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root)
        let first = try service.saveUserScript(id: nil, fallbackName: "Original", source: "void 0;", explicitPatterns: ["*://*/*"], injectionTime: nil)
        service.reportUserScriptError("original execution failure", scriptID: first.id)
        let store = root.appendingPathComponent("extensions.json")
        try FileManager.default.removeItem(at: store)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.saveUserScript(id: first.id, fallbackName: "Changed", source: "void 1;", explicitPatterns: ["*://*/*"], injectionTime: nil))
        XCTAssertEqual(service.userScript(id: first.id)?.source, first.source)
        XCTAssertEqual(service.userScriptRuntimeErrors[first.id], "original execution failure")
        service.setUserScriptEnabled(first.id, enabled: false)
        XCTAssertEqual(service.userScript(id: first.id)?.isEnabled, true)
        service.deleteUserScript(first.id)
        XCTAssertNotNil(service.userScript(id: first.id))
        XCTAssertNotNil(service.userScriptErrors[first.id])
    }

    func testDisabledExtensionUpdateStaysOffAndFailedDeleteKeepsResources() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), store = root.appendingPathComponent("store")
        let service = BrowserExtensionService(extensionRoot: store)
        let first = try await service.installWebExtension(from: package(root))
        defer { NativeWebExtensionRuntime.shared.unload(id: first.id) }
        service.setWebExtensionEnabled(first.id, enabled: false)
        let updated = try await service.installWebExtension(from: package(root, version: "2.0"))
        XCTAssertEqual(updated.id, first.id)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertFalse(NativeWebExtensionRuntime.shared.controller.extensionContexts.contains { $0.uniqueIdentifier == first.id.uuidString })
        let jsonURL = store.appendingPathComponent("extensions.json")
        try FileManager.default.removeItem(at: jsonURL)
        try FileManager.default.createDirectory(at: jsonURL, withIntermediateDirectories: true)
        service.setWebExtensionEnabled(first.id, enabled: true)
        XCTAssertFalse(service.webExtensions.first?.isEnabled ?? true)
        service.deleteWebExtension(first.id)
        XCTAssertNotNil(service.webExtensions.first { $0.id == first.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent("WebExtensions/" + first.id.uuidString + "/" + updated.storedResourceName).path))
        XCTAssertNotNil(service.webExtensionErrors[first.id])
    }

    func testBlockedHostInputKeepsOnlyValidWebHostsAndIncludesSubdomains() {
        XCTAssertEqual(WebExtensionAccess.normalizedHost(" HTTPS://Example.COM./ "), "example.com")
        for input in ["", "*.example.com", "user@example.com", "https://example.com:123", "example.com/path", "file:///etc/passwd", "example.com?query=1"] {
            XCTAssertNil(WebExtensionAccess.normalizedHost(input), input)
        }
        var access = WebExtensionAccess(); access.blockedHosts = ["example.com"]
        XCTAssertTrue(access.blocks(URL(string: "https://sub.example.com/")!))
        XCTAssertFalse(access.blocks(URL(string: "https://otherexample.com/")!))
    }

    func testStorageSnapshotsPreservePendingWritesAndIgnoreOutdatedReplies() throws {
        let js = try XCTUnwrap(JSContext())
        let id = UUID()
        let script = UserScriptRecord(id: id, name: "Storage", source: "", grants: ["GM_getValue", "GM.setValue", "GM_addValueChangeListener"])
        js.evaluateScript("""
        var window=globalThis, console={error:function(){}}, resolvers={}, events=[];
        var webkit={messageHandlers:{souloUserScriptAPI:{postMessage:function(p){
          if(p.action==='getStorageSnapshot')return Promise.resolve({revision:0,values:{}});
          return new Promise(function(resolve){resolvers[p.__souloMutationID]=resolve;});
        }}}};
        """)
        js.evaluateScript(UserScriptRuntime.compatibilityBootstrap(bridgeToken: "tab1", script: script))
        js.evaluateScript("GM_addValueChangeListener('key',function(k,a,b,r){events.push([b,r]);}); var pending=GM.setValue('key',1);")
        func send(_ value: Int, revision: Int, origin: String, mutation: String = "") throws {
            let source = try XCTUnwrap(UserScriptRuntime.storageUpdateScript(["scriptID":id.uuidString,
                "values":["key":"{\"value\":\(value)}"], "revision":revision,"origin":origin,"mutationID":mutation], bridgeToken: "tab1"))
            js.evaluateScript(source)
            XCTAssertNil(js.exception)
        }
        try send(2, revision: 1, origin: "tab2")
        XCTAssertEqual(js.evaluateScript("GM_getValue('key')")?.toInt32(), 1, "Pending write must stay visible")
        try send(1, revision: 2, origin: "tab1", mutation: "1")
        try send(3, revision: 3, origin: "tab2")
        js.evaluateScript("resolvers['1']({revision:2,origin:'tab1',mutationID:'1',values:{key:'{\"value\":1}'}});")
        XCTAssertEqual(js.evaluateScript("GM_getValue('key')")?.toInt32(), 3)
        XCTAssertEqual(js.evaluateScript("JSON.stringify(events)")?.toString(), "[[1,false],[3,true]]")
        try send(99, revision: 4, origin: "tab2")
        XCTAssertEqual(js.evaluateScript("GM_getValue('key')")?.toInt32(), 99)
        js.evaluateScript("window.__souloReceiveUserScriptStorage({scriptID:'\(id.uuidString)',token:'wrong',revision:5,values:{}});")
        XCTAssertEqual(js.evaluateScript("GM_getValue('key')")?.toInt32(), 99)
    }

    func testCompatibilityDoesNotRewriteThirdPartySourceAndCommandsRegistrationIsSafe() throws {
        let root = try temporaryRoot(), source = try package(root)
        let original = #"const text='.commands.onCommand.addListener'; chrome.commands.onCommand.addListener(()=>{});"#
        try Data(original.utf8).write(to: source.appendingPathComponent("content.js"))
        let destination = root.appendingPathComponent("prepared")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let prepared = try WebExtensionPackagePreparer.prepare(sourceURL: source, in: destination)
        XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("content.js"), encoding: .utf8), original)
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("var chrome={runtime:{getManifest:function(){return {};}}}; var console={error:function(){}};")
        js.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        js.evaluateScript(original)
        XCTAssertNil(js.exception)
    }

    func testRealTabsShareStorageAndReportScriptErrorsThroughProductionBridge() async throws {
        let defaults = UserDefaults.standard, previousPrivate = defaults.object(forKey: "is_incognito")
        defaults.set(false, forKey: "is_incognito")
        defer { defaults.set(previousPrivate, forKey: "is_incognito") }
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data("<html><body id='ready'>Storage</body></html>".utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let service = BrowserExtensionService.shared
        let source = """
        // ==UserScript==
        // @name Tab storage regression
        // @match http://127.0.0.1/*
        // @grant GM_getValue
        // @grant GM.setValue
        // @grant GM.deleteValue
        // @grant GM_addValueChangeListener
        // ==/UserScript==
        window.storageEvents=[];
        GM_addValueChangeListener('key',function(k,a,b,r){window.storageEvents.push([b===undefined?'deleted':b,r]);});
        window.readFixture=function(){return GM_getValue('key','missing');};
        window.writeFixture=function(value){return GM.setValue('key',value).then(function(){return true;});};
        window.deleteFixture=function(){return GM.deleteValue('key').then(function(){return true;});};
        window.scriptInstance=String(Math.random());
        window.scriptReady=true;
        """
        let script = try service.saveUserScript(id: nil, fallbackName: "Storage regression", source: source,
            explicitPatterns: nil, injectionTime: .documentEnd)
        defer { service.deleteUserScript(script.id) }
        let models = [WebViewModel(), WebViewModel()]
        let coordinators = models.map(WebViewRepresentable.Coordinator.init)
        let webs = zip(models, coordinators).map { model, coordinator in
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: "souloUserScriptAPI")
            configuration.userContentController.addUserScript(WKUserScript(source: UserScriptRuntime.wrappedSource(for: script,
                bridgeToken: coordinator.userScriptBridgeToken), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
            let web = AccessibleWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
            model.webView = web; web.navigationDelegate = coordinator
            return web
        }
        defer {
            for web in webs { web.stopLoading(); web.navigationDelegate = nil; web.configuration.userContentController.removeAllScriptMessageHandlers() }
            models.forEach { $0.webView = nil }
        }
        for (index, web) in webs.enumerated() {
            web.load(URLRequest(url: root.appendingPathComponent("page.html")))
            do {
                try await eventually { (try? await web.evaluateJavaScript("window.scriptReady===true")) as? Bool == true }
            } catch {
                let state = try? await web.evaluateJavaScript("JSON.stringify({url:location.href,ready:document.readyState,body:document.body?.innerHTML,scriptReady:window.scriptReady})")
                print("Storage fixture tab \(index) state: \(String(describing: state)), navigation error: \(String(describing: models[index].errorMessage)), script error: \(String(describing: service.userScriptRuntimeErrors[script.id]))")
                throw error
            }
        }
        _ = try await webs[0].callAsyncJavaScript("return await window.writeFixture(42);", in: nil, contentWorld: .page)
        try await eventually("remote write") { (try? await webs[1].evaluateJavaScript("readFixture()===42")) as? Bool == true }
        let localEvents = try await webs[0].evaluateJavaScript("JSON.stringify(storageEvents)") as? String
        let remoteEvents = try await webs[1].evaluateJavaScript("JSON.stringify(storageEvents)") as? String
        XCTAssertEqual(localEvents, "[[42,false]]")
        XCTAssertEqual(remoteEvents, "[[42,true]]")
        _ = try await webs[1].callAsyncJavaScript("return await window.deleteFixture();", in: nil, contentWorld: .page)
        try await eventually("remote delete") { (try? await webs[0].evaluateJavaScript("readFixture()==='missing'")) as? Bool == true }
        let deleteEvents = try await webs[0].evaluateJavaScript("JSON.stringify(storageEvents)") as? String
        XCTAssertEqual(deleteEvents, "[[42,false],[\"deleted\",true]]")
        // A later navigation must compile the latest stored values rather than the initial snapshot.
        _ = try await webs[0].callAsyncJavaScript("return await window.writeFixture(99);", in: nil, contentWorld: .page)
        let rawInstance = try await webs[1].evaluateJavaScript("window.scriptInstance") as? String
        let instance = try XCTUnwrap(rawInstance)
        webs[1].reload()
        try await eventually("reloaded snapshot") { (try? await webs[1].evaluateJavaScript("window.scriptReady===true && scriptInstance!=='\(instance)' && readFixture()===99")) as? Bool == true }
        var failing = script; failing.source = "throw new Error('fixture-script-failure');"
        _ = try await webs[0].evaluateJavaScript(UserScriptRuntime.wrappedSource(for: failing, bridgeToken: coordinators[0].userScriptBridgeToken))
        try await eventually("runtime error") { service.userScriptRuntimeErrors[script.id]?.contains("fixture-script-failure") == true }
        _ = try service.saveUserScript(id: script.id, fallbackName: script.name, source: source, explicitPatterns: nil, injectionTime: .documentEnd)
        XCTAssertNil(service.userScriptRuntimeErrors[script.id])
    }

    func testReviewAndManagementViewsRenderInChineseAndEnglish() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService.shared
        let preview = try await service.previewWebExtension(from: package(root, identity: UUID().uuidString + "@soulo.test"))
        let record = try await service.installWebExtension(preview, access: preview.access)
        defer { service.deleteWebExtension(record.id) }
        var access = service.webExtensionAccess(record.id)
        access.blockedHosts = ["private.example"]
        try service.setWebExtensionAccess(access, id: record.id)
        let review = try await service.previewWebExtension(from: package(root, version: "2.0"), replacing: record.id)
        defer { service.discardWebExtensionPreview(review) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let previousLanguage = LanguageManager.shared.currentLanguage
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible(); LanguageManager.shared.currentLanguage = previousLanguage }
        for language in ["zh-Hans", "en-US"] {
            LanguageManager.shared.currentLanguage = language
            for reviewPage in [true, false] {
                let view = reviewPage ? AnyView(WebExtensionReviewView(preview: review) { _ in })
                    : AnyView(NavigationStack { WebExtensionManagementView(id: record.id) })
                window.rootViewController = UIHostingController(rootView: view.environment(\.dynamicTypeSize, .large))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(400))
                let rendered = try XCTUnwrap(window.rootViewController?.view)
                rendered.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: rendered.bounds).image { _ in rendered.drawHierarchy(in: rendered.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "extensions-\(reviewPage ? "review" : "manage")-\(language)"
                attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThan(image.size.height, 400)
            }
        }
    }

    @available(iOS 18.4, *)
    private func extensionPage(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        web.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        try await eventually { (try? await web.evaluateJavaScript("!!document.getElementById('ready') && typeof browser !== 'undefined'")) as? Bool == true }
        return web
    }

    private func eventually(_ label: String = "condition", _ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Condition did not become true: " + label)
        throw URLError(.timedOut)
    }
}
