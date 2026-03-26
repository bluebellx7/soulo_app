import UIKit
import Foundation

struct ClipboardService {

    private static let lastHashKey = "last_clipboard_hash"

    // MARK: - Detect Searchable Content

    static func detectSearchableContent() -> String? {
        guard let raw = UIPasteboard.general.string else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1, trimmed.count <= 200 else { return nil }

        let hash = contentHash(trimmed)
        let lastHash = UserDefaults.standard.string(forKey: lastHashKey)

        guard hash != lastHash else { return nil }

        return trimmed
    }

    // MARK: - Mark As Seen

    static func markAsSeen(_ content: String) {
        let hash = contentHash(content)
        UserDefaults.standard.set(hash, forKey: lastHashKey)
    }

    // MARK: - Private

    private static func contentHash(_ content: String) -> String {
        return String(content.hashValue)
    }
}
