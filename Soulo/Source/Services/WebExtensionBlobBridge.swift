import Foundation
import WebKit

/// Blobs from another allowed origin are not fetchable from WebKit's content
/// world. Stage them on disk and stream bounded chunks through the extension's
/// background relay. Only owned extension Blobs or already granted public tabs
/// are eligible. This never proxies arbitrary network URLs.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionBlobBridge {
    private struct Entry {
        let owner: String
        let url: URL
        var touched: Date
    }
    private var entries: [String: Entry] = [:]
    private var workers: [UUID: (String, WebExtensionURLDownload)] = [:]
    private var reaper: Task<Void, Never>?

    func handle(_ values: [String: Any], context: WKWebExtensionContext, sources: [WKWebView],
                access: WebExtensionAccess?, reply: @escaping (Any?, Error?) -> Void) {
        let owner = context.uniqueIdentifier
        switch values["operation"] as? String {
        case "open":
            guard let text = values["url"] as? String, text.hasPrefix("blob:"),
                  let url = URL(string: text), let origin = URL(string: String(text.dropFirst(5))) else {
                reply(nil, URLError(.noPermissionsToReadFile)); return
            }
            func matches(_ page: URL?) -> Bool { page?.scheme == origin.scheme && page?.host == origin.host && page?.port == origin.port }
            let ownOrigin = matches(context.baseURL)
            let source = sources.first { view in
                guard let page = view.url, ["http","https"].contains(page.scheme ?? ""), matches(page),
                      view.configuration.websiteDataStore.isPersistent, access?.blocks(page) != true else { return false }
                return context.hasAccess(to: page)
            }
            guard ownOrigin || source != nil else { reply(nil, URLError(.noPermissionsToReadFile)); return }
            let token = UUID(), key = token.uuidString
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("extension-blob-" + key)
            let worker = WebExtensionURLDownload(temporaryDestination: destination, url: url, completed: { [weak self] file, mime, count in
                guard let self else { try? FileManager.default.removeItem(at: file); return }
                self.entries[key] = Entry(owner: owner, url: file, touched: Date())
                self.startReaper()
                reply(["token":key,"type":mime,"size":count], nil)
            }, rejected: { reply(nil, $0) }, ended: { [weak self] in self?.workers.removeValue(forKey: token) })
            workers[token] = (owner, worker)
            worker.start(context: context, source: source)
        case "read", "close":
            guard let key = values["token"] as? String, var entry = entries[key], entry.owner == owner else {
                reply(nil, URLError(.noPermissionsToReadFile)); return
            }
            if values["operation"] as? String == "close" {
                entries.removeValue(forKey: key); try? FileManager.default.removeItem(at: entry.url)
                reply([:], nil); return
            }
            guard let offset = values["offset"] as? NSNumber, offset.int64Value >= 0,
                  offset.doubleValue == Double(offset.int64Value) else { reply(nil, URLError(.badURL)); return }
            entry.touched = Date(); entries[key] = entry
            let file = entry.url, position = UInt64(offset.int64Value)
            Task {
                do {
                    let chunk = try await Task.detached(priority: .utility) {
                        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                        try handle.seek(toOffset: position)
                        return try handle.read(upToCount: 192 * 1024) ?? Data()
                    }.value
                    reply(["data":chunk.base64EncodedString()], nil)
                } catch { reply(nil, error) }
            }
        default: reply(nil, URLError(.unsupportedURL))
        }
    }

    func remove(owner: String) {
        for (key, entry) in entries where entry.owner == owner {
            entries.removeValue(forKey: key); try? FileManager.default.removeItem(at: entry.url)
        }
        for (_, work) in Array(workers) where work.0 == owner { work.1.cancel() }
        if entries.isEmpty { reaper?.cancel(); reaper = nil }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                for (key, entry) in self.entries where Date().timeIntervalSince(entry.touched) > 600 {
                    self.entries.removeValue(forKey: key); try? FileManager.default.removeItem(at: entry.url)
                }
                if self.entries.isEmpty { self.reaper = nil; return }
            }
        }
    }
}

