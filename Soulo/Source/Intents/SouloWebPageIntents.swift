import AppIntents
import CoreData

struct SouloWebPageEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Webpage", table: "FeatureImprovements"))
    static var defaultQuery = SouloWebPageQuery()
    var id: String { url.absoluteString }
    var title: String
    let url: URL
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url.host ?? id)")
    }

    init?(url: URL, title: String) {
        guard let url = BrowserHandoff.eligibleURL(url, isPrivate: false) else { return nil }
        self.url = url
        self.title = title.isEmpty ? url.host ?? url.absoluteString : String(title.prefix(200))
    }
}

struct SouloWebPageQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SouloWebPageEntity] {
        // IDs are validated public web URLs. Never return local files, private
        // network pages or arbitrary schemes to a system conversation.
        identifiers.compactMap { URL(string: $0).flatMap { SouloWebPageEntity(url: $0, title: "") } }
    }
    func entities(matching string: String) async throws -> [SouloWebPageEntity] {
        try await BrowserIntentLibrary.shared.pages(matching: string)
    }
    func suggestedEntities() async throws -> [SouloWebPageEntity] {
        try await BrowserIntentLibrary.shared.pages(matching: nil)
    }
}

@MainActor
final class BrowserIntentLibrary {
    static let shared = BrowserIntentLibrary()
    var context: NSManagedObjectContext?
    private var fallbackStore: LibraryStore?
    private func currentContext() throws -> NSManagedObjectContext {
        if let context { return context }
        if fallbackStore == nil { fallbackStore = try LibraryStore() }
        return fallbackStore!.mainContext
    }

    func pages(matching text: String?) throws -> [SouloWebPageEntity] {
        let request = BookmarkRecord.request(sortBy: [NSSortDescriptor(key: "dateAdded", ascending: false)])
        request.fetchLimit = 50
        if let text, !text.isEmpty {
            request.predicate = NSPredicate(format: "title CONTAINS[cd] %@ OR urlString CONTAINS[cd] %@", text, text)
        }
        return try currentContext().fetch(request).compactMap { record in
            URL(string: record.urlString).flatMap { SouloWebPageEntity(url: $0, title: record.title) }
        }
    }

    func save(_ page: SouloWebPageEntity) throws {
        guard SouloWebPageEntity(url: page.url, title: page.title) != nil else { throw CocoaError(.fileReadUnsupportedScheme) }
        let context = try currentContext()
        guard !BookmarkService.isBookmarked(url: page.id, context: context) else { return }
        context.insert(BookmarkRecord(title: page.title, urlString: page.id))
        try context.save()
    }
}

struct OpenSavedWebPageIntent: AppIntent {
    static var title: LocalizedStringResource = "intent_open_webpage_title"
    static var openAppWhenRun = true
    @Parameter(title: LocalizedStringResource("Webpage", table: "FeatureImprovements")) var page: SouloWebPageEntity
    func perform() async throws -> some IntentResult {
        guard SouloWebPageEntity(url: page.url, title: page.title) != nil else { throw CocoaError(.fileReadUnsupportedScheme) }
        await SouloSharedAction(kind: .openURL, text: page.id).dispatch()
        return .result()
    }
}

struct SaveWebPageIntent: AppIntent {
    static var title = LocalizedStringResource("Save webpage", table: "FeatureImprovements")
    static var openAppWhenRun = true
    @Parameter(title: LocalizedStringResource("Webpage", table: "FeatureImprovements")) var page: SouloWebPageEntity
    @MainActor func perform() async throws -> some IntentResult {
        try BrowserIntentLibrary.shared.save(page)
        return .result()
    }
}

struct WebPageLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "copy_link"
    @Parameter(title: LocalizedStringResource("Webpage", table: "FeatureImprovements")) var page: SouloWebPageEntity
    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        guard SouloWebPageEntity(url: page.url, title: page.title) != nil else { throw CocoaError(.fileReadUnsupportedScheme) }
        return .result(value: page.url)
    }
}
