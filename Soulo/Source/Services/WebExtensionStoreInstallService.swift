import Foundation

struct WebExtensionRemotePackage: Equatable {
    enum Store: String, Equatable {
        case chrome
        case edge
        case firefox
        case direct
    }

    let store: Store
    let downloadURL: URL
    let fileExtension: String
}

enum WebExtensionStoreInstallError: LocalizedError {
    case invalidLink
    case insecureLink
    case insecureRedirect
    case invalidResponse
    case packageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            AppLocalization.string("web_extension_store_invalid_link")
        case .insecureLink:
            AppLocalization.string("web_extension_store_https_required")
        case .insecureRedirect:
            AppLocalization.string("web_extension_store_insecure_redirect")
        case .invalidResponse:
            AppLocalization.string("web_extension_store_download_failed")
        case .packageTooLarge:
            AppLocalization.string("web_extension_store_package_too_large")
        }
    }
}

enum WebExtensionStoreRedirectPolicy {
    static func allows(_ redirectURL: URL, store: WebExtensionRemotePackage.Store) -> Bool {
        if redirectURL.scheme?.lowercased() == "https" { return true }
        guard store == .edge,
              redirectURL.scheme?.lowercased() == "http",
              let host = redirectURL.host?.lowercased() else { return false }
        return host == "delivery.mp.microsoft.com"
            || host.hasSuffix(".delivery.mp.microsoft.com")
    }
}

private final class WebExtensionStoreSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let store: WebExtensionRemotePackage.Store

    init(store: WebExtensionRemotePackage.Store) {
        self.store = store
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              WebExtensionStoreRedirectPolicy.allows(url, store: store) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

extension Notification.Name {
    static let webExtensionStoreInstallRequested = Notification.Name("soulo.webExtensionStoreInstallRequested")
}

enum WebExtensionStoreLinkResolver {
    private static let chromeHosts = Set(["chromewebstore.google.com", "chrome.google.com"])
    private static let edgeHosts = Set(["microsoftedge.microsoft.com"])
    private static let firefoxHosts = Set(["addons.mozilla.org", "www.addons.mozilla.org"])

    static func resolve(_ rawValue: String) throws -> WebExtensionRemotePackage {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WebExtensionStoreInstallError.invalidLink }

        if isChromeIdentifier(value) {
            return chromePackage(identifier: value)
        }

        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            throw WebExtensionStoreInstallError.invalidLink
        }
        guard url.scheme?.lowercased() == "https" else {
            throw WebExtensionStoreInstallError.insecureLink
        }

        let pathExtension = url.pathExtension.lowercased()
        if ["crx", "xpi", "zip"].contains(pathExtension) {
            return WebExtensionRemotePackage(
                store: .direct,
                downloadURL: url,
                fileExtension: pathExtension
            )
        }

        if chromeHosts.contains(host), let identifier = identifier(in: url, pattern: #"^[a-p]{32}$"#) {
            return chromePackage(identifier: identifier)
        }
        if edgeHosts.contains(host), let identifier = identifier(in: url, pattern: #"^[a-z]{32}$"#) {
            return edgePackage(identifier: identifier)
        }
        if firefoxHosts.contains(host), let slug = firefoxSlug(in: url) {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "addons.mozilla.org"
            components.path = "/firefox/downloads/latest/\(slug)/latest.xpi"
            guard let downloadURL = components.url else {
                throw WebExtensionStoreInstallError.invalidLink
            }
            return WebExtensionRemotePackage(store: .firefox, downloadURL: downloadURL, fileExtension: "xpi")
        }

        throw WebExtensionStoreInstallError.invalidLink
    }

    static func canInstall(from url: URL?) -> Bool {
        guard let url else { return false }
        return (try? resolve(url.absoluteString)) != nil
    }

    private static func chromePackage(identifier: String) -> WebExtensionRemotePackage {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "clients2.google.com"
        components.path = "/service/update2/crx"
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "131.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(identifier)&uc")
        ]
        return WebExtensionRemotePackage(store: .chrome, downloadURL: components.url!, fileExtension: "crx")
    }

    private static func edgePackage(identifier: String) -> WebExtensionRemotePackage {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "edge.microsoft.com"
        components.path = "/extensionwebstorebase/v1/crx"
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "x", value: "id=\(identifier)&installsource=ondemand&uc")
        ]
        return WebExtensionRemotePackage(store: .edge, downloadURL: components.url!, fileExtension: "crx")
    }

    private static func identifier(in url: URL, pattern: String) -> String? {
        url.pathComponents
            .map { $0.lowercased() }
            .last { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    private static func firefoxSlug(in url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let addonIndex = components.firstIndex(of: "addon"),
              components.indices.contains(addonIndex + 1) else { return nil }
        let slug = components[addonIndex + 1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !slug.isEmpty,
              slug.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return slug
    }

    private static func isChromeIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil
    }
}

@MainActor
final class WebExtensionStoreInstallService {
    static let shared = WebExtensionStoreInstallService()
    static let maximumPackageSize: Int64 = 100 * 1_024 * 1_024

    private init() {}

    private func makeSession(for store: WebExtensionRemotePackage.Store) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        return URLSession(
            configuration: configuration,
            delegate: WebExtensionStoreSessionDelegate(store: store),
            delegateQueue: nil
        )
    }

    func install(from rawValue: String) async throws -> WebExtensionRecord {
        let localURL = try await downloadPackage(from: rawValue)
        defer { try? FileManager.default.removeItem(at: localURL) }
        return try await BrowserExtensionService.shared.installWebExtension(from: localURL)
    }

    func downloadPackage(from rawValue: String) async throws -> URL {
        let package = try WebExtensionStoreLinkResolver.resolve(rawValue)
        var request = URLRequest(url: package.downloadURL)
        request.setValue(AppConstants.desktopWebViewUserAgent, forHTTPHeaderField: "User-Agent")
        let session = makeSession(for: package.store)
        defer { session.finishTasksAndInvalidate() }

        let temporaryDownload: URL
        let response: URLResponse
        do {
            (temporaryDownload, response) = try await session.download(for: request)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw WebExtensionStoreInstallError.insecureRedirect
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw WebExtensionStoreInstallError.invalidResponse
        }
        if response.expectedContentLength > Self.maximumPackageSize {
            throw WebExtensionStoreInstallError.packageTooLarge
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryDownload.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { throw WebExtensionStoreInstallError.invalidResponse }
        guard fileSize <= Self.maximumPackageSize else {
            throw WebExtensionStoreInstallError.packageTooLarge
        }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloExtension-\(UUID().uuidString)")
            .appendingPathExtension(package.fileExtension)
        try FileManager.default.moveItem(at: temporaryDownload, to: localURL)
        return localURL
    }
}
