import Foundation

/// Strings for the library and browser refinements. Kept in a separate table so
/// translations can be checked independently of the legacy reading tools.
enum FeatureText {
    static func text(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: "app_language") ?? Locale.preferredLanguages.first ?? "en-US"
        let bundle = LocalizedResourceBundles.selected(language)
        return bundle.localizedString(forKey: key, value: key, table: "FeatureImprovements")
    }
}
