import Foundation
import ImageIO

/// Favorite originals are user data, not a regenerable browser cache. A single
/// actor serializes migration, downloads and explicit removals off the UI actor.
actor FavoriteWallpaperImageStore {
    nonisolated let savedDirectory: URL
    nonisolated let legacyDirectory: URL
    private var favoriteIDs = Set<String>()
    private var revision: UInt64 = 0

    init(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
         caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        savedDirectory = applicationSupport.appendingPathComponent("WallpaperFavorites", isDirectory: true)
        legacyDirectory = caches.appendingPathComponent("wallpaper_hd", isDirectory: true)
    }

    nonisolated func imageURLs(for id: String) -> [URL] {
        [savedDirectory, legacyDirectory].compactMap { Self.imageURL(for: id, in: $0) }
    }

    func reconcile(favoriteIDs: Set<String>, removingIDs: Set<String> = [], revision: UInt64) {
        let isCurrent = adopt(favoriteIDs, revision: revision)
        for id in removingIDs where !self.favoriteIDs.contains(id) {
            for url in imageURLs(for: id) where Self.isSafeRegularFile(url) { try? FileManager.default.removeItem(at: url) }
        }
        guard isCurrent else { return }
        for id in favoriteIDs { migrateOriginal(for: id) }
    }

    func cachedData(for id: String) -> Data? {
        for url in imageURLs(for: id) where Self.isSafeRegularFile(url) {
            if let data = try? Data(contentsOf: url), Self.isImage(data) { return data }
        }
        return nil
    }

    /// A stale download cannot recreate an image after a newer unfavorite.
    @discardableResult
    func saveImage(_ data: Data, for id: String, favoriteIDs: Set<String>, revision: UInt64) -> Bool {
        guard adopt(favoriteIDs, revision: revision), self.favoriteIDs.contains(id), Self.isImage(data),
              let destination = Self.imageURL(for: id, in: savedDirectory) else { return false }
        do {
            try ensureSavedDirectory()
            if Self.isSafeRegularFile(destination) { return true }
            guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
            try data.write(to: destination, options: .atomic)
            return true
        } catch { return false }
    }

    private func adopt(_ ids: Set<String>, revision: UInt64) -> Bool {
        guard revision >= self.revision else { return false }
        self.revision = revision
        favoriteIDs = ids
        return true
    }

    private func migrateOriginal(for id: String) {
        guard let original = Self.imageURL(for: id, in: legacyDirectory), Self.isSafeRegularFile(original),
              let destination = Self.imageURL(for: id, in: savedDirectory) else { return }
        let manager = FileManager.default
        var staging: URL?
        do {
            try ensureSavedDirectory()
            if !manager.fileExists(atPath: destination.path) {
                let temporary = savedDirectory.appendingPathComponent(".migration-" + UUID().uuidString)
                staging = temporary
                try manager.copyItem(at: original, to: temporary)
                try manager.moveItem(at: temporary, to: destination)
                staging = nil
            }
            // Keep the old original if the destination differs, is unsafe, or
            // could not be verified. A failed migration never discards it.
            if Self.isSafeRegularFile(destination), manager.contentsEqual(atPath: original.path, andPath: destination.path) {
                try manager.removeItem(at: original)
            }
        } catch {
            if let staging { try? manager.removeItem(at: staging) }
        }
    }

    private func ensureSavedDirectory() throws {
        try FileManager.default.createDirectory(at: savedDirectory, withIntermediateDirectories: true)
        let info = try savedDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
    }

    nonisolated private static func imageURL(for id: String, in directory: URL) -> URL? {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (id + ".jpg").utf8.count <= 255 else { return nil }
        return directory.appendingPathComponent(id + ".jpg")
    }

    nonisolated private static func isSafeRegularFile(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        guard let parent = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              parent.isDirectory == true, parent.isSymbolicLink != true,
              let file = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              file.isRegularFile == true, file.isSymbolicLink != true else { return false }
        return true
    }

    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
