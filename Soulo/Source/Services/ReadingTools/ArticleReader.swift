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
    var isNovel = false
    var language: String? = nil
    var direction: String? = nil
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
        guard !loading else { return }
        loading = true; error = nil; defer { loading = false }
        sourceStore = webView.configuration.websiteDataStore
        sourceUserAgent = webView.customUserAgent
        do { try append(await Self.extractWhenReady(webView)) }
        catch is CancellationError {}
        catch { self.error = ToolText.text("reader_no_content") }
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
        return try await Self.extractWhenReady(view, retries: allowsScripts ? 8 : 0)
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
    /// Late DOM content is common on fiction sites. Retry in the original session,
    /// without reloading the user's page or retaining work after cancellation.
    static func extractWhenReady(_ webView: WKWebView, retries: Int = 8) async throws -> ReaderArticle {
        let originalURL = webView.url
        for attempt in 0...retries {
            try Task.checkCancellation()
            guard webView.url == originalURL else { throw CancellationError() }
            do { let article = try await extract(webView); try Task.checkCancellation(); return article }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard attempt < retries else { throw error }
                try await Task.sleep(for: .milliseconds(350))
            }
        }
        throw ReadingToolError.invalid
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
                             next: validNext((result["next"] as? String).flatMap(URL.init(string:)), from: url),
                             isNovel: result["novel"] as? Bool ?? false, language: result["language"] as? String, direction: result["direction"] as? String)
    }
    static let extractionScript = #"""
    (() => {
        let document = window.document;
        // Read same-origin embedded articles only when the outer page has little prose.
        const embedded = [...document.querySelectorAll('iframe')].slice(0,12).map(frame => {
            try { return frame.contentDocument; } catch { return null; }
        }).filter(doc => doc?.body && doc.body.textContent.trim().length >= 300)
          .sort((a,b) => b.body.textContent.length-a.body.textContent.length)[0];
        if (embedded && embedded.body.textContent.length > (document.body?.textContent.trim().length || 0) * 2) document = embedded;
        const location = new URL(/^https?:/.test(document.location?.href || '') ? document.location.href : document.baseURI || window.location.href);
        const nextText = /^(?:下(?:一)?(?:页|頁|章(?:节|節)?|节|節)|下1章|next(?:\s+(?:page|chapter))?|次(?:のページ|の章|章|へ)|다음(?:\s*(?:페이지|장))?|suivant(?:e)?|siguiente|nächste(?:\s+seite)?|próxim[oa](?:\s+página)?)[\s›»→>）)]*$/i;
        const validLink = a => {
            try { const u = new URL(a.href,location.href), here = new URL(location.href);
                u.hash = ''; here.hash = '';
                return u.origin === here.origin && /^https?:$/.test(u.protocol) && !u.username && !u.password && u.href !== here.href;
            } catch { return false; }
        };
        const next = [...document.querySelectorAll('link[rel~="next"][href],a[rel~="next"][href],a#pt_next[href],a#pb_next[href],a.url_next[href]')].find(validLink)
            || [...document.querySelectorAll('a[href]')].find(a => !a.closest('aside,header') && nextText.test((a.getAttribute('aria-label') || a.textContent).trim().replace(/[（(]\d+\s*[/／]\s*\d+[）)]$/, '').trim()) && validLink(a));
        const clone = document.cloneNode(true);
        const imageURL = raw => {
            try { if (!raw?.trim()) return ''; const u = new URL(raw,location.href); return /^https?:$/.test(u.protocol) && !u.username && !u.password ? u.href : ''; }
            catch { return ''; }
        };
        // Resolve lazy and responsive images before parsing strips site data attributes.
        clone.querySelectorAll('img').forEach((img,i) => {
            const lazy = img.getAttribute('data-src') || img.getAttribute('data-original') || img.getAttribute('data-lazy-src') || img.getAttribute('data-url');
            const responsive = img.getAttribute('data-srcset') || img.closest('picture')?.querySelector('source[srcset]')?.getAttribute('srcset');
            const fallback = responsive?.split(',').map(s => s.trim().split(/\s+/)[0]).map(imageURL).find(Boolean);
            const deferred = img.hasAttribute('data-srcset') ? fallback : '';
            const source = imageURL(lazy || '') || deferred || imageURL(document.images[i]?.currentSrc || '') || fallback || imageURL(img.getAttribute('src') || '');
            if (source) img.setAttribute('src',source);
        });
        const liveNodes = [...document.querySelectorAll('*')].slice(0,10000);
        const clonedNodes = [...clone.querySelectorAll('*')].slice(0,10000);
        liveNodes.forEach((node,i) => {
            if (!['HTML','BODY'].includes(node.tagName)) {
                const style = document.defaultView.getComputedStyle(node);
                if (style.display === 'none' || style.visibility === 'hidden') clonedNodes[i]?.remove();
            }
        });
        clone.querySelectorAll('[hidden],[aria-hidden="true"],script:not([type="application/ld+json"]),style,nav,footer,form,aside,.ads,.advertisement').forEach(e => e.remove());
        const chapterSelectors = '#chaptercontent,#chapterContent,#booktxt,#booktext,#BookText,#nr1,#nr,#txt,#chapterText,.read-content,.readcontent,.chapter-content,.chapterContent,.book-content';
        const fallbackSelectors = chapterSelectors + ',#content,article,main,[role="main"],[itemprop="articleBody"]';
        // Unnamed divs containing prose and BR-separated lines are common too.
        const plainContainers = [...clone.querySelectorAll('div,section,pre')].slice(0,2000).filter(node => {
            const text = node.textContent.trim();
            if (text.length < 240 || text.length > 500000) return false;
            const direct = [...node.childNodes].filter(n => n.nodeType === 3).reduce((n,t) => n + t.textContent.trim().length,0);
            return direct / text.length > .5 && (text.match(/[。！？.!?]/g) || []).length >= 4;
        });
        const candidates = [...new Set([...clone.querySelectorAll(fallbackSelectors), ...plainContainers])].map(node => {
            const candidate = node.cloneNode(true);
            candidate.querySelectorAll('script,style,nav,footer,header,form,aside,.ads,.ad,.advertisement,.bottem,.bottom,.page_chapter,.chapter-control').forEach(e => e.remove());
            candidate.querySelectorAll('a').forEach(a => {
                if (/^(?:上(?:一)?[页章节]|下(?:一)?[页章节]|返回目录|章节目录|加入书签|加入书架|投推荐票|书签|目录)$/.test(a.textContent.trim()) || /^(?:『|【)?如果章节错误/.test(a.textContent.trim())) a.remove();
            });
            const text = candidate.textContent.trim();
            const linked = [...candidate.querySelectorAll('a')].reduce((n,a) => n + a.textContent.length, 0);
            return { node: candidate, text, explicit: node.matches(chapterSelectors), density: linked / Math.max(1,text.length) };
        }).filter(c => c.text.length >= 120 && c.density < .15).sort((a,b) => Number(b.explicit)-Number(a.explicit) || b.text.length-a.text.length);
        let result = null;
        try { result = new Readability(clone, { maxElemsToParse: 100000, charThreshold: 120 }).parse(); } catch {}

        const chapter = candidates[0];
        const useChapter = chapter && (!result || result.textContent.trim().length < 120 || (chapter.explicit && chapter.text.length >= result.textContent.trim().length * .75));
        if (!result && !useChapter) return null;
        const root = document.createElement('div');
        root.innerHTML = useChapter ? chapter.node.innerHTML : result.content;
        root.querySelectorAll('script,style,iframe,object,embed,form,input,button,textarea,select,link,meta,svg,annotation,annotation-xml,video,audio,source,canvas,nav,footer,aside').forEach(e => e.remove());
        const tags = new Set(['DIV','P','BR','HR','SPAN','A','IMG','H1','H2','H3','H4','H5','H6','B','STRONG','I','EM','U','S','DEL','SMALL','SUP','SUB','BLOCKQUOTE','PRE','CODE','UL','OL','LI','DL','DT','DD','TABLE','THEAD','TBODY','TFOOT','TR','TD','TH','CAPTION','FIGURE','FIGCAPTION','SECTION','ARTICLE','MATH','MI','MN','MO','MROW','MSUP','MSUB','MSUBSUP','MFRAC','MSQRT','MROOT','MFENCED','MOVER','MUNDER','MUNDEROVER','MTABLE','MTR','MTD','MTEXT','MSPACE','SEMANTICS']);
        root.querySelectorAll('*').forEach(e => {
            if (!tags.has(e.tagName.toUpperCase())) { e.replaceWith(...e.childNodes); return; }
            for (const attr of [...e.attributes]) {
                if (!['href','src','alt','title','colspan','rowspan','id','lang','dir'].includes(attr.name)) e.removeAttribute(attr.name);
            }
            for (const attr of ['href','src']) if(e.hasAttribute(attr)) {
                try { const u = new URL(e.getAttribute(attr), location.href); if (!['http:','https:'].includes(u.protocol) || u.username || u.password) e.removeAttribute(attr); else { const here = new URL(location.href); const withoutFragment = new URL(u); withoutFragment.hash = ''; here.hash = ''; e.setAttribute(attr, attr === 'href' && u.hash && withoutFragment.href === here.href ? u.hash : u.href); } }
                catch { e.removeAttribute(attr); }
            }
        });
        const novel = !!((chapter?.explicit && useChapter) || /第.{1,18}[章回卷]|chapter\s+\d/i.test(document.querySelector('h1')?.textContent || document.title));
        // Turn BR-separated prose into real paragraphs while preserving inline markup.
        if (novel) root.querySelectorAll('pre:not(:has(code))').forEach(pre => {
            const prose = document.createElement('div');
            pre.textContent.split(/\n+/).map(line => line.trim()).filter(Boolean).forEach(line => {
                const p = document.createElement('p'); p.textContent = line; prose.appendChild(p);
            });
            pre.replaceWith(prose);
        });
        if (useChapter || novel) {
            const blocks = new Set(['DIV','P','SECTION','ARTICLE','PRE','TABLE','UL','OL','H1','H2','H3','H4','H5','H6','HR','DL','BLOCKQUOTE','FIGURE']);
            const paragraphs = container => {
                for (const child of [...container.children]) if (['DIV','SECTION'].includes(child.tagName)) paragraphs(child);
                if (![...container.childNodes].some(n => n.nodeType === 3 && n.textContent.trim() || n.nodeName === 'BR')) return;
                const fragment = document.createDocumentFragment(); let run = document.createElement('p');
                const flush = () => {
                    if (run.textContent.trim() || run.querySelector('img')) { run.innerHTML = run.innerHTML.trim(); fragment.appendChild(run); }
                    run = document.createElement('p');
                };
                for (const node of [...container.childNodes]) {
                    if (node.nodeName === 'BR') { flush(); continue; }
                    if (blocks.has(node.nodeName)) { flush(); fragment.appendChild(node); }
                    else if (node.nodeType === 3 && /\n\s*\n/.test(node.textContent)) {
                        node.textContent.split(/\n\s*\n/).forEach((part,i) => { if (i) flush(); run.appendChild(document.createTextNode(part)); });
                    } else run.appendChild(node);
                }
                flush(); container.replaceChildren(fragment);
            };
            paragraphs(root);
        }
        // Pagination notices are site chrome, not part of the chapter text.
        if (useChapter) {
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {
                walker.currentNode.textContent = walker.currentNode.textContent
                    .replace(/^\s*第\s*[（(]\d+\s*[/／]\s*\d+[）)]\s*页\s*$/, '')
                    .replace(/[（(]本章未完[,，]?请翻页[）)]/g, '');
            }
        }
        const title = (useChapter ? document.querySelector('#chaptername,.chapter-title,main h1,article h1,h1')?.textContent : result.title) || result?.title || document.title;
        // Avoid repeating a chapter heading already displayed by the reader shell.
        root.querySelectorAll('h1,h2').forEach(h => { if (h.textContent.trim() === title.trim()) h.remove(); });
        const totalText = root.textContent.trim().length;
        const linkedText = [...root.querySelectorAll('a[href]')].reduce((sum,a) => sum + a.textContent.trim().length,0);
        if (totalText < 80 || linkedText / Math.max(totalText,1) > .55) return null;
        const plain = root.cloneNode(true);
        plain.querySelectorAll('br').forEach(br => br.replaceWith('\n'));
        const language = result?.lang || document.documentElement.lang || '';
        const direction = result?.dir || document.documentElement.dir || getComputedStyle(document.body).direction;
        return { title: title.trim(), html: root.innerHTML, text: plain.textContent.trim(), next: next?.href || '',
                 novel, language, direction: ['rtl','ltr'].includes(direction) ? direction : 'auto' };
    })()
    """#

}
private extension URL {
    var removingFragment: URL { var parts = URLComponents(url: self, resolvingAgainstBaseURL: false); parts?.fragment = nil; return parts?.url ?? self }
}
