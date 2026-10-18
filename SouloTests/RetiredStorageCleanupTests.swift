import XCTest
@testable import Soulo

final class RetiredStorageCleanupTests: XCTestCase {
    func testCleanupCancelsTransfersBeforeRemovingOnlyTheRetiredDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("SouloLocalAI/Models/model.gguf")
        let preserved = root.appendingPathComponent("Downloads/article.pdf")
        let otherModels = root.appendingPathComponent("Models/keep.gguf")
        for file in [old, preserved, otherModels] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
        }
        var cancelled = false
        try RetiredStorageCleanup.removeLegacyFiles(in: root, hasPreferences: true) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
            cancelled = true
        }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SouloLocalAI").path))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: otherModels), Data("fixture".utf8))
    }

    func testNoLegacyDataSkipsSessionCreationButPreferencesCancelPendingTransfers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var cancellations = 0
        try RetiredStorageCleanup.removeLegacyFiles(in: root, hasPreferences: false) { cancellations += 1 }
        XCTAssertEqual(cancellations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try RetiredStorageCleanup.removeLegacyFiles(in: root, hasPreferences: true) { cancellations += 1 }
        XCTAssertEqual(cancellations, 1)
    }
}
