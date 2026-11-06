import SwiftUI
import UIKit

/// The browser's mounted window supplies its own context. Presented tool sheets
/// and a different key window must never mutate the browser behind them.
@MainActor
final class BrowserKeyboardContext: ObservableObject {
    private(set) weak var window: UIWindow?
    private weak var sourceView: UIView?

    var canPerform: Bool {
        guard let window, window.isKeyWindow,
              window.windowScene?.activationState == .foregroundActive,
              let root = window.rootViewController,
              root.presentedViewController == nil else { return false }
        return true
    }

    fileprivate func movedToWindow(_ view: UIView) {
        if let window = view.window {
            sourceView = view
            self.window = window
        } else {
            detach(view)
        }
    }

    fileprivate func detach(_ view: UIView) {
        // A retiring reader can be detached after its replacement has mounted.
        // It must not clear the replacement's valid window reference.
        guard sourceView === view else { return }
        sourceView = nil
        window = nil
    }
}

struct BrowserKeyboardWindowReader: UIViewRepresentable {
    let context: BrowserKeyboardContext

    func makeUIView(context: Context) -> WindowView {
        WindowView(owner: self.context)
    }

    func updateUIView(_ uiView: WindowView, context: Context) {}

    static func dismantleUIView(_ uiView: WindowView, coordinator: ()) {
        uiView.owner?.detach(uiView)
        uiView.owner = nil
    }

    final class WindowView: UIView {
        weak var owner: BrowserKeyboardContext?

        init(owner: BrowserKeyboardContext) {
            self.owner = owner
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            owner?.movedToWindow(self)
        }
    }
}

/// Each window publishes its own actions. Scene commands read only the active
/// scene's value, so no global window selection or invisible controls are used.
struct BrowserKeyboardActions {
    let enabled: Bool
    var canPerform: () -> Bool = { true }
    let focus: () -> Void
    let newTab: () -> Void
    let closeTab: () -> Void
    let restoreTab: () -> Void
    let reload: () -> Void
    let back: () -> Void
    let forward: () -> Void
    let find: () -> Void
    let newWindow: () -> Void
}

private struct BrowserKeyboardActionsKey: FocusedValueKey {
    typealias Value = BrowserKeyboardActions
}

extension FocusedValues {
    var souloBrowserKeyboardActions: BrowserKeyboardActions? {
        get { self[BrowserKeyboardActionsKey.self] }
        set { self[BrowserKeyboardActionsKey.self] = newValue }
    }
}

struct BrowserKeyboardCommands: Commands {
    @FocusedValue(\.souloBrowserKeyboardActions) private var actions

    var body: some Commands {
        CommandMenu("Soulo") {
            Group {
                Button(LanguageManager.shared.localizedString("browser_edit_address")) { perform(\.focus) }
                    .keyboardShortcut("l", modifiers: .command)
                Button(LanguageManager.shared.localizedString("tab_new_tab")) { perform(\.newTab) }
                    .keyboardShortcut("t", modifiers: .command)
                Button(LanguageManager.shared.localizedString("tab_close")) { perform(\.closeTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Button(LanguageManager.shared.localizedString("tab_restore_last")) { perform(\.restoreTab) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button(LanguageManager.shared.localizedString("browser_reload")) { perform(\.reload) }
                    .keyboardShortcut("r", modifiers: .command)
                Button(LanguageManager.shared.localizedString("browser_back")) { perform(\.back) }
                    .keyboardShortcut("[", modifiers: .command)
                Button(LanguageManager.shared.localizedString("browser_forward")) { perform(\.forward) }
                    .keyboardShortcut("]", modifiers: .command)
                Button(LanguageManager.shared.localizedString("find_in_page")) { perform(\.find) }
                    .keyboardShortcut("f", modifiers: .command)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Button(FeatureText.text("New window")) { perform(\.newWindow) }
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
            .disabled(actions?.enabled != true)
        }
    }

    private func perform(_ action: KeyPath<BrowserKeyboardActions, () -> Void>) {
        guard let actions, actions.enabled, actions.canPerform() else { return }
        actions[keyPath: action]()
    }
}

extension Notification.Name {
    static let focusSouloBrowserAddress = Notification.Name("soulo.focusBrowserAddress")
}
