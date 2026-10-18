import Foundation

public enum AIL10n {
    @MainActor private static var traditionalText: [String: String] = [:]
    static var resourceBundle: Bundle { .module }
    public static var language: String { UserDefaults.standard.string(forKey: "app_language") ?? Locale.preferredLanguages.first ?? "en" }
    public static func text(_ key: String) -> String {
        let locale = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: [language]).first ?? "en"
        let bundle = Bundle.module.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.module
        return bundle.localizedString(forKey: key, value: nil, table: "LocalAI")
    }
    /// Host-owned tool labels follow the same language fallback as the package UI.
    @MainActor public static func interfaceText(_ simplified: String, _ english: String) -> String {
        let locale = Bundle.preferredLocalizations(from: Bundle.module.localizations, forPreferences: [language]).first ?? "en"
        guard locale.hasPrefix("zh") else { return english }
        guard locale.lowercased() == "zh-hant" else { return simplified }
        if let cached = traditionalText[simplified] { return cached }
        let translated = simplified.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? simplified
        if traditionalText.count < 500 { traditionalText[simplified] = translated }
        return translated
    }
}
