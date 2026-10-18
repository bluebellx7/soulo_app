import Foundation

/// Only regular files inside Soulo's Downloads folder are eligible. No overwrite,
/// recursive traversal, or deletion; the reviewed paths are checked again on commit.
struct LocalAIFileMove: Sendable {
    let source: URL
    let destination: URL
    let bytes: Int
    let modified: Date?
}
enum LocalAIFileOrganizer {
    static func plan(in directory: URL) throws -> [LocalAIFileMove] {
        let root = directory.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var moves: [LocalAIFileMove] = []
        for file in files {
            if moves.count >= 200 { break }
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
            let ext = file.pathExtension.lowercased()
            guard !["download", "part", "partial", "tmp", "resume"].contains(ext) else { continue }
            let group: String
            switch ext {
            case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": group = "Images"
            case "mp4", "mov", "m4v", "webm": group = "Videos"
            case "mp3", "m4a", "wav", "flac", "aac": group = "Audio"
            case "pdf": group = "PDF"
            case "epub", "mobi", "azw", "azw3", "txt": group = "Books"
            case "zip", "7z", "rar", "tar", "gz": group = "Archives"
            default: group = "Documents"
            }
            let folder = root.appendingPathComponent(group, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            }
            let target = folder.appendingPathComponent(file.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            moves.append(.init(source: file, destination: target, bytes: info.fileSize ?? 0, modified: info.contentModificationDate))
        }
        return moves
    }
    static func commit(_ moves: [LocalAIFileMove], in directory: URL, reverse: Bool = false) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        // Validate the complete plan before the first mutation.
        for move in moves {
            let source = reverse ? move.destination : move.source
            let destination = reverse ? move.source : move.destination
            guard source.resolvingSymlinksInPath().path.hasPrefix(root), destination.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root) || destination.deletingLastPathComponent().resolvingSymlinksInPath().path + "/" == root,
                  !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
            var freshSource = URL(fileURLWithPath: source.path)
            freshSource.removeAllCachedResourceValues()
            let info = try freshSource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  info.fileSize == move.bytes, info.contentModificationDate == move.modified else { throw CocoaError(.fileReadCorruptFile) }
        }
        var completed: [(URL, URL)] = []
        do {
            for move in moves {
                let source = reverse ? move.destination : move.source
                let destination = reverse ? move.source : move.destination
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: destination)
                completed.append((source, destination))
            }
        } catch {
            for (source, destination) in completed.reversed() {
                // Roll back only our own moves, without overwriting later files.
                if !FileManager.default.fileExists(atPath: source.path) { try? FileManager.default.moveItem(at: destination, to: source) }
            }
            throw error
        }
    }
}
