import CoreData
import SwiftData

/// The library uses the same persistent store on iOS 16 and newer releases.
final class LibraryStore {
    let container: NSPersistentContainer
    var mainContext: NSManagedObjectContext { container.viewContext }

    private static let legacyImportKey = "SouloSwiftDataImported"

    init(inMemory: Bool = false, url: URL? = nil, legacyURL: URL? = nil) throws {
        container = NSPersistentContainer(name: "SouloLibrary", managedObjectModel: Self.model)
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            description.url = url ?? directory.appendingPathComponent("SouloLibrary.sqlite")
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        let importMarker: Bool?
        if description.type == NSSQLiteStoreType, let url = description.url {
            importMarker = try Self.migrateBookmarkFavoritesIfNeeded(at: url)
        } else { importMarker = nil }
        var loadingError: Error?
        container.loadPersistentStores { _, error in loadingError = error }
        if let loadingError { throw loadingError }
        if let importMarker, let store = container.persistentStoreCoordinator.persistentStores.first {
            var metadata = container.persistentStoreCoordinator.metadata(for: store)
            metadata[Self.legacyImportKey] = importMarker
            container.persistentStoreCoordinator.setMetadata(metadata, for: store)
        }
        configure(mainContext)
        if !inMemory, (url == nil || legacyURL != nil), #available(iOS 17.0, *) {
            let source = legacyURL ?? ModelConfiguration().url
            try importSwiftData(at: source)
        }
    }

    func makeContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = container.persistentStoreCoordinator
        configure(context)
        return context
    }

    private func configure(_ context: NSManagedObjectContext) {
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        context.undoManager = nil
    }

    @available(iOS 17.0, *)
    private func importSwiftData(at url: URL) throws {
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first,
              store.url?.standardizedFileURL != url.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }

        if coordinator.metadata(for: store)[Self.legacyImportKey] as? Bool != true {
            try autoreleasepool { try copySwiftDataRecords(at: url) }
            var metadata = coordinator.metadata(for: store)
            metadata[Self.legacyImportKey] = true
            coordinator.setMetadata(metadata, for: store)
        }
        // The new store is committed before retiring the old one. Use Core
        // Data's destruction API so SQLite locks, journals and external blobs
        // are handled safely. A failed cleanup can retry on the next launch.
        let cleanup = NSPersistentStoreCoordinator(managedObjectModel: Self.model)
        try? cleanup.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
    }

    @available(iOS 17.0, *)
    private func copySwiftDataRecords(at url: URL) throws {
        // Keep the original model names so SwiftData can also migrate stores
        // written before folders and browsing history were introduced.
        let legacy = try ModelContainer(
            for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        let source = ModelContext(legacy)
        do {
            let historyIDs = Set(try mainContext.fetch(SearchHistoryRecord.request()).map(\.id))
            let bookmarkIDs = Set(try mainContext.fetch(BookmarkRecord.request()).map(\.id))
            let folderIDs = Set(try mainContext.fetch(BookmarkFolderRecord.request()).map(\.id))
            for item in try source.fetch(FetchDescriptor<SearchHistoryItem>()) where !historyIDs.contains(item.id) {
                let record = SearchHistoryRecord(keyword: item.keyword, platformID: item.platformID,
                    timestamp: item.timestamp, visitedURLString: item.visitedURLString)
                record.id = item.id
                mainContext.insert(record)
            }
            for item in try source.fetch(FetchDescriptor<BookmarkFolder>()) where !folderIDs.contains(item.id) {
                let record = BookmarkFolderRecord(title: item.title, parentID: item.parentID)
                record.id = item.id
                record.dateAdded = item.dateAdded
                mainContext.insert(record)
            }
            for item in try source.fetch(FetchDescriptor<BookmarkItem>()) where !bookmarkIDs.contains(item.id) {
                let record = BookmarkRecord(title: item.title, urlString: item.urlString, platformName: item.platformName)
                record.id = item.id
                record.dateAdded = item.dateAdded
                record.folderID = item.folderID
                record.faviconData = item.faviconData
                mainContext.insert(record)
            }
            // One save commits the imported records together. Stable UUIDs
            // make retrying safe if the process stops before metadata is saved.
            try mainContext.save()
        } catch {
            mainContext.rollback()
            throw error
        }
    }

    static let model = makeModel()

    /// The previous model was built in code and has no .mom version in the
    /// bundle. Supply it explicitly for the one-time inferred migration.
    private static func migrateBookmarkFavoritesIfNeeded(at url: URL) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        guard !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return nil }
        guard let previous = [makeModel(includeFavorite: false, includeOrder: false), makeModel(includeOrder: false)]
            .first(where: { $0.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) }) else { return nil }
        let directory = url.deletingLastPathComponent().appendingPathComponent("SouloBookmarkMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let migrated = directory.appendingPathComponent("library.sqlite")
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: previous, destinationModel: model)
        let migration = NSMigrationManager(sourceModel: previous, destinationModel: model)
        try migration.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: nil,
            with: mapping, toDestinationURL: migrated, destinationType: NSSQLiteStoreType, destinationOptions: nil)
        try NSPersistentStoreCoordinator(managedObjectModel: model).replacePersistentStore(at: url,
            destinationOptions: nil, withPersistentStoreFrom: migrated, sourceOptions: nil, ofType: NSSQLiteStoreType)
        return metadata[legacyImportKey] as? Bool
    }

    static func makeModel(includeFavorite: Bool = true, includeOrder: Bool = true) -> NSManagedObjectModel {
        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = optional
            return attribute
        }
        func entity(_ name: String, _ type: NSManagedObject.Type, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
            let entity = NSEntityDescription()
            entity.name = name
            entity.managedObjectClassName = NSStringFromClass(type)
            entity.properties = attributes
            entity.uniquenessConstraints = [["id"]]
            return entity
        }
        let history = entity(SearchHistoryRecord.entityName, SearchHistoryRecord.self, [
            attribute("id", .UUIDAttributeType), attribute("keyword", .stringAttributeType),
            attribute("timestamp", .dateAttributeType), attribute("platformID", .UUIDAttributeType, optional: true),
            attribute("visitedURLString", .stringAttributeType, optional: true)
        ])
        let favicon = attribute("faviconData", .binaryDataAttributeType, optional: true)
        favicon.allowsExternalBinaryDataStorage = true
        let bookmarks = entity(BookmarkRecord.entityName, BookmarkRecord.self, [
            attribute("id", .UUIDAttributeType), attribute("title", .stringAttributeType),
            attribute("urlString", .stringAttributeType), attribute("platformName", .stringAttributeType, optional: true),
            attribute("dateAdded", .dateAttributeType), attribute("folderID", .UUIDAttributeType, optional: true), favicon
        ])
        if includeFavorite {
            let favorite = attribute("isFavorite", .booleanAttributeType)
            favorite.defaultValue = false
            bookmarks.properties.append(favorite)
        }
        if includeOrder {
            let order = attribute("sortOrder", .integer64AttributeType)
            order.defaultValue = 0
            bookmarks.properties.append(order)
        }
        let folders = entity(BookmarkFolderRecord.entityName, BookmarkFolderRecord.self, [
            attribute("id", .UUIDAttributeType), attribute("title", .stringAttributeType),
            attribute("parentID", .UUIDAttributeType, optional: true), attribute("dateAdded", .dateAttributeType)
        ])
        let model = NSManagedObjectModel()
        model.entities = [history, bookmarks, folders]
        return model
    }
}

