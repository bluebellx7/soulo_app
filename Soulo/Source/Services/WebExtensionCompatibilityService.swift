import Foundation
import AVFAudio
import UserNotifications
import WebKit
import zlib
import JavaScriptCore
import CryptoKit

/// Converts store packages into a private resource directory and installs a
/// small compatibility layer before an extension's own background code runs.
/// WebKit remains the extension engine; this only fills APIs that have a safe,
/// native iOS equivalent.
enum WebExtensionPackagePreparer {
    static let preparedResourceName = "Extension"
    private static let requiredWebRequestKey = "__soulo_required_web_request"
    private static let managedPermissionNames = ["downloads", "offscreen", "userScripts", "proxy"]
    static var compatibilitySourceForTesting: String { nativeBindingsJavaScript() + compatibilityBridgeJavaScript }
    static var nativeBindingsSourceForTesting: String { nativeBindingsJavaScript() }
    static var mediaLayoutSourceForTesting: String { ExtensionMediaLayoutScript.javaScript }

    static func prepare(sourceURL: URL, in installDirectory: URL, reusingInstalledResources: Bool = false) async throws -> URL {
        let destination = installDirectory.appendingPathComponent(
            preparedResourceName,
            isDirectory: true
        )
        if sourceURL.standardizedFileURL == destination.standardizedFileURL {
            try await installCompatibilityLayer(in: destination, reusingInstalledResources: reusingInstalledResources)
            return destination
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        var preparationStage = "source"
        do {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw BrowserExtensionError.invalidExtension
            }
            if isDirectory.boolValue {
                preparationStage = "directory-copy"
                try fileManager.copyItem(at: sourceURL, to: destination)
            } else {
                preparationStage = "archive-read"
                let packageData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                BrowserStartupTrace.mark("extension_archive_read", detail: "bytes=\(packageData.count)")
                preparationStage = "archive-envelope"
                let zipData = try zipPayload(from: packageData)
                BrowserStartupTrace.mark("extension_archive_payload", detail: "bytes=\(zipData.count)")
                preparationStage = "archive-extraction"
                try SafeZIPExtractor.extract(zipData, to: destination)
            }
            preparationStage = "compatibility"
            try await installCompatibilityLayer(in: destination, reusingInstalledResources: reusingInstalledResources)
            return destination
        } catch {
            BrowserStartupTrace.mark("extension_prepare_failure", detail: preparationStage + ":" + String(describing: error))
            try? fileManager.removeItem(at: destination)
            if error is CancellationError || error is WebExtensionInstallationFailure { throw error }
            throw WebExtensionInstallationFailure(stage: .package, underlying: error)
        }
    }

