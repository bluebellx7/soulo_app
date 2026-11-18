import Combine
import Foundation

enum SearchGroupScope: Hashable, Identifiable {
    case region(PlatformRegion)
    case custom(UUID)
    var id: String {
        switch self {
        case .region(let region): "region:" + region.rawValue
        case .custom(let id): "group:" + id.uuidString
        }
    }
    var region: PlatformRegion {
        if case .region(let region) = self { return region }
        return .international
    }
}

struct GroupDefaultSearchEngine: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var template: String
    var homeURL: String
    var icon: String
    var interactionType: PlatformInteractionType? = nil
    var requiresLogin: Bool? = nil
    func platform(region: PlatformRegion) -> SearchPlatform {
        SearchPlatform(id: id, name: name, iconName: icon, searchURLTemplate: template, homeURL: homeURL,
            region: region, isBuiltIn: false, isVisible: true, sortOrder: 0, usageCount: 0, isCustom: true,
            requiresLogin: requiresLogin ?? false, interactionType: interactionType ?? .urlSearch)
    }
    static func validTemplate(_ value: String) -> Bool {
        // Some platforms are landing pages (including chat sites), with no
        // keyword placeholder. Keep those usable without inventing a query URL.
        guard !value.contains(where: \.isWhitespace),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value.replacingOccurrences(of: "%@", with: "test")),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }
    var hasValidURLs: Bool {
        Self.validTemplate(template) && (homeURL.isEmpty || Self.validTemplate(homeURL))
    }
    static func groupOptions(for scope: SearchGroupScope, platforms: [SearchPlatform],
                             customGroups: [CustomGroup]) -> [Self] {
        let ordered: [SearchPlatform]
        switch scope {
        case .region(let region):
            ordered = platforms.enumerated().filter { $0.element.region == region }
                .sorted {
                    $0.element.sortOrder == $1.element.sortOrder
                        ? $0.offset < $1.offset : $0.element.sortOrder < $1.element.sortOrder
                }.map(\.element)
        case .custom(let id):
            let members = customGroups.first { $0.id == id }?.platformIDs ?? []
            let byID = Dictionary(platforms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            ordered = members.compactMap { byID[$0] }
        }
        var seen: Set<UUID> = []
        // Visibility never removes a choice. The saved value is a snapshot,
        // independent of later edits or removal of the original platform.
        return ordered.compactMap { platform in
            guard seen.insert(platform.id).inserted else { return nil }
            return Self(id: platform.id, name: platform.name, template: platform.searchURLTemplate,
                        homeURL: platform.homeURL, icon: platform.iconName,
                        interactionType: platform.interactionType, requiresLogin: platform.requiresLogin)
        }
    }
    static let presets: [Self] = [
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000001")!, name: "platform_baidu", template: "https://www.baidu.com/s?wd=%@", homeURL: "https://www.baidu.com", icon: "icon_baidu"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000008")!, name: "platform_quark", template: "https://quark.sm.cn/s?q=%@&safe=1&by=submit&snum=1", homeURL: "https://quark.sm.cn/", icon: "icon_quark"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000002")!, name: "platform_google", template: "https://www.google.com/search?q=%@", homeURL: "https://www.google.com", icon: "icon_google"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000003")!, name: "platform_google_jp", template: "https://www.google.co.jp/search?q=%@&hl=ja&gl=jp", homeURL: "https://www.google.co.jp", icon: "icon_google"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000004")!, name: "platform_google_kr", template: "https://www.google.co.kr/search?q=%@&hl=ko&gl=kr", homeURL: "https://www.google.co.kr", icon: "icon_google"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000005")!, name: "platform_yandex", template: "https://yandex.ru/search/?text=%@", homeURL: "https://yandex.ru", icon: "icon_yandex"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000006")!, name: "platform_bing", template: "https://www.bing.com/search?q=%@", homeURL: "https://www.bing.com", icon: "icon_bing"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000007")!, name: "platform_duckduckgo", template: "https://duckduckgo.com/?q=%@", homeURL: "https://duckduckgo.com", icon: "icon_duckduckgo")
    ]
    static func initial(scope: SearchGroupScope, language: String) -> Self {
        // Preset menu ordering must not change a region's default engine.
        let name = switch scope {
        case .region(.china): "platform_baidu"
        case .region(.international): "platform_google"
        case .region(.japan): "platform_google_jp"
        case .region(.korea): "platform_google_kr"
        case .region(.russia): "platform_yandex"
        case .custom: language.lowercased().hasPrefix("zh") ? "platform_baidu" : "platform_google"
        }
        return presets.first { $0.name == name }!
    }
}

/// Defaults are independent of platform visibility and survive removal of the source platform.
@MainActor
final class GroupDefaultSearchService: ObservableObject {
    static let shared = GroupDefaultSearchService()
    static let storageKey = "group_default_search_engines"
    @Published private(set) var overrides: [String: GroupDefaultSearchEngine] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults; reloadFromDefaults() }
    func reloadFromDefaults() {
        overrides = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([String: GroupDefaultSearchEngine].self, from: $0) } ?? [:]
        let quark = GroupDefaultSearchEngine.presets.first { $0.name == "platform_quark" }!
        let legacyNames: Set<String> = ["platform_shenma", "神马搜索", "神馬搜尋", "Shenma Search", "Shenma"]
        var changed = false
        for (scope, old) in overrides where old.id == quark.id
            && old.template == "https://m.sm.cn/s?q=%@&from=smor&safe=1" {
            var replacement = quark
            if !legacyNames.contains(old.name) { replacement.name = old.name }
            overrides[scope] = replacement
            changed = true
        }
        if changed { defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.storageKey) }
    }
    func engine(for scope: SearchGroupScope, language: String? = nil) -> GroupDefaultSearchEngine {
        if let value = overrides[scope.id], value.hasValidURLs { return value }
        return .initial(scope: scope, language: language ?? defaults.string(forKey: "app_language") ?? Locale.preferredLanguages.first ?? "en")
    }
    func platform(for scope: SearchGroupScope, region: PlatformRegion? = nil) -> SearchPlatform { engine(for: scope).platform(region: region ?? scope.region) }
    func save(_ engine: GroupDefaultSearchEngine, for scope: SearchGroupScope) throws {
        guard !engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              engine.hasValidURLs else { throw URLError(.badURL) }
        var next = overrides; next[scope.id] = engine
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: Self.storageKey); overrides = next
    }
    func remove(_ scope: SearchGroupScope) {
        overrides.removeValue(forKey: scope.id)
        defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.storageKey)
    }
    func reset() { defaults.removeObject(forKey: Self.storageKey); overrides = [:] }
}
