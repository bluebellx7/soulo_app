import Foundation
import SwiftData

@Model
final class SearchHistoryItem {
    var id: UUID
    var keyword: String
    var timestamp: Date
    var platformID: UUID?
    /// Non-nil for a visited web page. Search-query entries keep this nil so
    /// both kinds can share the history timeline without changing search chips.
    var visitedURLString: String?

    init(
        keyword: String,
        platformID: UUID? = nil,
        timestamp: Date = Date(),
        visitedURLString: String? = nil
    ) {
        self.id = UUID()
        self.keyword = keyword
        self.timestamp = timestamp
        self.platformID = platformID
        self.visitedURLString = visitedURLString
    }

    var isWebVisit: Bool {
        visitedURLString != nil
    }
}
