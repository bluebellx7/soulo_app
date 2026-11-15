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

    private let platformVersion = 47 // Increment when cached built-in defaults need migration

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

    func visiblePlatforms(forGroup group: CustomGroup) -> [SearchPlatform] {
        platformsForGroup(group).filter(\.isVisible)
    }

    func firstVisiblePlatform(for region: PlatformRegion) -> SearchPlatform? {
        visiblePlatforms(for: region).first
    }

    // MARK: - Mutations

    func incrementUsage(for platformID: UUID) {
        guard let index = platforms.firstIndex(where: { $0.id == platformID }) else { return }
        platforms[index].recordUse()
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

    /// Commit a local drag once it is dropped. Custom groups reference shared
    /// platform identities: moving between them removes only the source group's
    /// membership; a region-to-custom drag adds that reference without deleting
    /// the platform from its owning regional catalog.
    @discardableResult
    func movePlatform(_ id: UUID, from source: SearchGroupScope, to destination: SearchGroupScope,
                      relativeTo target: UUID? = nil) -> Bool {
        func ids(in scope: SearchGroupScope) -> [UUID]? {
            switch scope {
            case .region(let region): return platforms(for: region).map(\.id)
            case .custom(let group): return customGroups.first { $0.id == group }?.platformIDs.filter { id in platforms.contains { $0.id == id } }
            }
        }
        guard let sourceIDs = ids(in: source), sourceIDs.contains(id),
              let destinationIDs = ids(in: destination),
              target == nil || destinationIDs.contains(target!),
              let platformIndex = platforms.firstIndex(where: { $0.id == id }) else { return false }
        var updatedGroups = customGroups, updatedPlatforms = platforms
        var ordered = destinationIDs.filter { $0 != id }
        if target == id { ordered = destinationIDs }
        else if let target, let insertion = ordered.firstIndex(of: target) {
            let forward = source == destination && (destinationIDs.firstIndex(of: id) ?? Int.max) < (destinationIDs.firstIndex(of: target) ?? 0)
            ordered.insert(id, at: insertion + (forward ? 1 : 0))
        } else { ordered.append(id) }
        if source != destination, case .custom(let groupID) = source,
           let index = updatedGroups.firstIndex(where: { $0.id == groupID }) {
            updatedGroups[index].platformIDs.removeAll { $0 == id }
        }
        switch destination {
        case .custom(let groupID):
            guard let index = updatedGroups.firstIndex(where: { $0.id == groupID }) else { return false }
            updatedGroups[index].platformIDs = ordered
        case .region(let region):
            updatedPlatforms[platformIndex].region = region
            for (order, platformID) in ordered.enumerated() {
                if let index = updatedPlatforms.firstIndex(where: { $0.id == platformID }) { updatedPlatforms[index].sortOrder = order }
            }
        }
        // SearchPlatform equality intentionally compares only identity. A drag
        // keeps that identity, so compare the fields changed by this operation.
        let platformsChanged = zip(updatedPlatforms, platforms).contains {
            $0.region != $1.region || $0.sortOrder != $1.sortOrder
        }
        if platformsChanged { platforms = updatedPlatforms; _ = normalizeSortOrders(); savePlatforms() }
        if updatedGroups != customGroups { customGroups = updatedGroups; saveGroups() }
        return true
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

    /// Legacy arrays and grouped documents share a validated, bounded parser.
    func importPlatformsFromJSON(_ jsonString: String, groupName: String?, region: PlatformRegion = .international,
                                 intoGroupID: UUID? = nil) -> Int {
        guard let document = try? PlatformImportDocument.parse(jsonString) else { return 0 }
        return importPlatforms(document, groupName: groupName, region: region, intoGroupID: intoGroupID)
    }

    func importPlatforms(_ document: PlatformImportDocument, groupName: String?, region: PlatformRegion = .international,
                         intoGroupID: UUID? = nil) -> Int {
        applyImport(document, groupName: groupName, region: region, intoGroupID: intoGroupID).addedPlatforms
    }

    func applyImport(_ document: PlatformImportDocument, groupName: String?, region: PlatformRegion = .international,
                     intoGroupID: UUID? = nil) -> PlatformImportResult {
        // Named JSON groups are independent of the legacy destination picker.
        // An unnamed batch must never silently fall back when its group was deleted.
        if document.groups.contains(where: { $0.name == nil }), let intoGroupID,
           !customGroups.contains(where: { $0.id == intoGroupID }) { return .init() }
        var updatedPlatforms = platforms, updatedGroups = customGroups
        var known = Dictionary(platforms.map { ($0.searchURLTemplate, $0.id) }, uniquingKeysWith: { first, _ in first })
        var nextOrders = Dictionary(uniqueKeysWithValues: PlatformRegion.allCases.map { value in
            (value, (platforms.filter { $0.region == value }.map(\.sortOrder).max() ?? -1) + 1)
        })
        var result = PlatformImportResult()
        var importedIDs = Set<UUID>(), changedGroupIDs = Set<UUID>()
        for batch in document.groups {
            let name = batch.region == nil ? (batch.name ?? groupName?.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            let platformRegion = batch.region ?? region
            var target = batch.region == nil && batch.name == nil ? intoGroupID : nil
            if target == nil, let name, !name.isEmpty {
                if let existing = updatedGroups.first(where: { $0.name == name }) { target = existing.id }
                // Keep legacy duplicate-only imports from creating unwanted groups.
                // Explicit JSON groups may intentionally reuse existing platforms.
                else if !batch.platforms.isEmpty,
                        batch.name != nil || batch.platforms.contains(where: { known[$0.url] == nil }) {
                    let group = CustomGroup(name: name); updatedGroups.append(group); target = group.id
                    changedGroupIDs.insert(group.id)
                }
            }
            for item in batch.platforms {
                let id: UUID
                if let existing = known[item.url] { id = existing }
                else {
                    let home = item.homeURL ?? SearchPlatformURLInput.derivedHomeURL(from: item.url)
                    let order = nextOrders[platformRegion, default: 0]
                    let platform = SearchPlatform(id: UUID(), name: item.name, iconName: "icon_custom", searchURLTemplate: item.url,
                        homeURL: home, region: platformRegion, isBuiltIn: false, isVisible: true, sortOrder: order, usageCount: 0,
                        isCustom: true, requiresLogin: item.interactionType == .aiChat,
                        interactionType: item.interactionType ?? .urlSearch, faviconURL: Self.faviconURL(from: home))
                    nextOrders[platformRegion] = order + 1
                    updatedPlatforms.append(platform); known[item.url] = platform.id; id = platform.id
                    result.addedPlatforms += 1
                }
                if let target, let index = updatedGroups.firstIndex(where: { $0.id == target }), !updatedGroups[index].platformIDs.contains(id) {
                    updatedGroups[index].platformIDs.append(id)
                    changedGroupIDs.insert(target)
                }
                importedIDs.insert(id)
            }
        }
        if updatedPlatforms != platforms { platforms = updatedPlatforms; savePlatforms() }
        if updatedGroups != customGroups { customGroups = updatedGroups; saveGroups() }
        result.matchedPlatforms = importedIDs.count
        result.changedGroups = changedGroupIDs.count
        return result
    }

    /// Portable search links only: credentials, browsing data and unrelated
    /// settings never enter the text sent to an AI or the exported document.
    func exportPlatformLinks() throws -> Data {
        func item(_ platform: SearchPlatform) -> [String: Any] {
            ["id": platform.id.uuidString,
             "name": LanguageManager.shared.localizedString(platform.name),
             "url": platform.searchURLTemplate, "homeURL": platform.homeURL,
             "isVisible": platform.isVisible, "interactionType": platform.interactionType.rawValue]
        }
        var groups: [[String: Any]] = PlatformRegion.allCases.map { region in
            ["name": regionDisplayName(for: region), "region": region.rawValue,
             "platforms": platforms(for: region).map(item)]
        }
        groups += customGroups.map { group in
            ["id": group.id.uuidString, "name": group.name, "platforms": platformsForGroup(group).map(item)]
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "groups": groups], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func replacementPlan(_ document: PlatformImportDocument) throws -> PlatformReplacementPlan {
        guard document.rejectedPlatforms == 0, !document.groups.isEmpty,
              document.groups.contains(where: { !$0.platforms.isEmpty }),
              document.groups.allSatisfy({ $0.name != nil }) else { throw CocoaError(.coderReadCorrupt) }
        let byID = Dictionary(platforms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byURL = Dictionary(grouping: platforms, by: { SearchPlatformURLInput.searchTemplate($0.searchURLTemplate) ?? $0.searchURLTemplate })
        var next: [SearchPlatform] = [], groups: [CustomGroup] = [], names = Set<String>(), groupIDs = Set<UUID>()
        var known: [String: UUID] = [:], assembledIDs = Set<UUID>(), regionalAssignments: [UUID: PlatformRegion] = [:]
        var regionNames = regionNameOverrides
        for batch in document.groups {
            var ids: [UUID] = []
            for item in batch.platforms {
                let id: UUID
                let identity = item.id.map { "id:" + $0.uuidString } ?? "url:" + item.url
                if let existing = known[identity] { id = existing }
                else {
                    // The regional catalog may deliberately contain different
                    // entries with the same URL. Exported IDs disambiguate them.
                    let exact = item.id.flatMap { byID[$0] }.flatMap {
                        (SearchPlatformURLInput.searchTemplate($0.searchURLTemplate) ?? $0.searchURLTemplate) == item.url ? $0 : nil
                    }
                    let candidates = byURL[item.url] ?? []
                    let old = exact ?? candidates.first { !assembledIDs.contains($0.id) && (batch.region == nil || $0.region == batch.region) }
                        ?? candidates.first { !assembledIDs.contains($0.id) }
                    let home = item.homeURL ?? old?.homeURL ?? SearchPlatformURLInput.derivedHomeURL(from: item.url)
                    var platform = old ?? SearchPlatform(id: UUID(), name: item.name, iconName: "icon_custom",
                        searchURLTemplate: item.url, homeURL: home, region: batch.region ?? .international,
                        isBuiltIn: false, isVisible: item.isVisible ?? true, sortOrder: 0, usageCount: 0,
                        isCustom: true, requiresLogin: item.interactionType == .aiChat,
                        interactionType: item.interactionType ?? .urlSearch, faviconURL: Self.faviconURL(from: home))
                    if !platform.isBuiltIn || platform.isCustom { platform.name = item.name }
                    platform.homeURL = home
                    if let visible = item.isVisible { platform.isVisible = visible }
                    id = platform.id
                    if assembledIDs.insert(id).inserted { next.append(platform) }
                    known[identity] = id
                }
                if let region = batch.region {
                    if let prior = regionalAssignments[id], prior != region { throw CocoaError(.coderReadCorrupt) }
                    regionalAssignments[id] = region
                }
                if !ids.contains(id) { ids.append(id) }
            }
            if let region = batch.region { regionNames[region.rawValue] = batch.name! }
            else {
                let name = batch.name!
                guard names.insert(name).inserted else { throw CocoaError(.coderReadCorrupt) }
                let existing = batch.id.flatMap { id in customGroups.first { $0.id == id } }
                    ?? customGroups.first { $0.name == name }
                let id = existing?.id ?? UUID()
                guard groupIDs.insert(id).inserted else { throw CocoaError(.coderReadCorrupt) }
                groups.append(CustomGroup(id: id, name: name, platformIDs: ids))
            }
        }
        var orders: [PlatformRegion: Int] = [:]
        for index in next.indices {
            if let region = regionalAssignments[next[index].id] { next[index].region = region }
            let region = next[index].region
            next[index].sortOrder = orders[region, default: 0]; orders[region, default: 0] += 1
        }
        return PlatformReplacementPlan(platforms: next, groups: groups, regionNames: regionNames)
    }

    /// Validate and encode first. If the durable backup cannot be saved, the
    /// entire replacement fails without changing any platform or group.
    @discardableResult
    func replacePlatforms(_ document: PlatformImportDocument, backupStore: CloudSettingsBackupStore? = nil) throws -> PlatformImportResult {
        let plan = try replacementPlan(document), encoder = JSONEncoder()
        let platformData = try encoder.encode(plan.platforms), groupData = try encoder.encode(plan.groups)
        let namesData = try encoder.encode(plan.regionNames)
        var previous = CloudSettingsSyncEngine.snapshot(.standard)
        previous["platform_config"] = try encoder.encode(platforms)
        previous["custom_groups"] = try encoder.encode(customGroups)
        previous["region_name_overrides"] = try encoder.encode(regionNameOverrides)
        try (backupStore ?? CloudSettingsBackupStore()).save(previous)
        let oldIDs = Set(platforms.map(\.id))
        platforms = plan.platforms; customGroups = plan.groups; regionNameOverrides = plan.regionNames
        // A single main-actor turn publishes all collections before cloud sync
        // can snapshot them; normal sync journaling records explicit removals.
        UserDefaults.standard.set(platformData, forKey: userDefaultsKey)
        UserDefaults.standard.set(groupData, forKey: groupsKey)
        UserDefaults.standard.set(namesData, forKey: regionNamesKey)
        return PlatformImportResult(addedPlatforms: plan.platforms.filter { !oldIDs.contains($0.id) }.count,
            matchedPlatforms: plan.platforms.count, changedGroups: plan.groups.count, replaced: true)
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
        GroupDefaultSearchService.shared.reset()
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
        if version < 42,
           !platforms.contains(where: { $0.isBuiltIn && $0.name == "platform_bing" && $0.region == .china }) {
            let nextOrder = (platforms
                .filter { $0.region == .china }
                .map(\.sortOrder)
                .max() ?? -1) + 1
            platforms.append(Self.chinaBingPlatform(sortOrder: nextOrder))
        }
        if version < 43 {
            if let index = platforms.firstIndex(where: { $0.isBuiltIn && ["Kimi", "platform_kimi"].contains($0.name) }) {
                platforms[index].name = "Kimi"
                platforms[index].homeURL = "https://www.kimi.com/"
                platforms[index].searchURLTemplate = "https://www.kimi.com/"
                platforms[index].requiresLogin = true
                platforms[index].interactionType = .aiChat
            } else {
                let order = (platforms.filter { $0.region == .china }.map(\.sortOrder).max() ?? -1) + 1
                platforms.append(Self.kimiPlatform(sortOrder: order))
            }
        }

        if version < 44,
           !platforms.contains(where: { $0.isBuiltIn && $0.name == "platform_shenma" }),
           var shenma = Self.defaultPlatforms().first(where: { $0.name == "platform_shenma" }) {
            let china = platforms(for: .china)
            let position = china.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_baidu" }).map { $0 + 1 } ?? 0
            // Respect a fully disabled group and preserve the user's existing order.
            shenma.isVisible = china.contains(where: \.isVisible)
            shenma.sortOrder = position
            for (order, platform) in china.enumerated() {
                if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
                    platforms[index].sortOrder = order >= position ? order + 1 : order
                }
            }
            platforms.append(shenma)
        }

        if version < 45 {
            var china = platforms(for: .china)
            if let shenmaIndex = china.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_shenma" }),
               china.contains(where: { $0.isBuiltIn && $0.name == "platform_baidu" }) {
                let shenma = china.remove(at: shenmaIndex)
                let baiduIndex = china.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_baidu" })!
                china.insert(shenma, at: baiduIndex)
                for (order, platform) in china.enumerated() {
                    if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
                        platforms[index].sortOrder = order
                    }
                }
            }
        }

        if version < 46,
           let quarkDefault = Self.defaultPlatforms().first(where: { $0.name == "platform_quark" }) {
            if let index = platforms.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_shenma" }) {
                platforms[index].name = quarkDefault.name
                platforms[index].iconName = quarkDefault.iconName
                platforms[index].searchURLTemplate = quarkDefault.searchURLTemplate
                platforms[index].homeURL = quarkDefault.homeURL
            } else if version < 44, !platforms.contains(where: { $0.isBuiltIn && $0.name == "platform_quark" }) {
                // Older catalogs never had Shenma. Preserve an intentionally
                // deleted entry in newer catalogs, and a fully disabled group.
                let china = platforms(for: .china)
                let position = china.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_baidu" }) ?? 0
                var quark = quarkDefault
                quark.isVisible = china.contains(where: \.isVisible)
                quark.sortOrder = position
                for (order, platform) in china.enumerated() {
                    if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
                        platforms[index].sortOrder = order >= position ? order + 1 : order
                    }
                }
                platforms.append(quark)
            }
        }


        if version < 47 {
            var china = platforms(for: .china)
            if let baiduIndex = china.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_baidu" }),
               china.contains(where: { $0.isBuiltIn && $0.name == "platform_quark" }) {
                let baidu = china.remove(at: baiduIndex)
                let quarkIndex = china.firstIndex(where: { $0.isBuiltIn && $0.name == "platform_quark" })!
                china.insert(baidu, at: quarkIndex)
                for (order, platform) in china.enumerated() {
                    if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
                        platforms[index].sortOrder = order
                    }
                }
            }
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
              let decoded = try? JSONDecoder().decode([CustomGroup].self, from: data) else { customGroups = []; return }
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
        GroupDefaultSearchService.shared.remove(.custom(id))
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
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { regionNameOverrides = [:]; return }
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

    static func kimiPlatform(sortOrder: Int) -> SearchPlatform {
        SearchPlatform(id: UUID(), name: "Kimi", iconName: "icon_kimi",
            searchURLTemplate: "https://www.kimi.com/", homeURL: "https://www.kimi.com/",
            region: .china, isBuiltIn: true, isVisible: false, sortOrder: sortOrder,
            usageCount: 0, isCustom: false, requiresLogin: true, interactionType: .aiChat)
    }

    // MARK: - Default Platforms

    static func defaultPlatforms() -> [SearchPlatform] {
        var all: [SearchPlatform] = []

        // MARK: China
        let chinaData: [(String, String, String, String)] = [
            ("platform_baidu",        "icon_baidu",        "https://www.baidu.com/s?wd=%@",                             "https://www.baidu.com"),
            ("platform_quark",        "icon_quark",        "https://quark.sm.cn/s?q=%@&safe=1&by=submit&snum=1",           "https://quark.sm.cn/"),
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
        all.append(Self.chinaBingPlatform(sortOrder: chinaData.count))

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
            sortOrder: chinaData.count + 1,
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
                sortOrder: chinaData.count + 2 + offset, // Bing and Zhihu follow chinaData
                usageCount: 0,
                isCustom: false,
                requiresLogin: true,
                interactionType: .aiChat
            ))
        }

        all.append(Self.kimiPlatform(sortOrder: chinaData.count + 2 + aiPlatforms.count))

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

    private static func chinaBingPlatform(sortOrder: Int) -> SearchPlatform {
        SearchPlatform(
            id: UUID(),
            name: "platform_bing",
            iconName: "icon_bing",
            searchURLTemplate: "https://www.bing.com/search?q=%@",
            homeURL: "https://www.bing.com",
            region: .china,
            isBuiltIn: true,
            isVisible: true,
            sortOrder: sortOrder,
            usageCount: 0,
            isCustom: false
        )
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


struct PlatformReplacementPlan {
    let platforms: [SearchPlatform]
    let groups: [CustomGroup]
    let regionNames: [String: String]
}

struct PlatformImportResult {
    var addedPlatforms = 0
    var matchedPlatforms = 0
    var changedGroups = 0
    var replaced = false
    var hasChanges: Bool { replaced || addedPlatforms > 0 || changedGroups > 0 }
}

struct PlatformImportDocument: Sendable {
    struct Item: Decodable, Sendable {
        var name: String
        var url: String
        var homeURL: String?
        var id: UUID? = nil
        var isVisible: Bool? = nil
        var interactionType: PlatformInteractionType? = nil
    }
    struct Group: Decodable, Sendable {
        var name: String?
        var platforms: [Item]
        var id: UUID? = nil
        var region: PlatformRegion? = nil
    }
    let groups: [Group]
    var rejectedPlatforms = 0
    static func parse(_ source: String) throws -> Self {
        guard let data = source.data(using: .utf8), data.count <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder()
        struct Envelope: Decodable { let groups: [Group] }
        var groups: [Group]
        if let legacy = try? decoder.decode([Item].self, from: data) { groups = [.init(name: nil, platforms: legacy)] }
        else if let envelope = try? decoder.decode(Envelope.self, from: data) { groups = envelope.groups }
        else if let multiple = try? decoder.decode([Group].self, from: data) { groups = multiple }
        else { groups = [try decoder.decode(Group.self, from: data)] }
        guard groups.count <= 100, groups.reduce(0, { $0 + $1.platforms.count }) <= 2_000 else { throw CocoaError(.fileReadTooLarge) }
        var rejected = 0
        for index in groups.indices {
            if let name = groups[index].name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { throw CocoaError(.coderReadCorrupt) }
                groups[index].name = trimmed
            }
            let originalCount = groups[index].platforms.count
            groups[index].platforms = groups[index].platforms.compactMap { item in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let template = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let placeholders = template.components(separatedBy: "%@").count - 1
                guard !name.isEmpty, name.utf8.count <= 512, template.utf8.count <= 8_192,
                      item.interactionType == .aiChat ? placeholders <= 1 : placeholders == 1,
                      let url = SearchPlatformURLInput.webURL(from: template.replacingOccurrences(of: "%@", with: "test")),
                      url.user == nil, url.password == nil else { return nil }
                let home: String?
                if let provided = item.homeURL, !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard provided.utf8.count <= 8_192, let url = SearchPlatformURLInput.webURL(from: provided),
                          url.user == nil, url.password == nil else { return nil }
                    home = url.absoluteString
                } else { home = nil }
                return .init(name: name, url: template, homeURL: home, id: item.id, isVisible: item.isVisible, interactionType: item.interactionType)
            }
            rejected += originalCount - groups[index].platforms.count
        }
        return .init(groups: groups, rejectedPlatforms: rejected)
    }
}
