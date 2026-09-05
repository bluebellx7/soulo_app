import Foundation
import ZipArchive
import PLzmaSDK
import Unrar

struct ArchiveEntryInfo: Identifiable {
    var id: String { path }
    let path: String
    let size: UInt64
    let directory: Bool
}

/// Cooperative cancellation shared by C callbacks and Swift workers.
final class FileOperationProgress: NSObject, @unchecked Sendable, DecoderDelegate, EncoderDelegate, SSZipArchiveDelegate {
    let progress = Progress(totalUnitCount: 1000)
    func decoder(decoder: PLzmaSDK.Decoder, path: String, progress: Double) {
        self.progress.completedUnitCount = Int64(min(1, max(0, progress)) * 1000)
        if self.progress.isCancelled { try? decoder.abort() }
    }
    func encoder(encoder: PLzmaSDK.Encoder, path: String, progress: Double) {
        self.progress.completedUnitCount = Int64(min(1, max(0, progress)) * 1000)
        if self.progress.isCancelled { try? encoder.abort() }
    }
    func zipArchiveShouldUnzipFile(at fileIndex: Int, totalFiles: Int, archivePath: String, fileInfo: unz_file_info) -> Bool {
        progress.completedUnitCount = Int64(Double(fileIndex) / Double(max(1, totalFiles)) * 1000)
        return !progress.isCancelled && fileInfo.uncompressed_size <= ArchiveService.maximumFileSize
    }
    func check() throws { if progress.isCancelled { throw ReadingToolError.canceled } }
}

enum ArchiveService {
    static let maximumFileSize: UInt64 = 512 * 1024 * 1024
    static let maximumTotalSize: UInt64 = 1024 * 1024 * 1024
    static let extensions: Set<String> = ["zip", "7z", "rar"]

    static func validate(_ entries: [ArchiveEntryInfo]) throws {
        guard entries.count <= 10000 else { throw ReadingToolError.limit }
        var total: UInt64 = 0, paths = Set<String>()
        for entry in entries {
            let path = try FileSafety.relativePath(entry.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ReadingToolError.conflict }
            guard entry.size <= maximumFileSize, entry.size <= maximumTotalSize - total else { throw ReadingToolError.limit }
            total += entry.size
        }
    }

    static func list(_ url: URL, password: String? = nil) throws -> [ArchiveEntryInfo] {
        let entries: [ArchiveEntryInfo]
        switch url.pathExtension.lowercased() {
        case "zip": entries = try zipEntries(Data(contentsOf: url, options: .mappedIfSafe))
        case "7z":
            let decoder = try sevenDecoder(url, password: password)
            entries = try (0..<decoder.count()).map { index in
                let item = try decoder.item(at: index)
                return ArchiveEntryInfo(path: try item.path().description, size: item.size, directory: item.isDir)
            }
        case "rar":
            let archive = try Unrar.Archive(fileURL: url, password: password)
            guard !archive.isVolume else { throw ReadingToolError.unsupported }
            entries = try archive.entries().map { ArchiveEntryInfo(path: $0.fileName, size: $0.uncompressedSize, directory: $0.directory) }
        default: throw ReadingToolError.unsupported
        }
        try validate(entries); return entries
    }

    static func extract(_ url: URL, to directory: URL, password: String? = nil, operation: FileOperationProgress = FileOperationProgress()) throws -> URL {
        let entries = try list(url, password: password)
        try operation.check()
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard entries.reduce(UInt64(0), { $0 + $1.size }) < UInt64(max(0, available)) else { throw ReadingToolError.limit }
        let staging = directory.appendingPathComponent(".extract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        switch url.pathExtension.lowercased() {
        case "zip":
            var error: NSError?
            let ok = SSZipArchive.unzipFile(atPath: url.path, toDestination: staging.path, preserveAttributes: false, overwrite: false, password: password, error: &error, delegate: operation)
            try operation.check()
            guard ok else { throw error ?? ReadingToolError.invalid as NSError }
        case "7z":
            let decoder = try sevenDecoder(url, password: password, operation: operation)
            // Explicit streams prevent archive attributes from creating links or writing outside staging.
            var streams: [PLzmaSDK.Item: PLzmaSDK.OutStream] = [:]
            for index in 0..<(try decoder.count()) {
                let item = try decoder.item(at: index)
                let path = try FileSafety.relativePath(item.path().description)
                let target = staging.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: item.isDir ? target : target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !item.isDir { streams[item] = try PLzmaSDK.OutStream(path: PLzmaSDK.Path(target.path)) }
            }
            guard try decoder.extract(itemsToStreams: PLzmaSDK.ItemOutStreamArray(items: streams)) else { try operation.check(); throw ReadingToolError.invalid }
        case "rar":
            let archive = try Unrar.Archive(fileURL: url, password: password)
            for entry in try archive.entries() {
                try operation.check()
                let target = staging.appendingPathComponent(try FileSafety.relativePath(entry.fileName))
                try FileManager.default.createDirectory(at: entry.directory ? target : target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if entry.directory { continue }
                FileManager.default.createFile(atPath: target.path, contents: nil)
                let handle = try FileHandle(forWritingTo: target)
                var writeError: Error?, written: UInt64 = 0
                do {
                    try archive.extract(entry) { data, progress in
                        written += UInt64(data.count)
                        if operation.progress.isCancelled || written > entry.uncompressedSize { progress.cancel(); return }
                        do { try handle.write(contentsOf: data) } catch { writeError = error; progress.cancel() }
                        operation.progress.completedUnitCount = Int64(progress.fractionCompleted * 1000)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                if let writeError { throw writeError }
                guard written == entry.uncompressedSize else { throw ReadingToolError.invalid }
            }
        default: throw ReadingToolError.unsupported
        }
        try operation.check()
        // Verify extracted output before publishing the new folder.
        for file in FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])?.allObjects as? [URL] ?? [] {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw ReadingToolError.unsafePath }
        }
        let destination = FileSafety.availableURL(name: url.deletingPathExtension().lastPathComponent, directory: directory)
        try FileManager.default.moveItem(at: staging, to: destination)
        operation.progress.completedUnitCount = 1000
        return destination
    }

