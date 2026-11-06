import Combine
import Foundation

/// One timer belongs to the shared playback session, not to a player's screen.
/// Leaving the screen or advancing the queue does not restart its deadline.
@MainActor
final class PlaybackSleepTimerService: ObservableObject {
    static let maximumInterval: TimeInterval = 24 * 60 * 60
    @Published private(set) var deadline: Date?
    @Published private(set) var stopsAfterCurrentItem = false
    var isActive: Bool { deadline != nil || stopsAfterCurrentItem }
    var remainingTime: TimeInterval? { deadline.map { max(0, $0.timeIntervalSince(now())) } }

    private let pause: () -> Void
    private let now: () -> Date
    private var wakeup: Task<Void, Never>?
    private var generation = UUID()

    init(pause: @escaping () -> Void, now: @escaping () -> Date = Date.init) {
        self.pause = pause
        self.now = now
    }

    /// Invalid values leave an already configured timer unchanged.
    @discardableResult
    func start(after seconds: TimeInterval) -> Bool {
        let date = now()
        guard seconds.isFinite, seconds > 0, seconds <= Self.maximumInterval,
              date.timeIntervalSince1970.isFinite else { return false }
        cancel()
        deadline = date.addingTimeInterval(seconds)
        scheduleWakeup()
        return true
    }

    func stopAfterCurrentItem() {
        cancel()
        stopsAfterCurrentItem = true
    }

    func cancel() {
        generation = UUID()
        wakeup?.cancel(); wakeup = nil
        deadline = nil
        stopsAfterCurrentItem = false
    }

    /// Call on foregrounding as well as from the scheduled wakeup, because an
    /// inactive process can be resumed after its wall-clock deadline has passed.
    func refresh() {
        guard let deadline, deadline <= now() else { return }
        fire()
    }

    /// Consume before loop/automatic-next logic. A false result keeps an
    /// ordinary deadline alive across the next item in the queue.
    @discardableResult
    func playbackEnded() -> Bool {
        if stopsAfterCurrentItem || (deadline.map { $0 <= now() } ?? false) {
            fire()
            return true
        }
        return false
    }

    private func fire() {
        guard isActive else { return }
        cancel()
        pause()
    }

    private func scheduleWakeup() {
        guard let deadline else { return }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { fire(); return }
        let token = generation
        wakeup = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.generation == token else { return }
            self.refresh()
            // Moving the clock backwards must not abandon a future deadline.
            if self.generation == token, self.deadline != nil { self.scheduleWakeup() }
        }
    }

    deinit { wakeup?.cancel() }
}
