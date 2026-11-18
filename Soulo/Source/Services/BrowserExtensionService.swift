import Foundation
import Darwin
import Combine
import OSLog
import UniformTypeIdentifiers
import UIKit
import SwiftUI
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
    /// Installed dependency snapshots, keyed by the exact @require declaration.
    var requiredSources: [String: String]?
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
        requiredSources: [String: String] = [:],
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
        self.requiredSources = requiredSources
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

    var hasResolvedRequirements: Bool {
        (requiredURLs ?? []).allSatisfy { requiredSources?[$0] != nil }
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
    var access: WebExtensionAccess? = nil
    var packageIdentity: String? = nil
    var sourceURL: String? = nil
    var previousVersion: WebExtensionVersionSnapshot? = nil
}

enum BrowserInstallPackageKind: String, Equatable {
    case webExtension
    case userScript
}

/// A package downloaded from a webpage that Soulo can install directly.
/// UserScript detection verifies its metadata, including when a store supplies
/// a generic filename, so HTTP error pages are not offered for installation.
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

    static func isUserScriptURL(_ url: URL?) -> Bool {
        url?.lastPathComponent.lowercased().hasSuffix(".user.js") == true
    }

    static func detect(fileURL: URL, sourceURL: URL?) -> Self? {
        let filename = fileURL.lastPathComponent.lowercased()
        let scriptURL = isUserScriptURL(sourceURL)
        if filename.hasSuffix(".js") || scriptURL {
            guard containsUserScriptMetadata(fileURL) else { return nil }
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
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return false }
        // The bounded prefix may end in the middle of a UTF-8 character.
        let prefix = String(decoding: data, as: UTF8.self)
        let start = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !start.hasPrefix("<!doctype"), !start.hasPrefix("<html") else { return false }
        return prefix.contains("==UserScript==") && prefix.contains("==/UserScript==") && prefix.contains("@name")
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
    private(set) static weak var existingShared: BrowserExtensionService?
    static let shared: BrowserExtensionService = {
        let service = BrowserExtensionService()
        existingShared = service
        return service
    }()
    static let maximumUserScriptSize = 2 * 1_024 * 1_024
    static let maximumStoredValueSize = 256 * 1_024
    static let maximumStoredValuesSize = 1 * 1_024 * 1_024
    @Published private(set) var userScripts: [UserScriptRecord] = []
    @Published private(set) var webExtensions: [WebExtensionRecord] = []
    @Published private(set) var loadingWebExtensions: Set<UUID> = []
    @Published private(set) var webExtensionErrors: [UUID: String] = [:]
    @Published private(set) var loadingUserScripts: Set<UUID> = []
    @Published private(set) var userScriptErrors: [UUID: String] = [:]
    @Published private(set) var userScriptRuntimeErrors: [UUID: String] = [:]
    @Published private(set) var availableUserScriptUpdateVersions: [UUID: String] = [:]
    private var preparedExtensions: [UUID: WebExtensionInstallPreview] = [:]
    private var installingExtensionIDs: Set<UUID> = []
    private var storageRevisions: [UUID: Int] = [:]
    private var extensionLoadRevisions: [UUID: UUID] = [:]
    private var requirementTasks: [UUID: Task<Void, Never>] = [:]
    private var requirementRevisions: [UUID: UUID] = [:]
    private let requirementSession: URLSession
    private let updateDefaults: UserDefaults
    private var automaticUpdateCheckInProgress = false
    static let updateCheckDatesKey = "userscript_update_checked_at"
    static let availableUpdateVersionsKey = "userscript_update_available_versions"
    private let customExtensionRoot: URL?

    private let fileManager = FileManager.default

    init(extensionRoot: URL? = nil, requirementSession: URLSession = UserScriptRequirementLoader.makeSession(),
         updateDefaults: UserDefaults = .standard) {
        self.customExtensionRoot = extensionRoot
        self.requirementSession = requirementSession
        self.updateDefaults = updateDefaults
        loadStore()
        let installedIDs = Set(userScripts.map { $0.id.uuidString })
        let savedVersions = updateDefaults.dictionary(forKey: Self.availableUpdateVersionsKey) as? [String: String] ?? [:]
        availableUserScriptUpdateVersions = Dictionary(uniqueKeysWithValues: savedVersions.compactMap { key, version in
            guard installedIDs.contains(key), let id = UUID(uuidString: key), version.count <= 128 else { return nil }
            return (id, version)
        })
        installBuiltInExamplesIfNeeded()
        for script in userScripts where script.isEnabled && !script.hasResolvedRequirements {
            resolveUserScriptRequirements(script.id)
        }
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

    func previewUserScriptUpdate(_ id: UUID) async throws -> UserScriptUpdatePreview? {
        guard let script = userScript(id: id) else { throw CancellationError() }
        let preview = try await UserScriptUpdateLoader.check(script, session: requirementSession)
        try Task.checkCancellation()
        guard let current = userScript(id: id), current.source == script.source,
              current.updatedAt == script.updatedAt else { throw CancellationError() }
        availableUserScriptUpdateVersions[id] = preview?.metadata.version
        persistAvailableUserScriptUpdates()
        return preview
    }

    private func persistAvailableUserScriptUpdates() {
        updateDefaults.set(Dictionary(uniqueKeysWithValues: availableUserScriptUpdateVersions.map { ($0.key.uuidString, $0.value) }),
                           forKey: Self.availableUpdateVersionsKey)
    }

    /// Run only from the visible extension manager. Keep each visit bounded,
    /// throttle each script for 24 hours, and leave applying updates to review.
    func checkAutomaticUserScriptUpdates(now: Date = Date(), limit: Int = 4) async {
        guard !automaticUpdateCheckInProgress, !Task.isCancelled,
              !updateDefaults.bool(forKey: "is_incognito"), !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { return }
        var dates = updateDefaults.dictionary(forKey: Self.updateCheckDatesKey) as? [String: Double] ?? [:]
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite else { return }
        let candidates = userScripts.filter { script in
            guard script.isEnabled, script.isBuiltIn != true, UserScriptUpdateLoader.checkURL(for: script) != nil else { return false }
            guard let last = dates[script.id.uuidString], last.isFinite else { return true }
            return last > timestamp || timestamp - last >= 24 * 60 * 60
        }.sorted { (dates[$0.id.uuidString] ?? 0) < (dates[$1.id.uuidString] ?? 0) }
            .prefix(min(max(limit, 1), 4))
        guard !candidates.isEmpty else { return }
        automaticUpdateCheckInProgress = true
        defer { automaticUpdateCheckInProgress = false }
        for script in candidates {
            guard !Task.isCancelled else { return }
            do {
                let version = try await UserScriptUpdateLoader.availableVersion(script, session: requirementSession)
                try Task.checkCancellation()
                guard let current = userScript(id: script.id), current.isEnabled,
                      current.updatedAt == script.updatedAt else { continue }
                availableUserScriptUpdateVersions[script.id] = version
                persistAvailableUserScriptUpdates()
            } catch {
                if Task.isCancelled { return }
                // Failed servers receive the same backoff; reopening a page
                // must not create a tight network retry loop.
            }
            dates[script.id.uuidString] = timestamp
            let installed = Set(userScripts.map { $0.id.uuidString })
            dates = dates.filter { installed.contains($0.key) }
            updateDefaults.set(dates, forKey: Self.updateCheckDatesKey)
        }
    }

    @discardableResult
    func applyUserScriptUpdate(_ preview: UserScriptUpdatePreview) async throws -> UserScriptRecord {
        func stillCurrent() -> Bool {
            guard let current = userScript(id: preview.id) else { return false }
            return current.isBuiltIn != true && current.source == preview.installed.source
                && current.updatedAt == preview.installed.updatedAt
        }
        guard stillCurrent() else { throw CancellationError() }
        let metadata = try Self.validateUserScriptSource(preview.source, explicitPatterns: nil)
        // Re-fetch dependencies after review. An unchanged dependency URL may
        // publish a new version, so the old installation's cache is unsuitable.
        let sources = try await UserScriptRequirementLoader.resolve(metadata.requiredURLs,
            baseURL: preview.sourceURL, session: requirementSession)
        try Task.checkCancellation()
        guard stillCurrent() else { throw CancellationError() }
        return try saveUserScript(id: preview.id, fallbackName: preview.installed.name, source: preview.source,
            explicitPatterns: nil, injectionTime: nil, sourceURL: preview.sourceURL, requiredSources: sources)
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

    func importUserScript(from fileURL: URL, sourceURL: URL? = nil) async throws -> UserScriptRecord {
        let preview = try previewUserScript(from: fileURL, sourceURL: sourceURL)
        return try await saveUserScriptResolvingRequirements(
            id: nil,
            fallbackName: preview.name,
            source: preview.source,
            explicitPatterns: nil,
            injectionTime: nil,
            sourceURL: sourceURL
        )
    }

    @discardableResult
    func saveUserScriptResolvingRequirements(
        id: UUID?,
        fallbackName: String,
        source: String,
        explicitPatterns: [String]?,
        injectionTime: UserScriptInjectionTime?,
        explicitName: String? = nil,
        sourceURL: URL? = nil
    ) async throws -> UserScriptRecord {
        let metadata = try Self.validateUserScriptSource(source, explicitPatterns: explicitPatterns)
        let previous = id.flatMap { userScript(id: $0) }
        if id != nil && previous == nil { throw CancellationError() }
        let baseURL = sourceURL ?? previous?.sourceURL.flatMap(URL.init(string:))
        let sources = try await UserScriptRequirementLoader.resolve(
            metadata.requiredURLs,
            baseURL: baseURL,
            cachedSources: baseURL?.absoluteString == previous?.sourceURL ? previous?.requiredSources ?? [:] : [:],
            session: requirementSession
        )
        try Task.checkCancellation()
        // An edit finishing after a delete or another edit must not restore stale code.
        if let previous {
            guard let current = userScript(id: previous.id),
                  current.source == previous.source, current.updatedAt == previous.updatedAt else {
                throw CancellationError()
            }
        }
        return try saveUserScript(
            id: id, fallbackName: fallbackName, source: source,
            explicitPatterns: explicitPatterns, injectionTime: injectionTime,
            explicitName: explicitName, sourceURL: baseURL, requiredSources: sources
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
        sourceURL: URL? = nil,
        requiredSources: [String: String]? = nil
    ) throws -> UserScriptRecord {
        let metadata = try Self.validateUserScriptSource(source, explicitPatterns: explicitPatterns)
        let requestedPatterns = (explicitPatterns ?? metadata.patterns)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedPatterns = Self.deduplicated(requestedPatterns.isEmpty ? ["*://*/*"] : requestedPatterns)
        let normalizedExcludes = metadata.excludePatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

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
        let dependencySources = requiredSources ?? existingRecord?.requiredSources ?? [:]
        if let missing = metadata.requiredURLs.first(where: { dependencySources[$0] == nil }) {
            throw UserScriptRequirementLoader.Failure(declaration: missing, underlying: URLError(.resourceUnavailable))
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
            requiredSources: dependencySources.filter { metadata.requiredURLs.contains($0.key) },
            resources: metadata.resources,
            sourceURL: normalizedSourceURL ?? existingRecord?.sourceURL,
            storedValues: existingRecord?.storedValues ?? [:],
            isBuiltIn: existingRecord?.isBuiltIn ?? false,
            injectionTime: injectionTime ?? metadata.injectionTime,
            isEnabled: existingRecord?.isEnabled ?? true,
            installedAt: existingRecord?.installedAt ?? Date(),
            updatedAt: Date()
        )

        let previousScripts = userScripts
        if let index = userScripts.firstIndex(where: { $0.id == record.id }) {
            userScripts[index] = record
        } else {
            userScripts.insert(record, at: 0)
        }
        do { try writeExtensionStore() } catch { userScripts = previousScripts; throw error }
        cancelRequirementResolution(record.id)
        userScriptErrors[record.id] = nil
        userScriptRuntimeErrors[record.id] = nil
        if availableUserScriptUpdateVersions.removeValue(forKey: record.id) != nil { persistAvailableUserScriptUpdates() }
        NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
        return record
    }

    func setUserScriptEnabled(_ id: UUID, enabled: Bool) {
        guard let index = userScripts.firstIndex(where: { $0.id == id }) else { return }
        let previous = userScripts[index].isEnabled
        userScripts[index].isEnabled = enabled
        do { try writeExtensionStore() } catch {
            userScripts[index].isEnabled = previous; userScriptErrors[id] = error.localizedDescription; return
        }
        if enabled && !userScripts[index].hasResolvedRequirements {
            resolveUserScriptRequirements(id)
        } else if !enabled {
            cancelRequirementResolution(id)
        }
        NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
    }

    func deleteUserScript(_ id: UUID) {
        guard userScripts.first(where: { $0.id == id })?.isBuiltIn != true else { return }
        let previousScripts = userScripts
        userScripts.removeAll { $0.id == id }
        do { try writeExtensionStore() } catch {
            userScripts = previousScripts; userScriptErrors[id] = error.localizedDescription; return
        }
        cancelRequirementResolution(id)
        userScriptErrors[id] = nil
        userScriptRuntimeErrors[id] = nil
        if availableUserScriptUpdateVersions.removeValue(forKey: id) != nil { persistAvailableUserScriptUpdates() }
        UserScriptTabStore.shared.remove(scriptID: id)
        NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
    }

    private func cancelRequirementResolution(_ id: UUID) {
        requirementTasks.removeValue(forKey: id)?.cancel()
        requirementRevisions[id] = nil
        loadingUserScripts.remove(id)
    }

    private func resolveUserScriptRequirements(_ id: UUID) {
        guard let script = userScript(id: id), !script.hasResolvedRequirements else { return }
        cancelRequirementResolution(id)
        let revision = UUID()
        requirementRevisions[id] = revision
        loadingUserScripts.insert(id)
        userScriptErrors[id] = nil
        requirementTasks[id] = Task { [weak self, requirementSession] in
            do {
                let sources = try await UserScriptRequirementLoader.resolve(
                    script.requiredURLs ?? [], baseURL: script.sourceURL.flatMap(URL.init(string:)),
                    cachedSources: script.requiredSources ?? [:], session: requirementSession
                )
                try Task.checkCancellation()
                guard let self, self.requirementRevisions[id] == revision,
                      let index = self.userScripts.firstIndex(where: { $0.id == id }) else { return }
                self.userScripts[index].requiredSources = sources
                self.persistAndNotify()
            } catch {
                guard let self, self.requirementRevisions[id] == revision else { return }
                self.userScriptErrors[id] = error.localizedDescription
                if let index = self.userScripts.firstIndex(where: { $0.id == id }) {
                    self.userScripts[index].isEnabled = false
                    self.persistAndNotify()
                }
            }
            guard let self, self.requirementRevisions[id] == revision else { return }
            self.requirementTasks[id] = nil
            self.requirementRevisions[id] = nil
            self.loadingUserScripts.remove(id)
        }
    }

    func setStoredValue(_ encodedValue: String, forKey key: String, scriptID: UUID) throws {
        try setStoredValues([key: encodedValue], scriptID: scriptID)
    }

    func setStoredValues(_ encodedValues: [String: String], scriptID: UUID, origin: String = "", mutationID: String = "") throws {
        guard let index = userScripts.firstIndex(where: { $0.id == scriptID }),
              !encodedValues.isEmpty,
              encodedValues.allSatisfy({ key, encodedValue in
                  guard !key.isEmpty,
                        key.utf8.count <= 256,
                        encodedValue.utf8.count <= Self.maximumStoredValueSize,
                        let data = encodedValue.data(using: .utf8),
                        let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                  else { return false }
                  return wrapper.count == 1 && wrapper["value"] != nil
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
        let previous = userScripts[index].storedValues
        userScripts[index].storedValues = values
        do { try writeExtensionStore() } catch { userScripts[index].storedValues = previous; throw error }
        publishStorage(scriptID: scriptID, origin: origin, mutationID: mutationID)
    }

    func deleteStoredValue(forKey key: String, scriptID: UUID) {
        deleteStoredValues(forKeys: [key], scriptID: scriptID)
    }

    func deleteStoredValues(forKeys keys: [String], scriptID: UUID) {
        try? deleteStoredValuesPersisting(forKeys: keys, scriptID: scriptID)
    }

    func deleteStoredValuesPersisting(forKeys keys: [String], scriptID: UUID, origin: String = "", mutationID: String = "") throws {
        guard let index = userScripts.firstIndex(where: { $0.id == scriptID }) else { throw BrowserExtensionError.invalidStorageValue }
        let previous = userScripts[index].storedValues
        for key in keys {
            userScripts[index].storedValues?.removeValue(forKey: key)
        }
        do { try writeExtensionStore() } catch { userScripts[index].storedValues = previous; throw error }
        publishStorage(scriptID: scriptID, origin: origin, mutationID: mutationID)
    }

    func storageSnapshot(scriptID: UUID, origin: String = "", mutationID: String = "") -> [String: Any] {
        ["scriptID": scriptID.uuidString, "values": userScript(id: scriptID)?.storedValues ?? [:],
         "revision": storageRevisions[scriptID] ?? 0, "origin": origin, "mutationID": mutationID]
    }

    private func publishStorage(scriptID: UUID, origin: String, mutationID: String) {
        storageRevisions[scriptID, default: 0] += 1
        NotificationCenter.default.post(name: .userScriptStorageChanged, object: self,
            userInfo: storageSnapshot(scriptID: scriptID, origin: origin, mutationID: mutationID))
    }

    func reportUserScriptError(_ message: String, scriptID: UUID) {
        guard userScript(id: scriptID)?.isEnabled == true else { return }
        userScriptRuntimeErrors[scriptID] = String(message.prefix(2000))
    }

    @discardableResult
    func installWebExtension(from sourceURL: URL) async throws -> WebExtensionRecord {
        let preview = try await previewWebExtension(from: sourceURL)
        return try await installWebExtension(preview, access: preview.access)
    }

    func canChangeWebExtensionEnabled(_ id: UUID) -> Bool {
        !installingExtensionIDs.contains(id) && webExtensions.contains { $0.id == id }
    }

    func setWebExtensionEnabled(_ id: UUID, enabled: Bool) {
        guard !installingExtensionIDs.contains(id) else { return }
        guard let index = webExtensions.firstIndex(where: { $0.id == id }) else { return }
        let previous = webExtensions[index].isEnabled
        webExtensions[index].isEnabled = enabled
        do { try writeExtensionStore() } catch {
            webExtensions[index].isEnabled = previous; webExtensionErrors[id] = error.localizedDescription; return
        }
        let revision = UUID()
        extensionLoadRevisions[id] = revision
        webExtensionErrors[id] = nil
        let record = webExtensions[index]
        guard #available(iOS 18.4, *) else { return }
        if !enabled {
            loadingWebExtensions.remove(id)
            NativeWebExtensionRuntime.shared.unload(id: id)
            NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
            return
        }
        loadingWebExtensions.insert(id)
        Task {
            defer {
                if extensionLoadRevisions[id] == revision { loadingWebExtensions.remove(id) }
            }
            do {
                guard extensionLoadRevisions[id] == revision,
                      webExtensions.first(where: { $0.id == id })?.isEnabled == true else { return }
                _ = try await loadNativeExtension(record)
                guard extensionLoadRevisions[id] == revision else {
                    if webExtensions.first(where: { $0.id == id })?.isEnabled != true { NativeWebExtensionRuntime.shared.unload(id: id) }
                    return
                }
            } catch {
                guard extensionLoadRevisions[id] == revision,
                      let index = webExtensions.firstIndex(where: { $0.id == id }) else { return }
                webExtensions[index].isEnabled = false
                webExtensionErrors[id] = error.localizedDescription
                persistAndNotify(reloadPages: false)
            }
            NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
        }
    }

    func webExtensionAction(for id: UUID) -> WebExtensionActionPresentation? {
        guard #available(iOS 18.4, *),
              webExtensions.first(where: { $0.id == id })?.isEnabled == true,
              !loadingWebExtensions.contains(id) else { return nil }
        return NativeWebExtensionRuntime.shared.actionPresentation(id: id)
    }

    @discardableResult
    func performWebExtensionAction(_ id: UUID) -> Bool {
        guard #available(iOS 18.4, *),
              webExtensions.first(where: { $0.id == id })?.isEnabled == true,
              !loadingWebExtensions.contains(id) else { return false }
        return NativeWebExtensionRuntime.shared.performAction(id: id)
    }

    func webExtensionCommands(for id: UUID) -> [WebExtensionCommandPresentation] {
        guard #available(iOS 18.4, *),
              webExtensions.first(where: { $0.id == id })?.isEnabled == true,
              !loadingWebExtensions.contains(id) else { return [] }
        return NativeWebExtensionRuntime.shared.commands(id: id)
    }

    @discardableResult
    func performWebExtensionCommand(_ command: String, id: UUID) -> Bool {
        guard #available(iOS 18.4, *),
              webExtensions.first(where: { $0.id == id })?.isEnabled == true,
              !loadingWebExtensions.contains(id) else { return false }
        return NativeWebExtensionRuntime.shared.performCommand(command, id: id)
    }

    func deleteWebExtension(_ id: UUID) {
        guard let record = webExtensions.first(where: { $0.id == id }) else { return }
        let previous = webExtensions
        webExtensions.removeAll { $0.id == id }
        do { try writeExtensionStore() } catch {
            webExtensions = previous; webExtensionErrors[id] = error.localizedDescription; return
        }
        extensionLoadRevisions[id] = nil
        loadingWebExtensions.remove(id)
        webExtensionErrors[id] = nil
        if #available(iOS 18.4, *) {
            NativeWebExtensionRuntime.shared.unload(id: id)
            NativeWebExtensionRuntime.shared.forgetCompatibilityInstallation(id: id)
        }
        try? fileManager.removeItem(
            at: webExtensionRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
        )
        NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
    }

    private func restoreEnabledNativeExtensions() async {
        guard #available(iOS 18.4, *) else { return }
        var migratedStore = false
        var restoredAny = false
        for record in webExtensions.filter(\.isEnabled) {
            guard let index = webExtensions.firstIndex(where: { $0.id == record.id }), webExtensions[index].isEnabled else { continue }
            loadingWebExtensions.insert(record.id)
            defer { loadingWebExtensions.remove(record.id) }
            let originalResourceURL = resourceURL(for: record)
            let resourceURL: URL
            if record.storedResourceName == WebExtensionPackagePreparer.preparedResourceName
                || record.storedResourceName.hasPrefix("Versions/") {
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
            let revision = extensionLoadRevisions[record.id]
            do {
                _ = try await loadNativeExtension(record, resourceURL: resourceURL)
                if webExtensions.first(where: { $0.id == record.id })?.isEnabled != true {
                    NativeWebExtensionRuntime.shared.unload(id: record.id)
                } else {
                    restoredAny = true
                }
            } catch {
                if extensionLoadRevisions[record.id] == revision,
                   let current = webExtensions.firstIndex(where: { $0.id == record.id }), webExtensions[current].isEnabled {
                    webExtensions[current].isEnabled = false
                    webExtensionErrors[record.id] = error.localizedDescription
                    migratedStore = true
                }
            }
        }
        if migratedStore {
            persistAndNotify(reloadPages: false)
        }
        if restoredAny { NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil) }
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
        userScripts = store.userScripts.map { stored in
            var script = stored
            // Re-read old headers, including stores predating @require parsing
            // and URLs previously collapsed by case-insensitive deduplication.
            script.requiredURLs = Self.parseMetadata(from: script.source).requiredURLs
            return script
        }
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

    private func writeExtensionStore() throws {
        let store = BrowserExtensionStore(userScripts: userScripts, webExtensions: webExtensions)
        try fileManager.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }

    private func persistAndNotify(reloadPages: Bool = true) {
        try? writeExtensionStore()
        if reloadPages {
            NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
        }
    }

    private var extensionRoot: URL {
        if let customExtensionRoot { return customExtensionRoot }
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
            requiredURLs: deduplicated(requiredURLs, caseSensitive: true),
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

    private static func validateUserScriptSource(_ source: String, explicitPatterns: [String]?) throws -> UserScriptMetadata {
        guard source.utf8.count <= maximumUserScriptSize else { throw BrowserExtensionError.scriptTooLarge }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserExtensionError.emptyScript }
        let metadata = parseMetadata(from: source)
        if let explicitPatterns {
            let patterns = explicitPatterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !patterns.isEmpty else { throw BrowserExtensionError.invalidMatchPattern("") }
            if let invalid = patterns.first(where: { !UserScriptURLMatcher.isValid(pattern: $0) }) {
                throw BrowserExtensionError.invalidMatchPattern(invalid)
            }
        }
        try validate(metadata: metadata)
        return metadata
    }

    private static func deduplicated(_ values: [String], caseSensitive: Bool = false) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = caseSensitive ? value : value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

}

extension BrowserExtensionService {
    func discardWebExtensionPreview(_ preview: WebExtensionInstallPreview) {
        guard preparedExtensions.removeValue(forKey: preview.id) != nil else { return }
        try? fileManager.removeItem(at: preview.resourceURL.deletingLastPathComponent())
    }

    func previewWebExtension(from source: URL, sourceURL: URL? = nil, replacing id: UUID? = nil) async throws -> WebExtensionInstallPreview {
        try Task.checkCancellation()
        guard BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled else { throw BrowserExtensionError.temporarilyDisabled }
        guard #available(iOS 18.4, *) else { throw BrowserExtensionError.unsupportedSystem }
        let token = UUID()
        let stage = extensionRoot.appendingPathComponent("Staging/" + token.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Extraction and compatibility preparation can touch thousands of
            // files. Keep the main actor available for progress and Cancel.
            // Wait for the worker before removing staging on cancellation.
            let preparation = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let result = try WebExtensionPackagePreparer.prepare(sourceURL: source, in: stage)
                try Task.checkCancellation()
                return result
            }
            let resources = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            let object = try await WKWebExtension(resourceBaseURL: resources)
            try Task.checkCancellation()
            if let error = NativeWebExtensionIssuePolicy.firstFatalIssue(in: object.errors) { throw error }
            let identity = WebExtensionPackageIdentity.value(manifest: object.manifest, source: sourceURL)
            let previous = id.flatMap { target in webExtensions.first { $0.id == target } }
                ?? identity.flatMap { key in webExtensions.first { $0.packageIdentity == key } }
            if id != nil && previous == nil { throw CancellationError() }
            let descriptor = Self.extensionDescriptor(object.manifest)
            let permissions = Set(descriptor.permissions + object.requestedPermissions.map(\.rawValue)).sorted()
            let sites = Set(descriptor.sites + object.requestedPermissionMatchPatterns.map(\.string)).sorted()
            let access = previous.map { webExtensionAccess($0.id) } ?? .requested(permissions: permissions, sites: sites)
            var warnings = object.errors.map(\.localizedDescription)
            if object.manifest["commands"] != nil { warnings.append("commands") }
            if permissions.contains("offscreen") { warnings.append("offscreen") }
            if permissions.contains("notifications") { warnings.append("notifications: onClicked / onClosed") }
            let preview = WebExtensionInstallPreview(id: token, resourceURL: resources,
                name: object.displayName ?? AppLocalization.string("extension_untitled"), version: object.version,
                permissions: permissions, sites: sites, warnings: warnings, identity: identity ?? previous?.packageIdentity,
                sourceURL: sourceURL?.absoluteString ?? previous?.sourceURL, replacingID: previous?.id,
                replacingResourceName: previous?.storedResourceName, access: access)
            preparedExtensions[token] = preview
            return preview
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }
    }

    @discardableResult
    func installWebExtension(_ preview: WebExtensionInstallPreview, access: WebExtensionAccess) async throws -> WebExtensionRecord {
        try Task.checkCancellation()
        guard #available(iOS 18.4, *) else { throw BrowserExtensionError.unsupportedSystem }
        guard preparedExtensions[preview.id]?.resourceURL == preview.resourceURL else { throw CancellationError() }
        let previous = preview.replacingID.flatMap { id in webExtensions.first { $0.id == id } }
        guard previous?.storedResourceName == preview.replacingResourceName else { throw CancellationError() }
        if preview.replacingID != nil && previous == nil { throw CancellationError() }
        if let previous, webExtensionAccess(previous.id) != preview.access { throw CancellationError() }
        let id = previous?.id ?? UUID()
        guard !installingExtensionIDs.contains(id),
              preview.identity == nil || !webExtensions.contains(where: { $0.packageIdentity == preview.identity && $0.id != id })
        else { throw CancellationError() }
        installingExtensionIDs.insert(id); loadingWebExtensions.insert(id)
        let revision = UUID(); extensionLoadRevisions[id] = revision
        let relativeName = "Versions/" + UUID().uuidString + "/Extension"
        let destination = webExtensionRoot.appendingPathComponent(id.uuidString).appendingPathComponent(relativeName)
        defer {
            installingExtensionIDs.remove(id); loadingWebExtensions.remove(id)
            discardWebExtensionPreview(preview)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: preview.resourceURL, to: destination)
            NativeWebExtensionRuntime.shared.unload(id: id)
            var record = WebExtensionRecord(id: id, name: preview.name, version: preview.version,
                storedResourceName: relativeName, requestedPermissionCount: preview.permissions.count,
                requestedSiteCount: preview.sites.count, compatibilityWarningCount: preview.warnings.count,
                isEnabled: previous?.isEnabled ?? true, installedAt: previous?.installedAt ?? Date())
            record.access = access; record.packageIdentity = preview.identity; record.sourceURL = preview.sourceURL
            record.previousVersion = previous.map(WebExtensionVersionSnapshot.init)
            if record.isEnabled { _ = try await loadNativeExtension(record) }
            try Task.checkCancellation()
            guard extensionLoadRevisions[id] == revision else { throw CancellationError() }
            let original = webExtensions
            if let index = webExtensions.firstIndex(where: { $0.id == id }) { webExtensions[index] = record }
            else { webExtensions.insert(record, at: 0) }
            do { try writeExtensionStore() } catch { webExtensions = original; throw error }
            webExtensionErrors[id] = nil
            if let obsolete = previous?.previousVersion?.storedResourceName,
               obsolete != relativeName, obsolete != previous?.storedResourceName {
                try? fileManager.removeItem(at: checkedResourceURL(id: id, name: obsolete))
            }
            NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
            return record
        } catch {
            NativeWebExtensionRuntime.shared.unload(id: id)
            if let previous, extensionLoadRevisions[id] == revision,
               webExtensions.contains(where: { $0.id == id }), previous.isEnabled {
                do { _ = try await loadNativeExtension(previous) }
                catch { webExtensionErrors[id] = error.localizedDescription }
            }
            try? fileManager.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
    }

    func previewPreviousWebExtension(_ id: UUID) async throws -> WebExtensionInstallPreview {
        guard let record = webExtensions.first(where: { $0.id == id }), let previous = record.previousVersion else {
            throw BrowserExtensionError.invalidExtension
        }
        return try await previewWebExtension(from: checkedResourceURL(id: id, name: previous.storedResourceName), replacing: id)
    }

    func webExtensionAccess(_ id: UUID) -> WebExtensionAccess {
        guard let record = webExtensions.first(where: { $0.id == id }) else { return .init() }
        if let access = record.access { return access }
        let descriptor = webExtensionDetails(id)
        return .requested(permissions: descriptor.permissions, sites: descriptor.sites)
    }

    func webExtensionDetails(_ id: UUID) -> (permissions: [String], sites: [String]) {
        guard let record = webExtensions.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: checkedResourceURL(id: id, name: record.storedResourceName).appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        return Self.extensionDescriptor(manifest)
    }

    func setWebExtensionAccess(_ access: WebExtensionAccess, id: UUID) throws {
        guard !installingExtensionIDs.contains(id), let index = webExtensions.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        guard access.blockedHosts.allSatisfy({ WebExtensionAccess.normalizedHost($0) == $0 }) else {
            throw BrowserExtensionError.invalidExtension
        }
        let previous = webExtensions[index].access
        webExtensions[index].access = access
        do { try writeExtensionStore() } catch { webExtensions[index].access = previous; throw error }
        if #available(iOS 18.4, *) { NativeWebExtensionRuntime.shared.applyAccess(access, id: id) }
        NotificationCenter.default.post(name: .browserExtensionsChanged, object: nil)
    }

    func webExtensionDiagnostics(_ id: UUID) -> [String] {
        var messages: [String] = []
        if let error = webExtensionErrors[id] { messages.append(error) }
        let descriptor = webExtensionDetails(id)
        for name in ["offscreen", "debugger", "desktopCapture", "nativeMessaging"] where descriptor.permissions.contains(name) {
            if name != "nativeMessaging" { messages.append(name) }
        }
        if #available(iOS 18.4, *) { messages += NativeWebExtensionRuntime.shared.diagnostics(id: id) }
        return Array(Set(messages)).sorted()
    }

    private static func extensionDescriptor(_ manifest: [String: Any]) -> (permissions: [String], sites: [String]) {
        let entries = manifest["permissions"] as? [String] ?? []
        let permissions = entries.filter { !$0.contains("://") && $0 != "<all_urls>" }
        let matches = (manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] }
        let sites = entries.filter { $0.contains("://") || $0 == "<all_urls>" }
            + (manifest["host_permissions"] as? [String] ?? []) + matches
        return (Array(Set(permissions)).sorted(), Array(Set(sites)).sorted())
    }

    private func checkedResourceURL(id: UUID, name: String) throws -> URL {
        let root = webExtensionRoot.appendingPathComponent(id.uuidString).standardizedFileURL
        let url = root.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw BrowserExtensionError.invalidExtension }
        return url
    }

    @available(iOS 18.4, *)
    private func loadNativeExtension(_ record: WebExtensionRecord, resourceURL: URL? = nil) async throws -> NativeWebExtensionRuntime.Metadata {
        try await NativeWebExtensionRuntime.shared.load(id: record.id,
            resourceURL: resourceURL ?? checkedResourceURL(id: record.id, name: record.storedResourceName), access: record.access,
            onAccessChange: { [weak self] access in
                guard let self, !self.installingExtensionIDs.contains(record.id),
                      let index = self.webExtensions.firstIndex(where: { $0.id == record.id }) else { return false }
                let previous = self.webExtensions[index].access
                self.webExtensions[index].access = access
                do { try self.writeExtensionStore(); return true }
                catch { self.webExtensions[index].access = previous; self.webExtensionErrors[record.id] = error.localizedDescription; return false }
            })
    }
}

enum UserScriptRuntime {
    static let sourcePrefix = "/* Soulo UserScript */\n"

    static func storageUpdateScript(_ snapshot: [String: Any], bridgeToken: String) -> String? {
        var payload = snapshot; payload["token"] = bridgeToken
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.__souloReceiveUserScriptStorage?.(\(json));"
    }
    static func networkProgressScript(_ progress: UserScriptHTTPBridge.Progress, scriptID: UUID,
                                      requestID: String, bridgeToken: String) -> String? {
        let key = scriptID.uuidString + ":" + bridgeToken + ":" + requestID
        let value: [String: Any] = ["key": key, "event": progress.payload]
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "(()=>{const p=\(json), f=window.__souloUserScriptNetworkReceivers?.[p.key]; if(typeof f==='function')f(p.event); return true;})()"
    }
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
        var __souloStorage = Object.assign(Object.create(null), JSON.parse(\#(stringLiteral(storageLiteral))));
        var __souloResources = Object.assign(Object.create(null), JSON.parse(\#(stringLiteral(resourcesLiteral))));
        var __souloGM = {};
        var GM_info = JSON.parse(\#(stringLiteral(infoLiteral)));
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
            if (typeof encoded !== 'string' || !Object.prototype.hasOwnProperty.call(JSON.parse(encoded), 'value')) {
                throw new TypeError('Value is not JSON serializable');
            }
            return encoded;
        }
        var __souloCommittedStorage = Object.assign(Object.create(null), __souloStorage);
        var __souloPendingStorage = [];
        var __souloStorageRevision = -1, __souloNextMutation = 0;
        function __souloApplyStorage(target, changes) {
            Object.keys(changes).forEach(function(key) {
                if (changes[key] === null) delete target[key];
                else target[key] = changes[key];
            });
        }
        function __souloRefreshStorage(remote) {
            while (__souloPendingStorage.length && __souloPendingStorage[0].state !== 'pending') {
                var finished = __souloPendingStorage.shift();
                if (finished.state === 'committed' && finished.nativeRevision == null) __souloApplyStorage(__souloCommittedStorage, finished.changes);
            }
            var next = Object.assign(Object.create(null), __souloCommittedStorage);
            __souloPendingStorage.forEach(function(entry) {
                if (entry.state !== 'failed' && entry.nativeRevision == null) __souloApplyStorage(next, entry.changes);
            });
            var previous = __souloStorage;
            __souloStorage = next;
            var keys = Object.keys(Object.assign(Object.create(null), previous, next));
            keys.forEach(function(key) {
                if (JSON.stringify(previous[key]) !== JSON.stringify(next[key])) {
                    __souloNotifyValueListeners(key, previous[key] && previous[key].value, next[key] && next[key].value, remote);
                }
            });
        }
        function __souloReceiveStorage(snapshot) {
            if (!snapshot || typeof snapshot.revision !== 'number' || !snapshot.values) return false;
            if (snapshot.origin === '\#(bridgeToken.escapedForJS)') {
                __souloPendingStorage.forEach(function(entry) {
                    if (entry.id === snapshot.mutationID) { entry.state = 'committed'; entry.nativeRevision = snapshot.revision; }
                });
            }
            if (snapshot.revision >= __souloStorageRevision) {
                var next = Object.create(null);
                Object.keys(snapshot.values).forEach(function(key) {
                    try { next[key] = JSON.parse(snapshot.values[key]); } catch (_) {}
                });
                __souloCommittedStorage = next;
                __souloStorageRevision = snapshot.revision;
            }
            __souloRefreshStorage(snapshot.origin !== '\#(bridgeToken.escapedForJS)');
            return true;
        }
        var __souloStorageReceivers = window.__souloUserScriptStorageReceivers;
        if (!__souloStorageReceivers) {
            __souloStorageReceivers = Object.create(null);
            Object.defineProperty(window, '__souloUserScriptStorageReceivers', {value:__souloStorageReceivers,configurable:true});
        }
        __souloStorageReceivers['\#(script.id.uuidString)'] = function(snapshot) {
            if (snapshot.token === '\#(bridgeToken.escapedForJS)') __souloReceiveStorage(snapshot);
        };
        window.__souloReceiveUserScriptStorage = function(snapshot) {
            var receiver = snapshot && __souloStorageReceivers[snapshot.scriptID];
            if (typeof receiver === 'function') receiver(snapshot);
        };
        function __souloMutateStorage(action, payload, changes) {
            if (!Object.keys(changes).length) return Promise.resolve(true);
            var entry = { id: String(++__souloNextMutation), state: 'pending', changes: changes };
            payload.__souloMutationID = entry.id;
            __souloPendingStorage.push(entry);
            __souloRefreshStorage();
            var request;
            try { request = Promise.resolve(__souloBridge(action, payload)); }
            catch (error) { request = Promise.reject(error); }
            return request.then(function(result) {
                entry.state = 'committed';
                if (result && typeof result.revision === 'number') {
                    entry.nativeRevision = result.revision;
                    __souloReceiveStorage(result);
                }
                __souloRefreshStorage();
                return result;
            }, function(error) {
                entry.state = 'failed';
                __souloRefreshStorage();
                throw error;
            });
        }
        function __souloSetValue(key, value) {
            key = String(key);
            var encoded = __souloEncodeValue(value);
            var changes = Object.create(null);
            changes[key] = JSON.parse(encoded);
            return __souloMutateStorage('setValue', { key: key, value: encoded }, changes);
        }
        function __souloDeleteValue(key) {
            key = String(key);
            var changes = Object.create(null);
            changes[key] = null;
            return __souloMutateStorage('deleteValue', { key: key }, changes);
        }
        function __souloGetValues(keysOrDefaults) {
            var result = Object.create(null);
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
            var encodedValues = Object.create(null);
            var changes = Object.create(null);
            Object.keys(values).forEach(function(key) {
                encodedValues[key] = __souloEncodeValue(values[key]);
                changes[key] = JSON.parse(encodedValues[key]);
            });
            return __souloMutateStorage('setValues', { values: encodedValues }, changes);
        }
        function __souloDeleteValues(keys) {
            keys = Array.isArray(keys) ? keys.map(String) : [];
            var changes = Object.create(null);
            keys.forEach(function(key) { changes[key] = null; });
            return __souloMutateStorage('deleteValues', { keys: keys }, changes);
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
            var requestID = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
            var finished = false, resolveDownload, rejectDownload;
            var promise = new Promise(function(resolve, reject) { resolveDownload = resolve; rejectDownload = reject; });
            // Legacy callers receive a handle rather than the Promise.
            promise.catch(function() {});
            function callback(name, event) {
                try { if (typeof details[name] === 'function') details[name](event); }
                catch (error) { console.error(error); }
            }
            __souloBridge('download', {
                __souloDownloadID: requestID,
                url: new URL(String(details.url || ''), location.href).href,
                name: details.name == null ? '' : String(details.name)
            }).then(function(result) {
                if (finished) return;
                finished = true;
                resolveDownload(result);
                callback('onload', result);
            }).catch(function(error) {
                if (finished) return;
                finished = true;
                rejectDownload(error);
                callback('onerror', error);
            });
            function abort() {
                if (finished) return;
                finished = true;
                var error = { error: 'aborted' };
                __souloBridge('abortDownload', { __souloDownloadID: requestID }).catch(console.error);
                rejectDownload(error);
                callback('onabort', error);
                callback('onerror', error);
            }
            promise.abort = abort;
            return { abort: abort, promise: promise };
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

        function __souloBase64Blob(value, mimeType) {
            var binary = atob(value || '');
            var bytes = new Uint8Array(binary.length);
            for (var index = 0; index < binary.length; index += 1) {
                bytes[index] = binary.charCodeAt(index);
            }
            return new Blob([bytes], { type: mimeType || 'application/octet-stream' });
        }

        var __souloPendingHTTP = Object.create(null);
        var __souloNetworkReceivers = window.__souloUserScriptNetworkReceivers;
        if (!__souloNetworkReceivers) {
            __souloNetworkReceivers = Object.create(null);
            Object.defineProperty(window, '__souloUserScriptNetworkReceivers', {value:__souloNetworkReceivers,configurable:true});
        }
        if (typeof window.addEventListener === 'function') window.addEventListener('pagehide', function() {
            Object.keys(__souloPendingHTTP).forEach(function(key) { __souloPendingHTTP[key](); });
        }, {once:true});
        function __souloXMLHTTP(details, modern) {
            details = details || {};
            var finished = false, uploadStarted = false, uploadFinished = false, readyState = 1;
            var resolveRequest, rejectRequest;
            var promise = new Promise(function(resolve, reject) { resolveRequest = resolve; rejectRequest = reject; });
            if (!modern) promise.catch(function() {});
            var bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.souloUserScriptXHR;
            var requestID = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
            var receiverKey = '\#(script.id.uuidString):\#(bridgeToken.escapedForJS):' + requestID;
            function callback(name, event, target) {
                event.context = details.context;
                try { var owner = target || details; if (typeof owner[name] === 'function') owner[name](event); }
                catch (error) { console.error(error); }
            }
            function cleanup() { delete __souloNetworkReceivers[receiverKey]; delete __souloPendingHTTP[requestID]; }
            function fail(error, type) {
                if (finished) return;
                finished = true; cleanup();
                var event = { readyState: 4, status: 0, loaded: 0, total: 0, lengthComputable: false, error: String(error), type: type || 'error' };
                var handler = type === 'abort' ? 'onabort' : type === 'timeout' ? 'ontimeout' : 'onerror';
                if (details.upload && uploadStarted && !uploadFinished) {
                    uploadFinished = true; callback(handler, event, details.upload); callback('onloadend', event, details.upload);
                }
                callback('onreadystatechange', event); callback(handler, event); callback('onloadend', event);
                rejectRequest(event);
            }
            var payload = {
                __souloToken: '\#(bridgeToken.escapedForJS)', __souloScriptID: '\#(script.id.uuidString)', __souloRequestID: requestID,
                url: String(details.url || ''), method: String(details.method || 'GET'), headers: Object.assign({}, details.headers || {}),
                data: null, timeout: Number(details.timeout || 30_000), responseType: String(details.responseType || '').toLowerCase(),
                anonymous: details.anonymous === true, cookie: typeof details.cookie === 'string' ? details.cookie : null
            };
            function abort() {
                if (finished) return;
                fail('Request aborted', 'abort');
                if (bridge && typeof bridge.postMessage === 'function') {
                    bridge.postMessage({__souloToken: payload.__souloToken, __souloScriptID: payload.__souloScriptID,
                        __souloRequestID: requestID, action: 'abort'}).catch(console.error);
                }
            }
            promise.abort = abort;
            if (!bridge || typeof bridge.postMessage !== 'function') {
                fail('Soulo UserScript network bridge is unavailable');
                return modern ? promise : { abort: abort };
            }
            if (Object.keys(__souloPendingHTTP).length >= \#(UserScriptHTTPBridge.maximumConcurrentRequests)) {
                fail('Too many concurrent UserScript requests'); return modern ? promise : {abort:abort};
            }
            __souloPendingHTTP[requestID] = abort;
            __souloNetworkReceivers[receiverKey] = function(event) {
                if (finished || !event) return;
                if (event.kind === 'upload') {
                    if (!details.upload) return;
                    if (!uploadStarted) { uploadStarted = true; callback('onloadstart', event, details.upload); }
                    callback('onprogress', event, details.upload);
                    if (!uploadFinished && event.lengthComputable && event.loaded >= event.total) {
                        uploadFinished = true; callback('onload', event, details.upload); callback('onloadend', event, details.upload);
                    }
                } else {
                    if (readyState !== event.readyState) { readyState = event.readyState; callback('onreadystatechange', event); }
                    if (event.kind === 'download') callback('onprogress', event);
                }
            };
            function binaryBody(buffer) {
                var bytes = new Uint8Array(buffer);
                if (bytes.byteLength > \#(UserScriptHTTPBridge.maximumUploadSize)) throw new Error('UserScript upload exceeds 8 MiB');
                var parts = [];
                for (var at = 0; at < bytes.length; at += 8192) parts.push(String.fromCharCode.apply(null, bytes.subarray(at, at + 8192)));
                payload.dataBase64 = btoa(parts.join(''));
            }
            function prepareBody() {
                var data = details.data;
                if (data == null || /^(GET|HEAD)$/i.test(payload.method)) return null;
                if (typeof FormData !== 'undefined' && data instanceof FormData) {
                    var estimated = 0, fields = 0;
                    data.forEach(function(value, name) {
                        estimated += (typeof Blob !== 'undefined' && value instanceof Blob) ? value.size : new Blob([String(value)]).size;
                        estimated += String(name).length * 3 + 512;
                        if (++fields > 1024 || estimated > \#(UserScriptHTTPBridge.maximumUploadSize)) throw new Error('UserScript upload exceeds 8 MiB');
                    });
                    var response = new Response(data);
                    if (!Object.keys(payload.headers).some(function(k) { return k.toLowerCase() === 'content-type'; }))
                        payload.headers['Content-Type'] = response.headers.get('Content-Type');
                    return response.arrayBuffer().then(binaryBody);
                }
                if (typeof Blob !== 'undefined' && data instanceof Blob) {
                    if (data.size > \#(UserScriptHTTPBridge.maximumUploadSize)) throw new Error('UserScript upload exceeds 8 MiB');
                    if (data.type && !Object.keys(payload.headers).some(function(k) { return k.toLowerCase() === 'content-type'; })) payload.headers['Content-Type'] = data.type;
                    return data.arrayBuffer().then(binaryBody);
                }
                if (typeof ArrayBuffer !== 'undefined' && data instanceof ArrayBuffer) { binaryBody(data); return null; }
                if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView(data)) {
                    if (data.byteLength > \#(UserScriptHTTPBridge.maximumUploadSize)) throw new Error('UserScript upload exceeds 8 MiB');
                    binaryBody(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)); return null;
                }
                if (details.binary) {
                    var text = String(data);
                    if (text.length > \#(UserScriptHTTPBridge.maximumUploadSize)) throw new Error('UserScript upload exceeds 8 MiB');
                    var bytes = new Uint8Array(text.length);
                    for (var i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 255;
                    binaryBody(bytes.buffer); return null;
                }
                payload.data = String(data);
                if (payload.data.length > \#(UserScriptHTTPBridge.maximumUploadSize)) throw new Error('UserScript upload exceeds 8 MiB');
                return null;
            }
            function send() {
                if (finished) return;
                bridge.postMessage(payload).then(function(result) {
                    if (finished) return;
                    if (result.__souloErrorType) { fail(result.message || result.__souloErrorType, result.__souloErrorType); return; }
                    var responseText = result.responseText || '', response = responseText;
                    if (payload.responseType === 'blob') response = __souloBase64Blob(result.base64, result.mimeType);
                    else if (payload.responseType === 'arraybuffer') {
                        var binary = atob(result.base64 || ''), bytes = new Uint8Array(binary.length);
                        for (var index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
                        response = bytes.buffer;
                    } else if (payload.responseType === 'json') {
                        try { response = JSON.parse(responseText); } catch (_) { response = null; }
                    }
                    var event = {readyState:4, status:result.status || 0, statusText:result.statusText || '',
                        finalUrl:result.finalURL || payload.url, responseHeaders:result.responseHeaders || '', responseText:responseText, response:response};
                    if (details.upload && !uploadFinished && result.uploadedBytes > 0) {
                        var sent = {loaded:result.uploadedBytes,total:result.uploadTotal || result.uploadedBytes,lengthComputable:true};
                        if (!uploadStarted) { uploadStarted = true; callback('onloadstart', sent, details.upload); }
                        callback('onprogress', sent, details.upload);
                        if (sent.loaded >= sent.total) { uploadFinished = true; callback('onload', sent, details.upload); callback('onloadend', sent, details.upload); }
                    }
                    finished = true; cleanup();
                    callback('onreadystatechange', event); callback('onload', event); callback('onloadend', event); resolveRequest(event);
                }).catch(function(error) { fail(error); });
            }
            callback('onloadstart', {readyState:1});
            try { var prepared = prepareBody(); if (prepared && typeof prepared.then === 'function') prepared.then(send).catch(function(e) { fail(e); }); else send(); }
            catch (error) { fail(error); }
            return modern ? promise : {abort:abort};
        }
        \#(allowsXHR ? "var GM_xmlhttpRequest = function(details) { return __souloXMLHTTP(details, false); }; __souloGM.xmlHttpRequest = function(details) { return __souloXMLHTTP(details, true); };" : "")
        var GM = Object.freeze(__souloGM);
        \#((allowsGetValue || allowsGetValues || allowsListValues || allowsAddValueListener) ? "__souloBridge('getStorageSnapshot').then(__souloReceiveStorage).catch(console.error);" : "")
        """#
    }

    static func wrappedSource(for script: UserScriptRecord, bridgeToken: String = "") -> String {
        guard script.hasResolvedRequirements else {
            return sourcePrefix + "console.error('Soulo UserScript: @require dependencies are not ready');"
        }
        // Newlines prevent trailing // comments or source maps in a dependency
        // from swallowing the next file. All files share the script's scope.
        let dependencies = (script.requiredURLs ?? []).compactMap { script.requiredSources?[$0] }
            .map { $0 + "\n;\n" }.joined()
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
        function __souloReportScriptError(error) {
            try {
                var message = String(error && (error.message || error) || error);
                var stack = String(error && error.stack || '');
                if (stack && stack.indexOf(message) === -1) message += '\\n' + stack;
                window.webkit.messageHandlers.souloUserScriptAPI.postMessage({
                    __souloToken: '\(bridgeToken.escapedForJS)', __souloScriptID: '\(script.id.uuidString)',
                    action: 'reportError', message: message.slice(0,2000)
                }).catch(function() {});
            } catch (_) {}
        }
        function __souloRunUserScript() {
            try {
                \(compatibility)
                \(dependencies)
                \(script.source)
            } catch (error) {
                console.error('Soulo UserScript \(script.name.escapedForJS):', error);
                __souloReportScriptError(error);
            }
        }
        window.addEventListener?.('error', function(event) {
            if (String(event.error && event.error.stack || event.filename || '').includes('soulo-userscript-\(script.id.uuidString)')) __souloReportScriptError(event.error || event.message);
        });
        window.addEventListener?.('unhandledrejection', function(event) {
            if (String(event.reason && event.reason.stack || '').includes('soulo-userscript-\(script.id.uuidString)')) __souloReportScriptError(event.reason);
        });
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
        \(sourcePrefix)(function() {
            var __souloURL = String(window.location.href || '');
            if (__souloURL.toLowerCase().indexOf('http://') !== 0 && __souloURL.toLowerCase().indexOf('https://') !== 0) return;
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

    private static func stringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
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
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppConstants.appVersion,
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

struct UserScriptDownloadPolicy: Codable, Equatable, Sendable {
    let connectDomains: [String]
    let pageURL: String?

    init(script: UserScriptRecord, pageURL: URL?) {
        self.connectDomains = script.connectDomains ?? []
        self.pageURL = pageURL?.absoluteString
    }

    func allows(_ url: URL) -> Bool {
        UserScriptHTTPBridge.isAllowedTarget(
            url, script: UserScriptRecord(name: "Download", source: "", connectDomains: connectDomains),
            pageURL: pageURL.flatMap(URL.init(string:))
        )
    }
}

/// Register before dispatching an async bridge action so an immediate abort
/// also cancels downloads whose transport has not been created yet.
@MainActor
final class UserScriptDownloadRequests {
    private struct Request {
        var itemID: UUID?
        var isCanceled = false
    }
    private var requests: [String: Request] = [:]

    func begin(_ key: String) -> Bool {
        guard requests[key] == nil, requests.count < 64 else { return false }
        requests[key] = Request()
        return true
    }

    func attach(_ itemID: UUID, to key: String) -> Bool {
        guard let request = requests[key], !request.isCanceled else { return false }
        requests[key]?.itemID = itemID
        return true
    }

    func cancel(_ key: String) -> UUID? {
        guard var request = requests[key], !request.isCanceled else { return nil }
        request.isCanceled = true
        requests[key] = request
        return request.itemID
    }

    @discardableResult
    func finish(_ key: String) -> UUID? {
        requests.removeValue(forKey: key)?.itemID
    }
}

enum UserScriptHTTPBridge {
    static let maximumResponseSize = 20 * 1_024 * 1_024
    static let maximumUploadSize = 8 * 1_024 * 1_024
    static let maximumConcurrentRequests = 8
    struct Progress: Sendable {
        enum Kind: String, Sendable { case headers, download, upload }
        let kind: Kind
        let loaded: Int64
        let total: Int64
        var status = 0
        var finalURL = ""
        var responseHeaders = ""
        var payload: [String: Any] {
            ["kind": kind.rawValue, "loaded": loaded, "total": max(total, 0),
             "lengthComputable": total >= 0, "status": status, "finalUrl": finalURL,
             "responseHeaders": responseHeaders, "readyState": kind == .headers ? 2 : 3]
        }
    }
    private static let allowedMethods = Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
    private static let forbiddenHeaders = Set(["cookie", "host", "content-length", "origin"])

    static func response(
        for body: [String: Any],
        script: UserScriptRecord,
        pageURL: URL?,
        configuration: URLSessionConfiguration = .ephemeral,
        includesBinaryResponseText: Bool = false,
        onProgress: (@Sendable (Progress) async -> Void)? = nil
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
        request.timeoutInterval = requestedTimeout.isFinite ? min(max(requestedTimeout / 1_000, 1), 60) : 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let headers = body["headers"] as? [String: Any] {
            for (name, value) in headers {
                guard !forbiddenHeaders.contains(name.lowercased()) else { continue }
                request.setValue(String(describing: value), forHTTPHeaderField: name)
            }
        }
        if method != "GET", method != "HEAD" {
            if let encoded = body["dataBase64"] as? String {
                guard encoded.utf8.count <= ((maximumUploadSize + 2) / 3) * 4,
                      let data = Data(base64Encoded: encoded), data.count <= maximumUploadSize else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                request.httpBody = data
            } else if let text = body["data"] as? String {
                guard text.utf8.count <= maximumUploadSize else { throw URLError(.dataLengthExceedsMaximum) }
                request.httpBody = Data(text.utf8)
            }
        }
        let explicitCookie = body["cookie"] as? String
        if let cookie = explicitCookie, !cookie.isEmpty, body["anonymous"] as? Bool != true {
            guard script.hasGrant("GM_cookie", "GM.cookie"), cookie.utf8.count <= 16 * 1_024,
                  cookie.rangeOfCharacter(from: .controlCharacters) == nil else { throw URLError(.noPermissionsToReadFile) }
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        // A slowly trickling server must not retain a request slot forever.
        // URLRequest's timeout alone can reset whenever more bytes arrive.
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let redirectDelegate = UserScriptURLSessionDelegate(script: script, pageURL: pageURL,
            cookieOrigin: url, cookie: request.value(forHTTPHeaderField: "Cookie"), onProgress: onProgress)
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(maximumResponseSize)
                || response.expectedContentLength == NSURLSessionTransferSizeUnknown else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let responseHeaders = http.allHeaderFields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\r\n")
        await onProgress?(Progress(kind: .headers, loaded: 0, total: response.expectedContentLength,
            status: http.statusCode, finalURL: http.url?.absoluteString ?? rawURL, responseHeaders: responseHeaders))
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        var lastProgress = ProcessInfo.processInfo.systemUptime
        var reportedBytes = 0
        for try await byte in bytes {
            guard data.count < maximumResponseSize else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
            if onProgress != nil, data.count & 0x3fff == 0 {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastProgress >= 0.2 {
                    await onProgress?(Progress(kind: .download, loaded: Int64(data.count), total: response.expectedContentLength,
                        status: http.statusCode, finalURL: http.url?.absoluteString ?? rawURL))
                    lastProgress = now; reportedBytes = data.count
                }
            }
        }
        if reportedBytes != data.count {
            await onProgress?(Progress(kind: .download, loaded: Int64(data.count), total: response.expectedContentLength,
                status: http.statusCode, finalURL: http.url?.absoluteString ?? rawURL))
        }

        let binary = ["blob", "arraybuffer"].contains((body["responseType"] as? String)?.lowercased() ?? "")
        let responseText = binary && !includesBinaryResponseText ? "" : String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        var result: [String: Any] = [
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "finalURL": http.url?.absoluteString ?? rawURL,
            "responseHeaders": responseHeaders,
            "uploadedBytes": bytes.task.countOfBytesSent,
            "uploadTotal": max(bytes.task.countOfBytesExpectedToSend, bytes.task.countOfBytesSent),
            "responseText": responseText,
            "mimeType": http.mimeType ?? "application/octet-stream"
        ]
        if binary {
            result["base64"] = data.base64EncodedString()
        }
        return result
    }

    static func resourceResponse(
        named name: String, script: UserScriptRecord, pageURL: URL?,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> [String: Any] {
        guard let declaration = script.resources?[name],
              let url = URL(string: declaration, relativeTo: script.sourceURL.flatMap(URL.init(string:)))?.absoluteURL,
              url.scheme != nil else { throw URLError(.unsupportedURL) }
        let result = try await response(
            for: ["url": url.absoluteString, "method": "GET", "timeout": 30_000, "responseType": "arraybuffer"],
            script: script, pageURL: pageURL, configuration: configuration, includesBinaryResponseText: true
        )
        guard let status = result["status"] as? Int, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
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
            .components(separatedBy: "%").first!
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleanHost == "localhost" || cleanHost.hasSuffix(".localhost") || cleanHost.hasSuffix(".local") { return true }
        var ipv4 = in_addr()
        // inet_aton also recognizes integer, hexadecimal and abbreviated IPv4.
        if inet_aton(cleanHost, &ipv4) == 1 { return isPrivateIPv4(UInt32(bigEndian: ipv4.s_addr)) }
        guard cleanHost.contains(":") else { return false }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, cleanHost, &ipv6) == 1 else { return true }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.allSatisfy({ $0 == 0 }) || (bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1)
            || bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
        let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        let compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
        if mapped || compatible {
            let address = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return isPrivateIPv4(address)
        }
        return false
    }

    private static func isPrivateIPv4(_ value: UInt32) -> Bool {
        let first = value >> 24, second = (value >> 16) & 0xff
        return [0, 10, 127].contains(first) || first >= 224
            || (first == 169 && second == 254) || (first == 192 && second == 168)
            || (first == 172 && (16...31).contains(second)) || (first == 100 && (64...127).contains(second))
    }

    static func cookieForRedirect(_ cookie: String?, from origin: URL, to destination: URL) -> String? {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        guard origin.scheme?.lowercased() == destination.scheme?.lowercased(),
              origin.host?.lowercased() == destination.host?.lowercased(), port(origin) == port(destination) else { return nil }
        return cookie
    }

}

private final class UserScriptURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let script: UserScriptRecord
    private let pageURL: URL?
    private let cookieOrigin: URL
    private let cookie: String?
    private let onProgress: (@Sendable (UserScriptHTTPBridge.Progress) async -> Void)?
    private let progressLock = NSLock()
    private var lastUploadProgress: TimeInterval = 0

    init(script: UserScriptRecord, pageURL: URL?, cookieOrigin: URL, cookie: String?,
         onProgress: (@Sendable (UserScriptHTTPBridge.Progress) async -> Void)?) {
        self.script = script
        self.pageURL = pageURL
        self.cookieOrigin = cookieOrigin; self.cookie = cookie; self.onProgress = onProgress
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
        var next = request
        next.setValue(UserScriptHTTPBridge.cookieForRedirect(cookie, from: cookieOrigin, to: redirectURL), forHTTPHeaderField: "Cookie")
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let onProgress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        progressLock.lock()
        let report = now - lastUploadProgress >= 0.2 || totalBytesSent == totalBytesExpectedToSend
        if report { lastUploadProgress = now }
        progressLock.unlock()
        if report {
            Task { await onProgress(.init(kind: .upload, loaded: totalBytesSent, total: totalBytesExpectedToSend)) }
        }
    }
}

enum UserScriptURLMatcher {
    static func matches(url: URL, patterns: [String]) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return patterns.contains { pattern in
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
    static let userScriptStorageChanged = Notification.Name("soulo.userScriptStorageChanged")
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

    private(set) static weak var existingShared: NativeWebExtensionRuntime?
    static let shared: NativeWebExtensionRuntime = {
        let runtime = NativeWebExtensionRuntime()
        existingShared = runtime
        return runtime
    }()

    let controller: WKWebExtensionController
    private let browserWindow = NativeExtensionWindow()
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var pendingLoads: [UUID: (revision: UUID, task: Task<Metadata, Error>)] = [:]
    private var contextResourceURLs: [ObjectIdentifier: URL] = [:]
    private weak var tabManager: TabManager?
    private var tabObservers: Set<AnyCancellable> = []
    private var retainedMessagePorts: [ObjectIdentifier: WKWebExtension.MessagePort] = [:]
    private let compatibilityHost = WebExtensionCompatibilityHost()
    private var accessSettings: [UUID: WebExtensionAccess] = [:]
    private var accessHandlers: [UUID: (WebExtensionAccess) -> Bool] = [:]
    private var permissionObservers: [UUID: [NSObjectProtocol]] = [:]

    private override init() {
        controller = WKWebExtensionController()
        super.init()
        controller.delegate = self
        browserWindow.runtime = self
    }

    func apply(to configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    // Includes extension backgrounds/popups/offscreen documents, not only
    // browser tabs. Their stores must not be erased by ordinary site cleanup.
    var hasLoadedExtensionContexts: Bool { !contexts.isEmpty || !pendingLoads.isEmpty }

    func clearTemporaryCaches(identifiers requested: Set<UUID>? = nil) async throws {
        let installed = Set(contexts.keys).union(BrowserExtensionService.shared.webExtensions.map(\.id))
        let identifiers: Set<UUID>
        if let requested {
            let storedOrigins = await WebsiteStorageService.entries().filter { $0.bytes?.isExtension == true }.compactMap { UUID(uuidString: $0.domain) }
            identifiers = installed.union(storedOrigins).intersection(requested)
        } else { identifiers = installed }
        guard !identifiers.isEmpty else { return }
        guard !DownloadManagerService.shared.downloads.contains(where: { [.inProgress, .paused].contains($0.status) }) else {
            throw WebExtensionTemporaryCacheError.inUse
        }
        let views = browserWindow.tabs.compactMap(\.webView)
        let busy = await withTaskGroup(of: Bool.self) { group in
            for view in views {
                group.addTask { @MainActor in
                    if view.url?.scheme == "webkit-extension" { return true }
                    return await WebExtensionTemporaryCacheProbe.hasExtensionFrames(in: view)
                }
            }
            for await result in group where result { return true }
            return false
        }
        guard !busy else { throw WebExtensionTemporaryCacheError.inUse }
        try await WebExtensionTemporaryCacheProbe.clear(identifiers: identifiers)
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
        guard !UserDefaults.standard.bool(forKey: "is_incognito"),
              webView.configuration.websiteDataStore.isPersistent else { return }
        compatibilityHost.userScripts.attach(webView.configuration.userContentController)
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

    var externalMessagingCompatibilityScript: String? {
        let identifiers = contexts.compactMap { id, context -> String? in
            guard let root = contextResourceURLs[ObjectIdentifier(context)], WebExtensionTYTYAdapter.isPrepared(in: root) else { return nil }
            return id.uuidString
        }
        guard identifiers.count == 1, let identifier = identifiers.first else { return nil }
        return WebExtensionTYTYAdapter.externalMessagingScript(nativeID: identifier)
    }

    func activate(_ webView: WKWebView) {
        guard let tab = browserWindow.tab(for: webView) else { return }
        activate(tab)
    }

    func unregister(_ webView: WKWebView) {
        compatibilityHost.userScripts.detach(webView)
        browserWindow.tab(for: webView)?.detachWebView()
    }

    private func synchronizeBrowserTabs() {
        guard let tabManager else { return }
        let previousOrder = browserWindow.tabs
        let publicTabs = UserDefaults.standard.bool(forKey: "is_incognito") ? [] : tabManager.tabs.filter {
            $0.webViewModel.webView?.configuration.websiteDataStore.isPersistent != false
        }
        let browserIDs = Set(publicTabs.map(\.id))
        for nativeTab in browserWindow.tabs.reversed()
            where nativeTab.browserTabID.map({ !browserIDs.contains($0) }) == true {
            closeNativeTab(nativeTab)
        }

        var orderedTabs: [NativeExtensionTab] = []
        for browserTab in publicTabs {
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
        guard !UserDefaults.standard.bool(forKey: "is_incognito"),
              let browserTabID = tabManager?.activeTab?.id,
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
    func load(id: UUID, resourceURL: URL, access: WebExtensionAccess? = nil,
              onAccessChange: ((WebExtensionAccess) -> Bool)? = nil) async throws -> Metadata {
        if let onAccessChange { accessHandlers[id] = onAccessChange }
        // A context is inserted before its asynchronous background finishes.
        // Every joining caller must await that same initialization task.
        if let pending = pendingLoads[id] { return try await pending.task.value }
        if let current = contexts[id] {
            if let access { applyAccess(access, id: id, context: current) }
            let extensionObject = current.webExtension
            return metadata(for: extensionObject)
        }
        let revision = UUID()
        let task = Task { @MainActor in try await self.loadContext(id: id, resourceURL: resourceURL, access: access) }
        pendingLoads[id] = (revision, task)
        defer { if pendingLoads[id]?.revision == revision { pendingLoads[id] = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func loadContext(id: UUID, resourceURL: URL, access: WebExtensionAccess?) async throws -> Metadata {
        try Task.checkCancellation()
        if try resourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            BrowserStartupTrace.mark("extension_prepare_start", detail: id.uuidString)
            try WebExtensionPackagePreparer.installCompatibilityLayer(in: resourceURL)
            BrowserStartupTrace.mark("extension_prepare_end", detail: id.uuidString)
        }

        let extensionObject: WKWebExtension
        BrowserStartupTrace.mark("extension_native_load_start", detail: id.uuidString)
        do {
            extensionObject = try await WKWebExtension(resourceBaseURL: resourceURL)
            BrowserStartupTrace.mark("extension_native_load_end", detail: id.uuidString)
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
        try Task.checkCancellation()

        let context = WKWebExtensionContext(for: extensionObject)
        context.uniqueIdentifier = id.uuidString
        context.baseURL = URL(string: "webkit-extension://" + id.uuidString.lowercased() + "/")!
        let manifestPermissions = (extensionObject.manifest["permissions"] as? [String] ?? []).filter { !$0.contains("://") && $0 != "<all_urls>" }
        let decisions = access ?? .requested(permissions: Array(Set(manifestPermissions + extensionObject.requestedPermissions.map { $0.rawValue })),
                                            sites: extensionObject.requestedPermissionMatchPatterns.map(\.string))
        applyAccess(decisions, id: id, context: context)
        try controller.load(context)
        contexts[id] = context
        contextResourceURLs[ObjectIdentifier(context)] = resourceURL
        compatibilityHost.userScripts.restore(context: context, resourceURL: resourceURL, access: accessSettings[id])
        observePermissions(id: id, context: context)
        // The content-script port needs its listeners installed before the first
        // document connects, including after disable/re-enable and app launch.
        if extensionObject.hasBackgroundContent {
            compatibilityHost.prepareInstallation(context: context)
            do {
                BrowserStartupTrace.mark("extension_background_start", detail: id.uuidString)
                try await WebExtensionBackgroundStartup.wait { completion in context.loadBackgroundContent(completionHandler: completion) }
                BrowserStartupTrace.mark("extension_background_ready", detail: id.uuidString)
                try Task.checkCancellation()
            } catch {
                BrowserStartupTrace.mark("extension_background_error", detail: "\(id.uuidString):\(context.errors.map(\.localizedDescription).joined(separator: ";"))")
                if contexts[id] === context { unload(id: id) }
                throw error
            }
        }
        return metadata(for: extensionObject)
    }

    func applyAccess(_ access: WebExtensionAccess, id: UUID, context supplied: WKWebExtensionContext? = nil) {
        let policyChanged = accessSettings[id] != access
        accessSettings[id] = access
        guard let context = supplied ?? contexts[id] else { return }
        let recognized = Set(context.webExtension.requestedPermissions.union(context.webExtension.optionalPermissions).map(\.rawValue))
        let granted = Dictionary(uniqueKeysWithValues: access.permissions.filter { recognized.contains($0.key) }.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
        let deniedPermissions = Dictionary(uniqueKeysWithValues: access.deniedPermissions.filter { recognized.contains($0.key) }.map { (WKWebExtension.Permission(rawValue: $0.key), $0.value) })
        let sites: [WKWebExtension.MatchPattern: Date] = Dictionary(access.sites.compactMap { key, date in
            guard let pattern = try? WKWebExtension.MatchPattern(string: key), !Self.isBlocked(pattern, by: access) else { return nil }
            return (pattern, date)
        }, uniquingKeysWith: { a, _ in a })
        var denied = access.deniedSites
        for host in access.blockedHosts {
            denied["*://\(host)/*"] = .distantFuture
            denied["*://*.\(host)/*"] = .distantFuture
        }
        let deniedSites = Dictionary(denied.compactMap { key, date in
            (try? WKWebExtension.MatchPattern(string: key)).map { ($0, date) }
        }, uniquingKeysWith: { a, _ in a })
        // Even assigning an identical dictionary emits native permission
        // notifications and removes/reinjects content scripts. A rejected
        // persistence update could otherwise feed its own rollback forever.
        var nativeChanged = false
        if context.grantedPermissions != granted { context.grantedPermissions = granted; nativeChanged = true }
        if context.deniedPermissions != deniedPermissions { context.deniedPermissions = deniedPermissions; nativeChanged = true }
        if context.grantedPermissionMatchPatterns != sites { context.grantedPermissionMatchPatterns = sites; nativeChanged = true }
        if context.deniedPermissionMatchPatterns != deniedSites { context.deniedPermissionMatchPatterns = deniedSites; nativeChanged = true }
        if policyChanged || nativeChanged { compatibilityHost.refreshAccess(access, context: context) }
    }

    private func observePermissions(id: UUID, context: WKWebExtensionContext) {
        // WebKit can also change grants via permissions.remove(). Capture the
        // complete dictionaries after its notification transaction finishes.
        let notifications: [Notification.Name] = [WKWebExtensionContext.permissionsWereGrantedNotification,
            WKWebExtensionContext.permissionsWereDeniedNotification, WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionsWereRemovedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
            WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification,
            WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
            WKWebExtensionContext.deniedPermissionMatchPatternsWereRemovedNotification]
        permissionObservers[id] = notifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: context, queue: .main) { [weak self, weak context] _ in
                Task { @MainActor in
                    guard let self, let context, self.contexts[id] === context,
                          var access = self.accessSettings[id] else { return }
                    let recognized = Set(context.webExtension.requestedPermissions.union(context.webExtension.optionalPermissions).map(\.rawValue))
                    access.permissions = access.permissions.filter { !recognized.contains($0.key) }
                        .merging(Dictionary(uniqueKeysWithValues: context.grantedPermissions.map { ($0.key.rawValue, $0.value) })) { _, new in new }
                    access.deniedPermissions = access.deniedPermissions.filter { !recognized.contains($0.key) }
                        .merging(Dictionary(uniqueKeysWithValues: context.deniedPermissions.map { ($0.key.rawValue, $0.value) })) { _, new in new }
                    let blockedGrant = context.grantedPermissionMatchPatterns.keys.contains { Self.isBlocked($0, by: access) }
                    access.sites = Dictionary(uniqueKeysWithValues: context.grantedPermissionMatchPatterns
                        .filter { !Self.isBlocked($0.key, by: access) }.map { ($0.key.string, $0.value) })
                    access.deniedSites = Dictionary(uniqueKeysWithValues: context.deniedPermissionMatchPatterns.map { ($0.key.string, $0.value) })
                    for host in access.blockedHosts {
                        for pattern in ["*://\(host)/*", "*://*.\(host)/*"]
                        where self.accessSettings[id]?.deniedSites[pattern] == nil { access.deniedSites[pattern] = nil }
                    }
                    let missingBlock = access.blockedHosts.contains { host in
                        ["https://\(host)/", "http://\(host)/", "https://sub.\(host)/"].contains {
                            URL(string: $0).map { context.hasAccess(to: $0) } == true
                        }
                    }
                    guard access != self.accessSettings[id] else {
                        if blockedGrant || missingBlock { self.applyAccess(access, id: id) }
                        return
                    }
                    if self.accessHandlers[id]?(access) != false {
                        self.accessSettings[id] = access
                        if blockedGrant || missingBlock { self.applyAccess(access, id: id) }
                    }
                    else if let previous = self.accessSettings[id] { self.applyAccess(previous, id: id) }
                }
            }
        }
    }

    private static func isBlocked(_ pattern: WKWebExtension.MatchPattern, by access: WebExtensionAccess) -> Bool {
        guard let host = pattern.host, host != "*" else { return false }
        let base = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        return URL(string: "https://" + base + "/").map(access.blocks) == true
    }

    private func saveDecision(_ context: WKWebExtensionContext, permissions: [String] = [], sites: [String] = [], allowed: Bool) -> Bool {
        guard let id = UUID(uuidString: context.uniqueIdentifier), contexts[id] === context,
              var access = accessSettings[id] else { return false }
        for name in permissions { access.setPermission(name, allowed: allowed) }
        for pattern in sites { access.setSite(pattern, allowed: allowed) }
        guard accessHandlers[id]?(access) != false else { return false }
        applyAccess(access, id: id)
        return true
    }

    func diagnostics(id: UUID) -> [String] {
        guard let context = contexts[id] else { return [] }
        var errors = context.errors.map(\.localizedDescription)
        if context.webExtension.manifest["commands"] != nil { errors.append("commands") }
        return errors
    }

    func commands(id: UUID) -> [WebExtensionCommandPresentation] {
        guard !UserDefaults.standard.bool(forKey: "is_incognito"), let context = contexts[id] else { return [] }
        return context.commands.filter { !$0.id.hasPrefix("_execute_") && !$0.title.isEmpty }
            .map { WebExtensionCommandPresentation(id: $0.id, title: $0.title) }
    }

    @discardableResult
    func performCommand(_ identifier: String, id: UUID) -> Bool {
        guard !UserDefaults.standard.bool(forKey: "is_incognito"), let context = contexts[id],
              let command = context.commands.first(where: { $0.id == identifier }) else { return false }
        browserWindow.tabs.forEach { $0.refreshMediaState() }
        context.performCommand(command)
        return true
    }

    func actionPresentation(id: UUID) -> WebExtensionActionPresentation? {
        guard !UserDefaults.standard.bool(forKey: "is_incognito"), let context = contexts[id] else { return nil }
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
        guard !UserDefaults.standard.bool(forKey: "is_incognito"), let context = contexts[id] else { return false }
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
        WebExtensionPopupPresenter.dismissPopup(ownedBy: id)
        pendingLoads.removeValue(forKey: id)?.task.cancel()
        permissionObservers.removeValue(forKey: id)?.forEach { NotificationCenter.default.removeObserver($0) }
        accessSettings[id] = nil
        accessHandlers[id] = nil
        guard let context = contexts.removeValue(forKey: id) else { return }
        contextResourceURLs.removeValue(forKey: ObjectIdentifier(context))
        compatibilityHost.remove(context: context)
        try? controller.unload(context)
    }

    func forgetCompatibilityInstallation(id: UUID) { compatibilityHost.forgetInstallation(id: id) }

    fileprivate func browserTab(for nativeTab: NativeExtensionTab) -> BrowserTab? {
        guard let id = nativeTab.browserTabID else { return nil }
        return tabManager?.tabs.first { $0.id == id }
    }

    fileprivate func createBrowserTab(
        url: URL?,
        active: Bool,
        parent: NativeExtensionTab? = nil
    ) throws -> NativeExtensionTab {
        guard !UserDefaults.standard.bool(forKey: "is_incognito") else {
            throw NativeWebExtensionHostError.unsupported("private extension tabs")
        }
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

    /// Keep tabs.update's native tab identity attached to its destination.
    /// The source becomes a separate browser tab with its original live WKWebView.
    fileprivate func openExtensionDocument(_ url: URL, from nativeTab: NativeExtensionTab) throws {
        guard let manager = tabManager, let sourceID = nativeTab.browserTabID,
              manager.tabs.contains(where: { $0.id == sourceID }) else {
            throw NativeWebExtensionHostError.tabUnavailable
        }
        let target = manager.createTab(url: url)
        nativeTab.detachWebView()
        nativeTab.browserTabID = target.id
        target.webViewModel.returnToSourceTab = { [weak manager] in
            guard let manager, manager.tabs.contains(where: { $0.id == sourceID }) else { return false }
            manager.switchToTab(id: sourceID)
            return true
        }
        synchronizeBrowserTabs()
    }

    fileprivate func activateBrowserTab(_ nativeTab: NativeExtensionTab) throws {
        guard let id = nativeTab.browserTabID,
              let index = tabManager?.tabs.firstIndex(where: { $0.id == id }),
              let tabManager else { throw NativeWebExtensionHostError.tabUnavailable }
        tabManager.switchToTab(at: index, userInitiated: false)
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
            guard let allowed else { completionHandler([], nil); return }
            let saved = self.saveDecision(context, permissions: permissions.map(\.rawValue), allowed: allowed)
            completionHandler(saved && allowed ? permissions : [], saved && allowed ? .distantFuture : nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let access = UUID(uuidString: context.uniqueIdentifier).flatMap { accessSettings[$0] }
        let eligible = Set(urls.filter {
            let status = context.permissionStatus(for: $0)
            return access?.blocks($0) != true && status != .deniedExplicitly && status != .deniedImplicitly
        })
        guard !eligible.isEmpty else { completionHandler([], nil); return }
        // CORS retries can ask for URLs whose host permission is already granted.
        // Reuse that decision without renewing its expiration or prompting again.
        let existing = Self.existingURLAccess(eligible, context: context)
        let pending = eligible.subtracting(existing.urls)
        guard !pending.isEmpty else { completionHandler(existing.urls, existing.expiration); return }
        WebExtensionPermissionPrompter.confirm(
            extensionName: context.webExtension.displayName,
            items: pending.map(\.absoluteString).sorted()
        ) { allowed in
            let currentAccess = UUID(uuidString: context.uniqueIdentifier).flatMap { self.accessSettings[$0] }
            let stillApproved = Self.existingURLAccess(Set(existing.urls.filter { currentAccess?.blocks($0) != true }), context: context)
            guard let allowed else { completionHandler(stillApproved.urls, stillApproved.expiration); return }
            // A concurrent settings change wins over the older permission dialog.
            guard currentAccess == access else { completionHandler(stillApproved.urls, stillApproved.expiration); return }
            let patterns = pending.compactMap { url -> String? in
                guard let host = url.host else { return nil }; return "\(url.scheme ?? "https")://\(host)/*"
            }
            let saved = self.saveDecision(context, sites: patterns, allowed: allowed)
            let newlyAllowed = saved && allowed ? pending : []
            completionHandler(stillApproved.urls.union(newlyAllowed), stillApproved.expiration ?? (newlyAllowed.isEmpty ? nil : .distantFuture))
        }
    }

    static func existingURLAccess(_ urls: Set<URL>, context: WKWebExtensionContext,
                                  now: Date = Date()) -> (urls: Set<URL>, expiration: Date?) {
        var approved = Set<URL>(), expiration: Date?
        for url in urls where context.hasAccess(to: url) {
            // A more specific native denial still wins over a broad grant.
            let dates = context.grantedPermissionMatchPatterns.compactMap { pattern, date in
                date > now && pattern.matches(url) ? date : nil
            }
            guard let deadline = dates.max() else { continue }
            approved.insert(url)
            expiration = min(expiration ?? deadline, deadline)
        }
        return (approved, expiration)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let access = UUID(uuidString: context.uniqueIdentifier).flatMap { accessSettings[$0] } ?? .init()
        let eligible = matchPatterns.filter { !Self.isBlocked($0, by: access) }
        guard !eligible.isEmpty else { completionHandler([], nil); return }
        WebExtensionPermissionPrompter.confirm(
            extensionName: context.webExtension.displayName,
            items: eligible.map(\.string).sorted()
        ) { allowed in
            guard let allowed else { completionHandler([], nil); return }
            let saved = self.saveDecision(context, sites: eligible.map(\.string), allowed: allowed)
            completionHandler(saved && allowed ? Set(eligible) : [], saved && allowed ? .distantFuture : nil)
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
        guard action.presentsPopup, let popupViewController = WebExtensionPopupPresenter.contentViewController(for: action) else {
            completionHandler(WebExtensionPopupPresenter.unavailableError)
            return
        }
        WebExtensionPopupPresenter.present(popupViewController,
            ownerID: UUID(uuidString: context.uniqueIdentifier),
            title: context.webExtension.displayName,
            isActive: { [weak self, weak context] in
                guard let context, let id = UUID(uuidString: context.uniqueIdentifier) else { return false }
                return self?.contexts[id] === context
            }, completionHandler: completionHandler)
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
            access: UUID(uuidString: context.uniqueIdentifier).flatMap { accessSettings[$0] },
            webView: browserWindow.activeNativeTab?.webView(for: context),
            blobSources: browserWindow.tabs(for: context).compactMap { $0.webView?(for: context) },
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
        if compatibilityHost.connect(port, context: context,
            access: UUID(uuidString: context.uniqueIdentifier).flatMap { accessSettings[$0] }, completion: completionHandler) { return }
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

struct WebExtensionCommandPresentation: Identifiable {
    let id: String
    let title: String
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
        completion: @escaping (Bool?) -> Void
    ) {
        guard !items.isEmpty else {
            completion(true)
            return
        }
        guard let presenter = WebExtensionPopupPresenter.foregroundPresenter() else {
            completion(nil)
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
enum WebExtensionPopupPresenter {
    @available(iOS 18.4, *)
    static func contentViewController(for action: WKWebExtension.Action) -> UIViewController? {
        if let current = (presentedPopup as? UINavigationController)?.topViewController as? WebExtensionPopupContentController,
           presentedPopup?.isBeingDismissed != true, current.represents(action) {
            return current
        }
        guard let webView = action.popupWebView else { return nil }
        return WebExtensionPopupContentController(webView: webView, action: action)
    }
    static let unavailableError = NSError(
        domain: "com.dkluge.Soulo.WebExtensionPopup",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The extension popup is unavailable."]
    )
    private static weak var presentedPopup: UIViewController?
    private static var presentedPopupOwner: UUID?
    private static weak var downloadFolderHost: UIHostingController<WebExtensionDownloadFolderView>?

    static func presentDownloadFolder(at directory: URL, completion: @escaping (Error?) -> Void, attempt: Int = 0) {
        guard let presenter = foregroundPresenter() else { completion(unavailableError); return }
        if presenter.isBeingPresented || presenter.isBeingDismissed {
            guard attempt < 8 else { completion(unavailableError); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                presentDownloadFolder(at: directory, completion: completion, attempt: attempt + 1)
            }
            return
        }
        if let host = downloadFolderHost, host.presentingViewController != nil, !host.isBeingDismissed {
            host.rootView = WebExtensionDownloadFolderView(directory: directory)
            completion(nil)
            return
        }
        let host = UIHostingController(rootView: WebExtensionDownloadFolderView(directory: directory))
        host.view.accessibilityIdentifier = "extensions.downloads.folder"
        host.modalPresentationStyle = .pageSheet
        host.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        downloadFolderHost = host
        // Present above the extension instead of closing its document. The
        // native reply and any in-flight capture/merge keep their original page.
        presenter.present(host, animated: true) { completion(nil) }
    }

    static func present(
        _ popupViewController: UIViewController,
        ownerID: UUID? = nil,
        title: String? = nil,
        isActive: @escaping () -> Bool = { true },
        completionHandler: @escaping (Error?) -> Void,
        attempt: Int = 0
    ) {
        guard isActive(), let presenter = foregroundPresenter() else {
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
                    ownerID: ownerID, title: title, isActive: isActive,
                    completionHandler: completionHandler,
                    attempt: attempt + 1
                )
            }
            return
        }

        if let current = presentedPopup, current.presentingViewController != nil {
            if (current as? UINavigationController)?.topViewController === popupViewController {
                completionHandler(nil)
            } else {
                dismissCurrentPopup {
                    present(popupViewController, ownerID: ownerID, title: title,
                            isActive: isActive, completionHandler: completionHandler)
                }
            }
            return
        }

        // The extension owns a web viewport with fixed-position controls.
        // Keep it below our navigation bar instead of adding a second scroll
        // inset inside the publisher's viewport.
        popupViewController.edgesForExtendedLayout = []
        let host = WebExtensionPopupNavigationController(rootViewController: popupViewController)
        host.modalPresentationStyle = .popover
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": host.overrideUserInterfaceStyle = .light
        case "dark": host.overrideUserInterfaceStyle = .dark
        default: host.overrideUserInterfaceStyle = .unspecified
        }
        popupViewController.navigationItem.title = title
        let close = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
            dismissCurrentPopup(completion: {})
        })
        close.accessibilityIdentifier = "extensions.popup.close"
        popupViewController.navigationItem.rightBarButtonItem = close
        host.updatePopupSize()
        if let popover = host.popoverPresentationController {
            popover.delegate = host
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.safeAreaInsets.top + 1,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = [.up, .down]
            // Compact-width popovers otherwise adapt to a tall sheet, leaving
            // fixed web controls at the rounded bottom edge of the screen.
            let sheet = popover.adaptiveSheetPresentationController
            let fitted = UISheetPresentationController.Detent.Identifier("extension-content")
            sheet.detents = [.custom(identifier: fitted) { [weak host] context in
                min(host?.preferredContentSize.height ?? 524, context.maximumDetentValue * 0.8)
            }, .large()]
            sheet.selectedDetentIdentifier = fitted
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        presentedPopup = host
        presentedPopupOwner = ownerID
        presenter.present(host, animated: true) {
            if isActive() { completionHandler(nil) }
            else {
                host.dismiss(animated: false)
                completionHandler(unavailableError)
            }
        }
    }

    static func dismissPopup(ownedBy id: UUID) {
        guard presentedPopupOwner == id else { return }
        dismissCurrentPopup(completion: {})
    }

    fileprivate static func dismissPopup(containing content: UIViewController) {
        guard (presentedPopup as? UINavigationController)?.topViewController === content else { return }
        dismissCurrentPopup(completion: {})
    }

    fileprivate static func didDismiss(_ popup: UIViewController) {
        guard presentedPopup === popup else { return }
        presentedPopup = nil
        presentedPopupOwner = nil
    }

    static func dismissCurrentPopup(completion: @escaping () -> Void) {
        guard let popup = presentedPopup,
              popup.presentingViewController != nil,
              !popup.isBeingDismissed else {
            presentedPopup = nil
            presentedPopupOwner = nil
            completion()
            return
        }
        presentedPopup = nil
        presentedPopupOwner = nil
        (popup as? WebExtensionPopupNavigationController)?.closeContent()
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

private struct WebExtensionDownloadFolderView: View {
    let directory: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LibraryFilesView(directory: directory)
                .id(directory.standardizedFileURL.path)
                .navigationTitle(LanguageManager.shared.localizedString("downloads"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                            .accessibilityIdentifier("extensions.downloads.close")
                    }
                }
        }
    }
}

/// Host the official action webview in a normal, bounded viewport. Its native
/// self-sizing controller clips fixed-position controls in some iPad popovers.
/// Keeping the action's original webview retains popup API identity and events.
@MainActor
@available(iOS 18.4, *)
private final class WebExtensionPopupContentController: UIViewController {
    private let webView: WKWebView
    private let action: WKWebExtension.Action
    private var closed = false
    private var delegateProxy: WebExtensionPopupUIDelegate?

    init(webView: WKWebView, action: WKWebExtension.Action) {
        self.webView = webView
        self.action = action
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 640, height: 480)
        // WebKit can return a still-retained action webview after closePopup.
        // Each new presentation needs a fresh document; duplicate requests
        // return the current controller before reaching this initializer.
        webView.reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func represents(_ candidate: WKWebExtension.Action) -> Bool {
        !closed && candidate.popupWebView === webView
    }

    func closeIfNeeded() {
        guard !closed else { return }
        closed = true
        delegateProxy?.restore(on: webView)
        webView.stopLoading()
        action.closePopup()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let proxy = WebExtensionPopupUIDelegate(original: webView.uiDelegate) { [weak self] in
            guard let self, !self.closed else { return }
            self.closeIfNeeded()
            WebExtensionPopupPresenter.dismissPopup(containing: self)
        }
        delegateProxy = proxy
        webView.uiDelegate = proxy
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !closed && (isBeingDismissed || navigationController?.isBeingDismissed == true || navigationController?.presentingViewController == nil) {
            closeIfNeeded()
        }
    }
}

/// Keep all native action UI callbacks while routing window.close() to the
/// owning Soulo presentation as well as unloading the official action popup.
@MainActor
@available(iOS 18.4, *)
private final class WebExtensionPopupUIDelegate: NSObject, WKUIDelegate {
    private let original: (any WKUIDelegate)?
    private let onClose: () -> Void

    init(original: (any WKUIDelegate)?, onClose: @escaping () -> Void) {
        self.original = original
        self.onClose = onClose
        super.init()
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    func restore(on webView: WKWebView) {
        if webView.uiDelegate === self { webView.uiDelegate = original }
    }

    func webViewDidClose(_ webView: WKWebView) { onClose() }
}

@MainActor
private final class WebExtensionPopupNavigationController: UINavigationController, UIPopoverPresentationControllerDelegate {
    func closeContent() {
        if #available(iOS 18.4, *) { (topViewController as? WebExtensionPopupContentController)?.closeIfNeeded() }
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) { closeContent() }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        WebExtensionPopupPresenter.didDismiss(self)
    }
    func updatePopupSize() {
        guard let content = topViewController?.preferredContentSize,
              content.width > 0, content.height > 0 else { return }
        preferredContentSize = CGSize(width: content.width, height: content.height + max(44, navigationBar.frame.height))
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        updatePopupSize()
    }
}

@MainActor
@available(iOS 18.4, *)
private final class NativeExtensionWindow: NSObject, WKWebExtensionWindow {
    var tabs: [NativeExtensionTab] = []
    var activeNativeTab: NativeExtensionTab?
    weak var runtime: NativeWebExtensionRuntime?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        UserDefaults.standard.bool(forKey: "is_incognito") ? [] : tabs.filter {
            $0.webView?.configuration.websiteDataStore.isPersistent != false
        }
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard !UserDefaults.standard.bool(forKey: "is_incognito"),
              activeNativeTab?.webView?.configuration.websiteDataStore.isPersistent != false else { return nil }
        return activeNativeTab
    }

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
        // Open standalone extension applications separately, preserving the
        // source. Keep the native API's tab ID on the requested destination.
        let sourceURL = webView?.url ?? runtime?.browserTab(for: self)?.webViewModel.currentURL
        if url.scheme == context.baseURL.scheme, url.host?.lowercased() == context.baseURL.host?.lowercased(),
           ["http", "https"].contains(sourceURL?.scheme?.lowercased() ?? "") {
            DispatchQueue.main.async { [weak self] in
                guard let self, let runtime = self.runtime else {
                    completionHandler(NativeWebExtensionHostError.tabUnavailable); return
                }
                WebExtensionPopupPresenter.dismissCurrentPopup {
                    do {
                        try runtime.openExtensionDocument(url, from: self)
                        completionHandler(nil)
                    } catch { completionHandler(error) }
                }
            }
            return
        }
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
