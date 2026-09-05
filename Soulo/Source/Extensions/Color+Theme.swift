import SwiftUI
import DKlugeCore // provides Color(hex:)

/// One dynamic accent shared by SwiftUI, UIKit and app-owned web overlays.
/// Future user-selected themes should be resolved here rather than in controls.
enum AppTheme {
    static var uiAccent: UIColor { .systemBlue }

    static func accentCSS(for style: UIUserInterfaceStyle) -> String {
        let color = uiAccent.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()),
                      Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

extension Color {
    static let themePrimary = Color(uiColor: AppTheme.uiAccent)
    static let themeBackground = Color(UIColor.systemBackground)
    static let themeSecondaryBg = Color(UIColor.secondarySystemBackground)
    static let themeTertiaryBg = Color(UIColor.tertiarySystemBackground)
    static let themeGroupedBg = Color(UIColor.systemGroupedBackground)
    static let themeCard = Color(UIColor.secondarySystemGroupedBackground)
    static let themeLabel = Color(UIColor.label)
    static let themeSecondaryLabel = Color(UIColor.secondaryLabel)
    static let themeTertiaryLabel = Color(UIColor.tertiaryLabel)
    static let themeSeparator = Color(UIColor.separator)
}
