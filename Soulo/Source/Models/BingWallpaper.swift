import Foundation

struct BingWallpaper: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    let copyright: String
    let title: String

    var fullURL: URL? {
        URL(string: "https://www.bing.com\(url)")
    }

    var thumbURL: URL? {
        guard let full = fullURL else { return nil }
        let thumbString = full.absoluteString
            .replacingOccurrences(of: "1920x1080", with: "640x360")
        if let thumbURL = URL(string: thumbString), thumbString != full.absoluteString {
            return thumbURL
        }
        return URL(string: full.absoluteString + "&w=640&h=360&rs=1&c=4")
    }
}

enum WallpaperMode: String, Codable, CaseIterable {
    case bing = "bing"
    case custom = "custom"
    case none = "none"

    var nameKey: String {
        switch self {
        case .bing:   return "wallpaper_bing"
        case .custom: return "wallpaper_custom"
        case .none:   return "wallpaper_none"
        }
    }
}
