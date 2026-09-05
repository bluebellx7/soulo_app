import XCTest
import SwiftUI
import WebKit
import PDFKit
import AVFoundation
import ZipArchive
@testable import Soulo

final class ReadingToolsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func file(_ name: String, _ data: Data = Data("Soulo 测试 content".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url); return url
    }
    func testTextDecodingAndBoundedChapters() throws {
        let text = "第一章 开始\n" + String(repeating: "这是正文。", count: 20000)
        XCTAssertEqual(try TextBookDecoder.decode(Data(text.utf8)), text)
        XCTAssertEqual(try TextBookDecoder.decode(try XCTUnwrap(text.data(using: .utf16))), text)
        let chunks = TextBookDecoder.chapters(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThan(chunks.map(\.count).max()!, 25000)
        XCTAssertEqual(chunks.joined().trimmingCharacters(in: .newlines), text)
    }
    func testPalmDocBackReferencesAndCorruptInput() throws {
        XCTAssertEqual(try TextBookDecoder.decompressPalm(Array("abc".utf8) + [0x80, 0x18]), Data("abcabc".utf8))
        XCTAssertThrowsError(try TextBookDecoder.decompressPalm([0x80, 0x08]))
        XCTAssertThrowsError(try TextBookDecoder.decompressPalm([8, 1, 2]))
        XCTAssertThrowsError(try TextBookDecoder.palmDoc(Data(repeating: 0, count: 80)))
    }
    func testFormatUsesContentRatherThanFilename() throws {
        XCTAssertEqual(try BookFormat.detect(Data("%PDF-1.7".utf8), extension: "azw4"), .pdf)
        XCTAssertThrowsError(try BookFormat.detect(Data("garbage".utf8), extension: "mobi"))
        var data = Data(repeating: 0, count: 80); data.replaceSubrange(60..<68, with: Data("TEXtREAd".utf8))
        XCTAssertEqual(try BookFormat.detect(data, extension: "prc"), .palmDoc)
    }
    func testArchivePathsRejectTraversalAndConflicts() throws {
        for path in ["../escape", "/absolute", "C:\\file", "ok/../../escape", "a\0b", "./file"] { XCTAssertThrowsError(try FileSafety.relativePath(path), path) }
        XCTAssertEqual(try FileSafety.relativePath("小说/第一章.txt"), "小说/第一章.txt")
        XCTAssertThrowsError(try ArchiveService.validate([.init(path: "A.txt", size: 1, directory: false), .init(path: "a.txt", size: 1, directory: false)]))
        XCTAssertThrowsError(try ArchiveService.validate([.init(path: "large", size: ArchiveService.maximumFileSize + 1, directory: false)]))
    }
    func testZIPAndAESZIPRoundTripAndWrongPassword() throws {
        for password in [nil, "中文 Password 42"] as [String?] {
            let input = try file("original.txt")
            let archive = try ArchiveService.create(files: [input], format: "zip", directory: root, password: password)
            XCTAssertEqual(try ArchiveService.list(archive).map(\.path), [input.lastPathComponent])
            let folder = try ArchiveService.extract(archive, to: root, password: password)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(input.lastPathComponent)), try Data(contentsOf: input))
            if password != nil { XCTAssertThrowsError(try ArchiveService.extract(archive, to: root, password: "wrong")) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        }
    }
    func testSevenZipEncryptedRoundTripAndWrongPassword() throws {
        let input = try file("中文.txt")
        let archive = try ArchiveService.create(files: [input], format: "7z", directory: root, password: "测试-pass")
        XCTAssertThrowsError(try ArchiveService.list(archive, password: "wrong"))
        XCTAssertEqual(try ArchiveService.list(archive, password: "测试-pass").map(\.path), ["中文.txt"])
        let folder = try ArchiveService.extract(archive, to: root, password: "测试-pass")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("中文.txt")), try Data(contentsOf: input))
    }
    func testArchiveCancellationLeavesNoOutput() throws {
        let operation = FileOperationProgress(); operation.progress.cancel()
        let input = try file("original.txt")
        XCTAssertThrowsError(try ArchiveService.create(files: [input], format: "zip", directory: root, operation: operation))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["original.txt"])
    }
    func testZIPRejectsSymlinksAndCorruptCentralDirectory() throws {
        let input = try file("original.txt")
        let archive = try ArchiveService.create(files: [input], format: "zip", directory: root)
        var data = try Data(contentsOf: archive)
        let central = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        data[central.lowerBound + 41] = 0xa0
        XCTAssertThrowsError(try ArchiveService.zipEntries(data))
        XCTAssertThrowsError(try ArchiveService.zipEntries(Data("not a zip".utf8)))
    }
    func testHTTPFramingRejectsAmbiguousRequests() throws {
        let good = try TransferHTTPHead.parse(Data("PUT /file?name=a.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\n".utf8))
        XCTAssertEqual(good.length, 42)
        for headers in ["Content-Length: -1", "Content-Length: 1\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: invalid", "Content-Length: 999999999"] {
            XCTAssertThrowsError(try TransferHTTPHead.parse(Data("PUT /file HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n".utf8)))
        }
    }
    func testWiFiPairUploadDownloadConflictAndTraversal() async throws {
        let server = WiFiTransferServer(directory: root, code: "123456")
        let started = expectation(description: "server starts")
        let portBox = TransferPortBox()
        server.onState = { value, _ in if let value { portBox.set(value); started.fulfill() } }
        try server.start(wifiOnly: false)
        defer { server.stop() }
        await fulfillment(of: [started], timeout: 5)
        let port = portBox.get()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, _ method: String = "GET", _ body: Data? = nil, cookie: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
            req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 5
            if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let result = try await session.data(for: req)
            return (result.0, try XCTUnwrap(result.1 as? HTTPURLResponse))
        }
        let unauthorized = try await request("/files"); XCTAssertEqual(unauthorized.1.statusCode, 401)
        let wrong = try await request("/pair", "POST", Data("000000".utf8)); XCTAssertEqual(wrong.1.statusCode, 403)
        let paired = try await request("/pair", "POST", Data("123456".utf8)); XCTAssertEqual(paired.1.statusCode, 200)
        let cookie = try XCTUnwrap(paired.1.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
        let data = Data((0..<262144).map { UInt8($0 % 251) })
        let upload = try await request("/file?name=hello.txt", "PUT", data, cookie: cookie); XCTAssertEqual(upload.1.statusCode, 201)
        let download = try await request("/file?name=hello.txt", cookie: cookie); XCTAssertEqual(download.0, data)
        let conflict = try await request("/file?name=hello.txt", "PUT", data, cookie: cookie); XCTAssertEqual(conflict.1.statusCode, 409)
        let traversal = try await request("/file?name=..%2Foutside.txt", "PUT", Data(), cookie: cookie); XCTAssertEqual(traversal.1.statusCode, 400)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hello.txt")), data)
    }
    @MainActor func testNovelNavigationRestrictsOriginAndLoops() {
        let source = URL(string: "https://example.com/chapter1")!
        XCTAssertNotNil(ArticleReader.validNext(URL(string: "https://example.com/chapter2"), from: source))
        for value in ["https://other.com/chapter2", "javascript:alert(1)", "https://example.com/chapter1#next", "https://example.com:444/chapter2"] {
            XCTAssertNil(ArticleReader.validNext(URL(string: value), from: source))
        }
    }
    @MainActor func testMediaRejectsInvalidRatesAndReplacesSingleSession() async throws {
        let session = MediaSession.shared
        defer { session.stop() }
        XCTAssertFalse(MediaSession.validRate(.nan)); XCTAssertFalse(MediaSession.validRate(0)); XCTAssertFalse(MediaSession.validRate(17))
        XCTAssertTrue(MediaSession.validRate(16))
        let first = try file("first.wav", Self.wav())
        let second = try file("second.wav", Self.wav())
        let obsolete = session.reservePreparation()
        _ = session.reservePreparation()
        session.open(url: first, reservation: obsolete)
        XCTAssertNotEqual(session.url, first, "An obsolete web request must not claim the player")
        session.open(url: first)
        session.open(url: second)
        try await wait { session.player.currentItem?.status != .unknown }
        XCTAssertEqual(session.url, second)
        XCTAssertEqual(session.player.currentItem?.status, .readyToPlay)
        XCTAssertTrue(session.setRate(1.5)); XCTAssertEqual(session.rate, 1.5)
        session.pause(); XCTAssertEqual(session.player.rate, 0)
        session.seek(.nan); XCTAssertTrue(session.elapsed.isFinite)
        session.stop(); XCTAssertNil(session.player.currentItem)
        session.open(url: first)
        session.pause()
        try await wait { session.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.player.rate, 0, "An interruption while loading must not auto-resume")
    }
    @MainActor func testTXTReaderRendersSearchesAndChangesAppearance() async throws {
        let chunks = ["第一章\nSoulo first chapter " + String(repeating: "Readable text. ", count: 100), "第二章\nThe second chapter has a lighthouse."]
        let book = LibraryBook(id: UUID().uuidString, name: "Test", fileName: "test.txt")
        let controller = BookReaderController(book: book)
        let window = host(BookWebSurface(data: Data(), textData: try JSONEncoder().encode(chunks), format: .text, controller: controller))
        defer { window.isHidden = true }
        try await wait { controller.ready || controller.error != nil }
        XCTAssertNil(controller.error); XCTAssertTrue(controller.ready)
        XCTAssertEqual(controller.toc.count, 2)
        let text = try await controller.webView?.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
        XCTAssertTrue(text?.contains("Soulo first chapter") == true, text ?? "No content")
        controller.go("1")
        try await Task.sleep(for: .milliseconds(300))
        let second = try await controller.webView?.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
        XCTAssertTrue(second?.contains("lighthouse") == true)
        controller.theme = "dark"; controller.size = 24; controller.style()
        controller.search("lighthouse")
        try await wait { !controller.results.isEmpty || controller.error != nil }
        XCTAssertFalse(controller.results.isEmpty)
    }
    @MainActor func testMOBIAndPrintReplicaAndDRMRejection() async throws {
        for variant in ["mobi", "azw4", "protected"] {
            var text = Data("<html><body><h1>Soulo sample</h1><p>Original test content for the local reader.</p></body></html>".utf8)
            if variant == "azw4" {
                let pdf = Self.pdf()
                text = Data(repeating: 0, count: 20); text.replaceSubrange(0..<4, with: Data("%MOP".utf8))
                Self.be32(&text, 12, 20); Self.be32(&text, 16, UInt32(pdf.count)); text.append(pdf)
            }
            let bytes = Self.mobi(text, encrypted: variant == "protected")
            let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: "Sample", fileName: "sample." + variant))
            let window = host(BookWebSurface(data: bytes, textData: nil, format: .mobi, controller: controller))
            defer { window.isHidden = true }
            try await wait { controller.ready || controller.error != nil || controller.replicaPDF != nil }
            if variant == "protected" { XCTAssertTrue(controller.error?.contains("DRM") == true) }
            else if variant == "azw4" { XCTAssertNotNil(controller.replicaPDF.flatMap(PDFDocument.init(data:))) }
            else { XCTAssertNil(controller.error); XCTAssertTrue(controller.ready) }
        }
    }
    @MainActor func testEPUBRendersChaptersAndBlocksBookScripts() async throws {
        let content = root.appendingPathComponent("epub"); try FileManager.default.createDirectory(at: content.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: content.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>".write(to: content.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try "<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='id'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title>Soulo EPUB</dc:title><dc:identifier id='id'>test</dc:identifier><dc:language>en</dc:language></metadata><manifest><item id='c1' href='chapter.xhtml' media-type='application/xhtml+xml'/><item id='nav' href='nav.xhtml' media-type='application/xhtml+xml' properties='nav'/></manifest><spine><itemref idref='c1'/></spine></package>".write(to: content.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter</title></head><body><h1>Soulo EPUB chapter</h1><p>Readable test content.</p><script>parent.bookScriptExecuted = true</script></body></html>".write(to: content.appendingPathComponent("chapter.xhtml"), atomically: true, encoding: .utf8)
        try "<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><ol><li><a href='chapter.xhtml'>First chapter</a></li></ol></nav></body></html>".write(to: content.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        let zip = root.appendingPathComponent("test.epub")
        XCTAssertTrue(SSZipArchive.createZipFile(atPath: zip.path, withContentsOfDirectory: content.path))
        let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: "EPUB", fileName: "test.epub"))
        let window = host(BookWebSurface(data: try Data(contentsOf: zip), textData: nil, format: .epub, controller: controller))
        defer { window.isHidden = true }
        try await wait { controller.ready || controller.error != nil }
        XCTAssertNil(controller.error); XCTAssertTrue(controller.ready)
        XCTAssertEqual(controller.toc.first?.label, "First chapter")
        let executed = try await controller.webView?.evaluateJavaScript("window.bookScriptExecuted === true") as? Bool
        XCTAssertEqual(executed, false)
    }
    func testRAR4RAR5UnicodeEncryptionCRCAndVolumes() throws {
        let bundle = Bundle(for: Self.self)
        for name in ["test", "multibyte", "multibyte.v4", "encrypted", "encrypted-header"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "rar", subdirectory: "ReadingFixtures"))
            let password = name.hasPrefix("encrypted") ? "password" : nil
            let entries = try ArchiveService.list(url, password: password)
            XCTAssertFalse(entries.isEmpty, name)
            let extracted = try ArchiveService.extract(url, to: root, password: password)
            for entry in entries where !entry.directory {
                XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(entry.path)).count, Int(entry.size), name)
            }
            if password != nil { XCTAssertThrowsError(try ArchiveService.extract(url, to: root, password: "wrong")) }
        }
        for name in ["badcrc", "volumes.part1"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "rar", subdirectory: "ReadingFixtures"))
            XCTAssertThrowsError(try ArchiveService.extract(url, to: root))
        }
    }
    @MainActor func testRealKF8AndHuffDicAndPalmDocSamples() async throws {
        for name in ["sample-obfuscated-fonts", "sample-unicode-huffdic", "sample-textread"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mobi", subdirectory: "ReadingFixtures"))
            let data = try Data(contentsOf: url)
            let format = try BookFormat.detect(data, extension: "mobi")
            if format == .palmDoc {
                let text = try TextBookDecoder.palmDoc(data)
                XCTAssertGreaterThan(text.count, 1000)
                continue
            }
            let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: name, fileName: name + ".azw3"))
            let window = host(BookWebSurface(data: data, textData: nil, format: format, controller: controller))
            defer { window.isHidden = true }
            try await wait { controller.ready || controller.error != nil }
            XCTAssertNil(controller.error, name); XCTAssertTrue(controller.ready, name)
            let text = try await controller.webView?.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.body.textContent") as? String
            XCTAssertFalse(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, name)
        }
    }
    @MainActor func testArticleExtractionSanitizesAndPreservesOriginalPage() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let paragraph = String(repeating: "这是用于验证阅读模式的原创测试文章，段落需要有足够内容。", count: 30)
        webView.loadHTMLString("<html><head><title>Soulo article</title></head><body><article><h1>Article title</h1><p>" + paragraph + "</p><p onclick='alert(1)'>" + paragraph + "</p><form><input value='private'></form><script>window.original = true</script></article><a rel='next' href='/chapter2'>下一章</a></body></html>", baseURL: URL(string: "https://reader.test/chapter1"))
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("document.querySelectorAll('article p').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let article: ReaderArticle
        do { article = try await ArticleReader.extract(webView) }
        catch { let e = error as NSError; XCTFail("Article extraction: \(e.domain) \(e.code) \(e.userInfo)"); return }
        XCTAssertTrue(article.text.contains("原创测试文章"))
        XCTAssertFalse(article.html.contains("onclick")); XCTAssertFalse(article.html.contains("<form")); XCTAssertFalse(article.html.contains("<script"))
        XCTAssertEqual(article.next?.absoluteString, "https://reader.test/chapter2")
        let untouched = try await webView.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(untouched, "private")
    }
    @MainActor func testBookshelfDeduplicatesRestoresProgressAndFollowsMovedFiles() async throws {
        let metadata = root.appendingPathComponent("shelf.json")
        let library = BookLibrary(metadata: metadata)
        let input = try file("Soulo-test-" + UUID().uuidString + ".txt")
        let book = try await library.add(input)
        defer { try? FileManager.default.removeItem(at: book.url) }
        let duplicate = try await library.add(input)
        XCTAssertEqual(duplicate.id, book.id); XCTAssertEqual(library.books.count, 1)
        library.update(book.id, location: "epubcfi(/6/2!/4/2)", fraction: 0.4)
        library.bookmark(book.id); library.bookmark(book.id)
        let restored = BookLibrary(metadata: metadata)
        XCTAssertEqual(restored.books.first?.fraction, 0.4)
        XCTAssertEqual(restored.books.first?.bookmarks.count, 1)
        let moved = BookLibrary.directory.appendingPathComponent("moved-" + UUID().uuidString + ".txt")
        try FileManager.default.moveItem(at: book.url, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        XCTAssertEqual(book.url.standardizedFileURL, moved.standardizedFileURL)
    }
    @MainActor func testNativePlaybackActuallyAdvancesAtSupportedRates() async throws {
        let session = MediaSession.shared
        let old = session.rate
        defer { session.setRate(old); session.stop() }
        var wav = Self.wav(); wav.append(Data(repeating: 0, count: 44100 * 2 * 19))
        func le(_ value: UInt32, offset: Int) { for i in 0..<4 { wav[offset+i] = UInt8((value >> (i*8)) & 255) } }
        le(UInt32(wav.count - 8), offset: 4); le(UInt32(wav.count - 44), offset: 40)
        let url = try file("rates.wav", wav)
        session.open(url: url)
        try await wait { session.player.currentItem?.status == .readyToPlay }
        for rate: Float in [0.5, 1, 2, 4, 8, 16] {
            await session.player.seek(to: .zero)
            let accepted = session.setRate(rate)
            if !accepted { XCTAssertGreaterThan(rate, 2); print("MEDIA_RATE \(rate): unavailable for this asset; UI rejects it"); continue }
            session.play()
            // Readiness is not the same as starting playback: exclude audio-route
            // warm-up before measuring the actual clock advancement.
            try await wait { session.player.timeControlStatus == .playing && session.player.currentTime().seconds > 0 }
            let start = session.player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(250))
            let elapsed = session.player.currentTime().seconds - start
            XCTAssertGreaterThan(elapsed, Double(rate) * 0.1, "Rate \(rate) did not advance")
            XCTAssertEqual(session.player.rate, rate)
            print("MEDIA_RATE \(rate): elapsed=\(elapsed) in 0.25 s, actual rate=\(session.player.rate)")
            session.pause()
        }
    }
    @MainActor func testHTMLMediaRatesUseActualElementValues() async throws {
        let web = WKWebView()
        web.loadHTMLString("<video id='v'></video><audio></audio>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.querySelectorAll('video,audio').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        for rate in [0.5, 2, 8, 16] {
            let result = try await WebMediaPlaybackBridge.setRate(rate, on: web)
            XCTAssertEqual(result, [rate, rate])
        }
        do { _ = try await WebMediaPlaybackBridge.setRate(99, on: web); XCTFail("Reject out-of-range speed") } catch {}
    }
    @MainActor func testPDFSearchAndPageNavigation() async throws {
        let pdf = Self.pdf()
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.findString("Soulo", withOptions: [.caseInsensitive]).count, 1)
        let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: "PDF", fileName: "sample.pdf"))
        let window = host(PDFBookSurface(data: pdf, controller: controller)); defer { window.isHidden = true }
        try await wait { controller.pdfView != nil }
        controller.search("Soulo"); XCTAssertFalse(controller.results.isEmpty)
        controller.go("0"); XCTAssertNotNil(controller.pdfView?.currentPage)
    }
    @MainActor func testFloatingPlayerPreservesDirectoryNavigation() async throws {
        final class Route: ObservableObject { @Published var directory = false }
        struct Harness: View {
            @ObservedObject var route: Route
            var body: some View {
                NavigationStack {
                    Text("Root")
                        .mediaPlayerNavigation()
                        .navigationDestination(isPresented: $route.directory) {
                            Text("Directory").navigationTitle("Directory").mediaPlayerNavigation()
                        }
                }
            }
        }
        func navigation(in controller: UIViewController?) -> UINavigationController? {
            guard let controller else { return nil }
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.compactMap { navigation(in: $0) }.first
        }
        let route = Route()
        let window = host(Harness(route: route))
        defer { window.isHidden = true; MediaSession.shared.expanded = false }
        try await wait { navigation(in: window.rootViewController) != nil }
        let nav = try XCTUnwrap(navigation(in: window.rootViewController))
        route.directory = true
        try await wait { nav.viewControllers.count == 2 && nav.transitionCoordinator == nil }
        let directory = try XCTUnwrap(nav.topViewController)
        MediaSession.shared.expanded = true
        try await wait { nav.viewControllers.count == 3 && nav.transitionCoordinator == nil }
        XCTAssertTrue(nav.viewControllers[1] === directory, "Opening the player must retain the directory")
        XCTAssertTrue(route.directory)
        nav.popViewController(animated: false)
        try await wait { nav.viewControllers.count == 2 }
        XCTAssertTrue(nav.topViewController === directory)
    }

    @MainActor private func host<V: View>(_ view: V) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: view); window.makeKeyAndVisible(); window.layoutIfNeeded()
        return window
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("Timed out waiting for reading tool state")
    }
    static func be32(_ data: inout Data, _ offset: Int, _ value: UInt32) { for i in 0..<4 { data[offset+i] = UInt8((value >> ((3-i)*8)) & 255) } }
    static func mobi(_ text: Data, encrypted: Bool = false) -> Data {
        var data = Data(repeating: 0, count: 96)
        data.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8)); data[77] = 2
        be32(&data, 78, 96); be32(&data, 86, 352)
        var header = Data(repeating: 0, count: 256)
        header[1] = 1; header[9] = 1; header[10] = 16; header[13] = encrypted ? 2 : 0
        be32(&header, 4, UInt32(text.count)); header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        be32(&header, 20, 232); be32(&header, 24, 2); be32(&header, 28, 65001); be32(&header, 36, 6)
        be32(&header, 84, 248); be32(&header, 88, 5); be32(&header, 108, 2); be32(&header, 244, UInt32.max)
        header.replaceSubrange(248..<253, with: Data("Soulo".utf8)); data.append(header); data.append(text); return data
    }
    @MainActor static func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { context in
            context.beginPage(); ("Soulo PDF sample" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
    }
    static func wav() -> Data {
        let count: UInt32 = 44100 * 2
        var data = Data("RIFF".utf8)
        func le(_ number: UInt32) -> Data { var n = number.littleEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        data.append(le(36 + count)); data.append(Data("WAVEfmt ".utf8)); data.append(le(16))
        data.append(contentsOf: [1,0,1,0]); data.append(le(44100)); data.append(le(88200)); data.append(contentsOf: [2,0,16,0]); data.append(Data("data".utf8)); data.append(le(count)); data.append(Data(repeating: 0, count: Int(count))); return data
    }
}

private final class TransferPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16 = 0
    func set(_ value: UInt16) { lock.lock(); port = value; lock.unlock() }
    func get() -> UInt16 { lock.lock(); defer { lock.unlock() }; return port }
}
