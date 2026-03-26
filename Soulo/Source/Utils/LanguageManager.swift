import SwiftUI
import Combine

class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @AppStorage("selected_language") var selectedLanguage: String = LanguageManager.detectInitialLanguage()

    @Published var locale: Locale

    private init() {
        let lang = UserDefaults.standard.string(forKey: "selected_language") ?? Self.detectInitialLanguage()
        self.locale = Locale(identifier: lang)
    }

    func setLanguage(_ languageCode: String) {
        selectedLanguage = languageCode
        locale = Locale(identifier: languageCode)
        objectWillChange.send()
    }

    var currentLanguageName: String {
        AppConstants.supportedLanguages.first { $0.code == selectedLanguage }?.name ?? "English"
    }

    var currentFlag: String {
        AppConstants.supportedLanguages.first { $0.code == selectedLanguage }?.flag ?? "🇺🇸"
    }

    /// The speech locale identifier for voice recognition (e.g. "zh-Hans-CN", "en-US", "ja-JP")
    var speechLocaleIdentifier: String {
        switch selectedLanguage {
        case "zh-Hans": return "zh-Hans-CN"
        case "ja":      return "ja-JP"
        case "ko":      return "ko-KR"
        case "fr":      return "fr-FR"
        case "de":      return "de-DE"
        case "es":      return "es-ES"
        case "vi":      return "vi-VN"
        default:        return "en-US"
        }
    }

    func localizedString(_ key: String) -> String {
        let lang = resolvedLanguage(selectedLanguage)
        // Try selected language bundle
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let sentinel = "§§NOT_FOUND§§"
            let result = bundle.localizedString(forKey: key, value: sentinel, table: nil)
            if result != sentinel { return result }
        }
        // Fallback: English bundle
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let sentinel = "§§NOT_FOUND§§"
            let result = bundle.localizedString(forKey: key, value: sentinel, table: nil)
            if result != sentinel { return result }
        }
        // Last resort
        return key
    }

    // MARK: - Private

    /// Map system language codes to our lproj directory names
    private func resolvedLanguage(_ code: String) -> String {
        // System may return "zh" but our folder is "zh-Hans"
        switch code {
        case "zh", "zh-Hans", "zh-CN", "zh-SG": return "zh-Hans"
        case "zh-Hant", "zh-TW", "zh-HK":      return "zh-Hans" // fallback to simplified
        default: return code
        }
    }

    /// Detect the best initial language based on system locale
    private static func detectInitialLanguage() -> String {
        // Check preferred languages first
        for preferred in Locale.preferredLanguages {
            let code = Locale(identifier: preferred).language.languageCode?.identifier ?? ""
            if code == "zh" || preferred.hasPrefix("zh-Hans") {
                return "zh-Hans"
            }
            if let match = AppConstants.supportedLanguages.first(where: { $0.code == code }) {
                return match.code
            }
        }
        return "en"
    }
}
