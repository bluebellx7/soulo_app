import WebKit

struct WebEpisodeAction: Codable, Equatable {
    let token: String
    let scope: String
    let isCurrent: Bool
}

struct WebEpisode: Codable, Identifiable, Equatable {
    let title: String
    let url: URL
    var resourcePageURL: URL? = nil
    var action: WebEpisodeAction? = nil
    var id: String { action.map { "button:" + $0.token } ?? url.absoluteString }

    func matchesCurrentPage(_ pageURL: URL) -> Bool {
        action?.isCurrent ?? WebEpisodeList.matches(url, pageURL)
    }

    var directMediaResource: WebMediaResource? {
        guard action == nil, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              ["m3u8", "mp4", "m4v", "mov", "webm"].contains(url.pathExtension.lowercased()) else { return nil }
        return WebMediaResource(kind: .video, url: url, title: title, posterURL: nil,
            delivery: WebResourceInspectionService.delivery(for: url), sourcePageURL: resourcePageURL)
    }

    var isResourcePlaybackURL: Bool {
        directMediaResource != nil || url.path.range(
            of: #"/(?:play(?:er)?|vodplay|watch|episodes?|vplay|share)(?:[/.\-_]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
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
        sources.first { source in source.episodes.contains { $0.matchesCurrentPage(pageURL) } } ?? sources.first
    }

    var actionScope: String? {
        let scopes = Set(sources.flatMap(\.episodes).compactMap { $0.action?.scope })
        return scopes.count == 1 ? scopes.first : nil
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
            var seen = Set<String>()
            let episodes = source.episodes.filter { item in
                !item.title.isEmpty && item.title.count <= 160
                    && ["http", "https"].contains(item.url.scheme?.lowercased() ?? "")
                    && item.url.host != nil && item.url.user == nil && item.url.password == nil
                    && (item.resourcePageURL.map { matches($0, pageURL) } ?? true)
                    && (item.action.map { action in
                        UUID(uuidString: action.token) != nil && UUID(uuidString: action.scope) != nil
                            && matches(item.url, pageURL)
                    } ?? true)
                    && (Self.belongsToEpisodeSite(item.url, pageURL: pageURL)
                        || (item.resourcePageURL != nil && item.isResourcePlaybackURL))
                    && seen.insert(item.id).inserted
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

enum WebOverlayControlsRuntime {
    static let source: String = {
        guard let url = Bundle.main.url(forResource: "overlay-controls", withExtension: "js", subdirectory: "UserScripts") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
}

enum WebEpisodeRuntime {
    static let world = WKContentWorld.world(name: "SouloEpisodes")
    static let handler = "souloEpisodes"
    // Prefer real links. Button-only SPA catalogs keep opaque, document-bound
    // actions; only an explicit episode selection can activate a registered node.
    static let script: String = {
        guard let url = Bundle.main.url(forResource: "episode-detector", withExtension: "js", subdirectory: "UserScripts") else { return "" }
        return WebOverlayControlsRuntime.source + "\n" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }()

    @MainActor static func configuredScript(enabled: Bool) -> String {
        let defaults = UserDefaults.standard
        let configuration: [String: Any] = ["enabled": enabled,
            "dockEnabled": VideoPlaybackPreferences.showsEpisodeDock(),
            "watchChanges": VideoPlaybackPreferences.showsEpisodeDock() || VideoPlaybackPreferences.showsTools(),
            "label": ToolText.text("episodes"),
            "edge": defaults.string(forKey: "web_episode_dock_edge") ?? "right",
            "fraction": defaults.object(forKey: "web_episode_dock_fraction") as? Double ?? 0.62]
        let json = (try? JSONSerialization.data(withJSONObject: configuration))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return script + "\nwindow.__souloEpisodes?.configure(\(json));"
    }

    @MainActor static func activate(_ episode: WebEpisode, in webView: WKWebView) async throws {
        guard let action = episode.action,
              let current = webView.url, current.scheme == episode.url.scheme,
              current.host == episode.url.host else { throw WebEpisodeDownloadError.unavailable }
        let result = try await webView.callAsyncJavaScript(
            "return window.__souloEpisodes?.activate(token,scope)===true;",
            arguments: ["token": action.token, "scope": action.scope], in: nil, contentWorld: world)
        guard result as? Bool == true else { throw WebEpisodeDownloadError.unavailable }
    }

    @MainActor static func resolveActionMedia(_ episode: WebEpisode, in webView: WKWebView,
                                             timeout: TimeInterval, excluding previousResourceURL: URL? = nil) async throws -> WebMediaResource {
        func current() async -> WebMediaResource? {
            let token = (try? await webView.evaluateJavaScript("Array.from(document.querySelectorAll('video[data-soulo-media-id]')).sort((a,b)=>b.getBoundingClientRect().width*b.getBoundingClientRect().height-a.getBoundingClientRect().width*a.getBoundingClientRect().height)[0]?.getAttribute('data-soulo-media-id')??'__soulo_configured'")) as? String ?? "__soulo_configured"
            return await WebResourceInspectionService.currentVideoResource(webView:webView,frame:nil,token:token)
        }
        let before = await current()
        try await activate(episode,in:webView)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var previous: URL?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let media = await current(), media.delivery != .dash, media.url != previousResourceURL,
               media.url != before?.url || episode.action?.isCurrent == true {
                if previous == media.url {
                    _ = try? await webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v=>v.pause());true")
                    return WebMediaResource(kind:.video,url:media.url,title:episode.title,posterURL:media.posterURL,
                        delivery:media.delivery,companionAudioURL:media.companionAudioURL,
                        sourcePageURL:media.sourcePageURL ?? webView.url)
                }
                previous = media.url
            } else { previous = nil }
            try await Task.sleep(for:.milliseconds(250))
        }
        throw WebEpisodeDownloadError.unavailable
    }

}
