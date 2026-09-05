import Foundation

/// Fallbacks only. Reading defaults never writes over a saved local or synced choice.
enum BrowserInitialPreferences {
    static let showTopSearchBar = false
    static func wallpaperSource(in defaults: UserDefaults) -> WallpaperSource {
        defaults.string(forKey: "wallpaper_source").flatMap(WallpaperSource.init(rawValue:)) ?? .pixabay
    }
    static func wallpaperTopic(in defaults: UserDefaults) -> String {
        defaults.string(forKey: "wallpaper_topic") ?? "Nature"
    }
}
