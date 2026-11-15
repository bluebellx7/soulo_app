import XCTest
import WebKit
import CoreMotion
import AudioToolbox
import Combine
@testable import Soulo

@MainActor
final class BrowserGestureAndZoomTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: WebsiteZoomStore!
    override func setUp() {
        super.setUp()
        suite = "Soulo.ZoomTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        store = WebsiteZoomStore(defaults: defaults)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        store = nil; defaults = nil
        super.tearDown()
    }
    private func url(_ path: String = "example.invalid/a") -> URL { URL(string: "https://" + path)! }

    func testZoomUsesExactCanonicalHostAcrossPathsSchemesAndPorts() {
        store.set(1.4, for: URL(string: "https://EXAMPLE.invalid.:8443/first?q=1"))
        XCTAssertEqual(store.zoom(for: URL(string: "http://example.invalid/next")), 1.4)
        XCTAssertEqual(store.zoom(for: url("www.example.invalid/a")), 1)
        XCTAssertEqual(store.zoom(for: url("other.invalid/a")), 1)
        XCTAssertNil(WebsiteZoomStore.host(for: URL(string: "https://user:secret@example.invalid")))
        XCTAssertNil(WebsiteZoomStore.host(for: URL(string: "file:///example.invalid")))
        XCTAssertNil(WebsiteZoomStore.host(for: URL(string: "about:blank")))
    }

    func testZoomPersistsAndOneHundredPercentRemovesOverride() {
        store.set(1.34, for: url())
        XCTAssertEqual(WebsiteZoomStore(defaults: defaults).zoom(for: url()), 1.3)
        store.set(1, for: url())
        XCTAssertTrue(WebsiteZoomStore(defaults: defaults).sites.isEmpty)
        store.set(.nan, for: url())
        store.set(.infinity, for: url())
        XCTAssertTrue(store.sites.isEmpty)
        store.set(99, for: url()); XCTAssertEqual(store.zoom(for: url()), 2)
        store.set(-99, for: url()); XCTAssertEqual(store.zoom(for: url()), 0.5)
    }

    func testDisabledZoomKeepsOverridesAndResetAllRemovesThem() {
        store.set(1.6, for: url())
        store.isEnabled = false
        XCTAssertEqual(store.zoom(for: url()), 1)
        store.set(1.2, for: url())
        store.isEnabled = true
        XCTAssertEqual(store.zoom(for: url()), 1.6)
        store.resetAll()
        XCTAssertTrue(WebsiteZoomStore(defaults: defaults).sites.isEmpty)
    }

    func testMalformedImportedSettingsAreSanitized() {
        defaults.set(["good.invalid": 1.23, "bad.invalid": 4, "normal.invalid": 1,
                      "other.invalid/path": 1.5, "UPPER.invalid": 1.3], forKey: WebsiteZoomStore.sitesKey)
        XCTAssertEqual(WebsiteZoomStore(defaults: defaults).sites, ["good.invalid": 1.2])
    }

    func testModelsRestoreZoomOnNewTabsCrossDomainRedirectsAndHistory() {
        store.set(1.4, for: url())
        store.set(0.8, for: url("second.invalid/a"))
        let model = WebViewModel(zoomStore: store)
        model.recordNavigationRequest(url())
        XCTAssertEqual(model.pageZoom, 1.4, accuracy: 0.001)
        model.recordNavigationRequest(url("example.invalid/next"))
        XCTAssertEqual(model.pageZoom, 1.4, accuracy: 0.001)
        model.recordNavigationRequest(url("second.invalid/redirected"))
        XCTAssertEqual(model.pageZoom, 0.8, accuracy: 0.001)
        model.updateCurrentURL(url())
        XCTAssertEqual(model.pageZoom, 1.4, accuracy: 0.001)
        model.recordNavigationRequest(url("new.invalid/a"))
        XCTAssertEqual(model.pageZoom, 1)
    }

    func testRestoredTabAppliesSavedZoomBeforeInitialLoad() {
        store.set(1.5, for: url())
        let model = WebViewModel(zoomStore: store)
        model.currentURL = url()
        let view = WKWebView()
        model.webView = view
        view.stopLoading()
        XCTAssertEqual(model.pageZoom, 1.5, accuracy: 0.001)
        model.webView = nil
    }

    func testPrivateZoomRemainsInMemoryAndNeverChangesSavedSites() {
        store.set(1.4, for: url())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let model = WebViewModel(zoomStore: store)
        model.webView = WKWebView(frame: .zero, configuration: configuration)
        model.recordNavigationRequest(url())
        XCTAssertEqual(model.pageZoom, 1.4, accuracy: 0.001)
        model.setPageZoom(1.7)
        model.recordNavigationRequest(url("other.invalid/a"))
        model.recordNavigationRequest(url("example.invalid/back"))
        XCTAssertEqual(model.pageZoom, 1.7, accuracy: 0.001)
        XCTAssertEqual(WebsiteZoomStore(defaults: defaults).zoom(for: url()), 1.4)
        model.webView = nil
    }

    func testZoomChangesAndResetsReachOtherOpenTabs() async {
        let model = WebViewModel(zoomStore: store)
        model.recordNavigationRequest(url())
        store.set(1.6, for: url())
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.pageZoom, 1.6, accuracy: 0.001)
        store.reset(host: "example.invalid")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.pageZoom, 1)
    }

    func testParallelSwipeDirectionsAndThreshold() {
        let classifier = TwoFingerSwipeClassifier(first: CGPoint(x: 100, y: 100), second: CGPoint(x: 100, y: 160))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 120, y: 100), second: CGPoint(x: 120, y: 160)), .waiting)
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 200, y: 103), second: CGPoint(x: 200, y: 163)), .ready(.right))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 10, y: 96), second: CGPoint(x: 10, y: 156)), .ready(.left))
    }

    func testPinchRotationVerticalAndDivergingFingersDoNotBecomeSwipes() {
        let classifier = TwoFingerSwipeClassifier(first: CGPoint(x: 100, y: 100), second: CGPoint(x: 100, y: 180))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 100, y: 70), second: CGPoint(x: 100, y: 210)), .rejected)
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 120, y: 105), second: CGPoint(x: 80, y: 175)), .rejected)
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 110, y: 200), second: CGPoint(x: 110, y: 280)), .rejected)
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 200, y: 100), second: CGPoint(x: 145, y: 180)), .rejected)
    }

    func testRecognizedSwipeToleratesUnevenFingersAndKeepsDirectionWhenReturning() {
        let classifier = TwoFingerSwipeClassifier(first: CGPoint(x: 100, y: 100), second: CGPoint(x: 100, y: 180))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 140, y: 103), second: CGPoint(x: 128, y: 178)), .ready(.right))
        // Normal drift exceeds the old 12pt limit, but is not a pinch.
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 220, y: 108), second: CGPoint(x: 194, y: 173), lockedDirection: .right), .ready(.right))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 104, y: 103), second: CGPoint(x: 98, y: 181), lockedDirection: .right), .ready(.right))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 80, y: 102), second: CGPoint(x: 85, y: 179), lockedDirection: .right), .ready(.right))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 210, y: 30), second: CGPoint(x: 210, y: 250), lockedDirection: .right), .rejected)
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 180, y: 250), second: CGPoint(x: 180, y: 330), lockedDirection: .right), .rejected)
    }

    func testSecondFingerCanCatchUpBeforeDirectionIsRecognized() {
        let classifier = TwoFingerSwipeClassifier(first: CGPoint(x: 100, y: 100), second: CGPoint(x: 100, y: 180))
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 130, y: 100), second: CGPoint(x: 103, y: 180)), .waiting)
        XCTAssertEqual(classifier.evaluate(first: CGPoint(x: 145, y: 102), second: CGPoint(x: 130, y: 180)), .ready(.right))
    }

    func testGestureInstallationIsIdempotentAndCanBeDisabledAndRemoved() {
        let model = WebViewModel(zoomStore: store)
        let view = WKWebView()
        model.webView = view
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        coordinator.installTwoFingerSwipe(on: view, enabled: true)
        coordinator.installTwoFingerSwipe(on: view, enabled: true)
        let gestures = view.gestureRecognizers!.compactMap { $0 as? TwoFingerSwipeGestureRecognizer }
        XCTAssertEqual(gestures.count, 1)
        XCTAssertFalse(gestures[0].delaysTouchesBegan)
        XCTAssertFalse(gestures[0].delaysTouchesEnded)
        XCTAssertTrue(view.scrollView.panGestureRecognizer.isEnabled)
        coordinator.installTwoFingerSwipe(on: view, enabled: false)
        XCTAssertFalse(gestures[0].isEnabled)
        coordinator.removeTwoFingerSwipe()
        XCTAssertFalse(view.gestureRecognizers!.contains { $0 is TwoFingerSwipeGestureRecognizer })
        model.webView = nil
    }

    func testPreferencesKeepSidesIndependentAndSanitizeMenus() {
        XCTAssertEqual(BrowserSwipePreferences.action(for: .right, defaults: defaults), .closeTab)
        XCTAssertEqual(BrowserSwipePreferences.action(for: .left, defaults: defaults), .tabs)
        defaults.set("back", forKey: BrowserSwipePreferences.rightKey)
        XCTAssertEqual(BrowserSwipePreferences.action(for: .right, defaults: defaults), .back)
        XCTAssertEqual(BrowserSwipePreferences.action(for: .left, defaults: defaults), .tabs)
        XCTAssertEqual(BrowserSwipePreferences.menu(value: "back,unknown,none,menu,back,closeTab"), [.back, .closeTab])
        XCTAssertEqual(BrowserSwipePreferences.menu(value: ""), BrowserSwipePreferences.defaultMenu)
        XCTAssertFalse(BrowserSwipePreferences.enabledByDefault)
        XCTAssertEqual(BrowserSwipeExecution.release.rawValue, "release")
    }

    func testShakeDirectionFollowsScreenOrientationAndRejectsOtherAxes() {
        XCTAssertEqual(BrowserShakeIntensity.allCases.map(\.peakThreshold), [0.28, 0.42, 0.60, 0.80])
        XCTAssertEqual(BrowserShakeIntensity.allCases.map(\.strongPeakThreshold), [0.75, 1.0, 1.35, 1.65])
        let sideways = CMAcceleration(x: 0.9, y: 0.1, z: 0.1)
        let upwards = CMAcceleration(x: 0.1, y: 0.9, z: 0.1)
        let depth = CMAcceleration(x: 0.1, y: 0.1, z: 1.5)
        XCTAssertEqual(BrowserShakeDirection.horizontal.magnitude(sideways, orientation: .portrait), 0.9)
        XCTAssertNil(BrowserShakeDirection.horizontal.magnitude(upwards, orientation: .portrait))
        XCTAssertNil(BrowserShakeDirection.horizontal.magnitude(depth, orientation: .portrait))
        XCTAssertEqual(BrowserShakeDirection.horizontal.magnitude(upwards, orientation: .landscapeLeft), 0.9)
        XCTAssertEqual(BrowserShakeDirection.horizontal.magnitude(upwards, orientation: .landscapeRight), 0.9)
        XCTAssertEqual(BrowserShakeDirection.vertical.magnitude(upwards, orientation: .portrait), 0.9)
        XCTAssertEqual(BrowserShakeDirection.vertical.magnitude(sideways, orientation: .landscapeRight), 0.9)
        XCTAssertNil(BrowserShakeDirection.horizontal.magnitude(CMAcceleration(x: 0.8, y: 0.8, z: 0), orientation: .portrait))
        XCTAssertEqual(BrowserShakeDirection.any.magnitude(depth, orientation: .portrait)!, sqrt(2.27), accuracy: 0.0001)
    }

    func testDirectionalShakePreservesQuietZeroCrossingsButRejectsOffAxisPeaks() {
        var classifier = ShakeMotionClassifier()
        let side = CMAcceleration(x: 0.7, y: 0.05, z: 0.02)
        XCTAssertFalse(classifier.register(acceleration: side, direction: .horizontal, orientation: .portrait, at: 1))
        XCTAssertFalse(classifier.register(acceleration: CMAcceleration(x: 0, y: 0, z: 0), direction: .horizontal, orientation: .portrait, at: 1.04))
        XCTAssertTrue(classifier.register(acceleration: side, direction: .horizontal, orientation: .portrait, at: 1.12))
        XCTAssertFalse(classifier.register(acceleration: side, direction: .horizontal, orientation: .portrait, at: 2))
        XCTAssertFalse(classifier.register(acceleration: CMAcceleration(x: 0.05, y: 0.8, z: 0), direction: .horizontal, orientation: .portrait, at: 2.05))
        XCTAssertFalse(classifier.register(acceleration: side, direction: .horizontal, orientation: .portrait, at: 2.12))
        XCTAssertTrue(classifier.register(acceleration: side, direction: .horizontal, orientation: .portrait, at: 2.24))
        XCTAssertFalse(classifier.register(acceleration: side, direction: .horizontal, orientation: .portrait, at: 3.5))
        XCTAssertFalse(classifier.register(acceleration: CMAcceleration(x: 0.05, y: 0.7, z: 0), direction: .vertical, orientation: .portrait, at: 3.62))
    }

    func testNoHistorySwipeDisablesItselfWhileNativeBackIsAvailable() async throws {
        let html = Data("<meta name='viewport' content='width=device-width'><p>History guard</p>".utf8)
        let server = try DownloadPlaybackHTTPFixture(files: ["/first": html, "/second": html])
        let root = try await server.start(); defer { server.stop() }
        let model = WebViewModel(zoomStore: store)
        let view = WKWebView()
        model.webView = view
        defer { model.webView = nil }
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        func waitFor(_ url: URL) async throws {
            for _ in 0..<200 {
                if view.url == url && !view.isLoading { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("WebKit did not finish the local fixture")
        }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        model.recordNavigationRequest(first)
        view.load(URLRequest(url: first)); try await waitFor(first)
        coordinator.installNoHistorySwipe(on: view, enabled: true)
        let edge = try XCTUnwrap(view.gestureRecognizers?.compactMap { $0 as? UIScreenEdgePanGestureRecognizer }.first)
        XCTAssertTrue(edge.isEnabled)
        XCTAssertEqual(edge.maximumNumberOfTouches, 1)
        view.load(URLRequest(url: second)); try await waitFor(second)
        XCTAssertTrue(view.canGoBack)
        coordinator.installNoHistorySwipe(on: view, enabled: true)
        XCTAssertFalse(edge.isEnabled, "Existing history belongs to WebKit's native gesture")
        view.goBack(); try await waitFor(first)
        XCTAssertFalse(view.canGoBack)
        coordinator.installNoHistorySwipe(on: view, enabled: true)
        XCTAssertTrue(edge.isEnabled)
        coordinator.removeNoHistorySwipe()
        XCTAssertFalse(view.gestureRecognizers?.contains { $0 === edge } ?? false)
    }

    func testGestureZoomAndShakePreferencesSurvivePortableBackup() throws {
        defaults.set("menu", forKey: BrowserSwipePreferences.rightKey)
        defaults.set("newTab", forKey: BrowserSwipePreferences.leftKey)
        defaults.set("showToolbar", forKey: BrowserSwipePreferences.noHistoryKey)
        defaults.set("back,closeTab", forKey: BrowserSwipePreferences.menuKey)
        defaults.set(false, forKey: BrowserSwipePreferences.enabledKey)
        defaults.set("tap", forKey: BrowserSwipePreferences.executionKey)
        defaults.set(false, forKey: BrowserSwipePreferences.hapticsKey)
        defaults.set(true, forKey: BrowserSwipePreferences.soundKey)
        defaults.set("vertical", forKey: BrowserShakeDirection.preferenceKey)
        store.set(1.4, for: url())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backups = CloudSettingsBackupStore(directory: directory)
        let saved = try backups.save(CloudSettingsSyncEngine.snapshot(defaults))
        let imported = try backups.importData(backups.exportData(for: saved), preserving: [:])
        let values = try backups.values(for: imported)
        XCTAssertEqual(values[BrowserSwipePreferences.rightKey] as? String, "menu")
        XCTAssertEqual(values[BrowserSwipePreferences.leftKey] as? String, "newTab")
        XCTAssertEqual(values[BrowserSwipePreferences.noHistoryKey] as? String, "showToolbar")
        XCTAssertEqual(values[BrowserSwipePreferences.menuKey] as? String, "back,closeTab")
        XCTAssertEqual(values[BrowserSwipePreferences.enabledKey] as? Bool, false)
        XCTAssertEqual(values[BrowserSwipePreferences.executionKey] as? String, "tap")
        XCTAssertEqual(values[BrowserSwipePreferences.hapticsKey] as? Bool, false)
        XCTAssertEqual(values[BrowserSwipePreferences.soundKey] as? Bool, true)
        XCTAssertEqual(values[BrowserShakeDirection.preferenceKey] as? String, "vertical")
        XCTAssertEqual(values[WebsiteZoomStore.sitesKey] as? [String: Double], ["example.invalid": 1.4])
    }

    func testTouchSamplesDoNotInvalidateTheWebViewModel() {
        let model = WebViewModel(zoomStore: store)
        let request = BrowserSwipeRequest(direction: .right, action: .closeTab, url: nil, phase: .dragging)
        model.swipeActionRequest = request
        var invalidations = 0
        let observation = model.objectWillChange.sink { invalidations += 1 }
        for index in 0..<60 {
            request.motion = .init(progress: CGFloat(index) / 60, distance: CGFloat(index), verticalFraction: 0.5)
        }
        XCTAssertEqual(invalidations, 0, "The small hint observes touch movement without rebuilding webpage chrome at 60 Hz")
        withExtendedLifetime(observation) {}
    }
}

final class AppFeedbackTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "Soulo.AppFeedbackTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testExistingGesturePreferencesBecomeGlobalWithoutLosingValues() {
        XCTAssertTrue(AppFeedbackPreferences.hapticsEnabled(in: defaults))
        XCTAssertFalse(AppFeedbackPreferences.soundEnabled(in: defaults))
        defaults.set(false, forKey: BrowserSwipePreferences.hapticsKey)
        defaults.set(true, forKey: BrowserSwipePreferences.soundKey)
        XCTAssertFalse(AppFeedbackPreferences.hapticsEnabled(in: defaults))
        XCTAssertTrue(AppFeedbackPreferences.soundEnabled(in: defaults))
        let restored = UserDefaults(suiteName: suite)!
        XCTAssertFalse(AppFeedbackPreferences.hapticsEnabled(in: restored))
        XCTAssertTrue(AppFeedbackPreferences.soundEnabled(in: restored))
    }

    func testAllHapticTypesAndSoundsHonorIndependentSwitchesImmediately() {
        var haptics: [AppHapticFeedback] = []
        var sounds: [SystemSoundID] = []
        let player = AppFeedbackPlayer(defaults: defaults,
            hapticPlayer: { haptics.append($0) }, soundPlayer: { sounds.append($0) })
        for feedback in AppHapticFeedback.allCases { player.haptic(feedback) }
        player.playSound(123)
        XCTAssertEqual(haptics, AppHapticFeedback.allCases)
        XCTAssertTrue(sounds.isEmpty)
        haptics.removeAll()
        defaults.set(false, forKey: AppFeedbackPreferences.hapticsKey)
        defaults.set(true, forKey: AppFeedbackPreferences.soundKey)
        for feedback in AppHapticFeedback.allCases { player.haptic(feedback) }
        player.playSound(123)
        player.playSound(0)
        XCTAssertTrue(haptics.isEmpty)
        XCTAssertEqual(sounds, [123])
        defaults.set(true, forKey: AppFeedbackPreferences.hapticsKey)
        defaults.set(false, forKey: AppFeedbackPreferences.soundKey)
        player.haptic(.success)
        player.playSound(456)
        XCTAssertEqual(haptics, [.success])
        XCTAssertEqual(sounds, [123])
        defaults.set(false, forKey: AppFeedbackPreferences.hapticsKey)
        player.haptic(.error)
        player.playSound(456)
        XCTAssertEqual(haptics, [.success])
        XCTAssertEqual(sounds, [123])
    }
}
