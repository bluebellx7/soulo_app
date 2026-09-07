import SwiftUI
import WebKit

struct ArticleReaderView: View {
    let source: WKWebView
    @StateObject private var reader = ArticleReader()
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.fontSize") private var size = 18.0
    @AppStorage("reader.lineHeight") private var line = 1.6
    @AppStorage("reader.theme") private var theme = "paper"
    @State private var appearance = false
    @AppStorage("reader.font") private var font = "serif"
    @State private var progress = 0.0
    @State private var contents = false
    @State private var targetChapter: UUID?
    @AppStorage("reader.continuous") private var continuous = true
    private var paperColor: Color {
        theme == "dark" ? Color(red: 23/255, green: 25/255, blue: 24/255)
            : theme == "light" ? .white : Color(red: 246/255, green: 241/255, blue: 231/255)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if reader.articles.isEmpty {
                    if reader.loading {
                        ProgressView().frame(maxHeight: .infinity)
                    } else {
                        ContentUnavailableView {
                            Label(ToolText.text("reader_no_content"), systemImage: "doc.text")
                        } description: {
                            Text(ToolText.text("reader_retry_hint"))
                        } actions: {
                            Button(ToolText.text("retry")) { Task { await reader.open(source) } }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    ArticleSurface(articles: reader.articles, size: size, line: line, theme: theme, font: font, targetChapter: targetChapter, onProgress: { progress = $0 }) { url in
                        reader.cancel()
                        source.load(URLRequest(url: url))
                        dismiss()
                    }
                    if let error = reader.error { Text(error).font(.footnote).foregroundStyle(.secondary).padding(8) }
                    HStack(spacing: 16) {
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityLabel(ToolText.text("reading_progress"))
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                        Spacer()
                        if reader.loading {
                            ProgressView()
                            Button(ToolText.text("cancel")) { reader.cancel() }
                        } else if continuous, reader.articles.last?.next != nil {
                            Button(ToolText.text("reader_continue")) { reader.next() }.frame(minHeight: 44)
                        }
                        Button { targetChapter = nil; contents = true } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel(ToolText.text("loaded_chapters"))
                            .frame(minWidth: 44, minHeight: 44)
                    }.padding(.horizontal).padding(.vertical, 6)
                }
            }.background(paperColor)
                .navigationTitle(ToolText.text("reader_mode")).navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(paperColor, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(ToolText.text("done")) {
                            reader.cancel()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            appearance = true
                        } label: {
                            Image(systemName: "textformat.size").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                        }
                    }
                }
                .sheet(isPresented: $appearance) {
                    NavigationStack {
                        Form {
                            Picker(ToolText.text("font"), selection: $font) {
                                Text(ToolText.text("serif")).tag("serif")
                                Text(ToolText.text("sans")).tag("sans")
                                Text(ToolText.text("mono")).tag("mono")
                            }
                            LabeledContent(ToolText.text("font_size"), value: Int(size).formatted())
                            Slider(value: $size, in: 14...36, step: 1) { Text(ToolText.text("font_size")) }
                            LabeledContent(ToolText.text("line_height"), value: line.formatted())
                            Slider(value: $line, in: 1.2...2.4, step: 0.1) { Text(ToolText.text("line_height")) }
                            Picker(ToolText.text("appearance"), selection: $theme) {
                                Text(ToolText.text("paper")).tag("paper")
                                Text(ToolText.text("light")).tag("light")
                                Text(ToolText.text("dark")).tag("dark")
                            }.pickerStyle(.segmented)
                            Toggle(ToolText.text("continuous_reading"), isOn: $continuous).onChange(of: continuous) {
                                _, enabled in if !enabled { reader.cancel() }
                            }
                            Text(ToolText.text("reader_next_hint")).font(.footnote).foregroundStyle(.secondary)
                        }.navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { appearance = false } } }
                    }.presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $contents) {
                    NavigationStack {
                        List(reader.articles) { article in
                            Button {
                                targetChapter = article.id
                                contents = false
                            } label: {
                                Text(article.title).foregroundStyle(.primary).lineLimit(2)
                            }
                        }.navigationTitle(ToolText.text("loaded_chapters"))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) {
                                Button(ToolText.text("done")) { contents = false }
                            } }
                    }.presentationDetents([.medium, .large])
                }
                .task { await reader.open(source) }
                .onDisappear { reader.cancel() }
        }.preferredColorScheme(theme == "dark" ? .dark : .light)
    }
}
struct ArticleSurface: UIViewRepresentable {
    let articles: [ReaderArticle]
    let size: Double, line: Double
    let theme: String
    var font = "serif"
    var targetChapter: UUID? = nil
    var onProgress: ((Double) -> Void)? = nil
    var onOpenLink: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = AccessibleWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.scrollView.delegate = context.coordinator
        context.coordinator.progressObservation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak coordinator = context.coordinator] scrollView, _ in
            Task { @MainActor in coordinator?.publishProgress(scrollView) }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpenLink = onOpenLink
        coordinator.onProgress = onProgress
        coordinator.targetChapter = targetChapter
        coordinator.jumpIfNeeded(view)
        let colors = theme == "dark" ? ("#171918", "#d8ddd9") : theme == "light" ? ("#fff", "#202124") : ("#f6f1e7", "#29251f")
        let fontSize = min(36, max(14, size.isFinite ? size : 18))
        let lineHeight = min(2.5, max(1.2, line.isFinite ? line : 1.6))
        let family = font == "sans" ? "-apple-system, system-ui, sans-serif" : font == "mono" ? "ui-monospace, Menlo, monospace" : "Georgia, \"Songti SC\", \"Noto Serif CJK SC\", serif"
        let key = articles.map(\.id.description).joined() + "-\(fontSize)-\(lineHeight)-\(theme)-\(font)"
        guard coordinator.key != key else { return }
        coordinator.key = key
        coordinator.revision += 1
        coordinator.arguments = [
            "pages": articles.enumerated().map { index, article -> [String: String] in
                let continuation = index > 0 && articles[index - 1].title == article.title
                let header = continuation ? "" : "<header><h1>\(Self.escape(article.title))</h1><p class='source'>\(Self.escape(article.url.host ?? ""))</p></header>"
                return ["id": article.id.uuidString, "html": header + article.html,
                        "kind": (continuation ? "continuation" : "chapter") + (article.isNovel ? " novel" : ""),
                        "lang": article.language ?? "", "dir": article.direction ?? "auto"]
            },
            "fontSize": fontSize, "lineHeight": lineHeight, "fontFamily": family,
            "background": colors.0, "foreground": colors.1,
            "accent": AppTheme.accentCSS(for: theme == "dark" ? .dark : .light)
        ]
        if !coordinator.started {
            coordinator.started = true
            view.loadHTMLString("""
                <!doctype html><html><head><meta charset="utf-8">
                <meta name="viewport" content="width=device-width,initial-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http:; style-src 'unsafe-inline';">
                <style>
                html{background:\(colors.0);color:\(colors.1);-webkit-text-size-adjust:100%}
                body{margin:0;padding:32px 24px 48px;font:\(fontSize)px/\(lineHeight) Georgia,"Songti SC",serif;overflow-wrap:anywhere}
                main{max-width:38em;margin:auto}article{text-align:start}p{margin:0 0 1em}article.novel p:not(.source){text-indent:2em;text-align:justify;margin-bottom:.85em}article.novel p:has(img){text-indent:0}h1{font-weight:600;letter-spacing:.015em}
                article+article{border-top:1px solid #8885;margin-top:40px;padding-top:24px}
                article.continuation{border:0;margin-top:0;padding-top:0}
                h1{margin:0 0 .6em;font-size:1.5em;line-height:1.35}h2,h3,h4,h5,h6{line-height:1.4;margin:1.4em 0 .6em}
                .source{font:12px/1.5 -apple-system,system-ui;opacity:.6;margin-bottom:2em}
                img{display:block;max-width:100%;height:auto;margin:.9em auto}figure{margin:1em 0}
                figcaption{font-size:.85em;opacity:.7;text-align:center}
                blockquote{margin:1em 0;padding-inline-start:1em;border-inline-start:3px solid #8885}
                ul,ol{padding-inline-start:1.5em}li{margin:.4em 0}
                table{display:block;max-width:100%;overflow-x:auto;border-collapse:collapse;margin:1em 0;font-size:.9em;overflow-wrap:normal;word-break:normal}
                th,td{min-width:6em;padding:.5em .7em;border:1px solid #8885;text-align:start}th{background:#8881}
                pre{max-width:100%;overflow-x:auto;padding:1em;box-sizing:border-box;border-radius:8px;background:#8881;white-space:pre;overflow-wrap:normal}
                code{font:.85em/1.6 ui-monospace,Menlo,monospace}pre code{font-size:.85em}
                a{color:var(--reader-accent);text-decoration:underline;text-underline-offset:3px}
                hr{border:0;border-top:1px solid #8885;margin:1.5em 0}sup,sub{line-height:0}
                </style></head><body><main id="soulo-reader-content"></main></body></html>
                """, baseURL: URL(string: "https://soulo-reader.invalid/"))
        } else {
            coordinator.synchronize(view)
        }
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var key = "", revision = 0
        var started = false, ready = false, updating = false
        var arguments: [String: Any] = [:]
        var onOpenLink: ((URL) -> Void)?
        var onProgress: ((Double) -> Void)?
        var progressObservation: NSKeyValueObservation?
        var targetChapter: UUID?, lastJump: UUID?
        func scrollViewDidScroll(_ scrollView: UIScrollView) { publishProgress(scrollView) }
        func publishProgress(_ scrollView: UIScrollView) {
            let extent = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom
            let value = extent > 1 ? min(1, max(0, (scrollView.contentOffset.y + scrollView.adjustedContentInset.top) / extent)) : 1
            onProgress?(value)
        }
        func jumpIfNeeded(_ view: WKWebView) {
            if targetChapter == nil { lastJump = nil }
            guard ready, !updating, let targetChapter, targetChapter != lastJump else { return }
            lastJump = targetChapter
            view.callAsyncJavaScript("document.querySelector('[data-reader-id=\"' + chapter + '\"]')?.scrollIntoView({block:'start'});", arguments: ["chapter": targetChapter.uuidString], in: nil, in: .defaultClient) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            synchronize(webView)
        }
        func synchronize(_ view: WKWebView) {
            guard ready, !updating else { return }
            updating = true
            let currentRevision = revision
            // Append pages in place: reloading the whole document loses text selection,
            // reloads earlier images and jumps as their intrinsic sizes arrive again.
            view.callAsyncJavaScript("""
                const root = document.getElementById('soulo-reader-content');
                const existing = [...root.children];
                const appendOnly = existing.length <= pages.length && existing.every((node,i) => node.dataset.readerId === pages[i].id);
                const anchor = document.elementFromPoint(32,40);
                const top = anchor?.getBoundingClientRect().top;
                document.body.style.fontSize = fontSize + 'px';
                document.body.style.fontFamily = fontFamily;
                document.body.style.lineHeight = lineHeight;
                document.body.style.background = background;
                document.body.style.color = foreground;
                document.documentElement.style.background = background;
                document.documentElement.style.setProperty('--reader-accent',accent);
                if (anchor && top != null) window.scrollBy(0,anchor.getBoundingClientRect().top-top);
                if (!appendOnly) root.replaceChildren();
                const start = appendOnly ? existing.length : 0;
                for (const page of pages.slice(start)) {
                    const node = document.createElement('article');
                    node.dataset.readerId = page.id; node.className = page.kind;
                    node.lang = page.lang; node.dir = page.dir;
                    node.innerHTML = page.html;
                    // Keep repeated footnote/heading IDs distinct across appended pages.
                    node.querySelectorAll('[id]').forEach(e => e.id = page.id + '-' + e.id);
                    node.querySelectorAll('a[href^="#"]').forEach(a => a.setAttribute('href','#' + page.id + '-' + a.getAttribute('href').slice(1)));
                    root.appendChild(node);
                }
                return true;
                """, arguments: arguments, in: nil, in: .defaultClient) { [weak self, weak view] _ in
                    guard let self else { return }
                    self.updating = false
                    if let view {
                        self.publishProgress(view.scrollView)
                        if self.revision != currentRevision { self.synchronize(view) }
                        else { self.jumpIfNeeded(view) }
                    }
                }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated else { decisionHandler(.allow); return }
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.host == "soulo-reader.invalid", url.path == "/", url.fragment != nil {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
                    onOpenLink?(url)
                }
            }
        }
    }
}
