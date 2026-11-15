import Foundation

struct CustomGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var platformIDs: [UUID]

    init(id: UUID = UUID(), name: String, platformIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.platformIDs = platformIDs
    }
}
