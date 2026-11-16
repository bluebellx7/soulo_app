import Foundation

enum BrowserToolbarAction: String, Codable, CaseIterable, Identifiable {
    case none
    case home
    case back
    case forward
    case tabs
    case newTab
    case platforms
    case siteInformation
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
        case .newTab: "tab_new_tab"
        case .platforms: "toolbar_platforms"
        case .siteInformation: "site_information"
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
        case .books: "files"
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
        case .tabs: "square"
        case .newTab: "plus.square"
        case .platforms: "square.grid.2x2"
        case .siteInformation: "lock"
        case .more: "ellipsis"
        case .share: "square.and.arrow.up"
        case .bookmark: "bookmark"
        case .copyLink: "doc.on.doc"
        case .fullscreen: "arrow.up.left.and.arrow.down.right"
        case .desktopMode: "display"
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
        case .books: "folder"
        case .downloads: "arrow.down.circle"
        case .wifiTransfer: "wifi"
        case .adBlock: "shield.lefthalf.filled"
        }
    }

    @MainActor var localizedTitle: String {
        switch self {
        case .readerMode, .files, .books, .wifiTransfer, .platforms: ToolText.text(titleKey)
        default: LanguageManager.shared.localizedString(titleKey)
        }
    }

    var requiresPage: Bool {
        switch self {
        case .none, .home, .tabs, .newTab, .platforms, .more, .settings, .extensions, .library, .hideToolbar, .files, .books, .downloads, .wifiTransfer:
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
    static let leadingActionKey = "browser_toolbar_leading_action"
    static let moreActionsKey = "browser_more_menu_actions"
    static let defaultMoreActions: [BrowserToolbarAction] = [
        .home, .reload, .back, .forward, .fullscreen, .desktopMode, .darkMode, .tabs,
        .share, .copyLink, .bookmark, .library
    ]
    static let defaultActions: [BrowserToolbarAction] = [.home, .back, .tabs, .more]
    static let defaultLeadingAction: BrowserToolbarAction = .siteInformation
    static let defaultAddressAction: BrowserToolbarAction = .darkMode
    static let unsupportedAddressActions: Set<BrowserToolbarAction> = [.tabs, .more]
    /// Keep this hook for actions that must temporarily disappear without
    /// invalidating a saved toolbar layout.
    static let temporarilyUnavailableActions: Set<BrowserToolbarAction> = [.books]

    @Published private(set) var actions: [BrowserToolbarAction]
    @Published private(set) var leadingAction: BrowserToolbarAction
    @Published private(set) var addressAction: BrowserToolbarAction
    @Published private(set) var moreActions: [BrowserToolbarAction]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        moreActions = Self.decodedMoreActions(from: defaults)
        leadingAction = Self.normalizedLeadingAction(defaults.string(forKey: Self.leadingActionKey).flatMap(BrowserToolbarAction.init(rawValue:)))
        actions = Self.decodedActions(from: defaults) ?? Self.defaultActions
        addressAction = Self.normalizedAddressAction(
            defaults.string(forKey: Self.addressActionKey)
                .flatMap(BrowserToolbarAction.init(rawValue:))
        )
    }

    func save(actions: [BrowserToolbarAction], addressAction: BrowserToolbarAction, moreActions: [BrowserToolbarAction]? = nil, leadingAction: BrowserToolbarAction? = nil) {
        let normalized = Self.normalized(actions)
        self.actions = normalized
        let normalizedAddressAction = Self.normalizedAddressAction(addressAction)
        self.addressAction = normalizedAddressAction
        defaults.set(normalized.map(\.rawValue), forKey: Self.actionsKey)
        defaults.set(normalizedAddressAction.rawValue, forKey: Self.addressActionKey)
        if let moreActions { saveMoreActions(moreActions) }
        if let leadingAction {
            self.leadingAction = Self.normalizedLeadingAction(leadingAction)
            defaults.set(self.leadingAction.rawValue, forKey: Self.leadingActionKey)
        }
    }

    func saveMoreActions(_ actions: [BrowserToolbarAction]) {
        moreActions = Self.normalizedMoreActions(actions)
        defaults.set(moreActions.map(\.rawValue), forKey: Self.moreActionsKey)
    }

    func resetMoreActions() { saveMoreActions(Self.defaultMoreActions) }

    static func normalizedMoreActions(_ actions: [BrowserToolbarAction]) -> [BrowserToolbarAction] {
        var result = Array(actions.prefix(defaultMoreActions.count)).map {
            $0 == .books ? .files : ($0 == .more || temporarilyUnavailableActions.contains($0)) ? .none : $0
        }
        while result.count < defaultMoreActions.count { result.append(defaultMoreActions[result.count]) }
        return result
    }

    private static func decodedMoreActions(from defaults: UserDefaults) -> [BrowserToolbarAction] {
        guard let values = defaults.stringArray(forKey: moreActionsKey) else { return defaultMoreActions }
        return normalizedMoreActions(values.prefix(defaultMoreActions.count).enumerated().map { index, raw in
            BrowserToolbarAction(rawValue: raw) ?? defaultMoreActions[index]
        })
    }

    func reset() {
        save(actions: Self.defaultActions, addressAction: Self.defaultAddressAction, leadingAction: Self.defaultLeadingAction)
    }

    func reloadFromDefaults() {
        leadingAction = Self.normalizedLeadingAction(defaults.string(forKey: Self.leadingActionKey).flatMap(BrowserToolbarAction.init(rawValue:)))
        moreActions = Self.decodedMoreActions(from: defaults)
        actions = Self.decodedActions(from: defaults) ?? Self.defaultActions
        addressAction = Self.normalizedAddressAction(
            defaults.string(forKey: Self.addressActionKey)
                .flatMap(BrowserToolbarAction.init(rawValue:))
        )
    }

    static func normalized(_ actions: [BrowserToolbarAction]) -> [BrowserToolbarAction] {
        var result = Array(actions.prefix(4)).map {
            $0 == .books ? .files : temporarilyUnavailableActions.contains($0) ? .none : $0
        }
        while result.count < 4 {
            result.append(defaultActions[result.count])
        }
        return result
    }

    static func normalizedLeadingAction(_ action: BrowserToolbarAction?) -> BrowserToolbarAction {
        guard let action, !unsupportedAddressActions.contains(action) else { return defaultLeadingAction }
        if action == .books { return .files }
        return temporarilyUnavailableActions.contains(action) ? .none : action
    }

    static func normalizedAddressAction(_ action: BrowserToolbarAction?) -> BrowserToolbarAction {
        guard let action, !unsupportedAddressActions.contains(action) else {
            return defaultAddressAction
        }
        if action == .books { return .files }
        guard !temporarilyUnavailableActions.contains(action) else { return .none }
        return action
    }

    private static func decodedActions(from defaults: UserDefaults) -> [BrowserToolbarAction]? {
        guard let values = defaults.stringArray(forKey: actionsKey), !values.isEmpty else { return nil }
        return normalized(values.prefix(defaultActions.count).enumerated().map { index, value in
            BrowserToolbarAction(rawValue: value) ?? defaultActions[index]
        })
    }
}
