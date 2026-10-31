import WebKit

enum BrowserAdNavigationPolicy {
    static func shouldBlock(
        url: URL, sourceURL: URL?, navigationType: WKNavigationType,
        isNewWindow: Bool, sourceIsMainFrame: Bool,
        hasRecentGesture: Bool, gestureDestination: URL?, gestureIsControl: Bool,
        gestureIsLink: Bool = false, gestureIsForm: Bool = false,
        mainDocumentURL: URL? = nil
    ) -> Bool {
        if navigationType == .backForward || navigationType == .reload { return false }
        // A verification frame may return the top document to its requested
        // URL. This is not an advertising click-through or permission to open
        // a new tab / unrelated destination.
        if !isNewWindow, !sourceIsMainFrame,
           isCloudflareChallengeReturn(from: sourceURL, to: url, mainDocumentURL: mainDocumentURL) { return false }
        let intendedLink = hasRecentGesture && gestureDestination.map { matches($0, url) } == true
        if intendedLink { return false }
        // WebKit reports delegated result-card navigation as .other, and a
        // site's click handler may replace its tracking href. A real click on
        // a navigational element still authorizes the main-frame request.
        if hasRecentGesture && sourceIsMainFrame {
            if gestureIsLink && (navigationType == .linkActivated || (!isNewWindow && navigationType == .other)) { return false }
            if gestureIsForm && (navigationType == .formSubmitted || navigationType == .formResubmitted) { return false }
        }
        if url.absoluteString == "about:blank" && hasRecentGesture && gestureIsControl { return false }
        let authentication = url.scheme?.lowercased() != "about"
            && BrowserPopupPolicy.shouldPreserveJavaScriptContext(navigationType: navigationType, url: url)
        if authentication && hasRecentGesture && gestureIsControl { return false }
        let sameHost = sourceURL?.host?.lowercased() == url.host?.lowercased() && url.host != nil
        if isNewWindow {
            // A click on the page background or a player is not consent to open
            // an unrelated tab. Same-site script buttons remain usable.
            return !(sameHost && hasRecentGesture && gestureIsControl)
        }
        if navigationType == .other || navigationType == .linkActivated {
            // Stop iframe click-throughs and scripts that replace the requested
            // link with an advertising destination during a real interaction.
            if !sourceIsMainFrame { return true }
            if !sameHost && hasRecentGesture { return true }
        }
        return false
    }

    private static func isCloudflareChallengeReturn(from source: URL?, to destination: URL, mainDocumentURL: URL?) -> Bool {
        guard let source, let mainDocumentURL,
              WebCompatibilityService.isCloudflareChallengeURL(source),
              ["http", "https"].contains(mainDocumentURL.scheme?.lowercased() ?? ""),
              destination.scheme?.lowercased() == mainDocumentURL.scheme?.lowercased(),
              destination.host?.lowercased() == mainDocumentURL.host?.lowercased(),
              destination.port == mainDocumentURL.port, destination.path == mainDocumentURL.path,
              destination.user == nil, destination.password == nil else { return false }
        let host = source.host?.lowercased() ?? ""
        return host == "challenges.cloudflare.com" || host.hasSuffix(".challenges.cloudflare.com")
            || (host == mainDocumentURL.host?.lowercased() && source.scheme == mainDocumentURL.scheme && source.port == mainDocumentURL.port)
    }

    private static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        var first = URLComponents(url: lhs, resolvingAgainstBaseURL: true)
        var second = URLComponents(url: rhs, resolvingAgainstBaseURL: true)
        first?.fragment = nil
        second?.fragment = nil
        return first?.url == second?.url
    }
}
