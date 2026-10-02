import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit
import WebKit

enum WebDownloadFilename {
    static func media(
        _ resource: WebMediaResource,
        requested: String?,
        pageTitle: String?
    ) -> String {
        if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           requested != resource.suggestedFilename {
            return requested
        }
        guard let title = usableTitle(pageTitle) ?? usableTitle(resource.title) else {
            return requested ?? resource.suggestedFilename
        }
        let fileExtension: String
        if resource.delivery == .direct {
            let sourceExtension = (resource.suggestedFilename as NSString).pathExtension.lowercased()
            let videoExtensions: Set<String> = [
                "mp4", "m4v", "mov", "webm", "mkv", "avi", "ts", "m2ts", "3gp", "3g2",
                "ogv", "mpeg", "mpg", "wmv", "flv", "f4v", "vob"
            ]
            let audioExtensions: Set<String> = [
                "mp3", "m4a", "m4b", "aac", "wav", "flac", "ogg", "oga", "opus",
                "wma", "aiff", "ape", "alac", "amr"
            ]
            fileExtension = (resource.kind == .video ? videoExtensions : audioExtensions)
                .contains(sourceExtension) ? sourceExtension : (resource.kind == .video ? "mp4" : "m4a")
        } else {
            fileExtension = "mp4"
        }
        return titledFilename(title, fileExtension: fileExtension)
    }

    static func native(
        suggested: String,
        pageTitle: String?,
        response: URLResponse? = nil
    ) -> String {
        if let disposition = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("filename=") || disposition.contains("filename*=") {
            return suggested
        }
        let stem = (suggested as NSString).deletingPathExtension.lowercased()
        let genericNames: Set<String> = [
            "download", "file", "index", "master", "playlist", "stream",
            "media", "video", "audio", "play", "playback", "videoplayback"
        ]
        guard genericNames.contains(stem), let title = usableTitle(pageTitle) else {
            return suggested
        }
        let fileExtension = (suggested as NSString).pathExtension
        let inferredExtension = fileExtension.isEmpty
            ? response?.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ""
            : fileExtension
        return titledFilename(title, fileExtension: inferredExtension)
    }

    private static func titledFilename(_ title: String, fileExtension: String) -> String {
        let existingExtension = (title as NSString).pathExtension.lowercased()
        let baseName = existingExtension == fileExtension.lowercased()
            || (existingExtension == "m3u8" && fileExtension.lowercased() == "mp4")
            ? (title as NSString).deletingPathExtension : title
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return DownloadFilenameSanitizer.sanitize(baseName + suffix, preferredExtension: fileExtension)
    }

    private static func usableTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        guard !["untitled", "new tab", "新标签页", "about:blank"].contains(lowered),
              !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") else { return nil }
        return value
    }
}

