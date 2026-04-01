import SwiftUI
@_exported import DKlugeTheme

// MARK: - Soulo-specific compatibility

extension ThemeManager {
    /// Alias for appearanceMode (Soulo call sites use `appearance`).
    var appearance: String {
        get { appearanceMode }
        set { appearanceMode = newValue }
    }

    /// Alias for colorScheme (Soulo call sites use preferredColorScheme).
    var preferredColorScheme: ColorScheme? { colorScheme }
}
