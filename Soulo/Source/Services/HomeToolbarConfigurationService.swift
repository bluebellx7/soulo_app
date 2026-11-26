import Combine
import Foundation
import UIKit

enum HomeToolbarAction: String, Codable, CaseIterable, Identifiable {
    case none, downloads, files, bookmarks, history, wallpaper, refreshWallpaper, platforms, extensions, settings
    case newDownload, wifiTransfer, scanner, tabs, language, webAppearance, browserToolbar, homeToolbar
    case adBlock, privacy, backups, quickActions, urlSchemes, shake, feedback, version
    case search, newTab, privateBrowsing, shareApp, storage, more
    case appearance, videoSettings, gestures, websiteZoom, browsingDisplay, feedbackPreferences, restoreTab
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .none: "minus.circle"
        case .downloads: "arrow.down.circle"
        case .files: "folder"
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .wallpaper: "photo"
        case .refreshWallpaper: "sparkles"
        case .search: "magnifyingglass"
        case .newTab: "plus.square"
        case .privateBrowsing: "eye.slash"
        case .shareApp: "square.and.arrow.up"
        case .platforms: "square.grid.2x2"
        case .extensions: "puzzlepiece.extension"
        case .settings: "gearshape"
        case .newDownload: "plus.circle"
        case .wifiTransfer: "wifi"
        case .scanner: "qrcode.viewfinder"
        case .tabs: "square"
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
        case .storage: "internaldrive"
        case .more: "ellipsis"
        case .appearance: "circle.lefthalf.filled"
        case .videoSettings: "play.rectangle"
        case .gestures: "hand.draw"
        case .websiteZoom: "text.magnifyingglass"
        case .browsingDisplay: "rectangle.topthird.inset.filled"
        case .feedbackPreferences: "speaker.wave.2"
        case .restoreTab: "arrow.uturn.backward"
        }
    }
    var listSymbol: String {
        switch self {
        case .downloads: "arrow.down.circle.fill"
        case .files: "folder.fill"
        case .bookmarks: "bookmark.fill"
        case .wallpaper: "photo.stack.fill"
        case .platforms: "square.grid.2x2.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .settings: "gearshape.fill"
        default: symbol
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
        case .refreshWallpaper: LanguageManager.shared.localizedString("wallpaper_refresh")
        case .search: LanguageManager.shared.localizedString("search")
        case .newTab: LanguageManager.shared.localizedString("tab_new_tab")
        case .privateBrowsing: LanguageManager.shared.localizedString("privacy_incognito")
        case .shareApp: LanguageManager.shared.localizedString("quick_action_share_app")
        case .platforms: LanguageManager.shared.localizedString("settings_platforms")
        case .extensions: LanguageManager.shared.localizedString("userscripts")
        case .settings: LanguageManager.shared.localizedString("settings")
        case .newDownload: ToolText.text("new_download")
        case .wifiTransfer: ToolText.text("wifi_transfer")
        case .scanner: ToolText.text("scan_qr")
        case .tabs: LanguageManager.shared.localizedString("browser_tabs")
        case .language: LanguageManager.shared.localizedString("settings_language")
        case .webAppearance: LanguageManager.shared.localizedString("web_appearance")
        case .browserToolbar: ToolText.text("home_toolbar_browser_tools")
        case .homeToolbar: ToolText.text("home_toolbar_home_tools")
        case .adBlock: LanguageManager.shared.localizedString("ad_block")
        case .privacy: LanguageManager.shared.localizedString("settings_privacy")
        case .backups: ToolText.text("settings_sync_backup")
        case .quickActions: ToolText.text("app_icon_shortcuts")
        case .urlSchemes: ToolText.text("scheme_title")
        case .shake: LanguageManager.shared.localizedString("shake_action")
        case .feedback: LanguageManager.shared.localizedString("feedback_title")
        case .version: LanguageManager.shared.localizedString("settings_version")
        case .storage: FeatureText.text("Storage")
        case .more: LanguageManager.shared.localizedString("show_more")
        case .appearance: LanguageManager.shared.localizedString("settings_appearance")
        case .videoSettings: ToolText.text("video_settings")
        case .gestures: ToolText.text("gesture_settings_title")
        case .websiteZoom: ToolText.text("page_zoom")
        case .browsingDisplay: ToolText.text("browsing_display_settings")
        case .feedbackPreferences: ToolText.text("feedback_settings")
        case .restoreTab: LanguageManager.shared.localizedString("tab_restore_last")
        }
    }
}

enum HomePageElement: String, CaseIterable, Identifiable {
    case tabs, menu, title, subtitle, search, bookmarks, recentSearches

    static let bookmarksKey = "show_bookmarks_on_home"
    static let recentSearchesKey = "show_recent_searches_on_home"

    var id: String { rawValue }

    var sharedPreferenceKey: String? {
        switch self {
        case .bookmarks: Self.bookmarksKey
        case .recentSearches: Self.recentSearchesKey
        default: nil
        }
    }

    var defaultVisibility: Bool { self != .bookmarks }
}

