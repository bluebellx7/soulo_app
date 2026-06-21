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

        XCTAssertEqual(item.fileName, "Report 2.pdf")
        XCTAssertEqual(fileURL.lastPathComponent, "Report 2.pdf")
    }
}
