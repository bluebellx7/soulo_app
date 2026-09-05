import WebKit

@MainActor enum WebMediaPlaybackBridge {
    static func setRate(_ rate: Double, on webView: WKWebView) async throws -> [Double] {
        guard MediaSession.validRate(Float(rate)) else { throw ReadingToolError.invalid }
        let script = """
        (() => {
            const rates = [];
            const visit = doc => {
                doc.querySelectorAll('video,audio').forEach(media => {
                    try { media.playbackRate = \(rate); rates.push(media.playbackRate); } catch (_) {}
                });
                doc.querySelectorAll('iframe').forEach(frame => { try { if (frame.contentDocument) visit(frame.contentDocument); } catch (_) {} });
            };
            visit(document); return rates;
        })()
        """
        guard let rates = try await webView.evaluateJavaScript(script) as? [Double], !rates.isEmpty else { throw ReadingToolError.unsupported }
        return rates
    }
}
