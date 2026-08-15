import UIKit

enum AppQuickAction: String {
    case clearCache = "com.dkluge.Soulo.quick-action.clear-cache"
    case newPrivateTab = "com.dkluge.Soulo.quick-action.private-tab"
    case search = "com.dkluge.Soulo.quick-action.search"
    case shareApp = "com.dkluge.Soulo.quick-action.share-app"

    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(rawValue: shortcutItem.type)
    }
}

@MainActor
final class AppQuickActionService {
    static let shared = AppQuickActionService()

    private(set) var pendingAction: AppQuickAction?

    private init() {}

    func configureShortcuts() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: AppQuickAction.clearCache.rawValue,
                localizedTitle: LanguageManager.shared.localizedString("quick_action_clear_cache"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "trash.slash"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: AppQuickAction.newPrivateTab.rawValue,
                localizedTitle: LanguageManager.shared.localizedString("quick_action_private_tab"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "eye.slash"),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: AppQuickAction.search.rawValue,
                localizedTitle: LanguageManager.shared.localizedString("search"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(type: .search),
                userInfo: nil
            ),
            UIApplicationShortcutItem(
                type: AppQuickAction.shareApp.rawValue,
                localizedTitle: LanguageManager.shared.localizedString("quick_action_share_app"),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "square.and.arrow.up"),
                userInfo: nil
            )
        ]
    }

    func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = AppQuickAction(shortcutItem: shortcutItem) else { return false }
        pendingAction = action
        NotificationCenter.default.post(name: .appQuickActionReceived, object: action)
        return true
    }

    func consumePendingAction() -> AppQuickAction? {
        defer { pendingAction = nil }
        return pendingAction
    }
}

final class SouloAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            AppQuickActionService.shared.configureShortcuts()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Soulo Window",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SouloSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            completionHandler(AppQuickActionService.shared.receive(shortcutItem))
        }
    }
}

/// Home-screen quick actions are delivered through the scene lifecycle on
/// current iOS versions. Keeping this separate from the app delegate ensures
/// both a cold launch and a background-to-foreground activation reach Soulo.
final class SouloSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else { return }
        Task { @MainActor in
            _ = AppQuickActionService.shared.receive(shortcutItem)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            completionHandler(AppQuickActionService.shared.receive(shortcutItem))
        }
    }
}

extension Notification.Name {
    static let appQuickActionReceived = Notification.Name("soulo.appQuickActionReceived")
    static let focusHomeSearch = Notification.Name("soulo.focusHomeSearch")
}
