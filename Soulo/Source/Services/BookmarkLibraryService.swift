import Foundation
import SwiftData

@MainActor
enum BookmarkLibraryService {
    struct ImportResult {
        var added = 0
        var folders = 0
        var duplicates = 0
        var skipped = 0
    }
    private struct Location: Hashable {
        let parent: UUID?
        let value: String
    }

    static func importArchive(_ archive: BookmarkArchive, into parentID: UUID?, context: ModelContext) throws -> ImportResult {
        try context.save()
        let existingFolders = try context.fetch(FetchDescriptor<BookmarkFolder>())
        let existingLinks = try context.fetch(FetchDescriptor<BookmarkItem>())
        var foldersByLocation: [Location: UUID] = [:]
        for folder in existingFolders { foldersByLocation[.init(parent: folder.parentID, value: folder.title)] = folder.id }
        var links = Set(existingLinks.map { Location(parent: $0.folderID, value: $0.urlString) })
        var mappedIDs: [UUID: UUID] = [:]
        var result = ImportResult(skipped: archive.skipped)
        do {
            for folder in archive.folders {
                let parent = folder.parentID.flatMap { mappedIDs[$0] } ?? parentID
                let location = Location(parent: parent, value: folder.title)
                if let existing = foldersByLocation[location] { mappedIDs[folder.id] = existing }
                else {
                    let item = BookmarkFolder(title: folder.title, parentID: parent)
                    item.dateAdded = folder.dateAdded
                    context.insert(item)
                    mappedIDs[folder.id] = item.id
                    foldersByLocation[location] = item.id
                    result.folders += 1
                }
            }
            for link in archive.links {
                let folderID = link.folderID.flatMap { mappedIDs[$0] } ?? parentID
                guard links.insert(.init(parent: folderID, value: link.url)).inserted else {
                    result.duplicates += 1
                    continue
                }
                let item = BookmarkItem(title: link.title, urlString: link.url)
                item.folderID = folderID
                item.dateAdded = link.dateAdded
                context.insert(item)
                result.added += 1
            }
            try context.save()
            return result
        } catch { context.rollback(); throw error }
    }

    static func archive(context: ModelContext) throws -> BookmarkArchive {
        let folders = try context.fetch(FetchDescriptor<BookmarkFolder>(sortBy: [SortDescriptor(\.dateAdded)]))
        let items = try context.fetch(FetchDescriptor<BookmarkItem>(sortBy: [SortDescriptor(\.dateAdded)]))
        return BookmarkArchive(folders: folders.map { .init(id: $0.id, parentID: $0.parentID, title: $0.title, dateAdded: $0.dateAdded) },
            links: items.map { .init(folderID: $0.folderID, title: $0.title, url: $0.urlString, dateAdded: $0.dateAdded) })
    }

    /// Removing a folder keeps its contents in the parent folder, including nested folders.
    static func removeFolder(_ folder: BookmarkFolder, context: ModelContext) throws {
        try context.save()
        do {
            for item in try context.fetch(FetchDescriptor<BookmarkItem>()) where item.folderID == folder.id { item.folderID = folder.parentID }
            for child in try context.fetch(FetchDescriptor<BookmarkFolder>()) where child.parentID == folder.id { child.parentID = folder.parentID }
            context.delete(folder)
            try context.save()
        } catch { context.rollback(); throw error }
    }
}
