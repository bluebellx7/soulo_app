import SwiftUI

extension Color {
    static let themePrimary = Color("AccentColor")
    static let themeBackground = Color(UIColor.systemBackground)
    static let themeSecondaryBg = Color(UIColor.secondarySystemBackground)
    static let themeTertiaryBg = Color(UIColor.tertiarySystemBackground)
    static let themeGroupedBg = Color(UIColor.systemGroupedBackground)
    static let themeCard = Color(UIColor.secondarySystemGroupedBackground)
    static let themeLabel = Color(UIColor.label)
    static let themeSecondaryLabel = Color(UIColor.secondaryLabel)
    static let themeTertiaryLabel = Color(UIColor.tertiaryLabel)
    static let themeSeparator = Color(UIColor.separator)

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = ((int >> 24) & 0xFF, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
