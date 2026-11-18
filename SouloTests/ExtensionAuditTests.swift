import XCTest
import JavaScriptCore
import WebKit
import UIKit
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

    func testStaticClassicBackgroundPreservesProgramAndPermissionsWithoutVersionSpecificEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), script = "/* Initial imports */\nif(typeof Settings === 'undefined'){importScripts('/js/library.js');}\nvar result=Settings.answer;"
        try FileManager.default.createDirectory(at: source.appendingPathComponent("js"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: source.appendingPathComponent("js/worker.js"))
        try Data("var Settings={answer:42};".utf8).write(to: source.appendingPathComponent("js/library.js"))
        let manifest: [String: Any] = ["manifest_version":3,"name":"Generic background fixture","version":"1.0", "permissions":["storage"], "background":["service_worker":"js/worker.js"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("installed"), withIntermediateDirectories: true)
        let prepared = try WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("installed"))
        let manifestURL = prepared.appendingPathComponent("manifest.json")
        let first = try Data(contentsOf: manifestURL)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let background = try XCTUnwrap(result["background"] as? [String: Any])
        XCTAssertNil(background["service_worker"])
        XCTAssertEqual((background["scripts"] as? [String])?.suffix(2), ["js/library.js","js/worker.js"])
        XCTAssertEqual(result["permissions"] as? [String], ["storage"], "Basic bindings must not add nativeMessaging access")
        XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("js/worker.js"), encoding: .utf8), script)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("js/worker.js"), encoding: .utf8), script)
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
        XCTAssertEqual(try Data(contentsOf: manifestURL), first)
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
        // This regression covers migration of native worker wrappers. A worker
        // without imports retains that path rather than becoming an event page.
        try Data("globalThis.__workerAnswer=42;".utf8).write(to: source.appendingPathComponent("background/worker.js"))
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
        let scripts = try XCTUnwrap((manifest["background"] as? [String: Any])?["scripts"] as? [String])
        XCTAssertEqual(Array(scripts.suffix(2)), ["background/helper.js", "background/worker.js"])
        let context = try XCTUnwrap(JSContext())
        let resolve: @convention(block) (String, String) -> String = { path, base in
            URL(string: path, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? ""
        }
        context.setObject(resolve, forKeyedSubscript: "__resolve" as NSString)
        context.evaluateScript("function URL(path,base){this.href=__resolve(path,base)};var chrome={runtime:{getURL:path=>'webkit-extension://fixture/'+path}};var console={error:function(){}};")
        for path in scripts { context.evaluateScript(try String(contentsOf: prepared.appendingPathComponent(path), encoding: .utf8)) }
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
        for api in ["notifications", "audio", "downloads"] {
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
        let background = try XCTUnwrap(manifest["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], ["__soulo_blob_background.js", "__soulo_webextension_compatibility.js", "background.js"])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertNil(background["service_worker"])
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

    func testWildcardPortsAreNormalizedWithoutBroadeningFixedPortsOrChangingSource() throws {
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
        let prepared = try WebExtensionPackagePreparer.prepare(sourceURL: source, in: root.appendingPathComponent("store"))
        let preparedManifest = prepared.appendingPathComponent("manifest.json")
        let first = try Data(contentsOf: preparedManifest)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual((result["externally_connectable"] as? [String: Any])?["matches"] as? [String],
                       ["http://localhost/*", "https://192.168.0.2/*", "*://*.example.com/allowed/*",
                        "https://example.com:8443/*", "https://example.com/*", "ftp://example.com:*/*"])
        XCTAssertEqual(result["permissions"] as? [String], ["storage"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.appendingPathComponent("__soulo_webextension_compatibility.js").path))
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: prepared)
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
            "background": ["scripts": ["background.js"], "persistent": false],
            "externally_connectable": ["matches": ["http://localhost:*/*"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try Data("chrome.runtime.onMessageExternal.addListener((message,sender,reply)=>{reply({pong:message.ping});});chrome.storage.local.set({ready:true});".utf8)
            .write(to: package.appendingPathComponent("background.js"))
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
    }
}
