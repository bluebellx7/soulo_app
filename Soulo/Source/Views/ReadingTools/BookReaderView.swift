import PDFKit
import SwiftUI
import WebKit

struct ReaderLink: Identifiable {
    var id: String { href }
    let label: String
    let href: String
}
@MainActor final class BookReaderController: ObservableObject {
    @Published var toc: [ReaderLink] = []
    @Published var results: [ReaderLink] = []
    @Published var searched = false
    @Published var error: String?
    @Published var ready = false
    @Published var replicaPDF: Data?
    weak var webView: WKWebView?
    weak var pdfView: PDFView?
    var book: LibraryBook
    var size = 18.0, line = 1.6, theme = "paper", font = "serif"
    init(book: LibraryBook) { self.book = book }
    func command(_ name: String, _ args: [Any] = []) {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
            let json = String(data: data, encoding: .utf8)
        else { return }
        webView?.evaluateJavaScript("window.soulo.\(name)(...\(json)); null;", completionHandler: nil)
    }
    func style() { command("style", [size, line, theme, font]) }
    func go(_ href: String) {
        if let pdfView, let index = Int(href), let page = pdfView.document?.page(at: index) {
            pdfView.go(to: page)
        } else {
            command("go", [href])
        }
    }
    func search(_ query: String) {
        searched = true
        if let pdfView, let document = pdfView.document {
            let matches = document.findString(query, withOptions: [.caseInsensitive])
            results = matches.prefix(100).compactMap { selection in
                guard let page = selection.pages.first else { return nil }
                return ReaderLink(label: selection.string ?? query, href: String(document.index(for: page)))
            }
            if let first = matches.first {
                pdfView.setCurrentSelection(first, animate: true)
                pdfView.go(to: first)
            }
        } else {
            command("search", [query])
        }
    }
}

