import SwiftUI

enum WallpaperAppearance: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
    static func appPreference(_ mode: String?, systemIsDark: Bool) -> Self {
        switch mode {
        case "light": .light
        case "dark": .dark
        default: systemIsDark ? .dark : .light
        }
    }
    @MainActor var localizedName: String { LText("appearance_" + rawValue) }
    func key(_ base: String) -> String { base + "_" + rawValue }
}

struct WallpaperAppearancePreset: Equatable {
    var gradientID: String?
    var solidColor: String?
}

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


/// Compare both foreground choices in linear light, including saturated colors.
enum WallpaperContrast {
    static let defaultImageOverlayAmount = 0.30

    struct ImageSample: Sendable {
        private static let side = 32
        private let pixels: [UInt8]
        private let imageSize: CGSize

        init?(_ image: CGImage) {
            let side = Self.side
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drawn else { return nil }
            self.pixels = pixels
            imageSize = CGSize(width: image.width, height: image.height)
        }

        func prefersDarkText(overlayAmount: Double = 0) -> Bool {
            prefersDarkText(in: CGRect(x: 0, y: 0, width: 1, height: 1), overlayAmount: overlayAmount)
        }

        func prefersDarkText(in bounds: CGRect, wallpaperFrame: CGRect, overlayAmount: Double, blurRadius: CGFloat) -> Bool? {
            guard !wallpaperFrame.isEmpty, !bounds.isEmpty else { return nil }
            let visible = bounds.intersection(wallpaperFrame)
            guard !visible.isEmpty else { return nil }
            let scale = max(wallpaperFrame.width / imageSize.width, wallpaperFrame.height / imageSize.height)
                * WallpaperContrast.blurScale(blurRadius, in: wallpaperFrame.size)
            let width = imageSize.width * scale
            let height = imageSize.height * scale
            let origin = CGPoint(x: wallpaperFrame.midX - width / 2, y: wallpaperFrame.midY - height / 2)
            let sampleBounds = visible.insetBy(dx: -blurRadius, dy: -blurRadius)
            return prefersDarkText(in: CGRect(x: (sampleBounds.minX - origin.x) / width,
                y: (sampleBounds.minY - origin.y) / height, width: sampleBounds.width / width,
                height: sampleBounds.height / height), overlayAmount: overlayAmount)
        }

        private func prefersDarkText(in rect: CGRect, overlayAmount: Double) -> Bool {
            let side = Self.side
            func cells(_ lower: CGFloat, _ upper: CGFloat) -> Range<Int> {
                let start = min(side - 1, max(0, Int(floor(lower * CGFloat(side)))))
                return start..<max(start + 1, min(side, Int(ceil(upper * CGFloat(side)))))
            }
            let xs = cells(rect.minX, rect.maxX), ys = cells(rect.minY, rect.maxY)
            let scale = (1 - overlayAmount) / 255
            var sum = 0.0
            for y in ys {
                for x in xs {
                    let i = (y * side + x) * 4
                    sum += WallpaperContrast.luminance(red: Double(pixels[i]) * scale,
                        green: Double(pixels[i + 1]) * scale, blue: Double(pixels[i + 2]) * scale)
                }
            }
            return WallpaperContrast.prefersDarkText(luminance: sum / Double(xs.count * ys.count))
        }
    }

    static func blurScale(_ radius: CGFloat, in size: CGSize) -> CGFloat {
        1 + radius * 4 / max(1, min(size.width, size.height))
    }

    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func prefersDarkText(luminance: Double) -> Bool {
        let dark = self.luminance(red: 46.0/255, green: 42.0/255, blue: 71.0/255)
        return (luminance + 0.05) / (dark + 0.05) >= 1.05 / (luminance + 0.05)
    }

    static func prefersDarkText(hex: String) -> Bool {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return false }
        return prefersDarkText(luminance: luminance(red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255))
    }
}
