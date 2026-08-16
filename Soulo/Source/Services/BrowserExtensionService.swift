import Foundation
import UniformTypeIdentifiers
import WebKit

enum BrowserExtensionFeatureAvailability {
    // Standard WebExtensions remain compiled for the next release, but are
    // deliberately disabled until cross-store packaging and permission
    // behavior have completed device testing. UserScript stays available.
    static let standardWebExtensionsEnabled = false
}

enum UserScriptInjectionTime: String, Codable {
    case documentStart
    case documentEnd
}

struct UserScriptRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var source: String
    var matchPatterns: [String]
    /// Optional keeps stores written by earlier builds decodable.
    var excludePatterns: [String]?
    var grants: [String]?
    var connectDomains: [String]?
    var namespace: String?
    var version: String?
    var injectionTime: UserScriptInjectionTime
    var isEnabled: Bool
    var installedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        source: String,
        matchPatterns: [String] = ["*://*/*"],
        excludePatterns: [String] = [],
        grants: [String] = [],
        connectDomains: [String] = [],
        namespace: String? = nil,
        version: String? = nil,
        injectionTime: UserScriptInjectionTime = .documentEnd,
        isEnabled: Bool = true,
        installedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.matchPatterns = matchPatterns
        self.excludePatterns = excludePatterns
        self.grants = grants
        self.connectDomains = connectDomains
        self.namespace = namespace
        self.version = version
        self.injectionTime = injectionTime
        self.isEnabled = isEnabled
        self.installedAt = installedAt
    }

    var allowsXMLHTTPRequests: Bool {
        let declaredGrants = grants ?? []
        guard !declaredGrants.contains(where: { $0.caseInsensitiveCompare("none") == .orderedSame }) else {
            return false
        }
        // Older and hand-written scripts without @grant keep their existing behavior.
        return declaredGrants.isEmpty || declaredGrants.contains {
            ["GM_xmlhttpRequest", "GM.xmlHttpRequest"].contains($0)
        }
    }
}

struct WebExtensionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var version: String?
    var storedResourceName: String
    var requestedPermissionCount: Int
    var requestedSiteCount: Int
    var isEnabled: Bool
    var installedAt: Date
}

enum BrowserInstallPackageKind: String, Equatable {
    case webExtension
    case userScript
}

/// A package downloaded from a webpage that Soulo can install directly.
/// Recognition intentionally requires a known package suffix or a UserScript
/// metadata block so ordinary JavaScript downloads are not treated as scripts.
struct BrowserExtensionInstallCandidate: Identifiable, Equatable {
    let id = UUID()
    let fileURL: URL
    let sourceURL: URL?
    let kind: BrowserInstallPackageKind

