import Combine
import Foundation

private struct ReadingListCapacityError: LocalizedError {
    var errorDescription: String? {
        FeatureText.text("Reading list limit: 500 articles, 2 MB per article and 20 MB in total.")
    }
}

struct SavedReadingItem: Codable, Identifiable, Sendable {
    let id: UUID
    let url: URL
    var title: String
    var text: String
    var savedAt: Date
    var lastOpenedAt: Date?
    var paragraph: Int?
}

private struct ReadingListSnapshot: Sendable {
    let revision: UInt64
    let items: [SavedReadingItem]
}

/// Synchronous filesystem operations stay on this actor's executor. Each
/// mutation reads its authoritative items and writes atomically without any
/// suspension point, so overlapping UI requests cannot overwrite one another.
private actor ReadingListPersistence {
    private static let maximumItems = 500
    private static let maximumArticleBytes = 2 * 1_024 * 1_024
    private static let maximumTotalTextBytes = 20 * 1_024 * 1_024
    // JSON can expand a text character to six bytes (for example \u0001).
    private static let maximumArchiveBytes = 128 * 1_024 * 1_024

    private let fileURL: URL
    private var items: [SavedReadingItem] = []
    private var loaded = false
    private var revision: UInt64 = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() throws -> ReadingListSnapshot {
        guard !loaded else { return snapshot }
        guard fileURL.isFileURL else { throw ReadingToolError.unsafePath }
        let restored: [SavedReadingItem]
        do {
            let info = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw ReadingToolError.unsafePath }
            guard (info.fileSize ?? 0) <= Self.maximumArchiveBytes else { throw ReadingListCapacityError() }
            let decoded = try JSONDecoder().decode([SavedReadingItem].self, from: Data(contentsOf: fileURL, options: .mappedIfSafe))
            try validate(decoded)
            restored = decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            restored = []
        }
        items = restored
        loaded = true
        revision += 1
        return snapshot
    }

    func save(url: URL, title: String, text: String) throws -> ReadingListSnapshot {
        try validateArticle(url: url, text: text)
        _ = try load()
        var updated = items
        if let index = updated.firstIndex(where: { $0.url == url }) {
            updated[index].title = title
            updated[index].text = text
            updated[index].savedAt = Date()
            updated[index].paragraph = nil
        } else {
            guard updated.count < Self.maximumItems else { throw ReadingListCapacityError() }
            updated.insert(.init(id: UUID(), url: url, title: title, text: text, savedAt: Date()), at: 0)
        }
        return try persist(updated)
    }

    func remove(ids: Set<UUID>) throws -> ReadingListSnapshot {
        _ = try load()
        let updated = items.filter { !ids.contains($0.id) }
        guard updated.count != items.count else { return snapshot }
        return try persist(updated)
    }

    func updatePosition(id: UUID, paragraph: Int?) throws -> ReadingListSnapshot {
        guard paragraph.map({ $0 >= 0 }) ?? true else { throw ReadingToolError.invalid }
        _ = try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return snapshot }
        var updated = items
        updated[index].paragraph = paragraph
        updated[index].lastOpenedAt = Date()
        return try persist(updated)
    }

    private var snapshot: ReadingListSnapshot { .init(revision: revision, items: items) }

    private func validateArticle(url: URL, text: String) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              text.utf8.count <= Self.maximumArticleBytes,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReadingListCapacityError() }
    }

    private func validate(_ updated: [SavedReadingItem]) throws {
        guard updated.count <= Self.maximumItems else { throw ReadingListCapacityError() }
        var total = 0
        var ids = Set<UUID>(), urls = Set<URL>()
        for item in updated {
            try validateArticle(url: item.url, text: item.text)
            total += item.text.utf8.count
            guard total <= Self.maximumTotalTextBytes else { throw ReadingListCapacityError() }
            guard ids.insert(item.id).inserted, urls.insert(item.url).inserted,
                  item.paragraph.map({ $0 >= 0 }) ?? true else { throw ReadingToolError.invalid }
        }
    }

    private func persist(_ updated: [SavedReadingItem]) throws -> ReadingListSnapshot {
        try validate(updated)
        let data = try JSONEncoder().encode(updated)
        guard data.count <= Self.maximumArchiveBytes else { throw ReadingListCapacityError() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        items = updated
        revision += 1
        return snapshot
    }
}

@MainActor final class ReadingListStore: ObservableObject {
    static let shared = ReadingListStore()
    @Published private(set) var items: [SavedReadingItem] = []
    private let persistence: ReadingListPersistence
    private var publishedRevision: UInt64 = 0

    init(fileURL: URL? = nil) {
        let fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingList.json")
        persistence = ReadingListPersistence(fileURL: fileURL)
    }

    func load() async throws { publish(try await persistence.load()) }

    func save(url: URL, title: String, text: String) async throws {
        publish(try await persistence.save(url: url, title: title, text: text))
    }

    func remove(ids: Set<UUID>) async throws { publish(try await persistence.remove(ids: ids)) }

    func updatePosition(id: UUID, paragraph: Int?) async throws {
        publish(try await persistence.updatePosition(id: id, paragraph: paragraph))
    }

    private func publish(_ snapshot: ReadingListSnapshot) {
        guard snapshot.revision > publishedRevision else { return }
        publishedRevision = snapshot.revision
        items = snapshot.items
    }
}
