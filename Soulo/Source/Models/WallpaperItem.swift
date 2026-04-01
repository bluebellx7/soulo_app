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
}

struct GradientPreset: Identifiable {
    let id: String
    let colors: [Color]
    let startPoint: UnitPoint
    let endPoint: UnitPoint
    
    static let presets: [GradientPreset] = [
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
    var isFavorite: Bool = false
}
