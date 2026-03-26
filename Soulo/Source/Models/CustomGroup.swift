import Foundation

struct CustomGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var platformIDs: [UUID]

    init(name: String, platformIDs: [UUID] = []) {
        self.id = UUID()
        self.name = name
        self.platformIDs = platformIDs
    }
}
