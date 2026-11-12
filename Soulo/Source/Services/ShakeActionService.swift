import SwiftUI
import UIKit
import CoreMotion

enum BrowserShakeAction: String, CaseIterable, Identifiable {
    case none
    case fullscreen
    case darkMode
    case reload
    case closeTab

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .none: "shake_action_none"
        case .fullscreen: "shake_action_fullscreen"
        case .darkMode: "shake_action_dark"
        case .reload: "shake_action_reload"
        case .closeTab: "shake_action_close_tab"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "minus.circle"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .darkMode: "moon.fill"
        case .reload: "arrow.clockwise"
        case .closeTab: "xmark.square"
        }
    }
}

enum BrowserShakeDirection: String, CaseIterable, Identifiable {
    case horizontal, vertical, any
    static let preferenceKey = "browser_shake_direction"
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .horizontal: "shake_direction_horizontal"
        case .vertical: "shake_direction_vertical"
        case .any: "shake_direction_any"
        }
    }
    var symbol: String {
        switch self {
        case .horizontal: "arrow.left.and.right"
        case .vertical: "arrow.up.and.down"
        case .any: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
    /// Core Motion uses device axes; rotate the selected axis with the screen.
    func magnitude(_ acceleration: CMAcceleration, orientation: UIInterfaceOrientation) -> Double? {
        let x = abs(acceleration.x), y = abs(acceleration.y), z = abs(acceleration.z)
        if self == .any { return sqrt(x * x + y * y + z * z) }
        let landscape = orientation.isLandscape
        let horizontal = landscape ? y : x, vertical = landscape ? x : y
        let selected = self == .horizontal ? horizontal : vertical
        let other = self == .horizontal ? vertical : horizontal
        // Lifting the phone, tapping its back or moving diagonally must not
        // accumulate peaks toward an axis-specific shake.
        return selected > max(other, z) * 1.35 ? selected : nil
    }
}

enum BrowserShakeIntensity: String, CaseIterable, Identifiable {
    case light
    case standard
    case firm
    case strong

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .light: "shake_intensity_light"
        case .standard: "shake_intensity_standard"
        case .firm: "shake_intensity_firm"
        case .strong: "shake_intensity_strong"
        }
    }

    var systemImage: String {
        switch self {
        case .light: "waveform.path"
        case .standard: "waveform.path.ecg"
        case .firm: "waveform.path.ecg.rectangle"
        case .strong: "burst.fill"
        }
    }

    var peakThreshold: Double {
        switch self {
        case .light: 0.28
        case .standard: 0.42
        case .firm: 0.60
        case .strong: 0.80
        }
    }

    var strongPeakThreshold: Double {
        switch self {
        case .light: 0.75
        case .standard: 1.00
        case .firm: 1.35
        case .strong: 1.65
        }
    }
}

/// Converts a short sequence of modest acceleration peaks into one deliberate shake.
/// Using two peaks avoids accidental triggers while remaining more responsive than
/// UIKit's fixed system shake threshold.
struct ShakeMotionClassifier {
    static let minimumPeakSpacing: TimeInterval = 0.07
    static let peakWindow: TimeInterval = 0.48
    static let cooldown: TimeInterval = 0.8

    private var firstPeakTime: TimeInterval?
    private var lastPeakTime: TimeInterval?
    private var peakCount = 0
    private var cooldownUntil: TimeInterval = 0
    private let intensity: BrowserShakeIntensity
    private var lastDirection: BrowserShakeDirection?
    private var lastOrientation: UIInterfaceOrientation?

    init(intensity: BrowserShakeIntensity = .standard) {
        self.intensity = intensity
    }

    mutating func register(acceleration: CMAcceleration, direction: BrowserShakeDirection,
                           orientation: UIInterfaceOrientation, at timestamp: TimeInterval) -> Bool {
        if lastDirection != direction || lastOrientation != orientation {
            resetCandidate(); lastDirection = direction; lastOrientation = orientation
        }
        guard let magnitude = direction.magnitude(acceleration, orientation: orientation) else {
            if max(abs(acceleration.x), abs(acceleration.y), abs(acceleration.z)) >= intensity.peakThreshold { resetCandidate() }
            return false
        }
        return register(magnitude: magnitude, at: timestamp)
    }

