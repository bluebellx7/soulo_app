import Combine
import Foundation

/// Optional rendering and prefetch work yields to the user's battery setting
/// and to thermal pressure. Explicit navigation and downloads remain available.
@MainActor
final class BrowserResourcePolicy: ObservableObject {
    static let shared = BrowserResourcePolicy()
    @Published private(set) var allowsSpeculation: Bool
    private let readAllowance: () -> Bool
    private var observers = Set<AnyCancellable>()

    init(notificationCenter: NotificationCenter = .default, readAllowance: @escaping () -> Bool = {
        !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }) {
        self.readAllowance = readAllowance
        allowsSpeculation = readAllowance()
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            notificationCenter.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &observers)
        }
    }

    private func refresh() {
        let next = readAllowance()
        if allowsSpeculation != next { allowsSpeculation = next }
    }
}
