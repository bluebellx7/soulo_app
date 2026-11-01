import XCTest
import UIKit
@testable import Soulo

@MainActor
final class ScreenAwakeSettingsTests: XCTestCase {
    private func clearPreference() -> () -> Void {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: VideoScreenAwakeService.preferenceKey)
        defaults.removeObject(forKey: VideoScreenAwakeService.preferenceKey)
        VideoScreenAwakeService.shared.reloadUserPreference()
        return {
            defaults.set(original, forKey: VideoScreenAwakeService.preferenceKey)
            VideoScreenAwakeService.shared.reloadUserPreference()
        }
    }
    private func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: VideoScreenAwakeService.preferenceKey)
        VideoScreenAwakeService.shared.reloadUserPreference()
    }
    func testOffByDefaultAndReloadAppliesAndReleasesTheSavedPreference() {
        let restore = clearPreference(); defer { restore() }
        let initial = UIApplication.shared.isIdleTimerDisabled
        XCTAssertFalse(UserDefaults.standard.bool(forKey: VideoScreenAwakeService.preferenceKey))
        setEnabled(true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        VideoScreenAwakeService.shared.reloadUserPreference()
        setEnabled(false)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, initial)
    }
    func testDisablingPreferenceKeepsVideoPlaybackLeaseUntilThePlayerStops() {
        let restore = clearPreference(); defer { restore() }
        let initial = UIApplication.shared.isIdleTimerDisabled
        let owner = UUID(), service = VideoScreenAwakeService.shared
        defer { service.setActive(false, owner: owner) }
        setEnabled(true)
        service.setActive(true, owner: owner)
        setEnabled(false)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        service.setActive(false, owner: owner)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, initial)
    }
    func testPreferenceReleasesOnInactivityAndReturnsOnActivation() async throws {
        let restore = clearPreference(); defer { restore() }
        let initial = UIApplication.shared.isIdleTimerDisabled
        setEnabled(true)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, initial)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }
}
