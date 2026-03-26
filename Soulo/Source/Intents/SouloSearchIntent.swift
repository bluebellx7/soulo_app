import AppIntents

struct SouloSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search with Soulo"
    static var description: IntentDescription = "Search across multiple platforms"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Search query")
    var query: String

    @Parameter(title: "Platform", optionsProvider: PlatformOptionsProvider())
    var platformName: String?

    func perform() async throws -> some IntentResult {
        // Post notification for the app to handle
        await MainActor.run {
            NotificationCenter.default.post(
                name: .souloSearchFromIntent,
                object: nil,
                userInfo: ["query": query, "platform": platformName as Any]
            )
        }
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
    static let souloSearchFromIntent = Notification.Name("souloSearchFromIntent")
    static let webViewExternalURLRequest = Notification.Name("webViewExternalURLRequest")
}
