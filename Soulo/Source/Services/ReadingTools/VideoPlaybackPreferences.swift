import AVFoundation
import Foundation

enum VideoPlaybackPreferences {
    static let takesOverWebPlayersKey = "video.takeOverWebPlayers"
    static func takesOverWebPlayers(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: takesOverWebPlayersKey)
    }
    static let showsToolsKey = "video.showsWebTools"
    static let holdSpeedKey = "video.holdSpeed"
    static let showsEpisodeDockKey = "video.showsEpisodeDock"
    // Presentation only: download transports and existing tasks never consult this key.
    static let showsWebDownloadControlsKey = "video.showsWebDownloadControls"
    static func showsWebDownloadControls(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsWebDownloadControlsKey) == nil || defaults.bool(forKey: showsWebDownloadControlsKey)
    }
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

/// A full-width swipe covers up to five minutes, with bounds shared by both decoders.
enum VideoSeekGesture {
    static func target(start: Double, duration: Double, translation: CGFloat, width: CGFloat) -> Double? {
        guard start.isFinite, duration.isFinite, duration > 0, translation.isFinite, width.isFinite, width > 0 else { return nil }
        return min(duration, max(0, start + Double(translation / width) * min(duration, 300)))
    }
}

/// Startup warnings are recoverable. Pauses/background time never count as a failed start.
struct VideoStartupWatch {
    private var since: TimeInterval?
    private(set) var completed = false
    mutating func update(now: TimeInterval, requested: Bool, ready: Bool) -> Bool {
        if ready { completed = true; since = nil }
        guard !completed, requested else { since = nil; return false }
        if since == nil { since = now }
        return now - (since ?? now) >= 5
    }
}

struct VideoProgressWatch {
    private var checkpoint: (position: Double, lastMovement: ContinuousClock.Instant, lastActivity: ContinuousClock.Instant)?

    mutating func stalled(at position: Double, requested: Bool, receivingData: Bool = false,
                          now: ContinuousClock.Instant = .now) -> Bool {
        guard requested, position.isFinite else { checkpoint = nil; return false }
        guard var current = checkpoint, abs(position - current.position) < 0.05 else {
            checkpoint = (position, now, now)
            return false
        }
        if receivingData { current.lastActivity = now }
        checkpoint = current
        return current.lastActivity.duration(to: now) >= .seconds(12) || current.lastMovement.duration(to: now) >= .seconds(30)
    }
}

enum VideoLoadingStatus: Equatable {
    case rate(Int64)
    case complete

    var isTransferring: Bool {
        if case .rate = self { return true }
        return false
    }

    static func isOnline(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func coversVideo(_ ranges: [CMTimeRange], duration: CMTime) -> Bool {
        guard duration.isNumeric, duration > .zero else { return false }
        var loadedThrough = CMTime.zero
        for range in ranges.filter({ $0.start.isNumeric && $0.end.isNumeric && $0.duration > .zero })
            .sorted(by: { $0.start < $1.start }) {
            guard range.start <= loadedThrough else { break }
            loadedThrough = max(loadedThrough, range.end)
            if loadedThrough >= duration { return true }
        }
        return false
    }
}

struct VideoCacheCoverage {
    var ranges: [Range<Double>] = []
    var fileFraction: Double?
    var isComplete = false
}

struct VideoCacheProgress: Equatable {
    var timeFractions: [Range<Double>] = []
    var fileFraction: Double?

    init(duration: Double = 0, buffered: [CMTimeRange] = [], cache: VideoCacheCoverage = .init()) {
        fileFraction = cache.fileFraction
        guard duration.isFinite, duration > 0 else { return }
        if cache.isComplete { timeFractions = [0..<1]; return }

        let times = buffered.compactMap { range -> Range<Double>? in
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite, start < end else { return nil }
            return start..<end
        } + cache.ranges
        for range in times.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(0, range.lowerBound / duration), end = min(1, range.upperBound / duration)
            guard start < end else { continue }
            if let last = timeFractions.last, start <= last.upperBound {
                timeFractions[timeFractions.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                timeFractions.append(start..<end)
            }
        }
    }
}

struct VideoTransferMeter {
    private var previous: (bytes: Int64, time: ContinuousClock.Instant)?

    mutating func rate(totalBytes: Int64?, now: ContinuousClock.Instant = .now) -> VideoLoadingStatus? {
        guard let totalBytes, totalBytes >= 0 else { previous = nil; return nil }
        defer { previous = (totalBytes, now) }
        guard let previous, totalBytes > previous.bytes else { return nil }
        let elapsed = previous.time.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard seconds > 0, let rate = Int64(exactly: (Double(totalBytes - previous.bytes) / seconds).rounded()) else {
            return nil
        }
        return .rate(rate)
    }
}
