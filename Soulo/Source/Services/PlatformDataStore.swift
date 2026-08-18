import Foundation
import SwiftUI

@MainActor
class PlatformDataStore: ObservableObject {

    static let shared = PlatformDataStore()

    @Published var platforms: [SearchPlatform] = []
    @Published var customGroups: [CustomGroup] = []
    @Published var regionNameOverrides: [String: String] = [:] // region.rawValue -> custom name

    private let userDefaultsKey = "platform_config"
    private let groupsKey = "custom_groups"
    private let regionNamesKey = "region_name_overrides"

    private init() {
        load()
        loadGroups()
        loadRegionNames()
    }

    // MARK: - Persistence

    private let platformVersion = 41 // Increment when cached built-in defaults need migration

    private func load() {
        let savedVersion = UserDefaults.standard.integer(forKey: "platform_config_version")
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([SearchPlatform].self, from: data),
           !decoded.isEmpty {
            platforms = decoded
            var shouldSave = false
            if savedVersion < platformVersion {
                applyPlatformDefaultMigration(from: savedVersion)
                UserDefaults.standard.set(platformVersion, forKey: "platform_config_version")
                shouldSave = true
            }
            if normalizeSortOrders() {
                shouldSave = true
            }
            if shouldSave {
                savePlatforms()
            }
        } else {
            platforms = Self.defaultPlatforms()
            UserDefaults.standard.set(platformVersion, forKey: "platform_config_version")
            savePlatforms()
        }
    }

