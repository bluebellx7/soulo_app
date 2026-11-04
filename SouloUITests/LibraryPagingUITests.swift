import XCTest
import UIKit

@MainActor
final class LibraryPagingUITests: XCTestCase {
    private let sections = ["bookmarks", "history", "downloads", "files"]

    func testAirPlayFromSouloKeepsTheDefaultPlayerPreference() throws {
        let app = launch()
        func openVideo() throws {
            try open("files", app: app)
            let folder = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item.Player-QA")).firstMatch
            guard folder.waitForExistence(timeout: 5) else { throw XCTSkip("Requires opt-in playback fixtures") }
            folder.tap()
            app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item.01.mp4")).firstMatch.tap()
            XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 10))
        }
        try openVideo()
        app.buttons["media.file.airplay"].tap()
        XCTAssertTrue(app.otherElements["media.preview"].waitForExistence(timeout: 10), "AirPlay-compatible media must hand off to the system player")
        // Give the OS route picker time to present after the native asset and
        // its view have attached; the simulator may not offer any receivers.
        Thread.sleep(forTimeInterval: 3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "AirPlay device selection after switching from Soulo"; shot.lifetime = .keepAlways; add(shot)
        let picker = app.descendants(matching: .any)["media.airplay.routePicker"].firstMatch
        if picker.exists {
            picker.tap()
            Thread.sleep(forTimeInterval: 1)
            let routes = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            routes.name = "System AirPlay route picker"; routes.lifetime = .keepAlways; add(routes)
        }
        app.terminate(); app.launch()
        try openVideo()
        XCTAssertEqual(app.buttons["media.file.player"].value as? String, "Soulo", "Casting must not change the default video player")
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light",
            "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        return app
    }

    private func open(_ section: String, app: XCUIApplication) throws {
        app.open(try XCTUnwrap(URL(string: "soulo://" + section)))
        assertSelected(section, app: app)
    }

    private func assertSelected(_ section: String, app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["library.section." + section]
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription, file: file, line: line)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in button.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, app.debugDescription, file: file, line: line)
        if section != "files" {
            let page = app.collectionViews.firstMatch
            let viewport = app.scrollViews["library.pages"].firstMatch
            let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                page.exists && abs(page.frame.midX - viewport.frame.midX) < 1.5
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed, "Selected content must be on screen: " + app.debugDescription, file: file, line: line)
        }
        for other in sections where other != section {
            XCTAssertFalse(app.buttons["library.section." + other].isSelected, file: file, line: line)
        }
    }

    private func page(left: Bool, app: XCUIApplication) {
        let viewport = app.scrollViews["library.pages"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), app.debugDescription)
        // Start outside the inset row's swipe actions. A rightward page drag
        // begins well inside the viewport, away from the navigation edge.
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.97 : 0.25, dy: 0.7))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.95, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
    }

    func testSwipingAndTappingKeepPageSelectionAndToolbarInSync() throws {
        let app = launch()
        try open("bookmarks", app: app)
        XCTAssertTrue(app.buttons["favorites.manage"].exists)
        XCTAssertFalse(app.buttons["files.import"].exists)
        for section in sections.dropFirst() {
            page(left: true, app: app)
            assertSelected(section, app: app)
        }
        XCTAssertTrue(app.buttons["files.import"].exists)
        XCTAssertFalse(app.buttons["favorites.manage"].exists)
        for section in sections.dropLast().reversed() {
            page(left: false, app: app)
            assertSelected(section, app: app)
        }
        app.buttons["library.section.files"].tap()
        assertSelected("files", app: app)
        XCTAssertTrue(app.buttons["files.viewMode"].exists)
        app.buttons["library.section.history"].tap()
        assertSelected("history", app: app)
        XCTAssertFalse(app.buttons["files.viewMode"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Library after swipes and tab taps"; shot.lifetime = .keepAlways; add(shot)
    }

    func testLeftEdgeExitsEverySectionAndShortEdgeDragCancels() throws {
        let app = launch()
        for section in sections {
            try open(section, app: app)
            let y = app.frame.height * 0.55
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: y))
            if section == "history" {
                let cancel = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: y))
                start.press(forDuration: 0.05, thenDragTo: cancel, withVelocity: .slow, thenHoldForDuration: 0.3)
                assertSelected(section, app: app)
            }
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            XCTAssertTrue(app.buttons["library.section." + section].waitForNonExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5), app.debugDescription)
        }
    }

    func testRightwardSwipeStartingOnADownloadRowReturnsToPreviousTab() throws {
        let app = launch()
        try open("downloads", app: app)
        let row = app.collectionViews.cells.firstMatch
        guard row.waitForExistence(timeout: 5) else { throw XCTSkip("Requires a downloaded item") }
        let viewport = app.scrollViews["library.pages"].firstMatch
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: viewport.frame.maxX - 16, dy: row.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        assertSelected("history", app: app)
    }

    func testExpandedFileActionsCloseBeforePagingBack() throws {
        let app = launch()
        try open("files", app: app)
        let file = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item.Panda-QA.mp4")).firstMatch
        guard file.waitForExistence(timeout: 5) else { throw XCTSkip("Requires the opt-in video fixture in Downloads") }
        let y = file.frame.midY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: app.frame.width * 0.8, dy: y)).press(forDuration: 0.05,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.5, dy: y)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        let action = app.buttons["Delete"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "A short trailing swipe must reveal the native row action")
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.25, dy: y))
        let end = origin.withOffset(CGVector(dx: app.frame.width * 0.95, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(action.waitForNonExistence(timeout: 5), "The first leading swipe must restore the row")
        assertSelected("files", app: app)
        XCTAssertTrue(file.exists, "Canceling a swipe action must preserve the file")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        assertSelected("downloads", app: app)
    }

    func testHEVCFileListPlaybackShowsVisibleVideo() throws {
        let app = launch()
        try open("files", app: app)
        let realPath = ProcessInfo.processInfo.environment["SOULO_DEVICE_VIDEO_QA"]
        let components = (realPath ?? "Panda-QA.mp4").split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let folder = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item." + component)).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 8), "Missing real video folder: " + component)
            folder.tap()
        }
        let file = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item." + components.last!)).firstMatch
        if realPath == nil, !file.waitForExistence(timeout: 5) { throw XCTSkip("Requires the opt-in real HEVC video fixture in Downloads") }
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 10), "The Files entry must perform codec selection before playback")
        if realPath != nil {
            app.sliders["media.mkv.timeline"].adjust(toNormalizedSliderPosition: 0.055)
            // The real episode opens with black studio frames. Seek into the
            // same bright scene used by the simulator sample before checking pixels.
            Thread.sleep(forTimeInterval: 1)
        }
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "HEVC opened through the actual Files list"; attachment.lifetime = .keepAlways; add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colored = try pixels.withUnsafeMutableBytes { memory -> Double in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let data = memory.bindMemory(to: UInt8.self)
            var colorful = 0, sampled = 0
            for y in stride(from: height * 35 / 100, to: height * 55 / 100, by: 3) {
                for x in stride(from: width / 4, to: width * 3 / 4, by: 3) {
                    let index = (y * width + x) * 4
                    let rgb = [Int(data[index]), Int(data[index+1]), Int(data[index+2])]
                    if rgb.max()! - rgb.min()! > 24 && rgb.max()! > 60 { colorful += 1 }
                    sampled += 1
                }
            }
            return Double(colorful) / Double(max(1, sampled))
        }
        XCTAssertGreaterThan(colored, 0.05, "Decoded-frame counters alone must not pass a visibly black video surface")
        XCTAssertTrue(app.progressIndicators["media.mkv.buffering"].waitForNonExistence(timeout: 5))
        app.buttons["media.mkv.fullscreen"].tap()
        let close = app.buttons["media.mkv.fullscreen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "Fullscreen opens with visible controls")
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 4), .completed)
        let fullscreenShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        fullscreenShot.name = "Fullscreen video controls"; fullscreenShot.lifetime = .keepAlways; add(fullscreenShot)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Playing video should automatically hide its controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 2), "Tapping the video reveals its controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 2), "Tapping the video again hides its controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 2))
        app.buttons["media.file.speed"].tap()
        Thread.sleep(forTimeInterval: 4)
        let rate = app.descendants(matching: .any)["media.file.rate.1.25"].firstMatch
        XCTAssertTrue(rate.exists, "An open speed menu must survive the controls' auto-hide timer")
        rate.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 2))
        close.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 5))
        app.buttons["media.file.speed"].tap()
        app.descendants(matching: .any)["media.file.rate.1.0"].firstMatch.tap()
    }

    func testVideoBrightnessAndVolumeSwipeFeedback() throws {
        let app = launch()
        try open("files", app: app)
        let file = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item.Panda-QA.mp4")).firstMatch
        guard file.waitForExistence(timeout: 5) else { throw XCTSkip("Requires the opt-in video fixture in Downloads") }
        file.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 10))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for x in [0.25, 0.75] {
            let start = origin.withOffset(CGVector(dx: app.frame.width * x, dy: app.frame.height * 0.53))
            let end = origin.withOffset(CGVector(dx: app.frame.width * x, dy: app.frame.height * 0.38))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.05)
            let feedback = app.descendants(matching: .any).matching(identifier: "media.mkv.gesture.feedback").firstMatch
            XCTAssertTrue(feedback.waitForExistence(timeout: 1), "Vertical swipes must give adjustment feedback")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = x < 0.5 ? "Brightness swipe" : "Volume swipe"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
        }
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["library.section.files"].waitForExistence(timeout: 5))
    }

    func testFilePlayerSwitchesEngineSpeedAndEpisode() throws {
        let app = launch()
        try open("files", app: app)
        for view in ["Files layout before toggle", "Files layout after toggle"] {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = view; shot.lifetime = .keepAlways; add(shot)
            app.buttons["files.viewMode"].tap()
        }
        let folder = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item.Player-QA")).firstMatch
        guard folder.waitForExistence(timeout: 5) else { throw XCTSkip("Requires opt-in playback fixtures") }
        folder.tap()
        app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item.01.mp4")).firstMatch.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 10), "File video defaults to Soulo")
        app.buttons["media.file.episodes"].tap()
        let episodeClose = app.buttons["media.file.episodes.close"]
        XCTAssertTrue(episodeClose.waitForExistence(timeout: 3))
        let preview = app.otherElements["media.mkv.preview"].firstMatch
        XCTAssertLessThan(episodeClose.frame.minY, preview.frame.minY + 70, "Portrait episode lists must start at the top of the player")
        let portraitDrawer = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portraitDrawer.name = "Portrait episode drawer aligned to the top"; portraitDrawer.lifetime = .keepAlways; add(portraitDrawer)
        app.buttons["media.file.episodes.settings"].tap()
        XCTAssertTrue(app.switches["video-settings.episode-dock"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        episodeClose.tap()
        app.buttons["media.file.speed"].tap()
        app.descendants(matching: .any)["media.file.rate.1.5"].firstMatch.tap()
        XCTAssertEqual(app.buttons["media.file.speed"].value as? String, "1.5×")
        app.sliders["media.mkv.timeline"].adjust(toNormalizedSliderPosition: 0.25)
        if !app.buttons["media.mkv.play"].exists { preview.tap() }
        app.buttons["media.mkv.play"].tap()
        func seconds(_ text: String) -> Double {
            text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        let position = seconds(app.staticTexts["media.mkv.timeline.elapsed"].label)
        XCTAssertGreaterThan(position, 10, "The fixture must seek before testing a paused handoff")
        app.buttons["media.file.player"].tap()
        app.descendants(matching: .any)["media.file.engine.system"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["media.preview"].waitForExistence(timeout: 8), "Compatible video can switch to the native player")
        XCTAssertEqual(app.buttons["media.file.player"].value as? String, "System")
        XCTAssertEqual(app.buttons["media.file.speed"].value as? String, "1.5×", "Switching players preserves speed")
        app.buttons["media.file.player"].tap()
        app.descendants(matching: .any)["media.file.engine.soulo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 8))
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = app.staticTexts["media.mkv.timeline.elapsed"].label
            return abs(seconds(value) - position) <= 2
        }, object: nil)
        let resumedResult = XCTWaiter.wait(for: [resumed], timeout: 6)
        let resumedPosition = app.staticTexts["media.mkv.timeline.elapsed"].label
        XCTAssertEqual(resumedResult, .completed, "Switching a paused video must preserve \(position)s; got \(resumedPosition)")
        XCTAssertEqual(app.buttons["media.mkv.play"].label, "Play", "Switching players must preserve pause")
        XCTAssertTrue(app.progressIndicators["media.mkv.buffering"].waitForNonExistence(timeout: 3), "A paused handoff must not leave a loading spinner")
        app.buttons["media.mkv.fullscreen"].tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen.close"].waitForExistence(timeout: 4))
        app.buttons["media.file.episodes"].tap()
        XCTAssertTrue(app.otherElements["media.file.episodes.drawer"].waitForExistence(timeout: 3))
        let drawerShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        drawerShot.name = "Fullscreen episode drawer"; drawerShot.lifetime = .keepAlways; add(drawerShot)
        app.buttons["02.mp4"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["media.file.episodes.drawer"].waitForNonExistence(timeout: 8))
        let fullscreenClose = app.buttons["media.mkv.fullscreen.close"]
        if !fullscreenClose.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
        XCTAssertTrue(fullscreenClose.waitForExistence(timeout: 5), "Selecting an episode preserves the fullscreen player")
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        fullscreenClose.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["02.mp4"].waitForExistence(timeout: 5), "The selected episode updates the player title")
        app.buttons["media.file.speed"].tap()
        app.descendants(matching: .any)["media.file.rate.1.0"].firstMatch.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "File player with episodes, speed and player switching"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.firstMatch.tap()
        let mini = app.otherElements["media.mini-player"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "Soulo must keep the same mini player when navigating back")
        let miniShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        miniShot.name = "Soulo mini player over its original file directory"; miniShot.lifetime = .keepAlways; add(miniShot)
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "media.mini-player", "02.mp4")).firstMatch.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 8))
        app.buttons["media.file.player"].tap()
        app.descendants(matching: .any)["media.file.engine.system"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["media.preview"].waitForExistence(timeout: 8), "A restored Soulo mini player must still switch to system mode")
    }

    func testFileMoveAndFolderRename() throws {
        let app = launch()
        try open("files", app: app)
        func item(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "files.item." + name)).firstMatch
        }
        guard item("Move-QA").waitForExistence(timeout: 5) else { throw XCTSkip("Requires opt-in move fixtures") }
        item("Move-QA").tap()
        item("Source").press(forDuration: 0.6)
        app.buttons["Rename"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Renamed")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(item("Renamed").waitForExistence(timeout: 5))
        item("Renamed").tap()
        item("Note.txt").press(forDuration: 0.6)
        app.buttons["files.move"].tap()
        let destination = app.buttons["Move-QA/Target"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
        destination.tap()
        XCTAssertTrue(item("Note.txt").waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        item("Target").tap()
        XCTAssertTrue(item("Note.txt").waitForExistence(timeout: 5))
    }

    func testBookmarkFolderStaysOpenAcrossPagesAndRowsKeepSwipeActions() throws {
        let app = launch()
        try open("bookmarks", app: app)
        let name = "Paging QA " + UUID().uuidString.prefix(6)
        app.buttons["favorites.manage"].tap()
        app.buttons["New Folder"].firstMatch.tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
        input.typeText(name)
        app.alerts.buttons["Done"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        folder.tap()
        XCTAssertTrue(app.buttons["favorites.parent"].waitForExistence(timeout: 5), app.debugDescription)
        page(left: true, app: app)
        assertSelected("history", app: app)
        page(left: false, app: app)
        assertSelected("bookmarks", app: app)
        XCTAssertTrue(app.buttons["favorites.parent"].exists, "Swapping pages must preserve the open bookmark folder")
        app.buttons["favorites.parent"].tap()
        folder.swipeLeft()
        assertSelected("bookmarks", app: app)
        app.buttons["Delete"].firstMatch.tap()
        app.alerts.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 5), app.debugDescription)
    }
}