struct BookReaderView: View {
    let book: LibraryBook
    @StateObject private var controller: BookReaderController
    @State private var data: Data?
    @State private var textData: Data?
    @State private var format: BookFormat?
    @State private var showContents = false
    @State private var showStyle = false
    @State private var query = ""
    @State private var encoding = "auto"
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.font") private var font = "serif"
    @AppStorage("reader.lineHeight") private var lineHeight = 1.6
    @AppStorage("reader.theme") private var theme = "paper"
    @ObservedObject private var library = BookLibrary.shared
    init(book: LibraryBook) {
        self.book = book
        _controller = StateObject(wrappedValue: BookReaderController(book: book))
    }
    var body: some View {
        Group {
            if let error = controller.error {
                ContentUnavailableView {
                    Label(ToolText.text("reading_failed"), systemImage: "book.closed")
                } description: {
                    Text(error)
                } actions: {
                    Button(ToolText.text("retry")) {
                        controller.error = nil
                        Task { await prepare() }
                    }
                }
            } else if let pdf = controller.replicaPDF {
                PDFBookSurface(data: pdf, controller: controller)
            } else if let data, let format {
                if format == .pdf {
                    PDFBookSurface(data: data, controller: controller)
                } else {
                    BookWebSurface(data: data, textData: textData, format: format, controller: controller)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .mediaPlayerNavigation()
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    showContents = true
                } label: {
                    Image(systemName: "list.bullet").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }.accessibilityLabel(ToolText.text("contents"))
                Spacer()
                Button {
                    if let pdf = controller.pdfView { pdf.goToPreviousPage(nil) } else { controller.command("prev") }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
                Button {
                    if let pdf = controller.pdfView { pdf.goToNextPage(nil) } else { controller.command("next") }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
                Spacer()
                Button {
                    library.bookmark(book.id)
                } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }.accessibilityLabel(ToolText.text("bookmark"))
                Button {
                    showStyle = true
                } label: {
                    Image(systemName: "textformat.size").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }.accessibilityLabel(ToolText.text("appearance"))
            }
        }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                List {
                    Section(ToolText.text("search")) {
                        TextField(ToolText.text("search_book"), text: $query).onSubmit { controller.search(query) }
                        if controller.searched && controller.results.isEmpty {
                            Text(ToolText.text("search_empty")).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(Array(controller.results.enumerated()), id: \.offset) { _, link in
                            Button(link.label) {
                                controller.go(link.href)
                                showContents = false
                            }
                        }
                    }
                    Section(ToolText.text("bookmarks")) {
                        ForEach(library.books.first(where: { $0.id == book.id })?.bookmarks ?? []) { mark in
                            Button(mark.label) {
                                controller.go(mark.location)
                                showContents = false
                            }
                        }
                    }
                    Section(ToolText.text("contents")) {
                        ForEach(Array(controller.toc.enumerated()), id: \.offset) { _, link in
                            Button(link.label) {
                                controller.go(link.href)
                                showContents = false
                            }
                        }
                    }
                }.navigationTitle(ToolText.text("contents"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { showContents = false } } }
            }
        }
        .sheet(isPresented: $showStyle) {
            NavigationStack {
                Form {
                    LabeledContent(ToolText.text("font_size"), value: Int(fontSize).formatted())
                    Slider(value: $fontSize, in: 14...36, step: 1) { Text(ToolText.text("font_size")) }
                    LabeledContent(ToolText.text("line_height"), value: lineHeight.formatted())
                    Slider(value: $lineHeight, in: 1.2...2.4, step: 0.1) { Text(ToolText.text("line_height")) }
                    Picker(ToolText.text("font"), selection: $font) {
                        ForEach(["serif", "sans", "mono"], id: \.self) { Text(ToolText.text($0)).tag($0) }
                    }
                    Picker(ToolText.text("appearance"), selection: $theme) {
                        Text(ToolText.text("paper")).tag("paper")
                        Text(ToolText.text("light")).tag("light")
                        Text(ToolText.text("dark")).tag("dark")
                    }.pickerStyle(.segmented)
                    if format == .text || format == .palmDoc {
                        Picker(ToolText.text("encoding"), selection: $encoding) {
                            ForEach(["auto", "UTF-8", "UTF-16", "GB18030", "Big5", "Shift-JIS"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    }
                }.navigationTitle(ToolText.text("appearance"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { showStyle = false } } }
            }.presentationDetents([.medium, .large])
        }
        .onChange(of: font) { _, _ in updateStyle() }
        .onChange(of: fontSize) { _, _ in updateStyle() }
        .onChange(of: lineHeight) { _, _ in updateStyle() }
        .onChange(of: theme) { _, _ in updateStyle() }
        .onChange(of: encoding) { _, _ in
            data = nil
            Task { await prepare() }
        }
        .task { await prepare() }
    }
    private var isBookmarked: Bool {
        guard let current = library.books.first(where: { $0.id == book.id }) else { return false }
        return current.bookmarks.contains { $0.location == current.location }
    }
    private func updateStyle() {
        controller.font = font
        controller.size = fontSize
        controller.line = lineHeight
        controller.theme = theme
        controller.style()
    }
    private func prepare() async {
        updateStyle()
        let selectedEncoding = encoding
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: book.url, options: .mappedIfSafe)
                guard data.count <= 128 * 1024 * 1024 else { throw ReadingToolError.limit }
                let format = try BookFormat.detect(data, extension: book.url.pathExtension)
                var text: Data?
                if format == .text || format == .palmDoc {
                    let string =
                        try format == .palmDoc
                        ? TextBookDecoder.palmDoc(data) : TextBookDecoder.decode(data, encoding: selectedEncoding)
                    text = try JSONEncoder().encode(TextBookDecoder.chapters(string))
                }
                return (data, format, text)
            }.value
            guard !Task.isCancelled else { return }
            data = result.0
            format = result.1
            textData = result.2
        } catch { controller.error = error.localizedDescription }
    }
}

