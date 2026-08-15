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
        guard localized == key,
              selectedLanguage != "en",
              let englishPath = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let englishBundle = Bundle(path: englishPath) else {
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
        Self.supportedLanguages.first { $0.id == currentLanguage }?.name ?? "English"
    }

    var currentFlag: String {
        Self.supportedLanguages.first { $0.id == currentLanguage }?.flag ?? "🇺🇸"
    }

    /// Speech locale identifier for voice recognition.
    var speechLocaleIdentifier: String {
        switch currentLanguage {
        case "zh-Hans": return "zh-Hans-CN"
        case "zh-Hant": return "zh-Hant-TW"
        case "en":      return "en-US"
        case "ja":      return "ja-JP"
        case "ko":      return "ko-KR"
        case "fr":      return "fr-FR"
        case "de":      return "de-DE"
        case "es":      return "es-ES"
        case "ru":      return "ru-RU"
        case "vi":      return "vi-VN"
        case "pt-BR":   return "pt-BR"
        case "it":      return "it-IT"
        case "tr":      return "tr-TR"
        case "ar":      return "ar-SA"
        case "th":      return "th-TH"
        default:        return "en-US"
        }
    }

    /// Convenience: localized string with single-param signature.
    func localizedString(_ key: String) -> String {
        let localized = localizedString(for: key)
        guard localized == key,
              currentLanguage != "en",
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
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
