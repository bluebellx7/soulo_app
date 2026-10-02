import Foundation

/// Derived output only. Exact input keys and atomic replacement allow concurrent
/// preparation; a missing, stale or damaged entry always falls back to generation.
struct AdBlockStartupCache {
    enum Slot: String { case cosmeticScript, contentRuleIdentifiers }

    private struct Entry<Value: Codable>: Codable {
        let key: String
        let value: Value
    }

    static let shared = AdBlockStartupCache(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("SouloAdBlockStartup", isDirectory: true))

    let directory: URL?

    func read<Value: Codable>(_ type: Value.Type, slot: Slot, key: String) -> Value? {
        guard let url = directory?.appendingPathComponent(slot.rawValue + ".json"),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data),
              entry.key == key else { return nil }
        return entry.value
    }

    func write<Value: Codable>(_ value: Value, slot: Slot, key: String) {
        guard let directory,
              let data = try? JSONEncoder().encode(Entry(key: key, value: value)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(slot.rawValue + ".json"), options: .atomic)
    }
}

/// Avoid initializing the large subscription archive just to discover that
/// today's update already ran. The stamp is recorded only after validation.
struct AdBlockAutomaticUpdateState: Codable, Equatable {
    static let storageKey = "soulo_ad_block_validated_update_cache"
    let parserVersion: Int
    let revision: Double
    let modifiedAt: Date
    let size: Int
    let hasRules: Bool

    static func snapshot(archive: URL, defaults: UserDefaults, hasRules: Bool) -> Self? {
        // URL caches resource values. Reusing a URL after atomic replacement
        // or removal must inspect the file that exists now, not its old metadata.
        var archive = archive
        archive.removeAllCachedResourceValues()
        guard let values = try? archive.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modifiedAt = values.contentModificationDate, let size = values.fileSize else { return nil }
        return Self(parserVersion: AdBlockRuleParser.version,
                    revision: defaults.double(forKey: "soulo_ad_block_subscription_rules_version"),
                    modifiedAt: modifiedAt, size: size, hasRules: hasRules)
    }

    static func canSkipCheck(archive: URL, defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - defaults.double(forKey: "soulo_ad_block_subscription_auto_update_check")
        guard age >= 0, age < 24 * 60 * 60,
              defaults.data(forKey: "soulo_ad_block_subscription_rules") == nil,
              let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.hasRules,
              let current = snapshot(archive: archive, defaults: defaults, hasRules: true) else { return false }
        return current == saved
    }

    static func record(archive: URL, defaults: UserDefaults, hasRules: Bool) {
        guard let state = snapshot(archive: archive, defaults: defaults, hasRules: hasRules),
              let data = try? JSONEncoder().encode(state) else { return }
        if defaults.data(forKey: storageKey) != data { defaults.set(data, forKey: storageKey) }
    }
}