struct HomeToolbarLayout: Equatable {
    enum Style: String, CaseIterable { case tiles, capsule, icons }
    enum Placement: String, CaseIterable { case bottom, free }
    enum EdgeAlignment: String, CaseIterable { case leading, center, trailing }
    enum SearchPlacement: String, CaseIterable { case center, bottom }
    static let searchClearance: CGFloat = 8

    var style: Style = .tiles
    var placement: Placement = .bottom
    var alignment: EdgeAlignment = .center
    var searchPlacement: SearchPlacement = .center
    var x: Double = 0.5
    var y: Double = 1
    var hidesTopShortcuts = false
    private var visibility: [String: Bool] = [:]

    var freeToolbarAtBottom: Bool { placement == .free && y >= 0.995 }

    init() {}

    init(_ values: [String: Any]?, showsButtonBackground: Bool) {
        style = (values?["style"] as? String).flatMap(Style.init(rawValue:)) ?? (showsButtonBackground ? .tiles : .icons)
        placement = (values?["placement"] as? String).flatMap(Placement.init(rawValue:)) ?? .bottom
        alignment = (values?["alignment"] as? String).flatMap(EdgeAlignment.init(rawValue:)) ?? .center
        let storedSearchPlacement = values?["searchPlacement"] as? String
        searchPlacement = storedSearchPlacement == "lower" ? .bottom : storedSearchPlacement.flatMap(SearchPlacement.init(rawValue:)) ?? .center
        x = Self.normalized(values?["x"] as? Double, fallback: 0.5)
        y = Self.normalized(values?["y"] as? Double, fallback: 1)
        hidesTopShortcuts = values?["hidesTopShortcuts"] as? Bool ?? false
        visibility = values?["visibility"] as? [String: Bool] ?? [:]
        for removed in ["toolbar", "wallpaper", "suggestions", "voice", "groups"] { visibility.removeValue(forKey: removed) }
    }

    var propertyList: [String: Any] {
        ["style": style.rawValue, "placement": placement.rawValue, "alignment": alignment.rawValue,
         "searchPlacement": searchPlacement.rawValue,
         "x": Self.normalized(x, fallback: 0.5), "y": Self.normalized(y, fallback: 1),
         "hidesTopShortcuts": hidesTopShortcuts, "visibility": visibility]
    }

    func shows(_ element: HomePageElement, in actions: [HomeToolbarAction]) -> Bool {
        if let explicit = visibility[element.rawValue] { return explicit }
        // Preserve the previous opt-in until the user sets these independently.
        if hidesTopShortcuts {
            if element == .tabs && actions.contains(.tabs) { return false }
            if element == .menu && actions.contains(.settings) { return false }
        }
        return element.defaultVisibility
    }

    mutating func setVisibility(_ shown: Bool, for element: HomePageElement) {
        visibility[element.rawValue] = shown
    }

    func center(in area: CGSize, strip: CGSize, translation: CGSize = .zero) -> CGPoint {
        let travel = CGSize(width: max(0, area.width - strip.width), height: max(0, area.height - strip.height))
        return CGPoint(x: strip.width / 2 + min(travel.width, max(0, travel.width * x + translation.width)),
                       y: strip.height / 2 + min(travel.height, max(0, travel.height * y + translation.height)))
    }

    func reachesBottom(in area: CGSize, strip: CGSize, translation: CGSize) -> Bool {
        center(in: area, strip: strip, translation: translation).y + strip.height / 2 >= area.height - 4
    }

