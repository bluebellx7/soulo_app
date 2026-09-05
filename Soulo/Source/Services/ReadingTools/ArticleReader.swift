import Foundation
import WebKit
import CryptoKit

struct ReaderArticle: Identifiable {
    let id = UUID()
    let title: String
    let html: String
    let text: String
    let url: URL
    let next: URL?
}
@MainActor final class ArticleReader: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var articles: [ReaderArticle] = []
    @Published var loading = false
    @Published var error: String?
    private var loader: WKWebView?
    private var pending: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var seen = Set<String>()
    private var fingerprints = Set<String>()
    private var sourceUserAgent: String?
    private var sourceStore: WKWebsiteDataStore = .nonPersistent()
    static func validNext(_ candidate: URL?, from source: URL) -> URL? {
        guard let candidate, ["http", "https"].contains(candidate.scheme ?? ""),
              candidate.host == source.host, candidate.port == source.port, candidate.scheme == source.scheme,
              candidate.user == nil, candidate.password == nil,
              candidate.removingFragment != source.removingFragment else { return nil }
        return candidate
    }
    func open(_ webView: WKWebView) async {
        loading = true; error = nil; defer { loading = false }
        sourceStore = webView.configuration.websiteDataStore
        sourceUserAgent = webView.customUserAgent
        do { try append(await Self.extract(webView)) } catch { self.error = error.localizedDescription }
    }
    func next() {
        guard !loading, let url = articles.last?.next else { return }
        guard articles.count < 30, !seen.contains(url.removingFragment.absoluteString) else { error = ToolText.text("reader_loop"); return }
        loading = true; error = nil
        task = Task {
            defer { loading = false; loader?.stopLoading(); loader = nil }
            do {
                let article: ReaderArticle
                do { article = try await loadArticle(url, allowsScripts: false) }
                catch ReadingToolError.invalid {
                    // Static chapter pages do not need ad scripts. Retry dynamic pages only
                    // when no readable content was found, retaining the same-origin guard.
                    article = try await loadArticle(url, allowsScripts: true)
                }
                try Task.checkCancellation()
                try append(article)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func loadArticle(_ url: URL, allowsScripts: Bool) async throws -> ReaderArticle {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = sourceStore
        config.defaultWebpagePreferences.allowsContentJavaScript = allowsScripts
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = sourceUserAgent
        view.navigationDelegate = self; loader = view
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Task.sleep(for: .seconds(20)); throw URLError(.timedOut) }
            group.addTask { @MainActor in try await self.load(view, url: url) }
            defer { group.cancelAll() }
            do { _ = try await group.next() } catch { self.cancelLoad(); throw error }
        }
        try Task.checkCancellation()
        return try await Self.extract(view)
    }
    private func load(_ view: WKWebView, url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in pending = continuation; view.load(URLRequest(url: url)) }
        } onCancel: { Task { @MainActor in self.cancelLoad() } }
    }
    func cancel() { task?.cancel(); cancelLoad(); loading = false }
    private func cancelLoad() { loader?.stopLoading(); pending?.resume(throwing: CancellationError()); pending = nil }
    private func append(_ article: ReaderArticle) throws {
        let fingerprint = SHA256.hash(data: Data(article.text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard !fingerprints.contains(fingerprint), !seen.contains(article.url.removingFragment.absoluteString) else { throw ReadingToolError.invalid }
        fingerprints.insert(fingerprint); seen.insert(article.url.removingFragment.absoluteString); articles.append(article)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pending?.resume(); pending = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pending?.resume(throwing: error); pending = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pending?.resume(throwing: error); pending = nil }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.cancel); return }
        guard let source = articles.first?.url, let url = navigationAction.request.url, url.host == source.host, url.scheme == source.scheme, url.port == source.port else { decisionHandler(.cancel); cancelLoad(); return }
        decisionHandler(.allow)
    }
    static func extract(_ webView: WKWebView) async throws -> ReaderArticle {
        guard let url = webView.url, let resource = Bundle.main.url(forResource: "SouloReadability", withExtension: "js") else { throw ReadingToolError.invalid }
        let library = try String(contentsOf: resource, encoding: .utf8)
        let script = library + "\nreturn JSON.stringify(" + extractionScript + ");"
        guard let json = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? String, json != "null",
              let bytes = json.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let html = result["html"] as? String, let text = result["text"] as? String, text.count >= 80,
              webView.url == url else { throw ReadingToolError.invalid }
        return ReaderArticle(title: result["title"] as? String ?? "", html: html, text: text, url: url,
                             next: validNext((result["next"] as? String).flatMap(URL.init(string:)), from: url))
    }
    static let extractionScript = #"""
    (() => {
        const nextText = /^(?:下(?:一)?[页章节]|下1章|next(?:\s+(?:page|chapter))?)(?:[\s›»→>）)]|\(\d+\/\d+\))*$/i;
        const next = document.querySelector('a[rel~="next"][href],a#pt_next[href],a#pb_next[href],a.url_next[href]') || [...document.querySelectorAll('a[href]')].find(a => nextText.test(a.textContent.trim()));
        const clone = document.cloneNode(true);
        // Preserve lazy images before Readability removes their data attributes.
        clone.querySelectorAll('img').forEach(img => {
            const lazy = img.getAttribute('data-src') || img.getAttribute('data-original') || img.getAttribute('data-lazy-src');
            if (lazy && (!img.getAttribute('src') || /^(?:data:|about:)/.test(img.getAttribute('src')))) img.setAttribute('src', lazy);
        });
        const chapterSelectors = '#chaptercontent,#chapterContent,#booktxt,#nr1,#txt,.read-content,.chapter-content,.chapterContent,#content';
        const candidates = [...clone.querySelectorAll(chapterSelectors)].map(node => {
            const candidate = node.cloneNode(true);
            candidate.querySelectorAll('script,style,nav,footer,header,form,aside,.ads,.ad,.advertisement,.bottem,.bottom,.page_chapter,.chapter-control').forEach(e => e.remove());
            candidate.querySelectorAll('a').forEach(a => {
                if (/^(?:上(?:一)?[页章节]|下(?:一)?[页章节]|返回目录|章节目录|加入书签|加入书架|投推荐票|书签|目录)$/.test(a.textContent.trim()) || /^(?:『|【)?如果章节错误/.test(a.textContent.trim())) a.remove();
            });
            const text = candidate.textContent.trim();
            const linked = [...candidate.querySelectorAll('a')].reduce((n,a) => n + a.textContent.length, 0);
            return { node: candidate, text, density: linked / Math.max(1,text.length) };
        }).filter(c => c.text.length >= 120 && c.density < .15).sort((a,b) => b.text.length-a.text.length);
        const result = new Readability(clone, { maxElemsToParse: 100000, charThreshold: 120 }).parse();
        const chapter = candidates[0];
        const useChapter = chapter && (!result || chapter.text.length >= result.textContent.trim().length * .75);
        if (!result && !useChapter) return null;
        const root = document.createElement('div');
        root.innerHTML = useChapter ? chapter.node.innerHTML : result.content;
        root.querySelectorAll('script,style,iframe,object,embed,form,input,button,textarea,select,link,meta,svg,math,video,audio,source,canvas,nav,footer,aside').forEach(e => e.remove());
        const tags = new Set(['DIV','P','BR','HR','SPAN','A','IMG','H1','H2','H3','H4','H5','H6','B','STRONG','I','EM','U','S','DEL','SMALL','SUP','SUB','BLOCKQUOTE','PRE','CODE','UL','OL','LI','DL','DT','DD','TABLE','THEAD','TBODY','TFOOT','TR','TD','TH','CAPTION','FIGURE','FIGCAPTION','SECTION','ARTICLE']);
        root.querySelectorAll('*').forEach(e => {
            if (!tags.has(e.tagName)) { e.replaceWith(...e.childNodes); return; }
            for (const attr of [...e.attributes]) {
                if (!['href','src','alt','title','colspan','rowspan'].includes(attr.name)) e.removeAttribute(attr.name);
            }
            for (const attr of ['href','src']) if(e.hasAttribute(attr)) {
                try { const u = new URL(e.getAttribute(attr), location.href); if (!['http:','https:'].includes(u.protocol) || u.username || u.password) e.removeAttribute(attr); else e.setAttribute(attr, u.href); }
                catch { e.removeAttribute(attr); }
            }
        });
        // Pagination notices are site chrome, not part of the chapter text.
        if (useChapter) {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
                walker.currentNode.textContent = walker.currentNode.textContent
                    .replace(/^\s*第\s*[（(]\d+\s*[/／]\s*\d+[）)]\s*页\s*$/, '')
                    .replace(/[（(]本章未完[,，]?请翻页[）)]/g, '');
            }
        }
        const title = (useChapter ? document.querySelector('h1')?.textContent : result.title) || result?.title || document.title;
        // Avoid repeating a chapter heading already displayed by the reader shell.
        root.querySelectorAll('h1').forEach(h => { if (h.textContent.trim() === title.trim()) h.remove(); });
        const plain = root.cloneNode(true);
        plain.querySelectorAll('br').forEach(br => br.replaceWith('\n'));
        return { title: title.trim(), html: root.innerHTML, text: plain.textContent.trim(), next: next?.href || '' };
    })()
    """#

}
private extension URL {
    var removingFragment: URL { var parts = URLComponents(url: self, resolvingAgainstBaseURL: false); parts?.fragment = nil; return parts?.url ?? self }
}
