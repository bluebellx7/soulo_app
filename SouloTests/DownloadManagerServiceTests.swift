import XCTest
@testable import Soulo

@MainActor
final class DownloadManagerServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "DownloadManagerServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        directory = nil
        super.tearDown()
    }

    func testDownloadLifecyclePersistsFinishedItems() throws {
        let first = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)

        let (item, fileURL) = first.beginDownload(
            suggestedFilename: "bad/name?.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )
        try Data("pdf".utf8).write(to: fileURL)
        first.markFinished(id: item.id)

        let second = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let persisted = try XCTUnwrap(second.downloads.first)

        XCTAssertEqual(persisted.status, .finished)
        XCTAssertEqual(persisted.sourceURLString, "https://example.com/report.pdf")
        XCTAssertFalse(persisted.fileName.contains("/"))
        XCTAssertFalse(persisted.fileName.contains("?"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.localPath))
    }

    func testUniqueFilenameAvoidsExistingFiles() throws {
        try Data().write(to: directory.appendingPathComponent("Report.pdf"))
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)

        let (item, fileURL) = service.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )

        XCTAssertEqual(item.fileName, "Report 1.pdf")
        XCTAssertEqual(fileURL.lastPathComponent, "Report 1.pdf")
    }

    func testConcurrentDownloadsReserveDifferentFilenamesBeforeFilesExist() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let first = service.beginDownload(
            suggestedFilename: "report.pdf",
            sourceURL: URL(string: "https://example.com/first")
        ).0
        let second = service.beginDownload(
            suggestedFilename: "report.pdf",
            sourceURL: URL(string: "https://example.com/second")
        ).0

        XCTAssertEqual(first.fileName, "report.pdf")
        XCTAssertEqual(second.fileName, "report 1.pdf")
    }

    func testCancelAllDownloadsMarksInProgressItemsCanceled() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, fileURL) = service.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )
        try? Data("partial".utf8).write(to: fileURL)

        service.cancelAllDownloads()

        XCTAssertEqual(service.downloads.first(where: { $0.id == item.id })?.status, .canceled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCanceledDownloadCannotLaterBecomeFinished() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = service.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )

        service.markCanceled(id: item.id)
        service.markFinished(id: item.id)

        XCTAssertEqual(service.downloads.first(where: { $0.id == item.id })?.status, .canceled)
    }

    func testFailedDownloadRemovesPartialFile() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, fileURL) = service.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )
        try? Data("partial".utf8).write(to: fileURL)

        service.markFailed(
            id: item.id,
            error: NSError(domain: "test", code: 1)
        )

        XCTAssertEqual(service.downloads.first(where: { $0.id == item.id })?.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testInProgressDownloadCannotBeDeletedWithoutCancellation() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = service.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )

        service.delete(item)

        XCTAssertNotNil(service.downloads.first(where: { $0.id == item.id }))
    }

    func testStaleInProgressDownloadIsCanceledWhenManagerReloads() {
        let first = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = first.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )

        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)

        XCTAssertEqual(restored.downloads.first(where: { $0.id == item.id })?.status, .canceled)
    }
}
