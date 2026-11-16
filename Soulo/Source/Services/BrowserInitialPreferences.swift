import Foundation

enum PlatformBarPreferences {
    static let visibilityKey = "show_platform_bar"
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

/// Fallbacks only. Reading defaults never writes over a saved local or synced choice.
enum BrowserInitialPreferences {
    static let showTopSearchBar = false
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
