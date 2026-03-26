import Foundation
import SwiftData

@Model
final class SearchHistoryItem {
    var id: UUID
    var keyword: String
    var timestamp: Date
    var platformID: UUID?

    init(keyword: String, platformID: UUID? = nil) {
        self.id = UUID()
        self.keyword = keyword
        self.timestamp = Date()
        self.platformID = platformID
    }
}
