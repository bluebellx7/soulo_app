import UIKit
import UIKit.UIGestureRecognizerSubclass
import Combine
import AudioToolbox

enum BrowserSwipeDirection: String, CaseIterable, Identifiable {
    case right, left
    var id: String { rawValue }
    var title: String { ToolText.text(self == .right ? "gesture_swipe_right" : "gesture_swipe_left") }
    var symbol: String { self == .right ? "arrow.right" : "arrow.left" }
    var defaultAction: BrowserSwipeAction { self == .right ? .closeTab : .tabs }
    var storageKey: String { self == .right ? BrowserSwipePreferences.rightKey : BrowserSwipePreferences.leftKey }
}

enum BrowserSwipeAction: String, CaseIterable, Identifiable {
    case none, closeTab, tabs, newTab, back, forward, reload, home, showToolbar, menu
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .none: LanguageManager.shared.localizedString("none")
        case .closeTab: LanguageManager.shared.localizedString("tab_close")
        case .tabs: LanguageManager.shared.localizedString("browser_tabs")
        case .newTab: LanguageManager.shared.localizedString("tab_new_tab")
        case .back: LanguageManager.shared.localizedString("browser_back")
        case .forward: LanguageManager.shared.localizedString("browser_forward")
        case .reload: LanguageManager.shared.localizedString("browser_reload")
        case .home: LanguageManager.shared.localizedString("home_screen")
        case .showToolbar: ToolText.text("gesture_show_toolbar")
        case .menu: ToolText.text("gesture_quick_menu")
        }
    }
    var symbol: String {
        switch self {
        case .none: "minus.circle"
        case .closeTab: "xmark.square"
        case .tabs: "square.on.square"
        case .newTab: "plus.square"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .reload: "arrow.clockwise"
        case .home: "house"
        case .showToolbar: "rectangle.bottomthird.inset.filled"
        case .menu: "square.grid.2x2"
        }
    }
    static var menuChoices: [Self] { allCases.filter { $0 != .none && $0 != .menu } }
}

enum BrowserSwipePreferences {
    static let enabledByDefault = false
    static let enabledKey = "browser.twoFingerSwipe.enabled"
    static let rightKey = "browser.twoFingerSwipe.right"
    static let leftKey = "browser.twoFingerSwipe.left"
    static let menuKey = "browser.twoFingerSwipe.menu"
    static let noHistoryKey = "browser.noHistorySwipe.action"
    static let executionKey = "browser.swipe.execution"
    static let hapticsKey = AppFeedbackPreferences.hapticsKey
    static let soundKey = AppFeedbackPreferences.soundKey
    static let defaultMenu: [BrowserSwipeAction] = [.back, .forward, .tabs, .closeTab, .newTab, .showToolbar]
    static var defaultMenuValue: String { defaultMenu.map(\.rawValue).joined(separator: ",") }
    static func action(for direction: BrowserSwipeDirection, defaults: UserDefaults = .standard) -> BrowserSwipeAction {
        BrowserSwipeAction(rawValue: defaults.string(forKey: direction.storageKey) ?? "") ?? direction.defaultAction
    }
    static func menu(value: String) -> [BrowserSwipeAction] {
        var seen = Set<BrowserSwipeAction>()
        let actions = value.split(separator: ",").compactMap { BrowserSwipeAction(rawValue: String($0)) }
            .filter { $0 != .none && $0 != .menu && seen.insert($0).inserted }
        return actions.isEmpty ? defaultMenu : actions
    }
}

@MainActor enum BrowserSwipeFeedback {
    static func selection() {
        HapticsManager.selection()
    }

    static func executed() {
        HapticsManager.success()
        AppFeedbackPlayer.shared.playSound(sound)
    }

    // A bundled UI sound uses the system's volume and silent-mode behavior,
    // without changing the audio session or interrupting webpage playback.
    private static let sound: SystemSoundID = {
        guard let url = Bundle.main.url(forResource: "SwipeAction", withExtension: "wav") else { return 0 }
        var identifier: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &identifier) == kAudioServicesNoError else { return 0 }
        return identifier
    }()
}

enum BrowserSwipeExecution: String, CaseIterable, Identifiable {
    case release, tap
    var id: String { rawValue }
    var title: String { ToolText.text(self == .release ? "gesture_execute_release" : "gesture_execute_tap") }
}

@MainActor final class BrowserSwipeRequest: ObservableObject, Identifiable {
    enum Phase: Equatable { case dragging, ready, executing }
    struct Motion {
        var progress: CGFloat
        var distance: CGFloat
        var verticalFraction: CGFloat
        var windowY: CGFloat? = nil
    }
    let id = UUID()
    let direction: BrowserSwipeDirection
    let action: BrowserSwipeAction
    let url: URL?
    let execution: BrowserSwipeExecution
    var completedAt: TimeInterval = 0
    @Published var phase: Phase
    @Published var motion: Motion

    init(direction: BrowserSwipeDirection, action: BrowserSwipeAction, url: URL?,
         execution: BrowserSwipeExecution = .release, phase: Phase = .ready) {
        self.direction = direction; self.action = action; self.url = url
        self.execution = execution; self.phase = phase
        motion = Motion(progress: phase == .dragging ? 0 : 1, distance: 0, verticalFraction: 0.5)
    }

