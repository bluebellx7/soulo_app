import WebKit

struct WebPageToolsAvailability: Equatable {
    var likelyReadable = false
    var mediaCount = 0
    var mediaRate = 1.0

    func shouldShowMediaRate(for url: URL?) -> Bool {
        if mediaCount > 0 { return true }
        // Douyin swaps/lazily mounts its player. Keep an explicit video page's
        // action reachable even during a scan with no attached media source.
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              host == "douyin.com" || host.hasSuffix(".douyin.com") else { return false }
        let parts = url.path.split(separator: "/")
        func isVideoID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
        }
        if let index = parts.firstIndex(of: "video"), parts.indices.contains(index + 1),
           isVideoID(String(parts[index + 1])) { return true }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return url.path == "/s"
            && query.contains { $0.name == "pd" && $0.value == "video" }
            && query.contains { $0.name == "actv_aid" && isVideoID($0.value ?? "") }
    }

    @MainActor
    static func inspect(_ webView: WKWebView) async -> Self {
        let script = #"""
        let readable = false;
        const seen = new Set();
        const visit = doc => {
            if (!doc || seen.has(doc) || seen.size >= 12) return;
            seen.add(doc);
            const blocks = [...doc.querySelectorAll('article,main,[itemprop="articleBody"],p,pre,#content,#chaptercontent,.chapter-content')].slice(0,600);
            readable ||= blocks.some(node => {
                const style = doc.defaultView.getComputedStyle(node);
                if (style.display === 'none' || style.visibility === 'hidden' || node.closest('nav,aside,footer,[hidden]')) return false;
                const text = node.textContent.trim();
                const linked = [...node.querySelectorAll('a')].reduce((n,a) => n + a.textContent.length,0);
                return text.length >= 160 && linked / text.length < .2;
            });
            doc.querySelectorAll('iframe').forEach(frame => { try { visit(frame.contentDocument); } catch {} });
        };
        visit(document);
        return {readable};
        """#
        let media = await WebMediaPlaybackBridge.inspect(webView)
        // A readability error must not hide a working media player.
        let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        return .init(likelyReadable: result?["readable"] as? Bool ?? false, mediaCount: media.count, mediaRate: media.rate)
    }
}
