import Foundation
import CoreFoundation

struct CloudSettingsBackup: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let propertyList: Data
    let isInitial: Bool
    var version = 1
    // Missing in older files: preserve them as recovery snapshots rather than
    // guessing they were manual and including them in a bulk manual deletion.
    var isManual: Bool? = nil
}

@MainActor
final class CloudSettingsBackupStore {
    static let maximumRecentBackups = 20
    static let maximumPortableBackupSize = 16 * 1024 * 1024
    struct RecoveryDay: Identifiable {
        let id: Date
        let latest: CloudSettingsBackup
        let earlier: [CloudSettingsBackup]
    }

    private enum SaveMode {
        case initial, manual, daily, checkpoint
    }

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
    private let calendar: Calendar

    init(directory: URL? = nil, fileManager: FileManager = .default, calendar: Calendar = .autoupdatingCurrent) {
        self.fileManager = fileManager
        self.calendar = calendar
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

    static func recoveryDays(from newestFirst: [CloudSettingsBackup],
                             calendar: Calendar = .autoupdatingCurrent) -> [RecoveryDay] {
        let grouped = Dictionary(grouping: newestFirst.filter { $0.isManual != true }) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.compactMap { day, backups in
            backups.first.map { RecoveryDay(id: day, latest: $0, earlier: Array(backups.dropFirst())) }
        }.sorted { $0.id > $1.id }
    }

    @discardableResult
    func save(_ values: CloudSettingsSyncEngine.Values, initial: Bool = false, manual: Bool = false,
              date: Date = Date()) throws -> CloudSettingsBackup {
        try save(values, mode: initial ? .initial : (manual ? .manual : .checkpoint), date: date)
    }

    @discardableResult
    func saveDaily(_ values: CloudSettingsSyncEngine.Values, date: Date = Date()) throws -> CloudSettingsBackup {
        try save(values, mode: .daily, date: date)
    }

    private func save(_ values: CloudSettingsSyncEngine.Values, mode: SaveMode, date: Date) throws -> CloudSettingsBackup {
        _ = try CloudSettingsSyncEngine.flattened(values)
        let existing = try list()
        switch mode {
        case .initial:
            if let pinned = existing.first(where: \.isInitial) { return pinned }
        case .daily:
            // Reuse a readable recovery copy for this local day, including
            // the initial copy on the day settings sync was first enabled.
            for backup in existing where backup.isManual != true && calendar.isDate(backup.createdAt, inSameDayAs: date) {
                if (try? CloudSettingsSyncEngine.flattened(CloudSettingsSyncEngine.values(backup.propertyList))) != nil {
                    return backup
                }
            }
        case .manual, .checkpoint:
            if let latest = existing.first(where: { ($0.isManual == true) == (mode == .manual) }),
               let previous = try? CloudSettingsSyncEngine.values(latest.propertyList),
               CloudSettingsSyncEngine.equal(previous, values) { return latest }
        }
        let backup = CloudSettingsBackup(id: UUID(), createdAt: date,
                                         propertyList: try CloudSettingsSyncEngine.propertyList(values),
                                         isInitial: mode == .initial, isManual: mode == .manual)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(backup).write(to: url(for: backup), options: .atomic)
        // Historical duplicates share a retention slot. Keep the earlier
        // recovery points within the retained days, plus the initial copy.
        let savedRecoveryDay = mode == .daily || mode == .checkpoint ? calendar.startOfDay(for: date) : nil
        let otherDays = Self.recoveryDays(from: existing.filter { !$0.isInitial }, calendar: calendar)
            .filter { $0.id != savedRecoveryDay }
        let retainedExisting = Self.maximumRecentBackups - (savedRecoveryDay == nil ? 0 : 1)
        for day in otherDays.dropFirst(retainedExisting) {
            for old in [day.latest] + day.earlier { try? fileManager.removeItem(at: url(for: old)) }
        }
        return backup
    }

    func values(for backup: CloudSettingsBackup) throws -> CloudSettingsSyncEngine.Values {
        let saved = try JSONDecoder().decode(CloudSettingsBackup.self, from: Data(contentsOf: url(for: backup)))
        guard saved.version == 1, saved.id == backup.id else { throw CocoaError(.coderReadCorrupt) }
        let values = try CloudSettingsSyncEngine.values(saved.propertyList)
            .filter { !CloudSettingsSyncEngine.retiredKeys.contains($0.key) }
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
        let readableKeys = allowed.union(CloudSettingsSyncEngine.retiredKeys)
        guard portable.format == Self.portableFormat, portable.version == 1, portable.scope == "settings",
              portable.createdAt.timeIntervalSince1970.isFinite, !included.isEmpty,
              included.count == portable.includedKeys.count, included.isSubset(of: readableKeys) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let allIncoming = try CloudSettingsSyncEngine.values(portable.propertyList)
        guard Set(allIncoming.keys).isSubset(of: included) else { throw CocoaError(.coderReadCorrupt) }
        let incoming = allIncoming.filter { allowed.contains($0.key) }
        try validatePortableValues(incoming)
        var restored = currentValues.filter { allowed.contains($0.key) }
        for key in included.intersection(allowed) { restored[key] = incoming[key] }
        // Validate the resulting snapshot. A valid backup must still be able
        // to replace a corrupt current value inside its declared scope.
        try validatePortableValues(restored)
        // Full validation precedes the first write. A corrupt or newer format
        // cannot replace an existing local backup or partially change settings.
        return try save(restored, manual: true, date: date)
    }

    func delete(_ backup: CloudSettingsBackup) throws {
        let file = url(for: backup)
        guard fileManager.fileExists(atPath: file.path) else { return }
        try fileManager.removeItem(at: file)
    }

    func deleteAll() throws {
        for backup in try list() { try delete(backup) }
    }

    func deleteManualBackups() throws {
        for backup in try list() where backup.isManual == true { try delete(backup) }
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
