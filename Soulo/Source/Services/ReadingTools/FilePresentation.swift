import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FilePresentation: Sendable, Hashable {
    enum Kind: String, Sendable { case folder, image, video, audio, pdf, book, archive, text, other }
    let kind: Kind
    let fileExtension: String
    let size: Int64
    var symbol: String {
        switch kind {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .book: "book.closed"
        case .archive: "doc.zipper"
        case .text: "doc.text"
        case .other: "doc"
        }
    }
    var badge: String { fileExtension.isEmpty ? ToolText.text("file_data") : fileExtension.uppercased() }

    static func inspect(_ url: URL) -> FilePresentation {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { return FilePresentation(kind: .folder, fileExtension: "", size: 0) }
        var ext = url.pathExtension.lowercased()
        // ImageIO identifies bytes, including extensionless JPEG/WebP/HEIF downloads.
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) {
            ext = type.preferredFilenameExtension ?? ext
            return FilePresentation(kind: .image, fileExtension: ext, size: Int64(values?.fileSize ?? 0))
        }
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 16)) ?? Data()
            if header.starts(with: Data("%PDF-".utf8)) { ext = "pdf" }
            else if ext.isEmpty, header.starts(with: [0x50, 0x4b, 0x03, 0x04]) { ext = "zip" }
        }
        let type = UTType(filenameExtension: ext)
        let kind: Kind
        if ext == "pdf" { kind = .pdf }
        else if ["epub", "mobi", "azw", "azw3", "azw4", "prc", "pdb"].contains(ext) { kind = .book }
        else if ["zip", "rar", "7z"].contains(ext) { kind = .archive }
        else if type?.conforms(to: .audio) == true { kind = .audio }
        else if type?.conforms(to: .movie) == true { kind = .video }
        else if type?.conforms(to: .text) == true { kind = .text }
        else { kind = .other }
        return FilePresentation(kind: kind, fileExtension: ext, size: Int64(values?.fileSize ?? 0))
    }
}

struct PreparedFilePreview: Sendable {
    let url: URL
    let temporaryDirectory: URL?
    static func prepare(_ original: URL) throws -> PreparedFilePreview {
        let info = FilePresentation.inspect(original)
        guard !info.fileExtension.isEmpty,
              original.pathExtension.lowercased() != info.fileExtension else {
            return PreparedFilePreview(url: original, temporaryDirectory: nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SouloPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = original.lastPathComponent
        while name.utf8.count > 220 { name.removeLast() }
        let target = directory.appendingPathComponent(name).appendingPathExtension(info.fileExtension)
        do {
            do { try FileManager.default.linkItem(at: original, to: target) }
            catch { try FileManager.default.copyItem(at: original, to: target) }
            return PreparedFilePreview(url: target, temporaryDirectory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func removeTemporaryFile() { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
}

/// Only selected, app-owned regular files are removed. Directory and symlink deletion are excluded.
enum LibraryFileActions {
    static func delete(_ files: [URL], in directory: URL) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  file.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == root,
                  !file.lastPathComponent.hasPrefix(".") else { throw ReadingToolError.unsafePath }
        }
        for file in files { try FileManager.default.removeItem(at: file) }
    }
}
