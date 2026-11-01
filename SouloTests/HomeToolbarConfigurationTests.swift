import XCTest
@testable import Soulo

@MainActor
final class HomeToolbarConfigurationTests: XCTestCase {
    func testHiddenByDefaultAndFiveSlotsPersistAcrossReload() {
        let name = "HomeToolbarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = HomeToolbarConfigurationService(defaults: defaults)
        XCTAssertFalse(service.isVisible)
        XCTAssertFalse(service.showsButtonBackground)
        XCTAssertEqual(service.actions, Array(repeating: .none, count: 5))
        service.save([.downloads, .files, .bookmarks, .history, .wallpaper], showsButtonBackground: true)
        let restored = HomeToolbarConfigurationService(defaults: defaults)
        XCTAssertTrue(restored.isVisible)
        XCTAssertTrue(restored.showsButtonBackground)
        XCTAssertEqual(restored.actions, [.downloads, .files, .bookmarks, .history, .wallpaper])
        defaults.set(false, forKey: HomeToolbarConfigurationService.backgroundKey)
        restored.reloadFromDefaults()
        XCTAssertFalse(restored.showsButtonBackground)
        XCTAssertEqual(restored.actions, [.downloads, .files, .bookmarks, .history, .wallpaper])
        restored.save([])
        XCTAssertFalse(HomeToolbarConfigurationService(defaults: defaults).isVisible)
    }
    func testUnknownSavedActionsLeaveTheirSlotsEmptyWithoutMovingOthers() {
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "future-action", "wallpaper", "files", "settings"]),
                       [.downloads, .none, .wallpaper, .files, .settings])
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["history"]), [.history, .none, .none, .none, .none])
    }
    func testFourSlotUpgradeKeepsExistingChoicesAndRejectsASixthSlot() {
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "files", "bookmarks", "history"]),
                       [.downloads, .files, .bookmarks, .history, .none])
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "files", "bookmarks", "history", "wallpaper", "settings"]),
                       [.downloads, .files, .bookmarks, .history, .wallpaper])
    }
    func testEveryActionHasALocalizedLabelAndSymbol() {
        for action in HomeToolbarAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: action.symbol), action.rawValue)
            XCTAssertNotNil(UIImage(systemName: action.listSymbol), action.rawValue)
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
