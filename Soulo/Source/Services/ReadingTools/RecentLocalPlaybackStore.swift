import Combine
import Foundation

/// One continuation entry for media opened from the app's Downloads library.
/// The playback engine supplies the media identity; this store does no format
/// probing or directory scanning. Private playback must disable persistence.
@MainActor
final class RecentLocalPlaybackStore: ObservableObject {
    static let shared = RecentLocalPlaybackStore()
    static let storageKey = "soulo_recent_local_playback"

    private struct Entry: Codable, Equatable {
        let relativePath: String
        let title: String
    }

    @Published private var entry: Entry?
    private let userDefaults: UserDefaults
    private let rootURL: URL
    private var dismissedRelativePath: String?

    /// Existence is checked by the file list when presenting the continuation
    /// action. Resolving again here also rejects a newly introduced symlink.
    var latestURL: URL? { entry.flatMap { safeURL(relativePath: $0.relativePath) } }
    var title: String? { latestURL == nil ? nil : entry?.title }

    init(userDefaults: UserDefaults = .standard, rootURL: URL = BookLibrary.directory) {
        self.userDefaults = userDefaults
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        if let data = userDefaults.data(forKey: Self.storageKey), data.count <= 64 * 1_024,
           let saved = try? JSONDecoder().decode(Entry.self, from: data),
           !saved.title.isEmpty, saved.title.count <= 400,
           safeURL(relativePath: saved.relativePath) != nil {
            entry = saved
        }
    }

    /// A repeated position tick for the same item must not rewrite defaults.
    /// Passing false preserves the previous ordinary session's entry unchanged.
    func record(url: URL, title: String, persistPosition: Bool = true) {
        guard persistPosition, let file = containedURL(url),
              file.path != rootURL.path, FileManager.default.fileExists(atPath: file.path) else { return }
        let relative = String(file.path.dropFirst(rootURL.path.count + 1))
        guard safeURL(relativePath: relative) != nil, relative != dismissedRelativePath else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Entry(relativePath: relative, title: String((trimmedTitle.isEmpty ? file.lastPathComponent : trimmedTitle).prefix(400)))
        guard value != entry, let data = try? JSONEncoder().encode(value) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        entry = value
    }

    /// Removing the shortcut must not delete the file or its saved position.
    /// Ignore subsequent ticks from the already-running player until a new open.
    func dismissLatest() {
        dismissedRelativePath = entry?.relativePath ?? dismissedRelativePath
        userDefaults.removeObject(forKey: Self.storageKey)
        entry = nil
    }

    func beginPlayback(url: URL, persistPosition: Bool = true) {
        guard persistPosition, let file = containedURL(url), file.path != rootURL.path,
              FileManager.default.fileExists(atPath: file.path) else { return }
        let relative = String(file.path.dropFirst(rootURL.path.count + 1))
        if relative == dismissedRelativePath { dismissedRelativePath = nil }
    }

    /// Call after a confirmed deletion. Matching uses a path boundary so
    /// removing Videos never clears an entry in Videos 2.
    func clearIfContained(in targets: [URL]) {
        guard let file = latestURL else { return }
        let containsEntry = targets.contains { target in
            guard let target = containedURL(target) else { return false }
            return file.path == target.path || file.path.hasPrefix(target.path + "/")
        }
        guard containsEntry else { return }
        userDefaults.removeObject(forKey: Self.storageKey)
        entry = nil
    }

    /// Call only after the file operation succeeds (and again on a rollback).
    /// Container relocation needs no call because the stored path is relative.
    func relocate(from oldURL: URL, to newURL: URL) {
        guard let previous = latestURL, let entry,
              let source = containedURL(oldURL), source.path != rootURL.path,
              let destination = containedURL(newURL), destination.path != rootURL.path else { return }
        let next: URL
        let suffix: String
        if previous.path == source.path { next = destination; suffix = "" }
        else {
            guard previous.path.hasPrefix(source.path + "/") else { return }
            suffix = String(previous.path.dropFirst(source.path.count + 1))
            next = destination.appendingPathComponent(suffix)
        }
        let relative = String(next.path.dropFirst(rootURL.path.count + 1))
        guard safeURL(relativePath: relative) != nil, FileManager.default.fileExists(atPath: next.path) else { return }
        let logicalPrevious = suffix.isEmpty ? oldURL : oldURL.appendingPathComponent(suffix)
        let logicalNext = suffix.isEmpty ? newURL : newURL.appendingPathComponent(suffix)
        // File-list URLs and resolved URLs can differ by /var vs /private/var.
        let oldKeys = [MediaSession.positionKey(logicalPrevious), MediaSession.positionKey(previous)]
        let nextKeys = [MediaSession.positionKey(logicalNext), MediaSession.positionKey(next)]
        let position = oldKeys.compactMap { userDefaults.object(forKey: $0) }.first
            ?? nextKeys.compactMap { userDefaults.object(forKey: $0) }.first
        record(url: next, title: entry.title == previous.lastPathComponent ? next.lastPathComponent : entry.title)
        if Set(oldKeys) != Set(nextKeys), let position {
            for key in Set(nextKeys) { userDefaults.set(position, forKey: key) }
            for key in Set(oldKeys).subtracting(nextKeys) { userDefaults.removeObject(forKey: key) }
        }
    }

    private func safeURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty, relativePath.utf8.count <= 4_096,
              !relativePath.hasPrefix("/"),
              !relativePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return containedURL(rootURL.appendingPathComponent(relativePath))
    }

    private func containedURL(_ url: URL) -> URL? {
        guard rootURL.isFileURL, url.isFileURL,
              url.host?.isEmpty != false || url.host?.lowercased() == "localhost" else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path == rootURL.path || file.path.hasPrefix(rootURL.path + "/") else { return nil }
        return file
    }
}
