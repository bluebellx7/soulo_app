import AppIntents

struct OpenWebPageInSouloIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_open_webpage_title"
    static var description = IntentDescription("intent_open_webpage_title")
    static var openAppWhenRun = true

    @Parameter(title: "intent_webpage_url") var url: URL

    func perform() async throws -> some IntentResult {
        guard let webURL = SouloSharedContent.webURL(in: url.absoluteString),
              webURL == url else { throw CocoaError(.fileReadUnsupportedScheme) }
        await SouloSharedAction(kind: .openURL, text: webURL.absoluteString).dispatch()
        return .result()
    }
}

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
