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

/// Converts a short sequence of modest acceleration peaks into one deliberate shake.
/// Using two peaks avoids accidental triggers while remaining more responsive than
/// UIKit's fixed system shake threshold.
struct ShakeMotionClassifier {
    static let peakThreshold = 0.6
    static let strongPeakThreshold = 1.35
    static let minimumPeakSpacing: TimeInterval = 0.07
    static let peakWindow: TimeInterval = 0.48
    static let cooldown: TimeInterval = 0.8

    private var firstPeakTime: TimeInterval?
    private var lastPeakTime: TimeInterval?
    private var peakCount = 0
    private var cooldownUntil: TimeInterval = 0

    mutating func register(magnitude: Double, at timestamp: TimeInterval) -> Bool {
        guard timestamp >= cooldownUntil, magnitude >= Self.peakThreshold else { return false }

        if magnitude >= Self.strongPeakThreshold {
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
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let controller = ShakeViewController()
        controller.isEnabled = isEnabled
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ uiViewController: ShakeViewController, context: Context) {
        uiViewController.onShake = onShake
        uiViewController.isEnabled = isEnabled
        if isEnabled {
            uiViewController.becomeFirstResponder()
            uiViewController.startMotionUpdatesIfNeeded()
        }
    }

    final class ShakeViewController: UIViewController {
        var onShake: (() -> Void)?
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

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard isEnabled else { return }
            becomeFirstResponder()
            startMotionUpdatesIfNeeded()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopMotionUpdates()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            super.motionEnded(motion, with: event)
            guard isEnabled, motion == .motionShake else { return }
            deliverShake(at: ProcessInfo.processInfo.systemUptime)
        }

        func startMotionUpdatesIfNeeded() {
            guard isEnabled,
                  viewIfLoaded?.window != nil,
                  motionManager.isDeviceMotionAvailable,
                  !motionManager.isDeviceMotionActive else { return }

            motionManager.deviceMotionUpdateInterval = 1.0 / 40.0
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, self.isEnabled, let acceleration = motion?.userAcceleration else { return }
                let magnitude = sqrt(
                    acceleration.x * acceleration.x
                        + acceleration.y * acceleration.y
                        + acceleration.z * acceleration.z
                )
                let timestamp = ProcessInfo.processInfo.systemUptime
                if self.motionClassifier.register(magnitude: magnitude, at: timestamp) {
                    self.deliverShake(at: timestamp)
                }
            }
        }

        private func stopMotionUpdates() {
            motionManager.stopDeviceMotionUpdates()
            motionClassifier.resetCandidate()
        }

        private func deliverShake(at timestamp: TimeInterval) {
            guard timestamp - lastDeliveryTime >= ShakeMotionClassifier.cooldown else { return }
            lastDeliveryTime = timestamp
            onShake?()

            // Web content may become first responder after navigation or a full-screen change.
            // Reclaim it for the UIKit fallback while Core Motion keeps listening independently.
            DispatchQueue.main.async { [weak self] in
                guard self?.isEnabled == true else { return }
                self?.becomeFirstResponder()
            }
        }
    }
}
