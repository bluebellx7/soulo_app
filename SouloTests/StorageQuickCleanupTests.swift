import XCTest
@testable import Soulo

@MainActor final class StorageQuickCleanupTests: XCTestCase {
    private func manager(key: String) -> TabManager {
        // Prevent test managers from importing the real saved-tab preference.
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        return TabManager(storageKey: key)
    }

    func testEstimateCountsOnlyDefaultCategoriesAndAllowedSystemEntriesOnce() {
        let records = StorageUsageCategory.allCases.map { category in
            StorageUsageRecord(category: category,
                bytes: StorageCleanupChoice.safeDefaults.contains(.cache(category)) ? 100 : 1_000_000,
                isEstimated: false)
        }
        let count = StorageCleanupChoice.safeDefaults.filter { if case .cache = $0 { return true }; return false }.count
        XCTAssertEqual(StorageQuickCleanupService.defaultBytes(records: records, systemBytes: 37), Int64(count) * 100 + 37)
        XCTAssertNil(StorageQuickCleanupService.defaultBytes(records: records, systemBytes: nil))
        let pending = records.map { StorageUsageRecord(category: $0.category, bytes: $0.bytes,
            isEstimated: $0.category == .webData) }
        XCTAssertNil(StorageQuickCleanupService.defaultBytes(records: pending, systemBytes: 37))
    }

    func testShortcutDefaultsKeepPreviewsIconsAndAllSavedContent() async {
        let key = "quick-cleanup-scope-" + UUID().uuidString
        let tabs = manager(key: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let defaults = StorageCleanupChoice.safeDefaults
        XCTAssertFalse(defaults.contains(.cache(.tabSnapshots)))
        XCTAssertFalse(defaults.contains(.cache(.favicons)))
        XCTAssertTrue(defaults.contains(.cache(.webData)))
        XCTAssertTrue(defaults.contains(.systemCaches))
        XCTAssertTrue(defaults.allSatisfy { !$0.isSavedData })
        for destructive in StorageCleanupChoice.saved { XCTAssertFalse(defaults.contains(destructive)) }
        var executed: [StorageCleanupChoice] = []
        let service = StorageQuickCleanupService { choice, manager in
            XCTAssertTrue(manager === tabs)
            executed.append(choice)
            return .init()
        }
        let report = await service.clearDefaults(tabManager: tabs)
        XCTAssertEqual(Set(executed), defaults)
        XCTAssertEqual(executed.count, defaults.count)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(service.isRunning)
    }

    func testRepeatedShortcutRequestsShareWorkAndContinueAfterOneFailure() async {
        let key = "quick-cleanup-flight-" + UUID().uuidString
        let tabs = manager(key: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        var executed: [StorageCleanupChoice] = []
        var resume: CheckedContinuation<Void, Never>?
        var requested = 0
        let service = StorageQuickCleanupService { choice, _ in
            executed.append(choice)
            if executed.count == 1 { await withCheckedContinuation { resume = $0 } }
            if choice == .cache(.ruleCache) {
                throw NSError(domain: "StorageQuickCleanupFixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "fixture-rule-cache-failure"])
            }
            if choice == .cache(.temporaryFiles) { return .init(retainedCategories: [.temporaryFiles]) }
            return .init()
        }
        let first = Task { requested += 1; return await service.clearDefaults(tabManager: tabs) }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        XCTAssertTrue(service.isRunning)
        let second = Task { requested += 1; return await service.clearDefaults(tabManager: tabs) }
        let third = Task { requested += 1; return await service.clearDefaults(tabManager: tabs) }
        for _ in 0..<100 where requested < 3 { await Task.yield() }
        XCTAssertEqual(requested, 3)
        // The first action is still suspended, so all three callers overlap.
        XCTAssertEqual(executed.count, 1)
        resume?.resume()
        let firstReport = await first.value
        let secondReport = await second.value
        let thirdReport = await third.value
        XCTAssertEqual(Set(executed), StorageCleanupChoice.safeDefaults)
        XCTAssertEqual(executed.count, StorageCleanupChoice.safeDefaults.count)
        for report in [firstReport, secondReport, thirdReport] {
            XCTAssertTrue(report.retainedCategories.contains(.ruleCache))
            XCTAssertTrue(report.retainedCategories.contains(.temporaryFiles))
            XCTAssertEqual(report.failures.count, 1)
            XCTAssertTrue(report.failures[0].contains("fixture-rule-cache-failure"))
        }
        XCTAssertFalse(service.isRunning)
    }

    func testRealCacheBackendKeepsOldFilesOpenForReadingUntilTheirHandleCloses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-cleanup-fd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var locations = StorageUsageLocations(downloads: root.appendingPathComponent("Downloads"),
            applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        locations.temporary = root.appendingPathComponent("Temporary")
        let oldDate = Date(timeIntervalSinceNow: -600), cutoff = Date(timeIntervalSinceNow: -300)
        for category: StorageUsageCategory in [.temporaryFiles, .otherCaches] {
            let base = category == .temporaryFiles ? locations.temporary! : locations.caches
            let activeDirectory = base.appendingPathComponent("active-viewer")
            try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
            let opened = activeDirectory.appendingPathComponent("currently-reading.bin")
            let nextPart = activeDirectory.appendingPathComponent("next-part.bin")
            let reclaimable = base.appendingPathComponent("reclaimable.bin")
            for file in [opened, nextPart, reclaimable] {
                try Data(repeating: 0x41, count: 4096).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
            }
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: activeDirectory.path)
            let handle = try FileHandle(forReadingFrom: opened)
            do {
                let report = try StorageUsageService.clearAdditionalCache(category, locations: locations, olderThan: cutoff)
                XCTAssertTrue(report.retainedCategories.contains(category))
                XCTAssertTrue(FileManager.default.fileExists(atPath: opened.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: nextPart.path), "An active media/cache directory must stay intact")
                XCTAssertFalse(FileManager.default.fileExists(atPath: reclaimable.path))
            } catch { try? handle.close(); throw error }
            try handle.close()
            _ = try StorageUsageService.clearAdditionalCache(category, locations: locations, olderThan: cutoff)
            XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory.path), "Released old files must become reclaimable")
        }
    }

    func testRealTemporaryBackendKeepsAnActiveBlobLeaseBetweenFileReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-cleanup-lease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var locations = StorageUsageLocations(downloads: root.appendingPathComponent("Downloads"),
            applicationSupport: root.appendingPathComponent("Support"), caches: root.appendingPathComponent("Caches"))
        locations.temporary = root.appendingPathComponent("Temporary")
        let directory = locations.temporary!.appendingPathComponent("blob-worker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leasedFile = directory.appendingPathComponent("response.bin")
        try Data(repeating: 0x42, count: 4096).write(to: leasedFile)
        let oldDate = Date(timeIntervalSinceNow: -600), cutoff = Date(timeIntervalSinceNow: -300)
        for file in [leasedFile, directory] { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path) }
        let protected = try StorageUsageService.clearAdditionalCache(.temporaryFiles, locations: locations,
            olderThan: cutoff, protectedPaths: [leasedFile.path])
        XCTAssertTrue(protected.retainedCategories.contains(.temporaryFiles))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leasedFile.path))
        _ = try StorageUsageService.clearAdditionalCache(.temporaryFiles, locations: locations, olderThan: cutoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
