import Foundation
import SwiftData

@Model
final class BookmarkItem {
    var id: UUID
    var title: String
    var urlString: String
    var platformName: String?
    var dateAdded: Date
    @Attribute(.externalStorage) var faviconData: Data?

    init(title: String, urlString: String, platformName: String? = nil) {
        self.id = UUID()
        self.title = title
        self.urlString = urlString
        self.platformName = platformName
        self.dateAdded = Date()
    }

    var url: URL? {
        URL(string: urlString)
    }
}
