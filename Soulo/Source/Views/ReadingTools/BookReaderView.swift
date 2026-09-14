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
    @Published var controlsVisible = false
    @Published var fraction = 0.0
    @Published var title = ""
    weak var webView: WKWebView?
    weak var pdfView: PDFView?
    var book: LibraryBook
    var onBack: (() -> Void)?
    var size = 18.0, line = 1.6, theme = "paper", font = "serif"
    init(book: LibraryBook) { self.book = book }
    func command(_ name: String, _ args: [Any] = []) {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
            let json = String(data: data, encoding: .utf8)
        else { return }
        webView?.evaluateJavaScript("window.soulo.\(name)(...\(json)); null;", completionHandler: nil)
    }
    func seek(_ fraction: Double) {
        if let pdfView, let document = pdfView.document {
            let index = Int((fraction * Double(max(0, document.pageCount - 1))).rounded())
            if let page = document.page(at: index) { pdfView.go(to: page) }
        } else { command("fraction", [fraction]) }
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
    @State private var contentsPresentation: ReaderContentsPresentation?
    @State private var showStyle = false
    @State private var showBrightness = false
    @State private var showFileInfo = false
    @State private var pdfZoom = 1.0
    @State private var fileBytes: Int64 = 0
    @State private var fileModified: Date?
    @State private var seekPosition = 0.0
    @State private var isSeeking = false
    @State private var brightness = UIScreen.main.brightness
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        GeometryReader { geometry in
            readerContent
                .frame(width: geometry.size.width,
                    height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
                .offset(y: -geometry.safeAreaInsets.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(readerBackground.ignoresSafeArea())
        .overlay(alignment: .top) {
            if controller.controlsVisible || controller.error != nil {
                readerHeader.transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if controller.controlsVisible {
                readerFooter.transition(.opacity)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar, .bottomBar)
        .statusBarHidden(true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controller.controlsVisible)
        .accessibilityAction(named: Text(ToolText.text("appearance"))) { controller.controlsVisible.toggle() }
        .accessibilityAction(.escape) { dismiss() }
        .onChange(of: controller.fraction) { _, fraction in if !isSeeking { seekPosition = fraction } }
        .sheet(item: $contentsPresentation) { mode in
            ReaderContentsSheet(controller: controller, query: $query, mode: mode)
        }
        .sheet(isPresented: $showStyle) {
            NavigationStack {
                Form {
                    if isPDF {
                        LabeledContent(ToolText.text("page_zoom"), value: pdfZoom.formatted(.percent.precision(.fractionLength(0))))
                        Slider(value: $pdfZoom, in: 1...3, step: 0.1) { Text(ToolText.text("page_zoom")) }
                            .onChange(of: pdfZoom) { _, value in
                                guard let view = controller.pdfView else { return }
                                view.autoScales = false
                                view.scaleFactor = view.scaleFactorForSizeToFit * value
                            }
                        Text(ToolText.text("pdf_fixed_layout")).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        LabeledContent(ToolText.text("font_size"), value: Int(fontSize).formatted())
                        Slider(value: $fontSize, in: 14...36, step: 1) { Text(ToolText.text("font_size")) }
                        LabeledContent(ToolText.text("line_height"), value: lineHeight.formatted())
                        Slider(value: $lineHeight, in: 1.2...2.4, step: 0.1) { Text(ToolText.text("line_height")) }
                        Picker(ToolText.text("font"), selection: $font) {
                            ForEach(["serif", "sans", "mono"], id: \.self) { Text(ToolText.text($0)).tag($0) }
                        }
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
        .sheet(isPresented: $showBrightness) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "sun.min")
                    Slider(value: $brightness, in: 0.05...1)
                        .accessibilityLabel(ToolText.text("appearance"))
                        .onChange(of: brightness) { _, value in UIScreen.main.brightness = value }
                    Image(systemName: "sun.max")
                }
                themePicker
            }
            .padding(28)
            .presentationDetents([.height(190)])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: font) { _, _ in updateStyle() }
        .onChange(of: fontSize) { _, _ in updateStyle() }
        .onChange(of: lineHeight) { _, _ in updateStyle() }
        .onChange(of: theme) { _, _ in updateStyle() }
        .onChange(of: encoding) { _, _ in
            data = nil
            Task { await prepare() }
        }
        .sheet(isPresented: $showFileInfo) { fileInfoSheet }
        .onAppear {
            let action = dismiss
            controller.onBack = { action() }
        }
        .task { await prepare() }
        .onDisappear { library.flushReadingProgress(); controller.onBack = nil }

    }
    private var isPDF: Bool { format == .pdf || controller.replicaPDF != nil }
    @ViewBuilder private var readerContent: some View {
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
                pdfSurface(pdf)
            } else if let data, let format {
                if format == .pdf {
                    pdfSurface(data)
                } else {
                    BookWebSurface(data: data, textData: textData, format: format, controller: controller)
                }
            } else {
                ProgressView()
            }
        }
    }
    private func pdfSurface(_ bytes: Data) -> some View {
        PDFBookSurface(data: bytes, controller: controller)
            .overlay {
                if theme == "dark" { Color.white.blendMode(.difference).allowsHitTesting(false) }
            }
            .compositingGroup()
            .colorMultiply(theme == "paper" ? readerBackground : .white)
    }
    private var fileInfoSheet: some View {
        NavigationStack {
            Form {
                Section(ToolText.text("file_name")) {
                    Text(book.url.lastPathComponent).textSelection(.enabled)
                }
                LabeledContent(ToolText.text("format"), value: book.url.pathExtension.uppercased())
                LabeledContent(ToolText.text("file_size"), value: ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file))
                if let fileModified {
                    LabeledContent(ToolText.text("file_modified"), value: fileModified.formatted(date: .abbreviated, time: .shortened))
                }
                if let count = controller.pdfView?.document?.pageCount {
                    LabeledContent(ToolText.text("file_pages"), value: count.formatted())
                }
            }
            .navigationTitle(ToolText.text("file_info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { showFileInfo = false } } }
            .task {
                let url = book.url
                let values = try? await Task.detached(priority: .utility) {
                    try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                }.value
                fileBytes = Int64(values?.fileSize ?? data?.count ?? 0)
                fileModified = values?.contentModificationDate
            }
        }.presentationDetents([.medium, .large])
    }
    private var readerBackground: Color {
        switch theme {
        case "dark": Color(red: 0.09, green: 0.10, blue: 0.09)
        case "light": .white
        default: Color(red: 0.965, green: 0.945, blue: 0.906)
        }
    }
    private var readerForeground: Color { theme == "dark" ? Color.white.opacity(0.85) : Color.black.opacity(0.78) }
    private var readerHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(ToolText.text("close"))
                .accessibilityIdentifier("reader.back")
            Text(controller.title.isEmpty ? book.name : controller.title)
                .font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ShareLink(item: book.url) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel(ToolText.text("share"))
                .accessibilityIdentifier("reader.share")
            Menu {
                Button(ToolText.text("contents"), systemImage: "list.bullet") { contentsPresentation = .contents }
                Button(ToolText.text("file_info"), systemImage: "info.circle") { showFileInfo = true }
                Button(ToolText.text("appearance"), systemImage: "textformat.size") { showStyle = true }
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
                .accessibilityIdentifier("reader.more")
        }
        .buttonStyle(ReaderControlStyle())
        .foregroundStyle(readerForeground)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(readerBackground.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }
    private var readerFooter: some View {
        VStack(spacing: 14) {
            HStack {
                Text(ToolText.text("continuous_reading")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(controller.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $seekPosition, in: 0...1, onEditingChanged: { editing in
                isSeeking = editing
                if !editing { controller.seek(seekPosition) }
            })
            .accessibilityLabel(ToolText.text("continuous_reading"))
            .accessibilityIdentifier("reader.progress")
            HStack {
                Button { contentsPresentation = .contents } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel(ToolText.text("contents"))
                    .accessibilityIdentifier("reader.contents")
                Spacer()
                Button { contentsPresentation = .search } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(ToolText.text("search_book"))
                    .accessibilityIdentifier("reader.search")
                Spacer()
                Button { brightness = UIScreen.main.brightness; showBrightness = true } label: { Image(systemName: "sun.max") }
                    .accessibilityLabel(ToolText.text("appearance"))
                Spacer()
                Button { showStyle = true } label: { Image(systemName: isPDF ? "slider.horizontal.3" : "textformat.size") }
                    .accessibilityLabel(ToolText.text("appearance"))
                    .accessibilityIdentifier("reader.style")
            }
            .font(.system(size: 21, weight: .regular))
        }
        .buttonStyle(ReaderControlStyle())
        .foregroundStyle(readerForeground)
        .tint(theme == "dark" ? Color.white.opacity(0.75) : Color.black.opacity(0.6))
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background(readerBackground.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Divider().opacity(0.3) }
    }
    private var themePicker: some View {
        HStack(spacing: 16) {
            ForEach(["light", "paper", "dark"], id: \.self) { value in
                Button { theme = value } label: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(value == "dark" ? Color.black : value == "light" ? Color.white : Color(red: 0.965, green: 0.945, blue: 0.906))
                        .frame(height: 48)
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme == value ? Color.blue : Color.gray.opacity(0.3), lineWidth: theme == value ? 2 : 1) }
                }.accessibilityLabel(ToolText.text(value))
            }
        }
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

private enum ReaderContentsPresentation: String, Identifiable {
    case contents, search
    var id: String { rawValue }
}

/// Focus belongs to the presented sheet's view hierarchy, rather than the reader behind it.
private struct ReaderContentsSheet: View {
    @ObservedObject var controller: BookReaderController
    @Binding var query: String
    let mode: ReaderContentsPresentation
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if mode == .search {
                    Section(ToolText.text("search")) {
                        TextField(ToolText.text("search_book"), text: $query)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .onSubmit { controller.search(query) }
                            .task { searchFocused = true }
                        if controller.searched && controller.results.isEmpty {
                            Text(ToolText.text("search_empty")).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(Array(controller.results.enumerated()), id: \.offset) { _, link in
                            Button(link.label) { controller.go(link.href); dismiss() }
                        }
                    }
                } else {
                    Section(ToolText.text("contents")) {
                        ForEach(Array(controller.toc.enumerated()), id: \.offset) { _, link in
                            Button(link.label) { controller.go(link.href); dismiss() }
                        }
                    }
                }
            }
            .accessibilityIdentifier(mode == .search ? "reader.searchPage" : "reader.contentsPage")
            .navigationTitle(ToolText.text(mode == .search ? "search" : "contents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { dismiss() } } }
        }
    }
}

private struct ReaderControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.45 : 1)
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
        let view = SelectionSearchWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleControls(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let back = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeBack(_:)))
        back.edges = .left
        view.addGestureRecognizer(back)
        view.scrollView.panGestureRecognizer.require(toFail: back)
        view.scrollView.contentInsetAdjustmentBehavior = .never
        controller.webView = view
        view.load(URLRequest(url: URL(string: "soulo-book://reader/index")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "book")
    }
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {
        let parent: BookWebSurface
        init(_ parent: BookWebSurface) { self.parent = parent }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func swipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended, gesture.translation(in: gesture.view).x > 70 else { return }
            parent.controller.onBack?()
        }
        @objc func toggleControls(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, parent.controller.ready, let web = gesture.view as? WKWebView else { return }
            let point = gesture.location(in: web)
            guard point.x > web.bounds.width * 0.18, point.x < web.bounds.width * 0.82,
                  point.y > web.bounds.height * 0.2, point.y < web.bounds.height * 0.8 else { return }
            // Native recognition also works in sandboxed chapter frames, where
            // WebKit suppresses DOM click handlers. Keep text selection intact.
            web.evaluateJavaScript("window.soulo.canToggleAt(\(point.x), \(point.y))") { [weak self] value, _ in
                guard value as? Bool == true else { return }
                self?.parent.controller.controlsVisible.toggle()
            }
        }
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
                controller.title = body["title"] as? String ?? ""
                BookLibrary.shared.updateTitle(controller.book.id, title: controller.title)
                controller.toc = links(body["toc"])
                controller.style()
            case "toggleControls": controller.controlsVisible.toggle()
            case "scroll": if controller.controlsVisible { controller.controlsVisible = false }
            case "search": controller.results = links(body["results"])
            case "location":
                if let location = body["location"] as? String, let fraction = body["fraction"] as? Double {
                    controller.fraction = fraction
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
        let view = SelectionSearchPDFView()
        view.accessibilityIdentifier = "reader.pdf"
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
        view.backgroundColor = .white
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleControls(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let back = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeBack(_:)))
        back.edges = .left
        view.addGestureRecognizer(back)
        func configureScrolling(_ child: UIView) {
            if let scroll = child as? UIScrollView {
                scroll.contentInsetAdjustmentBehavior = .never
                scroll.panGestureRecognizer.require(toFail: back)
                scroll.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.scrolled(_:)))
            }
            child.subviews.forEach(configureScrolling)
        }
        configureScrolling(view)
        controller.ready = true
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
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: BookReaderController
        init(_ controller: BookReaderController) { self.controller = controller }
        @objc func swipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended, gesture.translation(in: gesture.view).x > 70 else { return }
            controller.onBack?()
        }
        @objc func toggleControls(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PDFView, view.currentSelection == nil else { return }
            let point = gesture.location(in: view)
            if point.x > view.bounds.width * 0.18 && point.x < view.bounds.width * 0.82 && point.y > view.bounds.height * 0.2 && point.y < view.bounds.height * 0.8 {
                controller.controlsVisible.toggle()
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        @objc func scrolled(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .changed && controller.controlsVisible { controller.controlsVisible = false }
        }
        @objc func pageChanged(_ event: Notification) {
            guard let view = event.object as? PDFView, let document = view.document, let page = view.currentPage else {
                return
            }
            let index = document.index(for: page)
            controller.fraction = Double(index) / Double(max(1, document.pageCount - 1))
            BookLibrary.shared.update(
                controller.book.id, location: String(index),
                fraction: Double(index) / Double(max(1, document.pageCount - 1)))
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
