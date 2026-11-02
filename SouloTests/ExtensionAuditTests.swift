import XCTest
import JavaScriptCore
import WebKit
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
