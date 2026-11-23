import CoreData
import SwiftData
import XCTest
@testable import Soulo

@MainActor
final class BookmarkCloudSyncTests: XCTestCase {
    private func peer(_ name: String, root: URL, transport: BookmarkTestTransport) throws -> (LibraryStore, BookmarkCloudSyncService) {
        let suite = "BookmarkTransport-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let library = try LibraryStore(inMemory: true)
        let service = BookmarkCloudSyncService(defaults: defaults, localDirectory: root.appendingPathComponent(name),
            locationProvider: { transport.location() })
        service.attach(container: library.container)
        return (library, service)
    }
    func testActualSaveObserversTwoPeersOfflineEditsAndExplicitDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkTransport-\(UUID())")
        let transport = BookmarkTestTransport(root: root.appendingPathComponent("Cloud"))
        let (phone, a) = try peer("Phone", root: root, transport: transport)
        let (pad, b) = try peer("Pad", root: root, transport: transport)
        defer { a.setEnabled(false); b.setEnabled(false) }
        let first = BookmarkRecord(title: "Phone original", urlString: "https://phone.example/")
        let second = BookmarkRecord(title: "Pad original", urlString: "https://pad.example/")
        phone.mainContext.insert(first); try phone.mainContext.save()
        pad.mainContext.insert(second); try pad.mainContext.save()
        a.setEnabled(true); b.setEnabled(true)
        await a.synchronizeNow(); await b.synchronizeNow(); await a.synchronizeNow()
        XCTAssertFalse(a.hasSyncIssue); XCTAssertFalse(b.hasSyncIssue)
        XCTAssertEqual(try phone.mainContext.count(for: BookmarkRecord.request()), 2)
        XCTAssertEqual(try pad.mainContext.count(for: BookmarkRecord.request()), 2)
        let padFirst = try XCTUnwrap(pad.mainContext.fetch(BookmarkRecord.request(predicate: NSPredicate(format: "id == %@", first.id as NSUUID))).first)
        transport.setAvailable(false)
        first.title = "Phone offline rename"; try phone.mainContext.save()
        padFirst.isFavorite = true; try pad.mainContext.save()
        await a.synchronizeNow(); await b.synchronizeNow()
        XCTAssertTrue(a.hasSyncIssue); XCTAssertTrue(b.hasSyncIssue)
        transport.setAvailable(true)
        await a.synchronizeNow(); await b.synchronizeNow(); await a.synchronizeNow()
        XCTAssertEqual(padFirst.title, "Phone offline rename"); XCTAssertTrue(first.isFavorite)
        XCTAssertFalse(a.hasSyncIssue); XCTAssertFalse(b.hasSyncIssue)
        a.setEnabled(false)
        phone.mainContext.delete(first); try phone.mainContext.save()
        await b.synchronizeNow()
        XCTAssertEqual(try pad.mainContext.count(for: BookmarkRecord.request()), 2, "Disabled peers cannot upload a deletion")
        a.setEnabled(true); await a.synchronizeNow(); await b.synchronizeNow()
        XCTAssertEqual(try pad.mainContext.fetch(BookmarkRecord.request()).map(\.id), [second.id])
        XCTAssertEqual(try phone.mainContext.fetch(BookmarkRecord.request()).map(\.id), [second.id])
        let (empty, c) = try peer("Empty-restored-device", root: root, transport: transport)
        defer { c.setEnabled(false) }
        c.setEnabled(true); await c.synchronizeNow(); await a.synchronizeNow()
        XCTAssertEqual(try empty.mainContext.fetch(BookmarkRecord.request()).map(\.id), [second.id])
        XCTAssertEqual(try phone.mainContext.fetch(BookmarkRecord.request()).map(\.id), [second.id])
    }

    func testAccountChangeDoesNotCarryOldAccountTombstonesIntoNewAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkAccount-\(UUID())")
        let transport = BookmarkTestTransport(root: root.appendingPathComponent("Cloud"))
        let (library, service) = try peer("Local", root: root, transport: transport)
        defer { service.setEnabled(false) }
        let first = BookmarkRecord(title: "Account one", urlString: "https://one.example/")
        let id = first.id
        library.mainContext.insert(first); try library.mainContext.save()
        service.setEnabled(true); await service.synchronizeNow()
        library.mainContext.delete(first); try library.mainContext.save(); await service.synchronizeNow()
        transport.switchAccount()
        let (newAccount, other) = try peer("Other", root: root, transport: transport)
        defer { other.setEnabled(false) }
        let restored = BookmarkRecord(title: "Second account keeps this", urlString: "https://second.example/")
        restored.id = id; newAccount.mainContext.insert(restored); try newAccount.mainContext.save()
        other.setEnabled(true); await other.synchronizeNow(); await service.synchronizeNow()
        let current = try XCTUnwrap(library.mainContext.fetch(BookmarkRecord.request()).first)
        XCTAssertEqual(current.id, id); XCTAssertEqual(current.title, "Second account keeps this")
        XCTAssertFalse(service.hasSyncIssue)
    }

    func testNewRecordsAndFaviconOnlySavesKeepTheTransportValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkMetadata-\(UUID())")
        let transport = BookmarkTestTransport(root: root.appendingPathComponent("Cloud"))
        let (library, a) = try peer("Phone", root: root, transport: transport)
        let (remote, b) = try peer("Pad", root: root, transport: transport)
        defer { a.setEnabled(false); b.setEnabled(false) }
        a.setEnabled(true); await a.synchronizeNow()
        let item = BookmarkRecord(title: "Inserted after enabling", urlString: "https://metadata.example/")
        library.mainContext.insert(item); try library.mainContext.save()
        await a.synchronizeNow()
        item.faviconData = Data([1, 2, 3]); try library.mainContext.save()
        await a.synchronizeNow()
        b.setEnabled(true); await b.synchronizeNow()
        let copy = try XCTUnwrap(remote.mainContext.fetch(BookmarkRecord.request()).first)
        XCTAssertEqual(copy.id, item.id); XCTAssertEqual(copy.title, item.title)
        XCTAssertFalse(a.hasSyncIssue); XCTAssertFalse(b.hasSyncIssue)
        XCTAssertEqual(item.faviconData, Data([1, 2, 3]))
    }

    func testDeletionBeforeFirstOptInSurvivesInitialAccountLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkFirstLink-\(UUID())")
        let transport = BookmarkTestTransport(root: root.appendingPathComponent("Cloud"))
        let (library, a) = try peer("Phone", root: root, transport: transport)
        let (remote, b) = try peer("Pad", root: root, transport: transport)
        defer { a.setEnabled(false); b.setEnabled(false) }
        let local = BookmarkRecord(title: "Explicitly deleted", urlString: "https://deleted.example/")
        let stale = BookmarkRecord(title: "Stale remote copy", urlString: local.urlString)
        stale.id = local.id
        library.mainContext.insert(local); try library.mainContext.save()
        library.mainContext.delete(local); try library.mainContext.save()
        remote.mainContext.insert(stale); try remote.mainContext.save()
        b.setEnabled(true); await b.synchronizeNow()
        a.setEnabled(true); await a.synchronizeNow(); await b.synchronizeNow()
        XCTAssertEqual(try library.mainContext.count(for: BookmarkRecord.request()), 0)
        XCTAssertEqual(try remote.mainContext.count(for: BookmarkRecord.request()), 0)
        XCTAssertFalse(a.hasSyncIssue); XCTAssertFalse(b.hasSyncIssue)
    }

    private func stamp(_ writer: String, _ sequence: UInt64, baseline: Bool = false, date: Double = 1) -> BookmarkSyncStamp {
        .init(baseline: baseline, date: Date(timeIntervalSince1970: date), sequence: sequence, writer: writer)
    }
    private func record(title: String, writer: String = "phone", sequence: UInt64 = 1, kind: BookmarkSyncRecord.Kind = .bookmark) -> BookmarkSyncRecord {
        let date = stamp(writer, sequence)
        var fields = ["title": BookmarkSyncField(value: title, stamp: date), "dateAdded": .init(value: "100", stamp: date)]
        if kind == .bookmark {
            fields["urlString"] = .init(value: "https://example.com/" + UUID().uuidString, stamp: date)
        }
        return .init(kind: kind, fields: fields)
    }

    func testIndependentDevicesMergeUnionAndEmptySnapshotsDoNotDelete() throws {
        let a = UUID().uuidString, b = UUID().uuidString
        var phone = BookmarkSyncJournal(writer: "phone", revision: 1, records: [a: record(title: "Phone")])
        let pad = BookmarkSyncJournal(writer: "pad", revision: 2, records: [b: record(title: "Pad", writer: "pad", sequence: 2)])
        try phone.merge(pad)
        XCTAssertEqual(Set(phone.records.keys), [a, b])
        XCTAssertEqual(phone.revision, 2)
        let before = phone
        try phone.merge(.init(writer: "old-empty-backup"))
        XCTAssertEqual(phone, before)
        let encoded = try PropertyListEncoder().encode(phone)
        XCTAssertEqual(try PropertyListDecoder().decode(BookmarkSyncJournal.self, from: encoded), phone)
    }

    func testConcurrentFieldEditsConvergeAndBaselineCannotOverwriteEdits() throws {
        let id = UUID().uuidString
        var initial = record(title: "Original", sequence: 0)
        for key in initial.fields.keys { initial.fields[key]?.stamp.baseline = true }
        var phoneRecord = initial, padRecord = initial
        phoneRecord.fields["title"] = .init(value: "Renamed on phone", stamp: stamp("phone", 1, date: 100))
        padRecord.fields["isFavorite"] = .init(value: "1", stamp: stamp("pad", 1, date: 200))
        var phone = BookmarkSyncJournal(writer: "phone", revision: 1, records: [id: phoneRecord])
        var pad = BookmarkSyncJournal(writer: "pad", revision: 1, records: [id: padRecord])
        let originalPhone = phone
        try phone.merge(pad); try pad.merge(originalPhone)
        XCTAssertEqual(phone.records, pad.records)
        XCTAssertEqual(phone.records[id]?.fields["title"]?.value, "Renamed on phone")
        XCTAssertEqual(phone.records[id]?.fields["isFavorite"]?.value, "1")
        var baseline = initial
        baseline.fields["title"] = .init(value: "Stale restored name", stamp: stamp("backup", 50, baseline: true, date: 99_999))
        try phone.merge(.init(writer: "backup", revision: 50, records: [id: baseline]))
        XCTAssertEqual(phone.records[id]?.fields["title"]?.value, "Renamed on phone")
    }

    func testOnlyAnExplicitTombstoneDeletesAndCannotBeRevivedByStaleData() throws {
        let library = try LibraryStore(inMemory: true), id = UUID().uuidString
        var live = record(title: "Saved")
        var journal = BookmarkSyncJournal(writer: "phone", revision: 1, records: [id: live])
        try BookmarkCloudSyncService.applyMergedRecords(journal, to: library.mainContext)
        XCTAssertEqual(try library.mainContext.count(for: BookmarkRecord.request()), 1)
        try BookmarkCloudSyncService.applyMergedRecords(.init(writer: "empty"), to: library.mainContext)
        XCTAssertEqual(try library.mainContext.count(for: BookmarkRecord.request()), 1)
        let deletion = BookmarkSyncRecord(kind: .bookmark, fields: [:], deletion: stamp("pad", 2))
        try journal.merge(.init(writer: "pad", revision: 2, records: [id: deletion]))
        live.fields["title"] = .init(value: "Stale item edited much later", stamp: stamp("phone", 30))
        try journal.merge(.init(writer: "phone", revision: 30, records: [id: live]))
        XCTAssertNotNil(journal.records[id]?.deletion)
        try BookmarkCloudSyncService.applyMergedRecords(journal, to: library.mainContext)
        XCTAssertEqual(try library.mainContext.count(for: BookmarkRecord.request()), 0)
    }

    func testDeletingRemoteFolderPreservesUnchangedLocalChildrenAndIcons() throws {
        let library = try LibraryStore(inMemory: true), context = library.mainContext
        let folder = BookmarkFolderRecord(title: "Removed folder")
        let child = BookmarkRecord(title: "Keep local child", urlString: "https://local.example/")
        let nested = BookmarkFolderRecord(title: "Keep nested folder", parentID: folder.id)
        let icon = Data([1, 2, 3, 4]); child.faviconData = icon; child.folderID = folder.id
        context.insert(folder); context.insert(child); context.insert(nested); try context.save()
        let delta = BookmarkSyncJournal(writer: "pad", revision: 2, records: [folder.id.uuidString:
            .init(kind: .folder, fields: [:], deletion: stamp("pad", 2))])
        try BookmarkCloudSyncService.applyMergedRecords(delta, to: context)
        XCTAssertEqual(try context.count(for: BookmarkFolderRecord.request()), 1)
        XCTAssertEqual(try context.count(for: BookmarkRecord.request()), 1)
        XCTAssertNil(child.folderID); XCTAssertNil(nested.parentID)
        XCTAssertEqual(child.faviconData, icon)
    }

    func testMalformedPeerIsRejectedAtomicallyAndCannotOverflowRevision() throws {
        let id = UUID().uuidString
        var local = BookmarkSyncJournal(writer: "phone", revision: 1, records: [id: record(title: "Keep")])
        let original = local
        var malformed = BookmarkSyncJournal(writer: "pad", revision: 2, records: [UUID().uuidString: record(title: "Valid", writer: "pad", sequence: 2),
            "not-a-uuid": record(title: "Invalid", writer: "pad", sequence: 2)])
        XCTAssertThrowsError(try local.merge(malformed)); XCTAssertEqual(local, original)
        malformed.records.removeValue(forKey: "not-a-uuid"); malformed.revision = UInt64.max
        XCTAssertThrowsError(try local.merge(malformed)); XCTAssertEqual(local, original)
        var conflict = record(title: "Wrong kind", writer: "pad", sequence: 2, kind: .folder)
        conflict.fields["parentID"] = .init(value: nil, stamp: stamp("pad", 2))
        XCTAssertThrowsError(try local.merge(.init(writer: "pad", revision: 2, records: [id: conflict])))
        XCTAssertEqual(local, original)
    }
}

