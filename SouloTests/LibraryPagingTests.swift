import XCTest
import SwiftUI
@testable import Soulo

final class LibraryPagingTests: XCTestCase {
    func testProgressUsesActualViewportAndClampsBounceInBothDirections() {
        let samples: [CGFloat] = [0, 0.25, 0.5, 1.75, 3]
        for value in samples {
            let width: CGFloat = 390
            let ltr = CGRect(x: -width * value, y: 0, width: width * 4, height: 700)
            let rtl = CGRect(x: width * (value - 3), y: 0, width: width * 4, height: 700)
            XCTAssertEqual(LibraryPageGeometry.progress(frame: ltr, width: width, direction: .leftToRight), value, accuracy: 0.001)
            XCTAssertEqual(LibraryPageGeometry.progress(frame: rtl, width: width, direction: .rightToLeft), value, accuracy: 0.001)
        }
        XCTAssertEqual(LibraryPageGeometry.progress(frame: CGRect(x: 60, y: 0, width: 1560, height: 700), width: 390, direction: .leftToRight), 0)
        XCTAssertEqual(LibraryPageGeometry.progress(frame: CGRect(x: -1400, y: 0, width: 1560, height: 700), width: 390, direction: .leftToRight), 3)
        XCTAssertEqual(LibraryPageGeometry.progress(frame: .zero, width: 0, direction: .leftToRight), 0)
    }

    func testIndicatorInterpolatesDifferentCaptionWidthsAndReversePositions() throws {
        let frames = [CGRect(x: 10, y: 2, width: 50, height: 50), CGRect(x: 95, y: 2, width: 70, height: 50)]
        let midway = try XCTUnwrap(LibraryPageGeometry.indicator(progress: 0.5, frames: frames))
        XCTAssertEqual(midway, CGRect(x: 52.5, y: 2, width: 60, height: 50))
        XCTAssertEqual(LibraryPageGeometry.indicator(progress: -1, frames: frames), frames[0])
        XCTAssertEqual(LibraryPageGeometry.indicator(progress: 5, frames: frames), frames[1])
        XCTAssertEqual(LibraryPageGeometry.indicator(progress: 0.5, frames: Array(frames.reversed())), midway)
        XCTAssertNil(LibraryPageGeometry.indicator(progress: .nan, frames: frames))
        XCTAssertNil(LibraryPageGeometry.indicator(progress: 0, frames: []))
    }

    @MainActor
    func testNativePagerReportsFractionalOffsetAndKeepsSelectionAfterResize() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let state = PagingState()
            let host = UIHostingController(rootView: PagingFixture(state: state).environment(\.layoutDirection, direction))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()

            func pager(in view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, scroll.bounds.width > 0,
                   scroll.contentSize.width > scroll.bounds.width * 3 { return scroll }
                return view.subviews.lazy.compactMap { pager(in: $0) }.first
            }
            for _ in 0..<100 where pager(in: host.view) == nil { try await Task.sleep(for: .milliseconds(20)) }
            let scroll = try XCTUnwrap(pager(in: host.view))
            // Allow the initial onAppear/scroll target transaction to finish
            // before simulating an independent, partially completed gesture.
            try await Task.sleep(for: .milliseconds(200))
            let reverse = direction == .rightToLeft
            let fractionalX = (reverse ? 2.6 : 0.4) * scroll.bounds.width
            scroll.setContentOffset(CGPoint(x: fractionalX, y: 0), animated: false)
            for _ in 0..<100 where abs(state.progress - 0.4) > 0.02 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(state.progress, 0.4, accuracy: 0.02, "The highlight must read the real scroll offset: \(direction), offset=\(scroll.contentOffset.x), samples=\(state.observed)")

            scroll.setContentOffset(CGPoint(x: reverse ? 3 * scroll.bounds.width : 0, y: 0), animated: false)
            for _ in 0..<100 where state.progress > 0.02 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(state.progress, 0, accuracy: 0.02, "Returning a partial swipe must restore the highlight")

            state.observed.removeAll()
            withAnimation(.easeInOut(duration: 0.35)) { state.section = .files }
            for _ in 0..<100 where abs(state.progress - 3) > 0.02 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(state.progress, 3, accuracy: 0.02)
            XCTAssertTrue(state.observed.contains { $0 > 0.1 && $0 < 2.9 }, "Tab taps must also expose intermediate page positions")
            window.frame.size.width = 600
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(state.section, .files)
            XCTAssertEqual(state.progress, 3, accuracy: 0.02)
            XCTAssertEqual(scroll.contentOffset.x, reverse ? 0 : 3 * scroll.bounds.width, accuracy: 1)
        }
    }

    @MainActor
    private final class PagingState: ObservableObject {
        @Published var section: LibrarySection = .bookmarks
        @Published var progress: CGFloat = 0 { didSet { observed.append(progress) } }
        var observed: [CGFloat] = []

        init(section: LibrarySection = .bookmarks) {
            self.section = section
            self.progress = CGFloat(LibrarySection.allCases.firstIndex(of: section) ?? 0)
        }
    }

    @MainActor
    func testNativePagerPositionsEveryInitialSectionInBothDirections() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for (index, section) in LibrarySection.allCases.enumerated() {
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                let state = PagingState(section: section)
                let host = UIHostingController(rootView: PagingFixture(state: state).environment(\.layoutDirection, direction))
                host.safeAreaRegions = []
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
                window.rootViewController = host; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
                host.view.frame = window.bounds; host.view.layoutIfNeeded()
                func pager(in view: UIView) -> UIScrollView? {
                    if let scroll = view as? UIScrollView, scroll.bounds.width > 0,
                       scroll.contentSize.width > scroll.bounds.width * 3 { return scroll }
                    return view.subviews.lazy.compactMap { pager(in: $0) }.first
                }
                for _ in 0..<100 where pager(in: host.view) == nil { try await Task.sleep(for: .milliseconds(20)) }
                let scroll = try XCTUnwrap(pager(in: host.view))
                let physicalIndex = direction == .rightToLeft ? 3 - index : index
                for _ in 0..<100 where abs(scroll.contentOffset.x - CGFloat(physicalIndex) * scroll.bounds.width) > 1 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(state.section, section)
                XCTAssertEqual(scroll.contentOffset.x, CGFloat(physicalIndex) * scroll.bounds.width, accuracy: 1, "Initial \(section), \(direction)")
                XCTAssertEqual(state.progress, CGFloat(index), accuracy: 0.02)
            }
        }
    }

    private struct PagingFixture: View {
        @ObservedObject var state: PagingState
        var body: some View {
            LibraryPager(selectedSection: $state.section, progress: $state.progress) { section in
                Text(section.rawValue).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @MainActor
    func testIndicatorRendersIntermediatePositionAndReturnsAfterCancelledDrag() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let manager = LanguageManager.shared
        let originalLanguage = manager.currentLanguage
        manager.currentLanguage = "en-US"
        let host = UIHostingController(rootView: LibrarySectionSwitcher(selectedSection: .constant(.bookmarks), progress: 0))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 80)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible(); manager.currentLanguage = originalLanguage
        }
        var images: [UIImage] = []
        for progress in [CGFloat(0), 0.5, 0] {
            host.rootView = LibrarySectionSwitcher(selectedSection: .constant(.bookmarks), progress: progress)
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            images.append(image)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Library tab drag progress \(progress)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertNotEqual(images[0].pngData(), images[1].pngData(), "A half drag must change the highlight before selection commits")
        XCTAssertEqual(images[0].pngData(), images[2].pngData(), "Cancelling the drag must restore the original highlight")
    }
}
