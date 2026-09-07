import WebKit

struct WebMediaPlaybackState: Equatable {
    var count = 0
    var rate = 1.0
}

@MainActor enum WebMediaPlaybackBridge {
    /// A small scan for visible browser controls; no article extraction or network requests.
    static func inspect(_ webView: WKWebView) async -> WebMediaPlaybackState {
        let script = #"""
        const items = [], seen = new Set();
        const visit = doc => {
            if (!doc || seen.has(doc) || seen.size >= 12) return;
            seen.add(doc);
            doc.querySelectorAll('video,audio').forEach(m => {
                if (m.currentSrc || m.getAttribute('src') || m.srcObject || m.querySelector('source[src]')) items.push(m);
            });
            doc.querySelectorAll('iframe').forEach(f => { try { visit(f.contentDocument); } catch {} });
        };
        visit(document);
        const area = m => {
            const r = m.getBoundingClientRect(), w = m.ownerDocument.defaultView;
            return Math.max(0, Math.min(r.right,w.innerWidth)-Math.max(r.left,0)) *
                Math.max(0,Math.min(r.bottom,w.innerHeight)-Math.max(r.top,0));
        };
        items.sort((a,b) => Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) || area(b) - area(a));
        const active = items[0];
        return {count: items.length, rate: active ? active.playbackRate : 1};
        """#
        guard let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else { return .init() }
        return .init(count: result["count"] as? Int ?? 0, rate: result["rate"] as? Double ?? 1)
    }

    static func setRate(_ rate: Double, on webView: WKWebView) async throws -> [Double] {
        guard MediaSession.validRate(Float(rate)) else { throw ReadingToolError.invalid }
        // The page world may wrap playbackRate. Use WebKit's isolated DOM bindings and
        // verify the native value after the player's initial ratechange handlers run.
        let result = try await webView.callAsyncJavaScript(rateControllerScript,
            arguments: ["requestedRate": rate], in: nil, contentWorld: .defaultClient)
        guard let rates = result as? [Double], let actual = rates.first,
              abs(actual - rate) < 0.001 else { throw ReadingToolError.unsupported }
        return rates
    }

    private static let rateControllerScript = #"""
    const key = '__souloMediaRateController_v1';
    const collect = () => {
        const documents = [], items = [], seen = new Set();
        const visit = doc => {
            if (!doc || seen.has(doc) || seen.size >= 12) return;
            seen.add(doc); documents.push(doc);
            doc.querySelectorAll('video,audio').forEach(m => items.push(m));
            doc.querySelectorAll('iframe').forEach(f => { try { visit(f.contentDocument); } catch {} });
        };
        visit(document);
        return {documents, items};
    };
    const readRate = m => {
        try {
            const proto = m.ownerDocument.defaultView.HTMLMediaElement.prototype;
            return Object.getOwnPropertyDescriptor(proto, 'playbackRate').get.call(m);
        } catch { return m.playbackRate; }
    };
    const writeRate = (m, value) => {
        try {
            const proto = m.ownerDocument.defaultView.HTMLMediaElement.prototype;
            for (const name of ['defaultPlaybackRate', 'playbackRate']) {
                const property = Object.getOwnPropertyDescriptor(proto, name);
                if (Math.abs(property.get.call(m) - value) > .001) property.set.call(m, value);
            }
        } catch {}
    };
    const ordered = items => {
        const visibleArea = m => {
            const r = m.getBoundingClientRect(), w = m.ownerDocument.defaultView;
            return Math.max(0, Math.min(r.right, w.innerWidth) - Math.max(r.left, 0)) *
                Math.max(0, Math.min(r.bottom, w.innerHeight) - Math.max(r.top, 0));
        };
        return [...items].sort((a,b) =>
            Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) || visibleArea(b) - visibleArea(a));
    };
    let controller = globalThis[key];
    if (!controller && collect().items.length === 0) return [];
    if (requestedRate === 1) {
        if (controller) controller.dispose();
        const items = ordered(collect().items);
        items.forEach(m => writeRate(m, 1));
        await new Promise(resolve => setTimeout(resolve, 160));
        return items.filter(m => m.isConnected).map(readRate);
    }
    if (!controller) {
        const records = new Map(), documents = new Map();
        let refreshTimer = null, disposed = false;
        controller = {
            desired: requestedRate,
            refresh,
            reset() {
                records.forEach((record, media) => { arm(record); writeRate(media, controller.desired); });
            },
            dispose() {
                disposed = true;
                clearTimeout(refreshTimer);
                records.forEach(record => record.remove()); records.clear();
                documents.forEach(record => record.remove()); documents.clear();
                window.removeEventListener('pagehide', controller.dispose);
                if (globalThis[key] === controller) delete globalThis[key];
            }
        };
        function arm(record) { record.retries = 0; record.until = performance.now() + 2000; }
        function schedule() {
            if (!disposed && refreshTimer === null) refreshTimer = setTimeout(() => {
                refreshTimer = null; refresh();
            }, 60);
        }
        function refresh() {
            if (disposed) return;
            const current = collect(), present = new Set(current.items);
            records.forEach((record, media) => {
                if (!present.has(media)) { record.remove(); records.delete(media); }
            });
            documents.forEach((record, doc) => {
                if (!current.documents.includes(doc)) { record.remove(); documents.delete(doc); }
            });
            current.documents.forEach(doc => {
                if (documents.has(doc)) return;
                const relevant = node => node.nodeType === 1 &&
                    (node.matches('video,audio,source,iframe') || node.querySelector('video,audio,source,iframe'));
                const observer = new MutationObserver(changes => {
                    if (changes.some(change => change.type === 'attributes'
                        ? change.target.matches('video,audio,source,iframe')
                        : [...change.addedNodes, ...change.removedNodes].some(relevant))) schedule();
                });
                observer.observe(doc, {subtree: true, childList: true, attributes: true, attributeFilter: ['src']});
                doc.addEventListener('load', schedule, true);
                documents.set(doc, {remove() { observer.disconnect(); doc.removeEventListener('load', schedule, true); }});
            });
            current.items.forEach(media => {
                const source = media.currentSrc || media.getAttribute('src') || media.querySelector('source[src]')?.src || '';
                let record = records.get(media);
                if (record) {
                    if (record.source !== source) {
                        record.source = source; arm(record); writeRate(media, controller.desired);
                    }
                    return;
                }
                record = {source, retries: 0, until: 0};
                const restart = () => {
                    if (performance.now() > record.until) arm(record);
                    if (record.retries < 4 && Math.abs(readRate(media) - controller.desired) > .001) {
                        record.retries++; writeRate(media, controller.desired);
                    }
                };
                const changed = () => {
                    if (disposed || Math.abs(readRate(media) - controller.desired) < .001) return;
                    // Repair startup resets only. Never create an endless ratechange fight,
                    // and allow the site's own speed controls once startup has settled.
                    if (performance.now() <= record.until && record.retries < 4) {
                        record.retries++; writeRate(media, controller.desired);
                    }
                };
                media.addEventListener('loadedmetadata', restart);
                media.addEventListener('play', restart);
                media.addEventListener('ratechange', changed);
                record.remove = () => {
                    media.removeEventListener('loadedmetadata', restart);
                    media.removeEventListener('play', restart);
                    media.removeEventListener('ratechange', changed);
                };
                records.set(media, record); restart();
            });
        }
        globalThis[key] = controller;
        window.addEventListener('pagehide', controller.dispose, {once: true});
    }
    controller.desired = requestedRate;
    controller.refresh();
    controller.reset();
    await new Promise(resolve => setTimeout(resolve, 160));
    return ordered(collect().items).map(readRate);
    """#
}
