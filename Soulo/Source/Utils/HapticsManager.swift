@_exported import DKlugeCore
import AudioToolbox
import Foundation

enum AppFeedbackPreferences {
    // Keep existing keys so gesture preferences, iCloud, and backups retain
    // their values when these controls become app-wide.
    static let hapticsKey = "browser.swipe.haptics"
    static let soundKey = "browser.swipe.sound"

    static func hapticsEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hapticsKey) == nil || defaults.bool(forKey: hapticsKey)
    }

    static func soundEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: soundKey)
    }
}

enum AppHapticFeedback: CaseIterable, Equatable {
    case light, medium, heavy, selection, success, warning, error
}

struct AppFeedbackPlayer {
    static let shared = AppFeedbackPlayer(defaults: .standard, hapticPlayer: { feedback in
        switch feedback {
        case .light: DKlugeCore.HapticsManager.light()
        case .medium: DKlugeCore.HapticsManager.medium()
        case .heavy: DKlugeCore.HapticsManager.heavy()
        case .selection: DKlugeCore.HapticsManager.selection()
        case .success: DKlugeCore.HapticsManager.success()
        case .warning: DKlugeCore.HapticsManager.warning()
        case .error: DKlugeCore.HapticsManager.error()
        }
    }, soundPlayer: { AudioServicesPlaySystemSound($0) })

    let defaults: UserDefaults
    private let hapticPlayer: (AppHapticFeedback) -> Void
    private let soundPlayer: (SystemSoundID) -> Void

    init(defaults: UserDefaults, hapticPlayer: @escaping (AppHapticFeedback) -> Void,
         soundPlayer: @escaping (SystemSoundID) -> Void) {
        self.defaults = defaults
        self.hapticPlayer = hapticPlayer
        self.soundPlayer = soundPlayer
    }

    func haptic(_ feedback: AppHapticFeedback) {
        guard AppFeedbackPreferences.hapticsEnabled(in: defaults) else { return }
        hapticPlayer(feedback)
    }

    func playSound(_ id: SystemSoundID) {
        guard id != 0, AppFeedbackPreferences.soundEnabled(in: defaults) else { return }
        soundPlayer(id)
    }
}

// All app-owned haptics pass through the same live preference check, including
// callers that previously created UIKit feedback generators directly.
enum HapticsManager {
    static func light() { AppFeedbackPlayer.shared.haptic(.light) }
    static func medium() { AppFeedbackPlayer.shared.haptic(.medium) }
    static func heavy() { AppFeedbackPlayer.shared.haptic(.heavy) }
    static func selection() { AppFeedbackPlayer.shared.haptic(.selection) }
    static func success() { AppFeedbackPlayer.shared.haptic(.success) }
    static func warning() { AppFeedbackPlayer.shared.haptic(.warning) }
    static func error() { AppFeedbackPlayer.shared.haptic(.error) }
}
