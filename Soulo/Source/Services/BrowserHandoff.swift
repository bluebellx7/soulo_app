import SwiftUI

/// Only public web pages may leave the device through Handoff.
enum BrowserHandoff {
    static let activityType = "com.dkluge.Soulo.browsing"
    static func eligibleURL(_ url: URL?, isPrivate: Bool) -> URL? {
        guard !isPrivate, let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              !host.isEmpty, host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal") else { return nil }
        // Never publish IP literals (including local network / loopback addresses).
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        return url
    }
}

struct BrowserHandoffModifier: ViewModifier {
    let url: URL?
    let title: String
    let enabled: Bool
    func body(content: Content) -> some View {
        content.userActivity(BrowserHandoff.activityType, element: enabled ? url : nil) { value, activity in
            activity.title = String((title.isEmpty ? value.host ?? "Soulo" : title).prefix(200))
            activity.webpageURL = value
            activity.isEligibleForHandoff = true
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
            activity.isEligibleForPrediction = false
        }
    }
}
