import Foundation
import CryptoKit

/// Version-pinned adaptation of the publisher's background program. Account,
/// request and cryptography code remain in the installed package.
enum WebExtensionTYTYAdapter {
    static let chromeID = "kmibgmblaakbhikfbjaincmnmabgnoim"
    static let originalHash = "21877195d29dc57a97ab457684674bf9fd4ab50915eb7687919044d1360e1036"
    private static let stateName = "__soulo_tyty_adapter.json"
    private static let backupName = "__soulo_tyty_original.js"
    private struct Patch: Decodable { let start: Int; let length: Int; let replacement: String }
    private struct Patches: Decodable { let originalSHA256: String; let patches: [Patch] }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func isPrepared(in root: URL) -> Bool {
        guard let state = try? Data(contentsOf: root.appendingPathComponent(stateName)),
              let values = try? JSONDecoder().decode([String: String].self, from: state),
              values["originalSHA256"] == originalHash,
              let current = try? Data(contentsOf: root.appendingPathComponent("background.min.js")) else { return false }
        return values["preparedSHA256"] == hash(current)
    }

    @discardableResult
    static func prepare(in root: URL, manifest: inout [String: Any]) throws -> Bool {
        guard manifest["name"] as? String == "TYTY", manifest["version"] as? String == "0.6.6" else { return false }
        let worker = root.appendingPathComponent("background.min.js")
        let backup = root.appendingPathComponent(backupName)
        guard let current = try? Data(contentsOf: worker) else { return false }
        let original = (try? Data(contentsOf: backup)) ?? current
        guard hash(original) == originalHash, current == original || isPrepared(in: root) else { return false }
        guard let patchURL = Bundle.main.url(forResource: "tyty-0.6.6-template-patches", withExtension: "json", subdirectory: "UserScripts") else {
            throw BrowserExtensionError.invalidExtension
        }
        let patches = try JSONDecoder().decode(Patches.self, from: Data(contentsOf: patchURL))
        guard patches.originalSHA256 == originalHash, let text = String(data: original, encoding: .utf8) else { throw BrowserExtensionError.invalidExtension }
        let source = NSMutableString(string: text)
        for patch in patches.patches.sorted(by: { $0.start > $1.start }) {
            guard patch.start >= 0, patch.length >= 0, patch.start + patch.length <= source.length else { throw BrowserExtensionError.invalidExtension }
            source.replaceCharacters(in: NSRange(location: patch.start, length: patch.length), with: patch.replacement)
        }
        // The document background loads this same library before the program.
        let prepared = (source as String).replacingOccurrences(of: "importScripts((\"./lib/jsencrypt.min.js\"));", with: "void 0;")
        guard !prepared.contains("importScripts("), prepared != text else { throw BrowserExtensionError.invalidExtension }
        let data = Data(prepared.utf8)
        if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
        try data.write(to: worker, options: .atomic)
        try Data((WebExtensionTampermonkeyAdapter.javaScript + ruleCompatibility).utf8)
            .write(to: root.appendingPathComponent("__soulo_tyty_rules.js"), options: .atomic)
        try JSONEncoder().encode(["originalSHA256": originalHash, "preparedSHA256": hash(data)])
            .write(to: root.appendingPathComponent(stateName), options: .atomic)
        manifest["background"] = ["scripts": ["lib/jsencrypt.min.js", "__soulo_tyty_rules.js", "background.min.js"], "persistent": false]
        return true
    }

    private static let ruleCompatibility = #"""
    (()=>{
      const api=chrome.declarativeNetRequest;
      for(const name of ['updateDynamicRules','updateSessionRules']){
        const original=api[name];
        let pending=Promise.resolve();
        const replacement=function(options,...rest){
          const expanded=[];
          for(const rule of options.addRules||[]){
            let next=1000000000+rule.id*128;
            expanded.push(...globalThis.__souloExpandTampermonkeyRules([rule],()=>next++));
          }
          // Stable reserved IDs also remove rules persisted by a previous run.
          const remove=new Set(options.removeRuleIds||[]);
          for(const id of options.removeRuleIds||[])for(let i=0;i<128;i++)remove.add(1000000000+id*128+i);
          // Startup, storage changes and onInstalled can update the same IDs
          // concurrently. Serialize native transactions to avoid lost removals.
          const request={...options,addRules:expanded,removeRuleIds:[...remove]};
          const update=pending.catch(()=>{}).then(()=>original.call(api,request,...rest));
          pending=update;
          return update;
        };
        Object.defineProperty(api,name,{value:replacement,configurable:true,writable:true});
      }
    })();
    """#

    /// Route only this known site's Chrome ID. The native API still enforces
    /// externally_connectable, host access and the extension's enabled state.
    static func externalMessagingScript(nativeID: String) -> String {
        let encoded = String(decoding: try! JSONEncoder().encode(nativeID), as: UTF8.self)
        return #"""
        (()=>{
          const host=location.hostname,protocol=location.protocol;
          if(!((protocol==='https:'&&['tyty.jo3.org','www.tyty.ee.eu.org','192.168.0.2'].includes(host))||(protocol==='http:'&&host==='localhost')))return;
          const target=__NATIVE_ID__;
          // Safari exposes browser.runtime to allowed webpages. The publisher's
          // site checks chrome.runtime; alias only the existing native runtime.
          if(!globalThis.chrome?.runtime&&globalThis.browser?.runtime){
            try{
              if(!globalThis.chrome)Object.defineProperty(globalThis,'chrome',{value:{},configurable:true,writable:true});
              Object.defineProperty(globalThis.chrome,'runtime',{value:globalThis.browser.runtime,configurable:true,writable:true});
            }catch(_){}
          }
          for(const key of ['chrome','browser']){
            const api=globalThis[key]?.runtime;
            if(!api||typeof api.sendMessage!=='function'||api.sendMessage.__souloTYTYTarget===target)continue;
            const original=api.sendMessage;
            const send=function(...args){if(args[0]==='kmibgmblaakbhikfbjaincmnmabgnoim')args[0]=target;return original.apply(this,args);};
            Object.defineProperty(send,'__souloTYTYTarget',{value:target});
            try{Object.defineProperty(api,'sendMessage',{value:send,configurable:true,writable:true});}catch(_){try{api.sendMessage=send;}catch(_){}}
          }
        })();
        """#.replacingOccurrences(of: "__NATIVE_ID__", with: encoded)
    }
}

/// WebKit's callback must not keep an enable operation alive forever. A late
/// callback after cancellation/timeout cannot resume the continuation twice.
enum WebExtensionBackgroundStartupError: LocalizedError {
    case timedOut
    var errorDescription: String? { FeatureText.text("Extension startup timed out.") }
}

@MainActor
final class WebExtensionBackgroundStartup {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result; timeoutTask?.cancel(); timeoutTask = nil
        continuation?.resume(with: result); continuation = nil
    }
    static func wait(timeout: TimeInterval = 15, start: (@escaping (Error?) -> Void) -> Void) async throws {
        let gate = WebExtensionBackgroundStartup()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if let result = gate.result { continuation.resume(with: result); return }
                gate.continuation = continuation
                gate.timeoutTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    gate.finish(.failure(WebExtensionBackgroundStartupError.timedOut))
                }
                start { error in gate.finish(error.map { .failure($0) } ?? .success(())) }
            }
        } onCancel: {
            Task { @MainActor in gate.finish(.failure(CancellationError())) }
        }
    }
}
