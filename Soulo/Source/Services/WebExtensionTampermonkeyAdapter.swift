import Foundation
import CryptoKit

/// A narrow port of the publisher's existing Content Script mode. Do not expose
/// a pretend chrome.userScripts API or run untrusted code in an app world.
enum WebExtensionTampermonkeyAdapter {
    static let javaScript = #"""
    (()=>{
      if(globalThis.__souloExpandTampermonkeyRules)return;
      function branches(pattern) {
        const stack=[{start:-1,content:0,pipes:[]}];let escaped=false,characterClass=false;
        for(let i=0;i<pattern.length;i++) {
          const char=pattern[i];
          if(escaped){escaped=false;continue;}if(char==='\\'){escaped=true;continue;}
          if(char==='['){characterClass=true;continue;}if(char===']'&&characterClass){characterClass=false;continue;}
          if(characterClass)continue;
          if(char==='('){stack.push({start:i,content:pattern.startsWith('(?:',i)?i+3:i+1,pipes:[]});continue;}
          if(char==='|'){stack[stack.length-1].pipes.push(i);continue;}
          if(char===')') {
            if(stack.length===1)throw Error('Unbalanced extension rule expression.');
            const group=stack.pop();if(group.pipes.length)return split(group,i);
          }
        }
        if(stack.length!==1)throw Error('Unbalanced extension rule expression.');
        return stack[0].pipes.length?split(stack[0],pattern.length):null;
        function split(group,end) {
          const ends=[...group.pipes,end],values=[];let start=group.content;
          for(const stop of ends){values.push(pattern.slice(0,group.content)+pattern.slice(start,stop)+pattern.slice(end));start=stop+1;}
          return values;
        }
      }
      Object.defineProperty(globalThis,'__souloExpandTampermonkeyRules',{value:function(rules,nextID) {
        const result=[];
        for(const rule of rules) {
          const expression=rule.condition?.regexFilter;
          if(typeof expression!=='string'){result.push(rule);continue;}
          let pending=[expression],expanded=[];
          while(pending.length) {
            const pattern=pending.pop(),parts=branches(pattern);
            if(parts)pending.push(...parts);else expanded.push(pattern);
            if(pending.length+expanded.length>128)throw Error('The extension rule has too many alternatives.');
          }
          if(expanded.length>1 && /\\[1-9]/.test(rule.action?.redirect?.regexSubstitution||''))
            throw Error('Numbered rule substitutions cannot be expanded safely.');
          for(let i=0;i<expanded.length;i++)result.push({...rule,id:i===0?rule.id:nextID(),condition:{...rule.condition,regexFilter:expanded[i]}});
          if(result.length>4096)throw Error('Too many extension rules.');
        }
        return result;
      }});
    })();
    """#
    private static let originalHash = "7377109daee3340f6f1f89d06f8099e92583229231b25d0f950653a63fb7dd32"
    private static let originalName = "__soulo_tampermonkey_background_original.js"

    static func isPrepared(in root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("__soulo_tampermonkey_adapter.json")),
              let state = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return state["originalSHA256"] == originalHash
    }

    @discardableResult
    static func prepare(worker: URL, root: URL, manifest: inout [String: Any]) throws -> Bool {
        guard manifest["version"] as? String == "5.5.1", manifest["name"] as? String == "__MSG_extName__",
              let commands = manifest["commands"] as? [String: Any], commands["open-dashboard"] != nil,
              commands["open-new-script"] != nil, worker.lastPathComponent == "background.js" else { return false }
        let backup = root.appendingPathComponent(originalName)
        let stateURL = root.appendingPathComponent("__soulo_tampermonkey_adapter.json")
        let current = try Data(contentsOf: worker)
        let original = (try? Data(contentsOf: backup)) ?? current
        guard SHA256.hash(data: original).map({ String(format: "%02x", $0) }).joined() == originalHash,
              var source = String(data: original, encoding: .utf8) else { return false }
        source = source.replacingOccurrences(of: #"runtime_content_mode:"userscripts""#, with: #"runtime_content_mode:"content""#)
            .replacingOccurrences(of: "An=e=>{let t,n=", with: "An=e=>{if(e==='runtime_content_mode')return 'content';let t,n=")
            .replacingOccurrences(of: #"INTERNAL_PAGE_PROTOCOLS:["chrome-extension:"]"#,
                                  with: #"INTERNAL_PAGE_PROTOCOLS:[new URL(chrome.runtime.getURL("")).protocol]"#)
            .replacingOccurrences(of: "if(!pt)throw new Error(", with: "if(!pt&&!globalThis.__souloWebExtensionStarting)throw new Error(")
            .replacingOccurrences(of: "sendBinary:async e=>{", with: "sendBinary:async e=>{if(typeof globalThis.__souloOffscreenBinary==='function')return (await globalThis.__souloOffscreenBinary(e)).result;")
            .replacingOccurrences(of: "addRules:e,removeRuleIds:t", with: "addRules:globalThis.__souloExpandTampermonkeyRules(e,()=>KA++),removeRuleIds:t")
            // WebKit grants hosts across ports and rejects ports in patterns.
            // Normalize only this permission query; keep the actual request URL.
            .replacingOccurrences(of: "Hn(t,{\nnopath:!0})", with: "Hn(t,{\nnopath:!0,noport:!0})")
            .replacingOccurrences(of: "C.runtime.onInstalled.addListener(e)", with: "globalThis.__souloAddInstallationListener(e)")
        // Keep the unsupported UserScripts choices out of this port's settings.
        let start = #"select:"content"!=wn.values.runtime_content_mode?"#
        if let first = source.range(of: start), let end = source.range(of: ",\nvalue:wn.values.runtime_content_mode", range: first.upperBound..<source.endIndex)
            ?? source.range(of: ",value:wn.values.runtime_content_mode", range: first.upperBound..<source.endIndex) {
            source.replaceSubrange(first.lowerBound..<end.lowerBound,
                with: #"select:[{name:Qr.getMessage("Content_Script"),value:"content"}]"#)
        }
        let patched = Data(("globalThis.__souloWebExtensionStarting=true;try{\n" + source + "\n}finally{globalThis.__souloWebExtensionStarting=false;}\n").utf8)
        // Preserve an extension package that somebody has edited after preparation.
        let previous = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        let currentHash = SHA256.hash(data: current).map({ String(format: "%02x", $0) }).joined()
        guard current == original || current == patched || previous?["preparedSHA256"] == currentHash else { return false }
        if !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
        try patched.write(to: worker, options: .atomic)
        try JSONEncoder().encode(["originalSHA256": originalHash,
            "preparedSHA256": SHA256.hash(data: patched).map({ String(format: "%02x", $0) }).joined()])
            .write(to: stateURL, options: .atomic)
        var scripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        if !scripts.contains(where: { $0["js"] as? [String] == ["page.js", "content.js"] }) {
            scripts.append(["js": ["page.js", "content.js"], "matches": ["<all_urls>"], "all_frames": true, "run_at": "document_start"])
        }
        manifest["content_scripts"] = scripts
        manifest["permissions"] = (manifest["permissions"] as? [String] ?? []).filter { $0 != "userScripts" }
        return true
    }
}