    var displayName: String {
        let filename = fileURL.lastPathComponent
        if kind == .userScript, filename.lowercased().hasSuffix(".user.js") {
            return String(filename.dropLast(".user.js".count))
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    static func recognizedDownloadURL(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if filename.hasSuffix(".user.js") {
            return true
        }

        guard BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled else {
            return false
        }
        if ["crx", "xpi"].contains(url.pathExtension.lowercased()) { return true }

        return url.host?.lowercased() == "clients2.google.com"
            && url.path.lowercased().contains("/service/update2/crx")
    }

    static func detect(fileURL: URL, sourceURL: URL?) -> Self? {
        let filename = fileURL.lastPathComponent.lowercased()
        if filename.hasSuffix(".user.js") || containsUserScriptMetadata(fileURL) {
            return Self(fileURL: fileURL, sourceURL: sourceURL, kind: .userScript)
        }

        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
           ["crx", "xpi", "zip"].contains(fileURL.pathExtension.lowercased())
            || sourceURL.map(recognizedDownloadURL) == true {
            return Self(fileURL: fileURL, sourceURL: sourceURL, kind: .webExtension)
        }
        return nil
    }

    private static func containsUserScriptMetadata(_ fileURL: URL) -> Bool {
        guard fileURL.pathExtension.lowercased() == "js",
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let prefix = String(data: data, encoding: .utf8) else { return false }
        return prefix.contains("==UserScript==") && prefix.contains("@name")
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

private struct BrowserExtensionStore: Codable {
    var userScripts: [UserScriptRecord]
    var webExtensions: [WebExtensionRecord]
}

enum BrowserExtensionError: LocalizedError {
    case temporarilyDisabled
    case unsupportedSystem
    case unreadableScript
    case emptyScript
    case invalidMatchPattern(String)
    case invalidExtension

    var errorDescription: String? {
        switch self {
        case .temporarilyDisabled:
            AppLocalization.string("web_extension_temporarily_disabled")
        case .unsupportedSystem:
            AppLocalization.string("web_extension_requires_ios")
        case .unreadableScript:
            AppLocalization.string("userscript_unreadable")
        case .emptyScript:
            AppLocalization.string("userscript_empty")
        case let .invalidMatchPattern(pattern):
            String(
                format: AppLocalization.string("userscript_invalid_match_pattern"),
                locale: Locale.current,
                arguments: [pattern]
            )
        case .invalidExtension:
            AppLocalization.string("web_extension_invalid")
        }
    }
}

@MainActor
final class BrowserExtensionService: ObservableObject {
    static let shared = BrowserExtensionService()

    @Published private(set) var userScripts: [UserScriptRecord] = []
    @Published private(set) var webExtensions: [WebExtensionRecord] = []

    private let fileManager = FileManager.default

    private init() {
        loadStore()
        if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled {
            Task { [weak self] in
                await self?.restoreEnabledNativeExtensions()
            }
        }
    }

    func scripts(for url: URL?, at injectionTime: UserScriptInjectionTime) -> [UserScriptRecord] {
        guard let url else { return [] }
        return userScripts.filter {
            $0.isEnabled
                && $0.injectionTime == injectionTime
                && UserScriptURLMatcher.matches(url: url, patterns: $0.matchPatterns)
                && !UserScriptURLMatcher.matches(url: url, patterns: $0.excludePatterns ?? [])
        }
    }

    func userScript(id: UUID) -> UserScriptRecord? {
        userScripts.first { $0.id == id }
    }

    @discardableResult
    func importUserScript(from sourceURL: URL) throws -> UserScriptRecord {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            throw BrowserExtensionError.unreadableScript
        }
        return try saveUserScript(
            id: nil,
            fallbackName: sourceURL.deletingPathExtension().lastPathComponent,
            source: source,
            explicitPatterns: nil,
            injectionTime: nil
        )
    }

    @discardableResult
    func saveUserScript(
        id: UUID?,
        fallbackName: String,
        source: String,
        explicitPatterns: [String]?,
        injectionTime: UserScriptInjectionTime?,
        explicitName: String? = nil
    ) throws -> UserScriptRecord {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { throw BrowserExtensionError.emptyScript }

        let metadata = Self.parseMetadata(from: source)
        let requestedPatterns = (explicitPatterns ?? metadata.patterns)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedPatterns = requestedPatterns.isEmpty ? ["*://*/*"] : requestedPatterns
        let normalizedExcludes = metadata.excludePatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let invalid = (normalizedPatterns + normalizedExcludes).first(where: {
            !UserScriptURLMatcher.isValid(pattern: $0)
        }) {
            throw BrowserExtensionError.invalidMatchPattern(invalid)
        }

        let resolvedName = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? LanguageManager.shared.localizedString("userscript_untitled")
        let normalizedNamespace = metadata.namespace?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let existingRecord = id.flatMap { existingID in userScripts.first { $0.id == existingID } }
            ?? normalizedNamespace.flatMap { namespace in
                userScripts.first {
                    $0.name.caseInsensitiveCompare(resolvedName) == .orderedSame
                        && $0.namespace?.caseInsensitiveCompare(namespace) == .orderedSame
                }
            }
        let record = UserScriptRecord(
            id: existingRecord?.id ?? id ?? UUID(),
            name: resolvedName,
            source: source,
            matchPatterns: normalizedPatterns,
            excludePatterns: normalizedExcludes,
            grants: metadata.grants,
            connectDomains: metadata.connectDomains,
            namespace: normalizedNamespace,
            version: metadata.version?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            injectionTime: injectionTime ?? metadata.injectionTime,
            isEnabled: existingRecord?.isEnabled ?? true,
            installedAt: existingRecord?.installedAt ?? Date()
        )

        if let index = userScripts.firstIndex(where: { $0.id == record.id }) {
            userScripts[index] = record
        } else {
            userScripts.insert(record, at: 0)
        }
        persistAndNotify()
        return record
    }

    func setUserScriptEnabled(_ id: UUID, enabled: Bool) {
        guard let index = userScripts.firstIndex(where: { $0.id == id }) else { return }
        userScripts[index].isEnabled = enabled
        persistAndNotify()
    }

    func deleteUserScript(_ id: UUID) {
        userScripts.removeAll { $0.id == id }
        persistAndNotify()
    }

    @discardableResult
    func installWebExtension(from sourceURL: URL) async throws -> WebExtensionRecord {
        guard BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled else {
            throw BrowserExtensionError.temporarilyDisabled
        }
        guard #available(iOS 18.4, *) else { throw BrowserExtensionError.unsupportedSystem }

        let identifier = UUID()
        let destinationDirectory = webExtensionRoot
            .appendingPathComponent(identifier.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let isCRXPackage = Self.isCRXFile(sourceURL)
        let storedResourceName = isCRXPackage
            ? sourceURL.deletingPathExtension().lastPathComponent + ".zip"
            : sourceURL.lastPathComponent
        let destination = destinationDirectory.appendingPathComponent(storedResourceName)

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            if isCRXPackage {
                try Self.convertCRXToZIP(sourceURL: sourceURL, destinationURL: destination)
            } else {
                try fileManager.copyItem(at: sourceURL, to: destination)
            }
            let metadata = try await NativeWebExtensionRuntime.shared.load(
                id: identifier,
                resourceURL: destination
            )
            let record = WebExtensionRecord(
                id: identifier,
                name: metadata.name,
                version: metadata.version,
                storedResourceName: storedResourceName,
                requestedPermissionCount: metadata.permissionCount,
                requestedSiteCount: metadata.siteCount,
                isEnabled: true,
                installedAt: Date()
            )
            webExtensions.insert(record, at: 0)
            // Reload the visible page once so the newly loaded extension can
            // attach to an already-open tab as well as future navigations.
            persistAndNotify()
            return record
        } catch {
            try? fileManager.removeItem(at: destinationDirectory)
            throw error
        }
    }

    func setWebExtensionEnabled(_ id: UUID, enabled: Bool) {
        guard let index = webExtensions.firstIndex(where: { $0.id == id }) else { return }
        webExtensions[index].isEnabled = enabled
        let record = webExtensions[index]
        persistAndNotify(reloadPages: false)

        guard #available(iOS 18.4, *) else { return }
        Task {
            if enabled {
                _ = try? await NativeWebExtensionRuntime.shared.load(
                    id: record.id,
                    resourceURL: resourceURL(for: record)
                )
            } else {
                NativeWebExtensionRuntime.shared.unload(id: record.id)
            }
            NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
        }
    }

    func deleteWebExtension(_ id: UUID) {
        guard let record = webExtensions.first(where: { $0.id == id }) else { return }
        if #available(iOS 18.4, *) {
            NativeWebExtensionRuntime.shared.unload(id: id)
        }
        webExtensions.removeAll { $0.id == id }
        try? fileManager.removeItem(
            at: webExtensionRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
        )
        persistAndNotify()
    }

    private func restoreEnabledNativeExtensions() async {
        guard #available(iOS 18.4, *) else { return }
        for record in webExtensions where record.isEnabled {
            _ = try? await NativeWebExtensionRuntime.shared.load(
                id: record.id,
                resourceURL: resourceURL(for: record)
            )
        }
    }

    private func resourceURL(for record: WebExtensionRecord) -> URL {
        webExtensionRoot
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent(record.storedResourceName)
    }

    private func loadStore() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(BrowserExtensionStore.self, from: data) else {
            return
        }
        userScripts = store.userScripts
        webExtensions = store.webExtensions
    }

    private func persistAndNotify(reloadPages: Bool = true) {
        let store = BrowserExtensionStore(userScripts: userScripts, webExtensions: webExtensions)
        try? fileManager.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeURL, options: .atomic)
        }
        if reloadPages {
            NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
        }
    }

    private var extensionRoot: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("SouloExtensions", isDirectory: true)
    }

    private var webExtensionRoot: URL {
        extensionRoot.appendingPathComponent("WebExtensions", isDirectory: true)
    }

    private var storeURL: URL {
        extensionRoot.appendingPathComponent("extensions.json")
    }

    private static func parseMetadata(from source: String) -> (
        name: String?,
        patterns: [String],
        excludePatterns: [String],
        grants: [String],
        connectDomains: [String],
        namespace: String?,
        version: String?,
        injectionTime: UserScriptInjectionTime
    ) {
        var name: String?
        var patterns: [String] = []
        var excludePatterns: [String] = []
        var grants: [String] = []
        var connectDomains: [String] = []
        var namespace: String?
        var version: String?
        var injectionTime: UserScriptInjectionTime = .documentEnd
        var isInsideMetadata = false

        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(320) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.contains("==UserScript==") {
                isInsideMetadata = true
                continue
            }
            if value.contains("==/UserScript==") { break }
            guard isInsideMetadata else { continue }

            if value.range(of: #"^//\s*@name\s+(.+)$"#, options: .regularExpression) != nil {
                name = value.replacingOccurrences(
                    of: #"^//\s*@name\s+"#,
                    with: "",
                    options: .regularExpression
                )
            } else if value.range(of: #"^//\s*@(match|include)\s+(.+)$"#, options: .regularExpression) != nil {
                let pattern = value.replacingOccurrences(
                    of: #"^//\s*@(match|include)\s+"#,
                    with: "",
                    options: .regularExpression
                )
                patterns.append(pattern)
            } else if value.range(of: #"^//\s*@(exclude|exclude-match)\s+(.+)$"#, options: .regularExpression) != nil {
                excludePatterns.append(value.replacingOccurrences(
                    of: #"^//\s*@(exclude|exclude-match)\s+"#,
                    with: "",
                    options: .regularExpression
                ))
            } else if value.range(of: #"^//\s*@grant\s+(.+)$"#, options: .regularExpression) != nil {
                grants.append(value.replacingOccurrences(
                    of: #"^//\s*@grant\s+"#,
                    with: "",
                    options: .regularExpression
                ))
            } else if value.range(of: #"^//\s*@connect\s+(.+)$"#, options: .regularExpression) != nil {
                connectDomains.append(value.replacingOccurrences(
                    of: #"^//\s*@connect\s+"#,
                    with: "",
                    options: .regularExpression
                ))
            } else if value.range(of: #"^//\s*@namespace\s+(.+)$"#, options: .regularExpression) != nil {
                namespace = value.replacingOccurrences(
                    of: #"^//\s*@namespace\s+"#,
                    with: "",
                    options: .regularExpression
                )
            } else if value.range(of: #"^//\s*@version\s+(.+)$"#, options: .regularExpression) != nil {
                version = value.replacingOccurrences(
                    of: #"^//\s*@version\s+"#,
                    with: "",
                    options: .regularExpression
                )
            } else if value.range(of: #"^//\s*@run-at\s+document-start"#, options: .regularExpression) != nil {
                injectionTime = .documentStart
            }
        }
        return (
            name,
            patterns,
            excludePatterns,
            grants,
            connectDomains,
            namespace,
            version,
            injectionTime
        )
    }

    private static func convertCRXToZIP(sourceURL: URL, destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard data.count > 16,
              String(data: data.prefix(4), encoding: .ascii) == "Cr24" else {
            throw BrowserExtensionError.invalidExtension
        }

        func littleEndianUInt32(at offset: Int) -> Int? {
            guard data.count >= offset + 4 else { return nil }
            return Int(data[offset])
                | (Int(data[offset + 1]) << 8)
                | (Int(data[offset + 2]) << 16)
                | (Int(data[offset + 3]) << 24)
        }

        guard let version = littleEndianUInt32(at: 4) else {
            throw BrowserExtensionError.invalidExtension
        }
        let zipOffset: Int
        if version == 2,
           let publicKeyLength = littleEndianUInt32(at: 8),
           let signatureLength = littleEndianUInt32(at: 12) {
            zipOffset = 16 + publicKeyLength + signatureLength
        } else if version == 3, let headerLength = littleEndianUInt32(at: 8) {
            zipOffset = 12 + headerLength
        } else {
            throw BrowserExtensionError.invalidExtension
        }

        guard zipOffset + 1 < data.count,
              data[zipOffset] == 0x50,
              data[zipOffset + 1] == 0x4B else {
            throw BrowserExtensionError.invalidExtension
        }
        try data.suffix(from: zipOffset).write(to: destinationURL, options: .atomic)
    }

    private static func isCRXFile(_ sourceURL: URL) -> Bool {
        if sourceURL.pathExtension.lowercased() == "crx" { return true }
        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4) else { return false }
        return String(data: header, encoding: .ascii) == "Cr24"
    }
}

