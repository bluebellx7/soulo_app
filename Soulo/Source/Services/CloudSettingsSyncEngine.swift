import Foundation

/// Each installation writes only its own journal. A fresh installation can never
/// replace an existing device's cloud document, even before the initial download.
struct CloudSettingsJournal: Codable {
    var version = 3
    let writerID: String
    var records: [String: CloudSettingsRecord]
    // References carry identity only, never stock preferences. Groups can then
    // refer to built-ins without publishing a fresh device's default settings.
    var platformAliases: [String: String] = [:]
}

struct CloudSettingsRecord: Codable, Equatable {
    let value: Data?
    let isExplicit: Bool
    let modifiedAt: Date
    let sequence: UInt64
    var baselinePriority = 0
}

@MainActor
enum CloudSettingsSyncEngine {
    typealias Values = [String: Any]
    private static let collections: Set<String> = ["platform_config", "custom_groups", "region_name_overrides", "soulo_ad_block_subscriptions"]
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let factoryPlatforms = Dictionary(
        PlatformDataStore.defaultPlatforms().map { (platformKey($0), $0) },
        uniquingKeysWith: { first, _ in first }
    )
    private static let factorySubscriptions = Dictionary(
        AdBlockSubscriptionService.defaultSubscriptions().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )

    static func snapshot(_ defaults: UserDefaults) -> Values {
        var values: Values = [:]
        let factory = scalarDefaults
        for key in CloudSyncService.syncedKeys {
            let value = defaults.object(forKey: key)
            // Foundation accepts YES/NO strings for boolean preferences (for
            // example, launch arguments). Store their typed value in backups.
            if factory[key] is Bool, let text = value as? String,
               ["yes", "no", "true", "false", "0", "1"].contains(text.lowercased()) {
                values[key] = defaults.bool(forKey: key)
            } else { values[key] = value }
        }
        return values
    }

    static func propertyList(_ values: Values) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    static func values(_ data: Data) throws -> Values {
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? Values else {
            throw CocoaError(.coderReadCorrupt)
        }
        return values
    }

    static func equal(_ lhs: Values, _ rhs: Values) -> Bool {
        guard let left = try? flattened(lhs), let right = try? flattened(rhs), left.keys.sorted() == right.keys.sorted() else { return false }
        return left.allSatisfy { key, value in
            (try? comparable(value, key: key)) == (try? comparable(right[key], key: key))
        }
    }

    static func platformKey(_ platform: SearchPlatform) -> String {
        // Built-ins have device-local UUIDs. Use their semantic identity on the
        // wire and preserve/remap local IDs when rebuilding groups.
        platform.isBuiltIn && !platform.isCustom
            ? "platform.builtin.\(platform.region.rawValue).\(platform.name)"
            : "platform.custom.\(platform.id.uuidString)"
    }

