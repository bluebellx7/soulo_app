import Foundation
@_exported import DKlugeI18n

/// Thread-safe localization for error descriptions and other protocol
/// requirements that cannot call the main-actor LanguageManager directly.
/// Missing strings fall back to English instead of exposing an internal key.
enum AppLocalization {
    static func string(_ key: String) -> String {
        let selectedLanguage = UserDefaults.standard.string(forKey: "app_language")
        let selectedBundle = selectedLanguage
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:))
        let localized = (selectedBundle ?? .main).localizedString(
            forKey: key,
            value: key,
            table: nil
        )
        let englishBundle = ["en-US", "en"]
            .compactMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .compactMap(Bundle.init(path:))
            .first
        guard localized == key, let englishBundle else {
            return localized
        }
        return englishBundle.localizedString(forKey: key, value: key, table: nil)
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
        let bundle = ["en-US", "en"]
            .compactMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .compactMap(Bundle.init(path:))
            .first
        guard localized == key, let bundle else {
            return localized
        }
        return NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle,
            value: key,
            comment: ""
        )
    }
}
