import Foundation
import SwiftData

@available(iOS 17.0, *)
@Model
final class BookmarkFolder {
    var id: UUID = UUID()
    var title: String = ""
    var parentID: UUID?
    var dateAdded: Date = Date()

    init(title: String, parentID: UUID? = nil) {
        self.title = title
        self.parentID = parentID
    }
}