enum WebExtensionBlobScript {
    static let backgroundFilename = "__soulo_blob_background.js"
    static let javaScript = #"""
    (()=>{
      const runtime=(globalThis.chrome||globalThis.browser)?.runtime;
      if(!runtime?.getURL||globalThis.__souloBlobFetchInstalled)return;
      const host='com.dkluge.Soulo.WebExtensionCompatibility';
      const request=payload=>new Promise((resolve,reject)=>{
        const done=value=>{const error=runtime.lastError;if(error)reject(new Error(error.message));else if(value?.error)reject(new Error(value.error));else resolve(value?.value??value);};
        try{
          if(typeof runtime.sendNativeMessage==='function')runtime.sendNativeMessage(host,payload,done);
          else runtime.sendMessage({__souloBlobBridge:1,payload},done);
        }catch(error){reject(error);}
      });
      Object.defineProperty(globalThis,'__souloInstallBlobRelay',{configurable:true,value:()=>{
        if(globalThis.__souloBlobRelayInstalled||!runtime.onMessage||!runtime.sendNativeMessage)return;
        globalThis.__souloBlobRelayInstalled=true;
        const add=globalThis.__souloFrameMessagingCore?.add||runtime.onMessage.addListener.bind(runtime.onMessage);
        add((message,sender,reply)=>{
          if(message?.__souloBlobBridge!==1||sender.id!==runtime.id)return;
          const payload=message.payload;
          if(payload?.api!=='blobs'||payload.souloCompatibility!==1)return;
          runtime.sendNativeMessage(host,payload,value=>{
            const error=runtime.lastError;reply(error?{error:error.message}:{value});
          });return true;
        });
      }});
      if(typeof globalThis.fetch!=='function'||typeof ReadableStream!=='function')return;
      const original=globalThis.fetch.bind(globalThis),prefix='blob:'+runtime.getURL('');
      Object.defineProperty(globalThis,'__souloBlobFetchInstalled',{value:true});
      globalThis.fetch=async function(input,options){
        const url=typeof input==='string'?input:input instanceof URL?input.href:input?.url;
        if(typeof url!=='string'||!(url.startsWith(prefix)||/^blob:https?:\/\//i.test(url)))return original(input,options);
        // Keep native fetch semantics in extension documents. Only retry the
        // WebKit cross-world restriction; unrelated requests stay native.
        try{return await original(input,options);}catch(error){
          const signal=options?.signal||input?.signal;
          if(signal?.aborted)throw signal.reason||new DOMException('Aborted','AbortError');
          const method=(options?.method||input?.method||'GET').toUpperCase();
          if(method!=='GET')throw error;
          const api=operation=>({souloCompatibility:1,api:'blobs',...operation});
          const file=await request(api({operation:'open',url}));let offset=0,closed=false;
          const close=()=>{if(closed)return;closed=true;signal?.removeEventListener('abort',abort);request(api({operation:'close',token:file.token})).catch(()=>{});};
          let controller;
          const abort=()=>{controller?.error(signal.reason||new DOMException('Aborted','AbortError'));close();};
          const body=new ReadableStream({start(value){controller=value;},async pull(value){
            try{
              if(closed)return;
              const part=await request(api({operation:'read',token:file.token,offset}));
              if(closed)return;
              const bytes=Uint8Array.from(atob(part.data),c=>c.charCodeAt(0));
              if(!bytes.length){value.close();close();return;}
              offset+=bytes.length;value.enqueue(bytes);
            }catch(error){value.error(error);close();}
          },cancel(){close();}});
          signal?.addEventListener('abort',abort,{once:true});
          if(signal?.aborted)abort();
          return new Response(body,{headers:{'Content-Type':file.type,'Content-Length':String(file.size)}});
        }
      };
    })();
    """# + #"""
    (()=>{
      const api=globalThis.chrome||globalThis.browser,runtime=api?.runtime;
      if(!runtime?.onMessage||!runtime.sendMessage||!runtime.getManifest||globalThis.__souloBlobMessagesInstalled)return;
      const manifest=runtime.getManifest(),permissions=[...(manifest.permissions||[]),...(manifest.optional_permissions||[])];
      if(!permissions.includes('downloads')||typeof Blob!=='function'||typeof URL.createObjectURL!=='function')return;
      globalThis.__souloBlobMessagesInstalled=true;
      const event=runtime.onMessage,add=event.addListener.bind(event),remove=event.removeListener.bind(event),has=event.hasListener.bind(event);
      globalThis.__souloNativeBindingsObjects?.push(event);
      const listeners=new Map(),inflight=new Map();
      const blobSize=Object.getOwnPropertyDescriptor(Blob.prototype,'size').get;
      const blobType=Object.getOwnPropertyDescriptor(Blob.prototype,'type').get;
      const tag='__soulo_blob_message_v1',reference='__soulo_blob_reference_v1';
      const envelopes=value=>value?.[tag]===1&&typeof value.id==='string';
      const isBlob=value=>{try{Reflect.apply(blobSize,value,[]);return true;}catch(_){return false;}};
      function encode(value){
        const urls=[];
        try{
          // Match the native JSON message contract, including toJSON/getters,
          // while replacing real DOM Blobs before JSON would erase their data.
          const json=JSON.stringify(value,(key,item)=>{
            if(!item||!isBlob(item))return item;
            const url=URL.createObjectURL(item);urls.push(url);
            return {[reference]:1,url,type:Reflect.apply(blobType,item,[])};
          });
          const plain=json===undefined?value:JSON.parse(json);
          const id=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),byte=>byte.toString(16).padStart(2,'0')).join('');
          return {value:urls.length?{[tag]:1,id:id(),value:plain}:plain,release:()=>urls.forEach(URL.revokeObjectURL)};
        }catch(error){urls.forEach(URL.revokeObjectURL);throw error;}
      }
      async function revive(value){
        if(!value||typeof value!=='object')return value;
        if(value[reference]===1&&typeof value.url==='string'&&value.url.startsWith('blob:')){
          const response=await fetch(value.url);
          if(!response.ok)throw new Error('Blob message could not be read.');
          const blob=await response.blob();return blob.type===value.type?blob:blob.slice(0,blob.size,value.type);
        }
        if(Array.isArray(value))return await Promise.all(value.map(revive));
        const result={};
        for(const key of Object.keys(value))Object.defineProperty(result,key,{enumerable:true,writable:true,configurable:true,value:await revive(value[key])});
        return result;
      }
      add((message,sender,respond)=>{
        if(!envelopes(message)||sender.id!==runtime.id||!listeners.size)return;
        let pending=inflight.get(message.id);
        if(!pending){pending=revive(message.value);inflight.set(message.id,pending);pending.finally(()=>setTimeout(()=>inflight.delete(message.id),1000)).catch(()=>{});}
        pending.then(value=>{
          let answered=false,waiting=false;
          const reply=result=>{if(answered)return;answered=true;respond(result);};
          for(const listener of listeners.keys())try{
            const result=listener(value,sender,reply);
            if(result?.then){waiting=true;result.then(reply,error=>reply({__souloBlobError:String(error)}));}
            else if(result===true)waiting=true;
          }catch(error){console.error(error);}
          if(!answered&&!waiting)reply(undefined);
        },error=>respond({__souloBlobError:error.message||String(error)}));
        return true;
      });
      Object.defineProperties(event,{
        addListener:{configurable:true,value:listener=>{if(listeners.has(listener))return;const wrapper=(message,sender,respond)=>{if(!envelopes(message))return listener(message,sender,respond);};listeners.set(listener,wrapper);add(wrapper);}},
        removeListener:{configurable:true,value:listener=>{const wrapper=listeners.get(listener);if(wrapper){remove(wrapper);listeners.delete(listener);}else remove(listener);}},
        hasListener:{configurable:true,value:listener=>listeners.has(listener)||has(listener)},
        hasListeners:{configurable:true,value:()=>listeners.size>0}
      });
      function install(owner,key,index,ownExtensionOnly){
        if(typeof owner?.[key]!=='function')return;
        const original=owner[key];
        Object.defineProperty(owner,key,{configurable:true,writable:true,value:function(...args){
          let position=index;
          if(ownExtensionOnly&&typeof args[0]==='string'){
            if(args[0]!==runtime.id)return Reflect.apply(original,owner,args);
            position=1;
          }
          const encoded=encode(args[position]);args[position]=encoded.value;
          const callback=typeof args.at(-1)==='function'?args.at(-1):null;
          if(callback)args[args.length-1]=function(value){encoded.release();callback(value);};
          try{
            const result=Reflect.apply(original,owner,args);
            if(!callback&&result?.then)return result.finally(encoded.release);
            return result;
          }catch(error){encoded.release();throw error;}
        }});
      }
      install(runtime,'sendMessage',0,true);
      install(api.tabs,'sendMessage',1,false);
    })();
    """#
}

enum WebExtensionTemporaryCacheError: LocalizedError {
    case inUse
    var errorDescription: String? {
        FeatureText.text("Temporary extension data is still in use. Close extension and video pages and finish downloads, then try again.")
    }
}

/// A bounded startup surface for full-page extension media applications. It
/// does not replace publisher errors, modify their text, or delay interactions.
enum WebExtensionMediaStartup {
    static let javaScript = #"""
    (()=>{
      if(typeof document==='undefined'||location.protocol!=='webkit-extension:'||globalThis.__souloMediaStartup)return;
      globalThis.__souloMediaStartup=true;
      let surface=null,video=null,finished=false;
      const stop=()=>{if(finished)return;finished=true;clearInterval(timer);clearTimeout(deadline);surface?.remove();removeEventListener('pointerdown',stop,true);removeEventListener('keydown',stop,true);};
      function check(){
        if(finished)return;
        if(video){if(!video.isConnected||video.readyState>0||video.error)stop();return;}
        for(const candidate of document.querySelectorAll('video')){
          const r=candidate.getBoundingClientRect();
          if(r.width<innerWidth*.75||r.height<innerHeight*.65||getComputedStyle(candidate).display==='none')continue;
          if(candidate.readyState>0||candidate.error){stop();return;}
          video=candidate;surface=document.createElement('div');surface.dataset.souloMediaStartup='';
          surface.style.cssText='position:fixed;inset:0;background:#101114;display:grid;place-items:center;pointer-events:none;z-index:2147483600';
          const shadow=surface.attachShadow({mode:'closed'}),progress=document.createElement('progress');
          progress.setAttribute('aria-busy','true');progress.setAttribute('aria-label',document.title||'…');
          progress.style.cssText='width:64px;height:4px;accent-color:#ddd';shadow.append(progress);
          document.documentElement.append(surface);
          for(const event of ['loadedmetadata','loadeddata','error'])video.addEventListener(event,stop,{once:true});
          break;
        }
      }
      const timer=setInterval(check,80),deadline=setTimeout(stop,4000);
      addEventListener('pointerdown',stop,true);addEventListener('keydown',stop,true);
      addEventListener('DOMContentLoaded',check,{once:true});check();
    })();
    """#
}

enum WebExtensionClipboardPolicy {
    static let javaScript = #"""
    (()=>{
      if(typeof location==='undefined'||location.protocol!=='webkit-extension:'||globalThis.__souloClipboardReadsGuarded)return;
      const api=globalThis.chrome||globalThis.browser,clipboard=globalThis.navigator?.clipboard;
      if(!api?.runtime?.getURL||!clipboard)return;
      Object.defineProperty(globalThis,'__souloClipboardReadsGuarded',{value:true});
      function permitted(){
        if(typeof api.permissions?.contains!=='function')return Promise.resolve(false);
        return new Promise(resolve=>{
          let finished=false;
          const done=value=>{if(finished)return;finished=true;clearTimeout(timer);resolve(value===true);};
          const timer=setTimeout(()=>done(false),500);
          try{
            const result=api.permissions.contains({permissions:['clipboardRead']},value=>done(!api.runtime.lastError&&value));
            if(result?.then)result.then(done,()=>done(false));
          }catch(_){done(false);}
        });
      }
      // Resolve outside a button gesture. A native permission-query round trip
      // between a rejected optional read and writeText can consume WebKit's
      // clipboard-write activation, even though the user only clicked Copy.
      let allowed=false;
      permitted().then(value=>{allowed=value;});
      api.permissions?.onAdded?.addListener?.(event=>{if(event.permissions?.includes('clipboardRead'))allowed=true;});
      api.permissions?.onRemoved?.addListener?.(event=>{if(event.permissions?.includes('clipboardRead'))allowed=false;});
      for(const method of ['read','readText']){
        const original=clipboard[method];if(typeof original!=='function')continue;
        try{Object.defineProperty(clipboard,method,{configurable:true,writable:true,value:function(...args){
          if(!allowed)return Promise.reject(new DOMException('The extension has not been granted clipboardRead permission.','NotAllowedError'));
          return Reflect.apply(original,clipboard,args);
        }});}catch(_){}
      }
    })();
    """#
}

/// A maintenance-only controller executes no publisher program and writes no
/// extension state. It uses the installed origin's website store solely to
/// clear CacheStorage and the publisher's known disposable media databases.
/// Arbitrary IndexedDB, chrome.storage, scripts and saved downloads are kept.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionTemporaryCacheProbe: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var host: UIView?

    static func clear(identifiers: Set<UUID>) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Cache maintenance", "version": "1.0"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><meta charset='utf-8'><title>Cache</title>".utf8).write(to: root.appendingPathComponent("cache.html"))
        let extensionObject = try await WKWebExtension(resourceBaseURL: root)
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = .default()
        let controller = WKWebExtensionController(configuration: configuration)
        for id in identifiers {
            try Task.checkCancellation()
            let context = WKWebExtensionContext(for: extensionObject)
            context.uniqueIdentifier = UUID().uuidString
            context.baseURL = URL(string: "webkit-extension://" + id.uuidString.lowercased() + "/")!
            try controller.load(context)
            do { try await WebExtensionTemporaryCacheProbe().run(context: context) }
            catch { try? controller.unload(context); throw error }
            try controller.unload(context)
        }
        let names = Set(identifiers.map { $0.uuidString.lowercased() })
        let dataStore = WKWebsiteDataStore.default()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: WebsiteStorageService.cacheTypes) { continuation.resume(returning: $0) }
        }
        let matching = records.filter { names.contains($0.displayName.lowercased()) }
        if !matching.isEmpty {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                dataStore.removeData(ofTypes: WebsiteStorageService.cacheTypes, for: matching) { continuation.resume() }
            }
        }
    }

    static func hasExtensionFrames(in view: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ value: Bool) { guard !finished else { return }; finished = true; continuation.resume(returning: value) }
            view.evaluateJavaScript("Array.from(document.querySelectorAll('iframe'),f=>f.src||f.getAttribute('src')||'').some(s=>/^(webkit-extension:|webkit-masked-url:)/.test(s))") { value, error in
                finish(error != nil || value as? Bool == true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(true) }
        }
    }

    private func run(context: WKWebExtensionContext) async throws {
        guard let configuration = context.webViewConfiguration else { throw URLError(.resourceUnavailable) }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            view.navigationDelegate = self; self.view = view
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
                let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
                host.isUserInteractionEnabled = false; host.accessibilityElementsHidden = true; host.clipsToBounds = true
                host.addSubview(view); window.insertSubview(host, at: 0); self.host = host
            }
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.finish(URLError(.timedOut))
            }
            view.load(URLRequest(url: context.baseURL.appendingPathComponent("cache.html")))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let blocked = try await webView.callAsyncJavaScript(Self.cleanupScript, arguments: [:], in: nil, contentWorld: .page)
                finish((blocked as? Bool) == true ? WebExtensionTemporaryCacheError.inUse : nil)
            } catch { finish(error) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    private func finish(_ error: Error?) {
        guard let continuation else { return }; self.continuation = nil
        timeout?.cancel(); timeout = nil
        view?.stopLoading(); view?.navigationDelegate = nil; view = nil
        host?.removeFromSuperview(); host = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    static let cleanupScript = #"""
    let busy=false;
    if(globalThis.caches){for(const name of await caches.keys())await caches.delete(name);}
    if(!globalThis.indexedDB)return false;
    let names=[];
    if(typeof indexedDB.databases==='function')names=(await indexedDB.databases()).map(v=>v.name);
    else {try{names=JSON.parse(localStorage.getItem('fs_temp_databases')||'[]');}catch(_){}}
    // These names are created exclusively for transient FastStream media.
    // In particular, faststream-progress and user-authored databases stay.
    const disposable=names.filter(name=>typeof name==='string'&&/^faststream-temp-(?:\d+-\d+|test)$/.test(name));
    for(const name of disposable.slice(0,2000)){
      const deleted=await new Promise((resolve,reject)=>{
        const request=indexedDB.deleteDatabase(name);
        request.onsuccess=()=>resolve(true);request.onblocked=()=>resolve(false);
        request.onerror=()=>reject(request.error||new Error('Temporary database could not be removed'));
      });
      if(!deleted)busy=true;
    }
    return busy||disposable.length>2000;
    """#
}

/// Desktop extensions often wire custom sliders and knobs to mouse events
/// only. Translate a real one-finger gesture only for such controls in the
/// extension's own document. Native form controls and touch/pointer-aware
/// controls keep WebKit's normal input behavior.
enum WebExtensionTouchInput {
    static let javaScript = #"""
    (()=>{
      if(typeof document==='undefined'||location.protocol!=='webkit-extension:'||globalThis.__souloTouchInput)return;
      Object.defineProperty(globalThis,'__souloTouchInput',{value:true});
      const add=EventTarget.prototype.addEventListener,remove=EventTarget.prototype.removeEventListener;
      const listeners=new WeakMap();
      function track(target,type,listener,added){
        if(!(target instanceof Element)||!['mousedown','touchstart','pointerdown'].includes(type)||!listener)return;
        let types=listeners.get(target);if(!types){types=new Map();listeners.set(target,types);}
        let values=types.get(type);if(!values){values=new Set();types.set(type,values);}
        if(added)values.add(listener);else values.delete(listener);
      }
      EventTarget.prototype.addEventListener=function(type,listener,options){
        const result=Reflect.apply(add,this,[type,listener,options]);track(this,type,listener,true);return result;
      };
      EventTarget.prototype.removeEventListener=function(type,listener,options){
        const result=Reflect.apply(remove,this,[type,listener,options]);track(this,type,listener,false);return result;
      };
      function eligible(event){
        for(const node of event.composedPath()){
          if(!(node instanceof Element))continue;
          if(node.matches('input,textarea,select,[contenteditable]:not([contenteditable="false"])'))return null;
          const types=listeners.get(node);
          if(types?.get('touchstart')?.size||types?.get('pointerdown')?.size)return null;
          if(types?.get('mousedown')?.size)return node;
        }
        return null;
      }
      let gesture=null;
      function mouse(type,touch,buttons){
        const g=gesture;if(!g)return;
        g.target.dispatchEvent(new MouseEvent(type,{bubbles:true,cancelable:true,composed:true,
          view:window,button:0,buttons,clientX:touch.clientX,clientY:touch.clientY,
          screenX:touch.screenX,screenY:touch.screenY}));
      }
      function hold(event){if(event.cancelable)event.preventDefault();event.stopImmediatePropagation();}
      Reflect.apply(add,window,['touchstart',event=>{
        if(!event.isTrusted||event.touches.length!==1||gesture)return;
        const control=eligible(event);if(!control)return;
        const touch=event.touches[0];
        gesture={target:event.target instanceof Element?event.target:control,id:touch.identifier,
          startX:touch.clientX,startY:touch.clientY,last:touch,moved:false};
        hold(event);mouse('mouseover',touch,0);mouse('mouseenter',touch,0);mouse('mousedown',touch,1);
      },{capture:true,passive:false}]);
      Reflect.apply(add,window,['touchmove',event=>{
        if(!gesture||!event.isTrusted)return;
        const touch=Array.from(event.touches).find(t=>t.identifier===gesture.id);if(!touch)return;
        gesture.last=touch;
        if(Math.abs(touch.clientX-gesture.startX)+Math.abs(touch.clientY-gesture.startY)>6)gesture.moved=true;
        hold(event);mouse('mousemove',touch,1);
      },{capture:true,passive:false}]);
      function finish(event){
        if(!gesture||!event.isTrusted)return;
        const touch=Array.from(event.changedTouches).find(t=>t.identifier===gesture.id);if(!touch)return;
        hold(event);mouse('mouseup',touch,0);
        if(event.type==='touchend'&&!gesture.moved)mouse('click',touch,0);
        mouse('mouseleave',touch,0);gesture=null;
      }
      Reflect.apply(add,window,['touchend',finish,{capture:true,passive:false}]);
      Reflect.apply(add,window,['touchcancel',finish,{capture:true,passive:false}]);
    })();
    """#
}

/// Limit extension-owned dialogs to the actual mobile viewport. No website
/// styles or publisher files are rewritten; common dialog markup opts in.
enum WebExtensionDialogLayout {
    static let javaScript = #"""
    (()=>{
      if(typeof document==='undefined'||location.protocol!=='webkit-extension:'||globalThis.__souloDialogLayout)return;
      globalThis.__souloDialogLayout=true;
      let scheduled=false;
      function update(){
        scheduled=false;const root=document.documentElement;if(!root)return;
        const viewport=globalThis.visualViewport;
        root.style.setProperty('--soulo-dialog-width',Math.floor(Math.min(innerWidth,viewport?.width||innerWidth))+'px');
        root.style.setProperty('--soulo-dialog-height',Math.floor(Math.min(innerHeight,viewport?.height||innerHeight))+'px');
      }
      function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(update);}}
      function install(){
        if(!document.documentElement)return;
        if(!document.getElementById('__soulo_dialog_layout')){
          const style=document.createElement('style');style.id='__soulo_dialog_layout';
          style.textContent=`
            @media(max-width:600px){
              :where(dialog,[role="dialog"],[aria-modal="true"],.swal2-popup){
                box-sizing:border-box!important;min-width:0!important;
                max-width:calc(var(--soulo-dialog-width,100vw) - 24px)!important;
                max-height:calc(var(--soulo-dialog-height,100dvh) - 24px)!important;
                overflow-y:auto!important;
              }
              .swal2-popup{width:min(32em,calc(var(--soulo-dialog-width,100vw) - 24px))!important;}
              :where(dialog,[role="dialog"],[aria-modal="true"],.swal2-popup) :where(input:not([type="checkbox"]):not([type="radio"]),textarea,select){
                box-sizing:border-box!important;min-width:0!important;max-width:100%!important;font-size:max(16px,1em);
              }
              .swal2-input,.swal2-textarea{width:calc(100% - 3em)!important;max-width:calc(100% - 3em)!important;}
              .swal2-actions{max-width:100%!important;flex-wrap:wrap!important;}
            }
          `;
          (document.head||document.documentElement).appendChild(style);
        }
        update();
      }
      addEventListener('DOMContentLoaded',install,{once:true});addEventListener('resize',schedule,{passive:true});
      globalThis.visualViewport?.addEventListener('resize',schedule,{passive:true});install();
    })();
    """#
}
