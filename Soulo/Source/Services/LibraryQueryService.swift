import Foundation

enum LibraryFileFilter: String, CaseIterable, Identifiable, Sendable {
    case all, folders, images, videos, audio, documents, archives, other
    var id: Self { self }

    func includes(_ kind: FilePresentation.Kind) -> Bool {
        switch self {
        case .all: true
        case .folders: kind == .folder
        case .images: kind == .image
        case .videos: kind == .video
        case .audio: kind == .audio
        case .documents: [.pdf, .book, .text, .document, .spreadsheet, .presentation, .code].contains(kind)
        case .archives: kind == .archive
        case .other: [.font, .other].contains(kind)
        }
    }
}

enum LibraryListSort: String, CaseIterable, Identifiable, Sendable {
    case newest, oldest, nameAscending, nameDescending, sizeLargest, sizeSmallest
    var id: Self { self }
}

enum DownloadStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, active, paused, completed, failed, canceled
    var id: Self { self }

    func includes(_ status: BrowserDownloadStatus) -> Bool {
        switch self {
        case .all: true
        case .active: status == .inProgress || status == .paused
        case .paused: status == .paused
        case .completed: status == .finished
        case .failed: status == .failed
        case .canceled: status == .canceled
        }
    }
}

private enum LibraryQueryText {
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
    }

    static func matches(_ tokens: [String], in values: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let text = values.map { normalized($0.removingPercentEncoding ?? $0) }.joined(separator: "\n")
        return tokens.allSatisfy { text.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

enum DownloadListQuery {
    /// Supply asynchronously measured sizes/kinds when available; the query
    /// itself performs no filesystem reads on the UI thread.
    static func apply(_ items: [BrowserDownloadItem], search: String = "",
                      status: DownloadStatusFilter = .all, kind: LibraryFileFilter = .all,
                      sort: LibraryListSort = .newest, sizes: [UUID: Int64] = [:],
                      kinds: [UUID: FilePresentation.Kind] = [:]) -> [BrowserDownloadItem] {
        let tokens = LibraryQueryText.tokens(search)
        return items.filter { item in
            status.includes(item.status)
                && kind.includes(kinds[item.id] ?? FilePresentation.kind(forFileExtension: item.localURL.pathExtension))
                && LibraryQueryText.matches(tokens, in: [item.fileName, item.sourceURLString])
        }.sorted { left, right in
            let ordered: ComparisonResult
            switch sort {
            case .newest, .oldest:
                ordered = left.startedAt.compare(right.startedAt)
            case .nameAscending, .nameDescending:
                ordered = left.fileName.localizedStandardCompare(right.fileName)
            case .sizeLargest, .sizeSmallest:
                let lhs = max(0, sizes[left.id] ?? max(left.expectedBytes, left.receivedBytes))
                let rhs = max(0, sizes[right.id] ?? max(right.expectedBytes, right.receivedBytes))
                ordered = lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
            }
            if ordered == .orderedSame { return left.id.uuidString < right.id.uuidString }
            return [.newest, .nameDescending, .sizeLargest].contains(sort)
                ? ordered == .orderedDescending : ordered == .orderedAscending
        }
    }
}

enum LibraryFileQuery {
    /// Works with the file view's existing records, retaining its prepared
    /// thumbnails, file metadata and selection identity without reading disk.
    static func apply<Item>(_ items: [Item], search: String = "", kind: LibraryFileFilter = .all,
                            sort: LibraryListSort = .nameAscending, directoriesFirst: Bool = true,
                            url: (Item) -> URL, presentation: (Item) -> FilePresentation,
                            modifiedAt: (Item) -> Date) -> [Item] {
        let tokens = LibraryQueryText.tokens(search)
        return items.filter { item in
            kind.includes(presentation(item).kind)
                && LibraryQueryText.matches(tokens, in: [url(item).lastPathComponent])
        }.sorted { left, right in
            let lhs = presentation(left), rhs = presentation(right)
            if directoriesFirst, (lhs.kind == .folder) != (rhs.kind == .folder) { return lhs.kind == .folder }
            let ordered: ComparisonResult
            switch sort {
            case .newest, .oldest:
                ordered = modifiedAt(left).compare(modifiedAt(right))
            case .nameAscending, .nameDescending:
                ordered = url(left).lastPathComponent.localizedStandardCompare(url(right).lastPathComponent)
            case .sizeLargest, .sizeSmallest:
                ordered = lhs.size == rhs.size ? .orderedSame : lhs.size < rhs.size ? .orderedAscending : .orderedDescending
            }
            if ordered == .orderedSame { return url(left).path < url(right).path }
            return [.newest, .nameDescending, .sizeLargest].contains(sort)
                ? ordered == .orderedDescending : ordered == .orderedAscending
        }
    }
}
