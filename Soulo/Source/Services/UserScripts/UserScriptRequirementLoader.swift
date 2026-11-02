import Foundation
import CryptoKit

/// Dependencies are fetched at installation, never while a webpage is starting.
enum UserScriptRequirementLoader {
    static let maximumCount = 32
    static let maximumFileSize = 5 * 1_024 * 1_024
    static let maximumTotalSize = 20 * 1_024 * 1_024

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    static func resolve(
        _ declarations: [String],
        baseURL: URL?,
        cachedSources: [String: String] = [:],
        session: URLSession,
        maximumFileSize: Int = maximumFileSize,
        maximumTotalSize: Int = maximumTotalSize
    ) async throws -> [String: String] {
        guard declarations.count <= maximumCount else {
            throw Failure(declaration: "@require", underlying: URLError(.dataLengthExceedsMaximum))
        }
        var sources: [String: String] = [:]
        var totalSize = 0
        for declaration in declarations {
            try Task.checkCancellation()
            do {
                let url = try resolvedURL(declaration, baseURL: baseURL)
                let source: String
                if let cached = cachedSources[declaration] {
                    source = cached
                } else {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
                    components.fragment = nil
                    guard let requestURL = components.url else { throw URLError(.badURL) }
                    var request = URLRequest(url: requestURL)
                    request.setValue("application/javascript, text/javascript, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          let finalURL = response.url,
                          finalURL.scheme?.lowercased() == "https" else {
                        throw URLError(.badServerResponse)
                    }
                    guard response.expectedContentLength <= maximumFileSize,
                          response.expectedContentLength <= maximumTotalSize - totalSize else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    guard !["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    var data = Data()
                    for try await byte in bytes {
                        guard data.count < maximumFileSize, totalSize + data.count < maximumTotalSize else {
                            throw URLError(.dataLengthExceedsMaximum)
                        }
                        data.append(byte)
                    }
                    try verifyIntegrity(of: data, url: url)
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
                }
                guard source.utf8.count <= maximumFileSize,
                      source.utf8.count <= maximumTotalSize - totalSize else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                totalSize += source.utf8.count
                sources[declaration] = source
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure(declaration: declaration, underlying: error)
            }
        }
        return sources
    }

    static func resolvedURL(_ declaration: String, baseURL: URL?) throws -> URL {
        guard let url = URL(string: declaration, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        // The app keeps ATS enabled for native requests. Older script headers
        // commonly use HTTP CDN links; fetch their HTTPS equivalent directly.
        if url.scheme?.lowercased() == "http" {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw URLError(.badURL) }
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
            guard let secureURL = components.url else { throw URLError(.badURL) }
            return secureURL
        }
        return url
    }

    private static func verifyIntegrity(of data: Data, url: URL) throws {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: true)?.fragment else { return }
        // Tampermonkey accepts hex/Base64 and uses the last supported hash.
        var expected: (String, String)?
        for part in fragment.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            guard let separator = part.firstIndex(where: { $0 == "=" || $0 == "-" }) else { continue }
            let algorithm = part[..<separator].lowercased()
            if ["md5", "sha1", "sha256", "sha384", "sha512"].contains(algorithm) {
                expected = (algorithm, String(part[part.index(after: separator)...]))
            }
        }
        guard let (algorithm, hash) = expected else {
            if fragment.lowercased().hasPrefix("sha") || fragment.lowercased().hasPrefix("md5") {
                throw IntegrityFailure()
            }
            return
        }
        let digest: Data
        switch algorithm {
        case "md5": digest = Data(Insecure.MD5.hash(data: data))
        case "sha1": digest = Data(Insecure.SHA1.hash(data: data))
        case "sha256": digest = Data(SHA256.hash(data: data))
        case "sha384": digest = Data(SHA384.hash(data: data))
        default: digest = Data(SHA512.hash(data: data))
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hash.lowercased() == hex || Data(base64Encoded: hash) == digest else {
            throw IntegrityFailure()
        }
    }

    struct Failure: LocalizedError {
        let declaration: String
        let underlying: Error

        var errorDescription: String? {
            String(format: AppLocalization.string("userscript_require_failed"), declaration, underlying.localizedDescription)
        }
    }

    private struct IntegrityFailure: LocalizedError {
        var errorDescription: String? { AppLocalization.string("userscript_require_integrity_failed") }
    }
}
