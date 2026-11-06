import Foundation
import CoreFoundation

struct CloudSettingsBackup: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let propertyList: Data
    let isInitial: Bool
    var version = 1
}

@MainActor
final class CloudSettingsBackupStore {
    static let maximumPortableBackupSize = 16 * 1024 * 1024
    private struct PortableBackup: Codable {
        let format: String
        let version: Int
        let scope: String
        let createdAt: Date
        let exportedByVersion: String?
        let includedKeys: [String]
        let propertyList: Data
    }
    private static let portableFormat = "com.dkluge.Soulo.settings-backup"
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soulo/SettingsBackups", isDirectory: true)
    }

    func list() throws -> [CloudSettingsBackup] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CloudSettingsBackup.self, from: Data(contentsOf: $0)) }
            .filter { $0.version == 1 }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ values: CloudSettingsSyncEngine.Values, initial: Bool = false,
              date: Date = Date()) throws -> CloudSettingsBackup {
        _ = try CloudSettingsSyncEngine.flattened(values)
        let existing = try list()
        if initial, let pinned = existing.first(where: \.isInitial) { return pinned }
        if !initial, let latest = existing.first,
           CloudSettingsSyncEngine.equal(try CloudSettingsSyncEngine.values(latest.propertyList), values) { return latest }
        let backup = CloudSettingsBackup(id: UUID(), createdAt: date,
                                         propertyList: try CloudSettingsSyncEngine.propertyList(values), isInitial: initial)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(backup).write(to: url(for: backup), options: .atomic)
        // Pin the pre-migration copy indefinitely. Retain the 20 most recent
        // additional copies, so repeated sync traffic cannot rotate it away.
        for old in existing.filter({ !$0.isInitial }).dropFirst(19) {
            try? fileManager.removeItem(at: url(for: old))
        }
        return backup
    }

    func values(for backup: CloudSettingsBackup) throws -> CloudSettingsSyncEngine.Values {
        let saved = try JSONDecoder().decode(CloudSettingsBackup.self, from: Data(contentsOf: url(for: backup)))
        guard saved.version == 1, saved.id == backup.id else { throw CocoaError(.coderReadCorrupt) }
        let values = try CloudSettingsSyncEngine.values(saved.propertyList)
        _ = try CloudSettingsSyncEngine.flattened(values)
        return values
    }

    /// Only settings in the documented sync scope can leave the device through
    /// this format; bookmarks and browser/private session data are separate.
    func exportData(for backup: CloudSettingsBackup) throws -> Data {
        let allowed = Set(CloudSyncService.syncedKeys)
        let values = try values(for: backup).filter { allowed.contains($0.key) }
        try validatePortableValues(values)
        let portable = PortableBackup(format: Self.portableFormat, version: 1, scope: "settings",
            createdAt: backup.createdAt,
            exportedByVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            includedKeys: allowed.sorted(), propertyList: try CloudSettingsSyncEngine.propertyList(values))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(portable)
        guard data.count <= Self.maximumPortableBackupSize else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    /// Import creates a local backup for review; it does not modify current
    /// preferences, enable sync or upload anything. Missing keys only reset
    /// settings the exporting version explicitly included in its scope.
    @discardableResult
    func importData(_ data: Data, preserving currentValues: CloudSettingsSyncEngine.Values,
                    date: Date = Date()) throws -> CloudSettingsBackup {
        guard data.count <= Self.maximumPortableBackupSize else { throw CocoaError(.fileReadTooLarge) }
        let portable = try JSONDecoder().decode(PortableBackup.self, from: data)
        let allowed = Set(CloudSyncService.syncedKeys), included = Set(portable.includedKeys)
        guard portable.format == Self.portableFormat, portable.version == 1, portable.scope == "settings",
              portable.createdAt.timeIntervalSince1970.isFinite, !included.isEmpty,
              included.count == portable.includedKeys.count, included.isSubset(of: allowed) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let incoming = try CloudSettingsSyncEngine.values(portable.propertyList)
        guard Set(incoming.keys).isSubset(of: included) else { throw CocoaError(.coderReadCorrupt) }
        try validatePortableValues(incoming)
        var restored = currentValues.filter { allowed.contains($0.key) }
        for key in included { restored[key] = incoming[key] }
        // Validate the resulting snapshot. A valid backup must still be able
        // to replace a corrupt current value inside its declared scope.
        try validatePortableValues(restored)
        // Full validation precedes the first write. A corrupt or newer format
        // cannot replace an existing local backup or partially change settings.
        return try save(restored, date: date)
    }

    func delete(_ backup: CloudSettingsBackup) throws {
        let file = url(for: backup)
        guard fileManager.fileExists(atPath: file.path) else { return }
        try fileManager.removeItem(at: file)
    }

    private func validatePortableValues(_ values: CloudSettingsSyncEngine.Values) throws {
        _ = try CloudSettingsSyncEngine.flattened(values)
        // Property lists permit NaN/infinity, but imported preferences must be
        // usable by the numeric controls that consume them.
        func hasFiniteNumbers(_ value: Any) -> Bool {
            if let number = value as? NSNumber { return number.doubleValue.isFinite }
            if let array = value as? [Any] { return array.allSatisfy(hasFiniteNumbers) }
            if let dictionary = value as? [String: Any] { return dictionary.values.allSatisfy(hasFiniteNumbers) }
            return true
        }
        guard values.values.allSatisfy(hasFiniteNumbers) else { throw CocoaError(.coderReadCorrupt) }
        if let value = values[VideoPlaybackPreferences.holdSpeedKey] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  VideoPlaybackPreferences.holdSpeeds.contains(number.doubleValue) else {
                throw CocoaError(.coderReadCorrupt)
            }
        }
    }

    private func url(for backup: CloudSettingsBackup) -> URL {
        directory.appendingPathComponent("\(backup.id.uuidString).json")
    }
}
