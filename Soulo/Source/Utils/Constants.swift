import Foundation

enum AppConstants {
    static let appName = "Soulo"
    static let appVersion = "1.1.4"
    static let maxSearchHistoryCount = 500
    static let clipboardMaxLength = 200
    static let mobileWebViewUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let desktopWebViewUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let webViewUserAgent = mobileWebViewUserAgent

    static let supportedLanguages: [(code: String, name: String, flag: String)] = [
        ("ar-SA", "العربية", "🇸🇦"),
        ("bn-BD", "বাংলা", "🇧🇩"),
        ("ca", "Català", "🇪🇸"),
        ("zh-Hans", "简体中文", "🇨🇳"),
        ("zh-Hant", "繁體中文", "🇹🇼"),
        ("hr", "Hrvatski", "🇭🇷"),
        ("cs", "Čeština", "🇨🇿"),
        ("da", "Dansk", "🇩🇰"),
        ("nl-NL", "Nederlands", "🇳🇱"),
        ("en-AU", "English (Australia)", "🇦🇺"),
        ("en-CA", "English (Canada)", "🇨🇦"),
        ("en-GB", "English (UK)", "🇬🇧"),
        ("en-US", "English (US)", "🇺🇸"),
        ("fi", "Suomi", "🇫🇮"),
        ("fr-FR", "Français", "🇫🇷"),
        ("fr-CA", "Français (Canada)", "🇨🇦"),
        ("de-DE", "Deutsch", "🇩🇪"),
        ("el", "Ελληνικά", "🇬🇷"),
        ("gu-IN", "ગુજરાતી", "🇮🇳"),
        ("he", "עברית", "🇮🇱"),
        ("hi", "हिन्दी", "🇮🇳"),
        ("hu", "Magyar", "🇭🇺"),
        ("id", "Bahasa Indonesia", "🇮🇩"),
        ("it", "Italiano", "🇮🇹"),
        ("ja", "日本語", "🇯🇵"),
        ("kn-IN", "ಕನ್ನಡ", "🇮🇳"),
        ("ko", "한국어", "🇰🇷"),
        ("ms", "Bahasa Melayu", "🇲🇾"),
        ("ml-IN", "മലയാളം", "🇮🇳"),
        ("mr-IN", "मराठी", "🇮🇳"),
        ("no", "Norsk", "🇳🇴"),
        ("or-IN", "ଓଡ଼ିଆ", "🇮🇳"),
        ("pl", "Polski", "🇵🇱"),
        ("pt-BR", "Português", "🇧🇷"),
        ("pt-PT", "Português (Portugal)", "🇵🇹"),
        ("pa-IN", "ਪੰਜਾਬੀ", "🇮🇳"),
        ("ro", "Română", "🇷🇴"),
        ("ru", "Русский", "🇷🇺"),
        ("sk", "Slovenčina", "🇸🇰"),
        ("sl-SI", "Slovenščina", "🇸🇮"),
        ("es-MX", "Español (México)", "🇲🇽"),
        ("es-ES", "Español (España)", "🇪🇸"),
        ("sv", "Svenska", "🇸🇪"),
        ("ta-IN", "தமிழ்", "🇮🇳"),
        ("te-IN", "తెలుగు", "🇮🇳"),
        ("tr", "Türkçe", "🇹🇷"),
        ("th", "ไทย", "🇹🇭"),
        ("uk", "Українська", "🇺🇦"),
        ("ur-PK", "اردو", "🇵🇰"),
        ("vi", "Tiếng Việt", "🇻🇳"),
    ]

    static func canonicalLanguageCode(_ rawCode: String) -> String {
        let normalized = rawCode.replacingOccurrences(of: "_", with: "-")
        if let exact = supportedLanguages.first(where: {
            $0.code.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact.code
        }

        let components = normalized.split(separator: "-").map(String.init)
        let language = components.first?.lowercased() ?? "en"
        let region = components.dropFirst().first(where: { $0.count == 2 })?.uppercased()
        if language == "zh" {
            let usesTraditional = components.contains { $0.caseInsensitiveCompare("Hant") == .orderedSame }
                || ["HK", "MO", "TW"].contains(region ?? "")
            return usesTraditional ? "zh-Hant" : "zh-Hans"
        }

        let regionalDefaults: [String: String] = [
            "ar": "ar-SA", "bn": "bn-BD", "de": "de-DE", "en": "en-US",
            "es": region == "MX" ? "es-MX" : "es-ES",
            "fr": region == "CA" ? "fr-CA" : "fr-FR",
            "nl": "nl-NL", "pt": region == "BR" ? "pt-BR" : "pt-PT",
            "sl": "sl-SI", "ur": "ur-PK"
        ]
        if let fallback = regionalDefaults[language] { return fallback }
        return supportedLanguages.first {
            $0.code.split(separator: "-").first?.lowercased() == language
        }?.code ?? "en-US"
    }

    static func preferredLanguageCode(from preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        canonicalLanguageCode(preferredLanguages.first ?? "en-US")
    }

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
        static let shakeIntensity = "browser_shake_intensity"
        static let browserToolbarActions = "browser_toolbar_actions"
        static let browserToolbarAddressAction = "browser_toolbar_address_action"
        static let browserToolbarHidden = "browser_toolbar_hidden"
        static let wallpaperMode = "wallpaper_mode"
        static let customWallpaperData = "custom_wallpaper_data"
        static let bingWallpaperCache = "bing_wallpapers_cache"
    }
}
