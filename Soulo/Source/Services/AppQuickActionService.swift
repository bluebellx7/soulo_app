import UIKit

enum AppQuickAction: String {
    case clearCache = "com.dkluge.Soulo.quick-action.clear-cache"
    case newPrivateTab = "com.dkluge.Soulo.quick-action.private-tab"
    case search = "com.dkluge.Soulo.quick-action.search"
    case scan = "com.dkluge.Soulo.quick-action.scan"
    case files = "com.dkluge.Soulo.quick-action.files"
    case bookmarks = "com.dkluge.Soulo.quick-action.bookmarks"
    case downloads = "com.dkluge.Soulo.quick-action.downloads"
    case history = "com.dkluge.Soulo.quick-action.history"
    case shareApp = "com.dkluge.Soulo.quick-action.share-app"

    static let defaultOrder: [Self] = [.scan, .clearCache, .newPrivateTab, .search]
    static let availableActions: [Self] = [.scan, .search, .newPrivateTab, .clearCache, .files, .bookmarks, .downloads, .history]
    static let maximumCount = 4
    static let orderKey = "app_icon_quick_action_order"

    static func resolvedOrder(_ stored: [String]?) -> [Self] {
        guard let stored else { return defaultOrder }
        var seen = Set<String>()
        let chosen = stored.compactMap(Self.init(rawValue:))
            .filter { availableActions.contains($0) && seen.insert($0.rawValue).inserted }
        if chosen.isEmpty && !stored.isEmpty { return defaultOrder }
        return Array(chosen.prefix(maximumCount))
    }

    var librarySection: LibrarySection? {
        switch self {
        case .files: .files
        case .bookmarks: .bookmarks
        case .downloads: .downloads
        case .history: .history
        default: nil
        }
    }

    @MainActor var title: String {
        switch self {
        case .scan: ToolText.text("scan_qr")
        case .clearCache: LanguageManager.shared.localizedString("quick_action_clear_cache")
        case .newPrivateTab: LanguageManager.shared.localizedString("quick_action_private_tab")
        case .search: LanguageManager.shared.localizedString("search")
        case .files: ToolText.text("files")
        case .bookmarks: LanguageManager.shared.localizedString("bookmarks")
        case .downloads: LanguageManager.shared.localizedString("downloads")
        case .history: LanguageManager.shared.localizedString("search_history")
        case .shareApp: LanguageManager.shared.localizedString("share")
        }
    }

    var symbol: String {
        switch self {
        case .scan: "qrcode.viewfinder"
        case .clearCache: "trash.slash"
        case .newPrivateTab: "eye.slash"
        case .search: "magnifyingglass"
        case .files: "folder"
        case .bookmarks: "bookmark"
        case .downloads: "arrow.down.circle"
        case .history: "clock.arrow.circlepath"
        case .shareApp: "square.and.arrow.up"
        }
    }

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
        let order = AppQuickAction.resolvedOrder(UserDefaults.standard.stringArray(forKey: AppQuickAction.orderKey))
        UIApplication.shared.shortcutItems = order.map {
            UIApplicationShortcutItem(type: $0.rawValue, localizedTitle: $0.title,
                localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: $0.symbol), userInfo: nil)
        }
    }

    func saveOrder(_ order: [AppQuickAction]) {
        let resolved = AppQuickAction.resolvedOrder(order.map(\.rawValue))
        UserDefaults.standard.set(resolved.map(\.rawValue), forKey: AppQuickAction.orderKey)
        configureShortcuts()
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
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == StreamingMediaDownloadService.hlsSessionIdentifier {
            StreamingMediaDownloadService.shared.backgroundEventsCompletionHandler = completionHandler
            return
        }
        guard identifier == BackgroundDownloadService.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundDownloadService.shared.backgroundEventsCompletionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // SwiftUI owns the WindowGroup scene configuration. Supplying an
        // unregistered name makes UIKit search Info.plist for a configuration
        // that does not exist, so keep the name nil and attach only our delegate.
        let configuration = UISceneConfiguration(
            name: nil,
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
