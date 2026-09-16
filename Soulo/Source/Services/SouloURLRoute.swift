import Foundation

/// Pure parser shared by external URL entry and its regression tests.
/// Query values are decoded exactly once by URLComponents.
enum SouloURLRoute: Equatable {
    case home
    case search(String?)
    case open(URL)
    case download(URL)
    case scan
    case files
    case bookmarks
    case history
    case downloads

    static func parse(_ url: URL) -> Self? {
        guard url.scheme?.lowercased() == "soulo",
              let separator = url.absoluteString.range(of: "://"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let tail = String(url.absoluteString[separator.upperBound...])
        let command = (components.host ?? "").lowercased()
        func query(_ names: [String]) -> String? {
            components.queryItems?.first(where: { names.contains($0.name.lowercased()) })?.value
        }
        func argument(_ names: [String]) -> String? {
            let path = String(components.percentEncodedPath.drop(while: { $0 == "/" }))
            guard !path.isEmpty else { return query(names) }
            // Legacy path form may contain a nested URL with its own query/fragment.
            if let slash = tail.firstIndex(of: "/") {
                return decodedArgument(String(tail[tail.index(after: slash)...]))
            }
            return nil
        }
        switch command {
        case "", "home": return .home
        case "action": return nil // Reserved for App Intents/share-extension handoff.
        case "search":
            let value = argument(["q", "text", "query"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .search(value.flatMap { $0.isEmpty ? nil : $0 })
        case "open":
            return argument(["url"]).flatMap(webURL).map(Self.open)
        case "download":
            return argument(["url"]).flatMap(webURL).map(Self.download)
        case "qrcode", "scan": return .scan
        case "files", "books", "bookshelf": return .files
        case "bookmarks": return .bookmarks
        case "history": return .history
        case "downloads": return .downloads
        default:
            // Short form: soulo://<search text or http(s) URL>.
            guard let value = decodedArgument(tail), !value.isEmpty else { return nil }
            if let target = webURL(value) { return .open(target) }
            // Do not turn unsupported nested schemes into a navigation command.
            guard !value.contains("://") else { return nil }
            return .search(value)
        }
    }

    private static func decodedArgument(_ value: String) -> String? {
        // Preserve a nested URL's own percent escapes, query and fragment.
        if value.lowercased().hasPrefix("https://") || value.lowercased().hasPrefix("http://") { return value }
        return value.removingPercentEncoding
    }

    private static func webURL(_ value: String) -> URL? {
        guard !value.contains(where: \.isWhitespace),
              let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              !(parts.host ?? "").isEmpty else { return nil }
        return parts.url
    }
}
