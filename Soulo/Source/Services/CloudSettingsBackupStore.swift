import Foundation

struct CloudSettingsBackup: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let propertyList: Data
    let isInitial: Bool
    var version = 1
}

@MainActor
final class CloudSettingsBackupStore {
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

    private func url(for backup: CloudSettingsBackup) -> URL {
        directory.appendingPathComponent("\(backup.id.uuidString).json")
    }
}
