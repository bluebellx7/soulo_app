import Foundation
import CryptoKit
import PDFKit

struct ReadingBookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var location: String
    var label: String
}
struct LibraryBook: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var fileName: String
    var location = ""
    var fraction = 0.0
    var openedAt = Date()
    var bookmarks: [ReadingBookmark] = []
    var hasCover: Bool?
    var fileBookmark: Data?
    var coverURL: URL { BookLibrary.coverDirectory.appendingPathComponent(id + ".jpg") }
    var url: URL {
        if let fileBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: fileBookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
               resolved.resolvingSymlinksInPath().path.hasPrefix(BookLibrary.directory.resolvingSymlinksInPath().path + "/") { return resolved }
        }
        return BookLibrary.directory.appendingPathComponent(fileName)
    }
}

@MainActor final class BookLibrary: ObservableObject {
    static let shared = BookLibrary()
    nonisolated static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads") }
    nonisolated static var coverDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BookCovers") }
    @Published private(set) var books: [LibraryBook] = []
    private let metadata: URL
    init(metadata: URL? = nil) {
        self.metadata = metadata ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BookLibrary.json")
        if let data = try? Data(contentsOf: self.metadata), let books = try? JSONDecoder().decode([LibraryBook].self, from: data) { self.books = books }
    }
    func add(_ url: URL) async throws -> LibraryBook {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let result = try await Task.detached(priority: .userInitiated) {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true, (info.fileSize ?? 0) <= 128 * 1024 * 1024 else { throw ReadingToolError.limit }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            _ = try BookFormat.preflight(data, extension: url.pathExtension)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
        if let book = books.first(where: { $0.id == result }) { return book }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var destination = url
        if url.deletingLastPathComponent().standardizedFileURL != Self.directory.standardizedFileURL {
            destination = FileSafety.availableURL(name: url.lastPathComponent, directory: Self.directory)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        var book = LibraryBook(id: result, name: url.deletingPathExtension().lastPathComponent, fileName: destination.lastPathComponent)
        book.fileBookmark = try? destination.bookmarkData(options: .minimalBookmark)
        books.insert(book, at: 0); try save(); return book
    }
    func update(_ id: String, location: String, fraction: Double) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].location = location; books[index].fraction = min(1, max(0, fraction)); books[index].openedAt = Date()
        try? save()
    }
    func bookmark(_ id: String) {
        guard let index = books.firstIndex(where: { $0.id == id }), !books[index].location.isEmpty else { return }
        let book = books[index]
        guard !book.bookmarks.contains(where: { $0.location == book.location }) else { return }
        books[index].bookmarks.append(ReadingBookmark(location: book.location, label: "\(Int(book.fraction * 100))%")); try? save()
    }
    func storeCover(_ id: String, data: Data) {
        guard data.count <= 4 * 1024 * 1024, let index = books.firstIndex(where: { $0.id == id }), books[index].hasCover != true else { return }
        do {
            try FileManager.default.createDirectory(at: Self.coverDirectory, withIntermediateDirectories: true)
            try data.write(to: books[index].coverURL, options: .atomic)
            books[index].hasCover = true; try save()
        } catch { /* A missing thumbnail must never block the reader. */ }
    }
    func remove(_ id: String) { books.removeAll { $0.id == id }; try? save() }
    private func save() throws {
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(books).write(to: metadata, options: .atomic)
    }
}

enum ReadingToolError: LocalizedError {
    case invalid, unsupported, protected, limit, unsafePath, conflict, canceled
    var errorDescription: String? {
        ToolText.text([.invalid: "invalid_file", .unsupported: "unsupported_file", .protected: "protected_file", .limit: "file_limit", .unsafePath: "unsafe_path", .conflict: "file_conflict", .canceled: "canceled"][self]!)
    }
}

enum BookFormat: String {
    case text, pdf, epub, mobi, palmDoc
    static let extensions: Set<String> = ["txt", "pdf", "epub", "mobi", "azw", "azw3", "azw4", "prc", "pdb"]
    static func preflight(_ data: Data, extension ext: String) throws -> BookFormat {
        let format = try detect(data, extension: ext)
        switch format {
        case .pdf:
            guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ReadingToolError.invalid }
            guard !document.isLocked else { throw ReadingToolError.protected }
        case .epub:
            let entries = try ArchiveService.zipEntries(data)
            guard entries.contains(where: { $0.path == "META-INF/container.xml" }) else { throw ReadingToolError.invalid }
            guard entries.reduce(UInt64(0), { $0 + $1.size }) <= 128 * 1024 * 1024 else { throw ReadingToolError.limit }
        case .mobi, .palmDoc:
            guard data.count >= 86 else { throw ReadingToolError.invalid }
            let count = Int(data[76]) << 8 | Int(data[77])
            guard count > 1, count <= 10000, 78 + count * 8 <= data.count else { throw ReadingToolError.invalid }
            let offset = (78..<82).reduce(0) { ($0 << 8) | Int(data[$1]) }
            guard offset >= 78 + count * 8, offset + 16 <= data.count else { throw ReadingToolError.invalid }
            if format == .mobi, data[offset + 12] != 0 || data[offset + 13] != 0 { throw ReadingToolError.protected }
        case .text: _ = try TextBookDecoder.decode(data)
        }
        return format
    }
    static func detect(_ data: Data, extension ext: String) throws -> BookFormat {
        if data.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return .epub }
        if data.count >= 78 {
            let signature = String(data: data[60..<68], encoding: .ascii)
            if signature == "BOOKMOBI" { return .mobi }
            if signature == "TEXtREAd" { return .palmDoc }
        }
        if ext.lowercased() == "txt", !data.isEmpty { return .text }
        throw ReadingToolError.unsupported
    }
}