    static func create(files: [URL], format: String, directory: URL, password: String? = nil, operation: FileOperationProgress = FileOperationProgress()) throws -> URL {
        guard ["zip", "7z"].contains(format), !files.isEmpty else { throw ReadingToolError.unsupported }
        let entries = try files.map { url -> ArchiveEntryInfo in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReadingToolError.unsupported }
            return ArchiveEntryInfo(path: url.lastPathComponent, size: UInt64(values.fileSize ?? 0), directory: false)
        }
        try validate(entries)
        let staging = directory.appendingPathComponent(".compress-" + UUID().uuidString + "." + format)
        defer { try? FileManager.default.removeItem(at: staging) }
        if format == "zip" {
            let archive = SSZipArchive(path: staging.path)
            guard archive.open() else { throw ReadingToolError.invalid }
            do {
                for (index, file) in files.enumerated() {
                    try operation.check()
                    guard archive.writeFile(atPath: file.path, withFileName: file.lastPathComponent, compressionLevel: 6, password: password, aes: true) else { throw ReadingToolError.invalid }
                    operation.progress.completedUnitCount = Int64(Double(index + 1) / Double(files.count) * 1000)
                }
                guard archive.close() else { throw ReadingToolError.invalid }
            } catch { archive.close(); throw error }
        } else {
            let encoder = try PLzmaSDK.Encoder(stream: PLzmaSDK.OutStream(path: PLzmaSDK.Path(staging.path)), fileType: .sevenZ, method: .LZMA2, delegate: operation)
            try encoder.setCompressionLevel(5)
            if let password, !password.isEmpty {
                try encoder.setPassword(password); try encoder.setShouldEncryptContent(true); try encoder.setShouldEncryptHeader(true)
            }
            for file in files { try encoder.add(path: PLzmaSDK.Path(file.path), mode: .default, archivePath: PLzmaSDK.Path(file.lastPathComponent)) }
            guard try encoder.open(), try encoder.compress() else { try operation.check(); throw ReadingToolError.invalid }
        }
        try operation.check()
        let destination = FileSafety.availableURL(name: "Archive." + format, directory: directory)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }
    private static func sevenDecoder(_ url: URL, password: String?, operation: FileOperationProgress? = nil) throws -> PLzmaSDK.Decoder {
        let decoder = try PLzmaSDK.Decoder(stream: PLzmaSDK.InStream(path: PLzmaSDK.Path(url.path)), fileType: .sevenZ, delegate: operation)
        try decoder.setPassword(password)
        guard try decoder.open() else { throw ReadingToolError.invalid }
        return decoder
    }

    static func zipEntries(_ data: Data) throws -> [ArchiveEntryInfo] {
        func value(_ offset: Int, _ size: Int) throws -> UInt64 {
            guard offset >= 0, offset + size <= data.count else { throw ReadingToolError.invalid }
            return (0..<size).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 22 else { throw ReadingToolError.invalid }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try value(i, 4) == 0x06054b50, i + 22 + Int(try value(i + 20, 2)) == data.count { end = i; break }
        }
        guard let end, try value(end + 4, 2) == 0, try value(end + 6, 2) == 0 else { throw ReadingToolError.invalid }
        let count = Int(try value(end + 10, 2))
        guard count < 65535, count <= 10000 else { throw ReadingToolError.limit }
        var offset = Int(try value(end + 16, 4)), result: [ArchiveEntryInfo] = []
        for _ in 0..<count {
            guard try value(offset, 4) == 0x02014b50 else { throw ReadingToolError.invalid }
            let length = Int(try value(offset + 28, 2)), extra = Int(try value(offset + 30, 2)), comment = Int(try value(offset + 32, 2))
            guard offset + 46 + length + extra + comment <= end else { throw ReadingToolError.invalid }
            let raw = data[(offset+46)..<(offset+46+length)]
            guard let name = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) else { throw ReadingToolError.invalid }
            let attributes = try value(offset + 38, 4)
            guard ((attributes >> 16) & 0xf000) != 0xa000 else { throw ReadingToolError.unsafePath }
            result.append(ArchiveEntryInfo(path: name, size: try value(offset + 24, 4), directory: name.hasSuffix("/")))
            offset += 46 + length + extra + comment
        }
        try validate(result); return result
    }
}
