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
    @AppStorage("reader.continuous") private var continuous = true
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
                    ArticleSurface(articles: reader.articles, size: size, line: line, theme: theme)
                    if let error = reader.error { Text(error).font(.footnote).foregroundStyle(.secondary).padding(8) }
                    HStack {
                        if reader.loading {
                            ProgressView()
                            Button(ToolText.text("cancel")) { reader.cancel() }
                        } else if continuous, reader.articles.last?.next != nil {
                            Button(ToolText.text("reader_continue")) { reader.next() }.frame(minHeight: 44)
                        } else {
                            Text(ToolText.text("reader_no_next")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal).padding(.vertical, 6)
                }
            }.navigationTitle(ToolText.text("reader_mode")).navigationBarTitleDisplayMode(.inline)
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
                .task { await reader.open(source) }
                .onDisappear { reader.cancel() }
        }
    }
}
struct ArticleSurface: UIViewRepresentable {
    let articles: [ReaderArticle]
    let size: Double, line: Double
    let theme: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let key = articles.map(\.id.description).joined()
        let colors = theme == "dark" ? ("#171918", "#d8ddd9") : theme == "light" ? ("#fff", "#202124") : ("#f6f1e7", "#29251f")
        let fontSize = min(36, max(14, size.isFinite ? size : 18))
        let lineHeight = min(2.5, max(1.2, line.isFinite ? line : 1.6))
        let styleKey = "\(fontSize)-\(lineHeight)-\(theme)"
        if context.coordinator.key == key {
            guard context.coordinator.styleKey != styleKey else { return }
            context.coordinator.styleKey = styleKey
            view.evaluateJavaScript("""
                (() => { const anchor=document.elementFromPoint(32,40); const top=anchor?.getBoundingClientRect().top;
                document.body.style.fontSize='\(fontSize)px'; document.body.style.lineHeight='\(lineHeight)';
                document.body.style.background='\(colors.0)'; document.body.style.color='\(colors.1)';
                if(anchor && top != null) window.scrollBy(0,anchor.getBoundingClientRect().top-top); })();
                """)
            return
        }
        context.coordinator.styleKey = styleKey
        guard context.coordinator.key != key else { return }
        let offset = view.scrollView.contentOffset.y
        context.coordinator.key = key
        context.coordinator.offset = offset
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let content = articles.enumerated().map { index, article in
            let continuation = index > 0 && articles[index - 1].title == article.title
            let header = continuation ? "" : "<header><h1>\(escape(article.title))</h1><p class='source'>\(escape(article.url.host ?? ""))</p></header>"
            return "<article class='\(continuation ? "continuation" : "chapter")'>\(header)\(article.html)</article>"
        }.joined()
        view.loadHTMLString(
            """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http:; style-src 'unsafe-inline';"><style>body{margin:0;padding:24px;background:\(colors.0);color:\(colors.1);font:\(fontSize)px/\(lineHeight) Georgia,serif;overflow-wrap:break-word;-webkit-text-size-adjust:100%}p{margin:0 0 1em}pre,table{max-width:100%;overflow:auto}figure{margin:1em 0}blockquote{margin:1em 0;padding-left:1em;border-left:2px solid #8885}article{max-width:680px;margin:auto}article+article{border-top:1px solid #8888;margin-top:40px;padding-top:24px}article.continuation{border:0;margin-top:0;padding-top:0}h1{font-size:1.5em;line-height:1.35}.source{font:12px system-ui;opacity:.6}img{max-width:100%;height:auto}a{color:inherit}</style></head><body>\(content)</body></html>
            """, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var key = "", styleKey = "", offset: CGFloat = 0
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        }
    }
}
