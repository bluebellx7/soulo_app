import AppIntents

struct SouloShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SouloSearchIntent(), phrases: ["Search with \(.applicationName)"], shortTitle: "intent_search_title", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenSouloIntent(), phrases: ["Open \(.applicationName)"], shortTitle: "intent_open_soulo_title", systemImageName: "safari")
        AppShortcut(intent: NewPrivateSearchIntent(), phrases: ["Private search with \(.applicationName)"], shortTitle: "intent_private_search_title", systemImageName: "eye.slash")
        AppShortcut(intent: PasteAndSearchSouloIntent(), phrases: ["Paste and search with \(.applicationName)"], shortTitle: "intent_paste_search_title", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: OpenSouloDownloadsIntent(), phrases: ["Open \(.applicationName) downloads"], shortTitle: "intent_open_downloads_title", systemImageName: "arrow.down.circle")
    }
}
