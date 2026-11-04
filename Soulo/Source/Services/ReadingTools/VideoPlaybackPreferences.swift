import Foundation

enum VideoPlaybackPreferences {
    static let showsToolsKey = "video.showsWebTools"
    static let defaultPlayerKey = "video.defaultPlayer"
    static let holdSpeedKey = "video.holdSpeed"
    static let showsEpisodeDockKey = "video.showsEpisodeDock"
    static func showsEpisodeDock(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsEpisodeDockKey) == nil || defaults.bool(forKey: showsEpisodeDockKey)
    }
    static let holdSpeeds: [Double] = [1.25, 1.5, 1.75, 2, 2.5, 3, 4]
    static func holdSpeed(in defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: holdSpeedKey)
        return holdSpeeds.contains(value) ? value : 2
    }
    static func showsTools(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsToolsKey) == nil || defaults.bool(forKey: showsToolsKey)
    }
    static func usesSystemPlayer(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: defaultPlayerKey) == "system"
    }
}

/// Keep a committed seek visible until the decoder reaches it. Its previous
/// clock can continue reporting while a remote segment is being buffered.
struct VideoPlaybackSeek {
    let id = UUID()
    let target: Double
    let started: ContinuousClock.Instant
    init(target: Double, started: ContinuousClock.Instant = .now) { self.target = target; self.started = started }
    func isPending(actual: Double, now: ContinuousClock.Instant = .now) -> Bool {
        abs(actual - target) > 1.5 && started.duration(to: now) < .seconds(20)
    }
}
