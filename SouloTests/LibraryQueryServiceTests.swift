import XCTest
@testable import Soulo

final class LibraryQueryServiceTests: XCTestCase {
    func testDownloadQueriesCombineStatusTypeAndDecodedSearchWithoutTouchingFiles() throws {
        func item(_ name: String, _ status: BrowserDownloadStatus, _ date: Double, _ bytes: Int64, source: String = "") -> BrowserDownloadItem {
            BrowserDownloadItem(id: UUID(), fileName: name, sourceURLString: source, localPath: "/nonexistent/" + name,
                startedAt: Date(timeIntervalSince1970: date), completedAt: nil, status: status, errorMessage: "", expectedBytes: bytes)
        }
        let first = item("Episode 2.mp4", .finished, 20, 200, source: "https://example.com/%E4%B8%AD%E6%96%87")
        let second = item("Episode 10.mp4", .inProgress, 30, 100)
        let audio = item("Episode.mp3", .paused, 10, 500)
        let failed = item("Report.pdf", .failed, 40, 300)
        let items = [failed, second, audio, first]
        XCTAssertEqual(DownloadListQuery.apply(items, search: "ÉPISODE 中文", status: .completed, kind: .videos).map(\.id), [first.id])
        XCTAssertEqual(DownloadListQuery.apply(items, status: .active, sort: .sizeLargest).map(\.id), [audio.id, second.id])
        XCTAssertEqual(DownloadListQuery.apply(items, kind: .videos, sort: .nameAscending).map(\.id), [first.id, second.id])
        XCTAssertEqual(DownloadListQuery.apply(items, kind: .documents).map(\.id), [failed.id])
        XCTAssertEqual(DownloadListQuery.apply(items, status: .failed).map(\.id), [failed.id])
        XCTAssertEqual(DownloadListQuery.apply(items, sort: .sizeLargest, sizes: [second.id: 900]).first?.id, second.id)
        let detected = item("unknown-file", .finished, 50, 1)
        XCTAssertEqual(DownloadListQuery.apply([detected], kind: .images, kinds: [detected.id: .image]).map(\.id), [detected.id])
    }

    func testFileQueriesKeepDirectoriesFirstAndUseActualPreparedKindsAndSizes() {
        struct Entry {
            let url: URL
            let info: FilePresentation
            let modifiedAt: Date
        }
        func entry(_ name: String, _ kind: FilePresentation.Kind, _ size: Int64, _ date: Double) -> Entry {
            Entry(url: URL(fileURLWithPath: "/nonexistent/" + name), info: FilePresentation(kind: kind, fileExtension: "", size: size),
                  modifiedAt: Date(timeIntervalSince1970: date))
        }
        let folder = entry("Folder", .folder, 0, 1), two = entry("Track 2", .audio, 200, 20)
        let ten = entry("Track 10", .audio, 100, 30), pdf = entry("manual.bin", .pdf, 400, 10)
        let values = [ten, pdf, two, folder]
        func query(_ kind: LibraryFileFilter = .all, sort: LibraryListSort = .nameAscending, search: String = "") -> [String] {
            LibraryFileQuery.apply(values, search: search, kind: kind, sort: sort, url: { $0.url }, presentation: { $0.info }, modifiedAt: { $0.modifiedAt })
                .map { $0.url.lastPathComponent }
        }
        XCTAssertEqual(query(), ["Folder", "manual.bin", "Track 2", "Track 10"])
        XCTAssertEqual(query(.audio, sort: .newest), ["Track 10", "Track 2"])
        XCTAssertEqual(query(.documents), ["manual.bin"])
        XCTAssertEqual(query(.all, sort: .sizeLargest), ["Folder", "manual.bin", "Track 2", "Track 10"])
        XCTAssertEqual(query(search: "track 10"), ["Track 10"])
    }

    func testFileMoveRejectsSourceOutsideTheOwnedRootWithoutMovingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("move-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned"), external = root.appendingPathComponent("external")
        let target = owned.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let original = external.appendingPathComponent("keep.txt"), bytes = Data("owned by external provider".utf8)
        try bytes.write(to: original)
        XCTAssertThrowsError(try LibraryFileActions.move([original], from: external, to: target, root: owned))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
    }
}
