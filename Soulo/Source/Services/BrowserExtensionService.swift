import Foundation
import Combine
import OSLog
import UniformTypeIdentifiers
import UIKit
import WebKit

private let browserExtensionLogger = Logger(
    subsystem: "com.dkluge.Soulo",
    category: "WebExtensions"
)

enum BrowserExtensionFeatureAvailability {
    // Native WebExtensions require iOS 18.4 or newer. Cross-store packages
    // still need to use WebKit-compatible manifests and background behavior.
    static let standardWebExtensionsEnabled = true
}

enum UserScriptInjectionTime: String, Codable {
    case documentStart
    case documentEnd
}

struct UserScriptMetadata: Equatable {
    var name: String?
    var description: String?
    var author: String?
    var namespace: String?
    var version: String?
    var homepageURL: String?
    var updateURL: String?
    var downloadURL: String?
    var patterns: [String]
    var excludePatterns: [String]
    var grants: [String]
    var connectDomains: [String]
    var requiredURLs: [String]
    var resources: [String: String]
    var injectionTime: UserScriptInjectionTime
}

struct UserScriptInstallPreview: Equatable {
    let name: String
    let source: String
    let sourceURL: URL?
    let metadata: UserScriptMetadata
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
    var scriptDescription: String?
    var author: String?
    var homepageURL: String?
    var updateURL: String?
    var downloadURL: String?
    var requiredURLs: [String]?
    var resources: [String: String]?
    var sourceURL: String?
    /// JSON object wrappers keyed by storage name. Optional keeps old stores decodable.
    var storedValues: [String: String]?
    /// Built-in examples stay available for learning and can be enabled like normal scripts.
    var isBuiltIn: Bool?
    var injectionTime: UserScriptInjectionTime
    var isEnabled: Bool
    var installedAt: Date
    var updatedAt: Date?

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
        scriptDescription: String? = nil,
        author: String? = nil,
        homepageURL: String? = nil,
        updateURL: String? = nil,
        downloadURL: String? = nil,
        requiredURLs: [String] = [],
        resources: [String: String] = [:],
        sourceURL: String? = nil,
        storedValues: [String: String] = [:],
        isBuiltIn: Bool = false,
        injectionTime: UserScriptInjectionTime = .documentEnd,
        isEnabled: Bool = true,
        installedAt: Date = Date(),
        updatedAt: Date? = nil
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
        self.scriptDescription = scriptDescription
        self.author = author
        self.homepageURL = homepageURL
        self.updateURL = updateURL
        self.downloadURL = downloadURL
        self.requiredURLs = requiredURLs
        self.resources = resources
        self.sourceURL = sourceURL
        self.storedValues = storedValues
        self.isBuiltIn = isBuiltIn
        self.injectionTime = injectionTime
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.updatedAt = updatedAt
    }

    var allowsXMLHTTPRequests: Bool {
        let declaredGrants = grants ?? []
        guard !declaredGrants.contains(where: { $0.caseInsensitiveCompare("none") == .orderedSame }) else {
            return false
        }
        // Older and hand-written scripts without @grant keep their existing behavior.
        return declaredGrants.isEmpty || declaredGrants.contains { grant in
            ["GM_xmlhttpRequest", "GM.xmlHttpRequest"].contains {
                grant.caseInsensitiveCompare($0) == .orderedSame
            }
        }
    }

    func hasGrant(_ names: String...) -> Bool {
        let declaredGrants = grants ?? []
        guard !declaredGrants.contains(where: { $0.caseInsensitiveCompare("none") == .orderedSame }) else {
            return false
        }
        // Preserve compatibility for older hand-written records that predate
        // grant parsing while honoring explicit modern permission declarations.
        return declaredGrants.isEmpty || declaredGrants.contains { grant in
            names.contains { grant.caseInsensitiveCompare($0) == .orderedSame }
        }
    }

    var unsupportedGrants: [String] {
        (grants ?? []).filter { !UserScriptRuntime.supportedGrantNames.contains($0.lowercased()) }
    }
}

struct WebExtensionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var version: String?
    var storedResourceName: String
    var requestedPermissionCount: Int
    var requestedSiteCount: Int
    /// WebKit can ignore individual invalid resources or rules while keeping
    /// the rest of an extension usable. Optional keeps older stores decodable.
    var compatibilityWarningCount: Int?
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
    case scriptTooLarge
    case invalidMatchPattern(String)
    case invalidConnectDomain(String)
    case invalidStorageValue
    case invalidExtension
    case incompatiblePersistentBackground

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
        case .scriptTooLarge:
            AppLocalization.string("userscript_too_large")
        case let .invalidMatchPattern(pattern):
            String(
                format: AppLocalization.string("userscript_invalid_match_pattern"),
                locale: Locale.current,
                arguments: [pattern]
            )
        case let .invalidConnectDomain(domain):
            String(
                format: AppLocalization.string("userscript_invalid_connect_domain"),
                locale: Locale.current,
                arguments: [domain]
            )
        case .invalidStorageValue:
            AppLocalization.string("userscript_storage_invalid")
        case .invalidExtension:
            AppLocalization.string("web_extension_invalid")
        case .incompatiblePersistentBackground:
            AppLocalization.string("web_extension_persistent_background_unsupported")
        }
    }
}

@MainActor
final class BrowserExtensionService: ObservableObject {
    static let shared = BrowserExtensionService()
    static let maximumUserScriptSize = 2 * 1_024 * 1_024
    static let maximumStoredValueSize = 256 * 1_024
    static let maximumStoredValuesSize = 1 * 1_024 * 1_024
    @Published private(set) var userScripts: [UserScriptRecord] = []
    @Published private(set) var webExtensions: [WebExtensionRecord] = []

    private let fileManager = FileManager.default

