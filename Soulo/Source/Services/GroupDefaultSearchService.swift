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
    func platform(region: PlatformRegion) -> SearchPlatform {
        SearchPlatform(id: id, name: name, iconName: icon, searchURLTemplate: template, homeURL: homeURL,
            region: region, isBuiltIn: false, isVisible: true, sortOrder: 0, usageCount: 0, isCustom: true)
    }
    static func validTemplate(_ value: String) -> Bool {
        guard value.contains("%@"), !value.contains(where: \.isWhitespace),
              let url = URL(string: value.replacingOccurrences(of: "%@", with: "test")),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }
    static let presets: [Self] = [
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000008")!, name: "platform_shenma", template: "https://m.sm.cn/s?q=%@&from=smor&safe=1", homeURL: "https://m.sm.cn/", icon: "icon_shenma"),
        .init(id: UUID(uuidString: "76B3B5DD-95C0-4F61-9635-000000000001")!, name: "platform_baidu", template: "https://www.baidu.com/s?wd=%@", homeURL: "https://www.baidu.com", icon: "icon_baidu"),
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
        case .region(.china): "platform_shenma"
        case .region(.international): "platform_google"
        case .region(.japan): "platform_google_jp"
        case .region(.korea): "platform_google_kr"
        case .region(.russia): "platform_yandex"
        case .custom: language.lowercased().hasPrefix("zh") ? "platform_shenma" : "platform_google"
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
    }
    func engine(for scope: SearchGroupScope, language: String? = nil) -> GroupDefaultSearchEngine {
        if let value = overrides[scope.id], GroupDefaultSearchEngine.validTemplate(value.template) { return value }
        return .initial(scope: scope, language: language ?? defaults.string(forKey: "app_language") ?? Locale.preferredLanguages.first ?? "en")
    }
    func platform(for scope: SearchGroupScope, region: PlatformRegion? = nil) -> SearchPlatform { engine(for: scope).platform(region: region ?? scope.region) }
    func save(_ engine: GroupDefaultSearchEngine, for scope: SearchGroupScope) throws {
        guard !engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              GroupDefaultSearchEngine.validTemplate(engine.template) else { throw URLError(.badURL) }
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
