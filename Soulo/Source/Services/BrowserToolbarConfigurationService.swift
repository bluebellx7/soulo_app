import Foundation

enum BrowserToolbarAction: String, Codable, CaseIterable, Identifiable {
    case none
    case home
    case back
    case forward
    case tabs
    case more
    case share
    case bookmark
    case copyLink
    case fullscreen
    case desktopMode
    case darkMode
    case settings
    case extensions
    case library
    case reload
    case hideToolbar
    case screenshot
    case translate
    case readerMode
    case resources
    case files
    case books
    case downloads
    case wifiTransfer
    case adBlock

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .none: "toolbar_action_empty"
        case .home: "home_screen"
        case .back: "browser_back"
        case .forward: "browser_forward"
        case .tabs: "browser_tabs"
        case .more: "show_more"
        case .share: "share"
        case .bookmark: "bookmarks"
        case .copyLink: "copy_link"
        case .fullscreen: "enter_fullscreen"
        case .desktopMode: "desktop_mode"
        case .darkMode: "web_force_dark_short"
        case .settings: "settings"
        case .extensions: "userscripts"
        case .library: "library"
        case .reload: "browser_reload"
        case .hideToolbar: "hide_browser_toolbar"
        case .screenshot: "web_capture"
        case .translate: "web_translate"
        case .readerMode: "reader_mode"
        case .resources: "resource_inspector_title"
        case .files: "files"
        case .books: "bookshelf"
        case .downloads: "downloads"
        case .wifiTransfer: "wifi_transfer"
        case .adBlock: "ad_block"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "minus.circle"
        case .home: "house.fill"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .tabs: "square.on.square"
        case .more: "ellipsis"
        case .share: "square.and.arrow.up"
        case .bookmark: "bookmark"
        case .copyLink: "doc.on.doc"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .desktopMode: "desktopcomputer"
        case .darkMode: "moon.fill"
        case .settings: "gearshape"
        case .extensions: "puzzlepiece.extension"
        case .library: "books.vertical"
        case .reload: "arrow.clockwise"
        case .hideToolbar: BrowserChromeSymbol.toolbarVisibility
        case .screenshot: "camera.viewfinder"
        case .translate: "character.bubble"
        case .readerMode: "doc.text"
        case .resources: "play.rectangle.on.rectangle"
        case .files: "folder"
        case .books: "books.vertical"
        case .downloads: "arrow.down.circle"
        case .wifiTransfer: "wifi"
        case .adBlock: "shield.lefthalf.filled"
        }
    }

    @MainActor var localizedTitle: String {
        switch self {
        case .readerMode, .files, .books, .wifiTransfer: ToolText.text(titleKey)
        default: LanguageManager.shared.localizedString(titleKey)
        }
    }

    var requiresPage: Bool {
        switch self {
        case .none, .home, .tabs, .more, .settings, .extensions, .library, .hideToolbar, .files, .books, .downloads, .wifiTransfer:
            false
        default:
            true
        }
    }
}

@MainActor
final class BrowserToolbarConfigurationService: ObservableObject {
    static let shared = BrowserToolbarConfigurationService()
    static let actionsKey = "browser_toolbar_actions"
    static let addressActionKey = "browser_toolbar_address_action"
    static let defaultActions: [BrowserToolbarAction] = [.home, .back, .tabs, .more]
    static let defaultAddressAction: BrowserToolbarAction = .darkMode
    static let unsupportedAddressActions: Set<BrowserToolbarAction> = [.tabs, .more]
    /// Keep this hook for actions that must temporarily disappear without
    /// invalidating a saved toolbar layout.
    static let temporarilyUnavailableActions: Set<BrowserToolbarAction> = []

    @Published private(set) var actions: [BrowserToolbarAction]
    @Published private(set) var addressAction: BrowserToolbarAction

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        actions = Self.decodedActions(from: defaults) ?? Self.defaultActions
        addressAction = Self.normalizedAddressAction(
            defaults.string(forKey: Self.addressActionKey)
                .flatMap(BrowserToolbarAction.init(rawValue:))
        )
    }

    func save(actions: [BrowserToolbarAction], addressAction: BrowserToolbarAction) {
        let normalized = Self.normalized(actions)
        self.actions = normalized
        let normalizedAddressAction = Self.normalizedAddressAction(addressAction)
        self.addressAction = normalizedAddressAction
        defaults.set(normalized.map(\.rawValue), forKey: Self.actionsKey)
        defaults.set(normalizedAddressAction.rawValue, forKey: Self.addressActionKey)
    }

    func reset() {
        save(actions: Self.defaultActions, addressAction: Self.defaultAddressAction)
    }

    func reloadFromDefaults() {
        actions = Self.decodedActions(from: defaults) ?? Self.defaultActions
        addressAction = Self.normalizedAddressAction(
            defaults.string(forKey: Self.addressActionKey)
                .flatMap(BrowserToolbarAction.init(rawValue:))
        )
    }

    static func normalized(_ actions: [BrowserToolbarAction]) -> [BrowserToolbarAction] {
        var result = Array(actions.prefix(4)).map {
            temporarilyUnavailableActions.contains($0) ? .none : $0
        }
        while result.count < 4 {
            result.append(defaultActions[result.count])
        }
        return result
    }

    static func normalizedAddressAction(_ action: BrowserToolbarAction?) -> BrowserToolbarAction {
        guard let action, !unsupportedAddressActions.contains(action) else {
            return defaultAddressAction
        }
        guard !temporarilyUnavailableActions.contains(action) else { return .none }
        return action
    }

    private static func decodedActions(from defaults: UserDefaults) -> [BrowserToolbarAction]? {
        guard let values = defaults.stringArray(forKey: actionsKey), !values.isEmpty else { return nil }
        return normalized(values.compactMap(BrowserToolbarAction.init(rawValue:)))
    }
}
