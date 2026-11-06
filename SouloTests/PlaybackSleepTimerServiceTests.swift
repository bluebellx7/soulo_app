import XCTest
@testable import Soulo

@MainActor
final class PlaybackSleepTimerServiceTests: XCTestCase {
    func testElapsedDeadlinePausesOnceIncludingAfterForegroundRefresh() {
        var date = Date(timeIntervalSince1970: 1_000), pauses = 0
        let timer = PlaybackSleepTimerService(pause: { pauses += 1 }, now: { date })
        XCTAssertTrue(timer.start(after: 60))
        XCTAssertEqual(timer.remainingTime, 60)
        date = date.addingTimeInterval(20)
        XCTAssertFalse(timer.playbackEnded(), "Advancing the queue must retain a normal deadline")
        XCTAssertEqual(timer.remainingTime, 40)
        date = date.addingTimeInterval(100)
        timer.refresh()
        XCTAssertEqual(pauses, 1)
        XCTAssertFalse(timer.isActive)
        timer.refresh()
        XCTAssertFalse(timer.playbackEnded())
        XCTAssertEqual(pauses, 1)
    }

    func testAfterCurrentItemConsumesTheTimerBeforeAutomaticNextAndCanBeCancelled() {
        var pauses = 0
        let timer = PlaybackSleepTimerService(pause: { pauses += 1 })
        timer.stopAfterCurrentItem()
        XCTAssertTrue(timer.stopsAfterCurrentItem)
        XCTAssertTrue(timer.playbackEnded())
        XCTAssertEqual(pauses, 1)
        XCTAssertFalse(timer.playbackEnded())
        timer.stopAfterCurrentItem()
        timer.cancel()
        XCTAssertFalse(timer.playbackEnded())
        XCTAssertEqual(pauses, 1)
    }

    func testInvalidOrReplacedTimerCannotPauseTheLaterSession() async throws {
        var pauses = 0
        let timer = PlaybackSleepTimerService(pause: { pauses += 1 })
        XCTAssertTrue(timer.start(after: 0.05))
        let first = timer.deadline
        for invalid in [0, -1, Double.nan, Double.infinity, PlaybackSleepTimerService.maximumInterval + 1] {
            XCTAssertFalse(timer.start(after: invalid))
            XCTAssertEqual(timer.deadline, first)
        }
        timer.stopAfterCurrentItem()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pauses, 0, "The replaced deadline must not pause the current item")
        XCTAssertTrue(timer.playbackEnded())
        XCTAssertEqual(pauses, 1)
    }

    func testScheduledTimerActuallyFiresAndClearsItsState() async throws {
        let paused = expectation(description: "Sleep timer pauses playback")
        var pauses = 0
        let timer = PlaybackSleepTimerService(pause: { pauses += 1; paused.fulfill() })
        XCTAssertTrue(timer.start(after: 0.03))
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertEqual(pauses, 1)
        XCTAssertNil(timer.deadline)
        XCTAssertFalse(timer.isActive)
    }
}
