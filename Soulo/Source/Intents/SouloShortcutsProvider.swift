import AppIntents

struct SouloShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SouloSearchIntent(),
            phrases: [
                "Search with \(.applicationName)",
                "Open \(.applicationName)",
            ],
            shortTitle: "Search Soulo",
            systemImageName: "magnifyingglass"
        )
    }
}
