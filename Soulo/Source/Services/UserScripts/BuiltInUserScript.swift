import Foundation

struct BuiltInUserScriptDefinition {
    let resourceFileName: String
    let namespace: String
    let nameKey: String?
    let descriptionKey: String?
    let source: String
    let metadata: UserScriptMetadata

    @MainActor
    func makeRecord(preserving existing: UserScriptRecord? = nil) -> UserScriptRecord {
        UserScriptRecord(
            id: existing?.id ?? UUID(),
            name: metadata.name ?? resourceFileName,
            source: source,
            matchPatterns: metadata.patterns.isEmpty ? ["*://*/*"] : metadata.patterns,
            excludePatterns: metadata.excludePatterns,
            grants: metadata.grants,
            connectDomains: metadata.connectDomains,
            namespace: metadata.namespace ?? namespace,
            version: metadata.version,
            scriptDescription: metadata.description,
            author: metadata.author,
            homepageURL: metadata.homepageURL,
            updateURL: metadata.updateURL,
            downloadURL: metadata.downloadURL,
            requiredURLs: metadata.requiredURLs,
            resources: metadata.resources,
            storedValues: existing?.storedValues ?? [:],
            isBuiltIn: true,
            injectionTime: metadata.injectionTime,
            isEnabled: existing?.isEnabled ?? false,
            installedAt: existing?.installedAt ?? Date(),
            updatedAt: existing?.updatedAt
        )
    }
}

@MainActor
enum BuiltInUserScripts {
    /// Optional localized presentation for known examples. Script discovery
    /// itself is automatic: adding a valid .user.js resource is sufficient.
    private static let localizationKeys: [String: (name: String, description: String)] = [
        "com.dkluge.soulo.examples.reading-progress": (
            "userscript_sample_name",
            "userscript_sample_desc"
        ),
        "com.dkluge.soulo.examples.page-marker": (
            "userscript_page_marker_name",
            "userscript_page_marker_desc"
        )
    ]

    static let retiredNamespaces: Set<String> = [
        "com.dkluge.soulo.examples.reading-mode"
    ]

    static let all: [BuiltInUserScriptDefinition] = discover()

    static func definition(namespace: String?) -> BuiltInUserScriptDefinition? {
        guard let namespace else { return nil }
        return all.first { $0.namespace.caseInsensitiveCompare(namespace) == .orderedSame }
    }

    static func displayName(for script: UserScriptRecord) -> String {
        guard let definition = definition(namespace: script.namespace),
              let key = definition.nameKey else { return script.name }
        return LanguageManager.shared.localizedString(key)
    }

    static func displayDescription(for script: UserScriptRecord) -> String? {
        guard let definition = definition(namespace: script.namespace) else {
            return script.scriptDescription
        }
        if let key = definition.descriptionKey {
            return LanguageManager.shared.localizedString(key)
        }
        return definition.metadata.description ?? script.scriptDescription
    }

    private static func discover() -> [BuiltInUserScriptDefinition] {
        guard let resourcesURL = Bundle.main.resourceURL else { return [] }
        let directoryURL = resourcesURL.appendingPathComponent("UserScripts", isDirectory: true)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return fileURLs
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".user.js") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { fileURL in
                guard let source = try? String(contentsOf: fileURL, encoding: .utf8),
                      !source.isEmpty else { return nil }
                let metadata = BrowserExtensionService.parseMetadata(from: source)
                guard let namespace = metadata.namespace,
                      !namespace.isEmpty,
                      metadata.patterns.allSatisfy({ UserScriptURLMatcher.isValid(pattern: $0) }),
                      metadata.excludePatterns.allSatisfy({ UserScriptURLMatcher.isValid(pattern: $0) }),
                      metadata.connectDomains.allSatisfy({ UserScriptConnectPolicy.isValid(declaration: $0) })
                else { return nil }
                let keys = localizationKeys[namespace]
                return BuiltInUserScriptDefinition(
                    resourceFileName: fileURL.lastPathComponent,
                    namespace: namespace,
                    nameKey: keys?.name,
                    descriptionKey: keys?.description,
                    source: source,
                    metadata: metadata
                )
            }
    }
}