    func savePlatforms() {
        if let data = try? JSONEncoder().encode(platforms) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func reloadFromDefaults() {
        load()
        loadGroups()
        loadRegionNames()
    }

    // MARK: - Queries

    func allPlatforms() -> [SearchPlatform] {
        platforms
    }

    func platforms(for region: PlatformRegion) -> [SearchPlatform] {
        platforms.enumerated()
            .filter { $0.element.region == region }
            .sorted { lhs, rhs in
                if lhs.element.sortOrder != rhs.element.sortOrder {
                    return lhs.element.sortOrder < rhs.element.sortOrder
                }
                // Old configurations may contain duplicate sort values. Preserve
                // their stored array order instead of letting sort reshuffle them.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func visiblePlatforms(for region: PlatformRegion) -> [SearchPlatform] {
        platforms(for: region).filter { $0.isVisible }
    }

    func firstVisiblePlatform(for region: PlatformRegion) -> SearchPlatform? {
        visiblePlatforms(for: region).first
    }

    // MARK: - Mutations

    func incrementUsage(for platformID: UUID) {
        guard let index = platforms.firstIndex(where: { $0.id == platformID }) else { return }
        platforms[index].usageCount += 1
        savePlatforms()
    }

    func movePlatform(from source: IndexSet, to destination: Int, within region: PlatformRegion) {
        var regionPlatforms = platforms(for: region)
        regionPlatforms.move(fromOffsets: source, toOffset: destination)

        // Re-assign sortOrder based on new position
        for (newOrder, platform) in regionPlatforms.enumerated() {
            if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
                platforms[index].sortOrder = newOrder
            }
        }
        savePlatforms()
    }

    func movePlatform(from source: IndexSet, to destination: Int, withinGroup groupID: UUID) {
        guard let groupIndex = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var orderedIDs = customGroups[groupIndex].platformIDs.filter { platformID in
            platforms.contains { $0.id == platformID }
        }
        orderedIDs.move(fromOffsets: source, toOffset: destination)
        customGroups[groupIndex].platformIDs = orderedIDs
        saveGroups()
    }

    func setPlatforms(_ platformIDs: [UUID], inGroup groupID: UUID) {
        guard let groupIndex = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        var seen = Set<UUID>()
        customGroups[groupIndex].platformIDs = platformIDs.filter { platformID in
            platforms.contains { $0.id == platformID } && seen.insert(platformID).inserted
        }
        saveGroups()
    }

    func toggleVisibility(platform: SearchPlatform) {
        guard let index = platforms.firstIndex(where: { $0.id == platform.id }) else { return }
        platforms[index].isVisible.toggle()
        savePlatforms()
    }

    func toggleVisibility(for platformID: UUID) {
        guard let index = platforms.firstIndex(where: { $0.id == platformID }) else { return }
        platforms[index].isVisible.toggle()
        savePlatforms()
    }

    func movePlatform(id platformID: UUID, toSortOrder newOrder: Int) {
        guard let index = platforms.firstIndex(where: { $0.id == platformID }) else { return }
        platforms[index].sortOrder = newOrder
        savePlatforms()
    }

    func addCustomPlatform(name: String, searchURL: String, homeURL: String, region: PlatformRegion) {
        let maxOrder = platforms
            .filter { $0.region == region }
            .map { $0.sortOrder }
            .max() ?? -1

        // Derive favicon URL from homeURL or searchURL domain
        let faviconURL = Self.faviconURL(from: homeURL.isEmpty ? searchURL : homeURL)

        let newPlatform = SearchPlatform(
            id: UUID(),
            name: name,
            iconName: "icon_custom",
            searchURLTemplate: searchURL,
            homeURL: homeURL,
            region: region,
            isBuiltIn: false,
            isVisible: true,
            sortOrder: maxOrder + 1,
            usageCount: 0,
            isCustom: true,
            faviconURL: faviconURL
        )
        platforms.append(newPlatform)
        savePlatforms()
    }

    /// Extract favicon URL from a website URL using Google's favicon service
    private static func faviconURL(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
    }

    /// Batch import platforms from JSON string.
    /// Format: [{"name": "xxx", "url": "https://...?wd=%@"}, ...]
    func importPlatformsFromJSON(_ jsonString: String, groupName: String?, region: PlatformRegion = .international) -> Int {
        struct ImportItem: Decodable {
            let name: String
            let url: String
        }
        guard let data = jsonString.data(using: .utf8),
              let items = try? JSONDecoder().decode([ImportItem].self, from: data),
              !items.isEmpty else { return 0 }

        // Create group if specified
        var groupID: UUID? = nil
        if let gName = groupName, !gName.isEmpty {
            if let existing = customGroups.first(where: { $0.name == gName }) {
                groupID = existing.id
            } else {
                let newGroup = CustomGroup(name: gName)
                customGroups.append(newGroup)
                saveGroups()
                groupID = newGroup.id
            }
        }

        var count = 0
        for item in items {
            // Skip duplicates
            if platforms.contains(where: { $0.searchURLTemplate == item.url }) { continue }

            let homeURL: String
            if let url = URL(string: item.url.replacingOccurrences(of: "%@", with: "")),
               let scheme = url.scheme, let host = url.host {
                homeURL = "\(scheme)://\(host)"
            } else {
                homeURL = ""
            }

            addCustomPlatform(name: item.name, searchURL: item.url, homeURL: homeURL, region: region)

            if let gid = groupID, let newPlatform = platforms.last {
                addPlatformToGroup(groupID: gid, platformID: newPlatform.id)
            }
            count += 1
        }
        return count
    }

    func updatePlatform(id: UUID, name: String, searchURL: String, homeURL: String) {
        guard let index = platforms.firstIndex(where: { $0.id == id }) else { return }
        platforms[index].name = name
        platforms[index].searchURLTemplate = searchURL
        platforms[index].homeURL = homeURL
        if platforms[index].isCustom {
            platforms[index].faviconURL = Self.faviconURL(from: homeURL.isEmpty ? searchURL : homeURL)
        }
        savePlatforms()
    }

    func deleteCustomPlatform(id: UUID) {
        platforms.removeAll { $0.id == id && $0.isCustom }
        savePlatforms()
    }

    func deletePlatform(id: UUID) {
        platforms.removeAll { $0.id == id }
        savePlatforms()
    }

    func resetToDefaults() {
        platforms = Self.defaultPlatforms()
        customGroups = []
        regionNameOverrides = [:]
        savePlatforms()
        saveGroups()
        UserDefaults.standard.set(platformVersion, forKey: "platform_config_version")
        UserDefaults.standard.removeObject(forKey: "region_name_overrides")
    }

    private func applyPlatformDefaultMigration(from version: Int) {
        if version < 35 {
            for index in platforms.indices where Self.defaultHiddenPlatformNames.contains(platforms[index].name) && platforms[index].isBuiltIn {
                platforms[index].isVisible = false
            }
        }
        if version < 36 {
            // Frequency ordering was removed: a user's drag order is authoritative.
            UserDefaults.standard.removeObject(forKey: "auto_sort_frequency")

            if !platforms.contains(where: { $0.name == "platform_xiaohongshu" }) {
                let nextOrder = (platforms
                    .filter { $0.region == .china }
                    .map(\.sortOrder)
                    .max() ?? -1) + 1
                platforms.append(Self.xiaohongshuPlatform(sortOrder: nextOrder))
            }
        }
        if version < 37,
           let index = platforms.firstIndex(where: { $0.name == "platform_xiaohongshu" && $0.isBuiltIn }) {
            platforms[index].requiresLogin = true
        }
        if version < 38 {
            let authenticatedPlatformNames: Set<String> = [
                "platform_twitter", "platform_twitter_jp", "platform_you"
            ]
            for index in platforms.indices
            where platforms[index].isBuiltIn && authenticatedPlatformNames.contains(platforms[index].name) {
                platforms[index].requiresLogin = true
            }

            let addedNames: Set<String> = [
                "platform_naver",
                "platform_daum",
                "platform_google_kr",
                "platform_youtube_kr"
            ]
            let additions = Self.defaultPlatforms().filter { addedNames.contains($0.name) }
            for var platform in additions where !platforms.contains(where: { $0.name == platform.name }) {
                platform.sortOrder = (platforms
                    .filter { $0.region == platform.region }
                    .map(\.sortOrder)
                    .max() ?? -1) + 1
                platforms.append(platform)
            }
        }
        if version < 39 {
            platforms.removeAll { platform in
                platform.isBuiltIn && platform.name == "platform_phind"
            }
        }
        if version < 40,
           let index = platforms.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_zhihu" }) {
            platforms[index].searchURLTemplate = "https://www.zhihu.com/search?type=content&q=%@"
            platforms[index].homeURL = "https://www.zhihu.com"
            platforms[index].requiresLogin = true
        }
        if version < 41,
           !platforms.contains(where: { $0.isBuiltIn && $0.name == "platform_zlibrary" }) {
            let nextOrder = (platforms
                .filter { $0.region == .international }
                .map(\.sortOrder)
                .max() ?? -1) + 1
            platforms.append(Self.zLibraryPlatform(sortOrder: nextOrder))
        }
    }

