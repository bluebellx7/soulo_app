import Foundation
import Combine

/// The Settings shortcut shares one cleanup run across windows and repeated
/// taps. It uses the same safe defaults as the storage sheet, never the
/// destructive saved-data choices exposed alongside them.
@MainActor final class StorageQuickCleanupService: ObservableObject {
    static let shared = StorageQuickCleanupService()
    @Published private(set) var isRunning = false
    @Published private(set) var isRefreshingSize = false
    @Published private(set) var clearableBytes: Int64?
    @Published private(set) var lastReport: StorageCleanupReport?
    var didClear: Bool { lastReport != nil && lastReport?.failures.isEmpty == true }

    typealias Operation = @MainActor (StorageCleanupChoice, TabManager) async throws -> StorageCleanupReport
    private let operation: Operation
    private var inFlight: (UUID, Task<StorageCleanupReport, Never>)?
    private var sizeRefresh: (UUID, Task<Void, Never>)?
    private let automaticallyRefreshesSize: Bool

    private init() { operation = Self.clearChoice; automaticallyRefreshesSize = true }

    /// Dependency injection keeps tests away from real downloads and WebKit.
    init(operation: @escaping Operation) { self.operation = operation; automaticallyRefreshesSize = false }

    /// Called when Settings appears, not at launch or on a repeating timer.
    /// Keep the last estimate visible while a replacement scan is pending.
    func refreshSize(forceRefresh: Bool = false) async {
        guard !isRunning else { return }
        if !forceRefresh, let sizeRefresh { await sizeRefresh.1.value; return }
        sizeRefresh?.1.cancel()
        let revision = UUID()
        isRefreshingSize = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.sizeRefresh?.0 == revision { self.sizeRefresh = nil; self.isRefreshingSize = false }
            }
            let inventory = await StorageUsageService.inventory(forceRefresh: forceRefresh)
            guard !Task.isCancelled, self.sizeRefresh?.0 == revision, !self.isRunning else { return }
            let locations = StorageUsageLocations.current
            let scan = Task.detached(priority: .utility) {
                Self.systemCacheBytes(entries: inventory.entries, locations: locations)
            }
            let systemBytes = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled, self.sizeRefresh?.0 == revision, !self.isRunning else { return }
            if let bytes = Self.defaultBytes(records: inventory.records, systemBytes: systemBytes) { self.clearableBytes = bytes }
        }
        sizeRefresh = (revision, task)
        await task.value
    }

    func clearDefaults(tabManager: TabManager) async -> StorageCleanupReport {
        if let inFlight { return await inFlight.1.value }
        sizeRefresh?.1.cancel(); sizeRefresh = nil; isRefreshingSize = false
        let revision = UUID(), operation = operation
        let choices = StorageCleanupChoice.safeDefaults.filter { choice in
            switch choice {
            case .cache, .systemCaches: return true
            default: return false
            }
        }.sorted { $0.id < $1.id }
        isRunning = true
        lastReport = nil
        let task = Task { @MainActor in
            StorageUsageService.invalidateInventory()
            defer { StorageUsageService.invalidateInventory() }
            var report = StorageCleanupReport()
            for choice in choices {
                do { report.merge(try await operation(choice, tabManager)) }
                catch {
                    if case let .cache(category) = choice { report.retainedCategories.insert(category) }
                    else { report.retainedCategories.insert(.otherData) }
                    report.failures.append(choice.title + " · " + error.localizedDescription)
                }
            }
            return report
        }
        inFlight = (revision, task)
        let report = await task.value
        if inFlight?.0 == revision {
            inFlight = nil; isRunning = false; lastReport = report
            if automaticallyRefreshesSize { Task { await refreshSize(forceRefresh: true) } }
        }
        return report
    }

    /// Categories partition the inventory. System-cache files must come only
    /// from otherData, never add that whole category (which includes videos).
    nonisolated static func defaultBytes(records: [StorageUsageRecord], systemBytes: Int64?) -> Int64? {
        var total: Int64 = 0
        for choice in StorageCleanupChoice.safeDefaults {
            let bytes: Int64?
            switch choice {
            case .cache(let category):
                let record = records.first { $0.category == category }
                bytes = record?.isEstimated == false ? record?.bytes : nil
            case .systemCaches: bytes = systemBytes
            default: continue
            }
            guard let bytes else { return nil }
            total = adding(total, max(0, bytes))
        }
        return total
    }

    private nonisolated static func adding(_ first: Int64, _ second: Int64) -> Int64 {
        let sum = first.addingReportingOverflow(second)
        return sum.overflow ? .max : sum.partialValue
    }

    private nonisolated static func systemCacheBytes(entries: [StorageDiskEntry], locations: StorageUsageLocations) -> Int64? {
        // Reuse the measured inventory. No additional directory traversal or
        // download-service initialization is needed just to display Settings.
        let classifier = StoragePathClassifier(locations: locations)
        var visited = Set<String>(), total: Int64 = 0
        for entry in entries where entry.category == .otherData {
            guard !Task.isCancelled else { return nil }
            guard StorageOtherCleanup.canClearCache(entry.url, locations: locations),
                  visited.insert(classifier.normalizedPath(entry.url.path)).inserted else { continue }
            total = adding(total, max(0, entry.bytes))
        }
        return total
    }

    private static func clearChoice(_ choice: StorageCleanupChoice, tabManager: TabManager) async throws -> StorageCleanupReport {
        switch choice {
        case .cache(let category): return try await StorageUsageService.clear(category, tabManager: tabManager)
        case .systemCaches: return try await StorageOtherCleanup.clearCaches()
        default: return .init()
        }
    }
}
