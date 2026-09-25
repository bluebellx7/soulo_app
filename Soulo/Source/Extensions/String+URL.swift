import Foundation

extension String {
    var isValidURL: Bool {
        BrowserNavigationResolver.webURL(for: self) != nil
    }

    var percentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    func asSearchURL(template: String) -> URL? {
        let urlString = template.replacingOccurrences(of: "%@", with: percentEncoded)
        return URL(string: urlString)
    }

    var asURL: URL? {
        BrowserNavigationResolver.webURL(for: self)
    }
}

enum BrowserInputKind: Equatable {
    case webpage(URL)
    case search(String)
}

enum BrowserNavigationResolver {
    static func classify(_ input: String) -> BrowserInputKind? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = webURL(for: trimmed) else { return .search(trimmed) }
        return .webpage(url)
    }

    static func webURL(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let hasExplicitScheme = trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        guard hasExplicitScheme || !trimmed.contains("@") else { return nil }
        let candidate = hasExplicitScheme ? trimmed : "https://\(trimmed)"
        guard let parts = URLComponents(string: candidate),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, isPlausibleHost(host),
              let url = parts.url else { return nil }
        return url
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        if host.contains(":") { return true } // IPv6 literal, validated by URLComponents.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) {
            return true
        }
        guard labels.count >= 2,
              let topLevel = labels.last, topLevel.count >= 2,
              topLevel.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "-" }) else {
            return false
        }
        return labels.allSatisfy { label in
            guard let first = label.first, let last = label.last,
                  first != "-", last != "-" else { return false }
            return label.unicodeScalars.allSatisfy {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-"
            }
        }
    }

    /// Resolves omnibox input without ever executing custom URL schemes.
    /// Plain hosts become HTTPS URLs; everything else becomes a search query.
    static func resolve(_ input: String, preferredSearchPlatform: SearchPlatform? = nil) -> URL? {
        guard let kind = classify(input) else { return nil }
        switch kind {
        case .webpage(let url): return url
        case .search(let query):
            if preferredSearchPlatform?.interactionType == .urlSearch,
               let searchURL = preferredSearchPlatform?.searchURL(for: query) {
                return searchURL
            }
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
            return components?.url
        }
    }
}