enum FileSafety {
    static func relativePath(_ path: String) throws -> String {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.contains("\0"),
              !parts.contains(".."), !parts.contains("."), path.utf8.count < 4096 else { throw ReadingToolError.unsafePath }
        return path
    }
    static func availableURL(name: String, directory: URL) -> URL {
        let safe = DownloadFilenameSanitizer.sanitize(name)
        var result = directory.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = directory.appendingPathComponent((safe as NSString).deletingPathExtension + " (\(n))").appendingPathExtension((safe as NSString).pathExtension)
            n += 1
        }
        return result
    }
}

enum TextBookDecoder {
    static func decode(_ data: Data, encoding: String = "auto") throws -> String {
        let cf: [String: CFStringEncodings] = ["GB18030": .GB_18030_2000, "Big5": .big5, "Shift-JIS": .shiftJIS]
        if let value = cf[encoding], let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))) { return text }
        if encoding == "UTF-16", let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let text = String(data: data, encoding: .utf16) { return text }
        if encoding == "auto", let value = cf["GB18030"], let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))) { return text }
        throw ReadingToolError.invalid
    }
    static func chapters(_ text: String) -> [String] {
        // Bound each WebView document; a large TXT never becomes a single DOM.
        var result: [String] = [], chunk = ""
        for line in text.components(separatedBy: .newlines) {
            if chunk.count > 24_000 || (chunk.count > 1000 && line.range(of: "^(第.{1,15}[章节回卷]|Chapter\\s+\\d+)", options: [.regularExpression, .caseInsensitive]) != nil) {
                result.append(chunk); chunk = ""
            }
            var remainder = line[...]
            while remainder.count > 24_000 {
                let end = remainder.index(remainder.startIndex, offsetBy: 24_000)
                chunk += remainder[..<end]; result.append(chunk); chunk = ""; remainder = remainder[end...]
            }
            chunk += remainder + "\n"
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
    static func palmDoc(_ data: Data) throws -> String {
        func u16(_ i: Int) throws -> Int { guard i >= 0, i + 2 <= data.count else { throw ReadingToolError.invalid }; return Int(data[i]) << 8 | Int(data[i+1]) }
        func u32(_ i: Int) throws -> Int { try u16(i) << 16 | u16(i+2) }
        let count = try u16(76)
        guard count > 1, count <= 10000, 78 + count * 8 <= data.count else { throw ReadingToolError.invalid }
        let offsets = try (0..<count).map { try u32(78 + $0 * 8) } + [data.count]
        guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 && $0 >= 78 && $1 <= data.count }) else { throw ReadingToolError.invalid }
        let header = offsets[0], compression = try u16(header), records = try u16(header + 8)
        guard [1, 2].contains(compression), records > 0, records < count else { throw ReadingToolError.unsupported }
        var output = Data()
        for n in 1...records {
            let bytes = Array(data[offsets[n]..<offsets[n+1]])
            if compression == 1 { output.append(contentsOf: bytes) } else { output.append(try decompressPalm(bytes)) }
            guard output.count <= 64 * 1024 * 1024 else { throw ReadingToolError.limit }
        }
        return try decode(output)
    }
    static func decompressPalm(_ bytes: [UInt8]) throws -> Data {
        var output: [UInt8] = []; var i = 0
        while i < bytes.count {
            let byte = Int(bytes[i]); i += 1
            switch byte {
            case 1...8:
                guard i + byte <= bytes.count else { throw ReadingToolError.invalid }
                output += bytes[i..<i+byte]; i += byte
            case 0, 9...127: output.append(UInt8(byte))
            case 128...191:
                guard i < bytes.count else { throw ReadingToolError.invalid }
                let pair = (byte << 8) | Int(bytes[i]); i += 1
                let distance = (pair & 0x3fff) >> 3, length = (pair & 7) + 3
                guard distance > 0, distance <= output.count else { throw ReadingToolError.invalid }
                for _ in 0..<length { output.append(output[output.count - distance]) }
            default: output += [32, UInt8(byte ^ 128)]
            }
            guard output.count <= 1024 * 1024 else { throw ReadingToolError.limit }
        }
        return Data(output)
    }
}
