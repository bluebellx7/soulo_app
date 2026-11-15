import AVKit
import SwiftUI

/// The system builds generated-subtitle availability, language choices and
/// caption styles from the current AVPlayer item. Never invent unavailable tracks.
struct SystemSubtitleMenu: View {
    let player: AVPlayer
    let interaction: () -> Void
    var body: some View {
        #if compiler(>=6.4)
        if #available(iOS 26.4, *) {
            SystemSubtitleButton(player: player, interaction: interaction).frame(width: 44, height: 44)
        }
        #endif
    }
}

#if compiler(>=6.4)
@available(iOS 26.4, *)
private struct SystemSubtitleButton: UIViewRepresentable {
    let player: AVPlayer
    let interaction: () -> Void
    final class Coordinator: NSObject, AVLegibleMediaOptionsMenuController.Delegate {
        let menu: AVLegibleMediaOptionsMenuController
        weak var button: UIButton?
        private var playerObservation: NSKeyValueObservation?
        private var itemTask: Task<Void, Never>?
        private weak var observedPlayer: AVPlayer?
        init(player: AVPlayer) {
            menu = AVLegibleMediaOptionsMenuController(player: player)
            super.init()
            menu.delegate = self
            connect(player)
        }
        func connect(_ player: AVPlayer) {
            guard observedPlayer !== player else { return }
            observedPlayer = player
            playerObservation?.invalidate()
            playerObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor in self?.loadOptions(for: player.currentItem) }
            }
        }
        private func loadOptions(for item: AVPlayerItem?) {
            itemTask?.cancel()
            refresh()
            guard let item else { return }
            itemTask = Task { @MainActor [weak self] in
                // The menu's enabled state can remain true because caption
                // appearance is available before the item's subtitle tracks.
                _ = try? await item.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled, let self, self.menu.player.currentItem === item else { return }
                self.refresh()
            }
        }
        func stop() {
            playerObservation?.invalidate(); playerObservation = nil
            itemTask?.cancel(); itemTask = nil
            button = nil; menu.delegate = nil
        }
        func refresh() {
            button?.menu = menu.menu(contents: .all)
            button?.isEnabled = button?.menu != nil
        }
        func legibleMenuController(_ menuController: AVLegibleMediaOptionsMenuController, didChange state: AVLegibleMediaOptionsMenuState) {
            // Track availability is asynchronous. Update from AVKit's state
            // callback rather than waiting for an unrelated playback redraw.
            refresh()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(player: player) }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = ToolText.text("media_subtitles")
        button.accessibilityIdentifier = "media.native.system-subtitles"
        button.addAction(UIAction { _ in interaction() }, for: .menuActionTriggered)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.button = button
        if context.coordinator.menu.player !== player { context.coordinator.menu.player = player }
        context.coordinator.connect(player)
        context.coordinator.refresh()
    }
    static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
        coordinator.stop()
    }
}
#endif
