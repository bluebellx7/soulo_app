import SwiftUI

class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var appearance: String {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    private init() {
        self.appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
    }

    func setAppearance(_ mode: String) {
        appearance = mode
    }
}
