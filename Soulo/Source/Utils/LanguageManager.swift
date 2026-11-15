import Foundation
@_exported import DKlugeI18n

/// Resource bundles are immutable for the installed app. Cache only bundle
/// selection; the chosen language is still read afresh on every lookup.
enum LocalizedResourceBundles {
    private static let localizations = Bundle.main.localizations
    private static let cache: NSCache<NSString, Bundle> = {
        let cache = NSCache<NSString, Bundle>(); cache.countLimit = 64; return cache
    }()
    static let english = ["en-US", "en"].compactMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
        .compactMap(Bundle.init(path:)).first ?? .main

    static func selected(_ language: String, preferred: Bool = true) -> Bundle {
        let key = (preferred ? "preferred:" : "exact:") + language
        if let bundle = cache.object(forKey: key as NSString) { return bundle }
        let resolved = preferred
            ? Bundle.preferredLocalizations(from: localizations, forPreferences: [language]).first ?? "en-US"
            : language
        let bundle = Bundle.main.path(forResource: resolved, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        cache.setObject(bundle, forKey: key as NSString)
        return bundle
    }
}

/// Thread-safe localization for error descriptions and other protocol
/// requirements that cannot call the main-actor LanguageManager directly.
/// Missing strings fall back to English instead of exposing an internal key.
enum AppLocalization {
    static func string(_ key: String) -> String {
        let selectedLanguage = UserDefaults.standard.string(forKey: "app_language")
        let selectedBundle = selectedLanguage.map { LocalizedResourceBundles.selected($0, preferred: false) }
        let localized = (selectedBundle ?? .main).localizedString(
            forKey: key,
            value: key,
            table: nil
        )
        guard localized == key else { return localized }
        return LocalizedResourceBundles.english.localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - Soulo-specific compatibility

extension LanguageManager {
    /// Alias for currentLanguage (Soulo call sites use selectedLanguage).
    var selectedLanguage: String {
        get { currentLanguage }
        set { currentLanguage = newValue }
    }

    var currentLanguageName: String {
        AppConstants.supportedLanguages.first { $0.code == currentLanguage }?.name ?? "English"
    }

    var currentFlag: String {
        AppConstants.supportedLanguages.first { $0.code == currentLanguage }?.flag ?? "🇺🇸"
    }

    /// Speech locale identifier for voice recognition.
    var speechLocaleIdentifier: String {
        switch currentLanguage {
        case "zh-Hans": return "zh-Hans-CN"
        case "zh-Hant": return "zh-Hant-TW"
        case "en", "en-US": return "en-US"
        case "en-AU": return "en-AU"
        case "en-CA": return "en-CA"
        case "en-GB": return "en-GB"
        case "ja":      return "ja-JP"
        case "ko":      return "ko-KR"
        case "fr", "fr-FR": return "fr-FR"
        case "fr-CA": return "fr-CA"
        case "de", "de-DE": return "de-DE"
        case "es", "es-ES": return "es-ES"
        case "es-MX": return "es-MX"
        case "ru":      return "ru-RU"
        case "vi":      return "vi-VN"
        case "pt-BR":   return "pt-BR"
        case "it":      return "it-IT"
        case "tr":      return "tr-TR"
        case "ar", "ar-SA": return "ar-SA"
        case "th":      return "th-TH"
        default:        return "en-US"
        }
    }

    /// Convenience: localized string with single-param signature.
    func localizedString(_ key: String) -> String {
        let localized = localizedString(for: key)
        guard localized == key else { return localized }
        return NSLocalizedString(
            key,
            tableName: nil,
            bundle: LocalizedResourceBundles.english,
            value: key,
            comment: ""
        )
    }
}