    @discardableResult
    private func normalizeSortOrders() -> Bool {
        var didChange = false
        for region in PlatformRegion.allCases {
            let orderedIDs = platforms.enumerated()
                .filter { $0.element.region == region }
                .sorted { lhs, rhs in
                    if lhs.element.sortOrder != rhs.element.sortOrder {
                        return lhs.element.sortOrder < rhs.element.sortOrder
                    }
                    return lhs.offset < rhs.offset
                }
                .map { $0.element.id }

            for (sortOrder, platformID) in orderedIDs.enumerated() {
                guard let index = platforms.firstIndex(where: { $0.id == platformID }) else { continue }
                if platforms[index].sortOrder != sortOrder {
                    platforms[index].sortOrder = sortOrder
                    didChange = true
                }
            }
        }
        return didChange
    }

    // MARK: - Custom Groups

    private func loadGroups() {
        guard let data = UserDefaults.standard.data(forKey: groupsKey),
              let decoded = try? JSONDecoder().decode([CustomGroup].self, from: data) else { return }
        customGroups = decoded
    }

    func saveGroups() {
        if let data = try? JSONEncoder().encode(customGroups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
    }

    func addGroup(name: String) {
        let group = CustomGroup(name: name)
        customGroups.append(group)
        saveGroups()
    }

    func deleteGroup(id: UUID) {
        customGroups.removeAll { $0.id == id }
        saveGroups()
    }

    func renameGroup(id: UUID, name: String) {
        guard let i = customGroups.firstIndex(where: { $0.id == id }) else { return }
        customGroups[i].name = name
        saveGroups()
    }

    func addPlatformToGroup(groupID: UUID, platformID: UUID) {
        guard let i = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        if !customGroups[i].platformIDs.contains(platformID) {
            customGroups[i].platformIDs.append(platformID)
            saveGroups()
        }
    }

    func removePlatformFromGroup(groupID: UUID, platformID: UUID) {
        guard let i = customGroups.firstIndex(where: { $0.id == groupID }) else { return }
        customGroups[i].platformIDs.removeAll { $0 == platformID }
        saveGroups()
    }

    func platformsForGroup(_ group: CustomGroup) -> [SearchPlatform] {
        group.platformIDs.compactMap { pid in platforms.first { $0.id == pid } }
    }

    // MARK: - Region Name Overrides

    private func loadRegionNames() {
        guard let data = UserDefaults.standard.data(forKey: regionNamesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        regionNameOverrides = decoded
    }

    func saveRegionNames() {
        if let data = try? JSONEncoder().encode(regionNameOverrides) {
            UserDefaults.standard.set(data, forKey: regionNamesKey)
        }
    }

    func regionDisplayName(for region: PlatformRegion) -> String {
        regionNameOverrides[region.rawValue] ?? LanguageManager.shared.localizedString(region.nameKey)
    }

    func renameRegion(_ region: PlatformRegion, to name: String) {
        regionNameOverrides[region.rawValue] = name
        saveRegionNames()
    }

    // MARK: - Default Platforms

    private static func defaultPlatforms() -> [SearchPlatform] {
        var all: [SearchPlatform] = []

        // MARK: China
        let chinaData: [(String, String, String, String)] = [
            ("platform_baidu",        "icon_baidu",        "https://www.baidu.com/s?wd=%@",                             "https://www.baidu.com"),
            ("platform_bilibili",     "icon_bilibili",     "https://search.bilibili.com/all?keyword=%@",                "https://www.bilibili.com"),
            ("platform_weibo",        "icon_weibo",        "https://s.weibo.com/weibo?q=%@",                            "https://weibo.com"),
            ("platform_wechat",       "icon_wechat",       "https://weixin.sogou.com/weixinwap?type=2&ie=utf8&s_from=input&query=%@", "https://weixin.sogou.com"),
            ("platform_douyin",       "icon_douyin",       "https://www.douyin.com/search/%@",                          "https://www.douyin.com"),
            ("platform_xiaohongshu",  "icon_xiaohongshu",  "https://www.xiaohongshu.com/search_result?keyword=%@&source=web_explore_feed&type=51", "https://www.xiaohongshu.com"),
            ("platform_taobao",       "icon_taobao",       "https://s.m.taobao.com/h5?q=%@",                             "https://m.taobao.com"),
            ("platform_jd",           "icon_jd",           "https://so.m.jd.com/ware/search.action?keyword=%@",          "https://m.jd.com"),
            ("platform_sogou",        "icon_sogou",        "https://www.sogou.com/web?query=%@",                         "https://www.sogou.com"),
            ("platform_360",          "icon_360",          "https://www.so.com/s?q=%@",                                  "https://www.so.com"),

            ("platform_youku",        "icon_youku",        "https://search.youku.com/search_video?keyword=%@",           "https://www.youku.com"),
            ("platform_iqiyi",        "icon_iqiyi",        "https://m.iqiyi.com/search.html?source=input&key=%@",        "https://m.iqiyi.com"),
            ("platform_csdn",         "icon_csdn",         "https://so.csdn.net/so/search?q=%@",                         "https://so.csdn.net"),
            ("platform_juejin",       "icon_juejin",       "https://juejin.cn/search?query=%@",                          "https://juejin.cn"),
        ]
        for (order, entry) in chinaData.enumerated() {
            all.append(SearchPlatform(
                id: UUID(),
                name: entry.0,
                iconName: entry.1,
                searchURLTemplate: entry.2,
                homeURL: entry.3,
                region: .china,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: order,
                usageCount: 0,
                isCustom: false
            ))
        }

        // MARK: International
        let internationalData: [(String, String, String, String)] = [
            ("platform_google",   "icon_google",   "https://www.google.com/search?q=%@",              "https://www.google.com"),
            ("platform_youtube",  "icon_youtube",  "https://www.youtube.com/results?search_query=%@", "https://www.youtube.com"),
            ("platform_twitter",  "icon_twitter",  "https://x.com/search?q=%@",                       "https://x.com"),
            ("platform_reddit",      "icon_reddit",      "https://www.reddit.com/search/?q=%@&type=link",   "https://www.reddit.com"),
            ("platform_amazon",      "icon_amazon",      "https://www.amazon.com/s?k=%@&i=mobile",          "https://www.amazon.com"),

            ("platform_bing",        "icon_bing",        "https://www.bing.com/search?q=%@",                "https://www.bing.com"),
            ("platform_duckduckgo",  "icon_duckduckgo",  "https://duckduckgo.com/?q=%@",                    "https://duckduckgo.com"),
            ("platform_github",      "icon_github",      "https://github.com/search?q=%@&type=repositories","https://github.com"),
            ("platform_wikipedia",   "icon_wikipedia",   "https://en.wikipedia.org/w/index.php?search=%@",  "https://en.wikipedia.org"),
            ("platform_perplexity",  "icon_perplexity",  "https://www.perplexity.ai/search?q=%@",           "https://www.perplexity.ai"),
            ("platform_you",         "icon_you",         "https://you.com/search?q=%@",                     "https://you.com"),
            ("platform_instagram",   "icon_instagram",   "https://www.instagram.com/explore/tags/%@/",      "https://www.instagram.com"),
            ("platform_linkedin",    "icon_linkedin",    "https://www.linkedin.com/search/results/all/?keywords=%@", "https://www.linkedin.com"),
            ("platform_pinterest",   "icon_pinterest",   "https://www.pinterest.com/search/pins/?q=%@",     "https://www.pinterest.com"),
            ("platform_ebay",        "icon_ebay",        "https://www.ebay.com/sch/i.html?_nkw=%@",         "https://www.ebay.com"),
            ("platform_stackoverflow","icon_stackoverflow","https://stackoverflow.com/search?q=%@",          "https://stackoverflow.com"),
            ("platform_scholar",     "icon_scholar",     "https://scholar.google.com/scholar?q=%@",          "https://scholar.google.com"),
        ]
        for (order, entry) in internationalData.enumerated() {
            all.append(SearchPlatform(
                id: UUID(),
                name: entry.0,
                iconName: entry.1,
                searchURLTemplate: entry.2,
                homeURL: entry.3,
                region: .international,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: order,
                usageCount: 0,
                isCustom: false
            ))
        }
        all.append(Self.zLibraryPlatform(sortOrder: internationalData.count))


        // MARK: Zhihu
        all.append(SearchPlatform(
            id: UUID(),
            name: "platform_zhihu",
            iconName: "icon_zhihu",
            searchURLTemplate: "https://www.zhihu.com/search?type=content&q=%@",
            homeURL: "https://www.zhihu.com",
            region: .china,
            isBuiltIn: true,
            isVisible: true,
            sortOrder: chinaData.count,
            usageCount: 0,
            isCustom: false,
            requiresLogin: true
        ))

        // MARK: AI Platforms (requires login, chat interaction)
        let aiPlatforms: [(String, String, String, String)] = [
            ("platform_doubao",   "icon_doubao",   "https://www.doubao.com/chat",   "https://www.doubao.com/chat"),
            ("platform_qianwen",  "icon_qianwen",  "https://www.qianwen.com/",      "https://www.qianwen.com/"),
            ("platform_deepseek", "icon_deepseek", "https://chat.deepseek.com/",    "https://chat.deepseek.com/"),
            ("platform_yuanbao",  "icon_yuanbao",  "https://yuanbao.tencent.com/",  "https://yuanbao.tencent.com/"),
        ]
        for (offset, entry) in aiPlatforms.enumerated() {
            all.append(SearchPlatform(
                id: UUID(),
                name: entry.0,
                iconName: entry.1,
                searchURLTemplate: entry.2,
                homeURL: entry.3,
                region: .china,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: chinaData.count + 1 + offset, // +1 for zhihu
                usageCount: 0,
                isCustom: false,
                requiresLogin: true,
                interactionType: .aiChat
            ))
        }

        // MARK: Japan (4)
        let japanData: [(String, String, String, String)] = [
            ("platform_yahoo_jp",    "icon_yahoo_jp", "https://search.yahoo.co.jp/search?p=%@",                     "https://www.yahoo.co.jp"),
            ("platform_google_jp",   "icon_google",   "https://www.google.co.jp/search?q=%@",                       "https://www.google.co.jp"),
            ("platform_twitter_jp",  "icon_twitter",  "https://x.com/search?q=%@&lang=ja",                          "https://x.com"),
            ("platform_youtube_jp",  "icon_youtube",  "https://www.youtube.com/results?search_query=%@&gl=JP",       "https://www.youtube.com"),
            ("platform_rakuten",     "icon_rakuten",  "https://search.rakuten.co.jp/search/mall/%@/",                "https://www.rakuten.co.jp"),
            ("platform_niconico",    "icon_niconico", "https://www.nicovideo.jp/search/%@",                          "https://www.nicovideo.jp"),
        ]
        for (order, entry) in japanData.enumerated() {
            all.append(SearchPlatform(
                id: UUID(),
                name: entry.0,
                iconName: entry.1,
                searchURLTemplate: entry.2,
                homeURL: entry.3,
                region: .japan,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: order,
                usageCount: 0,
                isCustom: false
            ))
        }

        // MARK: Korea
        let koreaData: [(String, String, String, String)] = [
            ("platform_naver",     "icon_naver",   "https://search.naver.com/search.naver?query=%@",               "https://www.naver.com"),
            ("platform_daum",      "icon_daum",    "https://search.daum.net/search?w=tot&q=%@",                   "https://www.daum.net"),
            ("platform_google_kr", "icon_google",  "https://www.google.co.kr/search?q=%@",                         "https://www.google.co.kr"),
            ("platform_youtube_kr","icon_youtube", "https://www.youtube.com/results?search_query=%@&gl=KR",       "https://www.youtube.com"),
        ]
        for (order, entry) in koreaData.enumerated() {
            all.append(SearchPlatform(
                id: UUID(),
                name: entry.0,
                iconName: entry.1,
                searchURLTemplate: entry.2,
                homeURL: entry.3,
                region: .korea,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: order,
                usageCount: 0,
                isCustom: false,
                faviconURL: entry.3
            ))
        }

        // MARK: Russia
        let russiaData: [(String, String, String, String)] = [
            ("platform_yandex", "icon_yandex", "https://yandex.ru/search/?text=%@",  "https://yandex.ru"),
            ("platform_vk",     "icon_vk",     "https://m.vk.com/search?q=%@",       "https://m.vk.com"),
        ]
        for (order, entry) in russiaData.enumerated() {
            all.append(SearchPlatform(
                id: UUID(),
                name: entry.0,
                iconName: entry.1,
                searchURLTemplate: entry.2,
                homeURL: entry.3,
                region: .russia,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: order,
                usageCount: 0,
                isCustom: false
            ))
        }

        // Mark platforms that require login
        let loginRequired: Set<String> = [
            "platform_xiaohongshu", "platform_taobao", "platform_jd",
            "platform_instagram", "platform_linkedin", "platform_twitter",
            "platform_twitter_jp", "platform_you"
        ]
        // Hide less important platforms by default (user can enable in settings)
        let hiddenByDefault = Self.defaultHiddenPlatformNames.union([
            "platform_sogou", "platform_360",
            "platform_youku", "platform_iqiyi",
            "platform_csdn", "platform_juejin",
            "platform_deepseek", "platform_yuanbao",
            "platform_instagram", "platform_linkedin", "platform_pinterest",
            "platform_ebay", "platform_stackoverflow", "platform_scholar",
            "platform_rakuten", "platform_niconico",
        ])
        for i in all.indices {
            if loginRequired.contains(all[i].name) {
                all[i].requiresLogin = true
            }
            if hiddenByDefault.contains(all[i].name) {
                all[i].isVisible = false
            }
        }

        return all
    }

    private static func xiaohongshuPlatform(sortOrder: Int) -> SearchPlatform {
        SearchPlatform(
            id: UUID(),
            name: "platform_xiaohongshu",
            iconName: "icon_xiaohongshu",
            searchURLTemplate: "https://www.xiaohongshu.com/search_result?keyword=%@&source=web_explore_feed&type=51",
            homeURL: "https://www.xiaohongshu.com",
            region: .china,
            isBuiltIn: true,
            isVisible: true,
            sortOrder: sortOrder,
            usageCount: 0,
            isCustom: false,
            requiresLogin: true
        )
    }

    private static func zLibraryPlatform(sortOrder: Int) -> SearchPlatform {
        SearchPlatform(
            id: UUID(),
            name: "platform_zlibrary",
            iconName: "icon_zlibrary",
            searchURLTemplate: "https://z-library.sk/s/book?keyword=%@",
            homeURL: "https://z-library.sk",
            region: .international,
            isBuiltIn: true,
            isVisible: true,
            sortOrder: sortOrder,
            usageCount: 0,
            isCustom: false,
            faviconURL: "https://z-library.sk"
        )
    }

    private static let defaultHiddenPlatformNames: Set<String> = [
        "platform_taobao",
        "platform_jd",
        "platform_zhihu",
        "platform_doubao",
        "platform_qianwen"
    ]
}
