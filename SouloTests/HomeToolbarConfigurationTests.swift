import XCTest
@testable import Soulo

@MainActor
final class HomeToolbarConfigurationTests: XCTestCase {
    func testHiddenByDefaultAndFourSlotsPersistAcrossReload() {
        let name = "HomeToolbarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = HomeToolbarConfigurationService(defaults: defaults)
        XCTAssertFalse(service.isVisible)
        XCTAssertEqual(service.actions, Array(repeating: .none, count: 4))
        service.save([.downloads, .files, .bookmarks, .history])
        let restored = HomeToolbarConfigurationService(defaults: defaults)
        XCTAssertTrue(restored.isVisible)
        XCTAssertEqual(restored.actions, [.downloads, .files, .bookmarks, .history])
        restored.save([])
        XCTAssertFalse(HomeToolbarConfigurationService(defaults: defaults).isVisible)
    }
    func testUnknownSavedActionsLeaveTheirSlotsEmptyWithoutMovingOthers() {
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "future-action", "wallpaper", "files", "settings"]),
                       [.downloads, .none, .wallpaper, .files])
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["history"]), [.history, .none, .none, .none])
    }
    func testEveryActionHasALocalizedLabelAndSymbol() {
        for action in HomeToolbarAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: action.symbol), action.rawValue)
            XCTAssertFalse(action.title.contains("_"), "Unresolved localization key: " + action.rawValue)
        }
    }
}

final class LibraryScrollCollapseTests: XCTestCase {
    @MainActor
    func testActivePageObservesVerticalScrollAndDisconnectsWhenInactive() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController(); window.rootViewController = controller
        let parent = UIView(frame: window.bounds)
        controller.view.addSubview(parent)
        let scroll = UIScrollView(frame: parent.bounds)
        scroll.contentSize = CGSize(width: 390, height: 1800)
        parent.addSubview(scroll)
        let marker = LibraryScrollCollapseObserver.Host(frame: parent.bounds)
        marker.active = true
        var offsets: [CGFloat] = []
        marker.onOffset = { offsets.append($0) }
        parent.addSubview(marker)
        window.makeKeyAndVisible()
        marker.setNeedsLayout(); marker.layoutIfNeeded()
        scroll.contentOffset.y = 120
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(offsets.last, 120)
        marker.active = false; marker.disconnect()
        let count = offsets.count
        scroll.contentOffset.y = 0
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(offsets.count, count)
        window.isHidden = true
    }
}
