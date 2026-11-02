import Foundation
import CryptoKit

/// Store the user's decisions, including denials, independently of the manifest.
struct WebExtensionAccess: Codable, Equatable {
    var permissions: [String: Date] = [:]
    var sites: [String: Date] = [:]
    var deniedPermissions: [String: Date] = [:]
    var deniedSites: [String: Date] = [:]
    var blockedHosts: Set<String> = []

    static func requested(permissions: [String], sites: [String]) -> Self {
        Self(permissions: Dictionary(permissions.map { ($0, .distantFuture) }, uniquingKeysWith: { a, _ in a }),
             sites: Dictionary(sites.map { ($0, .distantFuture) }, uniquingKeysWith: { a, _ in a }))
    }

    func allowsPermission(_ name: String) -> Bool {
        deniedPermissions[name].map { $0 > Date() } != true && permissions[name].map { $0 > Date() } == true
    }

    mutating func setPermission(_ name: String, allowed: Bool) {
        permissions[name] = allowed ? .distantFuture : nil
        deniedPermissions[name] = allowed ? nil : .distantFuture
    }

    mutating func setSite(_ pattern: String, allowed: Bool) {
        sites[pattern] = allowed ? .distantFuture : nil
        deniedSites[pattern] = allowed ? nil : .distantFuture
    }

    func blocks(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        return blockedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func normalizedHost(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("*"),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              ["", "/"].contains(url.path),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty, !host.contains(":"), !host.contains(" ") else { return nil }
        return host
    }
}

struct WebExtensionVersionSnapshot: Codable, Equatable {
    let name: String
    let version: String?
    let storedResourceName: String
    let permissionCount: Int
    let siteCount: Int
    let warningCount: Int?

    init(_ record: WebExtensionRecord) {
        name = record.name; version = record.version; storedResourceName = record.storedResourceName
        permissionCount = record.requestedPermissionCount; siteCount = record.requestedSiteCount
        warningCount = record.compatibilityWarningCount
    }
}

struct WebExtensionInstallPreview: Identifiable {
    let id: UUID
    let resourceURL: URL
    let name: String
    let version: String?
    let permissions: [String]
    let sites: [String]
    let warnings: [String]
    let identity: String?
    let sourceURL: String?
    let replacingID: UUID?
    let replacingResourceName: String?
    var access: WebExtensionAccess
}

enum WebExtensionPackageIdentity {
    static func value(manifest: [String: Any], source: URL?) -> String? {
        if let source, let package = try? WebExtensionStoreLinkResolver.resolve(source.absoluteString), package.store != .direct {
            return package.store.rawValue + ":" + package.downloadURL.absoluteString
        }
        for key in ["browser_specific_settings", "applications"] {
            if let settings = manifest[key] as? [String: Any], let gecko = settings["gecko"] as? [String: Any],
               let id = gecko["id"] as? String, !id.isEmpty { return "gecko:" + id }
        }
        if let key = manifest["key"] as? String, let data = Data(base64Encoded: key), !data.isEmpty {
            return "key:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard let source, var components = URLComponents(url: source, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host != nil else { return nil }
        components.fragment = nil; components.user = nil; components.password = nil
        return components.url.map { "url:" + $0.absoluteString }
    }
}
