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

    func testFilenameSanitizerRemovesUnsafeCharactersAndLimitsLength() {
        let unsafeName = String(repeating: "超长图片名称", count: 60)
            + "/\\:*?\"<>|😀%23.jpeg"

        let sanitized = DownloadFilenameSanitizer.sanitize(
            unsafeName,
            fallbackBaseName: "Image"
        )

        XCTAssertLessThanOrEqual(
            sanitized.utf8.count,
            DownloadFilenameSanitizer.maximumUTF8ByteCount
        )
        XCTAssertTrue(sanitized.hasSuffix(".jpeg"))
        ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "😀", "#"].forEach {
            XCTAssertFalse(sanitized.contains($0))
        }
    }

    func testFilenameSanitizerUsesImageFallbackAndPreferredExtension() {
        XCTAssertEqual(
            DownloadFilenameSanitizer.sanitize(
                "////",
                fallbackBaseName: "Image",
                preferredExtension: "PNG"
            ),
            "Image.png"
        )
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

    func testSharedDownloadLocationUsesDocumentsDownloadsFolder() {
        XCTAssertEqual(DownloadManagerService.downloadsDirectory.lastPathComponent, "Downloads")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool,
            true
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool,
            true
        )
    }

    func testWebResourceCookiesRespectDomainPathSecureAndExpiration() throws {
        let now = Date()
        let cookies = [
            try makeCookie(name: "domain", domain: ".example.com", path: "/account", secure: true),
            try makeCookie(name: "hostOnly", domain: "example.com", path: "/"),
            try makeCookie(name: "wrongPath", domain: ".example.com", path: "/private"),
            try makeCookie(
                name: "expired",
                domain: ".example.com",
                path: "/account",
                expires: now.addingTimeInterval(-60)
            )
        ]

        let secureURL = try XCTUnwrap(URL(string: "https://sub.example.com/account/profile"))
        XCTAssertEqual(
            WebResourceDownloadService.matchingCookies(from: cookies, for: secureURL, now: now).map(\.name),
            ["domain"]
        )

        let insecureURL = try XCTUnwrap(URL(string: "http://sub.example.com/account/profile"))
        XCTAssertTrue(
            WebResourceDownloadService.matchingCookies(from: cookies, for: insecureURL, now: now).isEmpty
        )

        let pathBoundaryURL = try XCTUnwrap(URL(string: "https://sub.example.com/accounting"))
        XCTAssertTrue(
            WebResourceDownloadService.matchingCookies(from: cookies, for: pathBoundaryURL, now: now).isEmpty
        )
    }

    func testWebResourceReferrerUsesStrictOriginBehavior() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/private?q=secret"))
        let sameOrigin = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
        let crossOrigin = try XCTUnwrap(URL(string: "https://cdn.example.net/image.jpg"))
        let downgrade = try XCTUnwrap(URL(string: "http://cdn.example.net/image.jpg"))

        XCTAssertEqual(
            WebResourceDownloadService.referrerHeader(pageURL: pageURL, resourceURL: sameOrigin),
            pageURL.absoluteString
        )
        XCTAssertEqual(
            WebResourceDownloadService.referrerHeader(pageURL: pageURL, resourceURL: crossOrigin),
            "https://example.com/"
        )
        XCTAssertNil(
            WebResourceDownloadService.referrerHeader(pageURL: pageURL, resourceURL: downgrade)
        )
    }

    private func makeCookie(
        name: String,
        domain: String,
        path: String,
        secure: Bool = false,
        expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "value",
            .domain: domain,
            .path: path
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if let expires {
            properties[.expires] = expires
        }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}
