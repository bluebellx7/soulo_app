import WebKit

@MainActor
enum WebKitCookieAccess {
    static func cookies(for url: URL, in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        // Xcode 27 exposes the URL-scoped public API. Keep the old SDK path
        // buildable, and always apply the same credential boundary afterwards.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return WebResourceDownloadService.matchingCookies(from: await store.cookies(for: url), for: url)
        }
        #endif
        let cookies: [HTTPCookie] = await withCheckedContinuation { reply in
            store.getAllCookies { reply.resume(returning: $0) }
        }
        return WebResourceDownloadService.matchingCookies(from: cookies, for: url)
    }
}
