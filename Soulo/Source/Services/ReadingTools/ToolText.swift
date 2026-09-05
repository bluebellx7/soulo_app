import Foundation

/// New reading tools use their own table; untranslated languages fall back to English.
enum ToolText {
    static func text(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: "app_language") ?? Locale.preferredLanguages.first ?? "en-US"
        let selected = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let english = Bundle.main.path(forResource: "en-US", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let fallback = english.localizedString(forKey: key, value: key, table: "ReadingTools")
        return selected?.localizedString(forKey: key, value: fallback, table: "ReadingTools") ?? fallback
    }
}
