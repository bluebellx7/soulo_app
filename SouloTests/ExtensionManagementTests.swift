import XCTest
import WebKit
import JavaScriptCore
import SwiftUI
@testable import Soulo

@MainActor
final class ExtensionManagementTests: XCTestCase {
    func testOrdinaryWebsiteClearKeepsLiveExtensionDatabasesAndSettingsWithoutAMaintenancePage() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(record.id) }
        let page = try await extensionPage(context(record.id))
        _ = try await page.callAsyncJavaScript(#"""
        localStorage.setItem('fixture-pref','keep');
        await chrome.storage.local.set({fixtureSetting:'keep'});
        await new Promise((resolve,reject)=>{const r=indexedDB.open('faststream-temp-123-456',1);
        r.onupgradeneeded=()=>r.result.createObjectStore('files');
        r.onerror=()=>reject(r.error);r.onsuccess=()=>{globalThis.busyDB=r.result;resolve(true);};});
        const cache=await caches.open('fixture-active-extension');await cache.put('https://fixture.soulo.test/active',new Response('playing'));
        return true;
        """#, arguments: [:], in: nil, contentWorld: .page)
        let server=try DownloadPlaybackHTTPFixture(files:["/site.html":Data("<body id='ready'>Website clear fixture</body>".utf8)])
        let base=try await server.start();server.releaseDownloads();defer{server.stop()}
        let web=WKWebView();defer{web.stopLoading()}
        web.load(URLRequest(url:base.appendingPathComponent("site.html")))
        try await eventually { (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true }
        _ = try await web.evaluateJavaScript("localStorage.setItem('fixture-pref','remove');true")
        let start=ProcessInfo.processInfo.systemUptime
        let report=await StorageUsageService.clearWebsiteData()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start, 8, "A blocked extension database must not be probed during ordinary website cleanup")
        XCTAssertTrue(report.retainedCategories.contains(.extensions))
        let state=try await page.callAsyncJavaScript(#"""
        const writable=await new Promise((resolve,reject)=>{const t=busyDB.transaction('files','readwrite');t.objectStore('files').put('still playing','media');t.oncomplete=()=>resolve(true);t.onerror=()=>reject(t.error);});
        return {writable,local:localStorage.getItem('fixture-pref'),setting:(await chrome.storage.local.get('fixtureSetting')).fixtureSetting,caches:await caches.keys()};
        """#, arguments: [:], in: nil, contentWorld: .page) as? [String:Any]
        XCTAssertEqual(state?["writable"] as? Bool, true)
        XCTAssertEqual(state?["local"] as? String, "keep")
        XCTAssertEqual(state?["setting"] as? String, "keep")
        XCTAssertTrue((state?["caches"] as? [String] ?? []).contains("fixture-active-extension"))
        let cleared=try await web.evaluateJavaScript("localStorage.getItem('fixture-pref')")
        XCTAssertTrue(cleared is NSNull)
        _ = try await page.evaluateJavaScript("busyDB.close();busyDB=null;true")
    }

    func testMediaStartupCoverEndsForReadyMediaAndNeverKeepsRealNoSourceErrorsHidden() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native WebExtensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(record.id) }
        let native = try context(record.id)
        let markup = "document.body.innerHTML='<video style=\"position:fixed;inset:0;width:100vw;height:100vh\"></video><p id=\"no-source\">No source loaded</p>';true"
        let readyPage = try await extensionPage(native)
        let normalPage = try await readyPage.evaluateJavaScript("document.querySelector('[data-soulo-media-startup]')===null") as? Bool
        XCTAssertEqual(normalPage, true,
                       "Ordinary extension forms must stay visible")
        _ = try await readyPage.evaluateJavaScript(markup)
        try await eventually { (try? await readyPage.evaluateJavaScript("!!document.querySelector('[data-soulo-media-startup]')")) as? Bool == true }
        _ = try await readyPage.evaluateJavaScript("document.querySelector('video').dispatchEvent(new Event('loadedmetadata'));true")
        try await eventually { (try? await readyPage.evaluateJavaScript("document.querySelector('[data-soulo-media-startup]')===null")) as? Bool == true }
        let emptyPage = try await extensionPage(native)
        _ = try await emptyPage.evaluateJavaScript(markup)
        try await eventually { (try? await emptyPage.evaluateJavaScript("!!document.querySelector('[data-soulo-media-startup]')")) as? Bool == true }
        try await Task.sleep(for: .milliseconds(4200))
        let visible = try await emptyPage.evaluateJavaScript("!document.querySelector('[data-soulo-media-startup]')&&document.getElementById('no-source').textContent==='No source loaded'")
        XCTAssertEqual(visible as? Bool, true, "The startup grace period must end and leave genuine publisher diagnostics intact")
    }

    func testOptionalClipboardReadsRespectGrantAndRevocationWithoutChangingCopy() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root=try temporaryRoot(),source=try package(root)
        let manifestURL=source.appendingPathComponent("manifest.json")
        var manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        manifest["optional_permissions"]=["clipboardRead"]
        try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
        let service=BrowserExtensionService(extensionRoot:root.appendingPathComponent("store"))
        let record=try await service.installWebExtension(from:source);defer{service.deleteWebExtension(record.id)}
        let native=try context(record.id)
        let page=try await extensionPage(native,bootstrap:#"""
        globalThis.clipboardNativeReads=0;globalThis.clipboardWrites=[];
        Object.defineProperty(navigator,'clipboard',{configurable:true,value:{
          readText:()=>{clipboardNativeReads++;return Promise.resolve('fixture-only clipboard');},
          read:()=>{clipboardNativeReads++;return Promise.resolve([]);},
          writeText:value=>{clipboardWrites.push(value);return Promise.resolve();}
        }});
        """#)
        let denied=try await page.callAsyncJavaScript("try{await navigator.clipboard.readText();return 'unexpected';}catch(error){await navigator.clipboard.writeText('copy fixture');return error.name;}",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(denied as? String,"NotAllowedError")
        let initialReads=try await page.evaluateJavaScript("clipboardNativeReads") as? Int
        XCTAssertEqual(initialReads,0,"An unrelated button must not invoke the native paste prompt")
        let writes=try await page.evaluateJavaScript("JSON.stringify(clipboardWrites)") as? String
        XCTAssertEqual(writes,"[\"copy fixture\"]")
        _ = try await page.evaluateJavaScript("chrome.permissions.onRemoved.addListener(e=>{if(e.permissions.includes('clipboardRead'))window.clipboardRevoked=true;});true")
        native.setPermissionStatus(.grantedExplicitly,for:.init(rawValue:"clipboardRead"))
        try await eventually("clipboard permission grant") {
            (try? await page.callAsyncJavaScript("return await navigator.clipboard.readText();",arguments:[:],in:nil,contentWorld:.page)) as? String == "fixture-only clipboard"
        }
        native.setPermissionStatus(.unknown,for:.init(rawValue:"clipboardRead"))
        try await eventually("clipboard permission revocation") { (try? await page.evaluateJavaScript("window.clipboardRevoked===true")) as? Bool == true }
        let revoked=try await page.callAsyncJavaScript("try{await navigator.clipboard.readText();return false;}catch(error){return error.name==='NotAllowedError';}",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(revoked as? Bool,true)
        let finalReads=try await page.evaluateJavaScript("clipboardNativeReads") as? Int
        XCTAssertEqual(finalReads,1)
    }

    func testTemporaryCacheMaintenanceSharesInstalledOriginAndKeepsScriptsSettingsAndOtherExtensions() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let first = try await service.installWebExtension(from: package(root, identity: "cache-first@soulo.test"))
        let second = try await service.installWebExtension(from: package(root, identity: "cache-second@soulo.test"))
        defer { service.deleteWebExtension(first.id); service.deleteWebExtension(second.id) }
        let firstPage = try await extensionPage(context(first.id)), secondPage = try await extensionPage(context(second.id))
        let seed = #"""
        await chrome.storage.local.set({fixtureSetting:'keep'});
        const save=name=>new Promise((resolve,reject)=>{
          const r=indexedDB.open(name,1);
          r.onupgradeneeded=()=>r.result.createObjectStore('files');r.onerror=()=>reject(r.error);
          r.onsuccess=()=>{const db=r.result,t=db.transaction('files','readwrite');t.objectStore('files').put(new Blob(['fixture-media']), 'keep');t.oncomplete=()=>{db.close();resolve();};};
        });
        await save('faststream-temp-123456789-1234');
        await save('faststream-progress');await save('user-authored-scripts');
        if(globalThis.caches){const c=await caches.open('fixture-media');await c.put('https://fixture.invalid/movie',new Response('cached-media'));}
        return (await indexedDB.databases()).map(v=>v.name);
        """#
        for page in [firstPage,secondPage] {
            let names = try await page.callAsyncJavaScript(seed, arguments: [:], in: nil, contentWorld: .page) as? [String]
            XCTAssertTrue(names?.contains("faststream-temp-123456789-1234") == true)
        }
        let storageBefore=await WebsiteStorageService.entries()
        let firstSize=try XCTUnwrap(storageBefore.first{$0.domain.lowercased()==first.id.uuidString.lowercased()}?.indexedDBBytes)
        XCTAssertGreaterThan(firstSize,0,"Real extension IndexedDB files must be attributed and measured")
        try await WebExtensionTemporaryCacheProbe.clear(identifiers: [first.id])
        let check = "return {names:(await indexedDB.databases()).map(v=>v.name),setting:(await chrome.storage.local.get('fixtureSetting')).fixtureSetting,caches:globalThis.caches?await caches.keys():[]};"
        let cleaned = try await firstPage.callAsyncJavaScript(check, arguments: [:], in: nil, contentWorld: .page) as? [String:Any]
        let untouched = try await secondPage.callAsyncJavaScript(check, arguments: [:], in: nil, contentWorld: .page) as? [String:Any]
        XCTAssertFalse((cleaned?["names"] as? [String] ?? []).contains("faststream-temp-123456789-1234"))
        XCTAssertTrue((cleaned?["names"] as? [String] ?? []).contains("faststream-progress"))
        XCTAssertTrue((cleaned?["names"] as? [String] ?? []).contains("user-authored-scripts"))
        XCTAssertEqual(cleaned?["setting"] as? String,"keep")
        XCTAssertEqual(cleaned?["caches"] as? [String],[])
        XCTAssertTrue((untouched?["names"] as? [String] ?? []).contains("faststream-temp-123456789-1234"))
        XCTAssertEqual(untouched?["setting"] as? String,"keep")
        XCTAssertEqual(service.webExtensions.first(where:{$0.id == first.id})?.version,"1.0")
        let storageAfter=await WebsiteStorageService.entries()
        let cleanedSize=try XCTUnwrap(storageAfter.first{$0.domain.lowercased()==first.id.uuidString.lowercased()}?.indexedDBBytes)
        XCTAssertLessThan(cleanedSize,firstSize,"Removing a disposable database must lower the displayed disk estimate")
    }

    func testTemporaryCacheMaintenanceDoesNotForceCloseAnActiveDatabase() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(record.id) }
        let page = try await extensionPage(context(record.id))
        _ = try await page.callAsyncJavaScript("return await new Promise(resolve=>{const r=indexedDB.open('faststream-temp-123-456',1);r.onupgradeneeded=()=>r.result.createObjectStore('files');r.onsuccess=()=>{globalThis.busyDB=r.result;resolve(true);};});",arguments:[:],in:nil,contentWorld:.page)
        do { try await WebExtensionTemporaryCacheProbe.clear(identifiers:[record.id]);XCTFail("Open media buffers must report that they are in use") }
        catch is WebExtensionTemporaryCacheError { }
        let writable = try await page.callAsyncJavaScript("return await new Promise((resolve,reject)=>{const t=busyDB.transaction('files','readwrite');t.objectStore('files').put('still playing','media');t.oncomplete=()=>resolve(true);t.onerror=()=>reject(t.error);});",arguments:[:],in:nil,contentWorld:.page)
        XCTAssertEqual(writable as? Bool,true)
        _ = try await page.evaluateJavaScript("busyDB.close();busyDB=null;true")
        try await WebExtensionTemporaryCacheProbe.clear(identifiers:[record.id])
    }

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

    func testCancellingStoreDownloadInterruptsRealPendingNetworkBeforeAnyInstall() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/pending.crx": Data("fixture".utf8)], heldPaths: ["/pending.crx"])
        let address = try await server.start(); defer { server.releaseDownloads(); server.stop() }
        let package = WebExtensionRemotePackage(store: .direct, downloadURL: address.appendingPathComponent("pending.crx"), fileExtension: "crx")
        let request = Task { try await WebExtensionStoreInstallService.shared.downloadPackage(package) }
        defer { request.cancel() }
        for _ in 0..<200 {
            if server.receivedRequests.contains(where: { $0.path == "/pending.crx" }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(server.receivedRequests.contains { $0.path == "/pending.crx" })
        let started = ProcessInfo.processInfo.systemUptime
        request.cancel()
        do { let file = try await request.value; try? FileManager.default.removeItem(at: file); XCTFail("Canceled transport must not stage a package") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, String(describing: error)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started, 2.5, "Cancel must interrupt the request rather than waiting for its network timeout")
    }

    func testIdempotentPermissionUpdatesAndRejectedPersistenceSettleWithoutReinjectionLoop() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native WebExtensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(record.id) }
        let native = try context(record.id), counter = PermissionNotificationCounter()
        let names: [Notification.Name] = [WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification, WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification, WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification, WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification]
        let observers = names.map { name in NotificationCenter.default.addObserver(forName: name, object: native, queue: .main) { _ in counter.increment() } }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        try await Task.sleep(for: .milliseconds(100))
        let initial = counter.value
        for _ in 0..<10 { NativeWebExtensionRuntime.shared.applyAccess(service.webExtensionAccess(record.id), id: record.id, context: native) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.value, initial, "Equal grants must emit no changes and inject no scripts")
        let store = root.appendingPathComponent("store/extensions.json")
        let originalStore = try Data(contentsOf: store)
        defer { try? FileManager.default.removeItem(at: store); try? originalStore.write(to: store) }
        try FileManager.default.removeItem(at: store)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        native.setPermissionStatus(.deniedExplicitly, for: .tabs)
        try await eventually { native.hasPermission(.tabs) }
        let settled = counter.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.value, settled, "Rollback after a failed write must settle instead of feeding its own notifications")
        XCTAssertLessThan(counter.value-initial, 12)
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

    func testOffscreenDocumentRunsDOMMessagingAndClosesOnPermissionRevocation() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), source = try package(root)
        try Data("<html><body><div id='answer'>real DOM</div><script src='offscreen.js'></script></body></html>".utf8)
            .write(to: source.appendingPathComponent("offscreen.html"))
        try Data("""
        chrome.runtime.onMessage.addListener((message,sender,reply)=>{if(message.offscreenProbe){reply({text:document.getElementById('answer').textContent,origin:location.origin});}});
        navigator.serviceWorker.onmessage=async event=>{const value=event.data;
          event.ports[0].postMessage({text:await value.blob.text(),bytes:new Uint16Array([1,256,65535]),buffer:value.buffer,nested:value.nested});};
        """.utf8)
            .write(to: source.appendingPathComponent("offscreen.js"))
        let service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: source)
        defer { service.deleteWebExtension(record.id) }
        let context = try context(record.id), page = try await extensionPage(context)
        let result = try await page.callAsyncJavaScript("""
        await chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Local DOM fixture'});
        const contexts=await chrome.runtime.getContexts({contextTypes:['OFFSCREEN_DOCUMENT']});
        const reply=await chrome.runtime.sendMessage({offscreenProbe:true});
        const binary=await __souloOffscreenBinary({blob:new Blob(['a'.repeat(70000)+'✓'],{type:'text/plain'}),buffer:new Uint8Array([0,128,255]).buffer,nested:{__protoKey:'safe',value:null}});
        let duplicateRejected=false;
        try { await chrome.offscreen.createDocument({url:'offscreen.html',reasons:['DOM_PARSER'],justification:'Duplicate'}); }
        catch (_) { duplicateRejected=true; }
        return {reply,contexts,duplicateRejected,open:await chrome.offscreen.hasDocument(),
          binary:{text:binary.text.slice(-2),length:binary.text.length,bytes:Array.from(binary.bytes),buffer:Array.from(new Uint8Array(binary.buffer)),nested:binary.nested}};
        """, in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual((result?["reply"] as? [String: Any])?["text"] as? String, "real DOM")
        XCTAssertEqual((result?["reply"] as? [String: Any])?["origin"] as? String, String(context.baseURL.absoluteString.dropLast()))
        XCTAssertEqual((result?["contexts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(result?["duplicateRejected"] as? Bool, true)
        XCTAssertEqual(result?["open"] as? Bool, true)
        let binary = result?["binary"] as? [String: Any]
        XCTAssertEqual(binary?["text"] as? String, "a✓")
        XCTAssertEqual(binary?["length"] as? Int, 70001)
        XCTAssertEqual(binary?["bytes"] as? [Int], [1, 256, 65535])
        XCTAssertEqual(binary?["buffer"] as? [Int], [0, 128, 255])
        var access = service.webExtensionAccess(record.id)
        access.setPermission("offscreen", allowed: false)
        try service.setWebExtensionAccess(access, id: record.id)
        let rejected = try await page.callAsyncJavaScript("try { await chrome.offscreen.hasDocument(); return false; } catch (_) { return true; }", in: nil, contentWorld: .page)
        XCTAssertEqual(rejected as? Bool, true)
        access.setPermission("offscreen", allowed: true)
        try service.setWebExtensionAccess(access, id: record.id)
        let open = try await page.callAsyncJavaScript("return await chrome.offscreen.hasDocument();", in: nil, contentWorld: .page)
        XCTAssertEqual(open as? Bool, false)
        let unrelatedPage = try await extensionPage(context)
        let leakedRole = try await unrelatedPage.evaluateJavaScript("globalThis.__souloOffscreenWorkerReceiver===true") as? Bool
        XCTAssertEqual(leakedRole,false,"Offscreen setup must not leak through a shared content controller into other extension pages")
        let invalidPaths = try await page.callAsyncJavaScript("""
        const paths=['https://example.com/a.html','../offscreen.html','%2e%2e/offscreen.html','content.js'];
        return await Promise.all(paths.map(async url=>{try{await chrome.offscreen.createDocument({url,reasons:['DOM_PARSER'],justification:'Invalid path'});return false;}catch(_){return true;}}));
        """, in: nil, contentWorld: .page)
        XCTAssertEqual(invalidPaths as? [Bool], [true, true, true, true])
    }

    func testInstallationLifecyclePreservesFirstInstallUpdatesAndUninstall() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), id = UUID(), host = WebExtensionCompatibilityHost()
        defer { host.forgetInstallation(id: id) }
        func event(_ version: String) async throws -> [String: Any] {
            let object = try await WKWebExtension(resourceBaseURL: package(root, version: version))
            let context = WKWebExtensionContext(for: object); context.uniqueIdentifier = id.uuidString
            defer { host.remove(context: context) }
            var result: [String: Any]?, failure: Error?
            XCTAssertTrue(host.handle(message: ["souloCompatibility": 1, "api": "lifecycle", "operation": "installation", "details": ["reason": "install"]],
                applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier, context: context, resourceURL: nil,
                replyHandler: { value, error in result = value as? [String: Any]; failure = error }))
            XCTAssertNil(failure); return try XCTUnwrap(result)
        }
        let first = try await event("1.0")
        XCTAssertEqual(first["skip"] as? Bool, false)
        XCTAssertEqual((first["details"] as? [String: Any])?["reason"] as? String, "install")
        let duplicate = try await event("1.0")
        XCTAssertEqual(duplicate["skip"] as? Bool, true)
        let update = try await event("2.0")
        XCTAssertEqual(update["skip"] as? Bool, false)
        XCTAssertEqual((update["details"] as? [String: Any])?["reason"] as? String, "update")
        XCTAssertEqual((update["details"] as? [String: Any])?["previousVersion"] as? String, "1.0")
        host.forgetInstallation(id: id)
        let reinstalled = try await event("2.0")
        XCTAssertEqual((reinstalled["details"] as? [String: Any])?["reason"] as? String, "install")
        XCTAssertEqual(reinstalled["skip"] as? Bool, false)
        let nextObject = try await WKWebExtension(resourceBaseURL: package(root, version: "3.0"))
        let nextContext = WKWebExtensionContext(for: nextObject); nextContext.uniqueIdentifier = id.uuidString
        defer { host.remove(context: nextContext) }
        func nextEvent(_ reason: String) -> [String: Any]? {
            var result: [String: Any]?
            _ = host.handle(message: ["souloCompatibility": 1, "api": "lifecycle", "operation": "installation", "details": ["reason": reason]],
                applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier, context: nextContext, resourceURL: nil,
                replyHandler: { value, error in XCTAssertNil(error); result = value as? [String: Any] })
            return result
        }
        XCTAssertEqual((nextEvent("chrome_update")?["details"] as? [String: Any])?["reason"] as? String, "chrome_update")
        let versionUpdate = nextEvent("install")
        XCTAssertEqual(versionUpdate?["skip"] as? Bool, false, "A browser update must not consume the extension version update")
        XCTAssertEqual((versionUpdate?["details"] as? [String: Any])?["reason"] as? String, "update")
        XCTAssertEqual(nextEvent("update")?["skip"] as? Bool, true, "A repeated update must not reopen its welcome page")
        XCTAssertEqual(nextEvent("install")?["skip"] as? Bool, true)
    }

    func testGenericInstallationListenersShareVersionGateAndKeepEventMembership() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("""
        var console={error:function(){}}, nativeListeners=[], nativeMessages=[], installationDeliveries=[];
        var rawInstallationEvent={
          addListener:function(listener){if(!nativeListeners.includes(listener))nativeListeners.push(listener);},
          removeListener:function(listener){nativeListeners=nativeListeners.filter(value=>value!==listener);},
          hasListener:function(listener){return nativeListeners.includes(listener);},
          hasListeners:function(){return nativeListeners.length>0;}
        };
        var chrome={runtime:{onInstalled:rawInstallationEvent,getManifest:function(){return {};},
          sendNativeMessage:function(host,message,reply){nativeMessages.push(message);reply({skip:false,details:message.details});}}};
        var browser=chrome;
        """)
        js.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        js.evaluateScript("""
        var first=function(details){installationDeliveries.push(['first',details.reason]);};
        var second=function(details){installationDeliveries.push(['second',details.reason]);};
        chrome.runtime.onInstalled.addListener(first);
        browser.runtime.onInstalled.addListener(second);
        chrome.runtime.onInstalled.addListener(first);
        """)
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("nativeListeners.length")?.toInt32(), 1)
        XCTAssertEqual(js.evaluateScript("chrome.runtime.onInstalled.hasListener(first)&&browser.runtime.onInstalled.hasListeners()")?.toBool(), true)
        js.evaluateScript("chrome.runtime.onInstalled.removeListener(first);browser.runtime.onInstalled.removeListener(second);")
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("nativeListeners.length")?.toInt32(), 0)
        XCTAssertEqual(js.evaluateScript("chrome.runtime.onInstalled.hasListener(first)||browser.runtime.onInstalled.hasListeners()")?.toBool(), false)
        js.evaluateScript("globalThis.__souloAddInstallationListener(first);chrome.runtime.onInstalled.addListener(second);")
        XCTAssertNil(js.exception)
        XCTAssertEqual(js.evaluateScript("nativeListeners.length")?.toInt32(), 1)
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

    func testURLPermissionRetryReusesExistingGrantWithoutRenewingIt() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let root = try temporaryRoot(), service = BrowserExtensionService(extensionRoot: root.appendingPathComponent("store"))
        let record = try await service.installWebExtension(from: package(root))
        defer { service.deleteWebExtension(record.id) }
        let native = try context(record.id), runtime = NativeWebExtensionRuntime.shared
        let publicURL = URL(string: "https://public.example/video.mp4")!
        let privateURL = URL(string: "https://private.example/video.mp4")!
        let deadline = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 120)
        var access = service.webExtensionAccess(record.id)
        access.sites = ["<all_urls>": deadline]; access.blockedHosts = ["private.example"]
        try service.setWebExtensionAccess(access, id: record.id)
        var callbackRan = false
        runtime.webExtensionController(runtime.controller, promptForPermissionToAccess: [publicURL, privateURL],
                                       in: nil, for: native) { urls, expiration in
            callbackRan = true
            XCTAssertEqual(urls, [publicURL]); XCTAssertEqual(expiration, deadline)
        }
        XCTAssertTrue(callbackRan, "Previously approved sites should not open another permission prompt")
        XCTAssertEqual(service.webExtensionAccess(record.id), access)
        XCTAssertTrue(NativeWebExtensionRuntime.existingURLAccess([publicURL], context: native,
                                                                 now: deadline.addingTimeInterval(1)).urls.isEmpty)
        access.setSite("https://public.example/*", allowed: false)
        try service.setWebExtensionAccess(access, id: record.id)
        XCTAssertTrue(NativeWebExtensionRuntime.existingURLAccess([publicURL, privateURL], context: native).urls.isEmpty)
        callbackRan = false
        runtime.webExtensionController(runtime.controller, promptForPermissionToAccess:[publicURL,privateURL], in:nil, for:native) { urls, _ in
            callbackRan = true; XCTAssertTrue(urls.isEmpty)
        }
        XCTAssertTrue(callbackRan,"A denied site's automatic CORS retry must not open another prompt")
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

    func testInjectedMediaLayoutPreservesRatioAndHonorsExternalAndFixedFrames() async throws {
        let html = #"""
        <meta name="viewport" content="width=device-width"><style>
        body{margin:0;width:360px}.ratio{position:relative;width:100%;height:0;padding-top:56.25%}
        .zero{height:0}.original{position:absolute;inset:0;width:100%;height:100%}
        </style><div class="ratio"><div class="zero"><video class="original"></video></div></div>
        """#
        let server = try DownloadPlaybackHTTPFixture(files:["/index.html":Data(html.utf8),"/blank.html":Data("<body>external frame</body>".utf8)])
        let base = try await server.start();server.releaseDownloads();defer{server.stop()}
        let web=WKWebView(frame:CGRect(x:0,y:0,width:640,height:700))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let previous=scene.keyWindow,window=UIWindow(windowScene:scene)
        window.rootViewController=UIViewController();window.rootViewController?.view.addSubview(web);window.makeKeyAndVisible()
        defer{web.stopLoading();window.isHidden=true;window.rootViewController=nil;previous?.makeKeyAndVisible()}
        web.load(URLRequest(url:base.appendingPathComponent("index.html")))
        try await eventually { (try? await web.evaluateJavaScript("document.querySelector('video')?.getBoundingClientRect().height>200")) as? Bool == true }
        _ = try await web.evaluateJavaScript("globalThis.chrome={runtime:{getURL:path=>'webkit-extension://layout-fixture/'+path}};")
        _ = try await web.evaluateJavaScript(WebExtensionPackagePreparer.mediaLayoutSourceForTesting)
        let originalHeight = try await web.evaluateJavaScript("document.querySelector('video').getBoundingClientRect().height") as? Double
        XCTAssertEqual(originalHeight ?? 0,202.5,accuracy:1)
        _ = try await web.callAsyncJavaScript("window.old=document.querySelector('.zero');window.frame=document.createElement('iframe');frame.src=url;frame.style='position:relative;width:360px;height:100px;border:0';old.replaceWith(frame);return true;",arguments:["url":base.appendingPathComponent("blank.html").absoluteString],in:nil,contentWorld:.page)
        try await Task.sleep(for:.milliseconds(80))
        let externalHeight=try await web.evaluateJavaScript("frame.getBoundingClientRect().height") as? Double
        XCTAssertEqual(externalHeight ?? 0,100,accuracy:1,"Unrelated HTTP frames must retain their own layout")
        _ = try await web.evaluateJavaScript("frame.replaceWith(old);frame=document.createElement('iframe');frame.src='webkit-masked-url://hidden/';frame.style='position:relative;width:360px;height:100px;border:0';old.replaceWith(frame);true")
        try await eventually("initial replacement") { (try? await web.evaluateJavaScript("Math.abs(frame.getBoundingClientRect().height-202.5)<1")) as? Bool == true }
        _ = try await web.evaluateJavaScript("document.body.style.width='480px';true")
        try await eventually("responsive replacement") { (try? await web.evaluateJavaScript("Math.abs(frame.getBoundingClientRect().height-270)<1&&frame.getBoundingClientRect().width===480")) as? Bool == true }
        _ = try await web.evaluateJavaScript("for(const[k,v]of Object.entries({position:'fixed',width:'200px',height:'120px'}))frame.style.setProperty(k,v,'important');true")
        try await Task.sleep(for:.milliseconds(80))
        let floatingHeight=try await web.evaluateJavaScript("frame.getBoundingClientRect().height") as? Double
        XCTAssertEqual(floatingHeight ?? 0,120,accuracy:1,"A publisher's floating/full-window layout must take precedence")
        _ = try await web.evaluateJavaScript("frame.style.setProperty('position','relative','important');true")
        try await eventually("leave floating layout") { (try? await web.evaluateJavaScript("frame.getBoundingClientRect().height===270")) as? Bool == true }
        _ = try await web.callAsyncJavaScript("frame.src=url;return true;",arguments:["url":base.appendingPathComponent("blank.html").absoluteString],in:nil,contentWorld:.page)
        try await eventually("release external navigation") { (try? await web.evaluateJavaScript("frame.style.position==='relative'&&frame.getBoundingClientRect().height===100")) as? Bool == true }
        _ = try await web.evaluateJavaScript("frame.replaceWith(old);true")
        let restoredHeight=try await web.evaluateJavaScript("document.querySelector('video').getBoundingClientRect().height") as? Double
        XCTAssertEqual(restoredHeight ?? 0,270,accuracy:1,"The original page layout must remain unchanged when the frame is removed")
    }

    @available(iOS 18.4, *)
    private func extensionPage(_ context: WKWebExtensionContext, bootstrap: String? = nil) async throws -> WKWebView {
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        if let bootstrap { configuration.userContentController.addUserScript(WKUserScript(source:bootstrap,injectionTime:.atDocumentStart,forMainFrameOnly:true,in:.page)) }
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

private final class PermissionNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
