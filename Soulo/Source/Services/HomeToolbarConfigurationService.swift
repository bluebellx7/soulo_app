import Combine
import Foundation

enum HomeToolbarAction: String, Codable, CaseIterable, Identifiable {
    case none, downloads, files, bookmarks, history, wallpaper, platforms, extensions, settings
    case newDownload, wifiTransfer, scanner, tabs, language, webAppearance, browserToolbar, homeToolbar
    case adBlock, privacy, backups, quickActions, urlSchemes, shake, feedback, version
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .none: "minus.circle"
        case .downloads: "arrow.down.circle"
        case .files: "folder"
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .wallpaper: "photo"
        case .platforms: "square.grid.2x2"
        case .extensions: "puzzlepiece.extension"
        case .settings: "gearshape"
        case .newDownload: "plus.circle"
        case .wifiTransfer: "wifi"
        case .scanner: "qrcode.viewfinder"
        case .tabs: "square.on.square"
        case .language: "globe"
        case .webAppearance: "paintbrush"
        case .browserToolbar: "rectangle.bottomthird.inset.filled"
        case .homeToolbar: "rectangle.split.2x2"
        case .adBlock: "shield.lefthalf.filled"
        case .privacy: "hand.raised"
        case .backups: "icloud"
        case .quickActions: "hand.tap"
        case .urlSchemes: "link"
        case .shake: "iphone.radiowaves.left.and.right"
        case .feedback: "bubble.left.and.bubble.right"
        case .version: "info.circle"
        }
    }
    @MainActor var title: String {
        switch self {
        case .none: LanguageManager.shared.localizedString("toolbar_action_empty")
        case .downloads: LanguageManager.shared.localizedString("downloads")
        case .files: ToolText.text("files")
        case .bookmarks: LanguageManager.shared.localizedString("bookmarks")
        case .history: LanguageManager.shared.localizedString("library_history_tab")
        case .wallpaper: LanguageManager.shared.localizedString("settings_wallpaper")
        case .platforms: LanguageManager.shared.localizedString("settings_platforms")
        case .extensions: LanguageManager.shared.localizedString("userscripts")
        case .settings: LanguageManager.shared.localizedString("settings")
        case .newDownload: ToolText.text("new_download")
        case .wifiTransfer: ToolText.text("wifi_transfer")
        case .scanner: ToolText.text("scan_qr")
        case .tabs: LanguageManager.shared.localizedString("browser_tabs")
        case .language: LanguageManager.shared.localizedString("settings_language")
        case .webAppearance: LanguageManager.shared.localizedString("web_appearance")
        case .browserToolbar: LanguageManager.shared.localizedString("toolbar_customize")
        case .homeToolbar: ToolText.text("home_toolbar_customize")
        case .adBlock: LanguageManager.shared.localizedString("ad_block")
        case .privacy: LanguageManager.shared.localizedString("settings_privacy")
        case .backups: LanguageManager.shared.localizedString("settings_backups")
        case .quickActions: ToolText.text("quick_actions_title")
        case .urlSchemes: ToolText.text("scheme_title")
        case .shake: LanguageManager.shared.localizedString("shake_action")
        case .feedback: LanguageManager.shared.localizedString("feedback")
        case .version: LanguageManager.shared.localizedString("settings_version")
        }
    }
}

@MainActor
final class HomeToolbarConfigurationService: ObservableObject {
    static let shared = HomeToolbarConfigurationService()
    static let storageKey = "home_toolbar_actions"
    static let slotCount = 4
    @Published private(set) var actions: [HomeToolbarAction]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        actions = Self.resolve(defaults.stringArray(forKey: Self.storageKey))
    }
    static func resolve(_ raw: [String]?) -> [HomeToolbarAction] {
        (0..<slotCount).map { index in
            guard let raw, raw.indices.contains(index) else { return .none }
            return HomeToolbarAction(rawValue: raw[index]) ?? .none
        }
    }
    func reloadFromDefaults() { actions = Self.resolve(defaults.stringArray(forKey: Self.storageKey)) }
    func save(_ actions: [HomeToolbarAction]) {
        self.actions = Self.resolve(actions.map(\.rawValue))
        defaults.set(self.actions.map(\.rawValue), forKey: Self.storageKey)
    }
    var isVisible: Bool { actions.contains { $0 != .none } }
}
