import WebKit

struct WebImageGalleryItem: Identifiable {
    let url: URL
    let pageURL: URL?
    let frame: WKFrameInfo?
    var id: String { url.absoluteString }
}

/// Read only image elements, without scanning styles or media manifests.
enum WebImageGalleryService {
    static let script = #"""
    (() => {
        const url = value => {
            if (!value) return '';
            try {
                const result = new URL(value, document.baseURI);
                return /^(https?:|blob:|data:)$/.test(result.protocol) ? result.href : '';
            } catch (_) { return ''; }
        };
        return Array.from(document.images).slice(0, 1000).flatMap(image => {
            const source = url(image.currentSrc || image.getAttribute('src') || image.getAttribute('data-src') || '');
            if (!source) return [];
            const width = image.naturalWidth || image.width;
            const height = image.naturalHeight || image.height;
            if (width > 0 && height > 0 && (Math.max(width, height) < 100 || Math.min(width, height) < 40)) return [];
            const linked = image.closest('a[href]')?.href || '';
            const original = image.getAttribute('data-original') || image.getAttribute('data-full') ||
                image.getAttribute('data-large') || (/\.(avif|webp|png|jpe?g|gif|heic)(?:[?#]|$)/i.test(linked) ? linked : '');
            return [{source, url: original ? (url(original) || source) : source}];
        }).slice(0, 200);
    })();
    """#

    @MainActor
    static func collect(for request: WebImagePreviewRequest) async -> (items: [WebImageGalleryItem], selectedID: String) {
        let initial = WebImageGalleryItem(url: request.url, pageURL: request.pageURL, frame: request.frame)
        guard let web = request.webView else { return ([initial], initial.id) }
        let source = web.url
        var items: [WebImageGalleryItem] = [], seen = Set<String>()
        var selectedID = initial.id
        // The pressed frame comes first, so its blob URLs and referrer stay paired.
        let frames: [WKFrameInfo?] = request.frame.map { $0.isMainFrame ? [nil] : [$0, nil] } ?? [nil]
        for frame in frames {
            guard !Task.isCancelled, web.url == source else { break }
            let value = try? await web.evaluateJavaScript(script, in: frame, contentWorld: .page)
            guard !Task.isCancelled, web.url == source else { break }
            for row in value as? [[String: String]] ?? [] {
                guard let value = row["url"], let url = URL(string: value),
                      ["https", "http", "data", "blob"].contains(url.scheme?.lowercased() ?? "") else { continue }
                if row["source"] == request.url.absoluteString || value == request.url.absoluteString { selectedID = value }
                if seen.insert(value).inserted {
                    items.append(.init(url: url, pageURL: frame?.requestURL ?? source, frame: frame))
                }
            }
        }
        if !seen.contains(selectedID) { items.insert(initial, at: 0); selectedID = initial.id }
        return (items, selectedID)
    }
}
