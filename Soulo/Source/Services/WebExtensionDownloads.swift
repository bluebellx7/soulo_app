import Foundation
import Combine
import WebKit
import UIKit
import UniformTypeIdentifiers

/// Download IDs and events are scoped to the installed extension. Transfers use
/// the same native queue, cookie handling and files as the rest of the browser.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionDownloads {
    static let portIdentifier = WebExtensionCompatibilityHost.applicationIdentifier + ".downloads"
    private struct Subscription {
        let port: WKWebExtension.MessagePort
        let owner: String
        var previous: [Int: [String: Any]]
        var observer: AnyCancellable?
    }
    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    private var ownerMappings: [String: [String: String]] = [:]
    private var itemCache: [UUID: (item: BrowserDownloadItem, value: [String: Any])] = [:]
    private let dateFormatter = ISO8601DateFormatter()
    private var nativeTransfers: [UUID: WebExtensionURLDownload] = [:]
    private var documentSaves: [UUID: (owner: String, task: Task<Void, Never>)] = [:]
    private var cancellationObserver: AnyCancellable?

    init() {
        cancellationObserver = DownloadManagerService.shared.$downloads.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let items = DownloadManagerService.shared.downloads
                for transfer in Array(self.nativeTransfers.values) {
                    if let id = transfer.itemID, !items.contains(where: { $0.id == id && $0.status == .inProgress }) { transfer.cancel() }
                }
            }
        }
    }

    private func storageKey(_ owner: String) -> String { "soulo.webextension.downloads." + owner }
    private func mapping(_ owner: String) -> [String: String] {
        if let cached = ownerMappings[owner] { return cached }
        let values = UserDefaults.standard.dictionary(forKey: storageKey(owner)) as? [String: String] ?? [:]
        ownerMappings[owner] = values
        return values
    }
    private func register(_ item: BrowserDownloadItem, owner: String) -> Int {
        var values = mapping(owner)
        let id = (values.keys.compactMap(Int.init).max() ?? 0) + 1
        values[String(id)] = item.id.uuidString
        ownerMappings[owner] = values
        UserDefaults.standard.set(values, forKey: storageKey(owner))
        return id
    }
    private func ownedItem(_ id: Int, owner: String) -> BrowserDownloadItem? {
        guard let value = mapping(owner)[String(id)], let uuid = UUID(uuidString: value) else { return nil }
        return DownloadManagerService.shared.downloads.first { $0.id == uuid }
    }
    private func object(_ item: BrowserDownloadItem, id: Int) -> [String: Any] {
        if let cached = itemCache[item.id], cached.item == item { return cached.value }
        let state = item.status == .finished ? "complete" : [.failed, .canceled].contains(item.status) ? "interrupted" : "in_progress"
        var value: [String: Any] = ["id": id, "url": item.sourceURLString, "finalUrl": item.sourceURLString,
            "filename": item.localPath, "state": state, "paused": item.status == .paused,
            "bytesReceived": item.receivedBytes, "totalBytes": item.expectedBytes,
            "fileSize": item.status == .finished ? item.receivedBytes : -1,
            "exists": FileManager.default.fileExists(atPath: item.localPath), "incognito": false,
            "canResume": item.status == .paused, "danger": "safe",
            "startTime": itemCache[item.id]?.value["startTime"] ?? dateFormatter.string(from: item.startedAt)]
        if let end = item.completedAt { value["endTime"] = dateFormatter.string(from: end) }
        if let mime = UTType(filenameExtension: item.localURL.pathExtension)?.preferredMIMEType { value["mime"] = mime }
        if item.status == .canceled { value["error"] = "USER_CANCELED" }
        else if item.status == .failed { value["error"] = "NETWORK_FAILED" }
        itemCache[item.id] = (item, value)
        return value
    }
    private func snapshot(_ owner: String) -> [Int: [String: Any]] {
        let owned = mapping(owner)
        guard !owned.isEmpty else { return [:] }
        let lookup = Dictionary(uniqueKeysWithValues: DownloadManagerService.shared.downloads.map { ($0.id, $0) })
        var result: [Int: [String: Any]] = [:]
        for (key, value) in owned {
            guard let id = Int(key), let uuid = UUID(uuidString: value) else { continue }
            guard let item = lookup[uuid] else { itemCache.removeValue(forKey: uuid); continue }
            result[id] = object(item, id: id)
        }
        return result
    }
    func connect(_ port: WKWebExtension.MessagePort, owner: String, completion: @escaping (Error?) -> Void) {
        let key = ObjectIdentifier(port)
        let initial = snapshot(owner)
        subscriptions[key] = Subscription(port: port, owner: owner, previous: initial)
        port.disconnectHandler = { [weak self] _ in self?.subscriptions.removeValue(forKey: key) }
        port.messageHandler = { [weak self, weak port] _, _ in
            guard let self, let port else { return }
            port.sendMessage(["type": "snapshot", "items": Array(self.snapshot(owner).values)], completionHandler: nil)
        }
        subscriptions[key]?.observer = DownloadManagerService.shared.$downloads
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.publish(key) } }
        completion(nil)
        port.sendMessage(["type": "snapshot", "items": Array(initial.values)], completionHandler: nil)
    }
    private func created(_ item: BrowserDownloadItem, id: Int, owner: String) {
        let value = object(item, id: id)
        for key in Array(subscriptions.keys) where subscriptions[key]?.owner == owner {
            subscriptions[key]?.previous[id] = value
            subscriptions[key]?.port.sendMessage(["type": "created", "item": value], completionHandler: nil)
        }
    }
    private func publish(_ key: ObjectIdentifier) {
        guard var subscription = subscriptions[key] else { return }
        let current = snapshot(subscription.owner)
        for (id, value) in current {
            guard let previous = subscription.previous[id] else {
                subscription.port.sendMessage(["type": "created", "item": value], completionHandler: nil); continue
            }
            var delta: [String: Any] = ["id": id]
            for field in ["state", "paused", "exists", "error", "filename", "totalBytes", "fileSize"] {
                let before = previous[field] as? NSObject, after = value[field] as? NSObject
                if before != after { delta[field] = ["previous": previous[field] ?? NSNull(), "current": value[field] ?? NSNull()] }
            }
            if delta.count > 1 { subscription.port.sendMessage(["type": "changed", "delta": delta], completionHandler: nil) }
        }
        for id in subscription.previous.keys where current[id] == nil {
            subscription.port.sendMessage(["type": "erased", "id": id], completionHandler: nil)
        }
        subscription.previous = current; subscriptions[key] = subscription
    }
    func disconnect(owner: String) {
        for (id, save) in documentSaves where save.owner == owner {
            documentSaves.removeValue(forKey: id)?.task.cancel()
        }
        for key in Array(subscriptions.keys) where subscriptions[key]?.owner == owner {
            let subscription = subscriptions.removeValue(forKey: key)
            subscription?.port.disconnect()
        }
    }

    /// Observe the real download initiated by its owning iframe. Starting a
    /// Blob request in another web view loses WebKit's storage partition.
    func adoptDocumentSave(url: String, owner: String, reply: @escaping (Any?, Error?) -> Void) {
        let token = UUID(), earliest = Date().addingTimeInterval(-2)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.documentSaves.removeValue(forKey: token) }
            do {
                for _ in 0..<200 {
                    try Task.checkCancellation()
                    if let item = DownloadManagerService.shared.downloads.first(where: {
                        $0.sourceURLString == url && $0.startedAt >= earliest
                    }) {
                        let existing = self.mapping(owner).first { $0.value == item.id.uuidString }.flatMap { Int($0.key) }
                        let id = existing ?? self.register(item, owner: owner)
                        if existing == nil { self.created(item, id: id, owner: owner) }
                        reply(["id": id], nil); return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw URLError(.timedOut)
            } catch { reply(nil, error) }
        }
        documentSaves[token] = (owner, task)
    }
    func forget(owner: String) {
        disconnect(owner: owner)
        for value in mapping(owner).values { if let id = UUID(uuidString: value) { itemCache.removeValue(forKey: id) } }
        ownerMappings.removeValue(forKey: owner)
        UserDefaults.standard.removeObject(forKey: storageKey(owner))
    }

    func handle(_ values: [String: Any], context: WKWebExtensionContext, webView: WKWebView?, reply: @escaping (Any?, Error?) -> Void) {
        let owner = context.uniqueIdentifier
        switch values["operation"] as? String {
        case "reportError":
            reply(nil, Self.failure(String((values["message"] as? String ?? "Download failed.").prefix(2048))))
        case "showDefaultFolder":
            WebExtensionPopupPresenter.presentDownloadFolder(at: DownloadManagerService.downloadsDirectory) { error in
                reply(error == nil ? ["success": true] : nil, error)
            }
        case "show":
            guard let id = values["id"] as? Int, let item = ownedItem(id, owner: owner) else {
                reply(nil, Self.failure("Unknown download ID.")); return
            }
            WebExtensionPopupPresenter.presentDownloadFolder(at: item.localURL.deletingLastPathComponent()) { error in
                reply(error == nil ? ["success": true] : nil, error)
            }
        case "getFileIcon":
            guard let id = values["id"] as? Int, let item = ownedItem(id, owner: owner) else {
                reply(nil, Self.failure("Unknown download ID.")); return
            }
            let options = values["options"] as? [String: Any] ?? [:]
            let size = options["size"] as? Int ?? 32
            guard [16, 32].contains(size) else { reply(nil, Self.failure("Icon size must be 16 or 32.")); return }
            let document = UIDocumentInteractionController(url: item.localURL)
            guard let icon = document.icons.last else { reply(nil, Self.failure("The file icon is unavailable.")); return }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let extent = CGSize(width: size, height: size)
            let png = UIGraphicsImageRenderer(size: extent, format: format).pngData { _ in
                icon.draw(in: CGRect(origin: .zero, size: extent))
            }
            reply("data:image/png;base64," + png.base64EncodedString(), nil)
        case "download":
            BrowserStartupTrace.mark("extension_download_api")
            guard let options = values["options"] as? [String: Any], let text = options["url"] as? String,
                  let url = URL(string: text) else {
                reply(nil, Self.failure("This URL cannot be downloaded by the native queue.")); return
            }
            if ["blob", "data"].contains(url.scheme?.lowercased() ?? "") {
                let token = UUID()
                let transfer = WebExtensionURLDownload(url: url, filename: options["filename"] as? String,
                    accepted: { [weak self] item in
                        guard let self else { return }
                        let id = self.register(item, owner: owner)
                        self.created(item, id: id, owner: owner)
                        reply(["id": id], nil)
                    }, rejected: { error in reply(nil, error) }, ended: { [weak self] in self?.nativeTransfers.removeValue(forKey: token) })
                nativeTransfers[token] = transfer
                transfer.start(context: context, source: webView)
                return
            }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                reply(nil, Self.failure("This URL cannot be downloaded by the native queue.")); return
            }
            let method = (options["method"] as? String ?? "GET").uppercased()
            guard ["GET", "POST"].contains(method), (options["body"] as? String)?.utf8.count ?? 0 <= 1_048_576 else {
                reply(nil, Self.failure("Unsupported download request.")); return
            }
            let (item, _) = DownloadManagerService.shared.beginDownload(suggestedFilename: options["filename"] as? String ?? url.lastPathComponent, sourceURL: url, transport: .background)
            let id = self.register(item, owner: owner)
            self.created(item, id: id, owner: owner)
            reply(["id": id], nil)
            Task { @MainActor in
                var request = await WebResourceDownloadService.shared.resourceRequest(url, pageURL: webView?.url, webView: webView)
                request.httpMethod = method
                if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
                for header in options["headers"] as? [[String: String]] ?? [] {
                    guard let name = header["name"], let value = header["value"], !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else { continue }
                    request.setValue(value, forHTTPHeaderField: name)
                }
                // Request preparation may briefly need the originating webview;
                // the transfer must not retain that page or its reply handler.
                guard DownloadManagerService.shared.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }) else { return }
                Task { @MainActor in
                    do { _ = try await BackgroundDownloadService.shared.start(request: request, item: item) }
                    catch { DownloadManagerService.shared.markFailed(id: item.id, error: error) }
                }
            }
        case "search":
            let query = values["query"] as? [String: Any] ?? [:]
            // A filesystem change does not necessarily update download history.
            let candidates: [Int: [String: Any]]
            if let id = query["id"] as? Int {
                if let item = ownedItem(id, owner: owner) {
                    itemCache.removeValue(forKey: item.id); candidates = [id: object(item, id: id)]
                } else { candidates = [:] }
            } else {
                for value in mapping(owner).values { if let id = UUID(uuidString: value) { itemCache.removeValue(forKey: id) } }
                candidates = snapshot(owner)
            }
            let result = candidates.values.filter { item in
                if let id = query["id"] as? Int, item["id"] as? Int != id { return false }
                if let state = query["state"] as? String, item["state"] as? String != state { return false }
                if let exists = query["exists"] as? Bool, item["exists"] as? Bool != exists { return false }
                if let words = query["query"] as? [String], !words.allSatisfy({ word in
                    ((item["filename"] as? String ?? "") + " " + (item["url"] as? String ?? "")).localizedCaseInsensitiveContains(word)
                }) { return false }
                return true
            }.sorted { ($0["id"] as? Int ?? 0) > ($1["id"] as? Int ?? 0) }
            reply(Array(result.prefix(max(0, min(1000, query["limit"] as? Int ?? 1000)))), nil)
        case "cancel":
            guard let id = values["id"] as? Int, let item = ownedItem(id, owner: owner) else { reply(nil, Self.failure("Unknown download ID.")); return }
            DownloadManagerService.shared.markCanceled(id: item.id)
            for transfer in Array(nativeTransfers.values) where transfer.itemID == item.id { transfer.cancel() }
            BackgroundDownloadService.shared.abandon(id: item.id)
            reply(["success": true], nil)
        default: reply(nil, Self.failure("This download operation is unavailable."))
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "com.dkluge.Soulo.WebExtensionDownloads", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum WebExtensionDownloadsScript {
    static let helperFilename = "__soulo_download.html"
    /// Inserted after the native-message helper, before the publisher's scripts.
    static let javaScript = #"""
    (()=>{
      if(chrome.downloads)return;
      if(typeof chrome.runtime.getManifest!=='function')return;
      const manifest=chrome.runtime.getManifest(),declared=[...(manifest.permissions||[]),...(manifest.optional_permissions||[])];
      if(!declared.includes('downloads')){
        // Chrome packages may use a generated-Blob save as their non-Chrome
        // fallback. Keep this equivalent to saving an owned document; do not
        // expose search, events, file access, or arbitrary network downloads.
        chrome.downloads={download(options,callback){
          const pending=native({souloCompatibility:1,api:'documentDownload',options}).catch(async error=>{
            const core=globalThis.__souloFrameMessagingCore;
            if(typeof options?.url!=='string'||!options.url.startsWith('blob:'+chrome.runtime.getURL(''))||!core)throw error;
            const result=core.saveOwnedDocument?await core.saveOwnedDocument(options):await core.request(core.packet('saveDocument',{options}));
            if(result?.error)throw new Error(result.error);
            return result;
          }).then(value=>value.id);
          if(typeof callback!=='function')return pending;
          pending.then(callback,()=>native({souloCompatibility:1,api:'downloads',operation:'reportError'},callback));
        }};
        return;
      }
      const events={},api={};let port=null,ready=null;
      const emit=(key,value)=>{for(const listener of events[key]||[])try{listener(value);}catch(error){console.error(error);}};
      function connect(){
        if(ready)return ready;
        const pending=new Promise((resolve,reject)=>{
          let timer=setTimeout(()=>{const connection=port;port=null;ready=null;connection?.disconnect();reject(new Error('Download event connection timed out.'));},5000);
          try{
            const connection=chrome.runtime.connectNative(host+'.downloads');port=connection;
            connection.onMessage.addListener(message=>{
              if(message.type==='snapshot'){clearTimeout(timer);resolve();}
              if(message.type==='created')emit('onCreated',message.item);
              if(message.type==='changed')emit('onChanged',message.delta);
              if(message.type==='erased')emit('onErased',message.id);
            });
            connection.onDisconnect.addListener(()=>{clearTimeout(timer);const error=chrome.runtime.lastError;if(port===connection){port=null;ready=null;}reject(new Error(error?.message||'Download event connection closed.'));});
            connection.postMessage({operation:'snapshot'});
          }catch(error){clearTimeout(timer);port=null;ready=null;reject(error);}
        });
        ready=pending;pending.catch(()=>{if(ready===pending)ready=null;});return pending;
      }
      for(const key of ['onCreated','onChanged','onErased']){
        const listeners=new Set();events[key]=listeners;
        api[key]={addListener(listener){listeners.add(listener);connect();},removeListener(listener){listeners.delete(listener);},hasListener(listener){return listeners.has(listener);},hasListeners(){return listeners.size>0;}};
      }
      function finish(promise,callback){
        if(typeof callback!=='function')return promise;
        promise.then(callback,error=>{
          // WebKit's lastError is a native accessor. Deliver the callback in
          // the native host's error scope instead of trying to overwrite it.
          native({souloCompatibility:1,api:'downloads',operation:'reportError',message:error.message||String(error)},callback);
        });
      }
      const readResource=typeof fetch==='function'?fetch.bind(globalThis):null;
      const objectURL=globalThis.URL?.createObjectURL?.bind(URL),revokeURL=globalThis.URL?.revokeObjectURL?.bind(URL);
      api.download=function(options,callback){
        let temporaryURL;
        const pending=connect().then(async()=>{
          let request=options;
          if(typeof options?.url==='string'&&options.url.startsWith('data:')&&readResource&&objectURL){
            const blob=await (await readResource(options.url)).blob();
            temporaryURL=objectURL(blob);request={...options,url:temporaryURL};
          }
          return native({souloCompatibility:1,api:'downloads',operation:'download',options:request});
        }).then(result=>result.id).finally(()=>{if(temporaryURL)revokeURL?.(temporaryURL);});
        return finish(pending,callback);
      };
      api.search=function(query,callback){return finish(native({souloCompatibility:1,api:'downloads',operation:'search',query:query||{}}),callback);};
      api.getFileIcon=function(id,options,callback){
        if(typeof options==='function'){callback=options;options={};}
        return finish(native({souloCompatibility:1,api:'downloads',operation:'getFileIcon',id,options:options||{}}),callback);
      };
      api.cancel=function(id,callback){return finish(native({souloCompatibility:1,api:'downloads',operation:'cancel',id}).then(()=>undefined),callback);};
      api.show=function(id){
        if(!Number.isSafeInteger(id)||id<0)throw new TypeError('A valid download ID is required.');
        native({souloCompatibility:1,api:'downloads',operation:'show',id}).catch(error=>console.error('downloads.show: '+error.message));
      };
      api.showDefaultFolder=function(){
        native({souloCompatibility:1,api:'downloads',operation:'showDefaultFolder'}).catch(error=>console.error('downloads.showDefaultFolder: '+error.message));
      };
      setIfMissing(chrome,'downloads',api);
      if(root.browser&&root.browser!==chrome)setIfMissing(root.browser,'downloads',api);
    })();
    """#
}