    static func flattened(_ values: Values) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for key in CloudSyncService.syncedKeys where !collections.contains(key) {
            if let value = values[key] {
                guard validScalar(value, key: key) else { throw CocoaError(.coderReadCorrupt) }
                result["setting.\(key)"] = try propertyList(["value": value])
            }
        }
        if let value = values["platform_config"] {
            guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
            let platforms = try JSONDecoder().decode([SearchPlatform].self, from: data)
            for platform in platforms {
                let key = platformKey(platform)
                guard result[key] == nil else { throw CocoaError(.coderReadCorrupt) }
                result[key] = try encoder.encode(platform)
            }
        }
        if let value = values["custom_groups"] {
            guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
            for group in try JSONDecoder().decode([CustomGroup].self, from: data) {
                let key = "group.\(group.id.uuidString)"
                guard result[key] == nil else { throw CocoaError(.coderReadCorrupt) }
                result[key] = try encoder.encode(group)
            }
        }
        if let value = values["soulo_ad_block_subscriptions"] {
            guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
            for subscription in try JSONDecoder().decode([AdBlockSubscription].self, from: data) {
                let key = "subscription.\(subscription.id)"
                guard result[key] == nil else { throw CocoaError(.coderReadCorrupt) }
                result[key] = try encoder.encode(preferencesOnly(subscription))
            }
        }
        if let value = values["region_name_overrides"] {
            guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
            let names = try JSONDecoder().decode([String: String].self, from: data)
            for (region, name) in names {
                result["region.\(region)"] = try propertyList(["value": name])
            }
        }
        return result
    }

    static func seed(_ values: Values, writerID: String, date: Date) throws -> CloudSettingsJournal {
        var records: [String: CloudSettingsRecord] = [:]
        for (key, value) in try flattened(values) {
            let priority = quality(value, key: key)
            // Stock defaults are not user changes. Do not publish them at all.
            guard priority > 0 else { continue }
            records[key] = CloudSettingsRecord(value: value, isExplicit: false,
                modifiedAt: date, sequence: 0, baselinePriority: priority)
        }
        var journal = CloudSettingsJournal(writerID: writerID, records: records)
        try rememberPlatformAliases(values, in: &journal)
        return journal
    }

    static func encodeJournal(_ journal: CloudSettingsJournal) throws -> Data { try encoder.encode(journal) }

    static func recordEdits(from before: Values, to after: Values,
                            in journal: inout CloudSettingsJournal, date: Date) throws -> Bool {
        let old = try flattened(before), new = try flattened(after)
        try rememberPlatformAliases(before, in: &journal)
        try rememberPlatformAliases(after, in: &journal)
        var changed = false
        for key in Set(old.keys).union(new.keys) {
            guard try comparable(old[key], key: key) != comparable(new[key], key: key) else { continue }
            let previousSequence = journal.records.values.map(\.sequence).max() ?? 0
            guard previousSequence < UInt64.max else { throw CocoaError(.coderReadCorrupt) }
            let sequence = previousSequence + 1
            let latest = journal.records.values.filter(\.isExplicit).map(\.modifiedAt).max() ?? .distantPast
            journal.records[key] = CloudSettingsRecord(
                value: new[key], isExplicit: true,
                modifiedAt: max(date, latest), sequence: sequence
            )
            changed = true
        }
        return changed
    }

    static func decodeJournal(_ data: Data, expectedWriter: String) throws -> CloudSettingsJournal {
        let journal = try JSONDecoder().decode(CloudSettingsJournal.self, from: data)
        guard journal.version == 3, journal.writerID == expectedWriter else { throw CocoaError(.coderReadCorrupt) }
        for (id, key) in journal.platformAliases {
            guard UUID(uuidString: id) != nil, key.hasPrefix("platform.") else { throw CocoaError(.coderReadCorrupt) }
            try validate(nil, key: key)
        }
        for (key, record) in journal.records {
            guard (record.isExplicit || record.value != nil), record.sequence < UInt64.max,
                  (0...1).contains(record.baselinePriority) else { throw CocoaError(.coderReadCorrupt) }
            try validate(record.value, key: key)
        }
        return journal
    }

    static func merged(_ journals: [CloudSettingsJournal], onto local: Values) throws -> Values {
        var winners: [String: (record: CloudSettingsRecord, writer: String)] = [:]
        var aliases: [UUID: String] = [:]
        for journal in journals {
            for (id, key) in journal.platformAliases {
                if let id = UUID(uuidString: id) { aliases[id] = key }
            }
            for (key, record) in journal.records {
                try validate(record.value, key: key)
                if key.hasPrefix("platform."), let data = record.value {
                    aliases[try JSONDecoder().decode(SearchPlatform.self, from: data).id] = key
                }
                if let existing = winners[key],
                   !preferred(record, writer: journal.writerID, over: existing.record, writer: existing.writer, key: key) { continue }
                winners[key] = (record, journal.writerID)
            }
        }
        var values = local
        var platforms: [String: SearchPlatform] = [:]
        if let data = local["platform_config"] as? Data {
            for platform in try JSONDecoder().decode([SearchPlatform].self, from: data) {
                let key = platformKey(platform)
                platforms[key] = platform
                aliases[platform.id] = key
            }
        }
        var groups: [UUID: CustomGroup] = [:]
        if let data = local["custom_groups"] as? Data {
            for group in try JSONDecoder().decode([CustomGroup].self, from: data) { groups[group.id] = group }
        }
        var regions: [String: String] = [:]
        if let data = local["region_name_overrides"] as? Data {
            regions = try JSONDecoder().decode([String: String].self, from: data)
        }
        var subscriptions: [String: AdBlockSubscription] = [:]
        if let data = local["soulo_ad_block_subscriptions"] as? Data {
            for subscription in try JSONDecoder().decode([AdBlockSubscription].self, from: data) {
                subscriptions[subscription.id] = subscription
            }
        }
        for (key, winner) in winners.sorted(by: { $0.key < $1.key }) {
            let data = winner.record.value
            if key.hasPrefix("setting.") {
                if let data, let value = try self.values(data)["value"] { values[String(key.dropFirst(8))] = value }
                else { values[String(key.dropFirst(8))] = nil }
            } else if key.hasPrefix("platform.") {
                if let data {
                    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    if let existing = platforms[key] {
                        object["id"] = existing.id.uuidString
                        object["usageCount"] = existing.usageCount
                    }
                    platforms[key] = try JSONDecoder().decode(SearchPlatform.self, from: JSONSerialization.data(withJSONObject: object))
                } else { platforms[key] = nil }
            } else if key.hasPrefix("group.") {
                let id = UUID(uuidString: String(key.dropFirst(6)))!
                groups[id] = try data.map { try JSONDecoder().decode(CustomGroup.self, from: $0) }
            } else if key.hasPrefix("region.") {
                regions[String(key.dropFirst(7))] = try data.flatMap { try self.values($0)["value"] as? String }
            } else if key.hasPrefix("subscription.") {
                let id = String(key.dropFirst(13))
                if let data {
                    var preference = try JSONDecoder().decode(AdBlockSubscription.self, from: data)
                    if let existing = subscriptions[id], existing.urlString == preference.urlString {
                        preference.lastUpdatedAt = existing.lastUpdatedAt
                        preference.networkRuleCount = existing.networkRuleCount
                        preference.cosmeticRuleCount = existing.cosmeticRuleCount
                        preference.errorMessage = existing.errorMessage
                    }
                    subscriptions[id] = preference
                } else { subscriptions[id] = nil }
            }
        }
        if local["platform_config"] != nil || winners.keys.contains(where: { $0.hasPrefix("platform.") }) {
            let ordered = platforms.values.sorted {
                if $0.region.rawValue != $1.region.rawValue { return $0.region.rawValue < $1.region.rawValue }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return platformKey($0) < platformKey($1)
            }
            values["platform_config"] = try encoder.encode(ordered)
        }
        if local["custom_groups"] != nil || winners.keys.contains(where: { $0.hasPrefix("group.") }) {
            for (id, var group) in groups {
                var seen = Set<UUID>()
                group.platformIDs = group.platformIDs.compactMap { member in
                    let mapped = aliases[member].flatMap { platforms[$0]?.id } ?? (platforms.values.contains { $0.id == member } ? member : nil)
                    return mapped.flatMap { seen.insert($0).inserted ? $0 : nil }
                }
                groups[id] = group
            }
            values["custom_groups"] = try encoder.encode(groups.values.sorted { $0.id.uuidString < $1.id.uuidString })
        }
        if local["region_name_overrides"] != nil || winners.keys.contains(where: { $0.hasPrefix("region.") }) {
            values["region_name_overrides"] = try encoder.encode(regions)
        }
        if local["soulo_ad_block_subscriptions"] != nil || winners.keys.contains(where: { $0.hasPrefix("subscription.") }) {
            values["soulo_ad_block_subscriptions"] = try encoder.encode(subscriptions.values.sorted { $0.id < $1.id })
        }
        return values
    }

    static func write(_ values: Values, to defaults: UserDefaults) {
        for key in CloudSyncService.syncedKeys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    private static func preferred(_ lhs: CloudSettingsRecord, writer lhsWriter: String,
                                  over rhs: CloudSettingsRecord, writer rhsWriter: String, key: String) -> Bool {
        if lhs.isExplicit != rhs.isExplicit { return lhs.isExplicit }
        if !lhs.isExplicit {
            let l = lhs.baselinePriority, r = rhs.baselinePriority
            if l != r { return l > r }
            // A fresh baseline never outranks an established baseline merely
            // because the new device's clock is newer.
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        } else if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
        return lhsWriter > rhsWriter
    }

    private static func comparable(_ data: Data?, key: String) throws -> Data? {
        guard let data, key.hasPrefix("platform.") else { return data }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["id"] = nil
        object["usageCount"] = nil
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func quality(_ data: Data?, key: String) -> Int {
        guard let data else { return 0 }
        if key.hasPrefix("platform.") {
            guard let factory = factoryPlatforms[key], let factoryData = try? encoder.encode(factory) else { return 1 }
            return (try? comparable(data, key: key)) == (try? comparable(factoryData, key: key)) ? 0 : 1
        }
        if key.hasPrefix("group.") || key.hasPrefix("region.") { return 1 }
        if key.hasPrefix("subscription.") {
            guard let factory = factorySubscriptions[String(key.dropFirst(13))],
                  let factoryData = try? encoder.encode(preferencesOnly(factory)) else { return 1 }
            return factoryData == data ? 0 : 1
        }
        let name = String(key.dropFirst(8))
        guard let value = try? values(data)["value"], let fallback = scalarDefaults[name] else { return 1 }
        return NSDictionary(dictionary: ["value": value]).isEqual(to: ["value": fallback]) ? 0 : 1
    }

    private static func validate(_ data: Data?, key: String) throws {
        if key.hasPrefix("setting.") {
            let name = String(key.dropFirst(8))
            guard CloudSyncService.syncedKeys.contains(name), !collections.contains(name) else { throw CocoaError(.coderReadCorrupt) }
            if let data {
                guard let value = try values(data)["value"], validScalar(value, key: name) else { throw CocoaError(.coderReadCorrupt) }
            }
        } else if key.hasPrefix("platform.") {
            if let data {
                let platform = try JSONDecoder().decode(SearchPlatform.self, from: data)
                guard platformKey(platform) == key else { throw CocoaError(.coderReadCorrupt) }
            } else if !key.hasPrefix("platform.builtin.") && UUID(uuidString: String(key.dropFirst("platform.custom.".count))) == nil {
                throw CocoaError(.coderReadCorrupt)
            }
        } else if key.hasPrefix("group.") {
            guard let id = UUID(uuidString: String(key.dropFirst(6))) else { throw CocoaError(.coderReadCorrupt) }
            if let data, try JSONDecoder().decode(CustomGroup.self, from: data).id != id { throw CocoaError(.coderReadCorrupt) }
        } else if key.hasPrefix("region.") {
            guard PlatformRegion(rawValue: String(key.dropFirst(7))) != nil else { throw CocoaError(.coderReadCorrupt) }
            if let data, try values(data)["value"] as? String == nil { throw CocoaError(.coderReadCorrupt) }
        } else if key.hasPrefix("subscription.") {
            let id = String(key.dropFirst(13))
            guard !id.isEmpty, id.utf8.count < 200 else { throw CocoaError(.coderReadCorrupt) }
            if let data, try JSONDecoder().decode(AdBlockSubscription.self, from: data).id != id { throw CocoaError(.coderReadCorrupt) }
        } else { throw CocoaError(.coderReadCorrupt) }
    }

    private static func preferencesOnly(_ subscription: AdBlockSubscription) -> AdBlockSubscription {
        var preference = subscription
        preference.lastUpdatedAt = nil
        preference.networkRuleCount = 0
        preference.cosmeticRuleCount = 0
        preference.errorMessage = ""
        return preference
    }

    private static func rememberPlatformAliases(_ values: Values, in journal: inout CloudSettingsJournal) throws {
        guard let data = values["platform_config"] as? Data else { return }
        for platform in try JSONDecoder().decode([SearchPlatform].self, from: data) {
            journal.platformAliases[platform.id.uuidString] = platformKey(platform)
        }
    }

    private static func validScalar(_ value: Any, key: String) -> Bool {
        if let fallback = scalarDefaults[key] {
            if fallback is Data { return value is Data }
            if fallback is String { return value is String }
            if fallback is [String] { return value is [String] }
            if fallback is Int || fallback is Bool { return value is NSNumber }
        }
        return PropertyListSerialization.propertyList(["value": value], isValidFor: .binary)
    }

    private static var scalarDefaults: Values {
        ["appearance": "dark", "theme_color": "#007AFF", "app_language": AppConstants.preferredLanguageCode(),
         "dynamic_theme": "midnight", "home_title": "Soulo", "home_subtitle": "",
         "show_bookmarks_on_home": false, "show_group_picker_on_home": false, "show_recent_searches_on_home": true,
         "show_top_search_bar": false, "keep_fullscreen_browsing": false, "web_follows_app_color_scheme": true,
         "web_warm_color_shift": false, "web_force_dark_pages": false, "web_reduce_page_motion": false,
         "web_underline_links": false, "browser_shake_action": "none", "browser_shake_intensity": "standard",
         "home_toolbar_actions": Array(repeating: HomeToolbarAction.none.rawValue, count: HomeToolbarConfigurationService.slotCount), "group_default_search_engines": Data(),
         "browser_toolbar_actions": ["home", "back", "tabs", "more"], "browser_toolbar_address_action": "darkMode",
         "ad_block_enabled": true, LiveActivityService.enabledKey: true, "privacy_https_upgrade_enabled": true,
         "privacy_strip_tracking_parameters": true, "privacy_gpc_enabled": true, "privacy_cookie_banner_enabled": true,
         "privacy_https_upgrade_excluded_hosts": [String](), "soulo_privacy_disabled_hosts": [String](),
         "soulo_ad_block_allowlisted_hosts": [String](), "soulo_ad_block_subscriptions": Data(),
         "soulo_external_navigation_blocked_hosts": [String](), "soulo_external_navigation_suppress_prompts": false,
         ExternalNavigationService.promptEnabledKey: true,
         "wallpaper_source": "pixabay", "wallpaper_gradient_id": "aurora", "wallpaper_solid_color": "#FFFFFF",
         "wallpaper_topic": "Nature", "wallpaper_vibe_tags": ["Nature", "Ocean", "Forest", "Night Sky", "Mountains", "Minimal", "Cyberpunk"],
         "wallpaper_refresh_interval": 0, "wallpaper_auto_random_sources": true, "wallpaper_auto_sources": [String](),
         "wallpaper_auto_random_topics": true, "wallpaper_only_favorites": false, "last_selected_region": "", "last_selected_group_id": ""]
    }
}
