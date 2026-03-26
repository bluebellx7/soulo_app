import Foundation

enum AppConstants {
    static let appName = "Soulo"
    static let appVersion = "1.0"
    static let maxSearchHistoryCount = 500
    static let clipboardMaxLength = 200
    static let webViewUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static let supportedLanguages: [(code: String, name: String, flag: String)] = [
        ("zh-Hans", "简体中文", "🇨🇳"),
        ("en", "English", "🇺🇸"),
        ("ja", "日本語", "🇯🇵"),
        ("ko", "한국어", "🇰🇷"),
        ("fr", "Français", "🇫🇷"),
        ("de", "Deutsch", "🇩🇪"),
        ("es", "Español", "🇪🇸"),
        ("vi", "Tiếng Việt", "🇻🇳"),
    ]

    enum StorageKeys {
        static let platformConfig = "platform_config"
        static let lastClipboardHash = "last_clipboard_hash"
        static let selectedLanguage = "selected_language"
        static let appearance = "appearance"
        static let isIncognito = "is_incognito"
        static let autoSortByFrequency = "auto_sort_frequency"
        static let iCloudSyncEnabled = "icloud_sync_enabled"
        static let wallpaperMode = "wallpaper_mode"
        static let customWallpaperData = "custom_wallpaper_data"
        static let bingWallpaperCache = "bing_wallpapers_cache"
    }
}
