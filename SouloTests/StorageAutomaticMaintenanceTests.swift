import Foundation
import XCTest
@testable import Soulo

final class StorageAutomaticMaintenanceTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func directory(_ prefix: String) throws -> URL {
        let directory = root.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try age(directory)
        return directory
    }
    private func file(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: 8).write(to: file)
        try age(file)
        return file
    }
    private func age(_ url: URL) throws {
        let old = now.addingTimeInterval(-172_800)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: url.path)
    }
    private var options: StorageAutomaticMaintenanceScan.Options {
        .init(now: now, sessionStartedAt: now.addingTimeInterval(-3_600), maximumDuration: 30)
    }

    func testOnlyExpiredOwnedArtifactsAreRemovedAndProtectedFilesRemain() throws {
        let owned = try directory("extension-cache-")
        let discarded = try file("cache.html", in: owned)
        let leasedDirectory = try directory("WallpaperExport-")
        let leased = try file("leased.bin", in: leasedDirectory)
        let database = try file("storage.sqlite3", in: owned)
        let currentWrite = try file("current.bin", in: owned)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: currentWrite.path)
        let unknown = try directory("unknown-")
        let keep = try file("keep.mp4", in: unknown)
        let host = try directory("extension-script-host-")
        let hostDatabase = try file("extension.sqlite3", in: host)
        let managed = try directory("com.apple.UserManagedAssets.")
        let movie = try file("movie.frag", in: managed)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-maintenance-" + UUID().uuidString)
        try Data([1]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("external"), withDestinationURL: outside)
        var config = options
        config.protectedPaths = [StorageAutomaticMaintenanceScan.path(leased)]
        let result = StorageAutomaticMaintenanceScan.run(in: root, options: config)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
        for kept in [leased, database, currentWrite, keep, hostDatabase, movie, outside] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
    }

    func testCurrentSessionCopiesAndOpenDescriptorsAreKept() throws {
        let current = try directory("WallpaperExport-")
        let copied = try file("copied-old-date.jpg", in: current)
        try FileManager.default.setAttributes([.creationDate: now], ofItemAtPath: current.path)
        let old = try directory("SouloPreview-")
        let playing = try file("old-preview.mp4", in: old)
        let handle = try FileHandle(forReadingFrom: playing)
        let result = StorageAutomaticMaintenanceScan.run(in: root, options: options)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.removedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: playing.path))
        try handle.close()
        let released = StorageAutomaticMaintenanceScan.run(in: root, options: options)
        XCTAssertEqual(released.removedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: playing.path))
    }

    func testEntryBudgetLeavesAResumableDirectoryAndCancellationDoesNoWork() throws {
        let owned = try directory("SouloPhotoImport-")
        for index in 0..<8 { _ = try file("\(index).jpg", in: owned) }
        var config = options
        config.maximumEntries = 4
        let partial = StorageAutomaticMaintenanceScan.run(in: root, options: config)
        XCTAssertFalse(partial.completed)
        XCTAssertLessThanOrEqual(partial.inspectedEntries, 4)
        XCTAssertEqual(partial.pendingDirectory, owned.lastPathComponent)
        let cancelled = StorageAutomaticMaintenanceScan.run(in: root, options: options, cancelled: { true })
        XCTAssertFalse(cancelled.completed)
        XCTAssertEqual(cancelled.removedFiles, 0)
        config = options
        config.pendingDirectory = partial.pendingDirectory
        let resumed = StorageAutomaticMaintenanceScan.run(in: root, options: config)
        XCTAssertTrue(resumed.completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    func testTimeBudgetStopsBeforeDeletingAndSymlinkRootsAreRejected() throws {
        let owned = try directory("soulo-import-")
        let file = try file("staged.pdf", in: owned)
        var config = options
        config.maximumDuration = 0
        let elapsed = StorageAutomaticMaintenanceScan.run(in: root, options: config)
        XCTAssertFalse(elapsed.completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let alias = root.deletingLastPathComponent().appendingPathComponent("maintenance-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertFalse(StorageAutomaticMaintenanceScan.run(in: alias, options: options).completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
