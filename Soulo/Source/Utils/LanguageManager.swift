@_exported import DKlugeI18n

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
        case "ja":      return "ja-JP"
        case "ko":      return "ko-KR"
        case "fr":      return "fr-FR"
        case "de":      return "de-DE"
        case "es":      return "es-ES"
        default:        return "en-US"
        }
    }

    /// Convenience: localized string with single-param signature.
    func localizedString(_ key: String) -> String {
        localizedString(for: key)
    }
}