protocol LibraryRecord: NSManagedObject, Identifiable where ID == UUID {
    static var entityName: String { get }
}

extension LibraryRecord {
    static func request(predicate: NSPredicate? = nil, sortBy: [NSSortDescriptor] = []) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = predicate
        request.sortDescriptors = sortBy
        return request
    }
}

@objc(SouloSearchHistoryRecord)
final class SearchHistoryRecord: NSManagedObject, LibraryRecord {
    static let entityName = "SearchHistoryRecord"
    @NSManaged var id: UUID
    @NSManaged var keyword: String
    @NSManaged var timestamp: Date
    @NSManaged var platformID: UUID?
    @NSManaged var visitedURLString: String?

    convenience init(keyword: String, platformID: UUID? = nil, timestamp: Date = Date(), visitedURLString: String? = nil) {
        self.init(entity: LibraryStore.model.entitiesByName[Self.entityName]!, insertInto: nil)
        id = UUID()
        self.keyword = keyword
        self.platformID = platformID
        self.timestamp = timestamp
        self.visitedURLString = visitedURLString
    }

    var isWebVisit: Bool { visitedURLString != nil }
}

@objc(SouloBookmarkRecord)
final class BookmarkRecord: NSManagedObject, LibraryRecord {
    static let entityName = "BookmarkRecord"
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var urlString: String
    @NSManaged var platformName: String?
    @NSManaged var dateAdded: Date
    @NSManaged var folderID: UUID?
    @NSManaged var faviconData: Data?
    @NSManaged var isFavorite: Bool
    @NSManaged var sortOrder: Int64

    convenience init(title: String, urlString: String, platformName: String? = nil) {
        self.init(entity: LibraryStore.model.entitiesByName[Self.entityName]!, insertInto: nil)
        id = UUID()
        self.title = title
        self.urlString = urlString
        self.platformName = platformName
        dateAdded = Date()
        isFavorite = false
        sortOrder = 0
    }

    var url: URL? { URL(string: urlString) }
}

@objc(SouloBookmarkFolderRecord)
final class BookmarkFolderRecord: NSManagedObject, LibraryRecord {
    static let entityName = "BookmarkFolderRecord"
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var parentID: UUID?
    @NSManaged var dateAdded: Date

    convenience init(title: String, parentID: UUID? = nil) {
        self.init(entity: LibraryStore.model.entitiesByName[Self.entityName]!, insertInto: nil)
        id = UUID()
        self.title = title
        self.parentID = parentID
        dateAdded = Date()
    }
}
