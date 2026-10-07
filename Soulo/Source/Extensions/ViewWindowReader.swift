import SwiftUI

/// Read the window that actually contains a view. A scene can change its
/// display and bounds without creating a new SwiftUI view (folding, resizing).
struct ViewWindowReader: UIViewRepresentable {
    var onChange: (UIWindow?) -> Void

    final class Host: UIView {
        var onChange: ((UIWindow?) -> Void)?
        private weak var reportedWindow: UIWindow?
        private weak var reportedScreen: UIScreen?
        private var reportedBounds = CGRect.null
        private var updateScheduled = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleUpdate()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            // Avoid changing SwiftUI state during a layout/update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                let screen = self.window?.windowScene?.screen
                let bounds = self.window?.bounds ?? .null
                guard self.window !== self.reportedWindow || screen !== self.reportedScreen
                    || bounds != self.reportedBounds else { return }
                self.reportedWindow = self.window
                self.reportedScreen = screen
                self.reportedBounds = bounds
                self.onChange?(self.window)
            }
        }
    }

    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: Host, context: Context) {
        view.onChange = onChange
    }
}
