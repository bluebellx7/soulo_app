import SwiftUI

/// Cached favicon shared across lists; failed requests keep a stable placeholder.
struct BookmarkFaviconView: View {
    let urlString: String
    var size: CGFloat = 32
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @State private var backplate: WebsiteFaviconService.Backplate = .automatic

    var body: some View {
        Group {
            if let image, loadedURL == WebsiteFaviconService.iconURL(for: urlString) {
                Image(uiImage: image).resizable().scaledToFit()
                    .padding(max(1, size * 0.05))
                    .frame(width: size, height: size)
                    .background(backplateColor)
            } else {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: "globe")
                            .font(.system(size: size * 0.5)).foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .accessibilityHidden(true)
        .task(id: WebsiteFaviconService.iconURL(for: urlString)) {
            let key = WebsiteFaviconService.iconURL(for: urlString)
            image = nil; loadedURL = nil; backplate = .automatic
            let result = await WebsiteFaviconService.shared.image(for: urlString)
            guard !Task.isCancelled else { return }
            loadedURL = key
            backplate = result.map(WebsiteFaviconService.backplate) ?? .automatic
            image = result
        }
    }

    private var backplateColor: Color {
        switch backplate {
        case .automatic: Color.primary.opacity(0.06)
        case .light: Color(red: 0.95, green: 0.96, blue: 0.97)
        case .dark: Color(red: 0.20, green: 0.24, blue: 0.30)
        }
    }
}
