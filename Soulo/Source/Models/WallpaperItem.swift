import SwiftUI

enum WallpaperSource: String, Codable, CaseIterable {
    case pexels = "pexels"
    case pixabay = "pixabay"
    case bing = "bing"
    case gradient = "gradient"
    case photo = "photo"
    case solid = "solid"

    @MainActor var localizedName: String {
        switch self {
        case .pexels:   return LText("wallpaper_pexels")
        case .pixabay:  return LText("wallpaper_pixabay")
        case .bing:     return LText("wallpaper_bing")
        case .gradient: return LText("wallpaper_gradient")
        case .photo:    return LText("wallpaper_photo")
        case .solid:    return LText("wallpaper_solid")
        }
    }

    var isRemote: Bool {
        self == .pexels || self == .pixabay || self == .bing
    }
}

enum WallpaperRefreshInterval: Int, CaseIterable, Codable {
    case none = 0
    case min1 = 60
    case min5 = 300
    case min15 = 900
    case min30 = 1800
    case hour1 = 3600
    case day1 = 86400

    @MainActor var localizedName: String {
        switch self {
        case .none: return LText("wallpaper_interval_none")
        case .min1: return LText("wallpaper_interval_1min")
        case .min5: return LText("wallpaper_interval_5min")
        case .min15: return LText("wallpaper_interval_15min")
        case .min30: return LText("wallpaper_interval_30min")
        case .hour1: return LText("wallpaper_interval_1hour")
        case .day1: return LText("wallpaper_interval_1day")
        }
    }
}

struct GradientPreset: Identifiable {
    let id: String
    let colors: [Color]
    let startPoint: UnitPoint
    let endPoint: UnitPoint
    let isLight: Bool
    
    init(id: String, colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint, isLight: Bool = false) {
        self.id = id
        self.colors = colors
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.isLight = isLight
    }
    
    static let presets: [GradientPreset] = [
        GradientPreset(id: "serenity", colors: [Color(hex: "#F4F5F7"), Color(hex: "#E2E8F0"), Color(hex: "#FFFDF0")], startPoint: .top, endPoint: .bottom, isLight: true),
        GradientPreset(id: "aurora",   colors: [Color(hex: "#4A3F8A"), Color(hex: "#6B5CA5"), Color(hex: "#3A7CA5")], startPoint: .topLeading, endPoint: .bottomTrailing),
        GradientPreset(id: "dawn",     colors: [Color(hex: "#2D1B3D"), Color(hex: "#8B3A62"), Color(hex: "#C97B4B")], startPoint: .top, endPoint: .bottom),
        GradientPreset(id: "deep_sea", colors: [Color(hex: "#0A0E1A"), Color(hex: "#12203A"), Color(hex: "#1A3050")], startPoint: .topLeading, endPoint: .bottomTrailing),
        GradientPreset(id: "forest",   colors: [Color(hex: "#1A2A1A"), Color(hex: "#2D4A3A"), Color(hex: "#3A5A4A")], startPoint: .top, endPoint: .bottom),
        GradientPreset(id: "cyber",    colors: [Color(hex: "#1A0A2E"), Color(hex: "#3D1A6E"), Color(hex: "#5B2D8E")], startPoint: .leading, endPoint: .trailing),
        GradientPreset(id: "minimal",  colors: [Color(hex: "#1A1A2E"), Color(hex: "#2A2A3E"), Color(hex: "#3A3A4E")], startPoint: .topLeading, endPoint: .bottomTrailing),
    ]
}

// Data model for Remote Wallpapers to handle likes/blocks
struct RemoteWallpaper: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let previewURL: String
    let source: String
    var topic: String = "Nature"
    var isFavorite: Bool = false

    init(id: String, url: String, previewURL: String, source: String, topic: String = "Nature", isFavorite: Bool = false) {
        self.id = id
        self.url = url
        self.previewURL = previewURL
        self.source = source
        self.topic = topic
        self.isFavorite = isFavorite
    }

    enum CodingKeys: String, CodingKey {
        case id, url, previewURL, source, topic, isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        previewURL = try c.decode(String.self, forKey: .previewURL)
        source = try c.decode(String.self, forKey: .source)
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? "Nature"
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}