enum WebResourceDownloadError: LocalizedError {
    case invalidResponse
    case photoAccessDenied
    case invalidImage
    case imageTooLarge
    case photoImportFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppLocalization.string("resource_download_invalid_response")
        case .photoAccessDenied:
            return AppLocalization.string("resource_photo_access_denied")
        case .invalidImage: return ToolText.text("photo_save_invalid")
        case .imageTooLarge: return ToolText.text("photo_save_too_large")
        case .photoImportFailed: return ToolText.text("photo_save_incompatible")
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
        _ resource: WebMediaResource,
        preferredFilename: String? = nil,
        pageURL: URL? = nil,
        webView: WKWebView?
    ) async throws -> URL {
        let filename = WebDownloadFilename.media(
            resource,
            requested: preferredFilename,
            pageTitle: webView?.title
        )
        switch resource.delivery {
        case .youtubeSABR:
            guard let webView else { throw StreamingMediaDownloadError.unavailable }
            return try await StreamingMediaDownloadService.shared.downloadYouTubeVideo(
                resource: resource,
                preferredFilename: filename,
                pageURL: pageURL,
                webView: webView
            )
        case .separateTracks:
            guard let webView, let audioURL = resource.companionAudioURL else {
                throw StreamingMediaDownloadError.missingTrack
            }
            return try await StreamingMediaDownloadService.shared.downloadSeparatedTracks(
                resource: resource,
                audioURL: audioURL,
                preferredFilename: filename,
                pageURL: pageURL,
                webView: webView
            )
        case .hls:
            guard let webView else { throw StreamingMediaDownloadError.unavailable }
            return try await StreamingMediaDownloadService.shared.downloadHLS(
                resource: resource,
                preferredFilename: filename,
                pageURL: pageURL,
                webView: webView
            )
        case .dash:
            throw StreamingMediaDownloadError.unsupportedManifest
        case .direct:
            return try await download(
                resource.url,
                preferredFilename: filename,
                pageURL: pageURL,
                webView: webView,
                fallbackBaseName: resource.kind == .video ? "Video" : "Audio",
                playbackResource: resource.kind == .video ? resource : nil
            )
        }
    }

    func download(
        _ url: URL,
        preferredFilename: String? = nil,
        pageURL: URL? = nil,
        webView: WKWebView? = nil,
        fallbackBaseName: String = "Download",
        playbackResource: WebMediaResource? = nil
    ) async throws -> URL {
        let automaticName = preferredFilename == nil
            ? WebDownloadFilename.native(suggested: url.lastPathComponent, pageTitle: webView?.title)
            : nil
        let suggestedFilename = normalizedFilename(
            preferredFilename ?? automaticName,
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
        let nativeVideoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "3g2"]
        let isNativeVideo = nativeVideoExtensions.contains((suggestedFilename as NSString).pathExtension.lowercased())
            && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        let video = playbackResource ?? (isNativeVideo
            ? WebMediaResource(kind: .video, url: url, title: suggestedFilename, posterURL: nil) : nil)
        if isNativeVideo, let resource = video, resource.delivery == .direct, resource.kind == .video {
            let asset = await WebResourceMediaService.asset(for: resource, webView: webView, preferDownloadedCopy: false)
            manager.registerPlaybackSource(id: item.id, asset: asset, pageURL: pageURL, webView: webView)
        }
        guard manager.downloads.contains(where: { $0.id == item.id && $0.status == .inProgress }) else {
            throw CancellationError()
        }
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
        try Task.checkCancellation()

        let temporaryURL: URL
        let filename: String?
        if url.isFileURL {
            temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: url, to: temporaryURL)
            filename = preferredFilename ?? url.lastPathComponent
        } else {
            let downloaded = try await temporaryDownload(url, pageURL: pageURL, webView: webView)
            temporaryURL = downloaded.0
            filename = preferredFilename ?? downloaded.1.suggestedFilename
        }
        let importDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloPhotoImport-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: importDirectory)
        }
        try Task.checkCancellation()

        try FileManager.default.createDirectory(
            at: importDirectory,
            withIntermediateDirectories: true
        )
        let original = try await Task.detached(priority: .userInitiated) {
            try PhotoImportPreparation.prepare(sourceURL: temporaryURL, directory: importDirectory, filename: filename)
        }.value
        try Task.checkCancellation()
        do {
            try await importPhoto(original)
        } catch {
            let failure = error as NSError
            guard failure.domain == PHPhotosErrorDomain,
                  failure.code == PHPhotosError.Code.invalidResource.rawValue else { throw error }
            try Task.checkCancellation()
            let compatible = try await Task.detached(priority: .userInitiated) {
                try PhotoImportPreparation.prepare(sourceURL: temporaryURL, directory: importDirectory,
                    filename: filename, convert: true)
            }.value
            try Task.checkCancellation()
            do { try await importPhoto(compatible) }
            catch {
                let failure = error as NSError
                if failure.domain == PHPhotosErrorDomain && failure.code == PHPhotosError.Code.invalidResource.rawValue {
                    throw WebResourceDownloadError.photoImportFailed
                }
                throw error
            }
        }
    }

    private func importPhoto(_ resource: PhotoImportPreparation.Resource) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = resource.typeIdentifier
                options.originalFilename = resource.url.lastPathComponent
                PHAssetCreationRequest.forAsset().addResource(
                    with: .photo,
                    fileURL: resource.url,
                    options: options
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
        webView: WKWebView? = nil,
        frame: WKFrameInfo? = nil,
        forPreview: Bool = false
    ) async throws -> UIImage {
        let temporaryURL = try await temporaryImageFile(url, pageURL: pageURL, webView: webView, frame: frame)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        if forPreview {
            let decoding = Task.detached(priority: .userInitiated) { LocalImagePreview.decode(temporaryURL) }
            let result = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
            guard let result else { throw WebResourceDownloadError.invalidImage }
            return result
        }
        guard let image = UIImage(contentsOfFile: temporaryURL.path) else {
            throw WebResourceDownloadError.invalidResponse
        }
        return image
    }

    /// Caller owns this original image file and must remove it after preview/sharing.
    func temporaryImageFile(
        _ url: URL, pageURL: URL? = nil, webView: WKWebView? = nil, frame: WKFrameInfo? = nil
    ) async throws -> URL {
        let temporaryURL: URL
        if ["data", "blob"].contains(url.scheme?.lowercased() ?? "") {
            guard let webView else { throw WebResourceDownloadError.invalidResponse }
            let value = try await webView.callAsyncJavaScript(#"""
                const response = await fetch(url);
                const blob = await response.blob();
                if (!blob.type.startsWith('image/') || blob.size > 32 * 1024 * 1024) throw new Error('Invalid image');
                return await new Promise((resolve, reject) => {
                    const reader = new FileReader(); reader.onload = () => resolve(reader.result);
                    reader.onerror = reject; reader.readAsDataURL(blob);
                });
                """#, arguments: ["url": url.absoluteString], in: frame, contentWorld: .defaultClient)
            guard let value = value as? String, let comma = value.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  data.count <= 32 * 1024 * 1024 else { throw WebResourceDownloadError.invalidImage }
            temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: temporaryURL, options: .atomic)
        } else {
            (temporaryURL, _) = try await temporaryDownload(url, pageURL: pageURL, webView: webView)
        }
        do {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let type = CGImageSourceGetType(source) as String?,
                  let suffix = UTType(type)?.preferredFilenameExtension else {
                throw WebResourceDownloadError.invalidImage
            }
            let named = temporaryURL.appendingPathExtension(suffix)
            try FileManager.default.moveItem(at: temporaryURL, to: named)
            return named
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
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

    func resourceRequest(_ url: URL, pageURL: URL?, webView: WKWebView?) async -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(
            webView?.customUserAgent?.isEmpty == false
                ? webView?.customUserAgent
                : AppConstants.mobileWebViewUserAgent,
            forHTTPHeaderField: "User-Agent"
        )
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

    // Only replay ordinary GET downloads. Blob URLs and form submissions must
    // remain owned by WebKit, which has their body and page-process context.
    static func canDownloadInBackground(_ request: URLRequest?) -> Bool {
        guard let request, let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Range") == nil else { return false }
        return true
    }

    func backgroundRequest(
        from original: URLRequest, pageURL: URL?, webView: WKWebView?
    ) async -> URLRequest {
        guard let url = original.url else { return original }
        let browserRequest = await resourceRequest(url, pageURL: pageURL, webView: webView)
        var request = original
        for (field, value) in browserRequest.allHTTPHeaderFields ?? [:]
        where request.value(forHTTPHeaderField: field) == nil {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpShouldHandleCookies = false
        return request
    }

    func allCookies(in webView: WKWebView) async -> [HTTPCookie] {
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
