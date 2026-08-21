import AVFoundation
import XCTest
@testable import Soulo

@MainActor
final class DownloadManagerServiceTests: XCTestCase {
    func testStreamingMuxCapsDuplicatedTracksToPageDuration() {
        let duration = StreamingMediaDownloadService.constrainedDuration(
            videoDuration: CMTime(seconds: 1_904.13, preferredTimescale: 600),
            audioDuration: CMTime(seconds: 1_904.13, preferredTimescale: 600),
            maximumDurationSeconds: 952.081
        )
        XCTAssertEqual(duration.seconds, 952.081, accuracy: 0.01)
    }

    func testBackgroundDownloadFallsBackOnlyForURLSessionUnknownError() {
        XCTAssertTrue(
            BackgroundDownloadService.shouldUseForegroundFallback(
                for: NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown)
            )
        )
        XCTAssertFalse(
            BackgroundDownloadService.shouldUseForegroundFallback(
                for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            )
        )
        XCTAssertFalse(
            BackgroundDownloadService.shouldUseForegroundFallback(
                for: NSError(domain: "Example", code: NSURLErrorUnknown)
            )
        )
    }
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

    func testBackgroundDownloadStagesCFNetworkFileBeforeDelegateReturns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloBackgroundStageTest-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("CFNetwork", isDirectory: true)
        let stagingDirectory = root.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = sourceDirectory.appendingPathComponent("CFNetworkDownload.tmp")
        let expectedData = Data("downloaded-media".utf8)
        try expectedData.write(to: sourceURL)
        let id = UUID()

        let stagedURL = try BackgroundDownloadService.stageDownloadedFile(
            at: sourceURL,
            id: id,
            directory: stagingDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), expectedData)
        XCTAssertEqual(stagedURL.lastPathComponent, "\(id.uuidString).download")
    }

    func testDownloadLifecyclePersistsFinishedItems() throws {
        let first = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)

        let (item, fileURL) = first.beginDownload(
            suggestedFilename: "bad/name?.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )
        try Data("pdf".utf8).write(to: fileURL)
        first.markFinished(id: item.id)

        XCTAssertEqual(first.finishedDownload(for: URL(string: "https://example.com/report.pdf")!)?.id, item.id)

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

    func testActiveDownloadLookupAndFailedRetryCleanupUseStableSourceURL() throws {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let sourceURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=fixture"))
        let active = service.beginDownload(
            suggestedFilename: "Fixture.mp4",
            sourceURL: sourceURL,
            transport: .streaming
        ).0

        XCTAssertEqual(service.activeDownload(for: sourceURL)?.id, active.id)

        service.markFailed(id: active.id, error: NSError(domain: "test", code: 1))
        let retry = service.beginDownload(
            suggestedFilename: "Fixture.mp4",
            sourceURL: sourceURL,
            transport: .streaming
        ).0
        service.markFailed(id: retry.id, error: NSError(domain: "test", code: 2))

        XCTAssertEqual(service.downloads.filter { $0.status == .failed }.count, 2)
        service.removeFailedDownloads(for: sourceURL)
        XCTAssertFalse(service.downloads.contains { $0.sourceURLString == sourceURL.absoluteString })
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

    func testInterruptedStreamingDownloadIsCanceledButHLSRemainsAttachable() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let streaming = service.beginDownload(
            suggestedFilename: "stream.mp4",
            sourceURL: URL(string: "https://example.com/stream"),
            transport: .streaming
        ).0
        let hls = service.beginDownload(
            suggestedFilename: "hls.mp4",
            sourceURL: URL(string: "https://example.com/master.m3u8"),
            transport: .hls
        ).0

        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertEqual(restored.downloads.first(where: { $0.id == streaming.id })?.status, .canceled)
        XCTAssertEqual(restored.downloads.first(where: { $0.id == hls.id })?.status, .inProgress)
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

    func testInProgressDownloadCanBeCanceledAndDeleted() {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = service.beginDownload(
            suggestedFilename: "Report.pdf",
            sourceURL: URL(string: "https://example.com/report.pdf")
        )

        service.delete(item)

        XCTAssertNil(service.downloads.first(where: { $0.id == item.id }))
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

    func testProgressPauseAndResumeStateArePersisted() throws {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = service.beginDownload(
            suggestedFilename: "Archive.zip",
            sourceURL: URL(string: "https://example.com/archive.zip"),
            transport: .background
        )

        service.updateProgress(id: item.id, completed: 256, total: 1024)
        var updated = try XCTUnwrap(service.downloads.first(where: { $0.id == item.id }))
        XCTAssertEqual(updated.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(updated.receivedBytes, 256)
        XCTAssertEqual(updated.expectedBytes, 1024)
        XCTAssertEqual(updated.transport, .background)

        let resumeData = Data("resume".utf8)
        service.markPaused(id: item.id, resumeData: resumeData)
        updated = try XCTUnwrap(service.downloads.first(where: { $0.id == item.id }))
        XCTAssertEqual(updated.status, .paused)
        XCTAssertEqual(service.resumeData(id: item.id), resumeData)

        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertEqual(restored.downloads.first(where: { $0.id == item.id })?.status, .paused)
        restored.delete(updated)
        XCTAssertNil(restored.resumeData(id: item.id))
    }

    func testMissingResumeDataDoesNotCreateAnUnresumablePausedDownload() throws {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = service.beginDownload(
            suggestedFilename: "Archive.zip",
            sourceURL: URL(string: "https://example.com/archive.zip"),
            transport: .background
        )

        service.markPaused(id: item.id, resumeData: nil)

        let updated = try XCTUnwrap(service.downloads.first(where: { $0.id == item.id }))
        XCTAssertEqual(updated.status, .inProgress)
        XCTAssertNil(service.resumeData(id: item.id))
    }

    func testStreamingDownloadCanPauseResumeAndDelete() throws {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, fileURL) = service.beginDownload(
            suggestedFilename: "Video.mp4",
            sourceURL: URL(string: "https://example.com/video.mp4"),
            transport: .streaming
        )
        try Data("partial-video".utf8).write(to: fileURL)
        service.updateProgress(id: item.id, completed: 300, total: 1_000)

        service.markPaused(id: item.id)
        var updated = try XCTUnwrap(service.downloads.first(where: { $0.id == item.id }))
        XCTAssertEqual(updated.status, .paused)
        XCTAssertEqual(updated.progress, 0.3, accuracy: 0.001)

        service.markResumed(id: item.id)
        updated = try XCTUnwrap(service.downloads.first(where: { $0.id == item.id }))
        XCTAssertEqual(updated.status, .inProgress)

        service.markPaused(id: item.id)
        service.delete(updated)
        XCTAssertNil(service.downloads.first(where: { $0.id == item.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testClearFinishedPreservesPausedDownloads() throws {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (paused, _) = service.beginDownload(
            suggestedFilename: "Paused.mp4",
            sourceURL: URL(string: "https://example.com/paused.mp4"),
            transport: .hls
        )
        service.markPaused(id: paused.id)
        let (finished, finishedURL) = service.beginDownload(
            suggestedFilename: "Finished.pdf",
            sourceURL: URL(string: "https://example.com/finished.pdf")
        )
        try Data("finished".utf8).write(to: finishedURL)
        service.markFinished(id: finished.id)

        service.clearFinished()

        XCTAssertEqual(service.downloads.map(\.id), [paused.id])
        XCTAssertEqual(service.downloads.first?.status, .paused)
    }

    func testInterruptedPausedStreamingDownloadIsCanceledAfterRelaunch() throws {
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, fileURL) = service.beginDownload(
            suggestedFilename: "Streaming.mp4",
            sourceURL: URL(string: "https://example.com/streaming.mp4"),
            transport: .streaming
        )
        try Data("partial".utf8).write(to: fileURL)
        service.markPaused(id: item.id)

        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)

        XCTAssertEqual(restored.downloads.first(where: { $0.id == item.id })?.status, .canceled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testBackgroundDownloadSurvivesReloadAndOrphansAreReconciled() throws {
        let first = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = first.beginDownload(
            suggestedFilename: "Video.mp4",
            sourceURL: URL(string: "https://example.com/video.mp4"),
            transport: .background
        )

        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertEqual(restored.downloads.first(where: { $0.id == item.id })?.status, .inProgress)

        restored.reconcileBackgroundDownloads(
            activeIDs: [],
            now: item.startedAt.addingTimeInterval(10)
        )
        XCTAssertEqual(restored.downloads.first(where: { $0.id == item.id })?.status, .failed)
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