    mutating func register(magnitude: Double, at timestamp: TimeInterval) -> Bool {
        guard timestamp >= cooldownUntil, magnitude >= intensity.peakThreshold else { return false }

        if magnitude >= intensity.strongPeakThreshold {
            completeShake(at: timestamp)
            return true
        }

        if let lastPeakTime,
           timestamp - lastPeakTime < Self.minimumPeakSpacing {
            return false
        }

        if let firstPeakTime,
           timestamp - firstPeakTime <= Self.peakWindow {
            peakCount += 1
        } else {
            firstPeakTime = timestamp
            peakCount = 1
        }
        lastPeakTime = timestamp

        guard peakCount >= 2 else { return false }
        completeShake(at: timestamp)
        return true
    }

    mutating func resetCandidate() {
        firstPeakTime = nil
        lastPeakTime = nil
        peakCount = 0
    }

    private mutating func completeShake(at timestamp: TimeInterval) {
        resetCandidate()
        cooldownUntil = timestamp + Self.cooldown
    }
}

struct DeviceShakeDetector: UIViewControllerRepresentable {
    let isEnabled: Bool
    let intensity: BrowserShakeIntensity
    var direction: BrowserShakeDirection = .horizontal
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let controller = ShakeViewController()
        controller.isEnabled = isEnabled
        controller.intensity = intensity
        controller.direction = direction
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ uiViewController: ShakeViewController, context: Context) {
        uiViewController.onShake = onShake
        uiViewController.intensity = intensity
        uiViewController.direction = direction
        uiViewController.isEnabled = isEnabled
        if isEnabled {
            uiViewController.startMotionUpdatesIfNeeded()
        }
    }

    final class ShakeViewController: UIViewController {
        var onShake: (() -> Void)?
        var intensity: BrowserShakeIntensity = .standard {
            didSet {
                guard intensity != oldValue else { return }
                motionClassifier = ShakeMotionClassifier(intensity: intensity)
            }
        }
        var direction: BrowserShakeDirection = .horizontal {
            didSet { if direction != oldValue { motionClassifier.resetCandidate() } }
        }
        var isEnabled = false {
            didSet {
                guard isEnabled != oldValue else { return }
                if isEnabled {
                    startMotionUpdatesIfNeeded()
                } else {
                    stopMotionUpdates()
                }
            }
        }

        private let motionManager = CMMotionManager()
        private var motionClassifier = ShakeMotionClassifier()
        private var lastDeliveryTime: TimeInterval = -.infinity

        override var canBecomeFirstResponder: Bool {
            isEnabled && direction == .any && !motionManager.isDeviceMotionAvailable
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard isEnabled else { return }
            startMotionUpdatesIfNeeded()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopMotionUpdates()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            super.motionEnded(motion, with: event)
            guard isEnabled,
                  motion == .motionShake,
                  direction == .any,
                  !motionManager.isDeviceMotionActive else { return }
            deliverShake(at: ProcessInfo.processInfo.systemUptime)
        }

        func startMotionUpdatesIfNeeded() {
            guard isEnabled,
                  let window = viewIfLoaded?.window else { return }
            // Core Motion does not need keyboard focus. The UIKit fallback may
            // claim an idle window, but must never replace a page or text field.
            guard motionManager.isDeviceMotionAvailable else {
                if direction == .any && !containsFirstResponder(in: window) { becomeFirstResponder() }
                return
            }
            guard !motionManager.isDeviceMotionActive else { return }

            motionManager.deviceMotionUpdateInterval = 1.0 / 40.0
            motionClassifier = ShakeMotionClassifier(intensity: intensity)
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, self.isEnabled, let acceleration = motion?.userAcceleration else { return }
                let orientation = self.view.window?.windowScene?.interfaceOrientation ?? .portrait
                let timestamp = ProcessInfo.processInfo.systemUptime
                if self.motionClassifier.register(acceleration: acceleration, direction: self.direction,
                                                   orientation: orientation, at: timestamp) {
                    self.deliverShake(at: timestamp)
                }
            }
        }

        private func stopMotionUpdates() {
            motionManager.stopDeviceMotionUpdates()
            motionClassifier.resetCandidate()
        }

        private func containsFirstResponder(in view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains { containsFirstResponder(in: $0) }
        }

        private func deliverShake(at timestamp: TimeInterval) {
            guard timestamp - lastDeliveryTime >= ShakeMotionClassifier.cooldown else { return }
            lastDeliveryTime = timestamp
            onShake?()

            // An action can change the presentation. Resume detection without
            // taking focus from an editor that became active in the meantime.
            DispatchQueue.main.async { [weak self] in
                self?.startMotionUpdatesIfNeeded()
            }
        }
    }
}
