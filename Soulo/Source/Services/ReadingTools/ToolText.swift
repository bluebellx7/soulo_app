import Foundation

/// Prefer the tool-specific wording, then shared app labels, then English.
enum ToolText {
    // Explicit mappings avoid mixing meanings such as book bookmarks and web favorites.
    static let sharedKeys = [
        "files": "library_files_tab", "bookshelf": "library_books_tab",
        "done": "done", "cancel": "cancel", "retry": "retry", "search": "search",
        "share": "share", "delete_files": "delete", "pause": "pause",
        "loading": "loading", "copied": "copied"
    ]

    static func text(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: "app_language") ?? Locale.preferredLanguages.first ?? "en-US"
        return text(key, language: language)
    }

    static func text(_ key: String, language: String) -> String {
        let resolved = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [language]).first ?? "en-US"
        let selected = Bundle.main.path(forResource: resolved, ofType: "lproj").flatMap(Bundle.init(path:))
        let english = Bundle.main.path(forResource: "en-US", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        if let localized = selected?.localizedString(forKey: key, value: key, table: "ReadingTools"), localized != key {
            return localized
        }
        if let sharedKey = sharedKeys[key],
           let localized = selected?.localizedString(forKey: sharedKey, value: sharedKey, table: nil), localized != sharedKey {
            return localized
        }
        let fallback = english.localizedString(forKey: key, value: key, table: "ReadingTools")
        return fallback
    }
}
