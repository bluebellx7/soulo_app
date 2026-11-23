import Foundation

enum PlatformBarPreferences {
    static let visibilityKey = "show_platform_bar"
    static let homeQuickSearchKey = "home_quick_search"
    static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: visibilityKey) == nil || defaults.bool(forKey: visibilityKey)
    }
    static func autoHides(in defaults: UserDefaults = .standard) -> Bool {
        isVisible(in: defaults) && defaults.bool(forKey: "auto_hide_platform_bar")
    }
    @MainActor static var hiddenHint: String {
        String(format: ToolText.text("platform_bar_hidden_hint"), ToolText.text("toolbar_platforms"),
               LanguageManager.shared.localizedString("toolbar_customize"))
    }
    @MainActor static var disabledHint: String {
        String(format: ToolText.text("platform_bar_disabled_hint"), ToolText.text("show_platform_bar"))
    }
}

/// Match the actual platform bar's HTTP(S) origins without a network lookup.
/// Keep sibling mobile/www hosts together, while respecting hostname labels
/// (google.co.kr must never match every other site under co.kr).
enum PlatformBarDomainPolicy {
    struct Source: Equatable {
        let id: UUID
        let homeURL: String
        let searchURLTemplate: String

        init(_ platform: SearchPlatform) {
            id = platform.id
            homeURL = platform.homeURL
            searchURLTemplate = platform.searchURLTemplate
        }
    }

    struct Entry {
        let id: UUID
        let hosts: Set<String>
    }

    static func entries(for sources: [Source]) -> [Entry] {
        sources.map { Entry(id: $0.id, hosts: hosts(from: [$0.homeURL, $0.searchURLTemplate])) }
    }

    static func hosts(for platforms: [SearchPlatform]) -> Set<String> {
        hosts(from: Set(platforms.flatMap { [$0.homeURL, $0.searchURLTemplate] }))
    }

    static func hosts(from sources: Set<String>) -> Set<String> {
        Set(sources.compactMap { URL(string: $0.replacingOccurrences(of: "%@", with: "soulo")) }.compactMap(host))
    }

    static func host(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let raw = url.host else { return nil }
        var value = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        while let prefix = ["www.", "m.", "mobile."].first(where: { value.hasPrefix($0) }) {
            value.removeFirst(prefix.count)
        }
        return value.isEmpty ? nil : value
    }

    static func matches(_ url: URL?, hosts: Set<String>) -> Bool {
        guard let url, let current = host(url) else { return false }
        return hosts.contains { matches(current, candidate: $0) }
    }

    /// A display-only match must never change the selected search engine or load a URL.
    /// Prefer the most specific host, then the user's selection, then bar order.
    static func highlightedPlatformID(for url: URL?, entries: [Entry], preferredID: UUID?) -> UUID? {
        guard let url, let current = host(url) else { return nil }
        var result: UUID?
        var specificity = 0
        for entry in entries {
            let score = entry.hosts.filter { matches(current, candidate: $0) }.map(\.count).max() ?? 0
            if score > specificity || (score > 0 && score == specificity && entry.id == preferredID) {
                result = entry.id
                specificity = score
            }
        }
        return result
    }

    private static func matches(_ current: String, candidate: String) -> Bool {
        current == candidate || (!candidate.contains(":")
            && !candidate.allSatisfy { $0.isNumber || $0 == "." }
            && current.hasSuffix("." + candidate))
    }
}

/// Fallbacks only. Reading defaults never writes over a saved local or synced choice.
enum BrowserInitialPreferences {
    static let restoreLastPageKey = "restore_last_page_on_launch"
    static let extendPageBackground = true
    static let defaultWallpaperTopic = "Nature"
    static func extendsPageBackground(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppConstants.StorageKeys.extendPageBackground) != nil else {
            return extendPageBackground
        }
        return defaults.bool(forKey: AppConstants.StorageKeys.extendPageBackground)
    }
    static func wallpaperSource(in defaults: UserDefaults) -> WallpaperSource {
        defaults.string(forKey: "wallpaper_source").flatMap(WallpaperSource.init(rawValue:)) ?? .pixabay
    }
    static func wallpaperTopic(in defaults: UserDefaults) -> String {
        defaults.string(forKey: "wallpaper_topic") ?? defaultWallpaperTopic
    }
    static func wallpaperVibeTags(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: "wallpaper_vibe_tags") ?? [defaultWallpaperTopic]
    }
}
