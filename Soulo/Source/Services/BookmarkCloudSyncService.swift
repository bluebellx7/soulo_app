import Foundation
import CoreData
import CryptoKit
import UIKit

/// Field-level merge: absence is never a deletion, and factory/restore baselines
/// cannot overwrite an explicit edit. A tombstone can only originate in a save
/// that actually deleted an object; it permanently wins for that UUID.
struct BookmarkSyncStamp: Codable, Equatable, Comparable, Sendable {
    var baseline: Bool
    var date: Date
    var sequence: UInt64
    var writer: String
    static func < (a: Self, b: Self) -> Bool {
        if a.baseline != b.baseline { return a.baseline }
        if a.sequence != b.sequence { return a.sequence < b.sequence }
        if a.date != b.date { return a.date < b.date }
        return a.writer < b.writer
    }
}
struct BookmarkSyncField: Codable, Equatable, Sendable {
    var value: String?
    var stamp: BookmarkSyncStamp
}
struct BookmarkSyncRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case bookmark, folder }
    var kind: Kind
    var fields: [String: BookmarkSyncField]
    var deletion: BookmarkSyncStamp?
}
struct BookmarkSyncJournal: Codable, Equatable, Sendable {
    var version = 1
    var writer: String
    var revision: UInt64 = 0
    var records: [String: BookmarkSyncRecord] = [:]

    mutating func merge(_ other: Self) throws {
        guard other.version == 1, !other.writer.isEmpty, other.writer.utf8.count <= 128,
              other.revision < UInt64.max - 1,
              Set(records.keys).union(other.records.keys).count <= 200_000 else { throw CocoaError(.coderReadCorrupt) }
        // Validate the entire peer before changing anything. A malformed final
        // record must not leave a partially applied journal in memory.
        for (id, incoming) in other.records {
            let allowed: Set<String> = incoming.kind == .bookmark
                ? ["title", "urlString", "dateAdded", "isFavorite", "sortOrder", "folderID", "platformName"]
                : ["title", "dateAdded", "parentID"]
            guard UUID(uuidString: id) != nil, incoming.fields.count <= 8,
                  Set(incoming.fields.keys).isSubset(of: allowed),
                  incoming.fields.values.allSatisfy({ ($0.value?.utf8.count ?? 0) <= 65_536 && Self.valid($0.stamp, revision: other.revision) }),
                  incoming.deletion?.baseline != true,
                  incoming.deletion.map({ Self.valid($0, revision: other.revision) }) ?? true,
                  records[id] == nil || records[id]?.kind == incoming.kind else { throw CocoaError(.coderReadCorrupt) }
        }
        for (id, incoming) in other.records {
            if var local = records[id] {
                for (key, value) in incoming.fields where local.fields[key] == nil || local.fields[key]!.stamp < value.stamp { local.fields[key] = value }
                if let deletion = incoming.deletion, local.deletion == nil || local.deletion! < deletion { local.deletion = deletion }
                records[id] = local
            } else { records[id] = incoming }
        }
        revision = max(revision, other.revision)
    }
    private static func valid(_ stamp: BookmarkSyncStamp, revision: UInt64) -> Bool {
        stamp.sequence <= revision && stamp.date.timeIntervalSince1970.isFinite
            && !stamp.writer.isEmpty && stamp.writer.utf8.count <= 128
    }
}
private struct BookmarkSyncSnapshot: Sendable {
    var id: String
    var kind: BookmarkSyncRecord.Kind
    var fields: [String: String]
    var changedKeys: Set<String>
}

