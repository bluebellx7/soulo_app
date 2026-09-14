import XCTest
import SwiftUI
import AVFoundation
@testable import Soulo

@MainActor final class DownloadAudioPlaybackTests: XCTestCase {
    func testDownloadedM4AStartsAndAdvancesInContentPreview() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("downloaded.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = url; exporter.outputFileType = .m4a
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed)
        let item = BrowserDownloadItem(id: UUID(), fileName: url.lastPathComponent, sourceURLString: "https://example.com/audio.m4a", localPath: url.path, startedAt: Date(), completedAt: Date(), status: .finished, errorMessage: "")
        let session = MediaSession.shared
        let oldRate = session.rate
        session.setRate(1)
        defer { session.stop(); session.setRate(oldRate) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.rootViewController = UIHostingController(rootView: NavigationStack { DownloadContentPreview(item: item) })
        window.makeKeyAndVisible()
        for _ in 0..<160 {
            if session.player.currentTime().seconds > 0.3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.url, url)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.playing)
        XCTAssertGreaterThan(session.player.currentTime().seconds, 0.3)
    }
}