    private init() {
        loadStore()
        installBuiltInExamplesIfNeeded()
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
    func previewUserScript(from fileURL: URL, sourceURL: URL? = nil) throws -> UserScriptInstallPreview {
        let source = try Self.readUserScriptSource(from: fileURL)
        let metadata = Self.parseMetadata(from: source)
        try Self.validate(metadata: metadata)
        return UserScriptInstallPreview(
            name: Self.resolvedUserScriptName(
                metadata: metadata,
                fallbackName: Self.fallbackName(for: fileURL)
            ),
            source: source,
            sourceURL: sourceURL,
            metadata: metadata
        )
    }

    func importUserScript(from fileURL: URL, sourceURL: URL? = nil) throws -> UserScriptRecord {
        let preview = try previewUserScript(from: fileURL, sourceURL: sourceURL)
        return try saveUserScript(
            id: nil,
            fallbackName: preview.name,
            source: preview.source,
            explicitPatterns: nil,
            injectionTime: nil,
            sourceURL: sourceURL
        )
    }

    @discardableResult
    func saveUserScript(
        id: UUID?,
        fallbackName: String,
        source: String,
        explicitPatterns: [String]?,
        injectionTime: UserScriptInjectionTime?,
        explicitName: String? = nil,
        sourceURL: URL? = nil
    ) throws -> UserScriptRecord {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { throw BrowserExtensionError.emptyScript }

        let metadata = Self.parseMetadata(from: source)
        let requestedPatterns = (explicitPatterns ?? metadata.patterns)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedPatterns = Self.deduplicated(requestedPatterns.isEmpty ? ["*://*/*"] : requestedPatterns)
        let normalizedExcludes = metadata.excludePatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let invalid = (normalizedPatterns + normalizedExcludes).first(where: {
            !UserScriptURLMatcher.isValid(pattern: $0)
        }) {
            throw BrowserExtensionError.invalidMatchPattern(invalid)
        }
        try Self.validate(metadata: metadata)

        let resolvedName = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? Self.resolvedUserScriptName(metadata: metadata, fallbackName: fallbackName)
        let normalizedNamespace = metadata.namespace?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let normalizedSourceURL = sourceURL?.absoluteString
        let identityURLs = Set(
            [normalizedSourceURL, metadata.updateURL, metadata.downloadURL]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        )
        let existingRecord = id.flatMap { existingID in userScripts.first { $0.id == existingID } }
            ?? (!identityURLs.isEmpty ? userScripts.first { existing in
                !identityURLs.isDisjoint(with: Set(
                    [existing.sourceURL, existing.updateURL, existing.downloadURL].compactMap { $0 }
                ))
            } : nil)
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
            scriptDescription: metadata.description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            author: metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            homepageURL: metadata.homepageURL,
            updateURL: metadata.updateURL,
            downloadURL: metadata.downloadURL,
            requiredURLs: metadata.requiredURLs,
            resources: metadata.resources,
            sourceURL: normalizedSourceURL ?? existingRecord?.sourceURL,
            storedValues: existingRecord?.storedValues ?? [:],
            isBuiltIn: existingRecord?.isBuiltIn ?? false,
            injectionTime: injectionTime ?? metadata.injectionTime,
            isEnabled: existingRecord?.isEnabled ?? true,
            installedAt: existingRecord?.installedAt ?? Date(),
            updatedAt: Date()
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
        guard userScripts.first(where: { $0.id == id })?.isBuiltIn != true else { return }
        userScripts.removeAll { $0.id == id }
        persistAndNotify()
    }

    func setStoredValue(_ encodedValue: String, forKey key: String, scriptID: UUID) throws {
        try setStoredValues([key: encodedValue], scriptID: scriptID)
    }

    func setStoredValues(_ encodedValues: [String: String], scriptID: UUID) throws {
        guard let index = userScripts.firstIndex(where: { $0.id == scriptID }),
              !encodedValues.isEmpty,
              encodedValues.allSatisfy({ key, encodedValue in
                  guard !key.isEmpty,
                        key.utf8.count <= 256,
                        encodedValue.utf8.count <= Self.maximumStoredValueSize,
                        let data = encodedValue.data(using: .utf8),
                        let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                  else { return false }
                  return wrapper.keys.allSatisfy { $0 == "value" }
              }) else {
            throw BrowserExtensionError.invalidStorageValue
        }
        var values = userScripts[index].storedValues ?? [:]
        values.merge(encodedValues) { _, new in new }
        let totalSize = values.reduce(0) { result, item in
            result + item.key.utf8.count + item.value.utf8.count
        }
        guard totalSize <= Self.maximumStoredValuesSize else {
            throw BrowserExtensionError.invalidStorageValue
        }
        userScripts[index].storedValues = values
        persistAndNotify(reloadPages: false)
    }

    func deleteStoredValue(forKey key: String, scriptID: UUID) {
        deleteStoredValues(forKeys: [key], scriptID: scriptID)
    }

    func deleteStoredValues(forKeys keys: [String], scriptID: UUID) {
        guard let index = userScripts.firstIndex(where: { $0.id == scriptID }) else { return }
        for key in keys {
            userScripts[index].storedValues?.removeValue(forKey: key)
        }
        persistAndNotify(reloadPages: false)
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
        let storedResourceName = WebExtensionPackagePreparer.preparedResourceName

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            let destination = try WebExtensionPackagePreparer.prepare(
                sourceURL: sourceURL,
                in: destinationDirectory
            )
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
                compatibilityWarningCount: metadata.compatibilityWarningCount,
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

    func webExtensionAction(for id: UUID) -> WebExtensionActionPresentation? {
        guard #available(iOS 18.4, *) else { return nil }
        return NativeWebExtensionRuntime.shared.actionPresentation(id: id)
    }

    @discardableResult
    func performWebExtensionAction(_ id: UUID) -> Bool {
        guard #available(iOS 18.4, *) else { return false }
        return NativeWebExtensionRuntime.shared.performAction(id: id)
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
        var migratedStore = false
        for index in webExtensions.indices where webExtensions[index].isEnabled {
            let record = webExtensions[index]
            let originalResourceURL = resourceURL(for: record)
            let resourceURL: URL
            if record.storedResourceName == WebExtensionPackagePreparer.preparedResourceName {
                try? WebExtensionPackagePreparer.installCompatibilityLayer(in: originalResourceURL)
                resourceURL = originalResourceURL
            } else {
                do {
                    resourceURL = try WebExtensionPackagePreparer.prepare(
                        sourceURL: originalResourceURL,
                        in: originalResourceURL.deletingLastPathComponent()
                    )
                    webExtensions[index].storedResourceName = WebExtensionPackagePreparer.preparedResourceName
                    migratedStore = true
                } catch {
                    // Preserve older working packages if a rare archive method
                    // cannot be migrated by the safe extractor.
                    browserExtensionLogger.error(
                        "Could not migrate extension \(record.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    resourceURL = originalResourceURL
                }
            }
            _ = try? await NativeWebExtensionRuntime.shared.load(
                id: record.id,
                resourceURL: resourceURL
            )
        }
        if migratedStore {
            persistAndNotify(reloadPages: false)
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

    private func installBuiltInExamplesIfNeeded() {
        let originalCount = userScripts.count
        userScripts.removeAll { script in
            script.isBuiltIn == true
                && BuiltInUserScripts.retiredNamespaces.contains(script.namespace ?? "")
        }
        var didChange = userScripts.count != originalCount
        for definition in BuiltInUserScripts.all {
            if let index = userScripts.firstIndex(where: {
                $0.namespace?.caseInsensitiveCompare(definition.namespace) == .orderedSame
            }) {
                // A user-authored script may intentionally share a namespace;
                // only bundled records are refreshed from app resources.
                guard userScripts[index].isBuiltIn == true else { continue }
                let refreshed = definition.makeRecord(preserving: userScripts[index])
                if refreshed != userScripts[index] {
                    userScripts[index] = refreshed
                    didChange = true
                }
            } else {
                userScripts.append(definition.makeRecord())
                didChange = true
            }
        }
        guard didChange else { return }
        persistAndNotify(reloadPages: false)
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

    static func parseMetadata(from source: String) -> UserScriptMetadata {
        var name: String?
        var description: String?
        var author: String?
        var patterns: [String] = []
        var excludePatterns: [String] = []
        var grants: [String] = []
        var connectDomains: [String] = []
        var requiredURLs: [String] = []
        var resources: [String: String] = [:]
        var namespace: String?
        var version: String?
        var homepageURL: String?
        var updateURL: String?
        var downloadURL: String?
        var injectionTime: UserScriptInjectionTime = .documentEnd
        var isInsideMetadata = false
        let trimSet = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}"))

        for line in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(512) {
            let value = line.trimmingCharacters(in: trimSet)
            if value.range(of: #"^//\s*==UserScript==\s*$"#, options: .regularExpression) != nil {
                isInsideMetadata = true
                continue
            }
            if value.range(of: #"^//\s*==/UserScript==\s*$"#, options: .regularExpression) != nil {
                break
            }
            guard isInsideMetadata else { continue }

            if value.range(of: #"^//\s*@name\s+(.+)$"#, options: .regularExpression) != nil {
                name = value.replacingOccurrences(
                    of: #"^//\s*@name\s+"#,
                    with: "",
                    options: .regularExpression
                )
            } else if value.range(of: #"^//\s*@description\s+(.+)$"#, options: .regularExpression) != nil {
                description = metadataValue(value, keyPattern: "description")
            } else if value.range(of: #"^//\s*@author\s+(.+)$"#, options: .regularExpression) != nil {
                author = metadataValue(value, keyPattern: "author")
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
            } else if value.range(of: #"^//\s*@(homepage|homepageURL|website|source)\s+(.+)$"#, options: .regularExpression) != nil {
                homepageURL = metadataValue(value, keyPattern: "(homepage|homepageURL|website|source)")
            } else if value.range(of: #"^//\s*@updateURL\s+(.+)$"#, options: .regularExpression) != nil {
                updateURL = metadataValue(value, keyPattern: "updateURL")
            } else if value.range(of: #"^//\s*@downloadURL\s+(.+)$"#, options: .regularExpression) != nil {
                downloadURL = metadataValue(value, keyPattern: "downloadURL")
            } else if value.range(of: #"^//\s*@require\s+(.+)$"#, options: .regularExpression) != nil {
                requiredURLs.append(metadataValue(value, keyPattern: "require"))
            } else if value.range(of: #"^//\s*@resource\s+\S+\s+\S+"#, options: .regularExpression) != nil {
                let resource = metadataValue(value, keyPattern: "resource")
                    .split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
                if resource.count == 2 {
                    resources[String(resource[0])] = String(resource[1])
                }
            } else if value.range(of: #"^//\s*@run-at\s+document-start"#, options: .regularExpression) != nil {
                injectionTime = .documentStart
            }
        }
        return UserScriptMetadata(
            name: name,
            description: description,
            author: author,
            namespace: namespace,
            version: version,
            homepageURL: homepageURL,
            updateURL: updateURL,
            downloadURL: downloadURL,
            patterns: deduplicated(patterns),
            excludePatterns: deduplicated(excludePatterns),
            grants: deduplicated(grants),
            connectDomains: deduplicated(connectDomains),
            requiredURLs: deduplicated(requiredURLs),
            resources: resources,
            injectionTime: injectionTime
        )
    }

    private static func metadataValue(_ line: String, keyPattern: String) -> String {
        line.replacingOccurrences(
            of: "^//\\s*@\(keyPattern)\\s+",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readUserScriptSource(from fileURL: URL) throws -> String {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            throw BrowserExtensionError.unreadableScript
        }
        guard fileSize.intValue <= maximumUserScriptSize else {
            throw BrowserExtensionError.scriptTooLarge
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= maximumUserScriptSize,
              let source = String(data: data, encoding: .utf8) else {
            throw BrowserExtensionError.unreadableScript
        }
        return source
    }

    private static func fallbackName(for fileURL: URL) -> String {
        let filename = fileURL.lastPathComponent
        if filename.lowercased().hasSuffix(".user.js") {
            return String(filename.dropLast(".user.js".count))
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private static func resolvedUserScriptName(
        metadata: UserScriptMetadata,
        fallbackName: String
    ) -> String {
        metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? LanguageManager.shared.localizedString("userscript_untitled")
    }

    private static func validate(metadata: UserScriptMetadata) throws {
        if let invalid = (metadata.patterns + metadata.excludePatterns).first(where: {
            !UserScriptURLMatcher.isValid(pattern: $0)
        }) {
            throw BrowserExtensionError.invalidMatchPattern(invalid)
        }
        if let invalid = metadata.connectDomains.first(where: {
            !UserScriptConnectPolicy.isValid(declaration: $0)
        }) {
            throw BrowserExtensionError.invalidConnectDomain(invalid)
        }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

}

enum UserScriptRuntime {
    static let supportedGrantNames: Set<String> = [
        "none", "unsafewindow", "gm_info", "gm.info",
        "gm_xmlhttprequest", "gm.xmlhttprequest",
        "gm_addstyle", "gm.addstyle", "gm_addelement", "gm.addelement",
        "gm_log", "gm.log",
        "gm_getvalue", "gm.getvalue", "gm_setvalue", "gm.setvalue",
        "gm_deletevalue", "gm.deletevalue", "gm_listvalues", "gm.listvalues",
        "gm_getvalues", "gm.getvalues", "gm_setvalues", "gm.setvalues",
        "gm_deletevalues", "gm.deletevalues",
        "gm_addvaluechangelistener", "gm.addvaluechangelistener",
        "gm_removevaluechangelistener", "gm.removevaluechangelistener",
        "gm_setclipboard", "gm.setclipboard",
        "gm_registermenucommand", "gm.registermenucommand",
        "gm_unregistermenucommand", "gm.unregistermenucommand",
        "gm_notification", "gm.notification",
        "gm_openintab", "gm.openintab",
        "gm_closetab", "gm.closetab", "gm_focustab", "gm.focustab",
        "gm_download", "gm.download",
        "gm_getresourcetext", "gm.getresourcetext",
        "gm_getresourceurl", "gm.getresourceurl",
        "gm_gettab", "gm.gettab", "gm_savetab", "gm.savetab",
        "gm_gettabs", "gm.gettabs", "gm_cookie", "gm.cookie",
        "window.onurlchange"
    ]

    static func compatibilityBootstrap(
        bridgeToken: String,
        script: UserScriptRecord
    ) -> String {
        let allowsUnsafeWindow = script.hasGrant("unsafeWindow")
        let allowsXHR = script.allowsXMLHTTPRequests
        let allowsAddStyle = script.hasGrant("GM_addStyle", "GM.addStyle")
        let allowsAddElement = script.hasGrant("GM_addElement", "GM.addElement")
        let allowsLog = script.hasGrant("GM_log", "GM.log")
        let allowsGetValue = script.hasGrant("GM_getValue", "GM.getValue")
        let allowsSetValue = script.hasGrant("GM_setValue", "GM.setValue")
        let allowsDeleteValue = script.hasGrant("GM_deleteValue", "GM.deleteValue")
        let allowsListValues = script.hasGrant("GM_listValues", "GM.listValues")
        let allowsGetValues = script.hasGrant("GM_getValues", "GM.getValues")
        let allowsSetValues = script.hasGrant("GM_setValues", "GM.setValues")
        let allowsDeleteValues = script.hasGrant("GM_deleteValues", "GM.deleteValues")
        let allowsAddValueListener = script.hasGrant(
            "GM_addValueChangeListener", "GM.addValueChangeListener"
        )
        let allowsRemoveValueListener = script.hasGrant(
            "GM_removeValueChangeListener", "GM.removeValueChangeListener"
        )
        let allowsClipboard = script.hasGrant("GM_setClipboard", "GM.setClipboard")
        let allowsRegisterMenu = script.hasGrant(
            "GM_registerMenuCommand", "GM.registerMenuCommand"
        )
        let allowsUnregisterMenu = script.hasGrant(
            "GM_unregisterMenuCommand", "GM.unregisterMenuCommand"
        )
        let allowsNotification = script.hasGrant("GM_notification", "GM.notification")
        let allowsOpenInTab = script.hasGrant("GM_openInTab", "GM.openInTab")
        let allowsCloseTab = script.hasGrant("GM_closeTab", "GM.closeTab")
        let allowsFocusTab = script.hasGrant("GM_focusTab", "GM.focusTab")
        let allowsDownload = script.hasGrant("GM_download", "GM.download")
        let allowsGetResourceText = script.hasGrant(
            "GM_getResourceText", "GM.getResourceText"
        )
        let allowsGetResourceURL = script.hasGrant(
            "GM_getResourceURL", "GM.getResourceUrl", "GM.getResourceURL"
        )
        let allowsGetTab = script.hasGrant("GM_getTab", "GM.getTab")
        let allowsSaveTab = script.hasGrant("GM_saveTab", "GM.saveTab")
        let allowsGetTabs = script.hasGrant("GM_getTabs", "GM.getTabs")
        let allowsCookie = script.hasGrant("GM_cookie", "GM.cookie")
        let allowsURLChange = script.hasGrant("window.onurlchange")
        let storageLiteral = storedValuesLiteral(script.storedValues ?? [:])
        let resourcesLiteral = dictionaryLiteral(script.resources ?? [:])
        let infoLiteral = userScriptInfoLiteral(script)

        return #"""
        var __souloStorage = \#(storageLiteral);
        var __souloResources = \#(resourcesLiteral);
        var __souloGM = {};
        var GM_info = \#(infoLiteral);
        __souloGM.info = GM_info;

        function __souloBridge(action, details) {
            var bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.souloUserScriptAPI;
            if (!bridge || typeof bridge.postMessage !== 'function') {
                return Promise.reject(new Error('Soulo UserScript bridge is unavailable'));
            }
            var payload = Object.assign({
                __souloToken: '\#(bridgeToken.escapedForJS)',
                __souloScriptID: '\#(script.id.uuidString)',
                action: action
            }, details || {});
            return bridge.postMessage(payload);
        }

        function __souloStoredValue(key, fallback) {
            key = String(key);
            if (!Object.prototype.hasOwnProperty.call(__souloStorage, key)) return fallback;
            return __souloStorage[key].value;
        }

        var __souloValueListeners = Object.create(null);
        var __souloNextValueListenerID = 1;
        function __souloNotifyValueListeners(key, oldValue, newValue, remote) {
            Object.keys(__souloValueListeners).forEach(function(id) {
                var item = __souloValueListeners[id];
                if (item.key !== key) return;
                try { item.callback(key, oldValue, newValue, Boolean(remote)); }
                catch (error) { console.error(error); }
            });
        }
        function __souloEncodeValue(value) {
            var encoded = JSON.stringify({ value: value });
            if (typeof encoded !== 'string') throw new TypeError('Value is not JSON serializable');
            return encoded;
        }
        function __souloSetValue(key, value) {
            key = String(key);
            var oldValue = __souloStoredValue(key, undefined);
            var encoded = __souloEncodeValue(value);
            __souloStorage[key] = { value: value };
            __souloNotifyValueListeners(key, oldValue, value, false);
            return __souloBridge('setValue', { key: key, value: encoded });
        }
        function __souloDeleteValue(key) {
            key = String(key);
            var oldValue = __souloStoredValue(key, undefined);
            var existed = Object.prototype.hasOwnProperty.call(__souloStorage, key);
            delete __souloStorage[key];
            if (existed) __souloNotifyValueListeners(key, oldValue, undefined, false);
            return __souloBridge('deleteValue', { key: key });
        }
        function __souloGetValues(keysOrDefaults) {
            var result = {};
            if (Array.isArray(keysOrDefaults)) {
                keysOrDefaults.forEach(function(key) {
                    key = String(key);
                    if (Object.prototype.hasOwnProperty.call(__souloStorage, key)) {
                        result[key] = __souloStorage[key].value;
                    }
                });
                return result;
            }
            var defaults = keysOrDefaults && typeof keysOrDefaults === 'object'
                ? keysOrDefaults : {};
            Object.keys(defaults).forEach(function(key) {
                result[key] = __souloStoredValue(key, defaults[key]);
            });
            if (!keysOrDefaults) {
                Object.keys(__souloStorage).forEach(function(key) {
                    result[key] = __souloStorage[key].value;
                });
            }
            return result;
        }
        function __souloSetValues(values) {
            values = values && typeof values === 'object' ? values : {};
            var encodedValues = {};
            Object.keys(values).forEach(function(key) {
                encodedValues[key] = __souloEncodeValue(values[key]);
            });
            Object.keys(values).forEach(function(key) {
                var oldValue = __souloStoredValue(key, undefined);
                __souloStorage[key] = { value: values[key] };
                __souloNotifyValueListeners(key, oldValue, values[key], false);
            });
            if (!Object.keys(encodedValues).length) return Promise.resolve(true);
            return __souloBridge('setValues', { values: encodedValues });
        }
        function __souloDeleteValues(keys) {
            keys = Array.isArray(keys) ? keys.map(String) : [];
            keys.forEach(function(key) {
                var oldValue = __souloStoredValue(key, undefined);
                var existed = Object.prototype.hasOwnProperty.call(__souloStorage, key);
                delete __souloStorage[key];
                if (existed) __souloNotifyValueListeners(key, oldValue, undefined, false);
            });
            if (!keys.length) return Promise.resolve(true);
            return __souloBridge('deleteValues', { keys: keys });
        }
        function __souloAddValueChangeListener(key, callback) {
            if (typeof callback !== 'function') throw new TypeError('callback must be a function');
            var id = __souloNextValueListenerID++;
            __souloValueListeners[id] = { key: String(key), callback: callback };
            return id;
        }
        function __souloRemoveValueChangeListener(id) {
            var existed = Object.prototype.hasOwnProperty.call(__souloValueListeners, id);
            delete __souloValueListeners[id];
            return existed;
        }
        function __souloAddElement(parent, tagName, attributes) {
            if (typeof parent === 'string') {
                attributes = tagName;
                tagName = parent;
                parent = document.head || document.body || document.documentElement;
            }
            parent = parent || document.head || document.body || document.documentElement;
            var element = document.createElement(String(tagName));
            Object.keys(attributes || {}).forEach(function(name) {
                var value = attributes[name];
                if (name === 'textContent' || name === 'innerHTML') element[name] = String(value);
                else if (name.slice(0, 2) === 'on' && typeof value === 'function') element[name] = value;
                else if (value === true) element.setAttribute(name, '');
                else if (value !== false && value != null) element.setAttribute(name, String(value));
            });
            if (!parent) throw new Error('No parent is available for GM_addElement');
            parent.appendChild(element);
            return element;
        }

        \#(allowsUnsafeWindow ? "var unsafeWindow = window;" : "")
        \#(allowsGetValue ? "var GM_getValue = function(key, fallback) { return __souloStoredValue(key, fallback); }; __souloGM.getValue = function(key, fallback) { return Promise.resolve(__souloStoredValue(key, fallback)); };" : "")
        \#(allowsSetValue ? "var GM_setValue = function(key, value) { __souloSetValue(key, value).catch(console.error); }; __souloGM.setValue = __souloSetValue;" : "")
        \#(allowsDeleteValue ? "var GM_deleteValue = function(key) { __souloDeleteValue(key).catch(console.error); }; __souloGM.deleteValue = __souloDeleteValue;" : "")
        \#(allowsListValues ? "var GM_listValues = function() { return Object.keys(__souloStorage); }; __souloGM.listValues = function() { return Promise.resolve(GM_listValues()); };" : "")
        \#(allowsGetValues ? "var GM_getValues = __souloGetValues; __souloGM.getValues = function(keysOrDefaults) { return Promise.resolve(__souloGetValues(keysOrDefaults)); };" : "")
        \#(allowsSetValues ? "var GM_setValues = function(values) { __souloSetValues(values).catch(console.error); }; __souloGM.setValues = __souloSetValues;" : "")
        \#(allowsDeleteValues ? "var GM_deleteValues = function(keys) { __souloDeleteValues(keys).catch(console.error); }; __souloGM.deleteValues = __souloDeleteValues;" : "")
        \#(allowsAddValueListener ? "var GM_addValueChangeListener = __souloAddValueChangeListener; __souloGM.addValueChangeListener = function(key, callback) { return Promise.resolve(__souloAddValueChangeListener(key, callback)); };" : "")
        \#(allowsRemoveValueListener ? "var GM_removeValueChangeListener = __souloRemoveValueChangeListener; __souloGM.removeValueChangeListener = function(id) { return Promise.resolve(__souloRemoveValueChangeListener(id)); };" : "")
        \#(allowsAddStyle ? "var GM_addStyle = function(css) { var style = document.createElement('style'); style.textContent = String(css); var attach = function() { var parent = document.head || document.documentElement; if (parent && !style.isConnected) parent.appendChild(style); }; attach(); if (!style.isConnected) document.addEventListener('DOMContentLoaded', attach, { once: true }); return style; }; __souloGM.addStyle = function(css) { return Promise.resolve(GM_addStyle(css)); };" : "")
        \#(allowsAddElement ? "var GM_addElement = __souloAddElement; __souloGM.addElement = function(parent, tagName, attributes) { return Promise.resolve(__souloAddElement(parent, tagName, attributes)); };" : "")
        \#(allowsLog ? "var GM_log = function() { console.log.apply(console, arguments); }; __souloGM.log = GM_log;" : "")
        \#(allowsClipboard ? "var GM_setClipboard = function(value) { __souloBridge('setClipboard', { value: String(value) }).catch(console.error); }; __souloGM.setClipboard = function(value) { return __souloBridge('setClipboard', { value: String(value) }); };" : "")

        function __souloNotification(details, onDone) {
            if (typeof details === 'string') details = { text: details };
            details = details || {};
            return new Promise(function(resolve) {
                var host = document.createElement('div');
                host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;right:max(16px,env(safe-area-inset-right));top:max(16px,env(safe-area-inset-top));max-width:min(360px,calc(100vw - 32px));';
                var root = host.attachShadow ? host.attachShadow({ mode: 'closed' }) : host;
                var card = document.createElement('button');
                card.type = 'button';
                card.style.cssText = 'all:initial;box-sizing:border-box;display:block;width:100%;padding:14px 16px;border-radius:16px;background:rgba(28,28,30,.94);color:white;box-shadow:0 12px 36px rgba(0,0,0,.28);font:14px -apple-system,BlinkMacSystemFont,sans-serif;cursor:pointer;backdrop-filter:blur(20px);';
                var title = details.title || GM_info.script.name || 'UserScript';
                card.innerHTML = '<strong style="display:block;font-size:15px;margin-bottom:4px"></strong><span style="display:block;line-height:1.4;opacity:.84"></span>';
                card.querySelector('strong').textContent = String(title);
                card.querySelector('span').textContent = String(details.text || details.message || '');
                root.appendChild(card);
                function finish(clicked) {
                    if (!host.isConnected) return;
                    host.remove();
                    if (clicked && typeof details.onclick === 'function') details.onclick();
                    if (clicked && typeof details.onClick === 'function') details.onClick();
                    if (typeof details.ondone === 'function') details.ondone();
                    if (typeof onDone === 'function') onDone();
                    resolve(clicked);
                }
                card.addEventListener('click', function() { finish(true); });
                (document.body || document.documentElement).appendChild(host);
                var timeout = Number(details.timeout);
                setTimeout(function() { finish(false); }, Number.isFinite(timeout) && timeout > 0 ? timeout : 5000);
            });
        }

        var __souloGlobalMenuCallbacks = window.__souloUserScriptMenuCallbacks;
        if (!__souloGlobalMenuCallbacks) {
            __souloGlobalMenuCallbacks = Object.create(null);
            Object.defineProperty(window, '__souloUserScriptMenuCallbacks', {
                value: __souloGlobalMenuCallbacks, configurable: true
            });
        }
        window.__souloDispatchUserScriptMenuCommand = function(id) {
            var callback = __souloGlobalMenuCallbacks[String(id)];
            if (typeof callback !== 'function') return false;
            try { callback(); return true; }
            catch (error) { console.error(error); return false; }
        };
        function __souloRegisterMenuCommand(caption, commandFunc) {
            if (typeof commandFunc !== 'function') throw new TypeError('commandFunc must be a function');
            var id = '\#(script.id.uuidString)-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
            __souloGlobalMenuCallbacks[id] = commandFunc;
            __souloBridge('registerMenuCommand', { id: id, title: String(caption) }).catch(function(error) {
                delete __souloGlobalMenuCallbacks[id];
                console.error(error);
            });
            return id;
        }
        function __souloUnregisterMenuCommand(id) {
            id = String(id);
            delete __souloGlobalMenuCallbacks[id];
            return __souloBridge('unregisterMenuCommand', { id: id });
        }
        function __souloOpenInTab(url, options) {
            options = typeof options === 'object' && options ? options : { active: options !== true };
            var absoluteURL = new URL(String(url), location.href).href;
            var id = '\#(script.id.uuidString)-tab-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
            var closed = false;
            var handle = {
                close: function() {
                    if (closed) return;
                    closed = true;
                    handle.closed = true;
                    __souloBridge('closeTab', { id: id }).catch(console.error);
                    if (typeof handle.onclose === 'function') handle.onclose();
                },
                onclose: null,
                closed: false
            };
            __souloBridge('openInTab', {
                id: id, url: absoluteURL, active: options.active !== false
            }).catch(console.error);
            return handle;
        }
        function __souloDownload(details, name) {
            if (typeof details === 'string') details = { url: details, name: name };
            details = details || {};
            var aborted = false;
            var promise = __souloBridge('download', {
                url: new URL(String(details.url || ''), location.href).href,
                name: details.name == null ? '' : String(details.name)
            }).then(function(result) {
                if (aborted) return result;
                if (typeof details.onload === 'function') details.onload(result);
                return result;
            }).catch(function(error) {
                if (!aborted && typeof details.onerror === 'function') details.onerror(error);
                throw error;
            });
            return { abort: function() { aborted = true; }, promise: promise };
        }
        function __souloGetResource(name) {
            name = String(name);
            if (!Object.prototype.hasOwnProperty.call(__souloResources, name)) {
                return Promise.reject(new Error('Unknown @resource: ' + name));
            }
            return __souloBridge('getResource', { name: name });
        }
        function __souloGetTab(callback) {
            return __souloBridge('getTab').then(function(tab) {
                if (typeof callback === 'function') callback(tab || {});
                return tab || {};
            });
        }
        function __souloSaveTab(tab) {
            var encoded = JSON.stringify(tab || {});
            if (typeof encoded !== 'string') throw new TypeError('Tab data is not JSON serializable');
            return __souloBridge('saveTab', { value: encoded });
        }
        function __souloGetTabs(callback) {
            return __souloBridge('getTabs').then(function(tabs) {
                tabs = tabs || {};
                if (typeof callback === 'function') callback(tabs);
                return tabs;
            });
        }
        var __souloCookieAPI = {
            list: function(details, callback) {
                var promise = __souloBridge('cookieList', { details: details || {} });
                if (typeof callback === 'function') promise.then(callback, function(error) { callback([], error); });
                return promise;
            },
            set: function(details, callback) {
                var promise = __souloBridge('cookieSet', { details: details || {} });
                if (typeof callback === 'function') promise.then(function() { callback(); }, callback);
                return promise;
            },
            delete: function(details, callback) {
                var promise = __souloBridge('cookieDelete', { details: details || {} });
                if (typeof callback === 'function') promise.then(function() { callback(); }, callback);
                return promise;
            }
        };

        \#(allowsRegisterMenu ? "var GM_registerMenuCommand = __souloRegisterMenuCommand; __souloGM.registerMenuCommand = function(caption, commandFunc) { return Promise.resolve(__souloRegisterMenuCommand(caption, commandFunc)); };" : "")
        \#(allowsUnregisterMenu ? "var GM_unregisterMenuCommand = function(id) { __souloUnregisterMenuCommand(id).catch(console.error); }; __souloGM.unregisterMenuCommand = __souloUnregisterMenuCommand;" : "")
        \#(allowsNotification ? "var GM_notification = function(details, onDone) { __souloNotification(details, onDone).catch(console.error); }; __souloGM.notification = __souloNotification;" : "")
        \#(allowsOpenInTab ? "var GM_openInTab = __souloOpenInTab; __souloGM.openInTab = function(url, options) { return Promise.resolve(__souloOpenInTab(url, options)); };" : "")
        \#(allowsCloseTab ? "var GM_closeTab = function() { __souloBridge('closeCurrentTab').catch(console.error); }; __souloGM.closeTab = function() { return __souloBridge('closeCurrentTab'); };" : "")
        \#(allowsFocusTab ? "var GM_focusTab = function() { __souloBridge('focusCurrentTab').catch(console.error); }; __souloGM.focusTab = function() { return __souloBridge('focusCurrentTab'); };" : "")
        \#(allowsDownload ? "var GM_download = __souloDownload; __souloGM.download = function(details, name) { return __souloDownload(details, name).promise; };" : "")
        \#(allowsGetResourceText ? "var GM_getResourceText = function(name) { return __souloGetResource(name).then(function(result) { return result.responseText || ''; }); }; __souloGM.getResourceText = GM_getResourceText;" : "")
        \#(allowsGetResourceURL ? "var GM_getResourceURL = function(name) { return __souloGetResource(name).then(function(result) { return 'data:' + (result.mimeType || 'application/octet-stream') + ';base64,' + (result.base64 || ''); }); }; __souloGM.getResourceUrl = GM_getResourceURL; __souloGM.getResourceURL = GM_getResourceURL;" : "")
        \#(allowsGetTab ? "var GM_getTab = function(callback) { __souloGetTab(callback).catch(console.error); }; __souloGM.getTab = __souloGetTab;" : "")
        \#(allowsSaveTab ? "var GM_saveTab = function(tab) { __souloSaveTab(tab).catch(console.error); }; __souloGM.saveTab = __souloSaveTab;" : "")
        \#(allowsGetTabs ? "var GM_getTabs = function(callback) { __souloGetTabs(callback).catch(console.error); }; __souloGM.getTabs = __souloGetTabs;" : "")
        \#(allowsCookie ? "var GM_cookie = __souloCookieAPI; __souloGM.cookie = __souloCookieAPI;" : "")
        \#(allowsURLChange ? "if (!window.__souloURLChangeInstalled) { window.__souloURLChangeInstalled = true; (function() { var lastURL = location.href; function emit() { var nextURL = location.href; if (nextURL === lastURL) return; lastURL = nextURL; window.dispatchEvent(new CustomEvent('urlchange', { detail: { url: nextURL } })); if (typeof window.onurlchange === 'function') window.onurlchange({ url: nextURL }); } ['pushState', 'replaceState'].forEach(function(name) { var original = history[name]; history[name] = function() { var result = original.apply(this, arguments); emit(); return result; }; }); addEventListener('popstate', emit); addEventListener('hashchange', emit); })(); }" : "")

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
                __souloScriptID: '\#(script.id.uuidString)',
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

        \#(allowsXHR ? "var GM_xmlhttpRequest = request; __souloGM.xmlHttpRequest = request;" : "")
        var GM = Object.freeze(__souloGM);
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
            script: script
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

    private static func dictionaryLiteral(_ values: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    private static func storedValuesLiteral(_ values: [String: String]) -> String {
        let object = values.reduce(into: [String: Any]()) { result, item in
            guard let data = item.value.data(using: .utf8),
                  let wrapper = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(wrapper) else { return }
            result[item.key] = wrapper
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return value
    }

    private static func userScriptInfoLiteral(_ script: UserScriptRecord) -> String {
        let runAt = script.injectionTime == .documentStart
            ? "document-start" : "document-end"
        let scriptInfo: [String: Any] = [
            "name": script.name,
            "namespace": script.namespace ?? "",
            "version": script.version ?? "",
            "description": script.scriptDescription ?? "",
            "author": script.author ?? "",
            "matches": script.matchPatterns,
            "excludes": script.excludePatterns ?? [],
            "grant": script.grants ?? [],
            "connects": script.connectDomains ?? [],
            "resources": script.resources ?? [:],
            "require": script.requiredURLs ?? [],
            "runAt": runAt
        ]
        let info: [String: Any] = [
            "scriptHandler": "Soulo",
            "version": AppConstants.appVersion,
            "isIncognito": false,
            "script": scriptInfo
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let value = String(data: data, encoding: .utf8) else {
            return "{}"
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
              let url = URL(string: rawURL, relativeTo: pageURL)?.absoluteURL,
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
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(maximumResponseSize)
                || response.expectedContentLength == NSURLSessionTransferSizeUnknown else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseSize else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
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
    static func isValid(declaration rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if ["*", "self"].contains(value) { return true }
        if value.contains("://") {
            return UserScriptURLMatcher.isValid(pattern: value)
        }
        let domain = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
        guard !domain.isEmpty,
              !domain.contains("/"),
              !domain.contains(" "),
              !domain.hasPrefix("."),
              !domain.hasSuffix(".") else {
            return false
        }
        return domain == "localhost"
            || domain.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
            || URL(string: "http://[\(domain)]")?.host != nil
    }

    static func allows(url: URL, script: UserScriptRecord, pageURL: URL?) -> Bool {
        let declarations = script.connectDomains ?? []
        guard let host = url.host?.lowercased() else { return false }

        // With no @connect declaration, constrain privileged requests to the
        // page's own host. Cross-site access requires an explicit domain or *.
        guard !declarations.isEmpty else {
            return pageURL?.host?.lowercased() == host
        }

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
    static let browserExtensionActionsChanged = Notification.Name("soulo.browserExtensionActionsChanged")
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
        let compatibilityWarningCount: Int
    }

    struct HostInterfaceCoverage: Equatable {
        let missingControllerSelectors: [String]
        let missingWindowSelectors: [String]
        let missingTabSelectors: [String]

        var isComplete: Bool {
            missingControllerSelectors.isEmpty
                && missingWindowSelectors.isEmpty
                && missingTabSelectors.isEmpty
        }
    }

    static let shared = NativeWebExtensionRuntime()

    let controller: WKWebExtensionController
    private let browserWindow = NativeExtensionWindow()
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var contextResourceURLs: [ObjectIdentifier: URL] = [:]
    private weak var tabManager: TabManager?
    private var tabObservers: Set<AnyCancellable> = []
    private var retainedMessagePorts: [ObjectIdentifier: WKWebExtension.MessagePort] = [:]
    private let compatibilityHost = WebExtensionCompatibilityHost()

    private override init() {
        controller = WKWebExtensionController()
        super.init()
        controller.delegate = self
        browserWindow.runtime = self
    }

    func apply(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    /// WebKit isolates every extension origin. An internal extension URL must
    /// be loaded with the owning context's configuration; a normal browser
    /// configuration (even one using the same controller) is rejected with
    /// NSURLErrorResourceUnavailable.
    func webViewConfiguration(for url: URL?) -> WKWebViewConfiguration? {
        guard url?.scheme?.lowercased() == "webkit-extension",
              let url,
              let context = controller.extensionContext(for: url) else { return nil }
        return context.webViewConfiguration
    }

    func hostInterfaceCoverage() -> HostInterfaceCoverage {
        let probeTab = NativeExtensionTab(
            browserTabID: nil,
            webView: nil,
            window: browserWindow,
            runtime: self
        )
        return HostInterfaceCoverage(
            missingControllerSelectors: Self.controllerHostSelectors.filter {
                !responds(to: NSSelectorFromString($0))
            },
            missingWindowSelectors: Self.windowHostSelectors.filter {
                !browserWindow.responds(to: NSSelectorFromString($0))
            },
            missingTabSelectors: Self.tabHostSelectors.filter {
                !probeTab.responds(to: NSSelectorFromString($0))
            }
        )
    }

    private static let controllerHostSelectors = [
        "webExtensionController:openWindowsForExtensionContext:",
        "webExtensionController:focusedWindowForExtensionContext:",
        "webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:",
        "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:",
        "webExtensionController:openOptionsPageForExtensionContext:completionHandler:",
        "webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:",
        "webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:",
        "webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:",
        "webExtensionController:didUpdateAction:forExtensionContext:",
        "webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:",
        "webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:",
        "webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:"
    ]

    private static let windowHostSelectors = [
        "tabsForWebExtensionContext:",
        "activeTabForWebExtensionContext:",
        "windowTypeForWebExtensionContext:",
        "windowStateForWebExtensionContext:",
        "setWindowState:forWebExtensionContext:completionHandler:",
        "isPrivateForWebExtensionContext:",
        "frameForWebExtensionContext:",
        "setFrame:forWebExtensionContext:completionHandler:",
        "focusForWebExtensionContext:completionHandler:",
        "closeForWebExtensionContext:completionHandler:"
    ]

    private static let tabHostSelectors = [
        "windowForWebExtensionContext:",
        "indexInWindowForWebExtensionContext:",
        "parentTabForWebExtensionContext:",
        "setParentTab:forWebExtensionContext:completionHandler:",
        "webViewForWebExtensionContext:",
        "titleForWebExtensionContext:",
        "isPinnedForWebExtensionContext:",
        "setPinned:forWebExtensionContext:completionHandler:",
        "isReaderModeAvailableForWebExtensionContext:",
        "isReaderModeActiveForWebExtensionContext:",
        "setReaderModeActive:forWebExtensionContext:completionHandler:",
        "isPlayingAudioForWebExtensionContext:",
        "isMutedForWebExtensionContext:",
        "setMuted:forWebExtensionContext:completionHandler:",
        "sizeForWebExtensionContext:",
        "zoomFactorForWebExtensionContext:",
        "setZoomFactor:forWebExtensionContext:completionHandler:",
        "urlForWebExtensionContext:",
        "pendingURLForWebExtensionContext:",
        "isLoadingCompleteForWebExtensionContext:",
        "detectWebpageLocaleForWebExtensionContext:completionHandler:",
        "takeSnapshotUsingConfiguration:forWebExtensionContext:completionHandler:",
        "loadURL:forWebExtensionContext:completionHandler:",
        "reloadFromOrigin:forWebExtensionContext:completionHandler:",
        "goBackForWebExtensionContext:completionHandler:",
        "goForwardForWebExtensionContext:completionHandler:",
        "activateForWebExtensionContext:completionHandler:",
        "isSelectedForWebExtensionContext:",
        "setSelected:forWebExtensionContext:completionHandler:",
        "duplicateUsingConfiguration:forWebExtensionContext:completionHandler:",
        "closeForWebExtensionContext:completionHandler:",
        "shouldGrantPermissionsOnUserGestureForWebExtensionContext:",
        "shouldBypassPermissionsForWebExtensionContext:"
    ]

    func attach(tabManager: TabManager) {
        guard self.tabManager !== tabManager else {
            synchronizeBrowserTabs()
            return
        }
        self.tabManager = tabManager
        tabObservers.removeAll()
        tabManager.$tabs
            .sink { [weak self] _ in
                // @Published sends in willSet. Synchronizing immediately would
                // still observe the old tab array and can leave an extension
                // page detached (or make a subsequent close re-enter WebKit).
                DispatchQueue.main.async { [weak self] in
                    self?.synchronizeBrowserTabs()
                }
            }
            .store(in: &tabObservers)
        tabManager.$activeTabIndex
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.synchronizeActiveBrowserTab()
                }
            }
            .store(in: &tabObservers)
        synchronizeBrowserTabs()
        synchronizeActiveBrowserTab()
    }

    func register(_ webView: WKWebView) {
        let browserTabID = tabManager?.tabs.first(where: {
            $0.webViewModel.webView === webView
        })?.id
        if let browserTabID,
           let existingTab = browserWindow.tab(id: browserTabID) {
            existingTab.attach(webView)
            activate(webView)
            return
        }
        if !browserWindow.contains(webView) {
            let tab = NativeExtensionTab(
                browserTabID: browserTabID,
                webView: webView,
                window: browserWindow,
                runtime: self
            )
            browserWindow.tabs.append(tab)
            controller.didOpenTab(tab)
        }
        activate(webView)
    }

    func activate(_ webView: WKWebView) {
        guard let tab = browserWindow.tab(for: webView) else { return }
        activate(tab)
    }

    func unregister(_ webView: WKWebView) {
        browserWindow.tab(for: webView)?.detachWebView()
    }

    private func synchronizeBrowserTabs() {
        guard let tabManager else { return }
        let previousOrder = browserWindow.tabs
        let browserIDs = Set(tabManager.tabs.map(\.id))
        for nativeTab in browserWindow.tabs.reversed()
            where nativeTab.browserTabID.map({ !browserIDs.contains($0) }) == true {
            closeNativeTab(nativeTab)
        }

        var orderedTabs: [NativeExtensionTab] = []
        for browserTab in tabManager.tabs {
            let nativeTab: NativeExtensionTab
            if let existing = browserWindow.tab(id: browserTab.id) {
                nativeTab = existing
                if let webView = browserTab.webViewModel.webView {
                    nativeTab.attach(webView)
                }
            } else if let webView = browserTab.webViewModel.webView,
                      let existingForWebView = browserWindow.tab(for: webView) {
                existingForWebView.browserTabID = browserTab.id
                nativeTab = existingForWebView
            } else {
                nativeTab = NativeExtensionTab(
                    browserTabID: browserTab.id,
                    webView: browserTab.webViewModel.webView,
                    window: browserWindow,
                    runtime: self
                )
                controller.didOpenTab(nativeTab)
            }
            orderedTabs.append(nativeTab)
        }
        let unmanagedTabs = browserWindow.tabs.filter { $0.browserTabID == nil }
        browserWindow.tabs = orderedTabs + unmanagedTabs
        for (newIndex, nativeTab) in orderedTabs.enumerated() {
            guard let oldIndex = previousOrder.firstIndex(where: { $0 === nativeTab }),
                  oldIndex != newIndex else { continue }
            controller.didMoveTab(nativeTab, from: oldIndex, in: browserWindow)
        }
        synchronizeActiveBrowserTab()
    }

    private func synchronizeActiveBrowserTab() {
        guard let browserTabID = tabManager?.activeTab?.id,
              let nativeTab = browserWindow.tab(id: browserTabID) else { return }
        activate(nativeTab)
    }

    private func activate(_ tab: NativeExtensionTab) {
        guard browserWindow.activeNativeTab !== tab else { return }
        let previousTab = browserWindow.activeNativeTab
        if let previousTab {
            controller.didDeselectTabs([previousTab])
        }
        browserWindow.activeNativeTab = tab
        controller.didSelectTabs([tab])
        controller.didActivateTab(tab, previousActiveTab: previousTab)
        NotificationCenter.default.post(name: .browserExtensionActionsChanged, object: nil)
    }

    private func closeNativeTab(_ tab: NativeExtensionTab) {
        let wasActive = browserWindow.activeNativeTab === tab
        if wasActive {
            controller.didDeselectTabs([tab])
            browserWindow.activeNativeTab = nil
        }
        browserWindow.tabs.removeAll { $0 === tab }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    @discardableResult
    func load(id: UUID, resourceURL: URL) async throws -> Metadata {
        if let current = contexts[id] {
            let extensionObject = current.webExtension
            return metadata(for: extensionObject)
        }

        let extensionObject: WKWebExtension
        do {
            extensionObject = try await WKWebExtension(resourceBaseURL: resourceURL)
        } catch let error as NSError
            where error.domain == WKWebExtension.errorDomain && error.code == 8 {
            throw BrowserExtensionError.incompatiblePersistentBackground
        }
        if let rawError = NativeWebExtensionIssuePolicy.firstFatalIssue(in: extensionObject.errors) {
            let error = rawError as NSError
            if error.domain == WKWebExtension.errorDomain, error.code == 8 {
                throw BrowserExtensionError.incompatiblePersistentBackground
            }
            throw rawError
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
        contextResourceURLs[ObjectIdentifier(context)] = resourceURL
        return metadata(for: extensionObject)
    }

    func actionPresentation(id: UUID) -> WebExtensionActionPresentation? {
        guard let context = contexts[id] else { return nil }
        let manifest = context.webExtension.manifest
        guard manifest["action"] != nil
                || manifest["browser_action"] != nil
                || manifest["page_action"] != nil else { return nil }
        let tab = browserWindow.activeNativeTab
        guard let action = context.action(for: tab) else { return nil }
        return WebExtensionActionPresentation(
            label: action.label.nonEmpty ?? context.webExtension.displayName?.nonEmpty ?? "Soulo",
            icon: action.icon(for: CGSize(width: 36, height: 36)),
            badgeText: action.badgeText,
            presentsPopup: action.presentsPopup,
            isEnabled: action.isEnabled
        )
    }

    @discardableResult
    func performAction(id: UUID) -> Bool {
        guard let context = contexts[id] else { return false }
        let manifest = context.webExtension.manifest
        guard manifest["action"] != nil
                || manifest["browser_action"] != nil
                || manifest["page_action"] != nil else { return false }
        let tab = browserWindow.activeNativeTab
        guard let action = context.action(for: tab), action.isEnabled else { return false }
        browserWindow.tabs.forEach { $0.refreshMediaState() }
        context.performAction(for: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for issue in context.errors {
                browserExtensionLogger.error(
                    "Runtime issue in \(context.webExtension.displayName ?? id.uuidString, privacy: .public): \(issue.localizedDescription, privacy: .public)"
                )
            }
        }
        return true
    }

    func unload(id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        contextResourceURLs.removeValue(forKey: ObjectIdentifier(context))
        compatibilityHost.remove(context: context)
        try? controller.unload(context)
    }

    fileprivate func browserTab(for nativeTab: NativeExtensionTab) -> BrowserTab? {
        guard let id = nativeTab.browserTabID else { return nil }
        return tabManager?.tabs.first { $0.id == id }
    }

    fileprivate func createBrowserTab(
        url: URL?,
        active: Bool,
        parent: NativeExtensionTab? = nil
    ) throws -> NativeExtensionTab {
        guard let tabManager else { throw NativeWebExtensionHostError.browserUnavailable }
        let browserTab = tabManager.createTab(url: url, switchTo: active)
        // createTab has completed here, so explicitly expose the new tab before
        // replying to WebKit's tabs.create/openOptions delegate callback.
        synchronizeBrowserTabs()
        guard let nativeTab = browserWindow.tab(id: browserTab.id) else {
            throw NativeWebExtensionHostError.browserUnavailable
        }
        nativeTab.parentNativeTab = parent
        if active {
            activate(nativeTab)
        }
        return nativeTab
    }

    fileprivate func activateBrowserTab(_ nativeTab: NativeExtensionTab) throws {
        guard let id = nativeTab.browserTabID,
              let index = tabManager?.tabs.firstIndex(where: { $0.id == id }),
              let tabManager else { throw NativeWebExtensionHostError.tabUnavailable }
        tabManager.switchToTab(at: index)
        activate(nativeTab)
    }

    fileprivate func closeBrowserTab(_ nativeTab: NativeExtensionTab) throws {
        guard let id = nativeTab.browserTabID,
              tabManager?.tabs.contains(where: { $0.id == id }) == true,
              let tabManager else { throw NativeWebExtensionHostError.tabUnavailable }
        tabManager.closeTab(id: id)
        synchronizeBrowserTabs()
    }

    func closeBrowserWindow() throws {
        guard let tabManager else { throw NativeWebExtensionHostError.browserUnavailable }
        tabManager.closeAllTabs()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [browserWindow]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        browserWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        guard !configuration.shouldBePrivate else {
            completionHandler(nil, NativeWebExtensionHostError.unsupported("private extension windows"))
            return
        }
        // WebKit invokes this delegate while it is updating its own tab model.
        // Publishing TabManager changes synchronously from that stack can re-enter
        // WKWebExtensionController and terminate the app. Cross one main-run-loop
        // boundary before notifying WebKit about the resulting Soulo tabs.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler(nil, NativeWebExtensionHostError.browserUnavailable)
                return
            }
            WebExtensionPopupPresenter.dismissCurrentPopup { [weak self] in
                guard let self else {
                    completionHandler(nil, NativeWebExtensionHostError.browserUnavailable)
                    return
                }
                do {
                    let urls = configuration.tabURLs.isEmpty ? [nil] : configuration.tabURLs.map(Optional.some)
                    for (index, url) in urls.enumerated() {
                        _ = try self.createBrowserTab(
                            url: url,
                            active: configuration.shouldBeFocused && index == 0
                        )
                    }
                    completionHandler(self.browserWindow, nil)
                } catch {
                    completionHandler(nil, error)
                }
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler(nil, NativeWebExtensionHostError.browserUnavailable)
                return
            }
            WebExtensionPopupPresenter.dismissCurrentPopup { [weak self] in
                guard let self else {
                    completionHandler(nil, NativeWebExtensionHostError.browserUnavailable)
                    return
                }
                do {
                    let parent = configuration.parentTab as? NativeExtensionTab
                    let tab = try self.createBrowserTab(
                        url: configuration.url,
                        active: configuration.shouldBeActive,
                        parent: parent
                    )
                    tab.setInitialMuted(configuration.shouldBeMuted)
                    completionHandler(tab, nil)
                } catch {
                    completionHandler(nil, error)
                }
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let url = context.optionsPageURL else {
            completionHandler(NativeWebExtensionHostError.unsupported("extension options page"))
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler(NativeWebExtensionHostError.browserUnavailable)
                return
            }
            WebExtensionPopupPresenter.dismissCurrentPopup { [weak self] in
                guard let self else {
                    completionHandler(NativeWebExtensionHostError.browserUnavailable)
                    return
                }
                do {
                    _ = try self.createBrowserTab(url: url, active: true)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        WebExtensionPermissionPrompter.confirm(
            extensionName: context.webExtension.displayName,
            items: permissions.map(String.init(describing:)).sorted()
        ) { allowed in
            completionHandler(allowed ? permissions : [], allowed ? .distantFuture : nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        WebExtensionPermissionPrompter.confirm(
            extensionName: context.webExtension.displayName,
            items: urls.map(\.absoluteString).sorted()
        ) { allowed in
            completionHandler(allowed ? urls : [], allowed ? .distantFuture : nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        WebExtensionPermissionPrompter.confirm(
            extensionName: context.webExtension.displayName,
            items: matchPatterns.map(\.string).sorted()
        ) { allowed in
            completionHandler(allowed ? matchPatterns : [], allowed ? .distantFuture : nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        NotificationCenter.default.post(name: .browserExtensionActionsChanged, object: nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard action.presentsPopup, let popupViewController = action.popupViewController else {
            completionHandler(WebExtensionPopupPresenter.unavailableError)
            return
        }
        WebExtensionPopupPresenter.present(popupViewController, completionHandler: completionHandler)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        if compatibilityHost.handle(
            message: message,
            applicationIdentifier: applicationIdentifier,
            context: context,
            resourceURL: contextResourceURLs[ObjectIdentifier(context)],
            replyHandler: replyHandler
        ) {
            return
        }
        replyHandler(
            nil,
            NativeWebExtensionHostError.unsupported(
                applicationIdentifier.map { "native messaging (\($0))" } ?? "native messaging"
            )
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let error = NativeWebExtensionHostError.unsupported("persistent native messaging")
        retainedMessagePorts[ObjectIdentifier(port)] = port
        port.disconnect(throwing: error)
        retainedMessagePorts.removeValue(forKey: ObjectIdentifier(port))
        completionHandler(error)
    }

    private func metadata(for extensionObject: WKWebExtension) -> Metadata {
        Metadata(
            name: extensionObject.displayName?.nonEmpty
                ?? LanguageManager.shared.localizedString("extension_untitled"),
            version: extensionObject.version,
            permissionCount: extensionObject.requestedPermissions.count,
            siteCount: extensionObject.requestedPermissionMatchPatterns.count,
            compatibilityWarningCount: NativeWebExtensionIssuePolicy.recoverableIssueCount(
                in: extensionObject.errors
            )
        )
    }
}

struct WebExtensionActionPresentation {
    let label: String
    let icon: UIImage?
    let badgeText: String
    let presentsPopup: Bool
    let isEnabled: Bool
}

enum NativeWebExtensionIssuePolicy {
    /// WKWebExtension still returns a usable extension for these parse issues
    /// and skips only the affected resource or declarative rule.
    private static let recoverableCodes = Set([2, 6, 7])
    private static var webExtensionErrorDomain: String {
        if #available(iOS 18.4, *) { return WKWebExtension.errorDomain }
        return "WKWebExtensionErrorDomain"
    }

    static func firstFatalIssue(in issues: [Error]) -> Error? {
        issues.first { issue in
            let error = issue as NSError
            return error.domain != webExtensionErrorDomain
                || !recoverableCodes.contains(error.code)
        }
    }

    static func recoverableIssueCount(in issues: [Error]) -> Int {
        issues.filter { issue in
            let error = issue as NSError
            return error.domain == webExtensionErrorDomain
                && recoverableCodes.contains(error.code)
        }.count
    }
}

private enum NativeWebExtensionHostError {
    private static let domain = "com.dkluge.Soulo.WebExtensionHost"

    static let browserUnavailable = NSError(
        domain: domain,
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The Soulo browser window is unavailable."]
    )
    static let tabUnavailable = NSError(
        domain: domain,
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The requested Soulo tab is unavailable."]
    )

    static func unsupported(_ feature: String) -> NSError {
        NSError(
            domain: domain,
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Soulo on iOS does not support \(feature)."]
        )
    }
}

@MainActor
private enum WebExtensionPermissionPrompter {
    static func confirm(
        extensionName: String?,
        items: [String],
        completion: @escaping (Bool) -> Void
    ) {
        guard !items.isEmpty else {
            completion(true)
            return
        }
        guard let presenter = WebExtensionPopupPresenter.foregroundPresenter() else {
            completion(false)
            return
        }
        let title = LanguageManager.shared.localizedString("userscript_permissions_title")
        let name = extensionName?.nonEmpty ?? LanguageManager.shared.localizedString("extension_untitled")
        let message = ([name] + items).joined(separator: "\n")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: LanguageManager.shared.localizedString("cancel"),
            style: .cancel
        ) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(
            title: LanguageManager.shared.localizedString("confirm"),
            style: .default
        ) { _ in
            completion(true)
        })
        presenter.present(alert, animated: true)
    }
}

@MainActor
private enum WebExtensionPopupPresenter {
    static let unavailableError = NSError(
        domain: "com.dkluge.Soulo.WebExtensionPopup",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The extension popup is unavailable."]
    )
    private static weak var presentedPopup: UIViewController?

    static func present(
        _ popupViewController: UIViewController,
        completionHandler: @escaping (Error?) -> Void,
        attempt: Int = 0
    ) {
        guard let presenter = foregroundPresenter() else {
            completionHandler(unavailableError)
            return
        }

        if presenter.isBeingDismissed || presenter.presentedViewController?.isBeingDismissed == true {
            guard attempt < 8 else {
                completionHandler(unavailableError)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                present(
                    popupViewController,
                    completionHandler: completionHandler,
                    attempt: attempt + 1
                )
            }
            return
        }

        if let popover = popupViewController.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.safeAreaInsets.top + 1,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = [.up, .down]
        }
        presenter.present(popupViewController, animated: true) {
            presentedPopup = popupViewController
            completionHandler(nil)
        }
    }

    static func dismissCurrentPopup(completion: @escaping () -> Void) {
        guard let popup = presentedPopup,
              popup.presentingViewController != nil,
              !popup.isBeingDismissed else {
            presentedPopup = nil
            completion()
            return
        }
        presentedPopup = nil
        popup.dismiss(animated: true, completion: completion)
    }

    fileprivate static func foregroundPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let root = scenes.lazy
            .compactMap { scene in
                scene.windows.first(where: \.isKeyWindow)?.rootViewController
                    ?? scene.windows.first(where: { !$0.isHidden })?.rootViewController
            }
            .first
        return root.map(topViewController)
    }

    private static func topViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = root as? UINavigationController,
           let visible = navigation.visibleViewController {
            return topViewController(from: visible)
        }
        if let tab = root as? UITabBarController,
           let selected = tab.selectedViewController {
            return topViewController(from: selected)
        }
        return root
    }
}

@MainActor
@available(iOS 18.4, *)
private final class NativeExtensionWindow: NSObject, WKWebExtensionWindow {
    var tabs: [NativeExtensionTab] = []
    var activeNativeTab: NativeExtensionTab?
    weak var runtime: NativeWebExtensionRuntime?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeNativeTab }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(
            state == .normal ? nil : NativeWebExtensionHostError.unsupported("changing iOS window state")
        )
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return activeScene?.coordinateSpace.bounds ?? .zero
    }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(NativeWebExtensionHostError.unsupported("resizing iOS windows"))
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let runtime = self?.runtime else {
                completionHandler(NativeWebExtensionHostError.browserUnavailable)
                return
            }
            do {
                try runtime.closeBrowserWindow()
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func contains(_ webView: WKWebView) -> Bool {
        tabs.contains { $0.webView === webView }
    }

    func tab(for webView: WKWebView) -> NativeExtensionTab? {
        tabs.first { $0.webView === webView }
    }

    func tab(id: UUID) -> NativeExtensionTab? {
        tabs.first { $0.browserTabID == id }
    }

    func remove(_ webView: WKWebView) -> NativeExtensionTab? {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return nil }
        return tabs.remove(at: index)
    }
}

@MainActor
@available(iOS 18.4, *)
private final class NativeExtensionTab: NSObject, WKWebExtensionTab {
    var browserTabID: UUID?
    weak var webView: WKWebView?
    weak var browserWindow: NativeExtensionWindow?
    weak var runtime: NativeWebExtensionRuntime?
    weak var parentNativeTab: NativeExtensionTab?
    private var isMutedByExtension = false
    private var isPlayingAudioOnPage = false
    private var webViewObservations: [NSKeyValueObservation] = []

    init(
        browserTabID: UUID?,
        webView: WKWebView?,
        window: NativeExtensionWindow,
        runtime: NativeWebExtensionRuntime
    ) {
        self.browserTabID = browserTabID
        self.webView = webView
        self.browserWindow = window
        self.runtime = runtime
        super.init()
        if let webView {
            observe(webView)
        }
    }

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        observe(webView)
        applyMutedState()
        refreshMediaState()
    }

    func detachWebView() {
        webViewObservations.removeAll()
        webView = nil
    }

    private func observe(_ webView: WKWebView) {
        webViewObservations.removeAll()
        let notify: (WKWebExtension.TabChangedProperties) -> Void = { [weak self] properties in
            guard let self else { return }
            self.runtime?.controller.didChangeTabProperties(properties, for: self)
        }
        webViewObservations = [
            webView.observe(\.url, options: [.new]) { _, _ in notify(.URL) },
            webView.observe(\.title, options: [.new]) { _, _ in notify(.title) },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                notify(.loading)
                if !webView.isLoading {
                    Task { @MainActor [weak self] in
                        self?.refreshMediaState()
                    }
                }
            },
            webView.observe(\.pageZoom, options: [.new]) { _, _ in notify(.zoomFactor) }
        ]
    }

    func setInitialMuted(_ muted: Bool) {
        isMutedByExtension = muted
        applyMutedState()
    }

    func refreshMediaState() {
        guard let webView else { return }
        let source = "Array.from(document.querySelectorAll('audio,video')).some(function(m){return !m.paused && !m.ended;})"
        webView.evaluateJavaScript(source) { [weak self] value, _ in
            guard let self, let playing = value as? Bool,
                  playing != self.isPlayingAudioOnPage else { return }
            self.isPlayingAudioOnPage = playing
            self.runtime?.controller.didChangeTabProperties(.playingAudio, for: self)
        }
    }

    private func applyMutedState() {
        guard let webView else { return }
        let source = "document.querySelectorAll('audio,video').forEach(function(m){m.muted=\(isMutedByExtension ? "true" : "false")});"
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browserWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browserWindow?.tabs.firstIndex(where: { $0 === self }) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        parentNativeTab
    }

    func setParentTab(
        _ parentTab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard parentTab == nil || parentTab is NativeExtensionTab else {
            completionHandler(NativeWebExtensionHostError.tabUnavailable)
            return
        }
        parentNativeTab = parentTab as? NativeExtensionTab
        completionHandler(nil)
    }

    func title(for context: WKWebExtensionContext) -> String? {
        runtime?.browserTab(for: self)?.webViewModel.pageTitle.nonEmpty ?? webView?.title
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool { false }

    func setPinned(
        _ pinned: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(
            pinned ? NativeWebExtensionHostError.unsupported("pinned tabs") : nil
        )
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { false }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { false }

    func setReaderModeActive(
        _ active: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(
            active ? NativeWebExtensionHostError.unsupported("reader mode") : nil
        )
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        refreshMediaState()
        return isPlayingAudioOnPage
    }
    func isMuted(for context: WKWebExtensionContext) -> Bool { isMutedByExtension }

    func setMuted(
        _ muted: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        isMutedByExtension = muted
        guard let webView else {
            completionHandler(nil)
            return
        }
        let source = "document.querySelectorAll('audio,video').forEach(function(m){m.muted=\(muted ? "true" : "false")});"
        webView.evaluateJavaScript(source) { _, error in
            completionHandler(error)
        }
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(runtime?.browserTab(for: self)?.webViewModel.pageZoom ?? webView?.pageZoom ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard zoomFactor.isFinite, zoomFactor > 0 else {
            completionHandler(NativeWebExtensionHostError.unsupported("the requested zoom factor"))
            return
        }
        if let model = runtime?.browserTab(for: self)?.webViewModel {
            model.setPageZoom(CGFloat(zoomFactor))
        } else {
            webView?.pageZoom = zoomFactor
        }
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        runtime?.browserTab(for: self)?.webViewModel.currentURL ?? webView?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        let tab = runtime?.browserTab(for: self)
        return tab?.webViewModel.isLoading == true ? tab?.webViewModel.currentURL : nil
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(runtime?.browserTab(for: self)?.webViewModel.isLoading ?? webView?.isLoading ?? false)
    }

    func detectWebpageLocale(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Locale?, Error?) -> Void
    ) {
        guard let webView else {
            completionHandler(nil, NativeWebExtensionHostError.tabUnavailable)
            return
        }
        webView.evaluateJavaScript("document.documentElement.lang || navigator.language || ''") { value, error in
            guard error == nil, let identifier = (value as? String)?.nonEmpty else {
                completionHandler(nil, error)
                return
            }
            completionHandler(Locale(identifier: identifier), nil)
        }
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (UIImage?, Error?) -> Void
    ) {
        guard let webView else {
            completionHandler(nil, NativeWebExtensionHostError.tabUnavailable)
            return
        }
        webView.takeSnapshot(with: configuration) { image, error in
            completionHandler(image, error)
        }
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let model = runtime?.browserTab(for: self)?.webViewModel {
            model.loadURL(url)
        } else if let webView {
            webView.load(URLRequest(url: url))
        } else {
            completionHandler(NativeWebExtensionHostError.tabUnavailable)
            return
        }
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let webView else {
            completionHandler(NativeWebExtensionHostError.tabUnavailable)
            return
        }
        if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let webView, webView.canGoBack else {
            completionHandler(NativeWebExtensionHostError.unsupported("back navigation for this tab"))
            return
        }
        webView.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let webView, webView.canGoForward else {
            completionHandler(NativeWebExtensionHostError.unsupported("forward navigation for this tab"))
            return
        }
        webView.goForward()
        completionHandler(nil)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try runtime?.activateBrowserTab(self)
            completionHandler(runtime == nil ? NativeWebExtensionHostError.browserUnavailable : nil)
        } catch {
            completionHandler(error)
        }
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        browserWindow?.activeNativeTab === self
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if selected {
            activate(for: context, completionHandler: completionHandler)
        } else if isSelected(for: context) {
            completionHandler(NativeWebExtensionHostError.unsupported("deselecting the active iOS tab"))
        } else {
            completionHandler(nil)
        }
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        let sourceURL = configuration.url ?? url(for: context)
        DispatchQueue.main.async { [weak self] in
            guard let self, let runtime = self.runtime else {
                completionHandler(nil, NativeWebExtensionHostError.browserUnavailable)
                return
            }
            do {
                let duplicate = try runtime.createBrowserTab(
                    url: sourceURL,
                    active: configuration.shouldBeActive,
                    parent: configuration.parentTab as? NativeExtensionTab ?? self
                )
                completionHandler(duplicate, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let runtime = self.runtime else {
                completionHandler(NativeWebExtensionHostError.browserUnavailable)
                return
            }
            do {
                try runtime.closeBrowserTab(self)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
}