/// Serial disk work keeps coordinated iCloud access and encoding off the main
/// thread. Older queued writes can never replace a newer local revision.
private actor BookmarkSyncDisk {
    private let locationProvider: (@Sendable () -> (URL, String)?)?
    init(locationProvider: (@Sendable () -> (URL, String)?)? = nil) { self.locationProvider = locationProvider }
    private var revisions: [URL: UInt64] = [:]
    private var readVersions: [URL: String] = [:]
    private var failedReads = Set<URL>()
    func resetCloudCache() { readVersions = [:]; failedReads = [] }
    func backup(_ journal: BookmarkSyncJournal, beside url: URL) throws {
        let directory = url.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let initial = directory.appendingPathComponent("initial.soulo-bookmarks")
        if !FileManager.default.fileExists(atPath: initial.path) { try write(journal, to: initial) }
        try write(journal, to: directory.appendingPathComponent("\(Date().timeIntervalSince1970).soulo-bookmarks"))
        let recent = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent != initial.lastPathComponent }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in recent.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
    }
    func read(_ url: URL, coordinated: Bool = false) throws -> BookmarkSyncJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var result: Result<BookmarkSyncJournal, Error>?
        let read: (URL) -> Void = { source in
            result = Result {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 64 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
                let journal = try PropertyListDecoder().decode(BookmarkSyncJournal.self, from: Data(contentsOf: source))
                var validator = BookmarkSyncJournal(writer: "validator"); try validator.merge(journal)
                return journal
            }
        }
        if coordinated {
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error, byAccessor: read)
            if let error { throw error }
        } else { read(url) }
        return try result?.get()
    }
    func write(_ journal: BookmarkSyncJournal, to url: URL, coordinated: Bool = false) throws {
        try Task.checkCancellation()
        guard journal.revision >= revisions[url, default: 0] else { return }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(journal)
        guard data.count <= 64 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var writeError: Error?
        let write: (URL) -> Void = { destination in
            do { try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            catch { writeError = error }
        }
        if coordinated {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error, byAccessor: write)
            if let error { throw error }
        } else { write(url) }
        if let writeError { throw writeError }
        revisions[url] = journal.revision
    }
    func locateCloud() -> (URL, String)? {
        if let locationProvider { return locationProvider() }
        guard let token = FileManager.default.ubiquityIdentityToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false),
              let root = FileManager.default.url(forUbiquityContainerIdentifier: BookmarkCloudSyncService.containerIdentifier) else { return nil }
        return (root.appendingPathComponent("Documents/BookmarkSync/v1", isDirectory: true), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    func documents(metadata: [URL], root: URL) throws -> [URL] {
        guard locationProvider != nil else { return metadata }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "soulo-bookmarks" }
    }
    func readCloud(_ urls: [URL], inside root: URL) -> ([BookmarkSyncJournal], Bool) {
        var journals: [BookmarkSyncJournal] = [], failed = false
        failedReads.formIntersection(Set(urls))
        for url in Set(urls) {
            guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), url.pathExtension == "soulo-bookmarks" else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .contentModificationDateKey, .fileSizeKey])
                if let status = values.ubiquitousItemDownloadingStatus, status != .current {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    continue
                }
                let signature = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
                guard readVersions[url] != signature else { continue }
                if let journal = try read(url, coordinated: true) {
                    guard url.deletingPathExtension().lastPathComponent == journal.writer else { throw CocoaError(.coderReadCorrupt) }
                    var validator = BookmarkSyncJournal(writer: "validator"); try validator.merge(journal)
                    journals.append(journal)
                }
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                    if let historical = try read(version.url, coordinated: true) { journals.append(historical) }
                }
                readVersions[url] = signature
                failedReads.remove(url)
            } catch { failed = true; failedReads.insert(url) }
        }
        return (journals, failed || !failedReads.isEmpty)
    }
}

