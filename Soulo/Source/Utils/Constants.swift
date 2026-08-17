import Foundation

enum AppConstants {
    static let appName = "Soulo"
    static let appVersion = "1.1.2"
    static let maxSearchHistoryCount = 500
    static let clipboardMaxLength = 200
    static let mobileWebViewUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let desktopWebViewUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let webViewUserAgent = mobileWebViewUserAgent

    static let supportedLanguages: [(code: String, name: String, flag: String)] = [
        ("en", "English", "🇺🇸"),
        ("zh-Hans", "简体中文", "🇨🇳"),
        ("zh-Hant", "繁體中文", "🇭🇰"),
        ("ja", "日本語", "🇯🇵"),
        ("ko", "한국어", "🇰🇷"),
        ("fr", "Français", "🇫🇷"),
        ("de", "Deutsch", "🇩🇪"),
        ("es", "Español", "🇪🇸"),
        ("it", "Italiano", "🇮🇹"),
        ("ru", "Русский", "🇷🇺"),
        ("pt-BR", "Português", "🇧🇷"),
        ("tr", "Türkçe", "🇹🇷"),
        ("th", "ไทย", "🇹🇭"),
        ("vi", "Tiếng Việt", "🇻🇳"),
        ("ar", "العربية", "🇸🇦"),
    ]

    enum StorageKeys {
        static let platformConfig = "platform_config"
        static let lastClipboardHash = "last_clipboard_hash"
        static let selectedLanguage = "app_language"
        static let appearance = "appearance"
        static let isIncognito = "is_incognito"
        static let iCloudSyncEnabled = "icloud_sync_enabled"
        static let keepFullscreenBrowsing = "keep_fullscreen_browsing"
        static let webFollowsAppColorScheme = "web_follows_app_color_scheme"
        static let webWarmColorShift = "web_warm_color_shift"
        static let webForceDarkPages = "web_force_dark_pages"
        static let webReducePageMotion = "web_reduce_page_motion"
        static let webUnderlineLinks = "web_underline_links"
        static let shakeAction = "browser_shake_action"
        static let browserToolbarActions = "browser_toolbar_actions"
        static let browserToolbarAddressAction = "browser_toolbar_address_action"
        static let browserToolbarHidden = "browser_toolbar_hidden"
        static let wallpaperMode = "wallpaper_mode"
        static let customWallpaperData = "custom_wallpaper_data"
        static let bingWallpaperCache = "bing_wallpapers_cache"
    }
}
