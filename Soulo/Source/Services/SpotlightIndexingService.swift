import CoreSpotlight
import UniformTypeIdentifiers

struct SpotlightIndexingService {
    static func indexHistoryItem(keyword: String, id: UUID) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = keyword
        attributeSet.contentDescription = "Search history"
        attributeSet.keywords = [keyword]

        let item = CSSearchableItem(
            uniqueIdentifier: "search-history-\(id.uuidString)",
            domainIdentifier: "soulo.history",
            attributeSet: attributeSet
        )
        item.expirationDate = Date().addingTimeInterval(30 * 24 * 3600) // 30 days
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func indexBookmark(title: String, url: String, id: UUID) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .url)
        attributeSet.title = title
        attributeSet.contentDescription = url
        attributeSet.url = URL(string: url)
        attributeSet.keywords = [title]

        let item = CSSearchableItem(
            uniqueIdentifier: "bookmark-\(id.uuidString)",
            domainIdentifier: "soulo.bookmarks",
            attributeSet: attributeSet
        )
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    static func deindexItem(id: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
    }

    static func deindexAll(domain: String) {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }
}