    func freeCenter(in area: CGSize, strip: CGSize, avoiding obstacles: [CGRect], translation: CGSize = .zero,
                    dockAtBottom: Bool = false) -> CGPoint? {
        let preferred = center(in: area, strip: strip)
        let halfWidth = strip.width / 2
        let halfHeight = strip.height / 2
        let horizontal = halfWidth...max(halfWidth, area.width - halfWidth)
        let vertical = halfHeight...max(halfHeight, area.height - halfHeight)
        let viewport = CGRect(origin: .zero, size: area)
        // Expand each obstacle into the space where the center of the strip would overlap it.
        let blocked = obstacles.map { $0.intersection(viewport) }.filter { !$0.isEmpty }.map {
            $0.insetBy(dx: -halfWidth - Self.searchClearance, dy: -halfHeight - Self.searchClearance)
        }

        func nearestAvailable(to point: CGPoint, within vertical: ClosedRange<CGFloat>) -> CGPoint? {
            let candidate = CGPoint(x: min(horizontal.upperBound, max(horizontal.lowerBound, point.x)),
                                    y: min(vertical.upperBound, max(vertical.lowerBound, point.y)))
            func isClear(_ point: CGPoint) -> Bool {
                !blocked.contains { point.x > $0.minX && point.x < $0.maxX && point.y > $0.minY && point.y < $0.maxY }
            }
            guard !isClear(candidate) else { return candidate }
            let xs = [candidate.x] + blocked.flatMap { [$0.minX, $0.maxX] }.filter(horizontal.contains)
            let ys = [candidate.y] + blocked.flatMap { [$0.minY, $0.maxY] }.filter(vertical.contains)
            return xs.flatMap { x in ys.map { CGPoint(x: x, y: $0) } }.filter(isClear)
                .min { hypot($0.x - candidate.x, $0.y - candidate.y) < hypot($1.x - candidate.x, $1.y - candidate.y) }
        }

        let bottom = vertical.upperBound...vertical.upperBound
        let dockedOrigin = freeToolbarAtBottom ? nearestAvailable(to: preferred, within: bottom) : nil
        if dockAtBottom {
            let target = CGPoint(x: (dockedOrigin?.x ?? preferred.x) + translation.width, y: vertical.upperBound)
            if let center = nearestAvailable(to: target, within: bottom) { return center }
        }
        guard let origin = dockedOrigin ?? nearestAvailable(to: preferred, within: vertical) else { return nil }
        guard translation != .zero else { return origin }
        return nearestAvailable(to: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height), within: vertical)
    }

    mutating func move(by translation: CGSize, in area: CGSize, strip: CGSize, avoiding obstacles: [CGRect] = [],
                       dockAtBottom: Bool = false) {
        guard let moved = freeCenter(in: area, strip: strip, avoiding: obstacles, translation: translation,
            dockAtBottom: dockAtBottom) else { return }
        let width = area.width - strip.width, height = area.height - strip.height
        if width > 0 { x = Self.normalized((moved.x - strip.width / 2) / width, fallback: x) }
        if height > 0 { y = Self.normalized((moved.y - strip.height / 2) / height, fallback: y) }
    }

    private static func normalized(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(1, max(0, value))
    }
}

@MainActor
final class HomeToolbarConfigurationService: ObservableObject {
    static let shared = HomeToolbarConfigurationService()
    static let storageKey = "home_toolbar_actions"
    static let backgroundKey = "home_toolbar_button_background"
    static let layoutKey = "home_toolbar_layout"
    static let maximumSlotCount = 8
    static var slotCount: Int { UIDevice.current.userInterfaceIdiom == .pad ? maximumSlotCount : 5 }
    @Published private(set) var actions: [HomeToolbarAction]
    @Published private(set) var layout: HomeToolbarLayout
    var showsButtonBackground: Bool { layout.style != .icons }
    private let defaults: UserDefaults
    private let slotLimit: Int
    init(defaults: UserDefaults = .standard, slotLimit: Int? = nil) {
        self.defaults = defaults
        self.slotLimit = min(max(slotLimit ?? Self.slotCount, 1), Self.maximumSlotCount)
        actions = Self.resolve(defaults.stringArray(forKey: Self.storageKey), slotLimit: self.slotLimit)
        layout = Self.readLayout(from: defaults)
    }
    static func resolve(_ raw: [String]?, slotLimit: Int? = nil) -> [HomeToolbarAction] {
        (0..<min(max(slotLimit ?? slotCount, 1), maximumSlotCount)).map { index in
            guard let raw, raw.indices.contains(index) else { return .none }
            return HomeToolbarAction(rawValue: raw[index]) ?? .none
        }
    }
    func reloadFromDefaults() {
        actions = Self.resolve(defaults.stringArray(forKey: Self.storageKey), slotLimit: self.slotLimit)
        layout = Self.readLayout(from: defaults)
    }
    private static func readLayout(from defaults: UserDefaults) -> HomeToolbarLayout {
        HomeToolbarLayout(defaults.dictionary(forKey: layoutKey), showsButtonBackground:
            defaults.object(forKey: backgroundKey) == nil || defaults.bool(forKey: backgroundKey))
    }

    func save(_ actions: [HomeToolbarAction], showsButtonBackground: Bool? = nil, layout newLayout: HomeToolbarLayout? = nil,
              sharedVisibility: [HomePageElement: Bool] = [:]) {
        self.actions = Self.resolve(actions.map(\.rawValue), slotLimit: slotLimit)
        // Editing the five visible phone slots must not delete iPad-only slots
        // when the same settings are restored or synchronized across devices.
        let extra = Array((defaults.stringArray(forKey: Self.storageKey) ?? []).dropFirst(slotLimit).prefix(Self.maximumSlotCount - slotLimit))
        defaults.set(self.actions.map(\.rawValue) + extra, forKey: Self.storageKey)
        if let updated = newLayout {
            layout = updated
            defaults.set(updated.propertyList, forKey: Self.layoutKey)
            defaults.set(updated.style != .icons, forKey: Self.backgroundKey)
        } else if let showsButtonBackground {
            layout.style = showsButtonBackground ? .tiles : .icons
            if defaults.object(forKey: Self.layoutKey) != nil {
                defaults.set(layout.propertyList, forKey: Self.layoutKey)
            }
            defaults.set(showsButtonBackground, forKey: Self.backgroundKey)
        }
        for (element, shown) in sharedVisibility {
            if let key = element.sharedPreferenceKey { defaults.set(shown, forKey: key) }
        }
    }
    var isVisible: Bool { actions.contains { $0 != .none } }
}