enum UserScriptRuntime {
    static func compatibilityBootstrap(
        bridgeToken: String,
        scriptID: UUID,
        allowsXMLHTTPRequests: Bool
    ) -> String {
        guard allowsXMLHTTPRequests else {
            return "var unsafeWindow = window; var GM = Object.freeze({});"
        }
        return #"""
        var unsafeWindow = window;
        function base64Blob(value, mimeType) {
            var binary = atob(value || '');
            var bytes = new Uint8Array(binary.length);
            for (var index = 0; index < binary.length; index += 1) {
                bytes[index] = binary.charCodeAt(index);
            }
            return new Blob([bytes], { type: mimeType || 'application/octet-stream' });
        }

        function request(details) {
            details = details || {};
            var aborted = false;
            var bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.souloUserScriptXHR;
            if (!bridge || typeof bridge.postMessage !== 'function') {
                var unavailable = new Error('Soulo UserScript network bridge is unavailable');
                if (typeof details.onerror === 'function') details.onerror(unavailable);
                return { abort: function() { aborted = true; } };
            }

            var payload = {
                __souloToken: '\#(bridgeToken.escapedForJS)',
                __souloScriptID: '\#(scriptID.uuidString)',
                url: String(details.url || ''),
                method: String(details.method || 'GET'),
                headers: details.headers || {},
                data: details.data == null ? null : String(details.data),
                timeout: Number(details.timeout || 30_000),
                responseType: String(details.responseType || '')
            };

            if (typeof details.onloadstart === 'function') {
                details.onloadstart({ readyState: 1 });
            }
            bridge.postMessage(payload).then(function(result) {
                if (aborted) return;
                var responseText = result.responseText || '';
                var response = responseText;
                if (payload.responseType === 'blob') {
                    response = base64Blob(result.base64, result.mimeType);
                } else if (payload.responseType === 'arraybuffer') {
                    var binary = atob(result.base64 || '');
                    var bytes = new Uint8Array(binary.length);
                    for (var index = 0; index < binary.length; index += 1) {
                        bytes[index] = binary.charCodeAt(index);
                    }
                    response = bytes.buffer;
                } else if (payload.responseType === 'json') {
                    try { response = JSON.parse(responseText); } catch (_) { response = null; }
                }
                var event = {
                    readyState: 4,
                    status: result.status || 0,
                    statusText: result.statusText || '',
                    finalUrl: result.finalURL || payload.url,
                    responseHeaders: result.responseHeaders || '',
                    responseText: responseText,
                    response: response
                };
                if (typeof details.onreadystatechange === 'function') details.onreadystatechange(event);
                if (typeof details.onload === 'function') details.onload(event);
                if (typeof details.onloadend === 'function') details.onloadend(event);
            }).catch(function(error) {
                if (aborted) return;
                var event = { readyState: 4, status: 0, error: String(error) };
                if (typeof details.onreadystatechange === 'function') details.onreadystatechange(event);
                if (typeof details.onerror === 'function') details.onerror(event);
                if (typeof details.onloadend === 'function') details.onloadend(event);
            });
            return { abort: function() { aborted = true; } };
        }

        var GM_xmlhttpRequest = request;
        var GM = Object.freeze({ xmlHttpRequest: request });
        """#
    }

    static func wrappedSource(for script: UserScriptRecord, bridgeToken: String = "") -> String {
        let includeLiteral = jsonLiteral(
            script.matchPatterns.compactMap(UserScriptURLMatcher.regularExpression)
        )
        let excludeLiteral = jsonLiteral(
            (script.excludePatterns ?? []).compactMap(UserScriptURLMatcher.regularExpression)
        )
        let compatibility = compatibilityBootstrap(
            bridgeToken: bridgeToken,
            scriptID: script.id,
            allowsXMLHTTPRequests: script.allowsXMLHTTPRequests
        )
        let execution = """
        function __souloRunUserScript() {
            try {
                \(compatibility)
                \(script.source)
            } catch (error) {
                console.error('Soulo UserScript \(script.name.escapedForJS):', error);
            }
        }
        """

        let schedule = script.injectionTime == .documentEnd
            ? """
              if (document.readyState === 'loading') {
                  document.addEventListener('DOMContentLoaded', __souloRunUserScript, { once: true });
              } else {
                  __souloRunUserScript();
              }
              """
            : "__souloRunUserScript();"

        return """
        (function() {
            var __souloURL = String(window.location.href || '');
            var __souloIncludes = \(includeLiteral);
            var __souloExcludes = \(excludeLiteral);
            function __souloMatches(expressions) {
                return expressions.some(function(expression) {
                    try { return new RegExp(expression, 'i').test(__souloURL); }
                    catch (_) { return false; }
                });
            }
            if (!__souloMatches(__souloIncludes) || __souloMatches(__souloExcludes)) return;
            \(execution)
            \(schedule)
        })();
        //# sourceURL=soulo-userscript-\(script.id.uuidString).js
        """
    }

    private static func jsonLiteral(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    @MainActor
    static func execute(
        _ script: UserScriptRecord,
        on webView: WKWebView,
        completion: ((Result<Any?, Error>) -> Void)? = nil
    ) {
        webView.evaluateJavaScript(wrappedSource(for: script)) { value, error in
            if let error {
                completion?(.failure(error))
            } else {
                completion?(.success(value))
            }
        }
    }
}

enum UserScriptHTTPBridge {
    static let maximumResponseSize = 20 * 1_024 * 1_024
    private static let allowedMethods = Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
    private static let forbiddenHeaders = Set(["cookie", "host", "content-length", "origin"])

    static func response(
        for body: [String: Any],
        script: UserScriptRecord,
        pageURL: URL?
    ) async throws -> [String: Any] {
        guard let rawURL = body["url"] as? String,
              let url = URL(string: rawURL),
              isAllowedTarget(url, script: script, pageURL: pageURL) else {
            throw URLError(.unsupportedURL)
        }

        let method = (body["method"] as? String ?? "GET").uppercased()
        guard allowedMethods.contains(method) else {
            throw URLError(.unsupportedURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let requestedTimeout = (body["timeout"] as? NSNumber)?.doubleValue ?? 30_000
        request.timeoutInterval = min(max(requestedTimeout / 1_000, 1), 60)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let headers = body["headers"] as? [String: Any] {
            for (name, value) in headers {
                guard !forbiddenHeaders.contains(name.lowercased()) else { continue }
                request.setValue(String(describing: value), forHTTPHeaderField: name)
            }
        }
        if let data = body["data"] as? String, method != "GET", method != "HEAD" {
            request.httpBody = Data(data.utf8)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let redirectDelegate = UserScriptURLSessionDelegate(script: script, pageURL: pageURL)
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseSize else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let responseText = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let responseHeaders = http.allHeaderFields
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\r\n")
        var result: [String: Any] = [
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "finalURL": http.url?.absoluteString ?? rawURL,
            "responseHeaders": responseHeaders,
            "responseText": responseText,
            "mimeType": http.mimeType ?? "application/octet-stream"
        ]
        if ["blob", "arraybuffer"].contains((body["responseType"] as? String)?.lowercased() ?? "") {
            result["base64"] = data.base64EncodedString()
        }
        return result
    }

    static func isAllowedTarget(_ url: URL, script: UserScriptRecord, pageURL: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !isLocalOrPrivateHost(host) else {
            return false
        }
        return UserScriptConnectPolicy.allows(url: url, script: script, pageURL: pageURL)
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        let cleanHost = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let isPrivateIPv6 = cleanHost.contains(":") && (
            cleanHost.hasPrefix("fc")
                || cleanHost.hasPrefix("fd")
                || cleanHost.range(of: #"^fe[89ab]"#, options: .regularExpression) != nil
                || cleanHost.hasPrefix("::ffff:127.")
        )
        if cleanHost == "localhost"
            || cleanHost == "::1"
            || cleanHost.hasSuffix(".local")
            || isPrivateIPv6
            || cleanHost.hasPrefix("127.")
            || cleanHost.hasPrefix("0.")
            || cleanHost.hasPrefix("10.")
            || cleanHost.hasPrefix("192.168.")
            || cleanHost.hasPrefix("169.254.") {
            return true
        }
        let parts = cleanHost.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }
}

private final class UserScriptURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let script: UserScriptRecord
    private let pageURL: URL?

    init(script: UserScriptRecord, pageURL: URL?) {
        self.script = script
        self.pageURL = pageURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              UserScriptHTTPBridge.isAllowedTarget(
                redirectURL,
                script: script,
                pageURL: pageURL
              ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum UserScriptURLMatcher {
    static func matches(url: URL, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            guard let expression = regularExpression(for: pattern) else { return false }
            return url.absoluteString.range(
                of: expression,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    static func isValid(pattern: String) -> Bool {
        guard let expression = regularExpression(for: pattern) else { return false }
        return (try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])) != nil
    }

    static func regularExpression(for rawPattern: String) -> String? {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        if pattern == "<all_urls>" { return #"^https?://"# }

        // @include also accepts regular-expression literals.
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            return String(pattern.dropFirst().dropLast())
        }

        guard let separator = pattern.range(of: "://") else {
            return anchoredWildcardExpression(pattern)
        }

        let schemePattern = String(pattern[..<separator.lowerBound]).lowercased()
        let remainder = String(pattern[separator.upperBound...])
        let hostAndPath = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawHost = hostAndPath.first.map(String.init), !rawHost.isEmpty else { return nil }

        let schemeExpression: String
        switch schemePattern {
        case "*", "http*": schemeExpression = "https?"
        case "http", "https": schemeExpression = NSRegularExpression.escapedPattern(for: schemePattern)
        default: return nil
        }

        let hostExpression: String
        if rawHost == "*" {
            hostExpression = "[^/:]+"
        } else if rawHost.hasPrefix("*.") {
            let base = String(rawHost.dropFirst(2))
            guard !base.isEmpty, !base.contains("*") else { return nil }
            hostExpression = "(?:[^/:]+\\.)?" + NSRegularExpression.escapedPattern(for: base)
        } else {
            guard !rawHost.contains("*") else { return nil }
            hostExpression = NSRegularExpression.escapedPattern(for: rawHost)
        }

        let rawPath = "/" + (hostAndPath.count > 1 ? String(hostAndPath[1]) : "")
        let pathExpression = wildcardFragment(rawPath)
        // Match patterns do not constrain an explicitly supplied web port.
        return "^\(schemeExpression)://\(hostExpression)(?::[0-9]+)?\(pathExpression)$"
    }

    private static func anchoredWildcardExpression(_ pattern: String) -> String {
        "^\(wildcardFragment(pattern))$"
    }

    private static func wildcardFragment(_ value: String) -> String {
        NSRegularExpression.escapedPattern(for: value)
            .replacingOccurrences(of: "\\*", with: ".*")
    }
}

enum UserScriptConnectPolicy {
    static func allows(url: URL, script: UserScriptRecord, pageURL: URL?) -> Bool {
        let declarations = script.connectDomains ?? []
        guard !declarations.isEmpty else { return true }
        guard let host = url.host?.lowercased() else { return false }

        return declarations.contains { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value == "*" { return true }
            if value == "self" {
                return pageURL?.host?.lowercased() == host
            }
            if value.contains("://") {
                return UserScriptURLMatcher.matches(url: url, patterns: [value])
            }
            let domain = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Notification.Name {
    static let browserExtensionsChanged = Notification.Name("soulo.browserExtensionsChanged")
    static let browserExtensionInstallCandidate = Notification.Name("soulo.browserExtensionInstallCandidate")
}

@MainActor
@available(iOS 18.4, *)
final class NativeWebExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    struct Metadata {
        let name: String
        let version: String?
        let permissionCount: Int
        let siteCount: Int
    }

    static let shared = NativeWebExtensionRuntime()

    let controller: WKWebExtensionController
    private let browserWindow = NativeExtensionWindow()
    private var contexts: [UUID: WKWebExtensionContext] = [:]

    private override init() {
        controller = WKWebExtensionController()
        super.init()
        controller.delegate = self
    }

    func apply(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    func register(_ webView: WKWebView) {
        guard !browserWindow.contains(webView) else { return }
        let tab = NativeExtensionTab(webView: webView)
        browserWindow.tabs.append(tab)
        controller.didOpenTab(tab)
    }

    func unregister(_ webView: WKWebView) {
        guard let tab = browserWindow.remove(webView) else { return }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    @discardableResult
    func load(id: UUID, resourceURL: URL) async throws -> Metadata {
        if let current = contexts[id] {
            let extensionObject = current.webExtension
            return metadata(for: extensionObject)
        }

        let extensionObject = try await WKWebExtension(resourceBaseURL: resourceURL)
        guard extensionObject.errors.isEmpty else {
            throw extensionObject.errors.first ?? BrowserExtensionError.invalidExtension
        }

        let context = WKWebExtensionContext(for: extensionObject)
        context.uniqueIdentifier = id.uuidString
        let expiration = Date.distantFuture
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: extensionObject.requestedPermissions.map { ($0, expiration) }
        )
        context.grantedPermissionMatchPatterns = Dictionary(
            uniqueKeysWithValues: extensionObject.requestedPermissionMatchPatterns.map { ($0, expiration) }
        )
        try controller.load(context)
        contexts[id] = context
        return metadata(for: extensionObject)
    }

    func unload(id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [browserWindow]
    }

    private func metadata(for extensionObject: WKWebExtension) -> Metadata {
        Metadata(
            name: extensionObject.displayName?.nonEmpty
                ?? LanguageManager.shared.localizedString("extension_untitled"),
            version: extensionObject.version,
            permissionCount: extensionObject.requestedPermissions.count,
            siteCount: extensionObject.requestedPermissionMatchPatterns.count
        )
    }
}

@MainActor
@available(iOS 18.4, *)
private final class NativeExtensionWindow: NSObject, WKWebExtensionWindow {
    var tabs: [NativeExtensionTab] = []

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabs.last }

    func contains(_ webView: WKWebView) -> Bool {
        tabs.contains { $0.webView === webView }
    }

    func remove(_ webView: WKWebView) -> NativeExtensionTab? {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return nil }
        return tabs.remove(at: index)
    }
}

@MainActor
@available(iOS 18.4, *)
private final class NativeExtensionTab: NSObject, WKWebExtensionTab {
    weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
}
