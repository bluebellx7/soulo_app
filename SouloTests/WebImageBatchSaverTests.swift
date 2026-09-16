import XCTest
@testable import Soulo

@MainActor
final class WebImageBatchSaverTests: XCTestCase {
    private func image(_ name: String) -> WebImageResource {
        WebImageResource(url: URL(string: "https://example.com/\(name).png")!, width: 300, height: 300, title: name)
    }

    func testDeduplicatesAndContinuesAfterFailureWithoutParallelImports() async {
        let saver = WebImageBatchSaver()
        let first = image("first"), bad = image("bad"), last = image("last")
        var calls: [String] = []
        var active = 0
        let finished = expectation(description: "batch finished")
        saver.start(images: [first, first, bad, last]) { item in
            active += 1
            XCTAssertEqual(active, 1)
            defer { active -= 1 }
            calls.append(item.id)
            await Task.yield()
            if item.id == bad.id { throw WebResourceDownloadError.invalidResponse }
        } completion: { result in
            XCTAssertEqual(result.savedIDs, [first.id, last.id])
            XCTAssertEqual(result.failedIDs, [bad.id])
            XCTAssertEqual(saver.completed, 3)
            XCTAssertEqual(saver.total, 3)
            XCTAssertFalse(saver.isSaving)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(calls, [first.id, bad.id, last.id])
    }

    func testPermissionDenialStopsRemainingRequests() async {
        let saver = WebImageBatchSaver()
        var calls = 0
        let finished = expectation(description: "denied")
        saver.start(images: [image("one"), image("two")]) { _ in
            calls += 1
            throw WebResourceDownloadError.photoAccessDenied
        } completion: { result in
            XCTAssertTrue(result.permissionDenied)
            XCTAssertTrue(result.savedIDs.isEmpty)
            XCTAssertEqual(result.failedIDs.count, 1)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(calls, 1)
    }

    func testCancellationKeepsCompletedImportsAndSkipsRemainingImages() async {
        let saver = WebImageBatchSaver()
        let first = image("first")
        let finished = expectation(description: "cancelled")
        saver.start(images: [first, image("later")]) { _ in
            // Simulate cancellation while PhotoKit commits the current photo.
            saver.cancel()
        } completion: { result in
            XCTAssertEqual(result.savedIDs, [first.id])
            XCTAssertTrue(result.wasCancelled)
            XCTAssertTrue(result.failedIDs.isEmpty)
            XCTAssertEqual(saver.completed, 1)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
    }
}