    nonisolated static func requiredDistance(width: CGFloat) -> CGFloat { max(64, min(100, width * 0.2)) }
}

/// Both fingers must travel together. A pinch or rotation changes their relative
/// vector and is rejected before this recognizer claims the gesture.
struct TwoFingerSwipeClassifier {
    enum Decision: Equatable { case waiting, rejected, ready(BrowserSwipeDirection) }
    let first: CGPoint
    let second: CGPoint
    func evaluate(first a: CGPoint, second b: CGPoint, lockedDirection: BrowserSwipeDirection? = nil) -> Decision {
        let dx1 = a.x - first.x, dx2 = b.x - second.x
        let dy1 = a.y - first.y, dy2 = b.y - second.y
        let dx = (dx1 + dx2) / 2, dy = (dy1 + dy2) / 2
        let spacing = hypot(second.x - first.x, second.y - first.y)
        let drift = hypot(dx1 - dx2, dy1 - dy2)
        guard spacing >= 18 else { return .rejected }
        if let lockedDirection {
            // Once recognized, small differences in speed, angle or spacing
            // must not make the hint blink away. Deliberate pinches/vertical
            // movement still cancel, and returning to the start disarms it.
            guard drift <= max(64, spacing * 0.75),
                  abs(dy) <= max(72, abs(dx) * 0.95) else { return .rejected }
            return .ready(lockedDirection)
        }
        guard !(abs(dy) > 24 && abs(dy) > abs(dx) * 0.8) else { return .rejected }
        if drift > max(24, spacing * 0.28) {
            if (dx1 * dx2 < 0 && min(abs(dx1), abs(dx2)) > 12) || drift > max(52, spacing * 0.65) {
                return .rejected
            }
            return .waiting
        }
        guard abs(dx) >= 24, dx1 * dx2 > 0, min(abs(dx1), abs(dx2)) >= 12,
              abs(dy) <= max(18, abs(dx) * 0.65) else { return .waiting }
        return .ready(dx > 0 ? .right : .left)
    }
}

final class TwoFingerSwipeGestureRecognizer: UIGestureRecognizer {
    private var fingers: [UITouch] = []
    private var firstTouchPoint: CGPoint?
    private var classifier: TwoFingerSwipeClassifier?
    private var liftedFingers = Set<UITouch>()
    private(set) var direction: BrowserSwipeDirection?
    private(set) var horizontalDistance: CGFloat = 0
    private(set) var lastLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard fingers.count + touches.count <= 2, state == .possible else { fail(); return }
        fingers.append(contentsOf: touches)
        if fingers.count == 1 { firstTouchPoint = fingers[0].location(in: view) }
        if fingers.count == 2 {
            classifier = TwoFingerSwipeClassifier(first: fingers[0].location(in: view), second: fingers[1].location(in: view))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible || state == .began || state == .changed else { return }
        guard let classifier, fingers.count == 2 else {
            if let finger = fingers.first, let start = firstTouchPoint {
                let point = finger.location(in: view)
                if hypot(point.x - start.x, point.y - start.y) > 28 { fail() }
            }
            return
        }
        // Keep the last two-finger position while the remaining finger lifts.
        // A tiny difference in lift time is normal and must not execute early.
        guard liftedFingers.isEmpty else { return }
        update(first: fingers[0].location(in: view), second: fingers[1].location(in: view), classifier: classifier)
    }

    private func update(first a: CGPoint, second b: CGPoint, classifier: TwoFingerSwipeClassifier) {
        lastLocation = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y))
        let translation = (a.x - classifier.first.x + b.x - classifier.second.x) / 2
        switch classifier.evaluate(first: a, second: b, lockedDirection: direction) {
        case .rejected: fail()
        case .waiting:
            if state == .began || state == .changed { state = .changed }
        case .ready(let result):
            direction = result
            horizontalDistance = max(0, translation * (result == .right ? 1 : -1))
            state = state == .possible ? .began : .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            // Before direction lock, a finger can be repositioned while the
            // other stays down. Keep waiting for a usable pair in that case.
            fingers.removeAll { touches.contains($0) }
            classifier = nil
            firstTouchPoint = fingers.first?.location(in: view)
            if fingers.isEmpty { state = .failed }
            return
        }
        guard state == .began || state == .changed else { return }
        // Ended touches no longer form a live pair. Keep the last movement
        // sample instead of reclassifying coordinates while a finger lifts.
        liftedFingers.formUnion(touches)
        guard fingers.allSatisfy({ liftedFingers.contains($0) }) else { return }
        let threshold = BrowserSwipeRequest.requiredDistance(width: view?.bounds.width ?? 390)
        state = horizontalDistance >= threshold ? .ended : .cancelled
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { fail() }
    override func reset() {
        super.reset()
        fingers = []; liftedFingers = []; firstTouchPoint = nil; classifier = nil; direction = nil; horizontalDistance = 0; lastLocation = .zero
    }
    private func fail() {
        if state == .possible { state = .failed }
        else if state == .began || state == .changed { state = .cancelled }
    }
}
