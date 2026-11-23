import CryptoKit
import Foundation
import WebKit

/// Blobs from another allowed origin are not fetchable from WebKit's content
/// world. Stage them on disk and stream bounded chunks through the extension's
/// background relay. Only owned extension Blobs or already granted public tabs
/// are eligible. This never proxies arbitrary network URLs.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionBlobBridge {
    private final class WeakBridge {
        weak var value: WebExtensionBlobBridge?
        init(_ value: WebExtensionBlobBridge) { self.value = value }
    }
    private static var liveBridges: [WeakBridge] = []
    init() {
        Self.liveBridges.removeAll { $0.value == nil }
        Self.liveBridges.append(WeakBridge(self))
    }
    /// Blob reads reopen their file between chunks, so descriptor inspection
    /// alone cannot identify an active extension lease.
    static var retainedTemporaryURLs: [URL] {
        liveBridges.compactMap(\.value).flatMap { bridge in
            bridge.entries.values.map(\.url) + bridge.workers.values.compactMap { $0.1.retainedTemporaryFileURL }
        }
    }
    private struct Entry {
        let owner: String
        let url: URL
        let isCapture: Bool
        let size: Int64
        var touched: Date
    }
    private var entries: [String: Entry] = [:]
    private var workers: [UUID: (String, WebExtensionURLDownload)] = [:]
    private var reaper: Task<Void, Never>?
    private static let captureByteLimit: Int64 = 96 * 1024 * 1024

    func handle(_ values: [String: Any], context: WKWebExtensionContext, sources: [WKWebView],
                access: WebExtensionAccess?, ownedCaptureOnly: Bool = false,
                reply: @escaping (Any?, Error?) -> Void) {
        let owner = context.uniqueIdentifier
        switch values["operation"] as? String {
        case "open":
            guard let text = values["url"] as? String, text.hasPrefix("blob:"),
                  let url = URL(string: text), let origin = URL(string: String(text.dropFirst(5))) else {
                reply(nil, URLError(.noPermissionsToReadFile)); return
            }
            func matches(_ page: URL?) -> Bool { page?.scheme == origin.scheme && page?.host == origin.host && page?.port == origin.port }
            let ownOrigin = matches(context.baseURL)
            if ownedCaptureOnly && !ownOrigin { reply(nil, URLError(.noPermissionsToReadFile)); return }
            let source = sources.first { view in
                guard let page = view.url, ["http","https"].contains(page.scheme ?? ""), matches(page),
                      view.configuration.websiteDataStore.isPersistent, access?.blocks(page) != true else { return false }
                return context.hasAccess(to: page)
            }
            guard ownOrigin || source != nil else { reply(nil, URLError(.noPermissionsToReadFile)); return }
            let token = UUID(), key = token.uuidString
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("extension-blob-" + key)
            let worker = WebExtensionURLDownload(temporaryDestination: destination, url: url,
                byteLimit: ownedCaptureOnly ? Self.captureByteLimit : nil, completed: { [weak self] file, mime, count in
                guard let self else { try? FileManager.default.removeItem(at: file); return }
                if ownedCaptureOnly {
                    let reserved = self.entries.values.filter { $0.owner == owner && $0.isCapture }
                        .reduce(0) { $0 + $1.size }
                    guard count > 0, count <= Self.captureByteLimit, reserved + count <= Self.captureByteLimit else {
                        try? FileManager.default.removeItem(at: file)
                        reply(nil, URLError(.dataLengthExceedsMaximum)); return
                    }
                }
                self.entries[key] = Entry(owner: owner, url: file, isCapture: ownedCaptureOnly, size: count, touched: Date())
                self.startReaper()
                reply(["token":key,"type":mime,"size":count], nil)
            }, rejected: { reply(nil, $0) }, ended: { [weak self] in self?.workers.removeValue(forKey: token) })
            workers[token] = (owner, worker)
            worker.start(context: context, source: source)
        case "read", "close":
            guard let key = values["token"] as? String, var entry = entries[key],
                  entry.owner == owner, entry.isCapture == ownedCaptureOnly else {
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

/// Restore a capture when WebKit presents the result in another data partition.
enum WebExtensionGoFullPageAdapter {
    static let manifestKey = "__soulo_go_full_page_capture_handoff"
    private static let module = "popup.88c38d4b.js"
    private static let moduleHash = "f070000932c31767f578e26a808c39ab761d76193b148176646cb06f07f60515"
    private static let insertionPoint = "const m=new WeakMap,y=new WeakMap,"
    private static let adapterStart = "const m=new WeakMap,y=new WeakMap;\n/* Soulo capture handoff */\n"
    private static let adapterEnd = "\n/* End Soulo capture handoff */\nconst "

    static func prepare(in root: URL, manifest: inout [String: Any]) throws {
        manifest.removeValue(forKey: manifestKey)
        guard manifest["version"] as? String == "8.11",
              let popup = (manifest["action"] as? [String: Any])?["default_popup"] as? String,
              popup == "popup.html",
              (manifest["permissions"] as? [String])?.contains("unlimitedStorage") == true else { return }
        let url = root.appendingPathComponent(module)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else { return }
        var publisher = current
        if let start = publisher.range(of: adapterStart),
           let end = publisher.range(of: adapterEnd, range: start.upperBound..<publisher.endIndex) {
            publisher.replaceSubrange(start.lowerBound..<end.upperBound, with: insertionPoint)
        }
        guard SHA256.hash(data: Data(publisher.utf8)).map({ String(format: "%02x", $0) }).joined() == moduleHash,
              let marker = publisher.range(of: insertionPoint) else { return }
        var prepared = publisher
        prepared.replaceSubrange(marker, with: adapterStart + script + adapterEnd)
        if current != prepared {
            try Data(prepared.utf8).write(to: url, options: .atomic)
        }
        manifest[manifestKey] = true
    }

    private static let script = #"""
    (() => {
      const isPopup = location.pathname === '/popup.html';
      const isCapture = location.pathname === '/capture.html';
      if (!isPopup && !isCapture) return;
      const runtime = globalThis.chrome?.runtime, storage = globalThis.chrome?.storage?.local;
      if (!runtime?.sendNativeMessage || !storage) return;
      const storagePrefix = '__souloGoFullPageCapture.';
      const indexKey = storagePrefix + 'index';
      const parameter = 'souloCapture';
      const retained = 5 * 60 * 1000;
      const pending = new Map(), tickets = new WeakMap();
      const request = values => new Promise((resolve, reject) => runtime.sendNativeMessage(
        'com.dkluge.Soulo.WebExtensionCompatibility', {souloCompatibility: 1, api: 'ownedCapture', ...values},
        value => {
          const error = runtime.lastError?.message || value?.error;
          if (error) reject(new Error(error));
          else resolve(value?.value ?? value);
        }
      ));
      const close = file => request({operation: 'close', token: file.token}).catch(() => {});
      const get = async key => (await storage.get(key))[key];
      async function stage(blob) {
        const url = URL.createObjectURL(blob);
        try { return await request({operation: 'open', url}); }
        finally { URL.revokeObjectURL(url); }
      }
      async function read(file) {
        const parts = [];
        for (let offset = 0; offset < file.size;) {
          const result = await request({operation: 'read', token: file.token, offset});
          const bytes = Uint8Array.from(atob(result.data), value => value.charCodeAt(0));
          if (!bytes.length || offset + bytes.length > file.size) throw new Error('Incomplete screenshot');
          parts.push(bytes);
          offset += bytes.length;
        }
        return new Blob(parts, {type: file.type});
      }
      if (isPopup) {
        const save = p.prototype.save;
        const display = Object.getOwnPropertyDescriptor(p.prototype, 'displayURL');
        Object.defineProperty(p.prototype, 'displayURL', {...display, get() {
          const source = display.get.call(this);
          const ticket = tickets.get(this);
          if (!ticket) return source;
          const url = new URL(source);
          url.searchParams.set(parameter, ticket);
          return url.href;
        }});
        p.prototype.save = async function(...arguments_) {
          const hasNewImages = m.has(this);
          const result = await save.apply(this, arguments_);
          const images = hasNewImages ? y.get(this) : null;
          if (!images?.length || images.reduce((total, blob) => total + blob.size, 0) > 96 * 1024 * 1024) return result;
          const files = [];
          try {
            for (const image of images) files.push(await stage(image));
            const ticket = crypto.randomUUID(), time = Date.now();
            const index = await get(indexKey) || [];
            const recent = index.filter(item => time - item.time <= retained);
            const expired = index.filter(item => time - item.time > retained).map(item => storagePrefix + item.ticket);
            await storage.set({
              [storagePrefix + ticket]: {time, capture: JSON.parse(JSON.stringify(this)), files},
              [indexKey]: [...recent, {time, ticket}]
            });
            tickets.set(this, ticket);
            if (expired.length) await storage.remove(expired).catch(() => {});
          } catch (_) {
            await Promise.all(files.map(close));
          }
          return result;
        };
        return;
      }
      const lookup = p.lookup;
      p.lookup = async function(id) {
        const ticket = new URLSearchParams(location.search).get(parameter);
        if (!ticket || !/^[0-9a-f-]{36}$/i.test(ticket)) return lookup.call(this, id);
        if (pending.has(ticket)) return pending.get(ticket);
        const promise = (async () => {
          const existing = await lookup.call(this, id);
          const stored = await get(storagePrefix + ticket).catch(() => null);
          if (!stored || Date.now() - stored.time > retained ||
              stored.capture.id !== Number(id)) return existing;
          try {
            const capture = {...stored.capture, time: new Date(stored.capture.time)};
            if (existing?.url === capture.url && existing.time?.getTime() === capture.time.getTime() &&
                (await existing._indexeddb_getBlobs(true)).length === stored.files.length) return existing;
            if (existing && (existing.url !== capture.url || existing.time?.getTime() !== capture.time.getTime())) delete capture.id;
            const blobs = await Promise.all(stored.files.map(read));
            const key = await d.transaction('rw', d.captures, d.captureBlobs, async () => {
              const key = await d.captures.put(capture);
              await d.captureBlobs.bulkPut(blobs.map((blob, index) => ({captureId: key, index, blob, size: blob.size})));
              return key;
            });
            if (key !== Number(id)) {
              const address = new URL(location.href);
              address.searchParams.set('id', key);
              address.searchParams.delete(parameter);
              history.replaceState(null, '', address.href);
            }
            return lookup.call(this, key);
          } catch (_) {
            return existing;
          } finally {
            await Promise.all(stored.files.map(close));
            await storage.remove(storagePrefix + ticket).catch(() => {});
          }
        })();
        pending.set(ticket, promise);
        return promise;
      };
    })();
    """#
}

/// Quick Snip's embedded editor sees its own partition of IndexedDB. Keep the
/// active capture in the publisher's background database when editing in a frame.
enum WebExtensionQuickSnipAdapter {
    private static let editorPath = "view/library.html"
    private static let storePath = "scripts/blobDb.js"
    private static let filename = "__soulo_quick_snip_capture.js"
    private static let storeHash = "d803d3261f550e8efd677a372e31482cdb33cb5637558f5da23bea848aa0c309"

    static func eventPageScripts(worker: URL, manifest: [String: Any]) -> [String]? {
        // The worker can idle while the user draws a selection. WebKit reliably
        // delivers the resulting region request to the same program as an event page.
        guard worker.lastPathComponent == "mainServiceWorker.js",
              manifest["version"] as? String == "1.6.2",
              let source = try? String(contentsOf: worker, encoding: .utf8),
              SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined()
                == "82ce675f61dc49638214e750ce3643d9d68c2fccae4b23bf8141ea303574c9d1",
              let expression = try? NSRegularExpression(pattern: #""([^"]+\.js)""#) else { return nil }
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    static func prepare(in root: URL, manifest: [String: Any]) throws -> String {
        guard let popup = (manifest["action"] as? [String: Any])?["default_popup"] as? String,
              popup.drop(while: { $0 == "/" }) == "view/popup.html",
              (manifest["permissions"] as? [String])?.contains("unlimitedStorage") == true,
              let store = try? Data(contentsOf: root.appendingPathComponent(storePath)),
              SHA256.hash(data: store).map({ String(format: "%02x", $0) }).joined() == storeHash else { return "" }

        let editorURL = root.appendingPathComponent(editorPath)
        guard var html = try? String(contentsOf: editorURL, encoding: .utf8),
              let scriptTag = html.range(of: "<script src=\"/\(storePath)\"></script>") else { return "" }

        try Data(javaScript.utf8).write(to: root.appendingPathComponent(filename), options: .atomic)
        if !html.contains(filename) {
            html.insert(contentsOf: "\n<script src=\"/\(filename)\"></script>", at: scriptTag.upperBound)
            try Data(html.utf8).write(to: editorURL, options: .atomic)
        }
        try enableTouchSelection(in: root)
        return "\n" + javaScript
    }

    private static func enableTouchSelection(in root: URL) throws {
        let url = root.appendingPathComponent("content/dynamic.js")
        guard let current = try? String(contentsOf: url, encoding: .utf8) else { return }
        let start = "\n          /* Soulo touch selection */"
        let end = "\n          /* End Soulo touch selection */"
        var source = current
        if let opening = source.range(of: start),
           let closing = source.range(of: end, range: opening.upperBound..<source.endIndex) {
            source.removeSubrange(opening.lowerBound..<closing.upperBound)
        }
        guard SHA256.hash(data: Data(source.utf8)).map({ String(format: "%02x", $0) }).joined()
                == "a111152505f119f06b33f2c51ea155dc10a8910bbd2f7e5a1f645bcbf2ffb4a4",
              let registration = source.range(of: #"document.addEventListener("mousedown", mousedown, false);"#)
        else { return }
        source.insert(contentsOf: start + touchSelection + end, at: registration.upperBound)
        if current != source { try Data(source.utf8).write(to: url, options: .atomic) }
    }

    private static let touchSelection = #"""

          const host = qsRegionHost.el();
          host.style.touchAction = "none";
          host.querySelector(".qs-region-guide-3").style.touchAction = "none";
          let pointerID = null;
          host.addEventListener("pointerdown", event => {
            if (event.pointerType !== "touch" || !event.isPrimary || pointerID !== null) return;
            pointerID = event.pointerId;
            try { host.setPointerCapture(pointerID); } catch (_) {}
            mousedown(event);
          });
          host.addEventListener("pointermove", event => {
            if (event.pointerId === pointerID) update(event);
          });
          host.addEventListener("pointerup", event => {
            if (event.pointerId !== pointerID) return;
            pointerID = null;
            update(event);
            remove();
          });
          function cancelSelection(event) {
            if (event.pointerId !== pointerID) return;
            pointerID = null;
            guide.remove();
            monitor.remove();
            qsRegionHost.remove();
          }
          host.addEventListener("pointercancel", cancelSelection);
          host.addEventListener("lostpointercapture", cancelSelection);
    """#

    private static let javaScript = #"""
    ;(() => {
      const runtime = (globalThis.chrome || globalThis.browser)?.runtime;
      if (!runtime?.connect || !runtime.onConnect) return;
      const editor = new URL(runtime.getURL('view/library.html'));
      const channel = '__soulo_quick_snip_capture';
      const chunkSize = 96 * 1024;
      // The publisher keeps at most 100 MiB of full-page captures.
      const maximumBytes = 100 * 1024 * 1024;

      function captureID(address) {
        if (address.protocol !== editor.protocol || address.host !== editor.host || address.pathname !== editor.pathname ||
            address.searchParams.get('overlay') !== '1') return null;
        const id = address.searchParams.get('capture') || address.searchParams.get('fp');
        return id?.length <= 256 ? id : null;
      }

      async function encodeChunk(blob) {
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let text = '';
        for (let offset = 0; offset < bytes.length; offset += 8192) {
          text += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
        }
        return btoa(text);
      }

      function decodeChunk(text) {
        if (typeof text !== 'string' || text.length > chunkSize * 4 / 3) throw new Error('Invalid screenshot chunk');
        return Uint8Array.from(atob(text), byte => byte.charCodeAt(0));
      }

      if (typeof document !== 'undefined' && location.pathname === editor.pathname) {
        if (window === window.top) return;
        const id = captureID(new URL(location.href));
        const store = globalThis.QSBlobStore;
        if (!id || !store || store.__souloCaptureAdapter) return;
        Object.defineProperty(store, '__souloCaptureAdapter', {value: true});
        const original = {get: store.get, put: store.put, delete: store.delete};

        async function transfer(operation) {
          const port = runtime.connect({name: channel});
          let pending;
          let timeout;
          port.onMessage.addListener(reply => {
            const current = pending;
            pending = null;
            clearTimeout(timeout);
            if (reply?.error) current?.reject(new Error(reply.error));
            else current?.resolve(reply?.value);
          });
          port.onDisconnect.addListener(() => {
            clearTimeout(timeout);
            pending?.reject(new Error(runtime.lastError?.message || 'The screenshot editor lost its background connection'));
            pending = null;
          });
          const send = message => new Promise((resolve, reject) => {
            pending = {resolve, reject};
            timeout = setTimeout(() => {
              pending = null;
              reject(new Error('The screenshot database did not respond'));
            }, 8000);
            try { port.postMessage(message); }
            catch (error) { clearTimeout(timeout); pending = null; reject(error); }
          });
          try { return await operation(send); }
          finally { port.disconnect(); }
        }

        store.get = key => key === id ? transfer(async send => {
          const info = await send({step: 'get'});
          if (!info) return original.get.call(store, key);
          const parts = [];
          for (let offset = 0; offset < info.size; offset += chunkSize) {
            parts.push(decodeChunk(await send({step: 'read', offset})));
          }
          return {...info.record, blob: new Blob(parts, {type: info.type})};
        }) : original.get.call(store, key);
        store.put = record => record?.id === id ? transfer(async send => {
          const {blob, ...metadata} = record;
          await send({step: 'put', record: metadata, size: blob.size, type: blob.type});
          for (let offset = 0; offset < blob.size; offset += chunkSize) {
            await send({step: 'write', bytes: await encodeChunk(blob.slice(offset, offset + chunkSize))});
          }
          return send({step: 'commit'});
        }) : original.put.call(store, record);
        store.delete = key => key === id ? transfer(send => send({step: 'delete'})) : original.delete.call(store, key);
        return;
      }

      runtime.onConnect.addListener(port => {
        if (port.name !== channel || port.sender?.id !== runtime.id || !port.sender.url) return;
        const id = captureID(new URL(port.sender.url));
        if (!id || !Number.isInteger(port.sender.frameId) || port.sender.frameId < 1) return;
        let readBlob, write, busy = false;
        let disconnected = false;
        port.onDisconnect.addListener(() => { disconnected = true; readBlob = undefined; write = undefined; });

        async function handle(message) {
          const store = globalThis.QSBlobStore;
          if (!store) throw new Error('The screenshot database is unavailable');
          switch (message?.step) {
            case 'get': {
              const stored = await store.get(id);
              if (!stored?.blob) return null;
              const {blob, ...record} = stored;
              if (blob.size > maximumBytes) throw new Error('The screenshot exceeds the capture budget');
              readBlob = blob;
              return {record, size: blob.size, type: blob.type};
            }
            case 'read': {
              const {offset} = message;
              if (!readBlob || !Number.isSafeInteger(offset) || offset < 0 || offset >= readBlob.size) break;
              return encodeChunk(readBlob.slice(offset, offset + chunkSize));
            }
            case 'put':
              if (write || message.record?.id !== id || !Number.isSafeInteger(message.size) || message.size < 0 ||
                  message.size > maximumBytes || typeof message.type !== 'string') break;
              write = {record: message.record, type: message.type, size: message.size, received: 0, parts: []};
              return true;
            case 'write': {
              if (!write) break;
              const bytes = decodeChunk(message.bytes);
              if (!bytes.length || write.received + bytes.length > write.size) break;
              write.parts.push(bytes);
              write.received += bytes.length;
              return true;
            }
            case 'commit': {
              if (!write || write.received !== write.size) break;
              const {record, parts, type} = write;
              write = undefined;
              return store.put({...record, blob: new Blob(parts, {type})});
            }
            case 'delete':
              await store.delete(id);
              return true;
          }
          throw new Error('Invalid screenshot transfer');
        }

        port.onMessage.addListener(message => {
          if (busy) return;
          busy = true;
          handle(message).then(
            value => { if (!disconnected) port.postMessage({value}); },
            error => { if (!disconnected) port.postMessage({error: String(error.message || error)}); }
          ).catch(() => {}).finally(() => { busy = false; });
        });
      });
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
      const manifest=api.runtime.getManifest();
      const canRequestRead=[...(manifest.permissions||[]),...(manifest.optional_permissions||[])].includes('clipboardRead');
      function permitted(){
        if(!canRequestRead||typeof api.permissions?.contains!=='function')return Promise.resolve(false);
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
              /* Desktop headings with a Semi Design action row need to wrap
                 before either the title or the actions are squeezed. */
              :where(main,section) > :where(div,header):has(> :is(h1,h2,h3)):has(> .semi-space){
                display:flex!important;flex-wrap:wrap!important;gap:8px;align-items:flex-start!important;
              }
              :where(main,section) > :where(div,header):has(> .semi-space) > :is(h1,h2,h3){
                flex:0 0 100%!important;min-width:0;margin:0;
              }
              :where(main,section) > :where(div,header):has(> :is(h1,h2,h3)):has(> .semi-space) > div:empty{
                display:none;
              }
              :where(main,section) > :where(div,header):has(> :is(h1,h2,h3)) .semi-space{
                min-width:0;max-width:100%;flex-wrap:wrap!important;
              }
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
