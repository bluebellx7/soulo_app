import XCTest
@testable import Soulo

final class StorageUsageServiceTests: XCTestCase {
    private var root: URL!
    private var locations: StorageUsageLocations!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-" + UUID().uuidString)
        locations = StorageUsageLocations(downloads: root.appendingPathComponent("Documents/Downloads"),
            applicationSupport: root.appendingPathComponent("ApplicationSupport"), caches: root.appendingPathComponent("Caches"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        locations = nil
    }

    @discardableResult
    private func write(_ name: String, under base: URL) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8192).write(to: url)
        return url
    }

    func testDiskCategoriesIncludeReadingListAndKeepUserDataReadOnly() throws {
        try write("movie.mp4", under: locations.downloads)
        try write("SouloTabSnapshots/page.jpg", under: locations.applicationSupport)
        try write("wallpaper_hd/nature.jpg", under: locations.caches)
        try write("ReadingList.json", under: locations.applicationSupport)
        try write("Soulo/SettingsBackups/saved.json", under: locations.applicationSupport)
        try write("AdBlock/subscription-rules.json", under: locations.applicationSupport)
        let records = StorageUsageService.measureDiskUsage(locations: locations)
        for category: StorageUsageCategory in [.downloads, .tabSnapshots, .wallpapers, .readingData, .backups, .filterRules] {
            let record = try XCTUnwrap(records.first { $0.category == category })
            XCTAssertGreaterThan(record.bytes, 0, category.rawValue)
            XCTAssertFalse(record.isEstimated)
        }
        XCTAssertEqual(StorageUsageCategory.allCases.filter(\.canClear), [.webData, .tabSnapshots, .favicons])
        for category: StorageUsageCategory in [.wallpapers, .downloads, .readingData, .backups, .filterRules] {
            XCTAssertThrowsError(try StorageUsageService.clearDiskCache(category, locations: locations))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.downloads.appendingPathComponent("movie.mp4").path))
    }

    func testClearingNamedCachesPreservesCurrentWallpaperAndAllSavedContent() throws {
        let hd = try write("wallpaper_hd/nature.jpg", under: locations.caches)
        let favorite = try write("WallpaperFavorites/other.jpg", under: locations.applicationSupport)
        let snapshot = try write("SouloTabSnapshots/page.jpg", under: locations.applicationSupport)
        let legacySnapshot = try write("SouloTabSnapshots/old.jpg", under: locations.caches)
        let retained = try [write("CurrentWallpaper/selected.jpg", under: locations.caches),
            write("custom_wallpaper.jpg", under: root.appendingPathComponent("Documents")),
            write("keep.mp3", under: locations.downloads),
            write("ReadingList.json", under: locations.applicationSupport),
            write("BookCovers/cover.jpg", under: locations.applicationSupport),
            write("Soulo/SettingsBackups/keep.json", under: locations.applicationSupport),
            write("AdBlock/merged-rules.json", under: locations.applicationSupport)]
        XCTAssertThrowsError(try StorageUsageService.clearDiskCache(.wallpapers, locations: locations))
        XCTAssertEqual(try Data(contentsOf: hd), Data(repeating: 0xAB, count: 8192))
        XCTAssertEqual(try Data(contentsOf: favorite), Data(repeating: 0xAB, count: 8192))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        try StorageUsageService.clearDiskCache(.tabSnapshots, locations: locations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySnapshot.path))
        for url in retained { XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 0xAB, count: 8192), url.path) }
    }

    func testFavoriteWallpaperMigrationDoesNotCountTheSameOriginalTwice() throws {
        let original = try write("wallpaper_hd/nature.jpg", under: locations.caches)
        let before = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .wallpapers })
        let saved = locations.applicationSupport.appendingPathComponent("WallpaperFavorites/nature.jpg")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: saved)
        let after = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .wallpapers })
        XCTAssertEqual(after.bytes, before.bytes)
        XCTAssertFalse(after.canClear)
    }

    func testMeasurementAndClearDoNotFollowCacheRootSymlinks() throws {
        let external = root.appendingPathComponent("external")
        let retained = try write("keep.jpg", under: external)
        try FileManager.default.createDirectory(at: locations.caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: locations.caches.appendingPathComponent("wallpaper_hd"), withDestinationURL: external)
        let record = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .wallpapers })
        XCTAssertEqual(record.bytes, 0)
        XCTAssertThrowsError(try StorageUsageService.clearDiskCache(.wallpapers, locations: locations))
        XCTAssertEqual(try Data(contentsOf: retained), Data(repeating: 0xAB, count: 8192))
    }

    func testOfflineHLSReferencesIncludeThePackageOnlyOnce() throws {
        let packageRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/StorageHLS-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        let package = packageRoot.appendingPathComponent("movie.movpkg")
        try write("segment.ts", under: package)
        try FileManager.default.createDirectory(at: locations.downloads, withIntermediateDirectories: true)
        let first = locations.downloads.appendingPathComponent("one.soulohls")
        try OfflineHLSReference.write(packageURL: package, to: first)
        let before = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .downloads }).bytes
        let second = locations.downloads.appendingPathComponent("two.soulohls")
        try OfflineHLSReference.write(packageURL: package, to: second)
        let after = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .downloads }).bytes
        let size = try second.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        XCTAssertGreaterThan(before, 8192)
        XCTAssertEqual(after - before, Int64(size.totalFileAllocatedSize ?? size.fileAllocatedSize ?? size.fileSize ?? 0))
    }
}
