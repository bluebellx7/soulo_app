import XCTest
import SwiftUI
import Combine
@testable import Soulo

@MainActor
final class MediaPictureInPictureTests: XCTestCase {
    func testUnchangedSouloStateDoesNotRepeatedlyInvalidatePlayerMenus() {
        let session = MediaSession.shared
        session.stop()
        defer { session.stop() }
        let playback = MatroskaPlayback()
        session.adoptSoulo(playback, url: URL(fileURLWithPath: "/tmp/unchanged-player.mp4"), title: nil,
            source: nil, pageURL: nil, systemAvailable: true)
        var changes = 0
        let observation = session.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for _ in 0..<20 { session.updateSouloState(playback) }
        XCTAssertEqual(changes, 0, "Polling unchanged state must not continuously replace an open native menu")
    }

    private final class SurfaceState: ObservableObject { @Published var primary = true }
    private struct Surfaces: View {
        @ObservedObject var state: SurfaceState
        var body: some View {
            VStack {
                if state.primary { InlineVideoSurface().frame(height: 220) }
                InlineVideoSurface(countsAsPlayerSurface: false).frame(width: 96, height: 54)
            }
        }
    }

    func testMiniSurfaceRecoversAfterPrimarySurfaceDisappears() async throws {
        let session = MediaSession.shared
        session.stop(); session.playerSurfaces = 0
        let state = SurfaceState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Surfaces(state: state)); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); session.stop() }
        func hosts(_ view: UIView) -> [InlineVideoSurface.Host] {
            (view as? InlineVideoSurface.Host).map { [$0] } ?? view.subviews.flatMap(hosts)
        }
        let root = try XCTUnwrap(window.rootViewController?.view)
        root.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let mini = try XCTUnwrap(hosts(root).first { !$0.countsAsPlayerSurface })
        XCTAssertNil(mini.video, "A thumbnail must not steal the mounted full-player layer")
        state.primary = false
        for _ in 0..<60 {
            if mini.video?.window != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(session.pictureInPicture.surface?.superview === mini,
                      "The already-created thumbnail must retry attachment after the full player leaves")
        XCTAssertNotNil(mini.video?.window)
        XCTAssertEqual(session.playerSurfaces, 0)
        window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(50))
    }

    func testQueuedStartTimesOutAndRepeatedTapsDoNotPostponeIt() async throws {
        let pip = MediaPictureInPicture(supported: true, startupTimeout: .milliseconds(60))
        defer { pip.stop() }
        pip.requestStart()
        XCTAssertTrue(pip.launching); XCTAssertTrue(pip.keepsPlaybackInBackground)
        try await Task.sleep(for: .milliseconds(30)); pip.requestStart()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(pip.launching); XCTAssertFalse(pip.keepsPlaybackInBackground)
        XCTAssertNotNil(pip.errorMessage)
        pip.requestStart()
        XCTAssertTrue(pip.launching); XCTAssertNil(pip.errorMessage)
        pip.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(pip.errorMessage); XCTAssertFalse(pip.launching)
    }

    func testNativeVideoStartsPictureInPictureFromPrimaryAndMiniSurfaces() async throws {
        let session = MediaSession.shared
        let pip = session.pictureInPicture
        try XCTSkipUnless(pip.supported, "The operating system does not support Picture in Picture")
        let oldLoop = session.loop
        session.stop(); session.playerSurfaces = 0
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = SurfaceState()
        window.rootViewController = UIHostingController(rootView: Surfaces(state: state)); window.makeKeyAndVisible()
        defer { session.stop(); session.loop = oldLoop; window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        session.open(url: file, title: "Native PiP fixture", autoplay: false)
        session.loop = true
        for primary in [true, false] {
            state.primary = primary
            window.rootViewController?.view.setNeedsLayout()
            pip.requestStart()
            for _ in 0..<120 {
                if pip.active || pip.errorMessage != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(pip.active, "Native PiP must actually start from \(primary ? "primary" : "mini") source: \(pip.errorMessage ?? "not ready"); possible=\(pip.possible), mounted=\(pip.surface?.window != nil), bounds=\(String(describing: pip.surface?.bounds)), ready=\(pip.surface?.playerLayer.isReadyForDisplay == true), item=\(String(describing: session.player.currentItem?.status)), time=\(session.elapsed), rate=\(session.player.rate), playbackError=\(session.error ?? "none")")
            guard pip.active else { return }
            let evidence = XCTAttachment(string: "active=\(pip.active), possible=\(pip.possible), mounted=\(pip.surface?.window != nil), elapsed=\(session.elapsed)")
            evidence.name = primary ? "native-pip-primary" : "native-pip-mini"; evidence.lifetime = .keepAlways; add(evidence)
            pip.stop()
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func testUnsupportedStartHasAnImmediateVisibleFailure() {
        let pip = MediaPictureInPicture(supported: false)
        pip.requestStart()
        XCTAssertNotNil(pip.errorMessage)
        XCTAssertFalse(pip.launching); XCTAssertFalse(pip.keepsPlaybackInBackground)
        pip.dismissError(); XCTAssertNil(pip.errorMessage)
    }
}
