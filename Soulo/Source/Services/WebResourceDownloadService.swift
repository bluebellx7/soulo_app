import Foundation
import Photos
import UniformTypeIdentifiers
import UIKit
import WebKit

enum WebResourceDownloadError: LocalizedError {
    case invalidResponse
    case photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLocalization.string("resource_download_invalid_response")
        case .photoAccessDenied:
            return AppLocalization.string("resource_photo_access_denied")
        }
    }
}

@MainActor
final class WebResourceDownloadService {
    static let shared = WebResourceDownloadService()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func download(
        _ url: URL,
        preferredFilename: String? = nil,
        pageURL: URL? = nil,
        webView: WKWebView? = nil,
        fallbackBaseName: String = "Download"
    ) async throws -> URL {
        let suggestedFilename = normalizedFilename(
            preferredFilename,
            responseFilename: nil,
            responseMIMEType: nil,
            fallbackBaseName: fallbackBaseName,
            sourceURL: url
        )
        let manager = DownloadManagerService.shared
        let (item, destinationURL) = manager.beginDownload(
            suggestedFilename: suggestedFilename,
            sourceURL: url,
            transport: .background
        )

        _ = destinationURL
        let request = await resourceRequest(url, pageURL: pageURL, webView: webView)
        return try await BackgroundDownloadService.shared.start(request: request, item: item)
    }

    func saveImageToPhotos(
        _ url: URL,
        preferredFilename: String? = nil,
        pageURL: URL? = nil,
        webView: WKWebView? = nil
    ) async throws {
        let status = await photoAuthorizationStatus()
        guard status == .authorized || status == .limited else {
            throw WebResourceDownloadError.photoAccessDenied
        }

        let (temporaryURL, response) = try await temporaryDownload(
            url,
            pageURL: pageURL,
            webView: webView
        )
        let importDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloPhotoImport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: importDirectory)
        }

        try FileManager.default.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: true
        )
        let filename = normalizedFilename(
            preferredFilename,
            responseFilename: response.suggestedFilename,
            responseMIMEType: response.mimeType,
            fallbackBaseName: "Image",
            sourceURL: url
        )
        let photoImportURL = importDirectory.appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.moveItem(at: temporaryURL, to: photoImportURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(
                    with: .photo,
                    fileURL: photoImportURL,
                    options: nil
                )
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: WebResourceDownloadError.invalidResponse)
                }
            }
        }
    }

    func loadImage(
        _ url: URL,
        pageURL: URL? = nil,
        webView: WKWebView? = nil
    ) async throws -> UIImage {
        let (temporaryURL, _) = try await temporaryDownload(url, pageURL: pageURL, webView: webView)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let image = UIImage(contentsOfFile: temporaryURL.path) else {
            throw WebResourceDownloadError.invalidResponse
        }
        return image
    }

    static func matchingCookies(
        from cookies: [HTTPCookie],
        for url: URL,
        now: Date = Date()
    ) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isSecureRequest = url.scheme?.lowercased() == "https"

        return cookies.filter { cookie in
            if let expiresDate = cookie.expiresDate, expiresDate <= now {
                return false
            }
            if cookie.isSecure && !isSecureRequest {
                return false
            }

            let rawDomain = cookie.domain.lowercased()
            let domain = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain
                || (rawDomain.hasPrefix(".") && host.hasSuffix(".\(domain)"))
            guard domainMatches else { return false }

            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            return requestPath == cookiePath
                || (requestPath.hasPrefix(cookiePath)
                    && (cookiePath.hasSuffix("/")
                        || requestPath.dropFirst(cookiePath.count).first == "/"))
        }
    }

    static func referrerHeader(pageURL: URL, resourceURL: URL) -> String? {
        guard let pageScheme = pageURL.scheme?.lowercased(),
              ["http", "https"].contains(pageScheme),
              let pageHost = pageURL.host?.lowercased(),
              let resourceScheme = resourceURL.scheme?.lowercased(),
              ["http", "https"].contains(resourceScheme),
              let resourceHost = resourceURL.host?.lowercased() else {
            return nil
        }

        if pageScheme == "https" && resourceScheme == "http" {
            return nil
        }

        let isSameOrigin = pageScheme == resourceScheme
            && pageHost == resourceHost
            && pageURL.port == resourceURL.port
        if isSameOrigin {
            return pageURL.absoluteString
        }

        var components = URLComponents()
        components.scheme = pageScheme
        components.host = pageHost
        components.port = pageURL.port
        components.path = "/"
        return components.url?.absoluteString
    }

    private func temporaryDownload(
        _ url: URL,
        pageURL: URL?,
        webView: WKWebView?
    ) async throws -> (URL, URLResponse) {
        let request = await resourceRequest(url, pageURL: pageURL, webView: webView)

        let (temporaryURL, response) = try await session.download(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw WebResourceDownloadError.invalidResponse
        }
        return (temporaryURL, response)
    }

    private func resourceRequest(_ url: URL, pageURL: URL?, webView: WKWebView?) async -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(AppConstants.mobileWebViewUserAgent, forHTTPHeaderField: "User-Agent")
        if let pageURL, let referrer = Self.referrerHeader(pageURL: pageURL, resourceURL: url) {
            request.setValue(referrer, forHTTPHeaderField: "Referer")
        }
        if let webView {
            let cookies = await allCookies(in: webView)
            for (field, value) in HTTPCookie.requestHeaderFields(with: Self.matchingCookies(from: cookies, for: url)) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    private func allCookies(in webView: WKWebView) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func photoAuthorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func normalizedFilename(
        _ preferredFilename: String?,
        responseFilename: String?,
        responseMIMEType: String?,
        fallbackBaseName: String,
        sourceURL: URL
    ) -> String {
        let candidates = [preferredFilename, responseFilename, sourceURL.lastPathComponent]
        let candidate = candidates
            .compactMap { $0?.removingPercentEncoding ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? fallbackBaseName
        let inferredExtension = candidates
            .compactMap { $0 }
            .map { ($0 as NSString).pathExtension }
            .first(where: { !$0.isEmpty })
            ?? responseMIMEType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }

        return DownloadFilenameSanitizer.sanitize(
            candidate,
            fallbackBaseName: fallbackBaseName,
            preferredExtension: inferredExtension
        )
    }
}
