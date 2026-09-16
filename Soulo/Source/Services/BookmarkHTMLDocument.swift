import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Netscape bookmark HTML, shared by Chrome, Edge, Safari and Firefox exports.
/// This is a data parser: it never loads HTML in WebKit or fetches embedded resources.
struct BookmarkArchive: Sendable, Equatable {
    struct Folder: Sendable, Equatable {
        var id: UUID = UUID()
        var parentID: UUID?
        var title: String
        var dateAdded: Date
    }
    struct Link: Sendable, Equatable {
        var folderID: UUID?
        var title: String
        var url: String
        var dateAdded: Date
    }
    var folders: [Folder] = []
    var links: [Link] = []
    var skipped = 0
}

enum BookmarkHTML {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumEntries = 50_000
    private static let entityPattern = try! NSRegularExpression(
        pattern: #"&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp);"#,
        options: [.caseInsensitive])
    enum Failure: LocalizedError {
        case invalid, tooLarge, tooDeep
        var errorDescription: String? {
            switch self {
            case .invalid: ToolText.text("favorites_invalid")
            case .tooLarge: ToolText.text("favorites_too_large")
            case .tooDeep: ToolText.text("favorites_too_deep")
            }
        }
    }

    static func read(_ url: URL) throws -> BookmarkArchive {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bounded read also protects against misleading file-size metadata.
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> BookmarkArchive {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let html: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            html = String(data: data, encoding: .utf16)
        } else {
            html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard let html else { throw Failure.invalid }
        // Tokens respect quoted '>' characters and ignore comments and executable content.
        let pattern = #"<!--[\s\S]*?-->|<script\b[^>]*>[\s\S]*?</script\s*>|<style\b[^>]*>[\s\S]*?</style\s*>|<(?:(?:"[^"]*"|'[^']*'|[^'">])*)>|[^<]+"#
        let tokens = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let attributes = try NSRegularExpression(pattern: #"([a-zA-Z_][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        let tagName = try NSRegularExpression(pattern: #"^<\s*(/?)\s*([a-zA-Z0-9]+)"#)
        var archive = BookmarkArchive()
        var stack: [UUID?] = []
        var pendingFolder: UUID?
        var capture: (tag: String, attrs: [String: String], text: String)?
        var sawList = false
        var failure: Failure?
        let now = Date()
        func date(_ attrs: [String: String]) -> Date {
            guard let seconds = attrs["add_date"].flatMap(Double.init), seconds.isFinite,
                  seconds >= 0, seconds <= 253_402_300_799 else { return now }
            return Date(timeIntervalSince1970: seconds)
        }
        func finishCapture() {
            guard let value = capture else { return }
            capture = nil
            let title = unescape(value.text).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.tag == "h3" {
                let folder = BookmarkArchive.Folder(parentID: stack.last ?? nil,
                    title: title.isEmpty ? ToolText.text("favorites_untitled") : title, dateAdded: date(value.attrs))
                archive.folders.append(folder)
                pendingFolder = folder.id
            } else if let href = value.attrs["href"], let url = URL(string: href),
                      ["https", "http", "ftp"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty {
                archive.links.append(.init(folderID: stack.last ?? nil,
                    title: title.isEmpty ? href : title, url: href, dateAdded: date(value.attrs)))
            } else { archive.skipped += 1 }
        }
        tokens.enumerateMatches(in: html, range: NSRange(html.startIndex..., in: html)) { match, _, stop in
            guard let match, let range = Range(match.range, in: html) else { return }
            let token = String(html[range])
            if token.hasPrefix("<") {
                guard let nameMatch = tagName.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)),
                      let nameRange = Range(nameMatch.range(at: 2), in: token) else { return }
                let name = token[nameRange].lowercased()
                if name == "script" || name == "style" { return }
                let closing = nameMatch.range(at: 1).length > 0
                if closing && (name == "a" || name == "h3") { finishCapture() }
                if name == "dl" {
                    finishCapture()
                    if closing {
                        if !stack.isEmpty { stack.removeLast() }
                        pendingFolder = nil
                    } else {
                        sawList = true
                        stack.append(pendingFolder ?? (stack.last ?? nil))
                        pendingFolder = nil
                        if stack.count > 64 { failure = .tooDeep }
                    }
                } else if !closing && (name == "a" || name == "h3") && !stack.isEmpty {
                    finishCapture()
                    var values: [String: String] = [:]
                    for match in attributes.matches(in: token, range: NSRange(token.startIndex..., in: token)) {
                        guard let keyRange = Range(match.range(at: 1), in: token) else { continue }
                        for index in 2...4 {
                            if let valueRange = Range(match.range(at: index), in: token) {
                                values[token[keyRange].lowercased()] = unescape(String(token[valueRange]))
                                break
                            }
                        }
                    }
                    capture = (name, values, "")
                }
            } else if capture != nil { capture?.text += token }
            if archive.links.count + archive.folders.count + archive.skipped > maximumEntries { failure = .tooLarge }
            if failure != nil { stop.pointee = true }
        }
        if let failure { throw failure }
        finishCapture()
        guard archive.links.count + archive.folders.count + archive.skipped <= maximumEntries else { throw Failure.tooLarge }
        guard sawList else { throw Failure.invalid }
        return archive
    }

    static func encode(_ archive: BookmarkArchive) -> Data {
        let folders = Dictionary(grouping: archive.folders, by: \.parentID)
        let links = Dictionary(grouping: archive.links, by: \.folderID)
        var output = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Soulo Bookmarks</TITLE>", "<H1>Soulo Bookmarks</H1>", "<DL><p>"]
        var visited: Set<UUID> = []
        func timestamp(_ date: Date) -> Int64 {
            Int64(max(0, min(253_402_300_799, date.timeIntervalSince1970)))
        }
        enum Entry {
            case folder(BookmarkArchive.Folder), link(BookmarkArchive.Link), close
        }
        var pending: [Entry] = []
        func enqueueChildren(_ parent: UUID?) {
            pending.append(contentsOf: (links[parent] ?? []).reversed().map(Entry.link))
            pending.append(contentsOf: (folders[parent] ?? []).reversed().map(Entry.folder))
        }
        func drain() {
            while let entry = pending.popLast() {
                switch entry {
                case .folder(let folder):
                    guard visited.insert(folder.id).inserted else { continue }
                    output.append("<DT><H3 ADD_DATE=\"\(timestamp(folder.dateAdded))\">\(escape(folder.title))</H3>")
                    output.append("<DL><p>")
                    pending.append(.close)
                    enqueueChildren(folder.id)
                case .link(let link):
                    output.append("<DT><A HREF=\"\(escape(link.url))\" ADD_DATE=\"\(timestamp(link.dateAdded))\">\(escape(link.title))</A>")
                case .close: output.append("</DL><p>")
                }
            }
        }
        enqueueChildren(nil)
        drain()
        // Recover detached folders/links rather than silently omitting saved data.
        for folder in archive.folders where !visited.contains(folder.id) {
            pending.append(.folder(folder))
            drain()
        }
        let folderIDs = Set(archive.folders.map(\.id))
        for link in archive.links where link.folderID.map({ !folderIDs.contains($0) }) == true {
            pending.append(.link(link))
            drain()
        }
        output.append("</DL><p>")
        return Data(output.joined(separator: "\n").utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ value: String) -> String {
        // Decode exactly once so a literal '&amp;' in a title survives round trips.
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}"]
        var result = value
        for match in entityPattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let innerRange = Range(match.range(at: 1), in: value), let range = Range(match.range, in: result) else { continue }
            let entity = value[innerRange].lowercased()
            var replacement = names[entity]
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                   let scalar = UnicodeScalar(number), number != 0 { replacement = String(scalar) }
            }
            if let replacement { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}

struct BookmarkHTMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.html] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
