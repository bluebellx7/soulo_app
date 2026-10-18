import XCTest
@testable import Soulo

final class LocalAIFileOrganizerTests: XCTestCase {
    @MainActor func testOrganizedBooksAndDownloadsKeepTheirIdentityTitleAndReadingProgress() async throws {
        let root = BookLibrary.directory, prefix = "Soulo-AI-Files-" + UUID().uuidString
        let first = root.appendingPathComponent(prefix + "-a.txt"), second = root.appendingPathComponent(prefix + "-b.txt")
        let folder = root.appendingPathComponent(prefix, isDirectory: true)
        let metadata = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + ".json")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: prefix))
        defer {
            for url in [first, second, folder, metadata] { try? FileManager.default.removeItem(at: url) }
            defaults.removePersistentDomain(forName: prefix)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = DownloadManagerService(userDefaults: defaults, storageKey: "downloads", storageDirectory: root)
        for source in [first, second] {
            let (item, destination) = manager.beginDownload(suggestedFilename: source.lastPathComponent, sourceURL: URL(string: "https://example.com/book")!)
            try Data((source.lastPathComponent + "\nChapter 1. Reading material.").utf8).write(to: destination)
            manager.markFinished(id: item.id)
        }
        let library = BookLibrary(metadata: metadata)
        let a = try await library.add(first), b = try await library.add(second)
        library.updateTitle(a.id, title: "My chosen title")
        library.update(a.id, location: "chapter:1:42", fraction: 0.42)
        let moves = try [first, second].map { source -> LocalAIFileMove in
            let info = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LocalAIFileMove(source: source, destination: folder.appendingPathComponent(source.lastPathComponent), bytes: info.fileSize ?? 0, modified: info.contentModificationDate)
        }
        try LocalAIFileOrganizer.commit(moves, in: root)
        try library.updateFileReferences([(bookIDs: [a.id], url: moves[0].destination), (bookIDs: [b.id], url: moves[1].destination)])
        manager.updateFileReferences(moves.map { (from: $0.source, to: $0.destination) })
        let restored = try XCTUnwrap(BookLibrary(metadata: metadata).books.first(where: { $0.id == a.id }))
        XCTAssertEqual(restored.url.standardizedFileURL, moves[0].destination.standardizedFileURL)
        XCTAssertEqual(restored.name, "My chosen title"); XCTAssertEqual(restored.location, "chapter:1:42"); XCTAssertEqual(restored.fraction, 0.42)
        let downloads = DownloadManagerService(userDefaults: defaults, storageKey: "downloads", storageDirectory: root).downloads
        XCTAssertEqual(downloads.count, 2)
        XCTAssertTrue(downloads.allSatisfy { $0.localURL.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL })
        try LocalAIFileOrganizer.commit(moves, in: root, reverse: true)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testOrganizingMovesOnlyFinishedRegularFilesAndCanUndo() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["photo.png", "paper.pdf", "waiting.download", ".hidden"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let plan = try LocalAIFileOrganizer.plan(in: root)
        XCTAssertEqual(plan.count, 2)
        try LocalAIFileOrganizer.commit(plan, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Images/photo.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("PDF/paper.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("waiting.download").path))
        try LocalAIFileOrganizer.commit(plan, in: root, reverse: true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.png")), Data("photo.png".utf8))
    }
    func testChangedFileInvalidatesTheEntireReviewedPlan() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.png", "b.pdf"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let plan = try LocalAIFileOrganizer.plan(in: root)
        try Data("Changed after review".utf8).write(to: root.appendingPathComponent("b.pdf"))
        XCTAssertThrowsError(try LocalAIFileOrganizer.commit(plan, in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.png").path))
    }
    func testOrganizerDoesNotFollowSymbolicLinksOrOverwriteFiles() throws {
        let root = try directory(), outside = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("PDF"), withDestinationURL: outside)
        try Data("own".utf8).write(to: root.appendingPathComponent("file.pdf"))
        XCTAssertTrue(try LocalAIFileOrganizer.plan(in: root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret.png")), Data("outside".utf8))
    }
}