    static func installCompatibilityLayer(in resourceDirectory: URL, reusingInstalledResources: Bool = true) async throws {
        try validateResourceTree(in: resourceDirectory)
        let manifestURL = resourceDirectory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifest = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
        else {
            throw WebExtensionInstallationFailure(stage: .manifest, underlying: BrowserExtensionError.invalidExtension)
        }
        try requireBackgroundFiles(in: manifest, root: resourceDirectory)
        let originalManifest = manifest
        if !reusingInstalledResources { manifest.removeValue(forKey: requiredWebRequestKey) }

        // A declarative Chrome panel can use the same native presentation as
        // extension popups on iPhone. Preserve any publisher-supplied popup.
        let panelFallbackMarker = resourceDirectory.appendingPathComponent("__soulo_synthesized_panel_popup")
        if let panel = manifest["side_panel"] as? [String: Any],
           let path = panel["default_path"] as? String,
           var action = manifest["action"] as? [String: Any],
           (action["default_popup"] as? String)?.isEmpty != false,
           let page = try? resourceURL(path, in: resourceDirectory),
           ["html", "htm"].contains(page.pathExtension.lowercased()),
           (try? page.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            action["default_popup"] = String(path.drop(while: { $0 == "/" }))
            manifest["action"] = action
            try Data().write(to: panelFallbackMarker, options: .atomic)
        }
        let nativeBindings = nativeBindingsJavaScript(
            synthesizedPanelPopup: FileManager.default.fileExists(atPath: panelFallbackMarker.path)
        )

        // Chrome's explicit wildcard ports are not portable to WebKit.
        // Omitting the port already matches every port; fixed ports stay intact.
        if var external = manifest["externally_connectable"] as? [String: Any],
           let matches = external["matches"] as? [String] {
            let normalized = matches.map(normalizeWildcardPort)
            if normalized != matches {
                external["matches"] = normalized
                manifest["externally_connectable"] = external
            }
        }

        // Chrome uses its host grants for redirects and header rewrites.
        // WebKit additionally requires this permission, which is reviewed
        // with the same manifest and still subject to the user's site grants.
        if var permissions = manifest["permissions"] as? [String],
           permissions.contains("declarativeNetRequest"),
           (manifest["host_permissions"] as? [String])?.isEmpty == false,
           !permissions.contains("declarativeNetRequestWithHostAccess"),
           (manifest["optional_permissions"] as? [String])?.contains("declarativeNetRequestWithHostAccess") != true {
            permissions.append("declarativeNetRequestWithHostAccess")
            manifest["permissions"] = permissions
        }
        try protectLocalExtensionResources(in: resourceDirectory, manifest: &manifest)

        _ = try WebExtensionTYTYAdapter.prepare(in: resourceDirectory, manifest: &manifest)
        if let background = manifest["background"] as? [String: Any],
           let worker = background["service_worker"] as? String,
           (background["type"] as? String)?.lowercased() != "module" {
            let original = try originalWorkerURL(worker, isModule: false, in: resourceDirectory)
            try repairImageyePopupSelection(worker: original, manifest: manifest)
            if let scripts = verifiedEventPageScripts(in: resourceDirectory, worker: original, manifest: manifest)
                ?? WebExtensionQuickSnipAdapter.eventPageScripts(worker: original, manifest: manifest) {
                manifest["background"] = ["scripts": scripts, "persistent": false]
            } else if try !WebExtensionTampermonkeyAdapter.prepare(worker: original, root: resourceDirectory, manifest: &manifest) {
                try await installClassicBackground(in: resourceDirectory, worker: original, manifest: &manifest)
            }
        }
        try WebExtensionGoFullPageAdapter.prepare(in: resourceDirectory, manifest: &manifest)
        try installNativeBindings(nativeBindings, in: resourceDirectory, manifest: &manifest)
        let permissions = (manifest["permissions"] as? [String]) ?? []
        let declaredPermissions = permissions + (manifest["optional_permissions"] as? [String] ?? [])
        let needsNotifications = declaredPermissions.contains("notifications")
        let needsOffscreen = declaredPermissions.contains("offscreen")
        let needsDownloads = declaredPermissions.contains("downloads")
        let needsUserScripts = declaredPermissions.contains("userScripts")
        let needsProxy = declaredPermissions.contains("proxy")
        let hasRequiredHosts = (manifest["host_permissions"] as? [String])?.isEmpty == false
            || permissions.contains { $0 == "<all_urls>" || $0.contains("://") }
        let needsTabMetadata = declaredPermissions.contains("tabs") && !hasRequiredHosts
        let needsNativeBridge = needsNotifications || needsOffscreen || needsDownloads || needsUserScripts
            || needsProxy || needsTabMetadata || manifest["commands"] != nil
        let needsBadgeColors = !needsNativeBridge && (manifest["action"] != nil || manifest["browser_action"] != nil)
            && publisherUsesBadgeTextColor(in: resourceDirectory)
        if needsDownloads || needsUserScripts || manifest["commands"] != nil || needsNotifications || needsOffscreen {
            try Data("<!doctype html><meta charset='utf-8'><title>Download</title>".utf8)
                .write(to: resourceDirectory.appendingPathComponent(WebExtensionDownloadsScript.helperFilename), options: .atomic)
        }
        guard needsNativeBridge || needsBadgeColors else {
            try prepareUTF8BackgroundPage(in: resourceDirectory, manifest: &manifest)
            // Plain packages need no manifest rewrite. Preserve their original
            // bytes while still persisting actual worker/port migrations.
            if !(manifest as NSDictionary).isEqual(originalManifest as NSDictionary) {
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                    .write(to: manifestURL, options: .atomic)
            }
            return
        }

        var updatedPermissions = permissions
        if !updatedPermissions.contains("nativeMessaging") {
            updatedPermissions.append("nativeMessaging")
            manifest["permissions"] = updatedPermissions
        }

        let compatibilityFilename = "__soulo_webextension_compatibility.js"
        let compatibilityURL = resourceDirectory.appendingPathComponent(compatibilityFilename)
        try Data((nativeBindings + compatibilityBridgeJavaScript + WebExtensionFastStreamSourceAdapter.source(in: resourceDirectory)).utf8).write(to: compatibilityURL, options: .atomic)

        if var background = manifest["background"] as? [String: Any] {
            if let serviceWorker = background["service_worker"] as? String {
                let isModule = (background["type"] as? String)?.lowercased() == "module"
                let workerURL = try originalWorkerURL(serviceWorker, isModule: isModule, in: resourceDirectory)
                var adaptedTampermonkey = false
                if !isModule {
                    adaptedTampermonkey = try WebExtensionTampermonkeyAdapter.prepare(worker: workerURL, root: resourceDirectory, manifest: &manifest)
                }
                let root = resourceDirectory.resolvingSymlinksInPath().standardizedFileURL
                let relativeDirectory = String(workerURL.deletingLastPathComponent().path.dropFirst(root.path.count))
                    .split(separator: "/").map(String.init)
                let wrapperName = (relativeDirectory + ["__soulo_webextension_background_v4.js"]).joined(separator: "/")
                let compatibilityImport = relativeDirectory.isEmpty ? "./\(compatibilityFilename)"
                    : String(repeating: "../", count: relativeDirectory.count) + compatibilityFilename
                let frameImport = relativeDirectory.isEmpty ? "./" + ExtensionFrameMessagingScript.backgroundFilename
                    : String(repeating: "../", count: relativeDirectory.count) + ExtensionFrameMessagingScript.backgroundFilename
                var imports = [compatibilityImport, frameImport]
                if needsDownloads && !isModule {
                    imports.append(String(repeating: "../", count: relativeDirectory.count) + WebExtensionBlobScript.backgroundFilename)
                }
                imports.append("./" + workerURL.lastPathComponent)
                let quoted = imports.map { "\"" + javaScriptString($0) + "\"" }
                let wrapper = isModule ? quoted.map { "import \($0);\n" }.joined()
                    : "importScripts(\(quoted.joined(separator: ", ")));\n"
                try Data(wrapper.utf8).write(
                    to: try resourceURL(wrapperName, in: resourceDirectory),
                    options: .atomic
                )
                if isModule {
                    // WebKit supports nonpersistent module event pages. Keep
                    // the publisher's import graph intact while avoiding a
                    // restored worker registration with stale listeners.
                    background = ["scripts": [wrapperName], "type": "module", "persistent": false]
                } else if adaptedTampermonkey {
                    // The verified publisher program also runs in a document.
                    // Avoid waiting on WebKit's stalled service-worker startup.
                    background = ["scripts": [compatibilityFilename,
                        (relativeDirectory + [workerURL.lastPathComponent]).joined(separator: "/")], "persistent": false]
                } else {
                    background["service_worker"] = wrapperName
                }
            } else if var scripts = background["scripts"] as? [String],
                      !scripts.contains(compatibilityFilename) {
                for script in scripts { _ = try resourceURL(script, in: resourceDirectory) }
                scripts.insert(compatibilityFilename, at: 0)
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        for page in extensionPages(in: manifest) {
            try injectCompatibilityScript(
                filename: compatibilityFilename,
                into: try resourceURL(page, in: resourceDirectory)
            )
        }
        if let files = FileManager.default.enumerator(at: resourceDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let page as URL in files where ["html", "htm"].contains(page.pathExtension.lowercased()) {
                try injectCompatibilityScript(filename: compatibilityFilename, into: page)
            }
        }

        if needsDownloads { try installBlobBackground(nativeBindings, in: resourceDirectory, manifest: &manifest) }
        try prepareUTF8BackgroundPage(in: resourceDirectory, manifest: &manifest)
        let updatedManifest = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedManifest.write(to: manifestURL, options: .atomic)
    }

    private static func publisherUsesBadgeTextColor(in root: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "html", "htm"]
        let names = [Data("setBadgeTextColor".utf8), Data("getBadgeTextColor".utf8)]
        for case let file as URL in files where scriptExtensions.contains(file.pathExtension.lowercased()) {
            guard !file.lastPathComponent.hasPrefix("__soulo_"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let source = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            if names.contains(where: { source.range(of: $0) != nil }) { return true }
        }
        return false
    }

    static func prepareClassicBackgroundRetry(in root: URL) async throws -> Data? {
        let manifestURL = root.appendingPathComponent("manifest.json")
        let backup = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: backup) as? [String: Any],
              let background = manifest["background"] as? [String: Any],
              let worker = background["service_worker"] as? String,
              (background["type"] as? String)?.lowercased() != "module" else { return nil }
        let original = try originalWorkerURL(worker, isModule: false, in: root)
        let source = try String(contentsOf: original, encoding: .utf8)
        guard source.utf8.count <= 8_000_000 else { return nil }
        let parser = try await WebExtensionSourceAnalyzer(function: WebExtensionClassicImports.javaScript)
        if let imports = try await parser.analyze(source, as: [String].self), imports.isEmpty {
            let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard original.path.hasPrefix(base) else { return nil }
            let entry = String(original.path.dropFirst(base.count))
            manifest["background"] = ["scripts": [entry], "persistent": false]
        } else {
            try await installClassicBackground(in: root, worker: original, manifest: &manifest, allowsGuardedRetry: true)
            guard (manifest["background"] as? [String: Any])?["scripts"] != nil else { return nil }
        }
        try Task.checkCancellation()
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        return backup
    }

    private static let nativeBindingsFilename = "__soulo_webextension_native_bindings.js"
    private static let localExtensionRulesetID = "__soulo_local_extension_resources"

    static func requestedPermissions(in manifest: [String: Any]) -> [String] {
        var entries = manifest["permissions"] as? [String] ?? []
        if manifest[requiredWebRequestKey] as? Bool == true,
           (manifest["optional_permissions"] as? [String])?.contains("webRequest") == true,
           !entries.contains("webRequest") {
            entries.append("webRequest")
        }
        return entries
    }

    static func managedOptionalPermissions(in manifest: [String: Any]) -> [String] {
        (manifest["optional_permissions"] as? [String] ?? []).filter { managedPermissionNames.contains($0) }
    }

    /// iOS 18 rejects required webRequest during manifest validation, but
    /// exposes its native events when the same permission is explicitly granted.
    /// Keep the publisher's request in Soulo's review and permission settings.
    static func prepareNonpersistentWebRequest(at manifestURL: URL) throws -> Data? {
        let original = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              manifest["manifest_version"] as? Int == 3,
              let background = manifest["background"] as? [String: Any],
              background["persistent"] as? Bool != true,
              var permissions = manifest["permissions"] as? [String], permissions.contains("webRequest") else { return nil }
        permissions.removeAll { $0 == "webRequest" }
        var optional = manifest["optional_permissions"] as? [String] ?? []
        if !optional.contains("webRequest") { optional.append("webRequest") }
        manifest["permissions"] = permissions
        manifest["optional_permissions"] = optional
        manifest[requiredWebRequestKey] = true
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
        return original
    }

    private static func protectLocalExtensionResources(in root: URL, manifest: inout [String: Any]) throws {
        let declared = (manifest["permissions"] as? [String] ?? []) + (manifest["optional_permissions"] as? [String] ?? [])
        guard declared.contains("declarativeNetRequest") || declared.contains("declarativeNetRequestWithHostAccess") else { return }
        var networkRules = manifest["declarative_net_request"] as? [String: Any] ?? [:]
        var resources = networkRules["rule_resources"] as? [[String: Any]] ?? []
        // WebKit applies an extension's rule list to its own UI and background.
        // A static allow also covers already-persisted dynamic rules on launch.
        // Match the requested URL so HTTP(S) fetches from those pages still use DNR.
        let identifier = localExtensionRulesetID
        let filename = identifier + ".json"
        if !resources.contains(where: { $0["id"] as? String == identifier && $0["path"] as? String == filename }) {
            resources.insert(["id": identifier, "enabled": true, "path": filename], at: 0)
            networkRules["rule_resources"] = resources
            manifest["declarative_net_request"] = networkRules
        }
        let allow: [[String: Any]] = [[
            "id": 1, "priority": Int32.max, "action": ["type": "allow"],
            "condition": [
                "urlFilter": "|webkit-extension://",
                "resourceTypes": ["main_frame", "sub_frame", "script", "stylesheet", "image", "font",
                                  "xmlhttprequest", "media", "ping", "websocket", "other"]
            ]
        ]]
        try JSONSerialization.data(withJSONObject: allow, options: .sortedKeys)
            .write(to: root.appendingPathComponent(filename), options: .atomic)
    }

    private static func prepareUTF8BackgroundPage(in root: URL, manifest: inout [String: Any]) throws {
        guard var background = manifest["background"] as? [String: Any],
              background["page"] == nil, background["service_worker"] != nil,
              background["type"] as? String != "module", background["preferred_environment"] == nil,
              let scripts = background["scripts"] as? [String], !scripts.isEmpty else { return }
        // Dual-environment Chromium/Firefox manifests give WebKit a classic
        // script list. Declare UTF-8 explicitly for that existing environment.
        let html = try scripts.map { reference -> String in
            _ = try resourceURL(reference, in: root)
            guard let encoded = URLComponents(string: reference)?.percentEncodedPath else { throw BrowserExtensionError.invalidExtension }
            let path = ("/" + String(encoded.drop(while: { $0 == "/" })))
                .replacingOccurrences(of: "&", with: "&amp;")
            return "<script src=\"\(path)\"></script>"
        }.joined(separator: "\n")
        let page = "__soulo_utf8_background.html"
        try Data(("<!doctype html><meta charset=\"utf-8\">\n" + html).utf8)
            .write(to: root.appendingPathComponent(page), options: .atomic)
        background.removeValue(forKey: "scripts")
        background.removeValue(forKey: "service_worker")
        background["page"] = page
        manifest["background"] = background
    }
    private static let idleCallbacksFilename = "__soulo_content_idle_callbacks.js"
    private static let idleCallbacks = #"""
    (()=>{
      if(typeof globalThis.requestIdleCallback==='function')return;
      const request=(callback,options)=>{
        const scheduled=performance.now();
        const timeout=options?.timeout;
        return setTimeout(()=>{
          const start=performance.now(),didTimeout=typeof timeout==='number'&&start-scheduled>=timeout;
          callback({didTimeout,timeRemaining:()=>didTimeout?0:Math.max(0,8-(performance.now()-start))});
        },0);
      };
      Object.defineProperties(globalThis,{
        requestIdleCallback:{configurable:true,writable:true,value:request},
        cancelIdleCallback:{configurable:true,writable:true,value:id=>clearTimeout(id)}
      });
    })();
    """#

    private static func repairImageyePopupSelection(worker: URL, manifest: [String: Any]) throws {
        guard manifest["version"] as? String == "7.5.7", worker.lastPathComponent == "background.js",
              let source = try? Data(contentsOf: worker), source.count == 37_080,
              SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined()
                == "9dfd9af7109cdd31646eeb24217966918430cad3b00a19af6fce2953e48ddaaf"
        else { return }
        // The publisher's fallback selects popup mode when sidePanel is
        // unavailable. Its subsequent tab query can clear that popup using
        // the saved desktop display mode. Keep the original capability check.
        let original = Data(#"case 8:"sidePanel"===(r=e.sent)?chrome.action.setPopup({popup:""}):m(t[0].id,r)"#.utf8)
        let corrected = Data(#"case 8:"sidePanel"===(r=e.sent)&&globalThis.canDisplayInSidePanel?chrome.action.setPopup({popup:""}):m(t[0].id,r)"#.utf8)
        guard let range = source.range(of: original) else { return }
        var updated = source
        updated.replaceSubrange(range, with: corrected)
        try updated.write(to: worker, options: .atomic)
    }

    private static func verifiedEventPageScripts(in root: URL, worker: URL, manifest: [String: Any]) -> [String]? {
        let entry = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("background.js")
        guard worker.path == entry.path, let permissions = manifest["permissions"] as? [String] else { return nil }
        let expectedHash: String
        switch manifest["version"] as? String {
        case "4.52.0" where permissions.contains("declarativeNetRequestWithHostAccess"):
            // Adblock Plus loses popup messages after its worker idles on iOS 18.
            expectedHash = "313fab898ae9977d770b2fbad9b682d3ae80067ca72c047089433cc044308dc7"
        case "4.0.4" where permissions.contains("offscreen") && permissions.contains("downloads"):
            // FetchV's worker misses native video requests in a browser tab.
            // Its original listeners handle the same requests in an event page.
            expectedHash = "09b0602ddbc3881a5abcb749f3357c44a36713b7bf87f5c4f5fe90a3e74b24ff"
        default:
            return nil
        }
        guard let bytes = try? Data(contentsOf: worker, options: .mappedIfSafe),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedHash else { return nil }
        return ["background.js"]
    }

    /// Move classic backgrounds with a static import list to an event page.
    /// Also use an event page for debugger-dependent Chrome backgrounds when
    /// the same parser confirms they have no worker-only APIs.
    private static func installClassicBackground(in root: URL, worker: URL, manifest: inout [String: Any],
                                                 allowsGuardedRetry: Bool = false) async throws {
        let usesDebugger = (manifest["permissions"] as? [String])?.contains("debugger") == true
        guard let initial = try? String(contentsOf: worker, encoding: .utf8),
              initial.utf8.count <= 8_000_000, usesDebugger || initial.contains("importScripts") else { return }
        guard let parser = try? await WebExtensionSourceAnalyzer(function: WebExtensionClassicImports.javaScript) else { return }
        let directImports = try? await parser.analyze(initial, as: [String].self)
        let entryImports: [String]?
        if let directImports {
            entryImports = directImports
        } else if allowsGuardedRetry {
            entryImports = try? await parser.analyze(initial, as: [String].self, mode: "guarded-entry")
        } else {
            entryImports = nil
        }
        guard let firstImports = entryImports else {
            try Task.checkCancellation()
            return
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        func relative(_ file: URL) -> String { String(file.standardizedFileURL.path.dropFirst(base.path.count + 1)) }
        if firstImports.isEmpty {
            if usesDebugger { manifest["background"] = ["scripts": [relative(worker)], "persistent": false] }
            return
        }
        var ordered: [URL] = [], discovered = Set<URL>()
        var remainingBytes = 8_000_000 - initial.utf8.count
        func visit(_ file: URL, knownImports: [String]? = nil) async throws -> Bool {
            try Task.checkCancellation()
            let file = file.resolvingSymlinksInPath().standardizedFileURL
            // Re-importing a script can intentionally repeat side effects.
            // Leave those programs on their original native worker path.
            guard file.path.hasPrefix(base.path + "/"), discovered.count < 128, discovered.insert(file).inserted else { return false }
            let dependencies: [String]
            if let knownImports {
                dependencies = knownImports
            } else {
                guard let source = try? String(contentsOf: file, encoding: .utf8), source.utf8.count <= remainingBytes,
                      let imports = try? await parser.analyze(source, as: [String].self,
                          mode: directImports == nil ? "guarded-dependency" : "") else { return false }
                remainingBytes -= source.utf8.count
                dependencies = imports
            }
            for reference in dependencies {
                let next = reference.hasPrefix("/") ? base.appendingPathComponent(String(reference.dropFirst()))
                    : worker.deletingLastPathComponent().appendingPathComponent(reference)
                guard try await visit(next) else { return false }
            }
            ordered.append(file)
            return true
        }
        guard try await visit(worker, knownImports: firstImports) else { return }
        let paths = ordered.map(relative)
        let encoded = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        let entry = String(decoding: try JSONEncoder().encode(relative(worker)), as: UTF8.self)
        let loader = "__soulo_classic_worker_imports.js"
        let script = """
        (()=>{const base=chrome.runtime.getURL(\(entry));const loaded=new Set(\(encoded).map(path=>chrome.runtime.getURL(path)));
          Object.defineProperty(globalThis,'importScripts',{configurable:true,value:function(...paths){
            for(const path of paths)if(!loaded.has(new URL(path,base).href))throw new Error('Dynamic worker imports require native service worker support.');
          }});
        })();
        """
        try Data(script.utf8).write(to: root.appendingPathComponent(loader), options: .atomic)
        try JSONSerialization.data(withJSONObject: ["entry": relative(worker), "scripts": paths])
            .write(to: root.appendingPathComponent("__soulo_classic_background.json"), options: .atomic)
        manifest["background"] = ["scripts": [loader] + paths, "persistent": false]
    }

    /// WebKit native API functions require their owning object as receiver.
    /// Chrome extensions also call i18n through detached references and Proxy.
    /// Plain JavaScript wrappers preserve that receiver in every calling form.
    private static func nativeBindingsJavaScript(synthesizedPanelPopup: Bool = false) -> String {
        let supportsRequestMethods: Bool
        if #available(iOS 26, *) { supportsRequestMethods = true }
        else { supportsRequestMethods = false }
        return #"""
    (()=>{
      // Some Chromium extensions read the brand list without checking for
      // Client Hints. WebKit has no Chromium brand to report.
      const navigator=globalThis.navigator;
      if(globalThis.location?.protocol==='webkit-extension:'&&navigator&&!navigator.userAgentData){
        const ua=navigator.userAgent||'';
        const mobile=/\b(iPhone|iPad|iPod)\b/i.test(ua)||(/Macintosh/.test(ua)&&navigator.maxTouchPoints>1);
        const brands=Object.freeze([]),platform=mobile?'iOS':(/Macintosh/.test(ua)?'macOS':'');
        const lowEntropy=()=>({brands,mobile,platform});
        const version=ua.match(mobile?/\bOS ([\d_]+)/:/\bMac OS X ([\d_]+)/)?.[1]?.replaceAll('_','.')||'';
        try{Object.defineProperty(navigator,'userAgentData',{configurable:true,value:Object.freeze({
          ...lowEntropy(),toJSON:lowEntropy,
          async getHighEntropyValues(hints){
            const result=lowEntropy();
            if(hints.includes('fullVersionList'))result.fullVersionList=brands;
            if(hints.includes('platformVersion'))result.platformVersion=version;
            return result;
          }
        })});}catch(_){}
      }
      // Native namespace accessors can recreate weakly held JS wrappers after
      // GC. Keep their owners reachable so installed methods survive between
      // the bootstrap, publisher scripts and later user interactions.
      const retained=globalThis.__souloNativeBindingsObjects||(globalThis.__souloNativeBindingsObjects=[]);
      // Match the types accepted by native WebKit when it omits the enum.
      const resourceTypes={
        MAIN_FRAME:'main_frame',SUB_FRAME:'sub_frame',STYLESHEET:'stylesheet',SCRIPT:'script',IMAGE:'image',
        FONT:'font',OBJECT:'object',XMLHTTPREQUEST:'xmlhttprequest',PING:'ping',CSP_REPORT:'csp_report',
        MEDIA:'media',WEBSOCKET:'websocket',OTHER:'other'
      };
      const localResourceRuleset='\#(localExtensionRulesetID)';
      const publisherRulesets=ids=>Array.isArray(ids)?ids.filter(id=>id!==localResourceRuleset):ids;
      const wrapMethod=(owner,key,wrap)=>{
        const native=owner?.[key];
        if(typeof native!=='function'||native.__souloRulesetBinding)return;
        const bound=wrap(native,owner);
        Object.defineProperty(bound,'__souloRulesetBinding',{value:true});
        try{Object.defineProperty(owner,key,{configurable:true,writable:true,value:bound});}catch(_){}
      };
      const ungroupedTab=tab=>Number.isInteger(tab?.id)&&tab.groupId==null?{...tab,groupId:-1}:tab;
      const mapResult=(value,transform)=>Array.isArray(value)?value.map(transform):transform(value);
      const tabResultOwners=globalThis.__souloUngroupedTabResultOwners||(globalThis.__souloUngroupedTabResultOwners=new WeakSet());
      const wrapResult=(original,owner,transform)=>function(...args){
        const callback=args.at(-1);
        if(typeof callback==='function'){
          args[args.length-1]=function(value){return callback.call(this,mapResult(value,transform));};
          return Reflect.apply(original,owner,args);
        }
        const promise=Reflect.apply(original,owner,args);
        return typeof promise?.then==='function'?promise.then(value=>mapResult(value,transform)):promise;
      };
      const wrapTabResults=(owner,methods,transform)=>{
        if(!owner||tabResultOwners.has(owner))return;
        tabResultOwners.add(owner);
        for(const method of methods)wrapMethod(owner,method,(original,receiver)=>wrapResult(original,receiver,transform));
      };
      const wrapTabEvent=(owner,key,position)=>{
        const event=owner?.[key];
        const add=event?.addListener,remove=event?.removeListener,has=event?.hasListener;
        if(typeof add!=='function'||add.__souloUngroupedTabEvent||typeof remove!=='function'||typeof has!=='function')return;
        const listeners=new WeakMap();
        const addListener=function(listener,...filters){
          if(typeof listener!=='function')return add.call(event,listener,...filters);
          let callback=listeners.get(listener);
          if(!callback){
            callback=function(...args){
              if(args.length>position)args[position]=ungroupedTab(args[position]);
              return Reflect.apply(listener,this,args);
            };
            listeners.set(listener,callback);
          }
          return add.call(event,callback,...filters);
        };
        Object.defineProperty(addListener,'__souloUngroupedTabEvent',{value:true});
        try{
          Object.defineProperties(event,{
            removeListener:{configurable:true,writable:true,value:listener=>remove.call(event,listeners.get(listener)||listener)},
            hasListener:{configurable:true,writable:true,value:listener=>has.call(event,listeners.get(listener)||listener)},
            addListener:{configurable:true,writable:true,value:addListener}
          });
          if(!retained.includes(event))retained.push(event);
        }catch(_){}
      };
      let sessionRuleWrite=Promise.resolve();
      for(const namespace of [globalThis.chrome,globalThis.browser]){
        if(!namespace)continue;
        for(const object of [namespace,...['i18n','tabs','windows','action','browserAction','pageAction','runtime','extension','permissions','webRequest','declarativeNetRequest','webNavigation','scripting','storage'].map(key=>namespace[key])]){
          if(object&&!retained.includes(object))retained.push(object);
        }
        if(!globalThis.chrome?.tabGroups&&!globalThis.browser?.tabGroups){
          // Chrome includes the ungrouped sentinel on every local tab. Older
          // WebKit omits it from both tab queries and toolbar click events.
          wrapTabResults(namespace.tabs,['query','get','getCurrent','create','update','duplicate','move','discard'],ungroupedTab);
          const populate=window=>Array.isArray(window?.tabs)?{...window,tabs:window.tabs.map(ungroupedTab)}:window;
          wrapTabResults(namespace.windows,['get','getCurrent','getLastFocused','getAll','create','update'],populate);
          wrapTabEvent(namespace.tabs,'onCreated',0);
          wrapTabEvent(namespace.tabs,'onUpdated',2);
          for(const action of [namespace.action,namespace.browserAction,namespace.pageAction]){
            wrapTabEvent(action,'onClicked',0);
          }
        }
        const windows=namespace.windows,tabs=namespace.tabs;
        if(windows&&typeof windows.create!=='function'&&typeof windows.getCurrent==='function'&&typeof tabs?.create==='function'){
          // Older iOS WebKit exposes one browser window and omits windows.create.
          // Match the native Soulo delegate by opening its URLs in that window.
          const open=async(options={})=>{
            const {url,focused=true,incognito=false,type='normal',state='normal',tabId}=options;
            if(incognito||type!=='normal'||state!=='normal'||tabId!==undefined)
              throw new Error('Only standard browser tabs can be opened on this system.');
            const urls=Array.isArray(url)?url:url===undefined?[]:[url];
            if(urls.some(address=>typeof address!=='string')||typeof focused!=='boolean')
              throw new TypeError('Invalid windows.create options.');
            const window=await windows.getCurrent();
            if(!Number.isInteger(window?.id)||window.incognito)throw new Error('The browser window is unavailable.');
            const created=[];
            for(const address of urls.length?urls:[undefined]){
              const request={windowId:window.id,active:focused&&created.length===0};
              if(address!==undefined)request.url=address;
              created.push(await tabs.create(request));
            }
            return {...window,tabs:created};
          };
          const create=function(options,callback){
            if(typeof options==='function'){callback=options;options=undefined;}
            const operation=open(options);
            if(typeof callback!=='function')return operation;
            operation.then(callback,()=>callback(undefined));
          };
          try{Object.defineProperty(windows,'create',{configurable:true,writable:true,value:create});}catch(_){}
        }
        const installEnum=(object,name,values)=>{
          if(!object||object[name])return;
          try{Object.defineProperty(object,name,{value:Object.freeze(values),configurable:true,enumerable:true});}catch(_){}
        };
        installEnum(namespace.runtime,'OnInstalledReason',{
          INSTALL:'install',UPDATE:'update',CHROME_UPDATE:'chrome_update',SHARED_MODULE_UPDATE:'shared_module_update'
        });
        const runtime = namespace.runtime;
        // Existing Chrome packages still call the deprecated getURL alias.
        // Native runtime.getURL keeps URL resolution within the current context.
        if (typeof runtime?.getURL === 'function') {
          const extension = namespace.extension || {};
          try {
            if (typeof extension.getURL !== 'function') {
              Object.defineProperty(extension, 'getURL', {
                configurable: true, writable: true, value: runtime.getURL.bind(runtime)
              });
            }
            if (!namespace.extension) {
              Object.defineProperty(namespace, 'extension', {configurable: true, value: extension});
            }
          } catch (_) {}
        }
        if (runtime && !runtime.onUpdateAvailable) {
          // Soulo installs extension updates after review. It has no staged,
          // background update to announce through Chrome's event.
          const listeners = new Set();
          try { Object.defineProperty(runtime, 'onUpdateAvailable', {configurable:true, value:{
            addListener(listener) { if (typeof listener === 'function') listeners.add(listener); },
            removeListener(listener) { listeners.delete(listener); },
            hasListener(listener) { return listeners.has(listener); },
            hasListeners() { return listeners.size > 0; }
          }}); } catch (_) {}
        }
        const permissions = namespace.permissions;
        const contains = permissions?.contains;
        if (typeof contains === 'function' && !contains.__souloPermissionQuery) {
          // Older WebKit throws on queries for unknown Chrome permissions.
          // An unsupported read-only query can report the permission absent.
          // Preserve native validation and all grants, requests and events.
          const wrapped = function(request, callback) {
            try { return Reflect.apply(contains, permissions, arguments); }
            catch (error) {
              const name = request && Object.keys(request).length === 1 && Array.isArray(request.permissions)
                && request.permissions.length === 1 ? request.permissions[0] : null;
              if (!['privacy','clipboardRead','debugger','webRequestBlocking','tabGroups'].includes(name) || (name==='privacy' && namespace.privacy) || arguments.length > 2
                  || (callback !== undefined && typeof callback !== 'function')
                  || !String(error).includes("'" + name + "' is not a valid permission")) throw error;
              if (callback) { queueMicrotask(() => callback(false)); return; }
              return Promise.resolve(false);
            }
          };
          Object.defineProperty(wrapped, '__souloPermissionQuery', {value:true});
          try { Object.defineProperty(permissions, 'contains', {configurable:true, writable:true, value:wrapped}); } catch (_) {}
        }
        installEnum(namespace.webRequest,'ResourceType',resourceTypes);
        installEnum(namespace.scripting,'ExecutionWorld',{ISOLATED:'ISOLATED',MAIN:'MAIN'});
        installEnum(namespace.tabs,'TabStatus',{UNLOADED:'unloaded',LOADING:'loading',COMPLETE:'complete'});
        installEnum(namespace.storage,'AccessLevel',{
          TRUSTED_CONTEXTS:'TRUSTED_CONTEXTS',TRUSTED_AND_UNTRUSTED_CONTEXTS:'TRUSTED_AND_UNTRUSTED_CONTEXTS'
        });
        const rules=namespace.declarativeNetRequest;
        if(rules){
          // Ruleset managers compare these lists to the publisher's own IDs.
          // Hide the local-resource guard from those lists and keep it enabled.
          wrapMethod(runtime,'getManifest',(original,owner)=>function(){
            const manifest=Reflect.apply(original,owner,arguments);
            const network=manifest?.declarative_net_request;
            if(!network?.rule_resources?.some(entry=>entry.id===localResourceRuleset))return manifest;
            const entries=network.rule_resources.filter(entry=>entry.id!==localResourceRuleset);
            const effective={...manifest};
            if(entries.length)effective.declarative_net_request={...network,rule_resources:entries};
            else delete effective.declarative_net_request;
            return effective;
          });
          wrapMethod(rules,'getEnabledRulesets',(original,owner)=>function(callback){
            if(arguments.length===0)return Reflect.apply(original,owner,[]).then(publisherRulesets);
            if(arguments.length!==1||typeof callback!=='function')return Reflect.apply(original,owner,arguments);
            return Reflect.apply(original,owner,[ids=>callback(publisherRulesets(ids))]);
          });
          wrapMethod(rules,'updateEnabledRulesets',(original,owner)=>function(...args){
            const options=args[0];
            if(Array.isArray(options?.disableRulesetIds)&&options.disableRulesetIds.includes(localResourceRuleset)){
              args[0]={...options,disableRulesetIds:publisherRulesets(options.disableRulesetIds)};
            }
            return Reflect.apply(original,owner,args);
          });
          installEnum(rules,'ResourceType',resourceTypes);
          installEnum(rules,'RuleActionType',{
            BLOCK:'block',REDIRECT:'redirect',ALLOW:'allow',UPGRADE_SCHEME:'upgradeScheme',
            MODIFY_HEADERS:'modifyHeaders',ALLOW_ALL_REQUESTS:'allowAllRequests'
          });
          installEnum(rules,'HeaderOperation',{APPEND:'append',SET:'set',REMOVE:'remove'});
          installEnum(rules,'DomainType',{FIRST_PARTY:'firstParty',THIRD_PARTY:'thirdParty'});
          // Older WebKit can accept a block rule and ignore its method
          // constraint. Reject the update before it blocks other methods.
          const methodBlockUnsupported=options=>!\#(supportsRequestMethods)&&Array.isArray(options?.addRules)&&
            options.addRules.some(rule=>rule?.action?.type==='block'&&
              (rule.condition?.requestMethods?.length||rule.condition?.excludedRequestMethods?.length));
          const rejectMethodBlock=callback=>{
            const error=new Error('This WebKit version does not support blocking rules limited to HTTP methods.');
            if(typeof callback==='function')throw error;
            return Promise.reject(error);
          };
          if(!\#(supportsRequestMethods)){
            wrapMethod(rules,'updateDynamicRules',(original,owner)=>function(options,callback){
              if(methodBlockUnsupported(options))return rejectMethodBlock(callback);
              return Reflect.apply(original,owner,arguments);
            });
          }
          const update=rules.updateSessionRules;
          if(typeof update==='function'&&!update.__souloSerializedSessionRules){
            function normalizeSessionRuleHeaders(options){
              if(!Array.isArray(options.addRules))return options;
              let changed=false;
              const addRules=options.addRules.map(rule=>{
                const action=rule?.action;
                if(action?.type!=='modifyHeaders')return rule;
                const hasName=(header,name)=>typeof header?.header==='string'&&header.header.toLowerCase()===name;
                const removesAlias=header=>header?.operation==='remove'&&hasName(header,'referrer');
                const removesPolicyValue=header=>header?.operation==='remove'&&hasName(header,'same-origin');
                let {requestHeaders,responseHeaders}=action;
                if(Array.isArray(requestHeaders)&&requestHeaders.some(header=>hasName(header,'referer'))&&requestHeaders.some(removesAlias)){
                  requestHeaders=requestHeaders.filter(header=>!removesAlias(header));
                }
                // Some CORS rules list the policy value `same-origin` as a
                // response header. WebKit rejects the whole rule on that entry.
                if(Array.isArray(responseHeaders)&&responseHeaders.some(header=>header?.operation==='set'&&hasName(header,'access-control-allow-origin'))
                    &&responseHeaders.some(removesPolicyValue)){
                  responseHeaders=responseHeaders.filter(header=>!removesPolicyValue(header));
                }
                if(requestHeaders===action.requestHeaders&&responseHeaders===action.responseHeaders)return rule;
                changed=true;
                const normalized={...action};
                if(requestHeaders!==action.requestHeaders)normalized.requestHeaders=requestHeaders;
                if(responseHeaders!==action.responseHeaders)normalized.responseHeaders=responseHeaders;
                return {...rule,action:normalized};
              });
              return changed?{...options,addRules}:options;
            }
            // Overlapping promise writes from an extension background can
            // collide in WebKit's session-rules database savepoints.
            const wrapped=function(options,callback){
              if(methodBlockUnsupported(options))return rejectMethodBlock(callback);
              if(arguments.length!==1||!options||typeof options!=='object'||Array.isArray(options)){
                return Reflect.apply(update,rules,arguments);
              }
              const result=sessionRuleWrite.then(()=>Reflect.apply(update,rules,[normalizeSessionRuleHeaders(options)]));
              sessionRuleWrite=result.then(()=>{},()=>{});
              return result;
            };
            Object.defineProperty(wrapped,'__souloSerializedSessionRules',{value:true});
            try{Object.defineProperty(rules,'updateSessionRules',{configurable:true,writable:true,value:wrapped});}catch(_){}
          }
        }
      }
      for(const api of [globalThis.chrome?.i18n,globalThis.browser?.i18n]){
        if(!api)continue;
        for(const key of ['getMessage','getUILanguage','getAcceptLanguages','detectLanguage','getSystemUILanguage','getPreferredSystemLanguages']){
          const original=api[key];
          if(typeof original!=='function'||original.__souloNativeBinding)continue;
          const wrapped=function(...args){return Reflect.apply(original,api,args);};
          Object.defineProperty(wrapped,'__souloNativeBinding',{value:true});
          try{Object.defineProperty(api,key,{value:wrapped,configurable:true,writable:true});}
          catch(_){try{api[key]=wrapped;}catch(_){}}
        }
      }
      const api=globalThis.chrome||globalThis.browser;
      if(!api)return;
      const manifest=api.runtime?.getManifest?.();
      const panel=manifest?.side_panel?.default_path, action=api.action;
      if(typeof panel==='string'&&panel&&manifest.permissions?.includes('sidePanel')&&
         typeof action?.setPopup==='function'&&typeof action?.getPopup==='function'){
        const synthesized=\#(synthesizedPanelPopup), popup=synthesized?'':manifest.action?.default_popup||'';
        const session=api.storage?.session, key='__souloSidePanelOptions';
        let memory={}, pending=Promise.resolve();
        const read=async()=>session?(await session.get(key))[key]||{}:memory;
        const write=async state=>{memory=state;if(session)await session.set({[key]:state});};
        const queue=operation=>{
          const result=pending.then(operation);
          pending=result.then(()=>{},()=>{});
          return result;
        };
        const choices=(state,tabId)=>({path:panel,enabled:true,...state.default,...state.tabs?.[tabId],...(tabId===undefined?{}:{tabId})});
        const validatePath=path=>{
          const base=new URL(api.runtime.getURL('/')), target=new URL(path,base);
          if(typeof path!=='string'||!path||target.protocol!==base.protocol||target.host!==base.host)
            throw new TypeError('The side panel path must be an extension resource.');
          return target.pathname.slice(1)+target.search+target.hash;
        };
        const restorePopup=async(target,panelPath,replacement)=>{
          const current=await action.getPopup(target);
          const base=api.runtime.getURL('/');
          // Disabling a panel can race with the extension configuring its own popup.
          if(current&&new URL(current,base).href===new URL(panelPath,base).href)
            await action.setPopup({...target,popup:replacement});
        };
        const updatePopup=async(previous,state,tabId)=>{
          const target=tabId===undefined?{}:{tabId}, options=choices(state,tabId);
          if(state.behavior&&options.enabled)await action.setPopup({...target,popup:options.path});
          else if(previous.behavior||synthesized)await restorePopup(target,choices(previous,tabId).path,popup);
        };
        for(const namespace of [globalThis.chrome,globalThis.browser]){
          if(!namespace||namespace.sidePanel)continue;
          const sidePanel={
            setPanelBehavior({openPanelOnActionClick}){return queue(async()=>{
              if(typeof openPanelOnActionClick!=='boolean')throw new TypeError('openPanelOnActionClick must be a boolean.');
              const previous=await read(), state={...previous,behavior:openPanelOnActionClick};
              await updatePopup(previous,state);
              const tabs=await api.tabs?.query?.({});
              for(const tab of tabs||[])if(state.tabs?.[tab.id])await updatePopup(previous,state,tab.id);
              await write(state);
            });},
            async getPanelBehavior(){return {openPanelOnActionClick:(await read()).behavior===true};},
            async getOptions({tabId}={}){return choices(await read(),tabId);},
            setOptions({tabId,path,enabled}){return queue(async()=>{
              const previous=await read(), state={...previous}, values={};
              if(path!==undefined)values.path=validatePath(path);
              if(enabled!==undefined){
                if(typeof enabled!=='boolean')throw new TypeError('The side panel enabled flag must be a boolean.');
                values.enabled=enabled;
              }
              if(tabId===undefined)state.default={...state.default,...values};
              else{
                if(!Number.isInteger(tabId)||tabId<0)throw new TypeError('Invalid side panel tab.');
                await api.tabs.get(tabId);
                const tabs=state.tabs||{};
                state.tabs={...tabs,[tabId]:{...tabs[tabId],...values}};
              }
              if(state.behavior)await updatePopup(previous,state,tabId);
              await write(state);
            });},
            async open({windowId,tabId}={}){
              if(typeof action.openPopup!=='function')throw new Error('Opening a side panel requires the extension toolbar action.');
              const tab=tabId===undefined?(await api.tabs.query(windowId===undefined?{active:true,currentWindow:true}:{active:true,windowId}))[0]:await api.tabs.get(tabId);
              if(!tab?.active)throw new Error('The side panel requires the active tab.');
              const state=await read(), options=choices(state,tab.id);
              if(!options.enabled)throw new Error('The side panel is disabled for this tab.');
              const target={tabId:tab.id}, previousPopup=await action.getPopup(target);
              await action.setPopup({...target,popup:options.path});
              try{await action.openPopup({windowId:tab.windowId});}
              finally{await restorePopup(target,options.path,previousPopup||'');}
            }
          };
          try{Object.defineProperty(namespace,'sidePanel',{configurable:true,value:Object.freeze(sidePanel)});}catch(_){}
        }
      }
      // iPhone exposes ManagedMediaSource instead of MediaSource. Let injected
      // hook scripts reach that real native prototype during synchronous setup,
      // then restore the website's feature detection before returning. No UA,
      // player selection, or permanent website API polyfill is installed.
      if(api.scripting?.executeScript&&!api.scripting.executeScript.__souloNativeBinding){
        const scripting=api.scripting,original=scripting.executeScript;
        const wrapped=function(details,callback){
          if(details?.world!=='MAIN'||!Array.isArray(details.files)||!details.files.length||details.files.some(file=>typeof file!=='string'))return Reflect.apply(original,scripting,arguments);
          const request={...details,files:['__soulo_media_source_enter.js',...details.files,'__soulo_media_source_exit.js']};
          const filter=values=>values?.filter(value=>value.result?.__souloMediaSourceScope!==1);
          // WebKit reports per-file exceptions in the results and continues to
          // the exit file. Keep callbacks inside its native lastError scope.
          if(typeof callback==='function')return Reflect.apply(original,scripting,[request,values=>callback(filter(values))]);
          return Reflect.apply(original,scripting,[request]).then(filter);
        };
        Object.defineProperty(wrapped,'__souloNativeBinding',{value:true});
        try{Object.defineProperty(scripting,'executeScript',{value:wrapped,configurable:true,writable:true});}catch(_){}
      }
      // Chrome accepts tab ID 0 and reports a missing tab asynchronously.
      // WebKit reserves 0 and throws before invoking the callback, which can
      // interrupt an extension restoring its default media-control selection.
      if(api.tabs?.get&&!api.tabs.get.__souloNativeBinding){
        const tabs=api.tabs,original=tabs.get;
        const wrapped=function(...args){
          try{return Reflect.apply(original,tabs,args);}
          catch(error){
            if(args[0]!==0)throw error;
            const callback=args[1];
            if(typeof callback!=='function')return Promise.reject(error);
            // Native lastError is a host accessor; JS cannot shadow it. Use an
            // unallocated positive sentinel to enter WebKit's real missing-tab
            // callback/error scope. Soulo never issues IDs near this value.
            return Reflect.apply(original,tabs,[Number.MAX_SAFE_INTEGER,callback]);
          }
        };
        Object.defineProperty(wrapped,'__souloNativeBinding',{value:true});
        try{Object.defineProperty(tabs,'get',{value:wrapped,configurable:true,writable:true});}catch(_){}
      }
      // Safari omits Chrome's option-enum objects. Expose only option values
      // that its native events support; optional EXTRA_HEADERS stays absent.
      if(api.webRequest)for(const [key,values] of Object.entries({
        OnBeforeSendHeadersOptions:{REQUEST_HEADERS:'requestHeaders'},
        OnSendHeadersOptions:{REQUEST_HEADERS:'requestHeaders'},
        OnHeadersReceivedOptions:{RESPONSE_HEADERS:'responseHeaders'},
        OnResponseStartedOptions:{RESPONSE_HEADERS:'responseHeaders'}
      }))if(!api.webRequest[key])try{Object.defineProperty(api.webRequest,key,{value:values,configurable:true});}catch(_){}
      const navigation=api.webNavigation,tabs=api.tabs;
      \#(WebExtensionRequestEventCompatibility.javaScript)(api,navigation,retained,wrapMethod);
      if(navigation?.getAllFrames){
        const missingFrameTree=message=>/(?:^|\s)(?:tab|main frame) not found\.?$/i.test(message||'');
        wrapMethod(navigation,'getAllFrames',(original,owner)=>function(details,callback){
          if(!Number.isInteger(details?.tabId)||details.tabId<=0||arguments.length>2||
            (callback!==undefined&&typeof callback!=='function'))return Reflect.apply(original,owner,arguments);
          if(typeof callback==='function'){
            return Reflect.apply(original,owner,[details,frames=>{
              // Chromium returns no frame result for either a closed tab or
              // one without renderer contents. Leave the native error scope first.
              if(missingFrameTree(api.runtime?.lastError?.message))queueMicrotask(()=>callback(null));
              else callback(frames);
            }]);
          }
          const result=Reflect.apply(original,owner,arguments);
          if(typeof result?.catch!=='function')return result;
          return result.catch(error=>{
            if(missingFrameTree(error?.message))return null;
            throw error;
          });
        });
      }
      const matchesNavigationURL=(url,filter)=>{
          if(!filter?.url)return true;
          const parsed=new URL(url);
          return filter.url.some(rule=>Object.entries(rule).every(([key,value])=>{
            if(key==='schemes')return value.includes(parsed.protocol.slice(0,-1));
            if(key==='ports')return value.some(port=>Array.isArray(port)?Number(parsed.port|| (parsed.protocol==='https:'?443:80))>=port[0]&&Number(parsed.port||(parsed.protocol==='https:'?443:80))<=port[1]:Number(parsed.port||(parsed.protocol==='https:'?443:80))===port);
            if(key==='urlMatches')return new RegExp(value).test(url);
            if(key==='originAndPathMatches')return new RegExp(value).test(parsed.origin+parsed.pathname);
            const part=key.startsWith('host')?parsed.hostname:key.startsWith('path')?parsed.pathname:key.startsWith('query')?parsed.search.slice(1):url;
            if(key.endsWith('Equals'))return part===value;
            if(key.endsWith('Contains'))return part.includes(value);
            if(key.endsWith('Prefix'))return part.startsWith(value);
            if(key.endsWith('Suffix'))return part.endsWith(value);
            return false;
          }));
      };
      if(navigation&&!navigation.onCreatedNavigationTarget&&tabs?.onCreated){
        const listeners=new Map();
        const receive=async tab=>{
          const url=tab.pendingUrl||tab.url;
          if(!listeners.size||tab.incognito||!url||!Number.isInteger(tab.id)||!Number.isInteger(tab.openerTabId))return;
          try{
            if(!await api.permissions?.contains({permissions:['webNavigation']}))return;
          }catch(_){return;}
          // Soulo supplies a native opener for browser-created tabs when
          // WebKit identifies the source as the main frame.
          const details={tabId:tab.id,sourceTabId:tab.openerTabId,sourceFrameId:0,sourceProcessId:-1,url,timeStamp:Date.now()};
          for(const [listener,filter] of listeners){
            try{if(matchesNavigationURL(url,filter))listener(details);}catch(error){console.error(error);}
          }
        };
        const event={
          addListener(listener,filter){
            if(typeof listener!=='function')throw new TypeError('Navigation listener must be a function.');
            if(listeners.has(listener))return;
            if(!listeners.size)tabs.onCreated.addListener(receive);
            listeners.set(listener,filter);
          },
          removeListener(listener){if(listeners.delete(listener)&&!listeners.size)tabs.onCreated.removeListener(receive);},
          hasListener(listener){return listeners.has(listener);},
          hasListeners(){return listeners.size>0;}
        };
        try{Object.defineProperty(navigation,'onCreatedNavigationTarget',{value:event,configurable:true});}catch(_){}
      }
      if(navigation&&(!navigation.onHistoryStateUpdated||!navigation.onReferenceFragmentUpdated)&&tabs?.onUpdated&&navigation.getFrame){
        const documents=new Map(),subscriptions=new Map();let observing=false;
        const hasListeners=()=>[...subscriptions.values()].some(listeners=>listeners.size);
        const identity=async tabId=>{
          const frame=await navigation.getFrame({tabId,frameId:0});
          if(frame?.documentId)return {url:frame.url,id:frame.documentId};
          if(!api.scripting?.executeScript)return null;
          const result=await api.scripting.executeScript({target:{tabId,frameIds:[0]},func:()=>({url:location.href,id:String(performance.timeOrigin)})});
          return result?.[0]?.result||null;
        };
        for(const name of ['onHistoryStateUpdated','onReferenceFragmentUpdated']){
          if(navigation[name])continue;
          const listeners=new Map();
          const event={addListener(listener,filter){listeners.set(listener,filter);start();},removeListener(listener){listeners.delete(listener);},hasListener(listener){return listeners.has(listener);},hasListeners(){return listeners.size>0;}};
          try{Object.defineProperty(navigation,name,{value:event,configurable:true});subscriptions.set(name,listeners);}catch(_){}
        }
        function start(){
        if(observing)return;observing=true;
        tabs.onUpdated.addListener(async(tabId,change)=>{
          if(!hasListeners()||!change.url)return;
          const before=documents.get(tabId);
          try{
            const current=await identity(tabId);if(!current)return;documents.set(tabId,current);
            if(!before||before.id!==current.id||before.url===current.url)return;
            const details={tabId,frameId:0,parentFrameId:-1,url:current.url,timeStamp:Date.now(),documentId:current.id,documentLifecycle:'active',frameType:'outermost_frame'};
            const fragmentOnly=before.url.split('#')[0]===current.url.split('#')[0];
            for(const [name,listeners] of subscriptions){
              if(name==='onReferenceFragmentUpdated'&&!fragmentOnly)continue;
              for(const [listener,filter] of listeners)if(matchesNavigationURL(current.url,filter))try{listener(details);}catch(error){console.error(error);}
            }
          }catch(_){}
        });
        navigation.onCommitted?.addListener(async details=>{if(!hasListeners()||details.frameId!==0)return;try{const current=await identity(details.tabId);if(current)documents.set(details.tabId,current);}catch(_){}});
        tabs.onActivated?.addListener(async details=>{if(!hasListeners())return;try{const current=await identity(details.tabId);if(current)documents.set(details.tabId,current);}catch(_){}});
        tabs.onRemoved?.addListener(tabId=>documents.delete(tabId));
        tabs.query({active:true,currentWindow:true}).then(values=>{for(const tab of values)identity(tab.id).then(value=>{if(value)documents.set(tab.id,value);},()=>{});},()=>{});
        }
      }
    })();
    """# + WebExtensionBlobScript.javaScript + ExtensionFrameMessagingScript.javaScript + ExtensionMediaLayoutScript.javaScript + WebExtensionClipboardPolicy.javaScript + WebExtensionTouchInput.javaScript + WebExtensionMediaStartup.javaScript + WebExtensionDialogLayout.javaScript
    }

    /// Keep extensions that initialize optional desktop debugging features
    /// from crashing before they can register unrelated background features.
    private static let unavailableDebuggerBackground = #"""
    ;(()=>{
      const event=()=>{
        const listeners=new Set();
        return Object.freeze({
          addListener(listener){if(typeof listener==='function')listeners.add(listener);},
          removeListener(listener){listeners.delete(listener);},
          hasListener(listener){return listeners.has(listener);},
          hasListeners(){return listeners.size>0;}
        });
      };
      const unavailable=(...args)=>{
        const error=new Error('Extension debugging is unavailable on iOS.');
        if(typeof args[args.length-1]==='function')throw error;
        return Promise.reject(error);
      };
      for(const api of [globalThis.chrome,globalThis.browser]){
        if(!api||api.debugger)continue;
        const debuggerAPI=Object.freeze({
          onEvent:event(),onDetach:event(),
          getTargets(callback){
            if(typeof callback==='function'){Promise.resolve().then(()=>callback([]));return;}
            return Promise.resolve([]);
          },
          attach:unavailable,detach:unavailable,sendCommand:unavailable
        });
        try{Object.defineProperty(api,'debugger',{value:debuggerAPI,configurable:true});}catch(_){}
      }
    })();
    """#

    private static func installNativeBindings(_ nativeBindings: String, in root: URL, manifest: inout [String: Any]) throws {
        try Data((nativeBindings + WebExtensionFastStreamSourceAdapter.source(in: root)).utf8).write(to: root.appendingPathComponent(nativeBindingsFilename), options: .atomic)
        try Data("globalThis.__souloFrameDocumentRequested=true;globalThis.__souloInstallExtensionFrameDocument?.();".utf8)
            .write(to: root.appendingPathComponent(ExtensionFrameMessagingScript.documentFilename), options: .atomic)
        let declaresDebugger = (manifest["permissions"] as? [String])?.contains("debugger") == true
        let backgroundBootstrap = "globalThis.__souloInstallExtensionFrameBackground?.();"
            + (declaresDebugger ? unavailableDebuggerBackground : "")
            + (try WebExtensionQuickSnipAdapter.prepare(in: root, manifest: manifest))
        try Data(backgroundBootstrap.utf8)
            .write(to: root.appendingPathComponent(ExtensionFrameMessagingScript.backgroundFilename), options: .atomic)
        try Data(#"""
        (()=>{const state=globalThis.__souloMediaSourceScope;
        if(state&&globalThis.MediaSource===state.native)state.depth++;
        else if(typeof globalThis.MediaSource==='undefined'&&typeof globalThis.ManagedMediaSource==='function'){
          Object.defineProperty(globalThis,'__souloMediaSourceScope',{configurable:true,value:{native:globalThis.ManagedMediaSource,depth:1,previous:Object.getOwnPropertyDescriptor(globalThis,'MediaSource')}});
          Object.defineProperty(globalThis,'MediaSource',{configurable:true,writable:true,value:globalThis.ManagedMediaSource});
        }return {__souloMediaSourceScope:1};})();
        """#.utf8).write(to: root.appendingPathComponent("__soulo_media_source_enter.js"), options: .atomic)
        try Data(#"""
        (()=>{const state=globalThis.__souloMediaSourceScope;if(state&&--state.depth===0){
          if(globalThis.MediaSource===state.native){if(state.previous)Object.defineProperty(globalThis,'MediaSource',state.previous);else delete globalThis.MediaSource;}
          delete globalThis.__souloMediaSourceScope;
        }return {__souloMediaSourceScope:1};})();
        """#.utf8).write(to: root.appendingPathComponent("__soulo_media_source_exit.js"), options: .atomic)
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let page as URL in files where ["html", "htm"].contains(page.pathExtension.lowercased()) {
                try injectCompatibilityScript(filename: ExtensionFrameMessagingScript.documentFilename, into: page)
                try injectCompatibilityScript(filename: nativeBindingsFilename, into: page)
            }
        }
        if var scripts = manifest["content_scripts"] as? [[String: Any]] {
            for index in scripts.indices {
                guard var files = scripts[index]["js"] as? [String] else { continue }
                if !files.contains(nativeBindingsFilename) { files.insert(nativeBindingsFilename, at: 0) }
                if !files.contains(idleCallbacksFilename), files.contains(where: { reference in
                    guard reference != nativeBindingsFilename, let script = try? resourceURL(reference, in: root),
                          let bytes = try? Data(contentsOf: script, options: .mappedIfSafe) else { return false }
                    return bytes.range(of: Data("requestIdleCallback(".utf8)) != nil
                }) {
                    files.insert(idleCallbacksFilename, at: 0)
                }
                if files.contains(idleCallbacksFilename) {
                    try Data(idleCallbacks.utf8).write(to: root.appendingPathComponent(idleCallbacksFilename), options: .atomic)
                }
                scripts[index]["js"] = files
            }
            manifest["content_scripts"] = scripts
        }
        guard var background = manifest["background"] as? [String: Any] else { return }
        if var scripts = background["scripts"] as? [String] {
            scripts.removeAll { $0 == nativeBindingsFilename || $0 == ExtensionFrameMessagingScript.backgroundFilename }
            scripts.insert(contentsOf: [nativeBindingsFilename, ExtensionFrameMessagingScript.backgroundFilename], at: 0)
            background["scripts"] = scripts
        } else if let worker = background["service_worker"] as? String {
            let isModule = (background["type"] as? String)?.lowercased() == "module"
            let original = try originalWorkerURL(worker, isModule: isModule, in: root)
            let base = root.resolvingSymlinksInPath().standardizedFileURL
            let directory = String(original.deletingLastPathComponent().path.dropFirst(base.path.count))
                .split(separator: "/").map(String.init)
            let wrapper = (directory + ["__soulo_webextension_background_bindings.js"]).joined(separator: "/")
            let binding = directory.isEmpty ? "./" + nativeBindingsFilename : String(repeating: "../", count: directory.count) + nativeBindingsFilename
            let frameBinding = directory.isEmpty ? "./" + ExtensionFrameMessagingScript.backgroundFilename
                : String(repeating: "../", count: directory.count) + ExtensionFrameMessagingScript.backgroundFilename
            let entry = javaScriptString("./" + original.lastPathComponent)
            let source = isModule ? "import \"\(binding)\";\nimport \"\(frameBinding)\";\nimport \"\(entry)\";\n"
                : "importScripts(\"\(binding)\", \"\(frameBinding)\", \"\(entry)\");\n"
            try Data(source.utf8).write(to: try resourceURL(wrapper, in: root), options: .atomic)
            background["service_worker"] = wrapper
        }
        manifest["background"] = background
    }

    private static func installBlobBackground(_ nativeBindings: String, in root: URL, manifest: inout [String: Any]) throws {
        let name = WebExtensionBlobScript.backgroundFilename
        let source = nativeBindings + "\nglobalThis.__souloInstallBlobRelay?.();\n"
        try Data(source.utf8).write(to: root.appendingPathComponent(name), options: .atomic)
        var background = manifest["background"] as? [String: Any] ?? ["scripts": [String](), "persistent": false]
        if var scripts = background["scripts"] as? [String] {
            if !scripts.contains(name) { scripts.insert(name, at: 0) }
            background["scripts"] = scripts
        }
        manifest["background"] = background
    }

    private static func normalizeWildcardPort(_ pattern: String) -> String {
        guard let separator = pattern.range(of: "://"),
              ["http", "https", "*"].contains(String(pattern[..<separator.lowerBound])),
              let path = pattern[separator.upperBound...].firstIndex(of: "/") else { return pattern }
        let authority = pattern[separator.upperBound..<path]
        guard authority.hasSuffix(":*"), authority.count > 2,
              !authority.contains("@") else { return pattern }
        return String(pattern[..<separator.upperBound]) + authority.dropLast(2) + pattern[path...]
    }

    private static func extensionPages(in manifest: [String: Any]) -> Set<String> {
        var pages = Set<String>()
        for key in ["action", "browser_action", "page_action"] {
            if let values = manifest[key] as? [String: Any],
               let popup = values["default_popup"] as? String,
               !popup.isEmpty {
                pages.insert(popup)
            }
        }
        if let page = manifest["options_page"] as? String, !page.isEmpty {
            pages.insert(page)
        }
        if let options = manifest["options_ui"] as? [String: Any],
           let page = options["page"] as? String,
           !page.isEmpty {
            pages.insert(page)
        }
        if let background = manifest["background"] as? [String: Any],
           let page = background["page"] as? String, !page.isEmpty { pages.insert(page) }
        return pages
    }

    private static func injectCompatibilityScript(filename: String, into pageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: pageURL.path),
              var html = try? String(contentsOf: pageURL, encoding: .utf8),
              !html.contains(filename) else { return }
        let tag = "<script src=\"/\(filename)\"></script>"
        if let headRange = html.range(of: "<head", options: .caseInsensitive),
           let closeRange = html.range(of: ">", range: headRange.lowerBound..<html.endIndex) {
            html.insert(contentsOf: tag, at: closeRange.upperBound)
        } else {
            html.insert(contentsOf: tag, at: html.startIndex)
        }
        try Data(html.utf8).write(to: pageURL, options: .atomic)
    }

    private static func validateResourceTree(in root: URL) throws {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw BrowserExtensionError.invalidExtension
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw BrowserExtensionError.invalidExtension
        }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw BrowserExtensionError.invalidExtension
            }
        }
    }

    private static func resourceURL(_ reference: String, in root: URL) throws -> URL {
        guard let components = URLComponents(string: reference), components.scheme == nil, components.host == nil,
              !components.path.isEmpty, !components.path.contains("\\"), !components.path.contains("\0"),
              !components.path.split(separator: "/").contains("..") else {
            throw BrowserExtensionError.invalidExtension
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let path = components.path.drop(while: { $0 == "/" })
        let target = base.appendingPathComponent(String(path)).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw BrowserExtensionError.invalidExtension }
        return target
    }

    private static func requireBackgroundFiles(in manifest: [String: Any], root: URL) throws {
        guard let background = manifest["background"] as? [String: Any] else { return }
        var files = (background["scripts"] as? [String] ?? []) + [background["page"] as? String].compactMap { $0 }
        if let worker = background["service_worker"] as? String {
            files.append(worker)
            // Prepared packages can point at a generated bootstrap on disk.
            // Check its publisher entry point as well.
            do {
                let original = try originalWorkerURL(worker, isModule: background["type"] as? String == "module", in: root)
                if original.lastPathComponent != worker.split(separator: "/").last.map(String.init) {
                    files.append(String(original.path.dropFirst(root.resolvingSymlinksInPath().standardizedFileURL.path.count + 1)))
                }
            } catch {
                throw WebExtensionInstallationFailure(stage: .background(worker), underlying: error)
            }
        }
        for path in files {
            do {
                let file = try resourceURL(path, in: root)
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw CocoaError(.fileNoSuchFile)
                }
            } catch {
                throw WebExtensionInstallationFailure(stage: .background(path), underlying: error)
            }
        }
    }

    private static func originalWorkerURL(_ reference: String, isModule: Bool, in root: URL) throws -> URL {
        // Recover the original entry point from wrappers installed by earlier
        // Soulo versions, so updating compatibility never nests wrappers.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let pattern = isModule ? #"import\s+("(?:[^"\\]|\\.)*")\s*;"#
            : #"importScripts\((?:\s*"(?:[^"\\]|\\.)*"\s*,\s*)+("(?:[^"\\]|\\.)*")\s*\);"#
        let regex = try NSRegularExpression(pattern: pattern)
        var current = try resourceURL(reference, in: root)
        var visited = Set<URL>()
        while true {
            let name = current.lastPathComponent
            let isBlobLoader = name == "__soulo_blob_worker.js"
            guard isBlobLoader || name.hasPrefix("__soulo_webextension_background_"),
                  let source = try? String(contentsOf: current, encoding: .utf8),
                  isBlobLoader ? source.contains(WebExtensionBlobScript.backgroundFilename)
                    : source.contains("__soulo_webextension_compatibility.js") || source.contains(nativeBindingsFilename)
            else { return current }
            guard visited.insert(current).inserted,
                  let match = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).last,
                  let range = Range(match.range(at: 1), in: source),
                  let original = try JSONSerialization.jsonObject(with: Data(source[range].utf8), options: [.fragmentsAllowed]) as? String,
                  let url = URL(string: original, relativeTo: current)?.absoluteURL,
                  url.path.hasPrefix(base)
            else { throw BrowserExtensionError.invalidExtension }
            current = try resourceURL(String(url.path.dropFirst(base.count)), in: root)
        }
    }

    private static func javaScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func zipPayload(from data: Data) throws -> Data {
        guard data.count >= 4 else { throw BrowserExtensionError.invalidExtension }
        if data[0] == 0x50, data[1] == 0x4B {
            return data
        }
        guard String(data: data.prefix(4), encoding: .ascii) == "Cr24",
              let version = data.littleEndianUInt32(at: 4) else {
            throw BrowserExtensionError.invalidExtension
        }
        let offset: Int
        switch version {
        case 2:
            guard let publicKeyLength = data.littleEndianUInt32(at: 8),
                  let signatureLength = data.littleEndianUInt32(at: 12) else {
                throw BrowserExtensionError.invalidExtension
            }
            offset = 16 + Int(publicKeyLength) + Int(signatureLength)
        case 3:
            guard let headerLength = data.littleEndianUInt32(at: 8) else {
                throw BrowserExtensionError.invalidExtension
            }
            offset = 12 + Int(headerLength)
        default:
            throw BrowserExtensionError.invalidExtension
        }
        guard offset >= 0, offset + 4 <= data.count,
              data[offset] == 0x50, data[offset + 1] == 0x4B else {
            throw BrowserExtensionError.invalidExtension
        }
        return data.subdata(in: offset..<data.count)
    }

    private static let compatibilityBridgeJavaScript = #"""
    (() => {
      'use strict';
      const root = globalThis;
      const chrome = root.chrome || root.browser;
      if (!chrome || !chrome.runtime || root.__souloCompatibilityInstalled) return;
      try { Object.defineProperty(root, '__souloCompatibilityInstalled', { value: true }); }
      catch (_) { root.__souloCompatibilityInstalled = true; }
      if (!root.chrome) {
        try { root.chrome = chrome; } catch (_) {}
      }
      const setIfMissing = (target, key, value) => {
        if (!target || target[key]) return target && target[key];
        try { target[key] = value; } catch (_) {}
        if (target[key]) return target[key];
        try { Object.defineProperty(target, key, { configurable: true, value }); } catch (_) {}
        return target[key] || value;
      };
      const host = 'com.dkluge.Soulo.WebExtensionCompatibility';
      \#(WebExtensionTampermonkeyAdapter.javaScript)
      const event = () => ({
        addListener() {}, removeListener() {}, hasListener() { return false; },
        hasListeners() { return false; }
      });
      // iOS has no desktop keyboard shortcuts. Keep registration safe without
      // rewriting the extension's source; the management page reports this limit.
      const commands = chrome.commands || {};
      setIfMissing(commands, 'onCommand', event());
      setIfMissing(commands, 'getAll', function(callback) {
        if (typeof callback === 'function') { callback([]); return; }
        return Promise.resolve([]);
      });
      setIfMissing(chrome, 'commands', commands);
      if (root.browser && root.browser !== chrome) setIfMissing(root.browser, 'commands', commands);
      const native = (payload, callback, transform = value => value) => {
        let settled = false;
        let resolveReply, rejectReply;
        const promise = new Promise((resolve, reject) => { resolveReply = resolve; rejectReply = reject; });
        if (typeof callback === 'function') promise.catch(() => {});
        const done = value => {
          if (settled) return;
          const lastError = chrome.runtime.lastError;
          if (lastError) {
            failed(new Error(lastError.message || String(lastError)));
            return;
          }
          settled = true;
          try {
            const result = transform(value);
            resolveReply(result);
            if (typeof callback === 'function') callback(result);
          } catch (error) { rejectReply(error); }
        };
        const failed = error => {
          if (settled) return;
          settled = true;
          rejectReply(error);
          if (typeof callback === 'function') callback(undefined);
        };
        try {
          if (typeof chrome.runtime.sendNativeMessage !== 'function') {
            failed(new Error('The native extension compatibility host is unavailable.'));
          } else {
            const result = chrome.runtime.sendNativeMessage(host, payload, done);
            if (result && typeof result.then === 'function') result.then(done, failed);
          }
        } catch (error) { failed(error); }
        return typeof callback === 'function' ? undefined : promise;
      };
      const manifest = chrome.runtime.getManifest?.() || {};
      \#(WebExtensionActionColorCompatibility.javaScript)(root,chrome,manifest,native,setIfMissing);
      const declaredPermissions = [...(manifest.permissions || []), ...(manifest.optional_permissions || [])];
      const managedPermissions = [\#(managedPermissionNames.map { "'\($0)'" }.joined(separator: ","))];
      for(const permissions of new Set([chrome.permissions,root.browser?.permissions])){
        for(const method of ['contains','request']){
          const original=permissions?.[method];
          if(typeof original!=='function')continue;
          const wrapped=function(request,callback){
            const name=request&&Object.keys(request).every(key=>key==='permissions'||key==='origins')
              &&(request.origins===undefined||Array.isArray(request.origins)&&request.origins.length===0)
              &&Array.isArray(request.permissions)&&request.permissions.length===1?request.permissions[0]:null;
            if(arguments.length>2||(callback!==undefined&&typeof callback!=='function')||!managedPermissions.includes(name)||!declaredPermissions.includes(name)){
              return Reflect.apply(original,permissions,arguments);
            }
            // These grants are managed by Soulo's extension permission UI.
            // A publisher request can confirm an approved grant.
            return native({souloCompatibility:1,api:'permissionStatus',name},callback);
          };
          try{Object.defineProperty(permissions,method,{configurable:true,writable:true,value:wrapped});}catch(_){}
        }
      }
      const hasRequiredHosts = !!manifest.host_permissions?.length
        || (manifest.permissions || []).some(value => value === '<all_urls>' || value.includes('://'));
      if (declaredPermissions.includes('tabs') && !hasRequiredHosts) {
        for (const tabs of new Set([chrome.tabs, root.browser?.tabs])) {
          if (!tabs?.query) continue;
          const query = tabs.query.bind(tabs);
          // WebKit can return a tab ID while withholding its URL when only
          // the Chrome tabs permission was granted. Match the original tab
          // IDs against a fresh native enumeration before filling fields.
          const enrich = async value => {
            const items = Array.isArray(value) ? value : [value];
            const missing = items.filter(tab => tab && !tab.incognito && !tab.url
              && Number.isInteger(tab.index) && Number.isSafeInteger(tab.id));
            if (!missing.length) return value;
            try {
              const data = await native({souloCompatibility:1, api:'tabMetadata',
                indexes:missing.map(tab => tab.index)});
              if (!Array.isArray(data) || !data.length) return value;
              const live = new Map((await query({})).map(tab => [tab.id,tab]));
              const metadata = new Map(data.map(tab => [tab.index,tab]));
              for (const tab of missing) {
                const current = live.get(tab.id), entry = metadata.get(tab.index);
                if (!entry || !current || current.incognito || current.index !== tab.index
                    || current.windowId !== tab.windowId || current.active !== entry.active) continue;
                tab.url = current.url || entry.url;
                if (!tab.title && entry.title) tab.title = entry.title;
              }
            } catch (_) {}
            return value;
          };
          for (const method of ['query','get','getCurrent']) {
            if (typeof tabs[method] !== 'function' || tabs[method].__souloTabMetadata) continue;
            const original = tabs[method];
            const wrapped = function(...args) {
              const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
              if (!callback) return Reflect.apply(original,tabs,args).then(enrich);
              return Reflect.apply(original,tabs,[...args,value => {
                if (chrome.runtime.lastError || value == null) callback(value);
                else enrich(value).then(callback);
              }]);
            };
            Object.defineProperty(wrapped,'__souloTabMetadata',{value:true});
            try { Object.defineProperty(tabs,method,{value:wrapped,configurable:true,writable:true}); } catch (_) {}
          }
        }
      }
      if (declaredPermissions.includes('proxy') && !chrome.proxy?.settings) {
        // No extension owns the system proxy. Listeners may register, but
        // Soulo cannot report route changes or failures it does not observe.
        const readOnlyEvent = () => {
          const listeners = new Set();
          return {
            addListener(listener) { if (typeof listener === 'function') listeners.add(listener); },
            removeListener(listener) { listeners.delete(listener); },
            hasListener(listener) { return listeners.has(listener); },
            hasListeners() { return listeners.size > 0; }
          };
        };
        const settings = {
          get(details, callback) {
            return native({souloCompatibility:1, api:'proxy', operation:'get'}, callback);
          },
          set(details, callback) {
            return native({souloCompatibility:1, api:'proxy', operation:'set'}, callback);
          },
          clear(details, callback) {
            return native({souloCompatibility:1, api:'proxy', operation:'clear'}, callback);
          },
          onChange: readOnlyEvent()
        };
        const proxy = chrome.proxy || {};
        setIfMissing(proxy, 'settings', settings);
        setIfMissing(proxy, 'onProxyError', readOnlyEvent());
        setIfMissing(chrome, 'proxy', proxy);
        if (root.browser && root.browser !== chrome) setIfMissing(root.browser, 'proxy', proxy);
      }
      \#(WebExtensionDownloadsScript.javaScript)
      \#(WebExtensionUserScriptsScript.javaScript)
      // WebKit can report install again when a context is re-created. All
      // publishers, including welcome-page listeners, share the native version
      // gate; the old adapter entry point uses this same event subscription.
      if (!root.__souloAddInstallationListener) {
        const source=chrome.runtime.onInstalled;
        const originalAdd=source?.addListener?.bind(source);
        const originalRemove=source?.removeListener?.bind(source);
        if(originalAdd) {
          const listeners=new Set();let registered=false;
          const dispatch=details=>{
            for(const listener of Array.from(listeners)) {
              if(!listeners.has(listener))continue;
              try{listener(details);}catch(error){console.error(error);}
            }
          };
          const receive=details=>native({souloCompatibility:1,api:'lifecycle',operation:'installation',details}).then(result=>{
            if(!result?.skip)dispatch(result?.details||details);
          },error=>{console.error(error);dispatch(details);});
          const methods={
            addListener(listener) {
              if(typeof listener!=='function')throw new TypeError('Installation listener must be a function.');
              listeners.add(listener);
              if(!registered){originalAdd(receive);registered=true;}
            },
            removeListener(listener) {
              listeners.delete(listener);
              if(!listeners.size&&registered&&originalRemove){originalRemove(receive);registered=false;}
            },
            hasListener(listener){return listeners.has(listener);},
            hasListeners(){return listeners.size>0;}
          };
          Object.defineProperty(root,'__souloAddInstallationListener',{value:methods.addListener});
          const replace=(target,key,value)=>{
            try{Object.defineProperty(target,key,{configurable:true,writable:true,value});}catch(_) {
              try{target[key]=value;}catch(_){}
            }
            return target[key]===value;
          };
          const events=new Set([source,root.browser?.runtime?.onInstalled]);
          for(const installation of events) {
            if(!installation)continue;
            // Shadow native event methods, retaining the real add/remove pair
            // above. Minified aliases of chrome/browser use the same wrapper.
            for(const [key,value] of Object.entries(methods))replace(installation,key,value);
          }
          // Prefer a stable facade even if a native namespace getter creates
          // another event wrapper on the next property access.
          for(const runtime of new Set([chrome.runtime,root.browser?.runtime])) {
            if(runtime)replace(runtime,'onInstalled',methods);
          }
        }
      }

      const notifications = chrome.notifications || {};
      setIfMissing(notifications, 'onClicked', event());
      setIfMissing(notifications, 'onButtonClicked', event());
      setIfMissing(notifications, 'onClosed', event());
      setIfMissing(notifications, 'onPermissionLevelChanged', event());
      if (typeof notifications.create !== 'function') {
        setIfMissing(notifications, 'create', function(id, options, callback) {
            if (typeof id === 'object') { callback = options; options = id; id = ''; }
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'create',
              id: id || '', options: options || {} }, callback, value => value && value.id || id || 'soulo');
          });
      }
      if (typeof notifications.update !== 'function') {
        setIfMissing(notifications, 'update', function(id, options, callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'update',
              id, options: options || {} }, callback, value => !!(value && value.success));
          });
      }
      if (typeof notifications.clear !== 'function') {
        setIfMissing(notifications, 'clear', function(id, callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'clear', id },
              callback, value => !!(value && value.success));
          });
      }
      if (typeof notifications.getAll !== 'function') {
        setIfMissing(notifications, 'getAll', function(callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'getAll' },
              callback, value => value && value.notifications || {});
          });
      }
      if (typeof notifications.getPermissionLevel !== 'function') {
        setIfMissing(notifications, 'getPermissionLevel', function(callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'permission' },
              callback, value => value && value.level || 'denied');
          });
      }
      setIfMissing(chrome, 'notifications', notifications);
      if (root.browser && root.browser !== chrome) {
        const browserNotifications = root.browser.notifications || {};
        for (const key of Object.keys(notifications)) {
          setIfMissing(browserNotifications, key, notifications[key]);
        }
        setIfMissing(root.browser, 'notifications', browserNotifications);
      }

      // Chrome's legacy extension.getViews API has no iOS equivalent. Returning
      // an empty list preserves the common "focus existing, otherwise tabs.create"
      // flow used by options, history and dashboard buttons.
      const extension = chrome.extension || {};
      setIfMissing(extension, 'getViews', function() { return []; });
      setIfMissing(extension, 'getBackgroundPage', function() { return null; });
      setIfMissing(chrome, 'extension', extension);
      if (root.browser && root.browser !== chrome) setIfMissing(root.browser, 'extension', extension);

      let offscreenOpen = false;
      const offscreen = chrome.offscreen || {};
      const usesOffscreenCompatibility = typeof offscreen.createDocument !== 'function';
      setIfMissing(offscreen, 'Reason', Object.fromEntries(['AUDIO_PLAYBACK','CLIPBOARD','DOM_PARSER',
        'LOCAL_STORAGE','BLOBS','IFRAME_SCRIPTING','DOM_SCRAPING','WORKERS','MATCH_MEDIA','TESTING']
        .map(value => [value, value])));
      if (typeof offscreen.createDocument !== 'function') setIfMissing(offscreen, 'createDocument', function(options) {
        return native({souloCompatibility:1, api:'offscreen', operation:'create', options}, undefined,
          () => { offscreenOpen = true; });
      });
      if (typeof offscreen.closeDocument !== 'function') setIfMissing(offscreen, 'closeDocument', function() {
        return native({souloCompatibility:1, api:'offscreen', operation:'close'}, undefined,
          () => { offscreenOpen = false; });
      });
      if (typeof offscreen.hasDocument !== 'function') {
        setIfMissing(offscreen, 'hasDocument', function() {
          return native({souloCompatibility:1, api:'offscreen', operation:'has'}, undefined,
            value => (offscreenOpen = !!value?.open));
        });
      }
      setIfMissing(chrome, 'offscreen', offscreen);
      if (root.browser && root.browser !== chrome) setIfMissing(root.browser, 'offscreen', offscreen);
      if (usesOffscreenCompatibility && !root.__souloOffscreenBinary) {
        const codec = \#(WebExtensionStructuredMessageCodec.javaScript);
        Object.defineProperty(root,'__souloOffscreenBinary',{value:async function(message) {
          const packet=await codec.encode(message);
          const response=await native({souloCompatibility:1,api:'offscreen',operation:'structuredMessage',packet});
          return codec.decode(response);
        }});
      }
      setIfMissing(chrome.runtime, 'getContexts', function(filter, callback) {
        return native({souloCompatibility:1, api:'offscreen', operation:'contexts', filter:filter || {}}, callback,
          value => value?.contexts || []);
      });
      if (root.browser && root.browser !== chrome) {
        setIfMissing(root.browser.runtime, 'getContexts', chrome.runtime.getContexts);
      }

      // Tomato Clock's MV3 worker cannot currently be kept alive by WebKit on
      // iOS. Keep its public message/storage contract intact in extension
      // pages so the original panel, options and persistence continue to work.
      // The command check deliberately limits this adapter to Tomato Clock.
      const usesTomatoTimerContract = !!(manifest.commands && manifest.commands['start-tomato']
        && manifest.commands['start-short-break'] && manifest.commands['start-long-break']);
      const localStorageArea = chrome.storage && chrome.storage.local;
      const storageCall = (method, value) => new Promise((resolve, reject) => {
        if (!localStorageArea || typeof localStorageArea[method] !== 'function') {
          reject(new Error('Local extension storage is unavailable.'));
          return;
        }
        let settled = false;
        const done = result => { if (!settled) { settled = true; resolve(result); } };
        try {
          const result = localStorageArea[method](value, done);
          if (result && typeof result.then === 'function') result.then(done, reject);
        } catch (error) { reject(error); }
      });
      const idleTimerState = () => ({ status: 'idle', type: null,
        scheduledTime: null, totalTime: null });
      const getTomatoTimerState = async () => {
        const values = await storageCall('get', 'timer');
        const state = values && values.timer;
        if (!state || state.status === 'idle') return idleTimerState();
        if (state.status === 'running' && Number(state.scheduledTime) <= Date.now()) {
          await storageCall('remove', 'timer');
          return idleTimerState();
        }
        return state;
      };
      const setTomatoTimerState = async state => {
        await storageCall('set', { timer: state });
        return state;
      };
      const handleTomatoTimerMessage = async message => {
        const action = String(message && message.action || '');
        if (action === 'getTimerState') return getTomatoTimerState();
        if (action === 'resetTimer') {
          await storageCall('remove', 'timer');
          return idleTimerState();
        }
        if (action === 'setTimer') {
          const type = message && message.data && message.data.type;
          const settingsValues = await storageCall('get', 'settings');
          const settings = settingsValues && settingsValues.settings || {};
          const minutes = type === 'shortBreak' ? Number(settings.minutesInShortBreak || 5)
            : type === 'longBreak' ? Number(settings.minutesInLongBreak || 15)
            : Number(settings.minutesInTomato || 25);
          const totalTime = Math.max(1, minutes) * 60 * 1000;
          return setTomatoTimerState({ status: 'running', type: type || 'tomato',
            scheduledTime: Date.now() + totalTime, totalTime });
        }
        if (action === 'pauseTimer') {
          const state = await getTomatoTimerState();
          if (state.status !== 'running') return state;
          return setTomatoTimerState({ status: 'paused', type: state.type,
            remainingTime: Math.max(0, state.scheduledTime - Date.now()), totalTime: state.totalTime });
        }
        if (action === 'resumeTimer') {
          const state = await getTomatoTimerState();
          if (state.status !== 'paused') return state;
          return setTomatoTimerState({ status: 'running', type: state.type,
            scheduledTime: Date.now() + state.remainingTime, totalTime: state.totalTime });
        }
        return undefined;
      };

      const originalSendMessage = typeof chrome.runtime.sendMessage === 'function'
        ? chrome.runtime.sendMessage.bind(chrome.runtime) : null;
      const compatibleSendMessage = function(...args) {
        const firstMessageIndex = typeof args[0] === 'string' ? 1 : 0;
        const message = args[firstMessageIndex];
        const action = String(message && message.action || '').toLowerCase();
        const source = message && message.data && message.data.src;
        const callback = typeof args[args.length - 1] === 'function'
          ? args[args.length - 1] : undefined;
        if (usesTomatoTimerContract && ['settimer', 'resettimer', 'gettimerstate',
          'pausetimer', 'resumetimer'].includes(action)) {
          const result = handleTomatoTimerMessage(message);
          if (callback) {
            result.then(callback, () => callback(undefined));
            return undefined;
          }
          return result;
        }
        if (offscreenOpen && action.includes('offscreen') && (source || action.includes('stop'))) {
          return native({ souloCompatibility: 1, api: 'audio',
            operation: action.includes('stop') ? 'stop' : 'play', source: source || '' }, callback);
        }
        return originalSendMessage ? originalSendMessage(...args) : Promise.resolve();
      };
      try { chrome.runtime.sendMessage = compatibleSendMessage; } catch (_) {}
    })();
    """#
}

private enum SafeZIPExtractor {
    private struct Entry {
        let path: String
        let flags: UInt16
        let compressionMethod: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let maximumEntryCount = 20_000
    private static let maximumEntrySize = 256 * 1_024 * 1_024
    private static let maximumExpandedSize = 768 * 1_024 * 1_024

    static func extract(_ archive: Data, to destination: URL) throws {
        let entries = try centralDirectoryEntries(in: archive)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        // Device container URLs can spell the same directory through /var and
        // /private/var. Compare canonical paths on both sides of the boundary.
        let canonicalDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = canonicalDestination.path + "/"

        for entry in entries {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"), !entry.path.contains("\0") else {
                throw BrowserExtensionError.invalidExtension
            }
            let outputURL = canonicalDestination
                .appendingPathComponent(entry.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard outputURL.path.hasPrefix(rootPath) else {
                BrowserStartupTrace.mark("extension_archive_path_rejected", detail: "rootTrailingSlash=\(destination.standardizedFileURL.path.hasSuffix("/")) entry=\(entry.path)")
                throw BrowserExtensionError.invalidExtension
            }
            if entry.path.hasSuffix("/") {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try payload(for: entry, in: archive)
            try payload.write(to: outputURL, options: .atomic)
        }
    }

    private static func centralDirectoryEntries(in data: Data) throws -> [Entry] {
        let eocdSignature: UInt32 = 0x06054B50
        let minimumEOCDSize = 22
        guard data.count >= minimumEOCDSize else { throw BrowserExtensionError.invalidExtension }
        let searchStart = max(0, data.count - minimumEOCDSize - 65_535)
        var eocdOffset: Int?
        var cursor = data.count - minimumEOCDSize
        while cursor >= searchStart {
            if data.littleEndianUInt32(at: cursor) == eocdSignature {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let eocdOffset,
              data.littleEndianUInt16(at: eocdOffset + 4) == 0,
              data.littleEndianUInt16(at: eocdOffset + 6) == 0,
              let entryCountValue = data.littleEndianUInt16(at: eocdOffset + 10),
              let directorySizeValue = data.littleEndianUInt32(at: eocdOffset + 12),
              let directoryOffsetValue = data.littleEndianUInt32(at: eocdOffset + 16)
        else { throw BrowserExtensionError.invalidExtension }

        let entryCount = Int(entryCountValue)
        let directorySize = Int(directorySizeValue)
        let directoryOffset = Int(directoryOffsetValue)
        guard entryCount <= maximumEntryCount,
              directoryOffset >= 0,
              directorySize >= 0,
              directoryOffset + directorySize <= data.count else {
            throw BrowserExtensionError.invalidExtension
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var totalExpandedSize = 0
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard data.littleEndianUInt32(at: offset) == 0x02014B50,
                  let flags = data.littleEndianUInt16(at: offset + 8),
                  let method = data.littleEndianUInt16(at: offset + 10),
                  let crc = data.littleEndianUInt32(at: offset + 16),
                  let compressedValue = data.littleEndianUInt32(at: offset + 20),
                  let uncompressedValue = data.littleEndianUInt32(at: offset + 24),
                  let nameLengthValue = data.littleEndianUInt16(at: offset + 28),
                  let extraLengthValue = data.littleEndianUInt16(at: offset + 30),
                  let commentLengthValue = data.littleEndianUInt16(at: offset + 32),
                  let localOffsetValue = data.littleEndianUInt32(at: offset + 42)
            else { throw BrowserExtensionError.invalidExtension }
            guard flags & 0x0001 == 0 else { throw BrowserExtensionError.invalidExtension }

            let compressedSize = Int(compressedValue)
            let uncompressedSize = Int(uncompressedValue)
            let nameLength = Int(nameLengthValue)
            let extraLength = Int(extraLengthValue)
            let commentLength = Int(commentLengthValue)
            let nextOffset = offset + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, nextOffset <= data.count,
                  compressedSize <= maximumEntrySize,
                  uncompressedSize <= maximumEntrySize else {
                throw BrowserExtensionError.invalidExtension
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let path = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1) else {
                throw BrowserExtensionError.invalidExtension
            }
            totalExpandedSize += uncompressedSize
            guard totalExpandedSize <= maximumExpandedSize else {
                throw BrowserExtensionError.invalidExtension
            }
            entries.append(Entry(
                path: path.replacingOccurrences(of: "\\", with: "/"),
                flags: flags,
                compressionMethod: method,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: Int(localOffsetValue)
            ))
            offset = nextOffset
        }
        return entries
    }

    private static func payload(for entry: Entry, in data: Data) throws -> Data {
        let offset = entry.localHeaderOffset
        guard data.littleEndianUInt32(at: offset) == 0x04034B50,
              let nameLength = data.littleEndianUInt16(at: offset + 26),
              let extraLength = data.littleEndianUInt16(at: offset + 28) else {
            throw BrowserExtensionError.invalidExtension
        }
        let payloadOffset = offset + 30 + Int(nameLength) + Int(extraLength)
        guard payloadOffset >= 0,
              entry.compressedSize >= 0,
              payloadOffset + entry.compressedSize <= data.count else {
            throw BrowserExtensionError.invalidExtension
        }
        let compressed = data.subdata(in: payloadOffset..<(payloadOffset + entry.compressedSize))
        let result: Data
        switch entry.compressionMethod {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw BrowserExtensionError.invalidExtension
            }
            result = compressed
        case 8:
            result = try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw BrowserExtensionError.invalidExtension
        }
        let calculatedCRC = result.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        guard UInt32(calculatedCRC) == entry.crc else {
            throw BrowserExtensionError.invalidExtension
        }
        return result
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw BrowserExtensionError.invalidExtension }
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        let status: Int32 = compressed.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                stream.next_in = UnsafeMutablePointer(
                    mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(inputBytes.count)
                stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBytes.count)
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return Z_STREAM_ERROR
                }
                defer { inflateEnd(&stream) }
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END,
              stream.total_out == expectedSize,
              stream.avail_in == 0 else {
            throw BrowserExtensionError.invalidExtension
        }
        return output
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

/// Routes only to the extension's own documents, bound to native sender IDs.
/// Preserve a padding-ratio video box when an injected extension frame
/// replaces a zero-height overflowing wrapper. WebKit masks frame URLs even
/// from the owning content world; this changes geometry only, never access.
private enum ExtensionMediaLayoutScript {
    static let javaScript = #"""
    (()=>{
      const api=globalThis.chrome||globalThis.browser;
      if(typeof document==='undefined'||!/^https?:$/.test(location.protocol)||!api?.runtime?.getURL||globalThis.__souloExtensionMediaLayout)return;
      let own;try{own=new URL(api.runtime.getURL(''));}catch(_){return;}
      if(own.protocol!=='webkit-extension:')return;
      Object.defineProperty(globalThis,'__souloExtensionMediaLayout',{value:true});
      const records=new Map(),videos=new Set(),frames=new Map();let scheduled=false;
      const owns=f=>{try{const u=new URL(f.getAttribute('src')||f.src,location.href);return u.protocol===own.protocol&&u.host===own.host||u.protocol==='webkit-masked-url:'&&u.host==='hidden';}catch(_){return false;}};
      function capture(v){
        const r=v.getBoundingClientRect();if(r.width<100||r.height<80)return;
        for(let e=v.parentElement,n=0;e&&e!==document.body&&n<8;e=e.parentElement,n++){
          const parent=e.parentElement;if(!parent)break;
          const z=e.getBoundingClientRect(),p=parent.getBoundingClientRect(),s=getComputedStyle(parent);
          const padding=(parseFloat(s.paddingTop)||0)+(parseFloat(s.paddingBottom)||0);
          // A visible, absolutely positioned video can overflow a zero-height
          // wrapper inside a padding-ratio box. Replacing that wrapper loses the
          // video's bounds even though the surrounding player still reserves them.
          if(z.height<=1&&Math.abs(p.width-r.width)<4&&Math.abs(p.height-r.height)<4&&padding>=r.height*.85&&s.position!=='static'){
            records.set(parent,{wrapper:e,video:v});
            if(records.size>32)records.delete(records.keys().next().value);
          }
        }
      }
      function repair(f,parent){
        if(!owns(f)||!parent.isConnected)return;
        const s=getComputedStyle(f),p=getComputedStyle(parent);
        if(s.display==='none'||s.position==='fixed'||document.fullscreenElement?.contains(f))return;
        const height=(parseFloat(p.paddingTop)||0)+(parseFloat(p.paddingBottom)||0),width=parent.clientWidth;
        if(height<80||width<100||p.position==='static')return;
        const previous=frames.get(f),actual=f.getBoundingClientRect();
        if(!previous&&actual.height>=height*.75)return;
        if(!previous){
          if(frames.size>=16)return;
          const observer=new MutationObserver(()=>schedule());
          observer.observe(f,{attributes:true,attributeFilter:['style','class','src']});
          frames.set(f,{parent,observer,before:{},written:{}});resize.observe(parent);
        }
        for(const [key,value] of Object.entries({position:'absolute',top:'0px',left:'0px',width:width+'px',height:height+'px',padding:'0px'})){
          const state=frames.get(f);
          if(!(key in state.before))state.before[key]=[f.style.getPropertyValue(key),f.style.getPropertyPriority(key)];
          state.written[key]=value;
          if(f.style.getPropertyValue(key)!==value||f.style.getPropertyPriority(key)!=='important')f.style.setProperty(key,value,'important');
        }
      }
      function update(){
        scheduled=false;
        for(const [frame,value] of frames){
          if(!frame.isConnected||!owns(frame)){value.observer.disconnect();resize.unobserve(value.parent);frames.delete(frame);for(const [key,old]of Object.entries(value.before))if(frame.style.getPropertyValue(key)===value.written[key]&&frame.style.getPropertyPriority(key)==='important'){if(old[0])frame.style.setProperty(key,...old);else frame.style.removeProperty(key);}continue;}
          repair(frame,value.parent);
        }
        for(const [parent,value] of records){
          if(!parent.isConnected){records.delete(parent);continue;}
          for(const frame of parent.children){
            if(frame.tagName!=='IFRAME'||!owns(frame))continue;
            const w=value.wrapper;
            if(!w.isConnected||w.parentElement===parent&&(w.getBoundingClientRect().height<=1||w.getBoundingClientRect().width<=1))repair(frame,parent);
          }
        }
      }
      function schedule(){if(!scheduled){scheduled=true;requestAnimationFrame(update);}}
      const resize=new ResizeObserver(entries=>{for(const entry of entries)if(entry.target.tagName==='VIDEO')capture(entry.target);schedule();});
      function watch(v){if(videos.has(v)){capture(v);return;}if(videos.size>=32){for(const old of videos)if(!old.isConnected){resize.unobserve(old);videos.delete(old);}}if(videos.size>=32)return;videos.add(v);resize.observe(v);capture(v);}
      function scan(node){if(node.nodeType!==1&&node.nodeType!==9)return;if(node.tagName==='VIDEO')watch(node);for(const v of node.querySelectorAll('video'))watch(v);}
      const mutations=new MutationObserver(entries=>{let changed=false;for(const entry of entries)for(const node of entry.addedNodes){if(node.nodeType!==1)continue;scan(node);if(node.tagName==='IFRAME'||node.querySelector('iframe'))changed=true;}if(changed||frames.size)schedule();});
      mutations.observe(document,{childList:true,subtree:true});
      for(const type of ['loadedmetadata','play'])addEventListener(type,e=>{if(e.target?.tagName==='VIDEO')watch(e.target);},true);
      addEventListener('resize',()=>{for(const v of videos)capture(v);schedule();},{passive:true});
      addEventListener('DOMContentLoaded',()=>scan(document),{once:true});scan(document);
    })();
    """#
}

private enum ExtensionFrameMessagingScript {
    static let documentFilename = "__soulo_webextension_frame_document.js"
    static let backgroundFilename = "__soulo_webextension_frame_background.js"
    static let javaScript = #"""
    (()=>{
      const api=globalThis.chrome||globalThis.browser,runtime=api?.runtime,event=runtime?.onMessage;
      if(!event?.addListener||!runtime.sendMessage||!runtime.getURL||typeof URL!=='function'||globalThis.__souloFrameMessagingCore)return;
      const marker='__soulo_extension_frame_v1';
      const own=new URL(runtime.getURL(''));
      const send=runtime.sendMessage.bind(runtime),add=event.addListener.bind(event);
      const remove=event.removeListener.bind(event),has=event.hasListener.bind(event);
      const listeners=new Map();
      function ownURL(value){try{const u=new URL(value);return u.protocol===own.protocol&&u.host===own.host;}catch(_){return false;}}
      function trusted(sender){return sender?.id===runtime.id&&(sender.url==null||ownURL(sender.url));}
      // WebKit exposes the container on custom-scheme documents, but rejects
      // registering any same-origin worker (only HTTP/HTTPS are accepted).
      // Advertise that actual document capability so packaged libraries can
      // use their Blob fallback. The native extension background stays intact.
      if(typeof document!=='undefined'&&ownURL(location.href)&&own.protocol==='webkit-extension:'&&!globalThis.__souloOffscreenWorkerReceiver){
        try{Object.defineProperty(navigator,'serviceWorker',{configurable:true,value:undefined});}catch(_){}
      }
      function protocol(value){return value&&value[marker]===1;}
      function packet(kind,extra){return {[marker]:1,kind,...extra};}
      function request(message){return new Promise((resolve,reject)=>{
        try{send(message,value=>{const error=runtime.lastError;error?reject(new Error(error.message||String(error))):resolve(value);});}
        catch(error){reject(error);}
      });}
      // Real ManagedMediaSource supplies MSE on iPhone. Restrict the alias and
      // required remote-playback setting to extension-owned documents and URLs.
      if(typeof document!=='undefined'&&ownURL(location.href)&&typeof globalThis.MediaSource==='undefined'&&typeof globalThis.ManagedMediaSource==='function'){
        const Managed=globalThis.ManagedMediaSource,urls=new Set();
        const create=URL.createObjectURL.bind(URL),revoke=URL.revokeObjectURL.bind(URL);
        Object.defineProperty(globalThis,'MediaSource',{configurable:true,writable:true,value:Managed});
        URL.createObjectURL=function(value){const url=create(value);if(value instanceof Managed)urls.add(url);return url;};
        URL.revokeObjectURL=function(url){urls.delete(String(url));return revoke(url);};
        function prepare(media,value){
          if(!urls.has(String(value)))return;
          const alternative=Array.from(media.querySelectorAll('source')).some(source=>{
            try{return ['http:','https:'].includes(new URL(source.src).protocol)&&!!source.type&&!!media.canPlayType(source.type);}catch(_){return false;}
          });
          if(!alternative)media.disableRemotePlayback=true;
        }
        const descriptor=Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,'src');
        if(descriptor?.set&&descriptor.configurable)Object.defineProperty(HTMLMediaElement.prototype,'src',{
          ...descriptor,set(value){prepare(this,value);return Reflect.apply(descriptor.set,this,[value]);}
        });
        const setAttribute=Element.prototype.setAttribute;
        Element.prototype.setAttribute=function(name,value){if(this instanceof HTMLMediaElement&&String(name).toLowerCase()==='src')prepare(this,value);return Reflect.apply(setAttribute,this,[name,value]);};
      }

      const core={ownURL,trusted,protocol,packet,request,send,add,listeners};
      const ownedBlobs=new Set();
      if(typeof document!=='undefined'&&ownURL(location.href)&&typeof Blob==='function'){
        const create=URL.createObjectURL.bind(URL),revoke=URL.revokeObjectURL.bind(URL);
        const size=Object.getOwnPropertyDescriptor(Blob.prototype,'size').get;
        URL.createObjectURL=function(value){const url=create(value);try{Reflect.apply(size,value,[]);ownedBlobs.add(url);}catch(_){}return url;};
        URL.revokeObjectURL=function(url){ownedBlobs.delete(String(url));return revoke(url);};
      }
      function frameNetwork(){
        const nativeFetch=globalThis.fetch?.bind(globalThis),active=new Map();
        const bytesToText=bytes=>{let text='';for(let i=0;i<bytes.length;i+=8192)text+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(text);};
        const textToBytes=text=>Uint8Array.from(atob(text),c=>c.charCodeAt(0));
        const same=(a,b)=>a.tabId===b.tabId&&a.frameId===b.frameId&&a.nonce===b.nonce;
        function close(id){const item=active.get(id);if(item){active.delete(id);item.controller.abort();item.reader?.cancel().catch(()=>{});}}
        function closeFrame(frame){for(const[id,item]of active)if(same(item,frame))close(id);}
        async function handle(m,frame){
          if(m.operation==='open'){
            const url=new URL(m.url),method=m.method;
            if(!['http:','https:'].includes(url.protocol)||!['GET','HEAD'].includes(method)||url.username||url.password)throw new Error('Unsupported embedded extension request');
            if(active.size>=24||typeof m.id!=='string'||!/^[a-f0-9-]{36}$/.test(m.id)||active.has(m.id))throw new Error('Invalid embedded extension request identifier');
            const controller=new AbortController(),id=m.id;
            const item={...frame,controller,touched:Date.now(),reader:null,left:null};active.set(id,item);startReaper();
            try{
              if(!await api.permissions.contains({origins:[url.protocol+'//'+url.hostname+'/*']}))throw new Error('Host permission is not granted');
              if(active.get(id)!==item)throw new DOMException('Aborted','AbortError');
              const response=await nativeFetch(url.href,{method,headers:m.headers,credentials:m.credentials,redirect:m.redirect,cache:m.cache,signal:controller.signal});
              if(!active.has(id))throw new DOMException('Aborted','AbortError');
              item.reader=response.body?.getReader();
              if(!item.reader)active.delete(id);
              return {id,status:response.status,statusText:response.statusText,url:response.url,redirected:response.redirected,headers:Array.from(response.headers),done:!item.reader};
            }catch(error){close(id);throw error;}
          }
          const item=active.get(m.id);
          if(!item||!same(item,frame))throw new Error('The embedded extension request is no longer active');
          item.touched=Date.now();
          if(m.operation==='cancel'){close(m.id);return {};}
          if(m.operation!=='read'||item.reading)throw new Error('Invalid embedded extension read');
          item.reading=true;
          try{
            const result=item.left?{value:item.left,done:false}:await item.reader.read();
            if(result.done){active.delete(m.id);return {done:true};}
            const bytes=result.value,part=bytes.subarray(0,96*1024);
            item.left=part.length<bytes.length?bytes.subarray(part.length):null;
            return {done:false,data:bytesToText(part)};
          }catch(error){close(m.id);throw error;}finally{item.reading=false;}
        }
        function installDocument(sendRequest){
          if(core.networkDocumentInstalled||!nativeFetch)return;core.networkDocumentInstalled=true;
          const crossHTTP=value=>{try{const u=new URL(value,location.href);return ['http:','https:'].includes(u.protocol)&&!ownURL(u.href);}catch(_){return false;}};
          async function relay(input,init){
            const requestObject=new Request(input,init),signal=requestObject.signal;
            if(signal.aborted)throw signal.reason||new DOMException('Aborted','AbortError');
            const id=crypto.randomUUID();
            const abort=()=>{if(id)sendRequest({operation:'cancel',id}).catch(()=>{});};
            signal.addEventListener('abort',abort,{once:true});
            try{
              const head=await sendRequest({operation:'open',id,url:requestObject.url,method:requestObject.method,headers:Array.from(requestObject.headers),credentials:requestObject.credentials,redirect:requestObject.redirect,cache:requestObject.cache});
              if(signal.aborted){abort();throw signal.reason||new DOMException('Aborted','AbortError');}
              const detach=()=>signal.removeEventListener('abort',abort);
              const body=head.done?null:new ReadableStream({
                async pull(controller){try{if(signal.aborted)throw signal.reason||new DOMException('Aborted','AbortError');const chunk=await sendRequest({operation:'read',id});if(chunk.done){detach();controller.close();}else controller.enqueue(textToBytes(chunk.data));}catch(error){detach();abort();controller.error(error);}},
                cancel(){detach();abort();}
              },{highWaterMark:0});
              if(head.done)detach();
              const response=new Response(body,{status:head.status,statusText:head.statusText,headers:head.headers});
              Object.defineProperties(response,{url:{value:head.url},redirected:{value:head.redirected}});
              return response;
            }catch(error){signal.removeEventListener('abort',abort);throw error;}
          }
          globalThis.fetch=async function(input,init){
            const method=String(init?.method??(input instanceof Request?input.method:'GET')).toUpperCase();
            const url=input instanceof Request?input.url:String(input);
            try{return await nativeFetch(input,init);}catch(error){
              if(error?.name!=='TypeError'||!['GET','HEAD'].includes(method)||!crossHTTP(url)||init?.signal?.aborted||input?.signal?.aborted)throw error;
              return relay(input,init);
            }
          };
          const NativeXHR=globalThis.XMLHttpRequest;
          if(!NativeXHR)return;
          globalThis.XMLHttpRequest=new Proxy(NativeXHR,{construct(Target,args){
            const native=Reflect.construct(Target,args),hub=new EventTarget(),handlers={},listeners=new Map();
            let proxy,method,url,asynchronous=true,headers=[],started=0,controller,relaying=false,done=false,override=null,timer,epoch=0;
            const emit=(type,event)=>{
              const e=new ProgressEvent(type,{lengthComputable:event?.lengthComputable??false,loaded:event?.loaded??0,total:event?.total??0});
              Object.defineProperties(e,{target:{value:proxy},currentTarget:{value:proxy}});
              if(typeof handlers[type]==='function')try{handlers[type].call(proxy,e);}catch(error){setTimeout(()=>{throw error;});}
              hub.dispatchEvent(e);
            };
            const end=(type)=>{if(done)return;done=true;clearTimeout(timer);override.readyState=4;emit('readystatechange');emit(type);emit('loadend');};
            async function retry(){
              if(relaying||done)return;relaying=true;const requestEpoch=epoch,requestController=new AbortController();controller=requestController;
              const remaining=native.timeout?native.timeout-(Date.now()-started):0;
              if(native.timeout){if(remaining<=0){override={readyState:4,status:0,statusText:'',response:null,responseText:''};end('timeout');return;}timer=setTimeout(()=>{if(epoch===requestEpoch){requestController.abort();end('timeout');}},remaining);}
              override={readyState:1,status:0,statusText:'',response:null,responseText:'',responseURL:'',responseXML:null,headers:new Headers()};
              try{
                const response=await relay(url,{method,headers,credentials:native.withCredentials?'include':'same-origin',signal:requestController.signal});
                if(epoch!==requestEpoch||done){response.body?.cancel();return;}
                Object.assign(override,{readyState:2,status:response.status,statusText:response.statusText,responseURL:response.url,headers:response.headers});emit('readystatechange');
                const chunks=[];let loaded=0;const total=Number(response.headers.get('Content-Length'))||0,reader=response.body?.getReader();
                if(reader)while(!done&&epoch===requestEpoch){const chunk=await reader.read();if(chunk.done||epoch!==requestEpoch)break;chunks.push(chunk.value);loaded+=chunk.value.length;override.readyState=3;emit('readystatechange');emit('progress',{loaded,total,lengthComputable:total>0});}
                if(done||epoch!==requestEpoch)return;
                const blob=new Blob(chunks,{type:response.headers.get('Content-Type')||''}),type=native.responseType;
                if(type==='arraybuffer')override.response=await blob.arrayBuffer();
                else if(type==='blob')override.response=blob;
                else {const text=await blob.text();override.responseText=text;if(type==='json'){try{override.response=JSON.parse(text);}catch(_){override.response=null;}}else if(type==='document'){override.responseXML=new DOMParser().parseFromString(text,'application/xml');override.response=override.responseXML;}else override.response=text;}
                if(epoch===requestEpoch)end('load');
              }catch(error){if(!done&&epoch===requestEpoch)end(requestController.signal.aborted?'abort':'error');}
            }
            for(const type of ['loadstart','readystatechange','progress','load','error','abort','timeout','loadend'])native.addEventListener(type,event=>{
              const fallback=asynchronous&&['GET','HEAD'].includes(method)&&crossHTTP(url);
              if(relaying)return;
              if(fallback&&native.readyState===4&&native.status===0){if(type==='error'){retry();return;}if(type==='readystatechange'||type==='loadend')return;}
              emit(type,event);
            });
            proxy=new Proxy(native,{
              get(target,key){
                if(key==='open')return function(m,u,async=true,...rest){epoch++;controller?.abort();clearTimeout(timer);method=String(m).toUpperCase();url=new URL(String(u),location.href).href;asynchronous=async!==false;headers=[];relaying=false;done=false;override=null;return native.open(m,u,async,...rest);};
                if(key==='send')return function(body){started=Date.now();return native.send(body);};
                if(key==='abort')return function(){if(relaying&&!done){controller.abort();end('abort');}else native.abort();};
                if(key==='setRequestHeader')return function(name,value){native.setRequestHeader(name,value);headers.push([String(name),String(value)]);};
                if(key==='getAllResponseHeaders')return ()=>override?Array.from(override.headers,([k,v])=>k+': '+v+'\r\n').join(''):native.getAllResponseHeaders();
                if(key==='getResponseHeader')return name=>override?override.headers.get(name):native.getResponseHeader(name);
                if(key==='addEventListener')return (type,listener,options)=>{if(!listener)return;let wrapped=listeners.get(listener);if(!wrapped){wrapped=e=>typeof listener==='function'?listener.call(proxy,e):listener.handleEvent(e);listeners.set(listener,wrapped);}hub.addEventListener(type,wrapped,options);};
                if(key==='removeEventListener')return (type,listener,options)=>hub.removeEventListener(type,listeners.get(listener)||listener,options);
                if(typeof key==='string'&&key.startsWith('on'))return handlers[key.slice(2)]??null;
                if(override&&key==='responseText'&&!['','text'].includes(native.responseType))throw new DOMException('The response type is not text','InvalidStateError');
                if(override&&Object.hasOwn(override,key))return override[key];
                const value=Reflect.get(target,key,target);return typeof value==='function'?value.bind(target):value;
              },
              set(target,key,value){if(typeof key==='string'&&key.startsWith('on')){handlers[key.slice(2)]=value;return true;}return Reflect.set(target,key,value,target);}
            });return proxy;
          }});
        }
        function startReaper(){if(core.networkReaper)return;core.networkReaper=setInterval(()=>{for(const[id,item]of active)if(Date.now()-item.touched>120000)close(id);if(!active.size){clearInterval(core.networkReaper);core.networkReaper=null;}},30000);}
        return {handle,closeFrame,installDocument,startReaper};
      }

      core.network=frameNetwork();
      globalThis.__souloFrameMessagingCore=core;
      globalThis.__souloNativeBindingsObjects?.push(event,core);
      // Retain the actual publisher callback identity. Internal routing envelopes
      // never enter publisher handlers, while ordinary messages stay native.
      Object.defineProperties(event,{
        addListener:{configurable:true,writable:true,value:function(listener){
          if(typeof listener!=='function')return add(listener);
          if(listeners.has(listener))return;
          const wrapped=function(message,sender,reply){if(protocol(message)&&(trusted(sender)||message.kind==='mediaSourceChanged'&&sender?.id===runtime.id))return;core.observeOwnedSender?.(sender);return Reflect.apply(listener,this,[message,sender,reply]);};
          listeners.set(listener,wrapped);return add(wrapped);
        }},
        removeListener:{configurable:true,writable:true,value:function(listener){const wrapped=listeners.get(listener)||listener;listeners.delete(listener);return remove(wrapped);}},
        hasListener:{configurable:true,writable:true,value:function(listener){return has(listeners.get(listener)||listener);}},
        hasListeners:{configurable:true,writable:true,value:function(){return listeners.size>0;}}
      });
      globalThis.__souloInstallExtensionFrameDocument=()=>{
        if(core.documentInstalled||typeof document==='undefined'||!ownURL(location.href))return;
        core.documentInstalled=true;
        const nonce=Array.from(crypto.getRandomValues(new Uint8Array(16)),n=>n.toString(16).padStart(2,'0')).join('');
        let identity,registration;
        function register(){
          if(identity)return Promise.resolve(identity);
          if(registration)return registration;
          registration=request(packet('register',{nonce,parentFrameId:Number(new URLSearchParams(location.search).get('parent_frame_id')??-1)})).then(value=>{identity=value?.nonce===nonce?value:null;return identity;}).catch(()=>null).finally(()=>{registration=null;});
          return registration;
        }
        function dispatch(message,sender){return new Promise((resolve,reject)=>{
          let settled=false,waiting=false;
          const reply=value=>{if(!settled){settled=true;resolve({[marker]:1,nonce,hasValue:value!==undefined,value:value===undefined?null:value});}};
          if(!listeners.size){reject(new Error('Could not establish connection. Receiving end does not exist.'));return;}
          for(const listener of listeners.keys()){
            try{const value=Reflect.apply(listener,undefined,[message,sender,reply]);
              if(value===true)waiting=true;
              else if(value&&typeof value.then==='function'){waiting=true;value.then(reply,error=>{if(!settled){settled=true;reject(error);}});}
            }catch(error){if(!settled){settled=true;reject(error);}}
          }
          if(!waiting&&!settled)reply(undefined);
        });}
        add((message,sender,reply)=>{
          if(!protocol(message)||!trusted(sender))return;
          if(message.kind==='nativeProbe'&&message.nonce===nonce){reply(packet('nativeProbeReply',{nonce}));return;}
          if(message.kind==='backgroundReady'){identity=null;register();return;}
          if(message.nonce===nonce&&identity&&['ownedDocumentQuery','saveOwnedDocument'].includes(message.kind)){
            if(message.kind==='ownedDocumentQuery'){reply({owned:ownedBlobs.has(message.options?.url)});return;}
            if(!ownedBlobs.has(message.options?.url)){reply({error:'The document no longer owns this Blob'});return;}
            const options=message.options;
            try{
              runtime.sendNativeMessage('com.dkluge.Soulo.WebExtensionCompatibility',
                {souloCompatibility:1,api:'documentDownload',operation:'observe',options},result=>{
                  const error=runtime.lastError;reply(error?{error:error.message}:result);
                });
              const link=document.createElement('a');link.href=options.url;link.download=options.filename||'download';
              document.body.appendChild(link);link.click();link.remove();
            }catch(error){reply({error:String(error?.message??error)});}
            return true;
          }
          if(message.kind==='mediaSourceDelivery'&&message.nonce===nonce&&identity&&message.tabId===identity.tabId&&message.frameId===identity.frameId){
            if(typeof core.applyMediaSource!=='function'){reply({handled:false});return;}
            Promise.resolve(core.applyMediaSource(message)).then(reply,error=>reply({handled:false,error:String(error?.message??error)}));return true;
          }
          if(message.kind!=='deliver'||message.nonce!==nonce)return;
          // A publisher can send its first ready message before our registration
          // reply returns. Keep the original message until that handshake settles.
          (async()=>{
            const current=await register();
            if(!current||message.tabId!==current.tabId||message.frameId!==current.frameId)throw new Error('Extension frame is unavailable');
            return await dispatch(message.message,sender);
          })().then(reply,error=>reply(packet('error',{nonce,error:String(error?.message??error)})));
          return true;
        });
        core.network.installDocument(async values=>{await register();if(!identity)throw new Error('Extension frame is unavailable');const result=await request(packet('network',{nonce,...values}));if(result?.error)throw new Error(result.error);return result;});
        register();
        addEventListener('pageshow',()=>register());
        addEventListener('pagehide',()=>{identity=null;try{send(packet('unregister',{nonce}),()=>{void runtime.lastError;});}catch(_){}});
      };
      globalThis.__souloInstallExtensionFrameBackground=()=>{
        if(core.backgroundInstalled||!api.tabs?.sendMessage)return;
        core.backgroundInstalled=true;
        const tabs=api.tabs,native=tabs.sendMessage.bind(tabs),frames=new Map(),pendingFrames=new Map();
        core.saveOwnedDocument=async options=>{
          if(typeof options?.url!=='string'||!options.url.startsWith('blob:'+runtime.getURL('')))throw new Error('Not an owned extension document');
          for(const frame of frames.values()){
            const owner=await request(packet('ownedDocumentQuery',{nonce:frame.nonce,options}));
            if(owner?.owned){
              const result=await request(packet('saveOwnedDocument',{nonce:frame.nonce,options}));
              if(result?.error)throw new Error(result.error);
              return result;
            }
          }
          throw new Error('The originating extension document is no longer available');
        };
        const key=(tabId,frameId)=>tabId+':'+frameId;
        function settleFrame(id){
          const pending=pendingFrames.get(id);if(!pending)return;
          pendingFrames.delete(id);clearTimeout(pending.timer);pending.resolve(frames.get(id)||null);
        }
        core.observeOwnedSender=sender=>{
          const tabId=sender?.tab?.id,frameId=sender?.frameId;
          if(!trusted(sender)||!ownURL(sender.url)||!Number.isSafeInteger(tabId)||tabId<1||!Number.isSafeInteger(frameId)||frameId<0)return;
          const id=key(tabId,frameId);if(frames.has(id)||pendingFrames.has(id)||pendingFrames.size>=128)return;
          let resolve;const promise=new Promise(done=>{resolve=done;});
          const pending={tabId,frameId,documentId:sender.documentId,promise,resolve,timer:setTimeout(()=>settleFrame(id),1000)};
          pendingFrames.set(id,pending);
        };
        function nativeRequest(tabId,message,options){return new Promise((resolve,reject)=>{
          try{native(tabId,message,options,value=>{const error=runtime.lastError;error?reject(new Error(error.message||String(error))):resolve(value);});}
          catch(error){reject(error);}
        });}
        add((message,sender,reply)=>{
          if(protocol(message)&&message.kind==='mediaSourceChanged'&&sender?.id===runtime.id&&/^https?:/.test(sender.url||'')){
            const tabId=sender.tab?.id,parentId=sender.frameId;
            const targets=Array.from(frames.values()).filter(frame=>frame.tabId===tabId&&frame.parentFrameId===parentId);
            if(targets.length!==1||typeof message.url!=='string'||message.url.length>8192){reply({handled:false});return;}
            (async()=>{
              const url=new URL(message.url),page=new URL(sender.url);
              if(!['http:','https:'].includes(url.protocol)||url.username||url.password)return {handled:false};
              if(!await api.permissions.contains({origins:[url.protocol+'//'+url.hostname+'/*',page.protocol+'//'+page.hostname+'/*']}))return {handled:false};
              const target=targets[0];return await request(packet('mediaSourceDelivery',{...target,url:url.href,play:message.play===true}));
            })().then(reply,error=>reply({handled:false,error:String(error?.message??error)}));return true;
          }
          if(!protocol(message)||!trusted(sender)||!ownURL(sender.url))return;
          const tabId=sender.tab?.id,frameId=sender.frameId;
          if(!Number.isSafeInteger(tabId)||tabId<1||!Number.isSafeInteger(frameId)||frameId<0)return;
          const id=key(tabId,frameId);
          if(message.kind==='saveDocument'){
            if(!frames.has(id))return;
            core.saveOwnedDocument(message.options).then(reply,error=>reply({error:String(error?.message??error)}));return true;
          }
          if(message.kind==='network'){
            const frame=frames.get(id);if(!frame||frame.nonce!==message.nonce)return;
            core.network.handle(message,frame).then(reply,error=>reply({error:String(error?.message??error)}));return true;
          }
          if(message.kind==='unregister'){const frame=frames.get(id);if(frame?.nonce===message.nonce){core.network.closeFrame(frame);frames.delete(id);settleFrame(id);}return;}
          if(message.kind!=='register'||typeof message.nonce!=='string'||!/^[a-f0-9]{32}$/.test(message.nonce))return;
          let frame=frames.get(id);
          if(!frame||frame.nonce!==message.nonce){
            if(frame)core.network.closeFrame(frame);
            frame={tabId,frameId,nonce:message.nonce,documentId:sender.documentId,parentFrameId:Number.isSafeInteger(message.parentFrameId)?message.parentFrameId:-1};frames.set(id,frame);
            // Probe only our own control listener. A future WebKit implementation
            // that delivers natively must never execute the publisher message twice.
            frame.nativeReady=Promise.race([nativeRequest(tabId,packet('nativeProbe',{nonce:frame.nonce}),{frameId})
              .then(value=>value?.kind==='nativeProbeReply'&&value.nonce===frame.nonce,()=>false),new Promise(resolve=>setTimeout(()=>resolve(false),1000))]);
          }
          reply({tabId,frameId,nonce:frame.nonce});
          settleFrame(id);
        });
        Object.defineProperty(tabs,'sendMessage',{configurable:true,writable:true,value:function(tabId,message,options,callback){
          const args=Array.from(arguments);
          if(typeof options==='function'){callback=options;options=undefined;}
          if(options&&typeof options!=='object')return native(...args);
          const frame=Number.isSafeInteger(options?.frameId)?frames.get(key(tabId,options.frameId)):
            typeof options?.documentId==='string'?Array.from(frames.values()).find(f=>f.tabId===tabId&&f.documentId===options.documentId):null;
          if(!frame){
            const pending=Number.isSafeInteger(options?.frameId)?pendingFrames.get(key(tabId,options.frameId)):
              typeof options?.documentId==='string'?Array.from(pendingFrames.values()).find(f=>f.tabId===tabId&&f.documentId===options.documentId):null;
            if(!pending)return native(...args);
            if(typeof callback==='function'){pending.promise.then(()=>tabs.sendMessage(...args));return;}
            return pending.promise.then(()=>tabs.sendMessage(...args));
          }
          if(options?.documentId&&frame.documentId!==options.documentId)return native(...args);
          const route=async()=>{
            const supported=await frame.nativeReady;
            if(supported)return {native:true};
            return {message:packet('deliver',{nonce:frame.nonce,tabId:frame.tabId,frameId:frame.frameId,message})};
          };
          const unpack=value=>value?.[marker]===1&&value.nonce===frame.nonce&&value.hasValue?value.value:undefined;
          const promiseReply=value=>{
            if(value?.[marker]===1&&value.nonce===frame.nonce&&value.kind==='error')throw new Error(value.error||'The extension message receiver failed');
            return unpack(value);
          };
          if(typeof callback==='function'){
            route().then(path=>{
              if(path.native)return native(...args);
              // Keep the callback inside WebKit's real lastError scope.
              send(path.message,value=>callback(unpack(value)));
            });return;
          }
          return route().then(path=>path.native?native(...args):request(path.message).then(promiseReply));
        }});
        tabs.onRemoved?.addListener(tabId=>{for(const [id,frame]of frames)if(frame.tabId===tabId){core.network.closeFrame(frame);frames.delete(id);}for(const [id,pending]of pendingFrames)if(pending.tabId===tabId)settleFrame(id);});

        try{send(packet('backgroundReady',{}),()=>{void runtime.lastError;});}catch(_){}
      };
      if(globalThis.__souloFrameDocumentRequested)globalThis.__souloInstallExtensionFrameDocument();
    })();
    """#
}

@MainActor
@available(iOS 18.4, *)
final class WebExtensionCompatibilityHost {
    static let applicationIdentifier = "com.dkluge.Soulo.WebExtensionCompatibility"

    private var audioPlayers: [ObjectIdentifier: AVAudioPlayer] = [:]
    private var offscreenDocuments: [ObjectIdentifier: WebExtensionOffscreenDocument] = [:]
    private let downloads = WebExtensionDownloads()
    private let blobs = WebExtensionBlobBridge()
    let userScripts = WebExtensionUserScripts()
    private final class BadgeTextColors {
        var defaultColor: [Int]?
        let tabs = NSMapTable<AnyObject, NSArray>.weakToStrongObjects()
    }
    private var badgeTextColors: [ObjectIdentifier: BadgeTextColors] = [:]
    private struct InstallationEvent {
        let previousVersion: String?
        let version: String
        var delivered = false
    }
    private var installationEvents: [ObjectIdentifier: InstallationEvent] = [:]

    func prepareInstallation(context: WKWebExtensionContext) {
        let identity = ObjectIdentifier(context)
        guard installationEvents[identity] == nil, let version = context.webExtension.version, !version.isEmpty else { return }
        let key = Self.installationKey(context.uniqueIdentifier)
        installationEvents[identity] = InstallationEvent(previousVersion: UserDefaults.standard.string(forKey: key), version: version)
        // Persist the instance load even if WebKit omits/delays its initial event.
        UserDefaults.standard.set(version, forKey: key)
    }

    func refreshAccess(_ access: WebExtensionAccess, context: WKWebExtensionContext) {
        userScripts.refresh(context: context, access: access)
        let key = ObjectIdentifier(context)
        offscreenDocuments[key]?.access = access
        if !hasPermission("offscreen", context: context, access: access) {
            offscreenDocuments.removeValue(forKey: key)?.close()
            audioPlayers.removeValue(forKey: key)?.stop()
        }
        if !hasPermission("downloads", context: context, access: access) {
            downloads.disconnect(owner: context.uniqueIdentifier)
            blobs.remove(owner: context.uniqueIdentifier)
        }
    }

    func connect(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext,
                 access: WebExtensionAccess?, completion: @escaping (Error?) -> Void) -> Bool {
        if port.applicationIdentifier == WebExtensionUserScripts.portIdentifier {
            guard hasPermission("userScripts", context: context, access: access) else {
                let error = NativeWebExtensionCompatibilityError.missingPermission("userScripts")
                completion(error); port.disconnect(throwing: error); return true
            }
            userScripts.connect(port, context: context, completion: completion); return true
        }
        guard port.applicationIdentifier == WebExtensionDownloads.portIdentifier else { return false }
        guard hasPermission("downloads", context: context, access: access) else {
            let error = NativeWebExtensionCompatibilityError.missingPermission("downloads")
            completion(error); port.disconnect(throwing: error); return true
        }
        downloads.connect(port, owner: context.uniqueIdentifier, completion: completion)
        return true
    }

    func handle(
        message: Any,
        applicationIdentifier: String?,
        context: WKWebExtensionContext,
        resourceURL: URL?,
        access: WebExtensionAccess? = nil,
        webView: WKWebView? = nil,
        blobSources: [WKWebView] = [],
        tabMetadata: ([Int]) -> [[String: Any]] = { _ in [] },
        badgeTab: (Int) -> AnyObject? = { _ in nil },
        replyHandler: @escaping (Any?, Error?) -> Void
    ) -> Bool {
        guard applicationIdentifier == Self.applicationIdentifier,
              let values = message as? [String: Any],
              (values["souloCompatibility"] as? Int) == 1,
              let api = values["api"] as? String else { return false }
        switch api {
        case "actionBadgeTextColor":
            let manifest = context.webExtension.manifest
            guard manifest["action"] != nil || manifest["browser_action"] != nil,
                  let operation = values["operation"] as? String else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedAPI); return true
            }
            let tab = (values["index"] as? Int).flatMap(badgeTab)
            guard values["index"] == nil || tab != nil else {
                replyHandler(nil, URLError(.resourceUnavailable)); return true
            }
            let key = ObjectIdentifier(context)
            switch operation {
            case "set":
                guard let color = values["color"] as? [Int], color.count == 4,
                      color.allSatisfy({ (0...255).contains($0) }), color[3] > 0 else {
                    replyHandler(nil, URLError(.cannotDecodeContentData)); return true
                }
                let state = badgeTextColors[key] ?? BadgeTextColors()
                if let tab { state.tabs.setObject(color as NSArray, forKey: tab) }
                else { state.defaultColor = color }
                badgeTextColors[key] = state
                NotificationCenter.default.post(name: .browserExtensionActionsChanged, object: nil)
                replyHandler(true, nil)
            case "get": replyHandler(badgeTextRGBA(for: context, tab: tab) ?? [255, 255, 255, 255], nil)
            default: replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedOperation)
            }
        case "permissionStatus":
            guard let permission = values["name"] as? String,
                  ["downloads", "offscreen", "userScripts", "proxy"].contains(permission) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedAPI); return true
            }
            replyHandler(hasPermission(permission, context: context, access: access), nil)
        case "tabMetadata":
            guard hasPermission("tabs", context: context, access: access),
                  let indexes = values["indexes"] as? [Int] else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("tabs")); return true
            }
            replyHandler(tabMetadata(indexes), nil)
        case "userScripts":
            guard hasPermission("userScripts", context: context, access: access), let resourceURL else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("userScripts")); return true
            }
            if values["operation"] as? String == "execute" {
                userScripts.execute(values, context: context, resourceURL: resourceURL, access: access, reply: replyHandler)
            } else {
                do { replyHandler(try userScripts.handle(values, context: context, resourceURL: resourceURL, access: access), nil) }
                catch { replyHandler(nil, error) }
            }
        case "documentDownload":
            BrowserStartupTrace.mark("extension_document_download", detail: values["operation"] as? String ?? "start")
            // An extension without the downloads permission can still save
            // its own generated document, just like an <a download> element.
            // This grants no network downloads or access to download history.
            let manifest = context.webExtension.manifest
            let permissions = (manifest["permissions"] as? [String] ?? []) + (manifest["optional_permissions"] as? [String] ?? [])
            guard !permissions.contains("downloads"),
                  let options = values["options"] as? [String: Any],
                  let text = options["url"] as? String, let url = URL(string: text),
                  url.scheme == "data" || (url.scheme == "blob" && URL(string: String(text.dropFirst(5))).map {
                      $0.scheme == context.baseURL.scheme && $0.host == context.baseURL.host && $0.port == context.baseURL.port
                  } == true) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("downloads")); return true
            }
            let restricted: [String: Any] = ["operation": "download", "options": ["url": text, "filename": options["filename"] as? String ?? "download"]]
            if values["operation"] as? String == "observe" {
                downloads.adoptDocumentSave(url: text, owner: context.uniqueIdentifier, reply: replyHandler)
                return true
            }
            // A background request can refer to a Blob created in an existing
            // extension tab. Start WebKit's download in that live storage
            // partition instead of inventing a separate helper document.
            let source = owningDownloadDocument(options: options, context: context, preferred: webView, sources: blobSources)
            downloads.handle(restricted, context: context, webView: source, reply: replyHandler)
        case "blobs":
            guard hasPermission("downloads", context: context, access: access) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("downloads")); return true
            }
            blobs.handle(values, context: context, sources: blobSources, access: access, reply: replyHandler)
        case "ownedCapture":
            guard context.webExtension.manifest[WebExtensionGoFullPageAdapter.manifestKey] as? Bool == true else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedAPI); return true
            }
            blobs.handle(values, context: context, sources: [], access: access, ownedCaptureOnly: true, reply: replyHandler)
        case "downloads":
            guard hasPermission("downloads", context: context, access: access) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("downloads")); return true
            }
            let source = owningDownloadDocument(options: values["options"] as? [String: Any] ?? [:], context: context, preferred: webView, sources: blobSources)
            downloads.handle(values, context: context, webView: source, reply: replyHandler)
        case "offscreen":
            if values["operation"] as? String == "contexts" {
                replyHandler(["contexts": extensionContexts(values["filter"] as? [String: Any] ?? [:],
                                                              context: context, access: access)], nil)
                return true
            }
            guard hasPermission("offscreen", context: context, access: access) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("offscreen"))
                return true
            }
            handleOffscreen(values, context: context, resourceURL: resourceURL, access: access, replyHandler: replyHandler)
        case "proxy":
            guard hasPermission("proxy", context: context, access: access) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("proxy")); return true
            }
            if values["operation"] as? String == "get" {
                replyHandler(["value": ["mode": "system"], "levelOfControl": "not_controllable"], nil)
            } else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedAPI)
            }
        case "notifications":
            guard hasPermission("notifications", context: context, access: access) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("notifications"))
                return true
            }
            handleNotification(values, context: context, replyHandler: replyHandler)
        case "audio":
            guard hasPermission("offscreen", context: context, access: access) else {
                replyHandler(nil, NativeWebExtensionCompatibilityError.missingPermission("offscreen"))
                return true
            }
            handleAudio(values, context: context, resourceURL: resourceURL, replyHandler: replyHandler)
        case "lifecycle":
            if values["operation"] as? String == "installation" {
                var details = values["details"] as? [String: Any] ?? [:]
                guard let version = context.webExtension.version, !version.isEmpty else {
                    replyHandler(["details": details, "skip": false], nil); return true
                }
                prepareInstallation(context: context)
                let identity = ObjectIdentifier(context)
                var event = installationEvents[identity]!
                let previous = event.previousVersion
                let isVersionEvent = ["install", "update"].contains(details["reason"] as? String ?? "")
                if isVersionEvent && (event.delivered || previous == version) {
                    replyHandler(["skip": true], nil)
                } else {
                    if details["reason"] as? String == "install", let previous {
                        details["reason"] = "update"; details["previousVersion"] = previous
                    }
                    replyHandler(["details": details, "skip": false], nil)
                }
                if ["install", "update"].contains(details["reason"] as? String ?? "") { event.delivered = true }
                installationEvents[identity] = event
            } else {
                // Accepted for packages prepared by an earlier wrapper.
                replyHandler(["success": true], nil)
            }
        default:
            replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedAPI)
        }
        return true
    }

    private func owningDownloadDocument(options: [String: Any], context: WKWebExtensionContext,
                                        preferred: WKWebView?, sources: [WKWebView]) -> WKWebView? {
        guard let text = options["url"] as? String, let url = URL(string: text),
              ["blob", "data"].contains(url.scheme?.lowercased() ?? "") else { return preferred }
        let owner = context.baseURL
        if url.scheme == "blob" {
            guard let origin = URL(string: String(text.dropFirst(5))),
                  origin.scheme == owner.scheme, origin.host?.lowercased() == owner.host?.lowercased(),
                  origin.port == owner.port else { return preferred }
        }
        func owns(_ view: WKWebView) -> Bool {
            view.url?.scheme == owner.scheme && view.url?.host?.lowercased() == owner.host?.lowercased()
                && view.url?.port == owner.port
        }
        if let preferred, owns(preferred) { return preferred }
        return sources.first(where: owns) ?? preferred
    }

    private func hasPermission(_ permission: String, context: WKWebExtensionContext, access: WebExtensionAccess?) -> Bool {
        let manifest = context.webExtension.manifest
        let declared = (manifest["permissions"] as? [String] ?? []) + (manifest["optional_permissions"] as? [String] ?? [])
        guard declared.contains(permission) else { return false }
        return access?.allowsPermission(permission) ?? context.hasPermission(.init(rawValue: permission))
    }

    private func badgeTextRGBA(for context: WKWebExtensionContext, tab: AnyObject?) -> [Int]? {
        guard let state = badgeTextColors[ObjectIdentifier(context)] else { return nil }
        return tab.flatMap { state.tabs.object(forKey: $0) as? [Int] } ?? state.defaultColor
    }

    func badgeTextColor(for context: WKWebExtensionContext, tab: AnyObject?) -> UIColor? {
        guard let rgba = badgeTextRGBA(for: context, tab: tab) else { return nil }
        return UIColor(red: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255,
                       blue: CGFloat(rgba[2]) / 255, alpha: CGFloat(rgba[3]) / 255)
    }

    func remove(context: WKWebExtensionContext) {
        userScripts.remove(context: context)
        let key = ObjectIdentifier(context)
        badgeTextColors.removeValue(forKey: key)
        audioPlayers[key]?.stop()
        audioPlayers.removeValue(forKey: key)
        offscreenDocuments.removeValue(forKey: key)?.close()
        installationEvents.removeValue(forKey: key)
        downloads.disconnect(owner: context.uniqueIdentifier)
        blobs.remove(owner: context.uniqueIdentifier)
    }

    private static func installationKey(_ id: String) -> String { "soulo.webextension.installation." + id }

    func forgetInstallation(id: UUID) {
        UserDefaults.standard.removeObject(forKey: Self.installationKey(id.uuidString))
        downloads.forget(owner: id.uuidString)
    }

    private func handleOffscreen(_ values: [String: Any], context: WKWebExtensionContext, resourceURL: URL?,
                                 access: WebExtensionAccess?, replyHandler: @escaping (Any?, Error?) -> Void) {
        let key = ObjectIdentifier(context)
        switch values["operation"] as? String {
        case "create":
            guard offscreenDocuments[key]?.descriptor == nil else {
                replyHandler(nil, WebExtensionOffscreenDocument.failure("Only one offscreen document may be open.")); return
            }
            guard let root = resourceURL, let options = values["options"] as? [String: Any],
                  let reference = options["url"] as? String, let reasons = options["reasons"] as? [String], !reasons.isEmpty,
                  let justification = options["justification"] as? String, !justification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                replyHandler(nil, WebExtensionOffscreenDocument.failure("An offscreen URL, reasons and justification are required.")); return
            }
            let supported: Set<String> = ["AUDIO_PLAYBACK", "DOM_PARSER", "LOCAL_STORAGE", "BLOBS", "IFRAME_SCRIPTING", "DOM_SCRAPING", "WORKERS", "MATCH_MEDIA", "TESTING"]
            guard reasons.allSatisfy(supported.contains) else {
                replyHandler(nil, WebExtensionOffscreenDocument.failure("The requested offscreen reason is unavailable on iOS.")); return
            }
            do {
                let document = try WebExtensionOffscreenDocument(reference: reference, root: root, context: context, access: access)
                offscreenDocuments[key] = document
                document.open(completion: replyHandler)
            } catch { replyHandler(nil, error) }
        case "close":
            guard let document = offscreenDocuments.removeValue(forKey: key), document.descriptor != nil else {
                replyHandler(nil, WebExtensionOffscreenDocument.failure("There is no open offscreen document.")); return
            }
            document.close(); replyHandler(["success": true], nil)
        case "has": replyHandler(["open": offscreenDocuments[key]?.descriptor != nil], nil)
        case "structuredMessage":
            guard let packet = values["packet"], let document = offscreenDocuments[key], document.descriptor != nil,
                  JSONSerialization.isValidJSONObject(packet),
                  let size = try? JSONSerialization.data(withJSONObject: packet).count, size <= 32 * 1024 * 1024 else {
                replyHandler(nil, WebExtensionOffscreenDocument.failure("The offscreen document or message is unavailable.")); return
            }
            document.sendStructuredMessage(packet, completion: replyHandler)
        default: replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedOperation)
        }
    }

    private func extensionContexts(_ filter: [String: Any], context: WKWebExtensionContext,
                                   access: WebExtensionAccess?) -> [[String: Any]] {
        // Use active app-managed documents owned by the requesting extension.
        var descriptors = [WebExtensionPopupPresenter.contextDescriptor(for: context)].compactMap { $0 }
        if hasPermission("offscreen", context: context, access: access),
           let descriptor = offscreenDocuments[ObjectIdentifier(context)]?.descriptor {
            descriptors.append(descriptor)
        }
        for (key, field) in [("contextTypes", "contextType"), ("contextIds", "contextId"), ("documentIds", "documentId"),
                             ("documentUrls", "documentUrl"), ("documentOrigins", "documentOrigin"),
                             ("frameIds", "frameId"), ("tabIds", "tabId"), ("windowIds", "windowId")] {
            guard let value = filter[key] else { continue }
            guard let accepted = value as? [AnyHashable] else { return [] }
            descriptors = descriptors.filter { descriptor in
                (descriptor[field] as? AnyHashable).map(accepted.contains) == true
            }
        }
        if let incognito = filter["incognito"] as? Bool {
            descriptors = descriptors.filter { $0["incognito"] as? Bool == incognito }
        }
        return descriptors
    }

    private func handleNotification(
        _ values: [String: Any],
        context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        let operation = values["operation"] as? String ?? ""
        let extensionPrefix = context.uniqueIdentifier + ":"
        let requestedID = (values["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notificationID = extensionPrefix + ((requestedID?.isEmpty == false) ? requestedID! : UUID().uuidString)

        switch operation {
        case "create", "update":
            let options = values["options"] as? [String: Any] ?? [:]
            let content = UNMutableNotificationContent()
            content.title = (options["title"] as? String)?.nonEmpty
                ?? context.webExtension.displayName?.nonEmpty
                ?? "Soulo"
            content.body = (options["message"] as? String)?.nonEmpty
                ?? (options["contextMessage"] as? String)?.nonEmpty
                ?? ""
            content.sound = AppFeedbackPreferences.soundEnabled() ? .default : nil
            content.userInfo[SouloAppDelegate.webExtensionNotificationKey] = true
            Task { @MainActor in
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    guard granted else {
                        replyHandler(nil, NativeWebExtensionCompatibilityError.notificationPermissionDenied)
                        return
                    }
                    try await center.add(UNNotificationRequest(
                        identifier: notificationID,
                        content: content,
                        trigger: nil
                    ))
                    replyHandler([
                        "id": String(notificationID.dropFirst(extensionPrefix.count)),
                        "success": true
                    ], nil)
                } catch {
                    replyHandler(nil, error)
                }
            }
        case "clear":
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [notificationID])
            replyHandler(["success": true], nil)
        case "getAll":
            Task { @MainActor in
                let requests = await center.pendingNotificationRequests()
                let delivered = await center.deliveredNotifications()
                var notifications: [String: [String: Any]] = [:]
                for identifier in requests.map(\.identifier) + delivered.map({ $0.request.identifier }) {
                    guard identifier.hasPrefix(extensionPrefix) else { continue }
                    notifications[String(identifier.dropFirst(extensionPrefix.count))] = [:]
                }
                replyHandler(["notifications": notifications], nil)
            }
        case "permission":
            Task { @MainActor in
                let settings = await center.notificationSettings()
                var granted: Set<UNAuthorizationStatus> = [.authorized, .provisional]
                #if os(iOS)
                granted.insert(.ephemeral)
                #endif
                replyHandler(["level": granted.contains(settings.authorizationStatus) ? "granted" : "denied"], nil)
            }
        default:
            replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedOperation)
        }
    }

    private func handleAudio(
        _ values: [String: Any],
        context: WKWebExtensionContext,
        resourceURL: URL?,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        let key = ObjectIdentifier(context)
        if values["operation"] as? String == "stop" {
            audioPlayers[key]?.stop()
            audioPlayers.removeValue(forKey: key)
            replyHandler(["success": true], nil)
            return
        }
        guard values["operation"] as? String == "play",
              let resourceURL,
              var relativePath = values["source"] as? String else {
            replyHandler(nil, NativeWebExtensionCompatibilityError.invalidResource)
            return
        }
        while relativePath.hasPrefix("/") { relativePath.removeFirst() }
        let audioURL = resourceURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = resourceURL.standardizedFileURL.path + "/"
        guard audioURL.path.hasPrefix(rootPath), FileManager.default.fileExists(atPath: audioURL.path) else {
            replyHandler(nil, NativeWebExtensionCompatibilityError.invalidResource)
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            guard player.play() else { throw NativeWebExtensionCompatibilityError.audioPlaybackFailed }
            audioPlayers[key] = player
            replyHandler(["success": true], nil)
        } catch {
            replyHandler(nil, error)
        }
    }
}

/// Dynamic scripts use a real WebKit world owned by this extension, without
/// exposing its privileged content-script API to the less-trusted program.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionUserScripts: NSObject, WKScriptMessageHandlerWithReply {
    private struct Entry {
        let context: WKWebExtensionContext
        let resources: URL
        var access: WebExtensionAccess?
        var scripts: [[String: Any]] = []
        var worlds: [String: [String: Any]] = [:]
    }
    private var entries: [String: Entry] = [:]
    private let executionHost = WebExtensionUserScriptExecutionHost()
    private let driverWorld = WKContentWorld.world(name: "Soulo.UserScriptFrameDirectory")
    private let frameEvent = "soulo-user-script-frame-" + UUID().uuidString
    private struct LocatedFrame {
        weak var webView: WKWebView?
        let info: WKFrameInfo
        let frameID: Int
        let documentID: String
    }
    private var locating: [String: [String: WKFrameInfo]] = [:]
    private struct MessageSubscription {
        let owner: String
        let port: WKWebExtension.MessagePort
        var receivesMessages = false
        var receivesConnections = false
    }
    private var subscriptions: [ObjectIdentifier: MessageSubscription] = [:]
    private struct PendingReply {
        let source: MessageEndpoint
        let reply: (Any?, Error?) -> Void
        let deadline: Task<Void, Never>
        var receivers: Set<ObjectIdentifier>
        var receiverError: Error? = nil
    }
    private var replies: [String: PendingReply] = [:]
    private struct MessageEndpoint {
        let owner: String
        let worldID: String
        let nonce: String
        let frame: LocatedFrame
        let world: WKContentWorld
    }
    private var channels: [String: MessageEndpoint] = [:]
    private var worlds: [String: (owner: String, id: String, csp: String)] = [:]
    static let portIdentifier = WebExtensionCompatibilityHost.applicationIdentifier + ".userScripts"
    private var injected: [WKUserScript] = []
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "com.dkluge.Soulo.UserScripts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
    func attach(_ controller: WKUserContentController) {
        guard !controllers.allObjects.contains(where: { $0 === controller }) else { return }
        controllers.add(controller)
        controller.addScriptMessageHandler(self, contentWorld: driverWorld, name: "souloUserScriptFrame")
        let event = (try? Self.json(frameEvent)) ?? "\"\""
        controller.addUserScript(WKUserScript(source: """
        (()=>{if(!/^https?:$/.test(location.protocol))return;
          addEventListener(\(event),event=>{
            if(typeof event.detail!=='string'||event.detail.length>100)return;
            event.stopImmediatePropagation();
            window.webkit.messageHandlers.souloUserScriptFrame.postMessage(event.detail).catch(()=>{});
          },true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: driverWorld))
        for (name, _) in worlds {
            controller.addScriptMessageHandler(self, contentWorld: WKContentWorld.world(name: name), name: "souloUserScript")
        }
        injected.forEach(controller.addUserScript)
    }
    func restore(context: WKWebExtensionContext, resourceURL: URL, access: WebExtensionAccess?) {
        let owner = context.uniqueIdentifier
        guard entries[owner] == nil else { return }
        var entry = Entry(context: context, resources: resourceURL, access: access)
        if let data = try? Data(contentsOf: Self.storeURL(entry)), data.count < 5_000_000,
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           state["version"] as? String == context.webExtension.version,
           let scripts = state["scripts"] as? [[String: Any]], scripts.count <= 128,
           let worlds = state["worlds"] as? [String: [String: Any]], worlds.count <= 50 {
            do {
                for (id, world) in worlds { try Self.checkWorld(world, id: id) }
                entry.worlds = worlds
                entry.scripts = try scripts.map { try Self.validated($0, entry: entry) }
            } catch { entry.scripts = []; entry.worlds = [:] }
        }
        entries[owner] = entry
        rebuild()
    }
    func refresh(context: WKWebExtensionContext, access: WebExtensionAccess) {
        guard var entry = entries[context.uniqueIdentifier] else { return }
        entry.access = access; entries[context.uniqueIdentifier] = entry; rebuild()
    }
    func remove(context: WKWebExtensionContext) {
        let owner = context.uniqueIdentifier
        entries.removeValue(forKey: owner)
        executionHost.remove(owner: owner)
        for (id, channel) in Array(channels) where channel.owner == owner { closeChannel(id, error: "The extension was disabled.") }
        for (id, pending) in Array(replies) where pending.source.owner == owner { finishReply(id, value: nil, error: Self.failure("The extension was disabled.")) }
        for (key, subscription) in Array(subscriptions) where subscription.owner == owner {
            subscriptions.removeValue(forKey: key); subscription.port.disconnect()
        }
        rebuild()
    }
    private static func storeURL(_ entry: Entry) -> URL {
        entry.resources.deletingLastPathComponent().appendingPathComponent("UserScripts-v1.json")
    }
    func handle(_ values: [String: Any], context: WKWebExtensionContext, resourceURL: URL, access: WebExtensionAccess?) throws -> Any {
        restore(context: context, resourceURL: resourceURL, access: access)
        let owner = context.uniqueIdentifier
        var entry = entries[owner]!
        let operation = values["operation"] as? String ?? ""
        let filter = values["filter"] as? [String: Any] ?? [:]
        let ids = filter["ids"] as? [String]
        switch operation {
        case "getScripts": return entry.scripts.filter { script in ids.map { $0.contains(script["id"] as? String ?? "") } ?? true }
        case "getWorldConfigurations": return entry.worlds.sorted { $0.key < $1.key }.map { id, raw in
            var value = raw; if !id.isEmpty { value["worldId"] = id }; return value
        }
        case "configureWorld":
            guard let properties = values["properties"] as? [String: Any] else { throw Self.failure("World properties are required.") }
            let id = properties["worldId"] as? String ?? ""
            var world = entry.worlds[id] ?? [:]
            for (key, value) in properties where key != "worldId" { world[key] = value }
            try Self.checkWorld(world, id: id)
            entry.worlds[id] = world
            guard entry.worlds.count <= 50 else { throw Self.failure("Too many user script worlds.") }
        case "resetWorldConfiguration": entry.worlds.removeValue(forKey: values["worldId"] as? String ?? "")
        case "unregister": entry.scripts.removeAll { script in ids.map { $0.contains(script["id"] as? String ?? "") } ?? true }
        case "register", "update":
            guard let changes = values["scripts"] as? [[String: Any]], !changes.isEmpty else { throw Self.failure("Scripts are required.") }
            var seen = Set<String>()
            for change in changes {
                guard let id = change["id"] as? String, seen.insert(id).inserted else { throw Self.failure("Script IDs must be unique.") }
                let index = entry.scripts.firstIndex { $0["id"] as? String == id }
                if operation == "register", index != nil { throw Self.failure("A script with this ID is already registered.") }
                if operation == "update", index == nil { throw Self.failure("The script ID is not registered.") }
                var raw = index.map { entry.scripts[$0] } ?? [:]
                for (key, value) in change { raw[key] = value }
                let checked = try Self.validated(raw, entry: entry)
                if let index { entry.scripts[index] = checked } else { entry.scripts.append(checked) }
            }
            guard entry.scripts.count <= 128 else { throw Self.failure("Too many registered user scripts.") }
        default: throw Self.failure("This userScripts operation is unavailable.")
        }
        let state: [String: Any] = ["version": context.webExtension.version ?? "", "scripts": entry.scripts, "worlds": entry.worlds]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard data.count < 5_000_000 else { throw Self.failure("Registered scripts exceed the storage limit.") }
        try data.write(to: Self.storeURL(entry), options: .atomic)
        entries[owner] = entry; rebuild(); return NSNull()
    }
    private static func checkWorld(_ world: [String: Any], id: String) throws {
        guard id.count <= 256, !id.hasPrefix("_") else { throw failure("Invalid user script world ID.") }
        if let messaging = world["messaging"], !(messaging is Bool) { throw failure("World messaging must be a Boolean.") }
        if let csp = world["csp"] as? String {
            guard csp.utf8.count <= 2048 else { throw failure("The world CSP is too long.") }
            for directive in csp.split(separator: ";") {
                let parts = directive.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let name = parts.first else { continue }
                let allowed: Set<String>
                switch name {
                case "script-src", "default-src", "connect-src":
                    allowed = ["'self'", "'none'", "'unsafe-eval'", "'wasm-unsafe-eval'", "'unsafe-inline'", "'strict-dynamic'", "*"]
                case "object-src": allowed = ["'none'", "'self'"]
                case "trusted-types": allowed = ["'none'"]
                default: throw failure("This user script CSP directive is not supported.")
                }
                guard parts.dropFirst().allSatisfy({ value in
                    if allowed.contains(value) { return true }
                    guard ["script-src", "default-src", "connect-src"].contains(name) else { return false }
                    if value.hasPrefix("'nonce-") || value.hasPrefix("'sha256-") || value.hasPrefix("'sha384-") || value.hasPrefix("'sha512-") { return name != "connect-src" && value.hasSuffix("'") }
                    return value.range(of: #"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|(?:(?:https?|wss?)://)?(?:\*\.)?[a-zA-Z0-9._-]+(?::(?:[0-9]+|\*))?(?:/[^\s;]*)?)$"#, options: .regularExpression) != nil
                }) else { throw failure("This user script CSP source is not supported.") }
            }
        }
    }
    private static func sources(_ raw: [String: Any], entry: Entry) throws -> [String] {
        guard let sources = raw["js"] as? [[String: Any]], !sources.isEmpty, sources.count <= 64 else { throw failure("Script sources are required.") }
        var size = 0
        return try sources.map { source in
            let code: String
            if let inline = source["code"] as? String, source["file"] == nil { code = inline }
            else if let path = source["file"] as? String, source["code"] == nil {
                let root = entry.resources.resolvingSymlinksInPath().standardizedFileURL
                let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(root.path + "/"),
                      (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4_000_000 else { throw failure("Invalid user script resource.") }
                code = try String(contentsOf: file, encoding: .utf8)
            } else { throw failure("Each script source must specify exactly one file or code string.") }
            size += code.utf8.count
            guard size <= 4_000_000 else { throw failure("The user script is too large.") }
            return code
        }
    }
    private static func validated(_ raw: [String: Any], entry: Entry) throws -> [String: Any] {
        guard let id = raw["id"] as? String, !id.isEmpty, id.count <= 256, !id.hasPrefix("_"),
              let matches = raw["matches"] as? [String], !matches.isEmpty,
              ["document_start", "document_end", "document_idle"].contains(raw["runAt"] as? String ?? "document_idle"),
              ["USER_SCRIPT", "MAIN"].contains(raw["world"] as? String ?? "USER_SCRIPT") else { throw failure("Invalid user script definition.") }
        for pattern in matches + (raw["excludeMatches"] as? [String] ?? []) {
            _ = try WKWebExtension.MatchPattern(string: pattern)
            guard UserScriptURLMatcher.regularExpression(for: pattern) != nil else { throw failure("Only web match patterns are supported.") }
        }
        let worldID = raw["worldId"] as? String ?? ""
        guard worldID.count <= 256, !worldID.hasPrefix("_"), raw["world"] as? String != "MAIN" || worldID.isEmpty else { throw failure("Invalid user script world.") }
        let source = try sources(raw, entry: entry).joined(separator: "\n;\n")
        let check = JSContext()!
        check.evaluateScript("new Function(" + (try json(source)) + ")")
        guard check.exception == nil else { throw failure("User script syntax error: " + (check.exception?.toString() ?? "invalid source")) }
        return raw
    }
    private static func conditions(_ patterns: [String]) -> [String] { patterns.compactMap(UserScriptURLMatcher.regularExpression) }
    private func allowsMessaging(from source: MessageEndpoint) -> Bool {
        guard let entry = entries[source.owner], let web = source.frame.webView,
              entry.worlds[source.worldID]?["messaging"] as? Bool == true else { return false }
        return Self.allowed(entry, frame: source.frame.info, webView: web)
    }

    private func rebuild() {
        for (id, channel) in Array(channels) where !allowsMessaging(from: channel) {
            closeChannel(id, error: "User script permission was revoked.")
        }
        for (id, pending) in Array(replies) where !allowsMessaging(from: pending.source) {
            finishReply(id, value: nil, error: Self.failure("User script permission was revoked."))
        }
        if entries.isEmpty { executionHost.close() }
        let previous = Set(injected.map(ObjectIdentifier.init)); var next: [WKUserScript] = []
        var bootstrapped = Set<String>()
        for (owner, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard entry.access?.allowsPermission("userScripts") == true else { continue }
            let allowed = entry.access?.sites.compactMap { pattern, expiry -> [String: Any]? in
                guard let expression = UserScriptURLMatcher.regularExpression(for: pattern) else { return nil }
                return ["pattern": expression, "until": expiry.timeIntervalSince1970 * 1000]
            } ?? []
            var denied = entry.access?.deniedSites ?? [:]
            for host in entry.access?.blockedHosts ?? [] { denied["*://\(host)/*"] = .distantFuture; denied["*://*.\(host)/*"] = .distantFuture }
            let deniedRules = denied.compactMap { pattern, expiry -> [String: Any]? in
                guard let expression = UserScriptURLMatcher.regularExpression(for: pattern) else { return nil }
                return ["pattern": expression, "until": expiry.timeIntervalSince1970 * 1000]
            }
            for raw in entry.scripts {
                guard let code = try? Self.sources(raw, entry: entry).joined(separator: "\n;\n") else { continue }
                let main = raw["world"] as? String == "MAIN", worldID = raw["worldId"] as? String ?? ""
                let worldProperties = entry.worlds[worldID] ?? [:]
                let csp = worldProperties["csp"] as? String ?? "script-src 'self' 'wasm-unsafe-eval'"
                let worldName = "Soulo.UserScripts.\(owner).\(worldID.utf8.count):\(worldID):\(csp)"
                let world = main ? WKContentWorld.page : WKContentWorld.world(name: worldName)
                if !main, worlds[worldName] == nil {
                    worlds[worldName] = (owner, worldID, csp)
                    for controller in controllers.allObjects {
                        controller.addScriptMessageHandler(self, contentWorld: world, name: "souloUserScript")
                    }
                }
                if !main, bootstrapped.insert(worldName).inserted {
                    // A script can reach same-origin child-window globals even
                    // when its registration only targets the top frame.
                    next.append(WKUserScript(source: Self.worldBootstrap(owner: owner, worldID: worldID, messaging: worldProperties["messaging"] as? Bool == true) + Self.worldPolicy(csp: csp), injectionTime: .atDocumentStart,
                        forMainFrameOnly: false, in: world))
                }
                let values: [String: Any] = ["matches": Self.conditions(raw["matches"] as? [String] ?? []),
                    "exclude": Self.conditions(raw["excludeMatches"] as? [String] ?? []), "includeGlobs": raw["includeGlobs"] as? [String] ?? [],
                    "excludeGlobs": raw["excludeGlobs"] as? [String] ?? [], "allowed": allowed, "denied": deniedRules,
                    "until": (entry.access?.permissions["userScripts"]?.timeIntervalSince1970 ?? 0) * 1000]
                guard let options = try? Self.json(values) else { continue }
                let guardSource = """
                const o=\(options),u=new URL(location.href);u.hash='';const href=u.href;
                const match=patterns=>patterns.some(p=>new RegExp(p).test(href));
                const glob=p=>new RegExp('^'+p.split('').map(c=>c==='*'?'.*':c==='?'?'.':c.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&')).join('')+'$').test(href);
                const now=Date.now(),granted=rules=>rules.some(r=>r.until>now&&new RegExp(r.pattern).test(href));
                if(!/^https?:$/.test(u.protocol)||o.until<=now||!match(o.matches)||match(o.exclude)||!granted(o.allowed)||granted(o.denied)
                  ||(o.includeGlobs.length&&!o.includeGlobs.some(glob))||o.excludeGlobs.some(glob))return;
                """
                let runAt = raw["runAt"] as? String ?? "document_idle"
                let body = code
                let run = runAt == "document_idle" ? "const run=()=>{\(body)\n};if(document.readyState==='complete')setTimeout(run,0);else addEventListener('load',()=>setTimeout(run,0),{once:true});" : body
                next.append(WKUserScript(source: "(()=>{\(guardSource)\n\(run)\n})();", injectionTime: runAt == "document_start" ? .atDocumentStart : .atDocumentEnd,
                    forMainFrameOnly: raw["allFrames"] as? Bool != true, in: world))
            }
        }
        if previous.isEmpty && next.isEmpty { return }
        for controller in controllers.allObjects {
            if !previous.isEmpty {
                let others = controller.userScripts.filter { !previous.contains(ObjectIdentifier($0)) }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
            }
            next.forEach(controller.addUserScript)
        }
        injected = next
    }
    private static func allowed(_ entry: Entry, frame: WKFrameInfo, webView: WKWebView) -> Bool {
        guard !UserDefaults.standard.bool(forKey: "is_incognito"), webView.configuration.websiteDataStore.isPersistent,
              entry.access?.allowsPermission("userScripts") == true,
              let url = frame.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              entry.access?.blocks(url) != true, entry.context.hasAccess(to: url) else { return false }
        let now = Date()
        let matches: (Dictionary<String, Date>.Element) -> Bool = { $0.value > now && UserScriptURLMatcher.matches(url: url, patterns: [$0.key]) }
        return entry.access?.sites.contains(where: matches) == true && entry.access?.deniedSites.contains(where: matches) != true
    }

    private func locatedFrames(target: [String: Any], entry: Entry) async throws -> [LocatedFrame] {
        guard let tab = target["tabId"] as? NSNumber, tab.doubleValue == Double(tab.intValue), tab.intValue > 0,
              !(target["allFrames"] as? Bool == true && (target["frameIds"] != nil || target["documentIds"] != nil)),
              !(target["frameIds"] != nil && target["documentIds"] != nil) else { throw Self.failure("Invalid user script injection target.") }
        let token = UUID().uuidString
        locating[token] = [:]; defer { locating[token] = nil }
        let (results, expectedWebView) = try await executionHost.frames(target: target, event: frameEvent, token: token, owner: entry.context)
        guard results.count <= 256 else { throw Self.failure("Too many target frames.") }
        for _ in 0..<40 {
            if results.allSatisfy({ (($0["result"] as? [String: Any])?["nonce"] as? String).map { locating[token]?[$0] != nil } == true }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        var frames: [LocatedFrame] = []
        for result in results {
            guard let nonce = (result["result"] as? [String: Any])?["nonce"] as? String,
                  let info = locating[token]?[nonce], let web = info.webView, web === expectedWebView,
                  let id = result["frameId"] as? Int, let document = result["documentId"] as? String,
                  Self.allowed(entry, frame: info, webView: web) else { throw Self.failure("The target frame is unavailable or host permission was denied.") }
            frames.append(LocatedFrame(webView: web, info: info, frameID: id, documentID: document))
        }
        guard !frames.isEmpty else { throw Self.failure("No matching target frame.") }
        return frames.sorted { $0.frameID == 0 || ($1.frameID != 0 && $0.frameID < $1.frameID) }
    }

    func execute(_ values: [String: Any], context: WKWebExtensionContext, resourceURL: URL,
                 access: WebExtensionAccess?, reply: @escaping (Any?, Error?) -> Void) {
        restore(context: context, resourceURL: resourceURL, access: access)
        Task { @MainActor [weak self] in
            do {
                guard let self, let entry = self.entries[context.uniqueIdentifier],
                      let injection = values["injection"] as? [String: Any], let target = injection["target"] as? [String: Any],
                      ["MAIN", "USER_SCRIPT"].contains(injection["world"] as? String ?? "USER_SCRIPT") else { throw Self.failure("Invalid user script injection.") }
                let main = injection["world"] as? String == "MAIN", worldID = injection["worldId"] as? String ?? ""
                guard worldID.count <= 256, !worldID.hasPrefix("_"), !main || worldID.isEmpty else { throw Self.failure("Invalid user script world.") }
                let code = try Self.sources(injection, entry: entry).joined(separator: "\n;\n")
                let completion = try await WebExtensionUserScriptParser.completion(in: code)
                let frames = try await self.locatedFrames(target: target, entry: entry)
                var output: [[String: Any]] = []
                for frame in frames {
                    guard let web = frame.webView, let current = self.entries[context.uniqueIdentifier], Self.allowed(current, frame: frame.info, webView: web) else { throw Self.failure("User script permission was revoked.") }
                    var result: [String: Any] = ["frameId": frame.frameID, "documentId": frame.documentID]
                    do {
                        if injection["injectImmediately"] as? Bool != true {
                            _ = try await web.callAsyncJavaScript("if(document.readyState!=='complete')await new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(Error('The target document did not become idle.')),15000);addEventListener('load',()=>{clearTimeout(t);resolve();},{once:true});});return true;", arguments: [:], in: frame.info, contentWorld: self.driverWorld)
                        }
                        guard let active = self.entries[context.uniqueIdentifier], Self.allowed(active, frame: frame.info, webView: web) else { throw Self.failure("User script permission was revoked.") }
                        let world: WKContentWorld
                        if main { world = .page } else {
                            let properties = active.worlds[worldID] ?? [:]
                            let csp = properties["csp"] as? String ?? "script-src 'self' 'wasm-unsafe-eval'"
                            let name = "Soulo.UserScripts.\(context.uniqueIdentifier).\(worldID.utf8.count):\(worldID):\(csp)"
                            world = WKContentWorld.world(name: name)
                            if self.worlds[name] == nil {
                                self.worlds[name] = (context.uniqueIdentifier, worldID, csp)
                                for controller in self.controllers.allObjects { controller.addScriptMessageHandler(self, contentWorld: world, name: "souloUserScript") }
                            }
                            _ = try await web.evaluateCompatibleJavaScript(Self.worldBootstrap(owner: context.uniqueIdentifier, worldID: worldID, messaging: properties["messaging"] as? Bool == true) + Self.worldPolicy(csp: csp), in: frame.info, contentWorld: world)
                        }
                        if let completion {
                            // Parse real statement boundaries rather than eval or
                            // semicolon splitting. Native execution retains global
                            // lexical declarations and does not weaken world CSP.
                            let text = code as NSString, slot = "__soulo_result_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            let prefix = text.substring(to: completion.statementStart)
                            let expression = text.substring(with: NSRange(location: completion.expressionStart, length: completion.expressionEnd - completion.expressionStart))
                            let suffix = text.substring(from: completion.statementEnd)
                            let captured = prefix + "\n;globalThis[" + (try Self.json(slot)) + "]=(" + expression + ");\n" + suffix + "\n;void 0;"
                            _ = try await web.evaluateCompatibleJavaScript(captured, in: frame.info, contentWorld: world)
                            result["result"] = try await web.callAsyncJavaScript("""
                            if(!Object.prototype.hasOwnProperty.call(globalThis,slot))throw Error('The target document changed.');
                            let timer;try{return await Promise.race([globalThis[slot],new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('User script execution timed out.')),15000);})]);}
                            finally{clearTimeout(timer);delete globalThis[slot];}
                            """, arguments: ["slot": slot], in: frame.info, contentWorld: world)
                        } else { result["result"] = try await web.evaluateCompatibleJavaScript(code, in: frame.info, contentWorld: world) }
                        if result["result"] == nil { result["result"] = NSNull() }
                    } catch {
                        let native = error as NSError
                        result["error"] = native.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    }
                    output.append(result)
                }
                reply(output, nil)
            } catch { reply(nil, error) }
        }
    }

    func connect(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext, completion: @escaping (Error?) -> Void) {
        let key = ObjectIdentifier(port), owner = context.uniqueIdentifier
        subscriptions[key] = MessageSubscription(owner: owner, port: port)
        port.disconnectHandler = { [weak self] _ in
            guard let self else { return }; self.subscriptions[key] = nil
            let error = Self.failure("The extension message receiver disconnected.")
            for (id, pending) in Array(self.replies) where pending.receivers.contains(key) {
                self.receiverFinished(key, for: id, error: error)
            }
            if !self.subscriptions.values.contains(where: { $0.owner == owner }) {
                for (id, channel) in Array(self.channels) where channel.owner == owner { self.closeChannel(id, error: "The extension message receiver disconnected.") }
            }
        }
        port.messageHandler = { [weak self] value, _ in
            guard let self, let packet = value as? [String: Any] else { return }
            if packet["operation"] as? String == "subscriptions" {
                self.subscriptions[key]?.receivesMessages = packet["messages"] as? Bool == true
                self.subscriptions[key]?.receivesConnections = packet["connections"] as? Bool == true
                return
            }
            guard let id = packet["id"] as? String else { return }
            switch packet["operation"] as? String {
            case "reply":
                guard let pending = self.replies[id], pending.receivers.contains(key) else { return }
                guard self.allowsMessaging(from: pending.source) else {
                    self.finishReply(id, value: nil, error: Self.failure("User script permission was revoked.")); return
                }
                self.finishReply(id, value: packet["value"] ?? NSNull(), error: (packet["error"] as? String).map(Self.failure))
            case "ignored":
                self.receiverFinished(key, for: id)
            case "post":
                guard let channel = self.channels[id], channel.owner == owner else { return }
                self.deliver(id, packet: ["operation": "message", "id": id, "value": packet["value"] ?? NSNull()], channel: channel)
            case "disconnect":
                guard self.channels[id]?.owner == owner else { return }; self.closeChannel(id, error: nil)
            default: break
            }
        }
        completion(nil)
    }

    private func finishReply(_ id: String, value: Any?, error: Error?) {
        guard let pending = replies.removeValue(forKey: id) else { return }
        pending.deadline.cancel(); pending.reply(value, error)
    }
    private func receiverFinished(_ key: ObjectIdentifier, for id: String, error: Error? = nil) {
        guard var pending = replies[id], pending.receivers.remove(key) != nil else { return }
        pending.receiverError = pending.receiverError ?? error
        replies[id] = pending
        if pending.receivers.isEmpty {
            finishReply(id, value: pending.receiverError == nil ? NSNull() : nil, error: pending.receiverError)
        }
    }
    private func waitForReceiver(owner: String, connection: Bool) async throws -> [ObjectIdentifier: MessageSubscription] {
        for attempt in 0..<12 {
            let available = subscriptions.filter { $0.value.owner == owner && !$0.value.port.isDisconnected }
            let receivers = available.filter { connection ? $0.value.receivesConnections : $0.value.receivesMessages }
            if !receivers.isEmpty { return receivers }
            if attempt > 0 && available.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Self.failure("Could not establish connection. Receiving end does not exist.")
    }
    func detach(_ webView: WKWebView) {
        for (id, channel) in Array(channels) where channel.frame.webView === webView { closeChannel(id, error: "The user script tab was closed.") }
        for (id, pending) in Array(replies) where pending.source.frame.webView === webView {
            finishReply(id, value: nil, error: Self.failure("The user script tab was closed."))
        }
    }
    private func send(_ owner: String, packet: [String: Any]) throws {
        let operation = packet["operation"] as? String
        let ports = subscriptions.values.filter {
            $0.owner == owner && !$0.port.isDisconnected &&
            (operation != "send" || $0.receivesMessages) && (operation != "connect" || $0.receivesConnections)
        }
        guard !ports.isEmpty else { throw Self.failure("Could not establish connection. Receiving end does not exist.") }
        for receiver in ports { receiver.port.sendMessage(packet, completionHandler: nil) }
    }
    private func deliver(_ id: String, packet: [String: Any], channel: MessageEndpoint) {
        guard let web = channel.frame.webView, allowsMessaging(from: channel) else { closeChannel(id, error: "User script permission was revoked."); return }
        Task { @MainActor [weak self] in
            do { _ = try await web.callAsyncJavaScript("if(globalThis.__souloUserScriptEndpoint!==nonce)throw Error('Document changed');globalThis.__souloUserScriptDeliver(packet);return true;", arguments: ["nonce": channel.nonce, "packet": packet], in: channel.frame.info, contentWorld: channel.world) }
            catch { self?.closeChannel(id, error: "The user script document was closed.") }
        }
    }
    private func closeChannel(_ id: String, error: String?) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        try? send(channel.owner, packet: ["operation": "disconnect", "id": id, "error": error ?? NSNull()])
        guard let web = channel.frame.webView else { return }
        Task { @MainActor in
            _ = try? await web.callAsyncJavaScript("if(globalThis.__souloUserScriptEndpoint===nonce)globalThis.__souloUserScriptDeliver({operation:'disconnect',id,error});return true;", arguments: ["nonce": channel.nonce, "id": id, "error": error ?? NSNull()], in: channel.frame.info, contentWorld: channel.world)
        }
    }

    private func identify(_ web: WKWebView, nonce: String, world: WKContentWorld, entry: Entry) async throws -> (LocatedFrame, [String: Any]) {
        guard let tab = entry.context.openTabs.compactMap { $0.base as? any WKWebExtensionTab }.first(where: { $0.webView?(for: entry.context) === web }),
              let index = tab.indexInWindow?(for: entry.context) else { throw Self.failure("The user script tab is unavailable.") }
        let identity = try await executionHost.tab(at: index, owner: entry.context)
        guard tab.webView?(for: entry.context) === web, tab.indexInWindow?(for: entry.context) == index,
              let id = identity["id"] as? Int else { throw Self.failure("The user script tab changed.") }
        let frames = try await locatedFrames(target: ["tabId": id, "allFrames": true], entry: entry)
        for frame in frames {
            let value = try? await web.evaluateCompatibleJavaScript("globalThis.__souloUserScriptEndpoint", in: frame.info, contentWorld: world) as? String
            if value == nonce { return (frame, identity) }
        }
        throw Self.failure("The user script document changed.")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        if message.name == "souloUserScriptFrame", message.world.name == driverWorld.name,
           let value = message.body as? String, let separator = value.firstIndex(of: ":") {
            let token = String(value[..<separator]), nonce = String(value[value.index(after: separator)...])
            guard locating[token] != nil, locating[token]!.count < 256, UUID(uuidString: nonce) != nil,
                  message.webView?.configuration.websiteDataStore.isPersistent == true else { replyHandler(nil, "Unknown frame request"); return }
            if locating[token]?[nonce] == nil { locating[token]?[nonce] = message.frameInfo }
            replyHandler(true, nil); return
        }
        guard message.name == "souloUserScript", let name = message.world.name, let configured = worlds[name],
              let entry = entries[configured.owner], let web = message.webView,
              Self.allowed(entry, frame: message.frameInfo, webView: web),
              let packet = message.body as? [String: Any], let operation = packet["operation"] as? String,
              let nonce = packet["nonce"] as? String, UUID(uuidString: nonce) != nil else { replyHandler(nil, "User script permission was denied."); return }
        if operation == "pagehide" {
            for (id, channel) in Array(channels) where channel.owner == configured.owner && channel.nonce == nonce { closeChannel(id, error: "The document was closed.") }
            for (id, pending) in Array(replies) where pending.source.owner == configured.owner && pending.source.nonce == nonce {
                finishReply(id, value: nil, error: Self.failure("The document was closed."))
            }
            replyHandler(true, nil); return
        }
        guard entry.worlds[configured.id]?["messaging"] as? Bool == true,
              ["send", "connect", "post", "disconnect"].contains(operation),
              (try? JSONSerialization.data(withJSONObject: packet).count) ?? Int.max <= 262_144 else { replyHandler(nil, "User script messaging is unavailable."); return }
        if ["post", "disconnect"].contains(operation) {
            guard let id = packet["id"] as? String, let channel = channels[id], channel.owner == configured.owner,
                  channel.nonce == nonce, channel.world.name == name, channel.frame.webView === web else { replyHandler(nil, "The user script port is disconnected."); return }
            if operation == "disconnect" { closeChannel(id, error: nil) }
            else { do { try send(configured.owner, packet: ["operation": "post", "id": id, "value": packet["value"] ?? NSNull()]) } catch { closeChannel(id, error: error.localizedDescription) } }
            replyHandler(true, nil); return
        }
        guard replies.count < 128, channels.count < 128 else { replyHandler(nil, "Too many active user script requests."); return }
        Task { @MainActor [weak self] in
            do {
                guard let self else { throw Self.failure("The user script host was closed.") }
                let (frame, tab) = try await self.identify(web, nonce: nonce, world: message.world, entry: entry)
                guard let current = self.entries[configured.owner], Self.allowed(current, frame: frame.info, webView: web),
                      current.worlds[configured.id]?["messaging"] as? Bool == true else { throw Self.failure("User script messaging permission was revoked.") }
                let receivers = try await self.waitForReceiver(owner: configured.owner, connection: operation == "connect")
                let source = MessageEndpoint(owner: configured.owner, worldID: configured.id, nonce: nonce, frame: frame, world: message.world)
                guard self.allowsMessaging(from: source) else { throw Self.failure("User script messaging permission was revoked.") }
                guard self.replies.count < 128, self.channels.count < 128 else { throw Self.failure("Too many active user script requests.") }
                var origin = URLComponents(); origin.scheme = frame.info.securityOrigin.protocol; origin.host = frame.info.securityOrigin.host
                let port = frame.info.securityOrigin.port
                if port > 0 && !(origin.scheme == "http" && port == 80) && !(origin.scheme == "https" && port == 443) { origin.port = port }
                let sender: [String: Any] = ["id": configured.owner, "url": frame.info.request.url?.absoluteString ?? "", "origin": origin.string ?? "null",
                    "tab": tab, "frameId": frame.frameID, "documentId": frame.documentID, "documentLifecycle": "active", "userScriptWorldId": configured.id]
                if operation == "connect" {
                    guard let id = packet["id"] as? String, UUID(uuidString: id) != nil, self.channels[id] == nil else { throw Self.failure("Invalid user script port.") }
                    self.channels[id] = source
                    do { try self.send(configured.owner, packet: ["operation": "connect", "id": id, "name": packet["name"] as? String ?? "", "sender": sender]) }
                    catch { self.channels[id] = nil; throw error }
                    replyHandler(true, nil)
                } else {
                    let id = UUID().uuidString
                    let deadline = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(15)); guard !Task.isCancelled else { return }
                        self?.finishReply(id, value: nil, error: Self.failure("The user script message timed out."))
                    }
                    self.replies[id] = PendingReply(source: source, reply: { value, error in
                        replyHandler(value, error?.localizedDescription)
                    }, deadline: deadline, receivers: Set(receivers.keys))
                    let request: [String: Any] = ["operation": "send", "id": id, "value": packet["value"] ?? NSNull(), "sender": sender]
                    for (key, receiver) in receivers {
                        receiver.port.sendMessage(request) { [weak self] error in
                            if let error { self?.receiverFinished(key, for: id, error: error) }
                        }
                    }
                }
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    private static func worldBootstrap(owner: String, worldID: String, messaging: Bool) -> String {
        let identity = (try? json(owner)) ?? "\"\"", identifier = (try? json(worldID)) ?? "\"\""
        return #"""
        (()=>{
          if(globalThis.__souloUserScriptEndpoint){if(\#(messaging))globalThis.__souloUserScriptEnableMessaging();return;}
          const then=Function.prototype.call.bind(Promise.prototype.then),stringify=JSON.stringify.bind(JSON),parse=JSON.parse.bind(JSON);
          const post=window.webkit.messageHandlers.souloUserScript.postMessage.bind(window.webkit.messageHandlers.souloUserScript);
          const nonce=crypto.randomUUID(),ports=new Map();let lastError;
          const call=packet=>post({...packet,nonce});
          const clone=value=>parse(stringify(value)??'null');
          const define=(key,value)=>Object.defineProperty(globalThis,key,{value,writable:false,configurable:false});
          define('__souloUserScriptEndpoint',nonce);
          const event=()=>{const set=new Set();return {addListener(fn){if(typeof fn==='function')set.add(fn);},removeListener:fn=>set.delete(fn),hasListener:fn=>set.has(fn),hasListeners:()=>set.size,emit(...args){for(const fn of set)try{fn(...args);}catch(error){console.error(error);}}};};
          const notify=(error,fn,value)=>{lastError=error?{message:String(error?.message??error)}:undefined;try{fn(value);}finally{lastError=undefined;}};
          define('__souloUserScriptDeliver',packet=>{
            const port=ports.get(packet.id);if(!port)return;
            if(packet.operation==='message')port.onMessage.emit(packet.value,port);
            if(packet.operation==='disconnect'){ports.delete(packet.id);port.closed=true;lastError=packet.error?{message:packet.error}:undefined;try{port.onDisconnect.emit(port);}finally{lastError=undefined;}}
          });
          const enable=()=>{
            if(Object.prototype.hasOwnProperty.call(globalThis,'chrome'))return;
            const runtime={id:\#(identity),get lastError(){return lastError;}};
            runtime.sendMessage=function(...args){
              const callback=typeof args.at(-1)==='function'?args.pop():null;
              if(args[0]===runtime.id&&args.length>1)args.shift();
              const pending=(()=>{try{return call({operation:'send',value:clone(args[0])});}catch(error){return Promise.reject(error);}})();
              if(!callback)return pending;
              then(pending,value=>notify(null,callback,value),error=>notify(error,callback,undefined));
            };
            runtime.connect=function(...args){
              if(args[0]===runtime.id)args.shift();
              if(args.length>1||typeof args[0]==='string')throw new Error('User scripts can connect only to their owning extension');
              const options=args[0]||{},id=crypto.randomUUID();let ready;
              const port={name:String(options.name||''),onMessage:event(),onDisconnect:event(),closed:false,
                postMessage(value){if(port.closed)throw new Error('The port is disconnected');const copy=clone(value);then(ready,()=>{if(!port.closed)return call({operation:'post',id,value:copy});}).catch(error=>close(error));},
                disconnect(){if(port.closed)return;ports.delete(id);port.closed=true;then(ready,()=>call({operation:'disconnect',id})).catch(()=>{});}
              };
              const close=error=>{if(!port.closed)globalThis.__souloUserScriptDeliver({operation:'disconnect',id,error:String(error?.message??error)});};
              ports.set(id,port);ready=call({operation:'connect',id,name:port.name});then(ready,()=>{},close);return port;
            };
            define('chrome',Object.freeze({runtime}));define('browser',globalThis.chrome);
          };
          define('__souloUserScriptEnableMessaging',enable);if(\#(messaging))enable();
          addEventListener('pagehide',()=>{call({operation:'pagehide'}).catch(()=>{});});
        })();
        """#
    }

    private static func connectionPolicy(sources: String) -> String {
        #"""
        {
          const sources=\#(sources),NativeURL=URL,origin=location.origin;
          const allowed=value=>{
            if(sources===null)return true;
            let url;try{url=new NativeURL(value,location.href);}catch(_){return false;}
            return sources.some(source=>{
              if(source==="'none'")return false;
              if(source==='*')return ['http:','https:','ws:','wss:'].includes(url.protocol);
              if(source==="'self'")return url.origin===origin;
              if(/^[a-z][a-z0-9+.-]*:$/i.test(source))return url.protocol===source.toLowerCase();
              try{
                const withScheme=source.includes('://')?source:location.protocol+'//'+source;
                const anyPort=withScheme.replace(/:\*(?=\/|$)/,':65535'),pattern=new NativeURL(anyPort);
                const scheme=pattern.protocol===url.protocol||pattern.protocol==='http:'&&url.protocol==='https:'||pattern.protocol==='ws:'&&url.protocol==='wss:';
                const host=pattern.hostname.startsWith('*.')?url.hostname.endsWith(pattern.hostname.slice(1)):url.hostname===pattern.hostname;
                const port=withScheme!==anyPort||pattern.port===url.port;
                const path=pattern.pathname==='/'||pattern.pathname.endsWith('/')&&url.pathname.startsWith(pattern.pathname)||pattern.pathname===url.pathname;
                return scheme&&host&&port&&path;
              }catch(_){return false;}
            });
          };
          if(sources!==null){
            const fail=()=>new DOMException('Blocked by user script connect-src policy','SecurityError');
            if(typeof fetch==='function'){const native=fetch;Object.defineProperty(globalThis,'fetch',{configurable:false,writable:false,value:(input,options)=>allowed(typeof input==='string'||input instanceof NativeURL?String(input):input?.url)?Reflect.apply(native,globalThis,[input,options]):Promise.reject(new TypeError('Blocked by user script connect-src policy'))});}
            if(globalThis.XMLHttpRequest){const native=XMLHttpRequest.prototype.open;Object.defineProperty(XMLHttpRequest.prototype,'open',{configurable:false,writable:false,value:function(method,url,...rest){if(!allowed(url))throw fail();return Reflect.apply(native,this,[method,url,...rest]);}});}
            for(const key of ['WebSocket','EventSource'])if(typeof globalThis[key]==='function'){const Native=globalThis[key];Object.defineProperty(globalThis,key,{configurable:false,writable:false,value:new Proxy(Native,{construct(target,args,newTarget){if(!allowed(args[0]))throw fail();return Reflect.construct(target,args,newTarget);}})});}
            if(typeof navigator.sendBeacon==='function'){const native=navigator.sendBeacon.bind(navigator);Object.defineProperty(navigator,'sendBeacon',{configurable:false,writable:false,value:(url,...args)=>{if(!allowed(url))throw fail();return native(url,...args);}});}
          }
        }
        """#
    }

    private static func worldPolicy(csp: String) -> String {
        let directives = csp.split(separator: ";")
        let fallback = directives.first { $0.split(whereSeparator: { $0.isWhitespace }).first == "default-src" }
        let script = directives.first { $0.split(whereSeparator: { $0.isWhitespace }).first == "script-src" }.map(String.init) ?? fallback.map(String.init) ?? "script-src 'self' 'wasm-unsafe-eval'"
        let connections = directives.first { $0.split(whereSeparator: { $0.isWhitespace }).first == "connect-src" } ?? fallback
        let sources = connections.map { $0.split(whereSeparator: { $0.isWhitespace }).dropFirst().map(String.init) }
        let networkSources = (try? json(sources as Any? ?? NSNull())) ?? "null"
        let blocksTrustedTypes = directives.contains { $0.split(whereSeparator: { $0.isWhitespace }).first == "trusted-types" && $0.contains("'none'") }
        let blocksEval = !script.contains("'unsafe-eval'")
        let blocksWasm = !script.contains("'wasm-unsafe-eval'") && blocksEval
        return """
        if(!globalThis.__souloUserScriptPolicy){
          Object.defineProperty(globalThis,'__souloUserScriptPolicy',{value:true});
          function blocked(){throw new EvalError('Blocked by user script Content Security Policy');}
          \(connectionPolicy(sources: networkSources))
          if(\(blocksEval)){
            for(const fn of [function(){},async function(){},function*(){},async function*(){}])Object.defineProperty(Object.getPrototypeOf(fn),'constructor',{value:blocked,writable:false,configurable:false});
            for(const key of ['eval','Function'])Object.defineProperty(globalThis,key,{value:blocked,writable:false,configurable:false});
            for(const key of ['setTimeout','setInterval']){const native=globalThis[key];Object.defineProperty(globalThis,key,{value:(fn,...args)=>{if(typeof fn!=='function')return blocked();return native(fn,...args);},writable:false,configurable:false});}
          }
          if(\(blocksWasm)&&globalThis.WebAssembly){
            const Module=WebAssembly.Module,instantiate=WebAssembly.instantiate;
            Object.defineProperty(WebAssembly,'instantiate',{value:(input,...args)=>input instanceof Module?instantiate(input,...args):blocked(),writable:false,configurable:false});
            for(const key of ['Module','compile','compileStreaming','instantiateStreaming'])Object.defineProperty(WebAssembly,key,{value:blocked,writable:false,configurable:false});
          }
          for(const key of ['Worker','SharedWorker'])if(key in globalThis)Object.defineProperty(globalThis,key,{value:blocked,writable:false,configurable:false});
          if(\(blocksTrustedTypes)&&globalThis.trustedTypes){
            Object.defineProperty(Object.getPrototypeOf(trustedTypes),'createPolicy',{value:function(){throw new TypeError('Blocked by user script Trusted Types policy');},writable:false,configurable:false});
          }
        }
        """
    }
}

private enum WebExtensionUserScriptsScript {
    static let javaScript = #"""
    (()=>{
      if(typeof chrome.runtime.getManifest!=='function')return;
      const declared=[...(chrome.runtime.getManifest().permissions||[]),...(chrome.runtime.getManifest().optional_permissions||[])];
      if(chrome.userScripts||!declared.includes('userScripts'))return;
      if(typeof document!=='undefined'&&!location.href.startsWith(chrome.runtime.getURL('')))return;
      const call=(operation,values={})=>native({souloCompatibility:1,api:'userScripts',operation,...values});
      const api={execute:injection=>call('execute',{injection}),getScripts:filter=>call('getScripts',{filter:filter||{}}),register:scripts=>call('register',{scripts}),update:scripts=>call('update',{scripts}),
        unregister:filter=>call('unregister',{filter:filter||{}}),configureWorld:properties=>call('configureWorld',{properties}),
        getWorldConfigurations:()=>call('getWorldConfigurations'),resetWorldConfiguration:worldId=>call('resetWorldConfiguration',{worldId:worldId||''})};
      setIfMissing(chrome,'userScripts',api);if(root.browser&&root.browser!==chrome)setIfMissing(root.browser,'userScripts',api);
      const receivers={},channels=new Map();let connection;
      function configure(){if(connection)connection.postMessage({operation:'subscriptions',messages:!!receivers.onUserScriptMessage?.listeners.size,connections:!!receivers.onUserScriptConnect?.listeners.size});}
      function connect(){
        if(connection){configure();return;}
        const port=chrome.runtime.connectNative(host+'.userScripts');connection=port;
        const post=packet=>{try{port.postMessage(packet);}catch(error){console.error(error);}};
        port.onMessage.addListener(packet=>{
          if(packet.operation==='send'){
            let settled=false,waiting=false;
            const reply=value=>{if(!settled){settled=true;post({operation:'reply',id:packet.id,value:value??null});}};
            const fail=error=>{if(!settled){settled=true;post({operation:'reply',id:packet.id,error:String(error?.message??error)});}};
            const listeners=receivers.onUserScriptMessage?.listeners;
            if(!listeners?.size){post({operation:'ignored',id:packet.id});return;}
            for(const listener of listeners){try{
              const response=listener(packet.value,packet.sender,reply);
              if(response===true)waiting=true;
              else if(response&&typeof response.then==='function'){waiting=true;response.then(reply,fail);}
            }catch(error){fail(error);}}
            if(!waiting&&!settled)post({operation:'ignored',id:packet.id});
          }else if(packet.operation==='connect'){
            const listeners=receivers.onUserScriptConnect?.listeners;
            if(!listeners?.size){post({operation:'disconnect',id:packet.id});return;}
            const event=()=>{const listeners=new Set();return {addListener:fn=>listeners.add(fn),removeListener:fn=>listeners.delete(fn),hasListener:fn=>listeners.has(fn),hasListeners:()=>!!listeners.size,emit(...args){for(const fn of listeners)try{fn(...args);}catch(error){console.error(error);}}};};
            const channel={name:packet.name,sender:packet.sender,onMessage:event(),onDisconnect:event(),closed:false,
              postMessage(value){if(channel.closed)throw Error('The port is disconnected');post({operation:'post',id:packet.id,value});},
              disconnect(){if(channel.closed)return;channel.closed=true;channels.delete(packet.id);post({operation:'disconnect',id:packet.id});}
            };
            channels.set(packet.id,channel);for(const listener of listeners)try{listener(channel);}catch(error){console.error(error);}
          }else if(packet.operation==='post'){
            const channel=channels.get(packet.id);if(channel&&!channel.closed)channel.onMessage.emit(packet.value,channel);
          }else if(packet.operation==='disconnect'){
            const channel=channels.get(packet.id);if(channel){channels.delete(packet.id);channel.closed=true;channel.onDisconnect.emit(channel);}
          }
        });
        port.onDisconnect.addListener(()=>{void chrome.runtime.lastError;if(connection===port)connection=null;for(const channel of channels.values()){channel.closed=true;channel.onDisconnect.emit(channel);}channels.clear();});
        configure();
      }
      for(const key of ['onUserScriptMessage','onUserScriptConnect']){
        const listeners=new Set(),event={listeners,addListener(fn){if(typeof fn!=='function')throw TypeError('Listener must be a function');listeners.add(fn);connect();},removeListener(fn){listeners.delete(fn);configure();},hasListener:fn=>listeners.has(fn),hasListeners:()=>!!listeners.size};
        receivers[key]=event;setIfMissing(chrome.runtime,key,event);if(root.browser?.runtime&&root.browser.runtime!==chrome.runtime)setIfMissing(root.browser.runtime,key,event);
      }

    })();
    """#
}

private enum NativeWebExtensionCompatibilityError: LocalizedError {
    case missingPermission(String)
    case unsupportedAPI
    case unsupportedOperation
    case invalidResource
    case audioPlaybackFailed
    case notificationPermissionDenied

    var errorDescription: String? {
        switch self {
        case let .missingPermission(permission): "Extension permission required: \(permission)."
        case .unsupportedAPI: "The requested compatibility API is unsupported."
        case .unsupportedOperation: "The requested compatibility operation is unsupported."
        case .invalidResource: "The extension resource is invalid or unavailable."
        case .audioPlaybackFailed: "The extension audio resource could not be played."
        case .notificationPermissionDenied: "System notification permission was denied."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// App-owned WebKit primitives. This private context has no publisher code,
/// content scripts, background, external messaging or web-accessible resources.
/// Publisher permissions remain unchanged; all user code is separately checked
/// against its owning context before it enters that owner's isolated world.
@MainActor
@available(iOS 18.4, *)
private final class WebExtensionUserScriptExecutionHost {
    private var context: WKWebExtensionContext?
    private var view: WKWebView?
    private var container: UIView?
    private var directory: URL?
    private var pending: Task<WKWebView, Error>?
    private var facades: [String: (view: WKWebView, container: UIView?)] = [:]
    private var pendingFacades: [String: Task<WKWebView, Error>] = [:]

    private func facade(_ owner: WKWebExtensionContext) async throws -> WKWebView {
        if let value = facades[owner.uniqueIdentifier] { return value.view }
        if let task = pendingFacades[owner.uniqueIdentifier] { return try await task.value }
        let task = Task { @MainActor in
            guard let configuration = owner.webViewConfiguration else { throw URLError(.cancelled) }
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            var host: UIView?
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
                let container = UIView(frame: web.bounds); container.isUserInteractionEnabled = false; container.accessibilityElementsHidden = true
                container.alpha = 0.01; container.clipsToBounds = true; container.addSubview(web); window.insertSubview(container, at: 0); host = container
            }
            self.facades[owner.uniqueIdentifier] = (web, host)
            web.load(URLRequest(url: owner.baseURL.appendingPathComponent(WebExtensionDownloadsScript.helperFilename)))
            for _ in 0..<150 {
                if (try? await web.evaluateCompatibleJavaScript("document.readyState==='complete'&&typeof globalThis.chrome?.tabs?.query==='function'")) as? Bool == true { return web }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        pendingFacades[owner.uniqueIdentifier] = task; defer { pendingFacades[owner.uniqueIdentifier] = nil }
        do { return try await task.value } catch { remove(owner: owner.uniqueIdentifier); throw error }
    }

    private func document(controller: WKWebExtensionController?) async throws -> WKWebView {
        guard let controller else { throw URLError(.cancelled) }
        if let view, context?.webExtensionController === controller { return view }
        if let pending { return try await pending.value }
        let task = Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-script-host-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.directory = root
            try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Soulo Script Execution Host", "version": "1.0",
                "permissions": ["scripting", "tabs", "webNavigation"], "host_permissions": ["http://*/*", "https://*/*"]]).write(to: root.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><title>Soulo Script Host</title><body id='soulo-script-host'>".utf8).write(to: root.appendingPathComponent("host.html"))
            let object = try await WKWebExtension(resourceBaseURL: root), context = WKWebExtensionContext(for: object)
            context.uniqueIdentifier = UUID().uuidString
            context.grantedPermissions = Dictionary(uniqueKeysWithValues: object.requestedPermissions.map { ($0, Date.distantFuture) })
            context.grantedPermissionMatchPatterns = Dictionary(uniqueKeysWithValues: object.requestedPermissionMatchPatterns.map { ($0, Date.distantFuture) })
            try controller.load(context); self.context = context
            guard let configuration = context.webViewConfiguration else { throw URLError(.cannotLoadFromNetwork) }
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) {
                let host = UIView(frame: web.bounds); host.isUserInteractionEnabled = false; host.accessibilityElementsHidden = true
                host.alpha = 0.01; host.clipsToBounds = true; host.addSubview(web); window.insertSubview(host, at: 0); self.container = host
            }
            self.view = web; web.load(URLRequest(url: context.baseURL.appendingPathComponent("host.html")))
            for _ in 0..<150 {
                if (try? await web.evaluateCompatibleJavaScript("!!document.getElementById('soulo-script-host')")) as? Bool == true { return web }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw URLError(.timedOut)
        }
        pending = task; defer { pending = nil }
        do { return try await task.value }
        catch { close(); throw error }
    }
    func frames(target: [String: Any], event: String, token: String, owner: WKWebExtensionContext) async throws -> ([[String: Any]], WKWebView) {
        let source = try await facade(owner)
        guard let sourceTab = try await source.callAsyncJavaScript("return await chrome.tabs.get(id);", arguments: ["id": target["tabId"]!], in: nil, contentWorld: .page) as? [String: Any], let index = sourceTab["index"] as? Int,
              let nativeTab = owner.openTabs.compactMap({ $0.base as? any WKWebExtensionTab }).first(where: { $0.indexInWindow?(for: owner) == index }),
              let expectedView = nativeTab.webView?(for: owner) else { throw URLError(.resourceUnavailable) }
        let web = try await document(controller: owner.webExtensionController)
        var translated = target
        guard let internalTab = try await web.callAsyncJavaScript("return (await chrome.tabs.query({currentWindow:true})).find(t=>t.index===index)?.id;", arguments: ["index": index], in: nil, contentWorld: .page) as? Int else { throw URLError(.resourceUnavailable) }
        translated["tabId"] = internalTab
        let results = try await web.callAsyncJavaScript("""
        const metadata=await chrome.webNavigation.getAllFrames({tabId:target.tabId});
        const results=await chrome.scripting.executeScript({target,world:'ISOLATED',func:(name,token)=>{
          const nonce=crypto.randomUUID();dispatchEvent(new CustomEvent(name,{detail:token+':'+nonce}));return {nonce};
        },args:[event,token]});
        return results.map(value=>({...value,documentId:value.documentId||metadata.find(frame=>frame.frameId===value.frameId)?.documentId}));
        """, arguments: ["target": translated, "event": event, "token": token], in: nil, contentWorld: .page) as? [[String: Any]] ?? []
        guard nativeTab.webView?(for: owner) === expectedView, nativeTab.indexInWindow?(for: owner) == index else { throw URLError(.cancelled) }
        return (results, expectedView)
    }
    func tab(at index: Int, owner: WKWebExtensionContext) async throws -> [String: Any] {
        let web = try await facade(owner)
        guard let tab = try await web.callAsyncJavaScript("return (await chrome.tabs.query({currentWindow:true})).find(tab=>tab.index===index);", arguments: ["index": index], in: nil, contentWorld: .page) as? [String: Any] else { throw URLError(.resourceUnavailable) }
        return tab
    }
    func remove(owner: String) {
        pendingFacades.removeValue(forKey: owner)?.cancel()
        if let facade = facades.removeValue(forKey: owner) { facade.view.stopLoading(); facade.container?.removeFromSuperview() }
    }
    func close() {
        for owner in Array(facades.keys) { remove(owner: owner) }
        pending?.cancel(); pending = nil
        view?.stopLoading(); view = nil; container?.removeFromSuperview(); container = nil
        if let context, let controller = context.webExtensionController { try? controller.unload(context) }; context = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
    }
}

// Parse publisher source as data in a private WebContent process. A parser
// process failure leaves the original worker available to WebKit.
@MainActor
private final class WebExtensionSourceAnalyzer {
    private static let engine: String? = Bundle.main.url(forResource: "acorn-8.15.0", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private let web: WKWebView
    private let world = WKContentWorld.world(name: "Soulo Extension Source Analysis")
    private let function: String
    private var initialized = false

    init(function: String) throws {
        guard Self.engine != nil else { throw URLError(.fileDoesNotExist) }
        self.function = function
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.web = WKWebView(frame: .zero, configuration: configuration)
    }

    func analyze<Value: Sendable>(_ source: String, as type: Value.Type, mode: String = "") async throws -> Value? {
        try Task.checkCancellation()
        let body: String
        if initialized {
            body = "return globalThis.__souloAnalyzeSource(source, mode);"
        } else {
            guard let engine = Self.engine else { throw URLError(.fileDoesNotExist) }
            body = engine + "\n;globalThis.__souloAnalyzeSource = " + function
                + ";return globalThis.__souloAnalyzeSource(source, mode);"
        }
        let value: Value? = try await withCheckedThrowingContinuation { continuation in
            var pending: CheckedContinuation<Value?, Error>? = continuation
            func finish(_ result: Result<Value?, Error>) {
                guard let current = pending else { return }
                pending = nil
                current.resume(with: result)
            }
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { finish(.failure(URLError(.timedOut))) }
            }
            web.callAsyncJavaScript(body, arguments: ["source": source, "mode": mode], in: nil, in: world) { result in
                deadline.cancel()
                finish(result.map { $0 as? Value })
            }
        }
        initialized = true
        try Task.checkCancellation()
        return value
    }
}

// Keep native listeners, filters and site grants authoritative. This adapter
// supplies the source document for nonblocking events on WebKit versions
// that omit Chrome's initiator field.
private enum WebExtensionRequestEventCompatibility {
    static let javaScript = #"""
    ((api,navigation,retained,wrapMethod)=>{
      if(!api.webRequest)return;
      function addRequestListener(add,owner,args){
        let current=args;
        for(;;){
          try{return Reflect.apply(add,owner,current);}
          catch(error){
            const filter=current[1],patterns=filter?.urls;
            if(!Array.isArray(patterns))throw error;
            // Preserve the native subscription for schemes accepted by this WebKit.
            const unsupported=patterns.find(pattern=>typeof pattern==='string'&&/^wss?:\/\//i.test(pattern)&&String(error).includes(pattern));
            if(!unsupported)throw error;
            const urls=patterns.filter(pattern=>pattern!==unsupported);
            if(!urls.length)throw error;
            current=Array.from(current);current[1]={...filter,urls};
          }
        }
      }
      const pendingOrigins=new Map();
      const transportHeaders=new Set([
        'authorization','cache-control','connection','content-length','host','if-modified-since',
        'if-none-match','if-range','partial-data','pragma','proxy-authorization','proxy-connection',
        'transfer-encoding','x-playback-session-id'
      ]);
      function publisherRequestHeaders(headers){
        return headers?.filter(({name})=>{
          const key=name.toLowerCase();
          return !transportHeaders.has(key)&&!key.startsWith('sec-fetch-');
        });
      }
      function requestOrigin(details){
        const {tabId,frameId,documentId,type}=details;
        if(!Number.isInteger(tabId)||tabId<0||!Number.isInteger(frameId)||frameId<0||!documentId
          ||type==='main_frame'||type==='sub_frame')return null;
        const key=JSON.stringify([tabId,frameId,documentId]);
        if(pendingOrigins.has(key))return pendingOrigins.get(key);
        const lookup=Promise.resolve().then(async()=>{
          try{
            const frame=await navigation.getFrame({tabId,frameId});
            if(frame?.documentId?.toLowerCase()!==documentId.toLowerCase())return null;
            const source=new URL(frame.url);
            if(source.protocol!=='https:'&&source.protocol!=='http:')return null;
            const allowed=await api.permissions.contains({origins:[source.protocol+'//'+source.hostname+'/*']});
            return allowed?source.origin:null;
          }catch(_){return null;}
          finally{pendingOrigins.delete(key);}
        });
        pendingOrigins.set(key,lookup);
        return lookup;
      }
      for(const name of ['onBeforeRequest','onBeforeSendHeaders','onSendHeaders','onHeadersReceived','onAuthRequired',
        'onBeforeRedirect','onResponseStarted','onCompleted','onErrorOccurred']){
        const event=api.webRequest[name];
        const optionsName=name[0].toUpperCase()+name.slice(1)+'Options';
        const supportsExtraHeaders=api.webRequest[optionsName]?.EXTRA_HEADERS==='extraHeaders';
        if(!event||event.addListener?.__souloRulesetBinding)continue;
        if(!retained.includes(event))retained.push(event);
        if(!navigation?.getFrame||!api.permissions?.contains||!['onBeforeSendHeaders','onSendHeaders','onResponseStarted'].includes(name)){
          wrapMethod(event,'addListener',(add,owner)=>function(...args){return addRequestListener(add,owner,args);});
          continue;
        }
        const listeners=new WeakMap();
        wrapMethod(event,'addListener',(add,owner)=>function(listener,filter,extra){
          if(typeof listener!=='function'||(extra!==undefined&&!Array.isArray(extra))
            ||extra?.some(value=>value==='blocking'||value==='asyncBlocking'))
            return addRequestListener(add,owner,arguments);
          if(listeners.has(listener))return;
          let active=true;
          const usesExtraHeadersFallback=!supportsExtraHeaders&&extra?.includes('extraHeaders');
          const wrapped=details=>{
            // The native transport exposes headers generated by the browser
            // itself. They cannot be replayed by the extension.
            const value=usesExtraHeadersFallback&&Array.isArray(details.requestHeaders)
              ? {...details,requestHeaders:publisherRequestHeaders(details.requestHeaders)} : details;
            if('initiator' in value||value.originUrl||value.documentUrl)return listener(value);
            const origin=requestOrigin(value);
            if(!origin)return listener(value);
            // A nonblocking event cannot change the request. Preserve the
            // listener's lifetime while resolving the exact source document.
            origin.then(source=>{
              if(active)listener(source?{...value,initiator:source}:value);
            }).catch(error=>console.error(error));
          };
          const args=[wrapped,filter];
          if(extra!==undefined)args.push(usesExtraHeadersFallback?extra.filter(value=>value!=='extraHeaders'):extra);
          const result=addRequestListener(add,owner,args);
          listeners.set(listener,{wrapped,cancel:()=>{active=false;}});
          return result;
        });
        wrapMethod(event,'removeListener',(remove,owner)=>function(listener){
          const registration=listeners.get(listener);
          const result=Reflect.apply(remove,owner,[registration?.wrapped||listener]);
          registration?.cancel();
          listeners.delete(listener);
          return result;
        });
        wrapMethod(event,'hasListener',(has,owner)=>function(listener){
          return Reflect.apply(has,owner,[listeners.get(listener)?.wrapped||listener]);
        });
      }
    })
    """#
}

// Badge color remains owned by the native context and the matching browser tab.
private enum WebExtensionActionColorCompatibility {
    static let javaScript = #"""
    ((root,chrome,manifest,native,setIfMissing)=>{
      if(!manifest.action&&!manifest.browser_action)return;
      const colorBytes = color => {
        if (Array.isArray(color)) {
          if (color.length === 4 && color.every(value => Number.isInteger(value) && value >= 0 && value <= 255) && color[3] > 0)
            return Array.from(color);
          throw new TypeError('Expected a non-transparent RGBA color.');
        }
        if (typeof color !== 'string' || !color.trim()) throw new TypeError('Expected a CSS color.');
        const canvas = typeof OffscreenCanvas === 'function' ? new OffscreenCanvas(1, 1) : root.document?.createElement('canvas');
        const drawing = canvas?.getContext('2d');
        if (!drawing) throw new Error('Color parsing is unavailable.');
        // Assign twice to distinguish invalid values from the canvas's current color.
        drawing.fillStyle = '#000000'; drawing.fillStyle = color;
        const first = drawing.fillStyle;
        drawing.fillStyle = '#ffffff'; drawing.fillStyle = color;
        if (first !== drawing.fillStyle) throw new TypeError('Invalid CSS color.');
        drawing.fillRect(0, 0, 1, 1);
        const bytes = Array.from(drawing.getImageData(0, 0, 1, 1).data);
        if (!bytes[3]) throw new TypeError('Expected a non-transparent RGBA color.');
        return bytes;
      };
      const badgeColor = (operation, details, callback) => {
        const message = {souloCompatibility:1,api:'actionBadgeTextColor',operation};
        if (operation === 'set') message.color = colorBytes(details?.color);
        const transform = operation === 'set' ? () => undefined : value => value;
        if (details?.tabId === undefined) return native(message,callback,transform);
        if (!Number.isSafeInteger(details.tabId) || details.tabId < 1) throw new TypeError('Invalid tab ID.');
        if (typeof callback === 'function') {
          chrome.tabs.get(details.tabId, tab => {
            if (chrome.runtime.lastError || !tab) { callback(undefined); return; }
            native({...message,index:tab.index},callback,transform);
          });
          return;
        }
        return chrome.tabs.get(details.tabId).then(tab=>native({...message,index:tab.index},undefined,transform));
      };
      for (const action of new Set([chrome.action,root.browser?.action])) {
        setIfMissing(action,'setBadgeTextColor',(details,callback)=>badgeColor('set',details,callback));
        setIfMissing(action,'getBadgeTextColor',(details,callback)=>typeof details==='function'
          ? badgeColor('get',undefined,details) : badgeColor('get',details,callback));
      }
    })
    """#
}

private enum WebExtensionClassicImports {
    static let javaScript = #"""
        (function(source, mode){
          try {
            if(source.length>8000000)return null;
            const program=acorn.parse(source,{ecmaVersion:'latest',sourceType:'script'});
            const imports=[], accepted=new Set();
            const workerOnly=new Set(['ServiceWorkerGlobalScope','WorkerGlobalScope','skipWaiting','clients','registration','caches','oninstall','onactivate','onfetch']);
            function literal(node){
              if(node.type==='Literal')return node.value;
              if(node.type==='TemplateLiteral'&&!node.expressions.length)return node.quasis[0].value.cooked;
              return null;
            }
            function call(statement){
              const node=statement?.type==='ExpressionStatement'&&statement.expression;
              return node?.type==='CallExpression'&&!node.optional&&node.callee.type==='Identifier'&&node.callee.name==='importScripts' ? node : null;
            }
            // Chrome packages also use a guard for a helper that supplies a global.
            function guardedCall(statement){
              if(statement.type!=='IfStatement'||statement.alternate||statement.consequent.type!=='BlockStatement'||statement.consequent.body.length!==1)return null;
              const test=statement.test;
              if(test.type!=='BinaryExpression'||!['===','=='].includes(test.operator)||test.left.type!=='UnaryExpression'||
                 test.left.operator!=='typeof'||test.left.argument.type!=='Identifier'||test.left.argument.name==='importScripts'||test.right.value!=='undefined')return null;
              return call(statement.consequent.body[0]);
            }
            // Preload only an initial static list. Diagnostics around imports
            // must be observational, including the catch path if a load fails.
            function diagnostic(statement, method, errorName){
              const node=statement?.type==='ExpressionStatement'&&statement.expression;
              if(node?.type!=='CallExpression'||node.optional||node.callee.type!=='MemberExpression'||node.callee.computed||
                 node.callee.object.name!=='console'||node.callee.property.name!==method)return false;
              function plainArgument(arg){
                if(arg.type==='Literal')return typeof arg.value==='string';
                if(arg.type==='BinaryExpression'&&arg.operator==='+')return plainArgument(arg.left)&&plainArgument(arg.right);
                if(errorName)return arg.type==='Identifier'&&arg.name===errorName;
                return arg.type==='NewExpression'&&arg.callee.name==='Date'&&!arg.arguments.length;
              }
              return node.arguments.every(plainArgument);
            }
            function guardedTryCall(statement){
              if(statement?.type!=='TryStatement'||statement.finalizer||statement.block.body.length!==1||
                 statement.handler?.param?.type!=='Identifier'||statement.handler.body.body.length!==1||
                 !diagnostic(statement.handler.body.body[0],'error',statement.handler.param.name))return null;
              const guard=statement.block.body[0];
              if(guard.type!=='IfStatement'||guard.alternate||guard.consequent.type!=='BlockStatement'||guard.consequent.body.length!==1)return null;
              const test=guard.test;
              if(test.type!=='UnaryExpression'||test.operator!=='!'||test.argument.type!=='MemberExpression'||
                 test.argument.optional||test.argument.computed||test.argument.object.name!=='globalThis')return null;
              return call(guard.consequent.body[0]);
            }
            const guardedEntry=mode==='guarded-entry', guardedDependency=mode==='guarded-dependency';
            let statements=program.body;
            if(guardedEntry){
              const prefix=statements.find(statement=>!statement.directive&&statement.type!=='EmptyStatement'&&!diagnostic(statement,'log'));
              if(!guardedTryCall(prefix))return null;
              statements=[prefix];
            }
            for(const statement of statements){
              if(statement.directive||statement.type==='EmptyStatement')continue;
              const direct=call(statement), entry=direct||(!accepted.size&&(guardedEntry?guardedTryCall(statement):guardedCall(statement)));
              if(!entry)break;
              if(!entry.arguments.length)return null;
              for(const argument of entry.arguments) {
                const path=literal(argument);
                if(typeof path!=='string'||!/^[A-Za-z0-9_./@+\-]+$/.test(path)||path.startsWith('//'))return null;
                imports.push(path);
              }
              accepted.add(entry.callee);
              if(!direct)break;
            }
            const standalone=imports.length===0;
            // A generated background document has a different URL and
            // cannot deliver service worker events.
            const extraWorkerEvents=new Set(['message','messageerror','push','pushsubscriptionchange','sync','periodicsync',
              'notificationclick','notificationclose','backgroundfetchabort','backgroundfetchclick','backgroundfetchfail',
              'backgroundfetchsuccess','contentdelete','cookiechange']);
            function registrationGuard(test){
              return test?.type==='MemberExpression'&&!test.optional&&!test.computed&&
                test.object.name==='globalThis'&&test.property.name==='registration';
            }
            function* descendants(tree){
              const remaining=[tree];
              while(remaining.length){
                const item=remaining.pop();
                yield item;
                for(const value of Object.values(item)){
                  if(Array.isArray(value)){for(const child of value)if(child?.type)remaining.push(child);}
                  else if(value?.type)remaining.push(value);
                }
              }
            }
            function hasDocumentNotification(guard){
              const createsWorkerNotification=Array.from(descendants(guard.consequent)).some(node=>
                node.type==='CallExpression'&&node.callee.object?.name==='registration'&&node.callee.property?.name==='showNotification');
              if(!createsWorkerNotification)return false;
              const assignments=Array.from(descendants(guard.alternate)).filter(node=>node.type==='AssignmentExpression'&&node.operator==='=');
              return assignments.some(({left,right})=>left.type==='Identifier'&&right.type==='NewExpression'&&right.callee.name==='Notification'&&
                assignments.some(({left:target,right:handler})=>target.type==='MemberExpression'&&!target.computed&&target.object.name===left.name&&
                  target.property.name==='onclick'&&['FunctionExpression','ArrowFunctionExpression'].includes(handler.type)));
            }
            let requiresNotificationFallback=false, hasNotificationFallback=false;
            const queue=[{node:program, inFunction:false, hasRegistration:false}];
            while(queue.length){
              const {node,inFunction,hasRegistration}=queue.pop();
              if(node.type==='Identifier'&&(workerOnly.has(node.name)&&!(hasRegistration&&node.name==='registration')||
                 node.name==='importScripts'&&!accepted.has(node)))return null;
              const value=literal(node);
              if(workerOnly.has(value)||value==='importScripts')return null;
              const stricter=standalone||guardedEntry||guardedDependency;
              if(stricter&&(node.type==='ImportExpression'||
                (node.name==='location'||value==='location')&&!(guardedDependency&&inFunction)||
                (node.type==='Identifier'&&node.name.startsWith('on')&&extraWorkerEvents.has(node.name.slice(2)))))return null;
              if(node.type==='CallExpression'&&node.arguments.length&&
                 (node.callee.name==='addEventListener'||node.callee.property?.name==='addEventListener'||node.callee.property&&literal(node.callee.property)==='addEventListener')){
                const event=literal(node.arguments[0]);
                if(guardedEntry&&event==='notificationclick'&&node.callee.object?.name==='globalThis')requiresNotificationFallback=true;
                else if(['install','activate','fetch'].includes(event)||stricter&&extraWorkerEvents.has(event))return null;
              }
              const insideFunction=inFunction||['FunctionDeclaration','FunctionExpression','ArrowFunctionExpression'].includes(node.type);
              const hasGuard=guardedEntry&&node.type==='IfStatement'&&registrationGuard(node.test)&&node.alternate;
              if(hasGuard&&!hasNotificationFallback)hasNotificationFallback=hasDocumentNotification(node);
              for(const child of Object.values(node)){
                if(Array.isArray(child)){for(const item of child)if(item?.type)queue.push({node:item,inFunction:insideFunction,hasRegistration});}
                else if(child?.type)queue.push({node:child,inFunction:insideFunction,
                  hasRegistration:hasRegistration||!!(hasGuard&&(child===node.test||child===node.consequent))});
              }
            }
            if(requiresNotificationFallback&&!hasNotificationFallback)return null;
            return imports;
          } catch (_) { return null; }
        })
        """#
}

private enum WebExtensionUserScriptParser {
    struct Completion: Sendable { let statementStart: Int; let statementEnd: Int; let expressionStart: Int; let expressionEnd: Int }
    private struct Result: Decodable { let ranges: [Int]?; let error: String? }

    static func completion(in source: String) async throws -> Completion? {
        let parser = try await WebExtensionSourceAnalyzer(function: #"""
        (function(source){
          try {
            const last=acorn.parse(source,{ecmaVersion:'latest',sourceType:'script'}).body.at(-1);
            return JSON.stringify(last?.type==='ExpressionStatement'
              ? {ranges:[last.start,last.end,last.expression.start,last.expression.end]} : {});
          } catch(error) { return JSON.stringify({error:String(error)}); }
        })
        """#)
        guard let value = try await parser.analyze(source, as: String.self) else { return nil }
        let result = try JSONDecoder().decode(Result.self, from: Data(value.utf8))
        if let error = result.error {
            throw NSError(domain: "com.dkluge.Soulo.UserScripts", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        guard let ranges = result.ranges, ranges.count == 4 else { return nil }
        return Completion(statementStart: ranges[0], statementEnd: ranges[1], expressionStart: ranges[2], expressionEnd: ranges[3])
    }
}

/// Source lifecycle integration for the unmodified FastStream package. The
/// public WebExtension API remains generic; this adapter only connects the
/// publisher's existing source API to a site's same-document video changes.
private enum WebExtensionFastStreamSourceAdapter {
    static func source(in root: URL) -> String {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("player/FastStreamClient.mjs").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("player/VideoSource.mjs").path) else { return "" }
        return javaScript
    }
    private static let javaScript = #"""
    ;(()=>{
      const api=globalThis.chrome||globalThis.browser,core=globalThis.__souloFrameMessagingCore;
      if(!api?.runtime||!core||globalThis.__souloFastStreamSourceLifecycle)return;
      Object.defineProperty(globalThis,'__souloFastStreamSourceLifecycle',{value:true});
      if(typeof document==='undefined')return;
      if(core.ownURL(location.href)&&location.pathname.endsWith('/player/index.html')){
        Object.defineProperty(globalThis,'__souloNativeMediaSource',{value:video=>{
          const client=globalThis.fastStream,source=client?.source;
          if(!source||client.player?.getVideo?.()!==video)return null;
          const url=new URL(source.url,location.href);if(!/^https?:$/.test(url.protocol))return null;
          const referrer=Object.entries(source.headers||{}).find(([key])=>key.toLowerCase()==='referer')?.[1]||'';
          const mode=String(source.mode||'');
          return {url:url.href,referrer,mime:mode.includes('hls')?'application/vnd.apple.mpegurl':mode.includes('dash')?'application/dash+xml':''};
        }});
        let revision=0;
        core.applyMediaSource=async message=>{
          const current=++revision,until=Date.now()+8000;
          while(!globalThis.fastStream?.setSource&&current===revision&&Date.now()<until)await new Promise(resolve=>setTimeout(resolve,40));
          const client=globalThis.fastStream;if(current!==revision||typeof client?.setSource!=='function')return {handled:false};
          if(client.source?.url===message.url)return {handled:true};
          const [{VideoSource},{URLUtils},{PlayerModes}]=await Promise.all([
            import(api.runtime.getURL('player/VideoSource.mjs')),import(api.runtime.getURL('player/utils/URLUtils.mjs')),import(api.runtime.getURL('player/enums/PlayerModes.mjs'))
          ]);
          if(current!==revision)return {handled:false};
          const previous=client.source,mode=URLUtils.getModeFromExtension(URLUtils.get_url_extension(message.url))||PlayerModes.ACCELERATED_MP4;
          let headers={};try{if(previous&&new URL(previous.url).origin===new URL(message.url).origin)headers={...previous.headers};}catch(_){}
          const source=new VideoSource(message.url,headers,mode);
          await client.setSource(source);
          if(current===revision&&message.play)try{await client.play();}catch(_){}
          return {handled:current===revision};
        };
        return;
      }
      if(!/^https?:$/.test(location.protocol))return;
      const watched=new Map();let pending=false;
      const owns=frame=>core.ownURL(frame.src)||frame.src.startsWith('webkit-masked-url:');
      function hasReplacement(video){
        for(let node=video,depth=0;node&&node!==document.body&&depth<8;node=node.parentElement,depth++){
          const parent=node.parentElement;if(!parent)break;
          const frames=Array.from(parent.children).filter(child=>child.tagName==='IFRAME'&&owns(child));
          if(frames.length)return frames.length===1;
        }
        return false;
      }
      function url(video){
        const value=video.getAttribute('src')||video.querySelector('source[src]')?.getAttribute('src');
        if(!value)return null;try{const result=new URL(value,location.href);return ['http:','https:'].includes(result.protocol)&&!result.username&&!result.password?result.href:null;}catch(_){return null;}
      }
      function flush(){
        pending=false;
        for(const[video,state]of watched){
          if(!video.isConnected){state.observer.disconnect();watched.delete(video);continue;}
          const next=url(video);if(!next||next===state.url)continue;
          if(!hasReplacement(video)){state.url=next;continue;}
          state.url=next;
          core.request(core.packet('mediaSourceChanged',{url:next,play:state.play||!video.paused})).catch(()=>{});
          state.play=false;
        }
      }
      function schedule(){if(!pending){pending=true;setTimeout(flush,120);}}
      function watch(video){
        if(watched.has(video))return;
        if(watched.size>=32){for(const[old,state]of watched)if(!old.isConnected){state.observer.disconnect();watched.delete(old);}}
        if(watched.size>=32)return;
        const observer=new MutationObserver(schedule);observer.observe(video,{attributes:true,attributeFilter:['src'],childList:true,subtree:true});
        watched.set(video,{url:url(video),play:!video.paused,observer});
      }
      function scan(node){if(node.nodeType!==1&&node.nodeType!==9)return;if(node.tagName==='VIDEO')watch(node);for(const video of node.querySelectorAll('video'))watch(video);}
      const observer=new MutationObserver(entries=>{for(const entry of entries)for(const node of entry.addedNodes)scan(node);schedule();});
      observer.observe(document,{childList:true,subtree:true});
      addEventListener('play',event=>{const state=watched.get(event.target);if(state){state.play=true;schedule();}},true);
      for(const event of ['loadedmetadata','loadstart','emptied'])addEventListener(event,value=>{if(value.target?.tagName==='VIDEO'){watch(value.target);schedule();}},true);
      addEventListener('DOMContentLoaded',()=>scan(document),{once:true});scan(document);
    })();
    """#
}
