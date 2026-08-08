import Foundation

extension String {
    var isValidURL: Bool {
        if let url = URL(string: self), url.scheme != nil, url.host != nil {
            return true
        }
        let pattern = #"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+(/.*)?$"#
        return range(of: pattern, options: .regularExpression) != nil
    }

    var percentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    func asSearchURL(template: String) -> URL? {
        let urlString = template.replacingOccurrences(of: "%@", with: percentEncoded)
        return URL(string: urlString)
    }

    var asURL: URL? {
        if let url = URL(string: self), url.scheme != nil {
            return url
        }
        if isValidURL {
            return URL(string: "https://\(self)")
        }
        return nil
    }
}

enum BrowserNavigationResolver {
    /// Resolves omnibox input without ever executing custom URL schemes.
    /// Plain hosts become HTTPS URLs; everything else becomes a search query.
    static func resolve(_ input: String, preferredSearchPlatform: SearchPlatform? = nil) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let explicitURL = URL(string: trimmed),
           let scheme = explicitURL.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           explicitURL.host != nil {
            return explicitURL
        }

        let declaredScheme = URLComponents(string: trimmed)?.scheme
        if declaredScheme == nil,
           !trimmed.contains(where: \.isWhitespace),
           trimmed.contains("."),
           let hostURL = URL(string: "https://\(trimmed)"),
           hostURL.host != nil {
            return hostURL
        }

        if preferredSearchPlatform?.interactionType == .urlSearch,
           let searchURL = preferredSearchPlatform?.searchURL(for: trimmed) {
            return searchURL
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}
