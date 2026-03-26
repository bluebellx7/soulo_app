import SwiftUI

/// Fetches and displays a website favicon with multiple fallback sources.
struct BookmarkFaviconView: View {
    let urlString: String
    var size: CGFloat = 32

    private var host: String? {
        URL(string: urlString)?.host
    }

    /// Multiple favicon sources — tries in order via AsyncImage cascade
    private var faviconURLs: [URL] {
        guard let host = host else { return [] }
        return [
            // 1. Direct site favicon
            URL(string: "https://\(host)/favicon.ico"),
            // 2. DuckDuckGo favicon API (works globally)
            URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico"),
            // 3. Google favicon API (may be blocked in China)
            URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64"),
        ].compactMap { $0 }
    }

    var body: some View {
        FaviconCascadeView(urls: faviconURLs, size: size)
    }
}

/// Tries loading favicon from multiple URLs — falls back to next on failure.
private struct FaviconCascadeView: View {
    let urls: [URL]
    let size: CGFloat
    var index: Int = 0

    var body: some View {
        if index < urls.count {
            AsyncImage(url: urls[index]) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                case .failure:
                    // Try next URL
                    FaviconCascadeView(urls: urls, size: size, index: index + 1)
                default:
                    // Loading placeholder
                    faviconPlaceholder
                }
            }
        } else {
            faviconPlaceholder
        }
    }

    private var faviconPlaceholder: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "globe")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white.opacity(0.5))
            )
    }
}
