import WebKit

struct WebEpisode: Codable, Identifiable, Equatable {
    let title: String
    let url: URL
    var resourcePageURL: URL? = nil
    var id: String { url.absoluteString }

    var directMediaResource: WebMediaResource? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              ["m3u8", "mp4", "m4v", "mov", "webm"].contains(url.pathExtension.lowercased()) else { return nil }
        return WebMediaResource(kind: .video, url: url, title: title, posterURL: nil,
            delivery: WebResourceInspectionService.delivery(for: url), sourcePageURL: resourcePageURL)
    }

    var isResourcePlaybackURL: Bool {
        directMediaResource != nil || url.path.range(
            of: #"/(?:play(?:er)?|vodplay|watch|episodes?|vplay)/"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct WebEpisodeSource: Codable, Identifiable, Equatable {
    let title: String
    let episodes: [WebEpisode]
    var id: String { episodes.first?.id ?? title }
}

struct WebEpisodeList: Codable, Equatable {
    let pageURL: URL
    let sources: [WebEpisodeSource]

    var currentSource: WebEpisodeSource? {
        sources.first { source in source.episodes.contains { Self.matches($0.url, pageURL) } } ?? sources.first
    }

    static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        func normalized(_ url: URL) -> URL? {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
            parts?.fragment = nil
            if let host = url.host?.lowercased(), host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
               url.path.hasPrefix("/video/") {
                var items = (parts?.queryItems ?? []).filter { $0.name == "p" }
                if items.isEmpty { items.append(URLQueryItem(name: "p", value: "1")) }
                parts?.queryItems = items
                if parts?.path.hasSuffix("/") == true { parts?.path.removeLast() }
            } else if let host = url.host?.lowercased(), host == "youku.com" || host.hasSuffix(".youku.com"),
                      url.path.hasPrefix("/v_show/") {
                parts?.queryItems = nil
            }
            return parts?.url
        }
        return normalized(lhs) == normalized(rhs)
    }

    static func parse(_ body: [String: Any], pageURL: URL) -> Self? {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let list = try? JSONDecoder().decode(Self.self, from: data),
              matches(list.pageURL, pageURL), list.sources.count <= 20,
              list.sources.reduce(0, { $0 + $1.episodes.count }) <= 5_000 else { return nil }
        let sources = list.sources.compactMap { source -> WebEpisodeSource? in
            var seen = Set<URL>()
            let episodes = source.episodes.filter {
                !$0.title.isEmpty && $0.title.count <= 160
                    && ["http", "https"].contains($0.url.scheme?.lowercased() ?? "")
                    && $0.url.host != nil
                    && $0.url.user == nil && $0.url.password == nil
                    && ($0.resourcePageURL.map { matches($0, pageURL) } ?? true)
                    && (Self.belongsToEpisodeSite($0.url, pageURL: pageURL)
                        || ($0.resourcePageURL != nil && $0.isResourcePlaybackURL))
                    && seen.insert($0.url).inserted
            }
            return episodes.isEmpty ? nil : WebEpisodeSource(title: String(source.title.prefix(100)), episodes: episodes)
        }
        return sources.isEmpty ? nil : Self(pageURL: pageURL, sources: sources)
    }

    private static func belongsToEpisodeSite(_ url: URL, pageURL: URL) -> Bool {
        guard let host = url.host?.lowercased(), let origin = pageURL.host?.lowercased() else { return false }
        if host == origin { return true }
        return ["bilibili.com", "youku.com"].contains { domain in
            (host == domain || host.hasSuffix("." + domain)) && (origin == domain || origin.hasSuffix("." + domain))
        }
    }
}

enum WebEpisodeRuntime {
    static let world = WKContentWorld.world(name: "SouloEpisodes")
    static let handler = "souloEpisodes"
    // Read DOM links only. Never evaluate a site's player configuration or click
    // its controls: native navigation avoids delegated advertising handlers.
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "episode-detector", withExtension: "js", subdirectory: "UserScripts") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @MainActor static func configuredScript(enabled: Bool) -> String {
        let defaults = UserDefaults.standard
        let configuration: [String: Any] = ["enabled": enabled, "label": ToolText.text("episodes"),
            "edge": defaults.string(forKey: "web_episode_dock_edge") ?? "right",
            "fraction": defaults.object(forKey: "web_episode_dock_fraction") as? Double ?? 0.62]
        let json = (try? JSONSerialization.data(withJSONObject: configuration))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return script + "\nwindow.__souloEpisodes?.configure(\(json));"
    }

}
