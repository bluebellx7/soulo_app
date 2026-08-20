import AppIntents

struct SouloSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_search_title"
    static var description: IntentDescription = "intent_search_description"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "intent_search_query")
    var query: String

    @Parameter(title: "intent_search_platform", optionsProvider: PlatformOptionsProvider())
    var platformName: String?

    func perform() async throws -> some IntentResult {
        await SouloSharedAction(
            kind: .search,
            text: query,
            platformName: platformName
        ).dispatch()
        return .result()
    }
}

struct PlatformOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        await MainActor.run {
            PlatformDataStore.shared.allPlatforms()
                .filter { $0.isVisible }
                .map { LanguageManager.shared.localizedString($0.name) }
        }
    }
}

extension Notification.Name {
    static let webViewExternalURLRequest = Notification.Name("webViewExternalURLRequest")
}
