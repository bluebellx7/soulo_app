import Foundation

enum WebNavigationDecision: Equatable {
    case allow
    case cancel
    case external(URL)
}

struct WebNavigationPolicyService {
    static let shared = WebNavigationPolicyService()

    private let webSchemes: Set<String> = ["http", "https", "about", "blob", "data"]
    private let externalDomains: [String] = [
        "apps.apple.com", "itunes.apple.com",
        "music.apple.com", "podcasts.apple.com", "books.apple.com",
        "maps.apple.com", "tv.apple.com",
        "open.spotify.com",
        "play.google.com",
        "t.me", "telegram.me",
        "line.me",
        "wa.me", "api.whatsapp.com",
    ]

    func decision(for url: URL) -> WebNavigationDecision {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""

        guard webSchemes.contains(scheme) else {
            return .external(url)
        }

        if externalDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return .external(url)
        }

        return .allow
    }
}
