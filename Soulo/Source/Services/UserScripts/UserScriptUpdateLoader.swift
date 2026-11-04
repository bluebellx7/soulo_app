import Foundation

struct UserScriptUpdatePreview: Identifiable {
    var id: UUID { installed.id }
    let installed: UserScriptRecord
    let source: String
    let sourceURL: URL
    let metadata: UserScriptMetadata
}

/// Explicit update checks only. Nothing is fetched when a webpage loads.
@MainActor enum UserScriptUpdateLoader {
    static func checkURL(for script: UserScriptRecord) -> URL? {
        guard script.isBuiltIn != true,
              script.updateURL?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) != "none" else { return nil }
        return [script.updateURL, script.downloadURL, script.sourceURL].compactMap { value in
            value.flatMap { try? UserScriptRequirementLoader.resolvedURL($0, baseURL: script.sourceURL.flatMap(URL.init(string:))) }
        }.first
    }

    static func check(_ script: UserScriptRecord, session: URLSession) async throws -> UserScriptUpdatePreview? {
        guard let checkURL = checkURL(for: script) else { throw Failure("userscript_update_no_url") }
        let probe = try await fetch(checkURL, session: session)
        let advertised = try metadata(in: probe.source)
        guard let version = advertised.version, !version.isEmpty else { throw Failure("userscript_update_invalid") }
        if let old = script.version, !isNewer(version, than: old) { return nil }
        let downloadURL: URL
        if let declared = advertised.downloadURL ?? script.downloadURL {
            downloadURL = try UserScriptRequirementLoader.resolvedURL(declared, baseURL: probe.url)
        } else if probe.url.path.lowercased().hasSuffix(".meta.js") {
            guard let original = script.sourceURL, let url = URL(string: original),
                  url.path.lowercased().hasSuffix(".user.js") else { throw Failure("userscript_update_no_url") }
            downloadURL = try UserScriptRequirementLoader.resolvedURL(original, baseURL: nil)
        } else { downloadURL = probe.url }
        let downloaded = downloadURL == probe.url ? probe : try await fetch(downloadURL, session: session)
        let next = try metadata(in: downloaded.source)
        guard let nextVersion = next.version, !nextVersion.isEmpty,
              !isNewer(version, than: nextVersion),
              script.version.map({ isNewer(nextVersion, than: $0) }) ?? true else { throw Failure("userscript_update_invalid") }
        if let namespace = script.namespace, next.namespace != namespace { throw Failure("userscript_update_invalid") }
        guard downloaded.source != script.source else { return nil }
        return UserScriptUpdatePreview(installed: script, source: downloaded.source, sourceURL: downloaded.url, metadata: next)
    }

    private static func metadata(in source: String) throws -> UserScriptMetadata {
        guard source.range(of: #"(?m)^\s*//\s*==UserScript=="#, options: .regularExpression) != nil,
              source.range(of: #"(?m)^\s*//\s*==/UserScript=="#, options: .regularExpression) != nil else { throw Failure("userscript_update_invalid") }
        let result = BrowserExtensionService.parseMetadata(from: source)
        guard let name = result.name, !name.isEmpty else { throw Failure("userscript_update_invalid") }
        return result
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> (source: String, url: URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/javascript, text/javascript, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let final = response.url, final.scheme?.lowercased() == "https", final.user == nil, final.password == nil,
              !["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= BrowserExtensionService.maximumUserScriptSize else { throw BrowserExtensionError.scriptTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < BrowserExtensionService.maximumUserScriptSize else { throw BrowserExtensionError.scriptTooLarge }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BrowserExtensionError.unreadableScript }
        return (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text, final)
    }

    /// Numeric versions and dates compare numerically; a release is newer than
    /// its prerelease. Build metadata does not trigger an update.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        func parts(_ value: String) -> (String, String?) {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.first == "v" { value.removeFirst() }
            value = String(value.split(separator: "+", maxSplits: 1).first ?? "")
            let pieces = value.split(separator: "-", maxSplits: 1)
            return (String(pieces.first ?? ""), pieces.count > 1 ? String(pieces[1]) : nil)
        }
        let a = parts(candidate), b = parts(installed)
        var left = a.0.split(separator: ".").map(String.init), right = b.0.split(separator: ".").map(String.init)
        while left.last == "0" { left.removeLast() }; while right.last == "0" { right.removeLast() }
        let order = left.joined(separator: ".").compare(right.joined(separator: "."), options: .numeric)
        if order != .orderedSame { return order == .orderedDescending }
        switch (a.1, b.1) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedDescending
        }
    }

    struct Failure: LocalizedError {
        let key: String
        init(_ key: String) { self.key = key }
        var errorDescription: String? { ToolText.text(key) }
    }
}
