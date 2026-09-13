import UIKit

/// Coalesces frequent statistics/progress writes without postponing them forever.
/// State stays current in memory; backgrounding flushes the latest pending value.
@MainActor final class DeferredPersistence: NSObject {
    private let delay: Duration
    private let notificationCenter: NotificationCenter
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?

    init(delay: Duration = .seconds(1), notificationCenter: NotificationCenter = .default) {
        self.delay = delay
        self.notificationCenter = notificationCenter
        super.init()
        notificationCenter.addObserver(self, selector: #selector(flush),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(flush),
            name: UIApplication.willTerminateNotification, object: nil)
    }

    func schedule(_ action: @escaping () -> Void) {
        pending = action
        guard task == nil else { return }
        let delay = delay
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
    }

    @objc func flush() {
        let action = pending
        cancel()
        action?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    deinit {
        task?.cancel()
        notificationCenter.removeObserver(self)
    }
}