private final class BookmarkTestTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var available = true
    private var account = "first"
    init(root: URL) { self.root = root }
    func location() -> (URL, String)? {
        lock.lock(); defer { lock.unlock() }
        return available ? (root.appendingPathComponent(account), account) : nil
    }
    func setAvailable(_ value: Bool) { lock.lock(); available = value; lock.unlock() }
    func switchAccount() { lock.lock(); account = "second"; lock.unlock() }
}

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testCorruptLibraryExitsStartupLoadWithoutOverwritingStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let corruptStore = Data("Unreadable SQLite test fixture".utf8)
        try corruptStore.write(to: url)

        XCTAssertNil(SouloApp.openLibrary { try LibraryStore(url: url) })
        XCTAssertEqual(try Data(contentsOf: url), corruptStore)
    }

    func testFavoriteOnlyLibraryMigratesManualOrderAndPersistsAFilteredReorder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("favorite.sqlite")
        let ids = (0..<4).map { _ in UUID() }
        try autoreleasepool {
            let previous = NSPersistentContainer(name: "FavoriteOnly", managedObjectModel: LibraryStore.makeModel(includeOrder: false, includeVideoToolHistory: false))
            previous.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
            var failure: Error?
            previous.loadPersistentStores { _, error in failure = error }; if let failure { throw failure }
            for index in ids.indices {
                let item = NSEntityDescription.insertNewObject(forEntityName: BookmarkRecord.entityName, into: previous.viewContext)
                for (key, value) in ["id": ids[index], "title": "Page \(index)", "urlString": "https://example.com/\(index)",
                                     "dateAdded": Date(timeIntervalSince1970: Double(10-index)), "isFavorite": index.isMultiple(of: 2)] as [String: Any] {
                    item.setValue(value, forKey: key)
                }
            }
            try previous.viewContext.save()
            let store = try XCTUnwrap(previous.persistentStoreCoordinator.persistentStores.first)
            previous.viewContext.reset(); try previous.persistentStoreCoordinator.remove(store)
        }
        try autoreleasepool {
            let migrated = try LibraryStore(url: url)
            let all = try migrated.mainContext.fetch(BookmarkRecord.request(sortBy: BookmarkService.sortDescriptors))
            XCTAssertEqual(all.map(\.id), ids)
            XCTAssertEqual(all.filter(\.isFavorite).map(\.id), [ids[0], ids[2]])
            try BookmarkService.reorder([ids[2], ids[0]], context: migrated.mainContext)
            XCTAssertEqual(try migrated.mainContext.fetch(BookmarkRecord.request(sortBy: BookmarkService.sortDescriptors)).map(\.id), [ids[2], ids[1], ids[0], ids[3]])
            try close(migrated)
        }
        let reopened = try LibraryStore(url: url)
        XCTAssertEqual(try reopened.mainContext.fetch(BookmarkRecord.request(sortBy: BookmarkService.sortDescriptors)).map(\.id), [ids[2], ids[1], ids[0], ids[3]])
        let exported = try BookmarkLibraryService.archive(context: reopened.mainContext)
        let target = try LibraryStore(inMemory: true)
        _ = try BookmarkLibraryService.importArchive(BookmarkHTML.parse(BookmarkHTML.encode(exported)), into: nil, context: target.mainContext)
        XCTAssertEqual(try target.mainContext.fetch(BookmarkRecord.request(sortBy: BookmarkService.sortDescriptors)).map(\.urlString), exported.links.map(\.url))
        try close(reopened)
    }

    func testPreviousLibraryMigratesFavoriteMarksWithoutLosingRecordsOrExternalIcons() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("previous.sqlite"), id = UUID(), folderID = UUID()
        let icon = Data(repeating: 37, count: 2 * 1024 * 1024)
        try autoreleasepool {
            let previous = NSPersistentContainer(name: "Previous", managedObjectModel: LibraryStore.makeModel(includeFavorite: false, includeOrder: false, includeVideoToolHistory: false))
            previous.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
            var failure: Error?
            previous.loadPersistentStores { _, error in failure = error }; if let failure { throw failure }
            let record = NSEntityDescription.insertNewObject(forEntityName: BookmarkRecord.entityName, into: previous.viewContext)
            for (key, value) in ["id": id, "title": "Original page", "urlString": "https://example.com/", "dateAdded": Date(), "folderID": folderID, "faviconData": icon] as [String: Any] { record.setValue(value, forKey: key) }
            try previous.viewContext.save()
            let store = try XCTUnwrap(previous.persistentStoreCoordinator.persistentStores.first)
            var metadata = previous.persistentStoreCoordinator.metadata(for: store)
            metadata["SouloSwiftDataImported"] = true; previous.persistentStoreCoordinator.setMetadata(metadata, for: store)
            previous.viewContext.reset(); try previous.persistentStoreCoordinator.remove(store)
            try NSPersistentStoreCoordinator.setMetadata(metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: url)
        }
        try autoreleasepool {
            let library = try LibraryStore(url: url)
            let record = try XCTUnwrap(library.mainContext.fetch(BookmarkRecord.request()).first)
            XCTAssertEqual(record.id, id); XCTAssertEqual(record.folderID, folderID)
            XCTAssertEqual(record.faviconData, icon); XCTAssertFalse(record.isFavorite)
            XCTAssertEqual(library.container.persistentStoreCoordinator.metadata(for: try XCTUnwrap(library.container.persistentStoreCoordinator.persistentStores.first))["SouloSwiftDataImported"] as? Bool, true)
            record.title = "Renamed page"; record.isFavorite = true; try library.mainContext.save(); try close(library)
        }
        let reopened = try LibraryStore(url: url)
        let record = try XCTUnwrap(reopened.mainContext.fetch(BookmarkRecord.request()).first)
        XCTAssertEqual(record.title, "Renamed page"); XCTAssertTrue(record.isFavorite)
        XCTAssertEqual(record.faviconData, icon)
        let archive = try BookmarkLibraryService.archive(context: reopened.mainContext)
        XCTAssertTrue(try BookmarkHTML.parse(BookmarkHTML.encode(archive)).links[0].isFavorite)
        try close(reopened)
    }

    func testVideoToolsHistoryMigratesAndKeepsTheNewestPageAndItsMark() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("library.sqlite")
        let address = try XCTUnwrap(URL(string: "https://example.com/watch?id=1"))
        let alternate = try XCTUnwrap(URL(string: "https://example.com/watch?id=1&utm_source=fixture#player"))
        let now = Date()
        let id = UUID()
        try autoreleasepool {
            let previous = NSPersistentContainer(name: "PreviousHistory",
                managedObjectModel: LibraryStore.makeModel(includeVideoToolHistory: false))
            let description = NSPersistentStoreDescription(url: location)
            description.shouldAddStoreAsynchronously = false
            previous.persistentStoreDescriptions = [description]
            var failure: Error?
            previous.loadPersistentStores { _, error in failure = error }
            if let failure { throw failure }
            let context = previous.viewContext
            let row = NSEntityDescription.insertNewObject(forEntityName: SearchHistoryRecord.entityName, into: context)
            row.setValue(id, forKey: "id")
            row.setValue("Existing visit", forKey: "keyword")
            row.setValue(now, forKey: "timestamp")
            row.setValue(address.absoluteString, forKey: "visitedURLString")
            try context.save()
            context.reset()
            try previous.persistentStoreCoordinator.remove(XCTUnwrap(previous.persistentStoreCoordinator.persistentStores.first))
        }
        try autoreleasepool {
            let library = try LibraryStore(url: location)
            let context = library.mainContext
            let row = try XCTUnwrap(context.fetch(SearchHistoryRecord.request()).first)
            XCTAssertEqual(row.id, id)
            XCTAssertFalse(row.usedVideoTools)
            // An older copy can still carry an interaction that the latest visit did not.
            let older = SearchHistoryRecord(keyword: "Old video title", timestamp: now.addingTimeInterval(-10),
                visitedURLString: alternate.absoluteString)
            older.usedVideoTools = true
            context.insert(older)
            try context.save()
            SearchHistoryService.purgeExpiredBrowsingHistory(referenceDate: now, context: context)
            SearchHistoryService.recordWebVisit(url: alternate, title: "New video title",
                visitedAt: now.addingTimeInterval(2), context: context)
            XCTAssertEqual(row.keyword, "New video title")
            XCTAssertEqual(row.timestamp, now.addingTimeInterval(2))
            XCTAssertTrue(row.usedVideoTools)
            try close(library)
        }
        let reopened = try LibraryStore(url: location)
        let history = try reopened.mainContext.fetch(SearchHistoryRecord.request())
        XCTAssertEqual(history.map(\.id), [id])
        XCTAssertEqual(history.first?.visitedURLString, address.absoluteString)
        XCTAssertEqual(history.first?.usedVideoTools, true)
        SearchHistoryService.clearBrowsingHistory(context: reopened.mainContext)
        XCTAssertTrue(try reopened.mainContext.fetch(SearchHistoryRecord.request()).isEmpty)
        try close(reopened)
    }

    func testSearchHistoryUpdatesTheNewestTermAndPreservesPlatformScope() throws {
        let library = try LibraryStore(inMemory: true)
        let context = library.mainContext
        let now = Date()
        let latest = try XCTUnwrap(SearchHistoryService.addEntry(keyword: "Video", platformID: nil,
            context: context, searchedAt: now))
        let platformID = UUID()
        SearchHistoryService.addEntry(keyword: "Video", platformID: platformID, context: context, searchedAt: now)
        let repeated = SearchHistoryService.addEntry(keyword: "  video  ", platformID: nil,
            context: context, searchedAt: now.addingTimeInterval(60))
        let history = SearchHistoryService.fetchRecent(limit: 10, context: context)
        XCTAssertEqual(repeated?.id, latest.id)
        XCTAssertEqual(history.map(\.keyword), ["video", "Video"])
        XCTAssertEqual(history.first?.timestamp, now.addingTimeInterval(60))
        XCTAssertEqual(history.last?.platformID, platformID)
    }

    func testQuickLinksPreferHeartsAcrossFoldersAndFallBackWithoutDuplicates() throws {
        let library = try LibraryStore(inMemory: true)
        let pages = (0..<10).map { BookmarkRecord(title: "Page \($0)", urlString: "https://example.org/\($0)") }
        pages.forEach(library.mainContext.insert)
        XCTAssertEqual(BookmarkService.quickLinks(from: pages).map(\.title), Array(pages.prefix(8)).map(\.title))
        pages[8].folderID = UUID(); pages[8].isFavorite = true
        XCTAssertEqual(BookmarkService.quickLinks(from: pages).map(\.title), ["Page 8"])
        pages[8].isFavorite = false
        XCTAssertEqual(BookmarkService.quickLinks(from: [pages[0], pages[0]]).count, 1)
        XCTAssertTrue(BookmarkService.quickLinks(from: pages, limit: 0).isEmpty)
    }

    func testExistingSwiftDataLibraryMigratesAndDeletedItemsStayDeleted() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Legacy SwiftData libraries require iOS 17") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("library.sqlite")
        let bookmarkID = UUID(), folderID = UUID(), historyID = UUID()
        let date = Date(timeIntervalSince1970: 1_680_000_000)
        let favicon = Data(repeating: 17, count: 2 * 1024 * 1024)
        try autoreleasepool {
            let legacy = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
                configurations: ModelConfiguration(url: legacyURL, cloudKitDatabase: .none))
            let folder = BookmarkFolder(title: "Saved folder")
            folder.id = folderID
            folder.dateAdded = date
            let bookmark = BookmarkItem(title: "Saved page", urlString: "https://example.com/?a=1&b=2", platformName: "Example")
            bookmark.id = bookmarkID
            bookmark.folderID = folderID
            bookmark.dateAdded = date
            bookmark.faviconData = favicon
            let history = SearchHistoryItem(keyword: "Saved visit", platformID: UUID(), timestamp: date,
                visitedURLString: "https://example.com/")
            history.id = historyID
            legacy.mainContext.insert(folder)
            legacy.mainContext.insert(bookmark)
            legacy.mainContext.insert(history)
            try legacy.mainContext.save()
        }
        try autoreleasepool {
            let library = try LibraryStore(url: destination, legacyURL: legacyURL)
            let context = library.mainContext
            let bookmark = try XCTUnwrap(context.fetch(BookmarkRecord.request()).first)
            XCTAssertEqual(bookmark.id, bookmarkID)
            XCTAssertEqual(bookmark.folderID, folderID)
            XCTAssertEqual(bookmark.dateAdded, date)
            XCTAssertEqual(bookmark.faviconData, favicon)
            XCTAssertEqual(bookmark.platformName, "Example")
            let folder = try XCTUnwrap(context.fetch(BookmarkFolderRecord.request()).first)
            XCTAssertEqual(folder.id, folderID)
            XCTAssertEqual(folder.title, "Saved folder")
            let history = try XCTUnwrap(context.fetch(SearchHistoryRecord.request()).first)
            XCTAssertEqual(history.id, historyID)
            XCTAssertEqual(history.timestamp, date)
            XCTAssertEqual(history.visitedURLString, "https://example.com/")
            context.delete(bookmark)
            try context.save()
            try close(library)
        }
        try autoreleasepool {
            // Core Data can leave a truncated SQLite file after destruction.
            // Verify its records are gone, then simulate a stale source being
            // restored from backup: the migration marker must prevent revival.
            let retired = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
                configurations: ModelConfiguration(url: legacyURL, cloudKitDatabase: .none))
            XCTAssertEqual(try retired.mainContext.fetchCount(FetchDescriptor<BookmarkItem>()), 0)
            XCTAssertEqual(try retired.mainContext.fetchCount(FetchDescriptor<BookmarkFolder>()), 0)
            XCTAssertEqual(try retired.mainContext.fetchCount(FetchDescriptor<SearchHistoryItem>()), 0)
            let stale = BookmarkItem(title: "Deleted bookmark", urlString: "https://example.com/")
            stale.id = bookmarkID
            retired.mainContext.insert(stale)
            try retired.mainContext.save()
        }
        let reopened = try LibraryStore(url: destination, legacyURL: legacyURL)
        XCTAssertEqual(try reopened.mainContext.count(for: BookmarkRecord.request()), 0)
        XCTAssertEqual(try reopened.mainContext.count(for: BookmarkFolderRecord.request()), 1)
        XCTAssertEqual(try reopened.mainContext.count(for: SearchHistoryRecord.request()), 1)
        try close(reopened)
    }

    func testFailedLegacyImportPreservesSourceAndCanRetry() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Legacy SwiftData libraries require iOS 17") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("library.sqlite")
        let invalid = Data("Unreadable legacy library".utf8)
        try invalid.write(to: legacyURL)
        XCTAssertThrowsError(try LibraryStore(url: destination, legacyURL: legacyURL))
        XCTAssertEqual(try Data(contentsOf: legacyURL), invalid)
        try FileManager.default.removeItem(at: legacyURL)
        try autoreleasepool {
            let legacy = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
                configurations: ModelConfiguration(url: legacyURL, cloudKitDatabase: .none))
            legacy.mainContext.insert(BookmarkItem(title: "Recovered", urlString: "https://example.com/"))
            try legacy.mainContext.save()
        }
        let recovered = try LibraryStore(url: destination, legacyURL: legacyURL)
        XCTAssertEqual(try recovered.mainContext.fetch(BookmarkRecord.request()).map(\.title), ["Recovered"])
        try close(recovered)
    }

    private func close(_ library: LibraryStore) throws {
        library.mainContext.reset()
        for store in library.container.persistentStoreCoordinator.persistentStores {
            try library.container.persistentStoreCoordinator.remove(store)
        }
    }

    func testRollbackRestoresBookmarkChanges() throws {
        let library = try LibraryStore(inMemory: true)
        let bookmark = BookmarkRecord(title: "Original", urlString: "https://example.com/")
        library.mainContext.insert(bookmark)
        try library.mainContext.save()
        bookmark.title = "Unsaved"
        bookmark.folderID = UUID()
        library.mainContext.rollback()
        XCTAssertEqual(bookmark.title, "Original")
        XCTAssertNil(bookmark.folderID)
    }
}
