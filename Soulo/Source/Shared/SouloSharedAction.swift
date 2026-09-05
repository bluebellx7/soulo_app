import Foundation

enum SouloSharedConstants {
    static let appGroupIdentifier = "group.com.dkluge.Soulo"
    static let pendingActionKey = "soulo.pending.shared.action"
}

struct SouloSharedAction: Codable, Equatable {
    enum Kind: String, Codable {
        case search
        case privateSearch
        case openDownloads
        case openHome
    }

    let id: UUID
    let kind: Kind
    let text: String?
    let platformName: String?
    let createdAt: Date

    init(kind: Kind, text: String? = nil, platformName: String? = nil) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.platformName = platformName
        createdAt = Date()
    }

    func store() {
        guard let defaults = UserDefaults(suiteName: SouloSharedConstants.appGroupIdentifier),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: SouloSharedConstants.pendingActionKey)
    }

    func dispatch() async {
        store()
        await MainActor.run {
            NotificationCenter.default.post(name: .souloSharedActionRequested, object: nil)
        }
    }

    static func consume() -> SouloSharedAction? {
        guard let defaults = UserDefaults(suiteName: SouloSharedConstants.appGroupIdentifier),
              let data = defaults.data(forKey: SouloSharedConstants.pendingActionKey),
              let action = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        defaults.removeObject(forKey: SouloSharedConstants.pendingActionKey)
        return action
    }

    static func discardPending() {
        UserDefaults(suiteName: SouloSharedConstants.appGroupIdentifier)?
            .removeObject(forKey: SouloSharedConstants.pendingActionKey)
    }

    var deepLink: URL? {
        var components = URLComponents()
        components.scheme = "soulo"
        components.host = "action"
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return components.url
    }
}

extension Notification.Name {
    static let souloSharedActionRequested = Notification.Name("soulo.sharedActionRequested")
}
