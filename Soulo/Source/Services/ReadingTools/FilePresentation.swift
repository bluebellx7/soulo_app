import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FilePresentation: Sendable, Hashable {
    enum Kind: String, Sendable { case folder, image, video, audio, pdf, book, archive, text, other }
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "log", "csv", "tsv", "json", "yaml", "yml", "xml", "html", "htm", "css", "js", "jsx", "ts", "tsx", "swift", "py", "java", "c", "h", "cpp", "hpp", "cs", "go", "rs", "sh", "sql", "ini", "cfg", "conf", "toml", "srt", "vtt", "ass", "lrc", "tex", "rst"]
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
    var badge: String {
        if fileExtension == OfflineHLSReference.fileExtension { return "HLS" }
        return fileExtension.isEmpty ? ToolText.text("file_data") : fileExtension.uppercased()
    }

    static func inspect(_ url: URL) -> FilePresentation {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if url.pathExtension.lowercased() == "movpkg" {
            return FilePresentation(kind: .video, fileExtension: "movpkg", size: FileStorageSize.bytes(at: url) ?? 0)
        }
        if url.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
            return FilePresentation(kind: .video, fileExtension: OfflineHLSReference.fileExtension, size: FileStorageSize.bytes(at: url) ?? 0)
        }
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
        else if ext == "mkv" || type?.conforms(to: .movie) == true { kind = .video }
        else if Self.textExtensions.contains(ext) || type?.conforms(to: .text) == true { kind = .text }
        else { kind = .other }
        return FilePresentation(kind: kind, fileExtension: ext, size: Int64(values?.fileSize ?? 0))
    }
}

/// Logical file bytes, including the media behind an offline HLS reference.
/// Call off the main thread: packages can contain thousands of fragments.
enum FileStorageSize {
    static func bytes(at url: URL) -> Int64? {
        guard url.isFileURL else { return nil }
        let target: URL
        if url.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
            guard let package = try? OfflineHLSReference.packageURL(for: url) else { return nil }
            target = package
        } else { target = url }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? target.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
        if values.isRegularFile == true { return values.fileSize.map(Int64.init) }
        guard values.isDirectory == true, target.pathExtension.lowercased() == "movpkg",
              let files = FileManager.default.enumerator(at: target, includingPropertiesForKeys: Array(keys)) else { return nil }
        var total: Int64 = 0
        for case let file as URL in files {
            guard !Task.isCancelled else { return nil }
            guard let info = try? file.resourceValues(forKeys: keys) else { return nil }
            if info.isSymbolicLink == true { files.skipDescendants(); continue }
            if info.isRegularFile == true {
                guard let size = info.fileSize else { return nil }
                let sum = total.addingReportingOverflow(Int64(size))
                guard !sum.overflow else { return nil }
                total = sum.partialValue
            }
        }
        return total
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

/// Only selected children of the current directory can be removed.
/// Folders include their contents; symbolic links are never followed.
enum LibraryFileActions {
    static func rename(_ file: URL, baseName: String, in directory: URL) throws -> URL {
        let name = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."),
              !name.contains(where: { "/\\:".contains($0) }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReadingToolError.unsafePath
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              file.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == root else {
            throw ReadingToolError.unsafePath
        }
        let filename = file.pathExtension.isEmpty ? name : name + "." + file.pathExtension
        guard filename.utf8.count <= 255 else { throw ReadingToolError.limit }
        let target = directory.appendingPathComponent(filename)
        if target.standardizedFileURL == file.standardizedFileURL { return file }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ReadingToolError.conflict }
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    static func delete(_ files: [URL], in directory: URL) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        for file in files {
            guard file.isFileURL else { throw ReadingToolError.unsafePath }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard (values.isRegularFile == true || values.isDirectory == true), values.isSymbolicLink != true,
                  file.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == root,
                  !file.lastPathComponent.hasPrefix(".") else { throw ReadingToolError.unsafePath }
        }
        for file in files {
            // HLS references can point to system-owned packages outside Downloads.
            // Remove those packages as well when deleting their containing folder.
            var references = [file]
            if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
               let contents = FileManager.default.enumerator(at: file,
                includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsPackageDescendants]) {
                for case let child as URL in contents where child.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
                    if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false {
                        references.append(child)
                    }
                }
            }
            for reference in references where reference.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
                try? OfflineHLSReference.removePackage(for: reference)
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    static func contains(_ url: URL, in targets: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return targets.contains {
            let target = $0.standardizedFileURL.path
            return path == target || path.hasPrefix(target + "/")
        }
    }
}

/// Keep an app-owned copy: external providers can revoke access after handoff.
enum ExternalDocumentImporter {
    static func copyToLibrary(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw ReadingToolError.unsafePath }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let directory = BookLibrary.directory
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if source.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) { return source }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(ReadingToolError.invalid)
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result {
                let info = try readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true else { throw ReadingToolError.unsupported }
                guard (info.fileSize ?? 0) <= 1024 * 1024 * 1024 else { throw ReadingToolError.limit }
                let target = FileSafety.availableURL(name: readable.lastPathComponent, directory: directory)
                do { try FileManager.default.copyItem(at: readable, to: target) }
                catch { try? FileManager.default.removeItem(at: target); throw error }
                return target
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