@MainActor
final class BookmarkCloudSyncService: NSObject, ObservableObject {
    static let shared = BookmarkCloudSyncService()
    nonisolated static let containerIdentifier = "iCloud.com.dkluge.Soulo"
    static let enabledKey = "icloud_bookmarks_sync_enabled"
    @Published private(set) var hasSyncIssue = false
    @Published private(set) var isSynchronizing = false
    private let disk: BookmarkSyncDisk
    private let defaults: UserDefaults
    private let localDirectory: URL
    private let usesMetadataQuery: Bool
    private var context: NSManagedObjectContext?
    private var container: NSPersistentContainer?
    private var journal: BookmarkSyncJournal?
    private var query: NSMetadataQuery?
    private var cloudRoot: URL?
    private var loading: Task<Void, Never>?
    private var syncing: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var applying = false
    private var uploadedRecords: [String: BookmarkSyncRecord]?
    private var changes: [BookmarkSyncSnapshot] = []
    private var deleted: [(String, BookmarkSyncRecord.Kind)] = []
    private var deferredChanges: [String: BookmarkSyncSnapshot] = [:]
    private var deferredDeletions: [String: BookmarkSyncRecord.Kind] = [:]
    private var switchingAccount = false
    private var accountChanges: [String: BookmarkSyncSnapshot] = [:]
    private var accountDeletions: [String: BookmarkSyncRecord.Kind] = [:]
    private var initialized = false
    private var scope: String
    private var generation = 0
    private var needsReconciliation = false
    private var reconciliationIDs = Set<String>()
    private var needsAnotherPass = false
    private var lastEnabled: Bool?
    private var observers: [NSObjectProtocol] = []
    private let writer: String
    init(defaults: UserDefaults = .standard, localDirectory: URL? = nil,
         locationProvider: (@Sendable () -> (URL, String)?)? = nil) {
        self.defaults = defaults
        self.localDirectory = localDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soulo/BookmarkSync", isDirectory: true)
        disk = BookmarkSyncDisk(locationProvider: locationProvider)
        usesMetadataQuery = locationProvider == nil
        scope = defaults.string(forKey: "soulo.bookmarks.lastCloudAccount") ?? "local"
        let key = "soulo.bookmarks.installationID"
        let installation = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(installation, forKey: key)
        let raw = installation + "." + (UIDevice.current.identifierForVendor?.uuidString ?? "local")
        writer = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        super.init()
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        pending?.cancel(); syncing?.cancel(); loading?.cancel()
    }
    private var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    private var localURL: URL {
        localURL(for: scope)
    }
    private func localURL(for scope: String) -> URL {
        localDirectory.appendingPathComponent("\(scope)/\(writer).soulo-bookmarks")
    }
    func attach(container: NSPersistentContainer) {
        guard context == nil else { return }
        self.container = container; context = container.viewContext
        NotificationCenter.default.addObserver(self, selector: #selector(willSave), name: .NSManagedObjectContextWillSave, object: context)
        NotificationCenter.default.addObserver(self, selector: #selector(didSave), name: .NSManagedObjectContextDidSave, object: context)
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.accountChanged() }
        })
        lastEnabled = enabled
        if enabled || FileManager.default.fileExists(atPath: localURL.path) { load() }
    }
    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.enabledKey)
        preferenceChanged()
    }
    @objc private func preferenceChanged() {
        guard lastEnabled != enabled else { return }; lastEnabled = enabled
        if enabled { load(); schedule() }
        else { generation += 1; pending?.cancel(); syncing?.cancel(); query?.stop(); query = nil; cloudRoot = nil; uploadedRecords = nil; isSynchronizing = false }
    }
    @objc private func accountChanged() {
        generation += 1; pending?.cancel(); syncing?.cancel(); query?.stop(); query = nil; cloudRoot = nil
        uploadedRecords = nil
        Task { await disk.resetCloudCache() }
        if enabled { schedule() }
    }
    private func load() {
        guard !initialized, loading == nil, let container else { return }
        let url = localURL, currentWriter = writer
        loading = Task { [weak self] in
            guard let self else { return }
            defer { self.loading = nil }
            do {
                var initial = try await self.disk.read(url) ?? BookmarkSyncJournal(writer: currentWriter)
                guard initial.writer == currentWriter else { throw CocoaError(.coderReadCorrupt) }
                let background = container.newBackgroundContext()
                let snapshots = try await background.perform { try Self.snapshots(in: background) }
                self.seed(snapshots, into: &initial)
                let existing = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.fields) })
                self.reconciliationIDs = Set(initial.records.compactMap { id, record in
                    let differs = record.deletion != nil ? existing[id] != nil : existing[id] != record.fields.compactMapValues(\.value)
                    return differs ? id : nil
                })
                self.journal = initial; self.initialized = true; self.needsReconciliation = true
                self.capture(Array(self.deferredChanges.values), deletions: self.deferredDeletions.map { ($0.key, $0.value) })
                self.deferredChanges = [:]; self.deferredDeletions = [:]
                self.persist(); if self.enabled { self.schedule() }
            } catch { self.hasSyncIssue = true }
        }
    }
    private nonisolated static func snapshots(in context: NSManagedObjectContext) throws -> [BookmarkSyncSnapshot] {
        try context.fetch(BookmarkRecord.request()).map { snapshot($0) } + context.fetch(BookmarkFolderRecord.request()).map { snapshot($0) }
    }
    private nonisolated static func snapshot(_ object: NSManagedObject) -> BookmarkSyncSnapshot {
        if let item = object as? BookmarkRecord {
            var fields = ["title": item.title, "urlString": item.urlString, "dateAdded": String(item.dateAdded.timeIntervalSince1970), "isFavorite": item.isFavorite ? "1" : "0", "sortOrder": String(item.sortOrder)]
            fields["folderID"] = item.folderID?.uuidString
            fields["platformName"] = item.platformName
            let metadata: Set<String> = ["title", "urlString", "dateAdded", "isFavorite", "sortOrder", "folderID", "platformName"]
            return .init(id: item.id.uuidString, kind: .bookmark, fields: fields, changedKeys: Set(object.changedValues().keys).intersection(metadata))
        }
        let item = object as! BookmarkFolderRecord
        var fields = ["title": item.title, "dateAdded": String(item.dateAdded.timeIntervalSince1970)]
        fields["parentID"] = item.parentID?.uuidString
        return .init(id: item.id.uuidString, kind: .folder, fields: fields, changedKeys: Set(object.changedValues().keys).intersection(["title", "dateAdded", "parentID"]))
    }
    private func seed(_ snapshots: [BookmarkSyncSnapshot], into journal: inout BookmarkSyncJournal) {
        for item in snapshots where journal.records[item.id] == nil {
            let stamp = BookmarkSyncStamp(baseline: true, date: Date(timeIntervalSince1970: Double(item.fields["dateAdded"] ?? "") ?? 0), sequence: 0, writer: writer)
            journal.records[item.id] = .init(kind: item.kind, fields: item.fields.mapValues { .init(value: $0, stamp: stamp) })
        }
    }
    @objc private func willSave() {
        guard !applying, let context else { return }
        // Remember explicit local edits even before the first opt-in. Loading is
        // lazy and remains local while disabled; favicon-only saves do no work.
        changes = context.insertedObjects.union(context.updatedObjects).compactMap { object in
            guard object is BookmarkRecord || object is BookmarkFolderRecord else { return nil }
            let snapshot = Self.snapshot(object)
            return object.isInserted || !snapshot.changedKeys.isEmpty ? snapshot : nil
        }
        deleted = context.deletedObjects.compactMap { object in
            if let item = object as? BookmarkRecord { return (item.id.uuidString, .bookmark) }
            if let item = object as? BookmarkFolderRecord { return (item.id.uuidString, .folder) }
            return nil
        }
    }
    @objc private func didSave() {
        guard !applying, !changes.isEmpty || !deleted.isEmpty else { return }
        if !initialized {
            enqueue(changes, deletions: deleted, into: &deferredChanges, removed: &deferredDeletions)
            changes = []; deleted = []; load(); return
        }
        if switchingAccount { enqueue(changes, deletions: deleted, into: &accountChanges, removed: &accountDeletions) }
        capture(changes, deletions: deleted); changes = []; deleted = []; persist()
        if enabled { schedule() }
    }
    private func enqueue(_ snapshots: [BookmarkSyncSnapshot], deletions: [(String, BookmarkSyncRecord.Kind)], into pending: inout [String: BookmarkSyncSnapshot], removed: inout [String: BookmarkSyncRecord.Kind]) {
        for var snapshot in snapshots {
            snapshot.changedKeys.formUnion(pending[snapshot.id]?.changedKeys ?? [])
            pending[snapshot.id] = snapshot
        }
        for (id, kind) in deletions { removed[id] = kind }
    }
    private func capture(_ snapshots: [BookmarkSyncSnapshot], deletions: [(String, BookmarkSyncRecord.Kind)]) {
        guard var current = journal, !snapshots.isEmpty || !deletions.isEmpty else { return }
        current.revision += 1
        let stamp = BookmarkSyncStamp(baseline: false, date: Date(), sequence: current.revision, writer: writer)
        for item in snapshots {
            var record = current.records[item.id] ?? .init(kind: item.kind, fields: [:])
            let keys = Set(item.fields.keys).union(record.fields.keys).union(item.changedKeys)
            for key in keys where record.fields[key]?.value != item.fields[key] || item.changedKeys.contains(key) {
                record.fields[key] = .init(value: item.fields[key], stamp: stamp)
            }
            current.records[item.id] = record
        }
        for (id, kind) in deletions {
            var record = current.records[id] ?? .init(kind: kind, fields: [:]); record.deletion = stamp; current.records[id] = record
        }
        journal = current
    }
    private func persist() {
        guard let snapshot = journal else { return }; let url = localURL
        Task { do { try await disk.write(snapshot, to: url) } catch { hasSyncIssue = true } }
    }
    func refresh() { guard enabled else { return }; load(); schedule() }
    func synchronizeNow() async {
        guard enabled else { return }
        load()
        await loading?.value
        pending?.cancel()
        if let syncing { await syncing.value }
        await synchronize()
    }
    private func schedule() {
        guard enabled else { return }; pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            await self?.synchronize()
        }
    }
    private func synchronize() async {
        guard enabled, initialized, let context else { return }
        guard syncing == nil else { needsAnotherPass = true; return }
        let currentGeneration = generation
        isSynchronizing = true
        syncing = Task { [weak self] in
            guard let self else { return }
            defer {
                self.syncing = nil; self.isSynchronizing = false
                if self.needsAnotherPass { self.needsAnotherPass = false; if self.enabled, !self.hasSyncIssue { self.schedule() } }
            }
            do {
                guard let (root, account) = await self.disk.locateCloud() else { throw CocoaError(.ubiquitousFileUnavailable) }
                guard self.generation == currentGeneration, self.enabled else { return }
                if account != self.scope {
                    self.switchingAccount = true
                    defer { self.switchingAccount = false }
                    var accountJournal = try await self.disk.read(self.localURL(for: account)) ?? BookmarkSyncJournal(writer: self.writer)
                    guard accountJournal.writer == self.writer else { throw CocoaError(.coderReadCorrupt) }
                    guard self.generation == currentGeneration, self.enabled, !Task.isCancelled else { return }
                    // The first account inherits this installation's offline
                    // edit history. Later account changes stay partitioned.
                    if self.scope == "local", let local = self.journal { try accountJournal.merge(local) }
                    self.seed(try Self.snapshots(in: context), into: &accountJournal)
                    self.scope = account
                    self.defaults.set(account, forKey: "soulo.bookmarks.lastCloudAccount")
                    self.journal = accountJournal
                    self.capture(Array(self.accountChanges.values), deletions: self.accountDeletions.map { ($0.key, $0.value) })
                    self.accountChanges = [:]; self.accountDeletions = [:]
                    self.needsReconciliation = true
                    self.reconciliationIDs = Set(self.journal?.records.keys.map { $0 } ?? [])
                    self.uploadedRecords = nil
                    await self.disk.resetCloudCache()
                    self.persist()
                }
                self.cloudRoot = root; self.startQuery()
                if context.hasChanges { try context.save() }
                let metadata = (self.query?.results as? [NSMetadataItem] ?? []).compactMap { $0.value(forAttribute: NSMetadataItemURLKey) as? URL }
                let urls = try await self.disk.documents(metadata: metadata, root: root)
                let (peers, failed) = await self.disk.readCloud(urls, inside: root)
                guard self.generation == currentGeneration, self.enabled, !Task.isCancelled else { return }
                if context.hasChanges { try context.save() }
                guard let base = self.journal else { return }
                var merged = try await Task.detached(priority: .utility) {
                    var result = base
                    for peer in peers { try result.merge(peer); result.revision = max(result.revision, peer.revision) }
                    return result
                }.value
                guard self.generation == currentGeneration, self.enabled, !Task.isCancelled else { return }
                if let latest = self.journal, latest.revision != base.revision { try merged.merge(latest); merged.revision = max(merged.revision, latest.revision) }
                if merged.records != self.journal?.records || self.needsReconciliation {
                    if let before = self.journal { try await self.disk.backup(before, beside: self.localURL) }
                    guard self.generation == currentGeneration, self.enabled, !Task.isCancelled else { return }
                    // Edits can arrive while the recovery copy is written.
                    if let latest = self.journal { try merged.merge(latest); merged.revision = max(merged.revision, latest.revision) }
                    var delta = merged
                    delta.records = merged.records.filter { id, record in self.reconciliationIDs.contains(id) || self.journal?.records[id] != record }
                    try self.apply(delta, to: context)
                    merged.revision += 1; self.journal = merged; self.needsReconciliation = false
                    self.reconciliationIDs = []
                    try await self.disk.write(merged, to: self.localURL)
                }
                guard self.generation == currentGeneration, self.enabled, !Task.isCancelled else { return }
                if let local = self.journal, local.revision < merged.revision { self.journal = merged; self.persist() }
                if self.uploadedRecords != merged.records {
                    try await self.disk.write(merged, to: root.appendingPathComponent(self.writer + ".soulo-bookmarks"), coordinated: true)
                    self.uploadedRecords = merged.records
                }
                self.hasSyncIssue = failed
            } catch is CancellationError { }
            catch { self.hasSyncIssue = true }
        }
        await syncing?.value
    }
    private func startQuery() {
        guard usesMetadataQuery, query == nil else { return }
        let query = NSMetadataQuery(); query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.soulo-bookmarks")
        query.notificationBatchingInterval = 1
        NotificationCenter.default.addObserver(self, selector: #selector(metadataChanged), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(metadataChanged), name: .NSMetadataQueryDidUpdate, object: query)
        self.query = query; query.start()
    }
    @objc private func metadataChanged() { schedule() }
    private func apply(_ merged: BookmarkSyncJournal, to context: NSManagedObjectContext) throws {
        applying = true; defer { applying = false }
        do { try Self.applyMergedRecords(merged, to: context) }
        catch { context.rollback(); throw error }
    }
    static func applyMergedRecords(_ merged: BookmarkSyncJournal, to context: NSManagedObjectContext) throws {
        let ids = merged.records.keys.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return }
        let folderIDs = merged.records.compactMap { id, record in record.kind == .folder ? UUID(uuidString: id) : nil }
        let predicate = folderIDs.isEmpty ? NSPredicate(format: "id IN %@", ids)
            : NSCompoundPredicate(orPredicateWithSubpredicates: [NSPredicate(format: "id IN %@", ids), NSPredicate(format: "folderID IN %@", folderIDs)])
        var bookmarks = Dictionary(uniqueKeysWithValues: try context.fetch(BookmarkRecord.request(predicate: predicate)).map { ($0.id.uuidString, $0) })
        var folders = Dictionary(uniqueKeysWithValues: try context.fetch(BookmarkFolderRecord.request()).map { ($0.id.uuidString, $0) })
        for (id, record) in merged.records {
            guard let uuid = UUID(uuidString: id) else { continue }
            if record.deletion != nil {
                if let item = bookmarks[id] { context.delete(item) }; if let folder = folders[id] { context.delete(folder) }
                continue
            }
            func value(_ key: String) -> String? { record.fields[key]?.value }
            guard let title = value("title"), let rawDate = value("dateAdded"), let seconds = Double(rawDate), seconds.isFinite else { continue }
            if record.kind == .folder {
                let folder = folders[id] ?? BookmarkFolderRecord(title: title)
                if folder.managedObjectContext != nil, Self.snapshot(folder).fields == record.fields.compactMapValues(\.value) { continue }
                if folder.managedObjectContext == nil { folder.id = uuid; context.insert(folder); folders[id] = folder }
                folder.title = title; folder.dateAdded = Date(timeIntervalSince1970: seconds)
                folder.parentID = value("parentID").flatMap(UUID.init(uuidString:))
                if folder.parentID == uuid { folder.parentID = nil }
            } else {
                guard let url = value("urlString"), URL(string: url) != nil else { continue }
                let item = bookmarks[id] ?? BookmarkRecord(title: title, urlString: url)
                if item.managedObjectContext != nil, Self.snapshot(item).fields == record.fields.compactMapValues(\.value) { continue }
                if item.managedObjectContext == nil { item.id = uuid; context.insert(item); bookmarks[id] = item }
                item.title = title; item.urlString = url; item.dateAdded = Date(timeIntervalSince1970: seconds)
                item.isFavorite = value("isFavorite") == "1"; item.sortOrder = value("sortOrder").flatMap(Int64.init) ?? 0
                item.folderID = value("folderID").flatMap(UUID.init(uuidString:)); item.platformName = value("platformName")
            }
        }
        // Missing/deleted folders must not make live children disappear.
        let liveFolderIDs = Set(folders.values.filter { !$0.isDeleted }.map(\.id))
        for item in bookmarks.values where !item.isDeleted {
            if let parent = item.folderID, !liveFolderIDs.contains(parent) { item.folderID = nil }
        }
        for folder in folders.values where !folder.isDeleted {
            var seen: Set<UUID> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard seen.insert(id).inserted, let next = folders[id.uuidString], !next.isDeleted else { folder.parentID = nil; break }
                parent = next.parentID
            }
        }
        if context.hasChanges { try context.save() }
    }
}
