import XCTest
import JavaScriptCore
import WebKit
import UIKit
@testable import Soulo

@MainActor
final class ExtensionAuditTests: XCTestCase {
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

    private func context(grants: [String], storedValues: [String: String] = [:]) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window = globalThis;
        var location = {href:'https://example.com/'};
        var console = {error:function(){},log:function(){}};
        var __reject = false;
        var __apiReplies = [];
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

    func testExistingBackgroundWrapperMigrationIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let prepared = try WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifestURL = prepared.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["background"] = ["service_worker":"__soulo_webextension_background_v3.js"]
        try Data(#"importScripts("__soulo_webextension_compatibility.js", "background/worker.js");"#.utf8)
            .write(to: prepared.appendingPathComponent("__soulo_webextension_background_v3.js"))
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        let first = try Data(contentsOf: manifestURL)
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
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

    func testPreparedClassicWorkerKeepsItsOriginalRelativeImportDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let prepared = try WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: prepared.appendingPathComponent("manifest.json"))) as? [String: Any])
        let path = try XCTUnwrap((manifest["background"] as? [String: Any])?["service_worker"] as? String)
        let entryURL = prepared.appendingPathComponent(path)
        XCTAssertEqual(entryURL.deletingLastPathComponent().lastPathComponent, "background")
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var chrome={runtime:{}}; var console={error:function(){}};")
        let load: @convention(block) (String) -> Void = { [weak context] path in
            guard let context else { return }
            let url = URL(string: path, relativeTo: entryURL)!.absoluteURL
            do { context.evaluateScript(try String(contentsOf: url, encoding: .utf8)) }
            catch { context.exception = JSValue(newErrorFromMessage: "Missing relative import: \(path)", in: context) }
        }
        context.setObject(load, forKeyedSubscript: "__load" as NSString)
        context.evaluateScript("function importScripts(){for(var i=0;i<arguments.length;i++)__load(arguments[i]);}")
        context.evaluateScript(try String(contentsOf: entryURL, encoding: .utf8))
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("globalThis.__workerAnswer")?.toInt32(), 42)
    }

    func testManifestResourceTraversalCannotModifyFilesOutsideThePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root, popup: "../outside.html")
        let install = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let outside = install.appendingPathComponent("outside.html")
        let original = "<html><head></head><body>Unrelated file</body></html>"
        try Data(original.utf8).write(to: outside)
        XCTAssertThrowsError(try WebExtensionPackagePreparer.prepare(sourceURL: source, in: install))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), original)
    }

    func testDirectoryPackagesRejectSymbolicLinksOutsideTheirResourceRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try package(root: root)
        let outside = root.appendingPathComponent("outside.html")
        let original = "<html><head></head><body>Outside</body></html>"
        try Data(original.utf8).write(to: outside)
        try FileManager.default.removeItem(at: source.appendingPathComponent("popup.html"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("popup.html"), withDestinationURL: outside)
        XCTAssertThrowsError(try WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed")))
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
        for api in ["notifications", "audio"] {
            var failure: Error?
            var replied = false
            XCTAssertTrue(host.handle(message: ["souloCompatibility":1,"api":api,"operation":"stop"], applicationIdentifier: WebExtensionCompatibilityHost.applicationIdentifier, context: context, resourceURL: root) { _, error in replied=true; failure=error })
            XCTAssertTrue(replied)
            XCTAssertNotNil(failure)
            XCTAssertTrue(failure?.localizedDescription.contains("permission") == true)
        }
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
        XCTAssertEqual((manifest["content_scripts"] as? [[String: Any]])?.filter { $0["js"] as? [String] == ["page.js", "content.js"] }.count, 1)
        let worker = preview.resourceURL.appendingPathComponent("background.js")
        let source = try String(contentsOf: worker, encoding: .utf8)
        XCTAssertTrue(source.contains("globalThis.__souloAddInstallationListener(e)"))
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: preview.resourceURL)
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
}
