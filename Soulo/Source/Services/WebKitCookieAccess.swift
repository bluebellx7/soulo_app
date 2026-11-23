import WebKit

@MainActor
enum WebKitCookieAccess {
    static func cookies(for url: URL, in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        // The URL-scoped WebKit API can crash before calling back on iOS 27.2
        // and 27.2.1. Filter the established asynchronous store API locally.
        let cookies: [HTTPCookie] = await withCheckedContinuation { reply in
            store.getAllCookies { reply.resume(returning: $0) }
        }
        return WebResourceDownloadService.matchingCookies(from: cookies, for: url)
    }
}
