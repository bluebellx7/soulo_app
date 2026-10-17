import Foundation
import OSLog

enum SouloSharedConstants {
    static let appGroupIdentifier = "group.com.dkluge.Soulo"
    static let pendingActionKey = "soulo.pending.shared.action"
}

struct SouloSharedAction: Codable, Equatable {
    enum Kind: String, Codable {
        case search
        case openURL
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

    @discardableResult
    func store() -> Bool {
        SouloSharedActionFileStore.appGroup?.store(self) ?? false
    }

    func dispatch() async {
        guard store() else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .souloSharedActionRequested, object: nil)
        }
    }

    static func consume(matchingID: UUID? = nil,
                        now: Date = Date()) -> SouloSharedAction? {
        SouloSharedActionFileStore.appGroup?.consume(matchingID: matchingID,
            legacyDefaults: UserDefaults(suiteName: SouloSharedConstants.appGroupIdentifier), now: now)
    }

    static func discardPending(matchingID: UUID? = nil) {
        SouloSharedActionFileStore.appGroup?.discard(matchingID: matchingID,
            legacyDefaults: UserDefaults(suiteName: SouloSharedConstants.appGroupIdentifier))
    }

    var deepLink: URL? {
        var components = URLComponents()
        components.scheme = "soulo"
        components.host = "action"
        components.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        return components.url
    }
}

/// A completed atomic file write is the cross-process handoff. Preferences
/// synchronization can return false even when a share was written, and must
/// not prevent a browser link from opening. File coordination also ensures
/// that two windows cannot consume the same request or erase a newer write.
struct SouloSharedActionFileStore {
    private struct Snapshot: Codable {
        let version: Int
        let action: SouloSharedAction?
        init(action: SouloSharedAction?) { version = 1; self.action = action }
    }

    private static let logger = Logger(subsystem: "com.dkluge.Soulo", category: "ShareStorage")
    private static let maximumBytes = 512_000
    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("PendingSharedAction.json", isDirectory: false)
    }

    static var appGroup: Self? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SouloSharedConstants.appGroupIdentifier)
            .map(Self.init(directory:))
    }

    func store(_ action: SouloSharedAction) -> Bool {
        coordinate { url in try write(action, to: url) }
    }

    func consume(matchingID: UUID? = nil, legacyDefaults: UserDefaults? = nil,
                 now: Date = Date()) -> SouloSharedAction? {
        var result: SouloSharedAction?
        let success = coordinate { url in
            guard let action = try read(from: url, legacyDefaults: legacyDefaults),
                  matchingID == nil || matchingID == action.id else { return }
            // Retain an empty snapshot so an old preferences request cannot
            // reappear after consumption, even if preferences flushing fails.
            try write(nil, to: url)
            legacyDefaults?.removeObject(forKey: SouloSharedConstants.pendingActionKey)
            if now.timeIntervalSince(action.createdAt) < 7 * 24 * 3600 { result = action }
        }
        return success ? result : nil
    }

    func discard(matchingID: UUID? = nil, legacyDefaults: UserDefaults? = nil) {
        _ = coordinate { url in
            let action = try read(from: url, legacyDefaults: legacyDefaults)
            if let matchingID, let action, action.id != matchingID { return }
            try write(nil, to: url)
            legacyDefaults?.removeObject(forKey: SouloSharedConstants.pendingActionKey)
        }
    }

    private func read(from url: URL, legacyDefaults: UserDefaults?) throws -> SouloSharedAction? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard let data = legacyDefaults?.data(forKey: SouloSharedConstants.pendingActionKey),
                  data.count <= Self.maximumBytes else { return nil }
            return try? JSONDecoder().decode(SouloSharedAction.self, from: data)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumBytes else {
            throw NSError(domain: "Soulo.SharedAction", code: 1)
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else { throw NSError(domain: "Soulo.SharedAction", code: 2) }
        return snapshot.action
    }

    private func write(_ action: SouloSharedAction?, to url: URL) throws {
        let data = try JSONEncoder().encode(Snapshot(action: action))
        guard data.count <= Self.maximumBytes else { throw NSError(domain: "Soulo.SharedAction", code: 1) }
        try data.write(to: url, options: .atomic)
    }

    private func coordinate(_ operation: (URL) throws -> Void) -> Bool {
        var coordinationError: NSError?
        var operationError: NSError?
        var success = false
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { url in
            do { try operation(url); success = true }
            catch { operationError = error as NSError }
        }
        if let error = coordinationError ?? operationError {
            Self.logger.error("Shared handoff file operation failed: \(error.domain, privacy: .public), code \(error.code)")
        }
        return success && coordinationError == nil
    }
}

extension Notification.Name {
    static let souloSharedActionRequested = Notification.Name("soulo.sharedActionRequested")
    static let prepareSouloExternalEntry = Notification.Name("soulo.prepareExternalEntry")
    static let openSouloWebURL = Notification.Name("soulo.openWebURL")
}

enum SouloSharedContent {
    static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ url: URL) -> Bool {
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
        }
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), valid(url) { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            .compactMap(\.url).first(where: valid)
    }

    static func action(for text: String) -> SouloSharedAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64_000 else { return nil }
        if let url = webURL(in: trimmed) { return SouloSharedAction(kind: .openURL, text: url.absoluteString) }
        return SouloSharedAction(kind: .search, text: trimmed)
    }
}
