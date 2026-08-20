import AppIntents

struct OpenSouloIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_open_soulo_title"
    static var description = IntentDescription("intent_open_soulo_description")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await SouloSharedAction(kind: .openHome).dispatch()
        return .result()
    }
}

struct OpenSouloDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_open_downloads_title"
    static var description = IntentDescription("intent_open_downloads_description")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await SouloSharedAction(kind: .openDownloads).dispatch()
        return .result()
    }
}

struct PasteAndSearchSouloIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_paste_search_title"
    static var description = IntentDescription("intent_paste_search_description")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await SouloSharedAction(kind: .search).dispatch()
        return .result()
    }
}

struct NewPrivateSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_private_search_title"
    static var description = IntentDescription("intent_private_search_description")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await SouloSharedAction(kind: .privateSearch).dispatch()
        return .result()
    }
}
