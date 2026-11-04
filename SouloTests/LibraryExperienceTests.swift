import XCTest
import SwiftUI
import WebKit
import CoreImage
@testable import Soulo

final class LibraryExperienceTests: XCTestCase {
    func testMoveAndFolderRenamePreserveContentsAndRejectUnsafeDestinations() throws {
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent("Relocate-\(UUID())")
        let source = root.appendingPathComponent("Music.2026"), target = root.appendingPathComponent("Target")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let song = source.appendingPathComponent("Song.mp3"), data = Data("Original audio bytes".utf8)
        try data.write(to: song)
        let renamed = try LibraryFileActions.rename(source, baseName: "Renamed.music", in: root)
        XCTAssertEqual(renamed.lastPathComponent, "Renamed.music")
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("Song.mp3")), data)
        let nested = renamed.appendingPathComponent("Nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LibraryFileActions.move([renamed], from: root, to: nested, root: root))
        let moved = try LibraryFileActions.move([renamed], from: root, to: target, root: root)
        XCTAssertEqual(moved.map(\.lastPathComponent), ["Renamed.music"])
        XCTAssertEqual(try Data(contentsOf: moved[0].appendingPathComponent("Song.mp3")), data)
        XCTAssertEqual(LibraryFileActions.relocated(song, from: source, to: moved[0])?.lastPathComponent, "Song.mp3")
        let duplicate = root.appendingPathComponent("Song.mp3"), original = moved[0].appendingPathComponent("Song.mp3")
        try Data("Keep destination".utf8).write(to: target.appendingPathComponent("Song.mp3"))
        try data.write(to: duplicate)
        XCTAssertThrowsError(try LibraryFileActions.move([duplicate], from: root, to: target, root: root))
        XCTAssertEqual(try Data(contentsOf: duplicate), data)
        XCTAssertEqual(try Data(contentsOf: original), data)
        let link = root.appendingPathComponent("linked.mp3")
        try manager.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try LibraryFileActions.move([link], from: root, to: target, root: root))
        let package = root.appendingPathComponent("Offline.hls")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("#EXTM3U".utf8).write(to: package.appendingPathComponent("index.m3u8"))
        let renamedPackage = try LibraryFileActions.rename(package, baseName: "Episode", in: root)
        XCTAssertEqual(renamedPackage.lastPathComponent, "Episode.hls")
        XCTAssertEqual(try LocalHLSMedia.playlistURL(for: renamedPackage).lastPathComponent, "index.m3u8")
    }

    func testScannedURLsAndLocalTextStaySeparate() {
        for value in ["https://example.com/a?b=1", "http://localhost:8080", "example.com/path", "example.com?a=1", "192.168.1.1:8080", "https://example.com/image.jpg", "https://example.com/book.pdf"] {
            XCTAssertNotNil(ScannedContent(text: value).webURL, value)
        }
        for value in ["hello world", "WIFI:T:WPA;S:my wifi;P:secret;;", "javascript:alert(1)", "file:///tmp/a", "soulo://action", "data:text/html,test"] {
            XCTAssertNil(ScannedContent(text: value).webURL, value)
        }
        let html = ScannedContent(text: "<script>fetch('https://example.com')</script>\nhello & goodbye").html
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>fetch"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("hello &amp; goodbye"))
    }

    func testQRDecoderReadsImagePayload() throws {
        let payload = "https://example.com/scan?value=1"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let image = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        XCTAssertEqual(try ScannedContent.decodeImage(data), payload)
    }

    func testPhotoTextFallbackAndEmptyImage() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 400))
        let photo = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 400))
            ("Read this original image text." as NSString).draw(at: CGPoint(x: 45, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black,
            ])
        }
        let text = try ScannedContent.decodeImage(try XCTUnwrap(photo.pngData()))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("original image text"), text)
        let empty = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 400)) }
        XCTAssertThrowsError(try ScannedContent.decodeImage(try XCTUnwrap(empty.pngData())))
    }

    func testBarcodeImageReturnsItsContent() throws {
        let filter = try XCTUnwrap(CIFilter(name: "CICode128BarcodeGenerator"))
        filter.setValue(Data("SOULO-12345".utf8), forKey: "inputMessage")
        let code = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let bounds = code.extent.insetBy(dx: -60, dy: -60)
        let white = CIImage(color: .white).cropped(to: bounds)
        let image = try XCTUnwrap(CIContext().createCGImage(code.composited(over: white), from: bounds))
        XCTAssertEqual(try ScannedContent.decodeImage(try XCTUnwrap(UIImage(cgImage: image).pngData())), "SOULO-12345")
    }

    func testExternalDocumentIsCopiedWithoutChangingOriginal() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("External-\(UUID().uuidString).txt")
        let bytes = Data("An original imported document.".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try ExternalDocumentImporter.copyToLibrary(source)
        defer { try? FileManager.default.removeItem(at: imported) }
        XCTAssertNotEqual(imported, source)
        XCTAssertEqual(imported.deletingLastPathComponent(), BookLibrary.directory)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        XCTAssertEqual(try ExternalDocumentImporter.copyToLibrary(imported), imported)
        XCTAssertThrowsError(try ExternalDocumentImporter.copyToLibrary(URL(string: "https://example.com/file.txt")!))
    }

    func testOpeningMoviesIsRegisteredIncludingMatroska() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let types = declarations.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(types.contains("public.movie"))
        XCTAssertTrue(types.contains("org.matroska.mkv"))
        let imported = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let matroska = try XCTUnwrap(imported.first { $0["UTTypeIdentifier"] as? String == "org.matroska.mkv" })
        XCTAssertTrue((matroska["UTTypeConformsTo"] as? [String])?.contains("public.movie") == true)
    }

    func testExternalLargeVideoCanBeImportedWithoutChangingTheOriginal() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("External-\(UUID().uuidString).mkv")
        let header = Data([0x1a, 0x45, 0xdf, 0xa3])
        try header.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let size: UInt64 = 1024 * 1024 * 1024 + 4096
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: size); try writer.close()
        let imported = try ExternalDocumentImporter.copyToLibrary(source)
        defer { try? FileManager.default.removeItem(at: imported) }
        for file in [source, imported] {
            XCTAssertEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(size))
            let reader = try FileHandle(forReadingFrom: file)
            XCTAssertEqual(try reader.read(upToCount: header.count), header)
            try reader.close()
        }
    }

    @MainActor func testContinuousReaderCrossesChaptersAndBoundsLoadedDocuments() async throws {
        let chunks = (0..<12).map { "Chapter \($0)\n" + String(repeating: "Paragraph of original test prose, with a steady rhythm for continuous scrolling.\n", count: 50) }
        let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: "Continuous", fileName: "continuous.txt"))
        let window = try host(BookWebSurface(data: Data(), textData: JSONEncoder().encode(chunks), format: .text, controller: controller))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { controller.ready || controller.error != nil }
        XCTAssertNil(controller.error)
        let web = try XCTUnwrap(controller.webView)
        controller.go("5")
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 5")
        try await Task.sleep(for: .milliseconds(450))
        let count = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents().length") as? Int
        XCTAssertLessThanOrEqual(try XCTUnwrap(count), 5)
        XCTAssertGreaterThan(try XCTUnwrap(count), 1, "Neighboring chapters should already be ready")
        _ = try await web.evaluateJavaScript("""
        (() => {const r = document.querySelector('foliate-view').renderer;
        const section = r.getContents()[0].doc.defaultView.frameElement.closest('.section');
        // Neighbor measurement can adjust the offset after goTo. Cross the
        // actual chapter boundary instead of assuming we are still at its top.
        r.scrollBy(0, section.offsetTop + section.offsetHeight + 100 - section.parentElement.scrollTop); return true;})()
        """)
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 6")
        try await waitJS(web, "document.querySelector('foliate-view').lastLocation?.tocItem?.href === '6'")
        let rawLocation = try await web.evaluateJavaScript("document.querySelector('foliate-view').lastLocation?.cfi") as? String
        let location = try XCTUnwrap(rawLocation)
        XCTAssertTrue(location.hasPrefix("epubcfi("))
        controller.go("1")
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 1")
        controller.go(location)
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 6")
        // Publisher styles on descendants must not prevent reader preferences from applying.
        _ = try await web.evaluateJavaScript("""
        (() => { const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc;
        const p = doc.querySelector('p') || doc.body.appendChild(doc.createElement('p'));
        p.id = 'publisher-font-test'; p.textContent = 'Publisher text 字体测试';
        p.style.cssText = 'font-family: Times; font-size: 12px; line-height: 1'; return true; })()
        """)
        controller.font = "sans"; controller.line = 2
        controller.theme = "dark"; controller.size = 22; controller.style()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(controller.error)
        let font = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('foliate-view').renderer.getContents()[0].doc.body).fontSize") as? String
        XCTAssertEqual(font, "22px")
        let paragraph = try await web.evaluateJavaScript("""
        (() => {const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc;
        const style = doc.defaultView.getComputedStyle(doc.getElementById('publisher-font-test'));
        return {font: style.fontFamily, size: style.fontSize, line: style.lineHeight};})()
        """) as? [String: String]
        XCTAssertTrue(paragraph?["font"]?.contains("PingFang SC") == true)
        XCTAssertEqual(paragraph?["size"], "22px")
        XCTAssertEqual(paragraph?["line"], "44px")
        let attachment = XCTAttachment(image: try await web.takeSnapshot(configuration: nil))
        attachment.name = "continuous-reader-dark"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        // A cold WebKit process can take longer than five seconds to launch.
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for the reader")
        throw URLError(.timedOut)
    }
    @MainActor private func waitJS(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let state = try? await web.evaluateJavaScript("""
        (()=>{const v=document.querySelector('foliate-view'), c=v.renderer.getContents(), s=c[0]?.doc.defaultView.frameElement.parentElement.parentElement.parentElement;
        return JSON.stringify({last:v.lastLocation?.cfi,scroll:s?.scrollTop,contents:c.map(x=>({index:x.index,top:x.doc.defaultView.frameElement.parentElement.parentElement.offsetTop,height:x.doc.defaultView.frameElement.parentElement.parentElement.offsetHeight}))})})()
        """)
        XCTFail("Reader condition did not become true: \(script), state: \(state ?? "none")")
    }
}