struct BookWebSurface: UIViewRepresentable {
    let data: Data
    let textData: Data?
    let format: BookFormat
    let controller: BookReaderController
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "soulo-book")
        config.userContentController.add(context.coordinator, name: "book")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        controller.webView = view
        view.load(URLRequest(url: URL(string: "soulo-book://reader/index")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "book")
    }
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: BookWebSurface
        init(_ parent: BookWebSurface) { self.parent = parent }
        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.host == "reader" else {
                urlSchemeTask.didFailWithError(ReadingToolError.unsafePath)
                return
            }
            let data: Data
            let mime: String
            switch url.path {
            case "/book":
                data = parent.data
                mime = "application/octet-stream"
            case "/text":
                data = parent.textData ?? Data("[]".utf8)
                mime = "application/json"
            case "/engine.js":
                guard let resource = Bundle.main.url(forResource: "SouloBookEngine", withExtension: "js"),
                    let source = try? Data(contentsOf: resource)
                else {
                    urlSchemeTask.didFailWithError(ReadingToolError.invalid)
                    return
                }
                data = source
                mime = "text/javascript"
            case "/index":
                data = Data(
                    """
                    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta charset="utf-8">
                    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src soulo-book: 'unsafe-eval'; style-src 'unsafe-inline' blob:; img-src blob: data:; font-src blob: data:; connect-src soulo-book: blob:; frame-src blob:;">
                    <style>html,body{margin:0;height:100%;overflow:hidden}foliate-view{display:block;height:100%;width:100%}</style></head><body><script src="soulo-book://reader/engine.js"></script></body></html>
                    """.utf8)
                mime = "text/html"
            default:
                urlSchemeTask.didFailWithError(ReadingToolError.unsafePath)
                return
            }
            urlSchemeTask.didReceive(
                URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                let type = body["type"] as? String
            else { return }
            let controller = parent.controller
            switch type {
            case "boot": controller.command("open", [parent.format.rawValue, controller.book.location])
            case "ready":
                controller.ready = true
                controller.toc = links(body["toc"])
                controller.style()
            case "search": controller.results = links(body["results"])
            case "location":
                if let location = body["location"] as? String, let fraction = body["fraction"] as? Double {
                    BookLibrary.shared.update(controller.book.id, location: location, fraction: fraction)
                }
            case "cover":
                if let encoded = body["data"] as? String, encoded.count < 6_000_000,
                    let bytes = Data(base64Encoded: encoded)
                {
                    BookLibrary.shared.storeCover(controller.book.id, data: bytes)
                }
            case "pdf":
                if let encoded = body["data"] as? String, encoded.count <= 180_000_000,
                    let pdf = Data(base64Encoded: encoded), pdf.starts(with: Array("%PDF-".utf8))
                {
                    controller.replicaPDF = pdf
                } else {
                    controller.error = ToolText.text("invalid_file")
                }
            case "error": controller.error = body["message"] as? String ?? ToolText.text("invalid_file")
            default: break
            }
        }
        private func links(_ value: Any?) -> [ReaderLink] {
            (value as? [[String: Any]] ?? []).compactMap { item in
                guard let href = item["href"] as? String else { return nil }
                return ReaderLink(label: item["label"] as? String ?? href, href: href)
            }
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                ["soulo-book", "blob", "about"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.controller.error = ToolText.text("reading_failed")
        }
    }
}

struct PDFBookSurface: UIViewRepresentable {
    let data: Data
    let controller: BookReaderController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        guard let document = PDFDocument(data: data), !document.isLocked else {
            controller.error = ToolText.text("protected_file")
            return view
        }
        if let cover = document.page(at: 0)?.thumbnail(of: CGSize(width: 180, height: 260), for: .mediaBox).jpegData(
            compressionQuality: 0.8)
        {
            BookLibrary.shared.storeCover(controller.book.id, data: cover)
        }
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        controller.pdfView = view
        if let index = Int(controller.book.location), let page = document.page(at: index) { view.go(to: page) }
        func outline(_ item: PDFOutline?) -> [ReaderLink] {
            guard let item else { return [] }
            var result: [ReaderLink] = []
            if let page = item.destination?.page {
                result.append(ReaderLink(label: item.label ?? "", href: String(document.index(for: page))))
            }
            for i in 0..<item.numberOfChildren { result += outline(item.child(at: i)) }
            return result
        }
        controller.toc = outline(document.outlineRoot)
        if controller.toc.isEmpty {
            controller.toc = (0..<document.pageCount).map { ReaderLink(label: String($0 + 1), href: String($0)) }
        }
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.pageChanged(_:)), name: .PDFViewPageChanged,
            object: view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
    @MainActor final class Coordinator: NSObject {
        let controller: BookReaderController
        init(_ controller: BookReaderController) { self.controller = controller }
        @objc func pageChanged(_ event: Notification) {
            guard let view = event.object as? PDFView, let document = view.document, let page = view.currentPage else {
                return
            }
            let index = document.index(for: page)
            BookLibrary.shared.update(
                controller.book.id, location: String(index),
                fraction: Double(index) / Double(max(1, document.pageCount - 1)))
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
