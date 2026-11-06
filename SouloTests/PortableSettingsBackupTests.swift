import XCTest
@testable import Soulo

@MainActor
final class PortableSettingsBackupTests: XCTestCase {
    private func store() -> CloudSettingsBackupStore {
        CloudSettingsBackupStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableSettingsBackup-\(UUID())", isDirectory: true))
    }

    private func changed(_ data: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testExportRoundTripContainsOnlySettingsAndDoesNotRestoreThemAutomatically() throws {
        let source = store(), target = store()
        defer { try? FileManager.default.removeItem(at: source.directory); try? FileManager.default.removeItem(at: target.directory) }
        let original = try source.save(["home_title": "Saved", "is_incognito": true, "bookmarks": "excluded"])
        let data = try source.exportData(for: original)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap((envelope["propertyList"] as? String).flatMap { Data(base64Encoded: $0) })
        let exported = try CloudSettingsSyncEngine.values(payload)
        XCTAssertEqual(exported["home_title"] as? String, "Saved")
        XCTAssertNil(exported["is_incognito"])
        XCTAssertNil(exported["bookmarks"])
        let current: CloudSettingsSyncEngine.Values = ["home_title": "Current"]
        let imported = try target.importData(data, preserving: current)
        XCTAssertEqual(current["home_title"] as? String, "Current", "Import only creates a backup; restore is a separate action")
        XCTAssertEqual(try target.values(for: imported)["home_title"] as? String, "Saved")
    }

    func testOlderScopePreservesNewSettingsButHonorsExplicitMissingKeys() throws {
        let backups = store(); defer { try? FileManager.default.removeItem(at: backups.directory) }
        let original = try backups.save(["home_title": "Older"])
        let exported = try backups.exportData(for: original)
        let oldFormat = try changed(exported) { object in
            object["includedKeys"] = ["home_title", "home_subtitle"]
            object["propertyList"] = try CloudSettingsSyncEngine.propertyList(["home_title": "Older"]).base64EncodedString()
        }
        let imported = try backups.importData(oldFormat, preserving: [
            "home_title": "Current", "home_subtitle": "Explicitly reset", VideoPlaybackPreferences.holdSpeedKey: 2.5,
            "is_incognito": true
        ])
        let values = try backups.values(for: imported)
        XCTAssertEqual(values["home_title"] as? String, "Older")
        XCTAssertNil(values["home_subtitle"], "The old format explicitly included this missing/default setting")
        XCTAssertEqual(values[VideoPlaybackPreferences.holdSpeedKey] as? Double, 2.5,
                       "An older exporting version cannot reset settings it did not know")
        XCTAssertNil(values["is_incognito"])
    }

    func testValidImportCanReplaceInvalidCurrentValuesInsideItsScope() throws {
        let backups = store(); defer { try? FileManager.default.removeItem(at: backups.directory) }
        let original = try backups.save(["home_title": "Recovered", VideoPlaybackPreferences.holdSpeedKey: 2.5])
        let data = try backups.exportData(for: original)
        let imported = try backups.importData(data, preserving: [
            "home_title": 42, VideoPlaybackPreferences.holdSpeedKey: "invalid current preference"
        ])
        let restored = try backups.values(for: imported)
        XCTAssertEqual(restored["home_title"] as? String, "Recovered")
        XCTAssertEqual(restored[VideoPlaybackPreferences.holdSpeedKey] as? Double, 2.5)
    }

    func testUnsupportedVersionsScopesAndInvalidValuesLeaveExistingBackupsUntouched() throws {
        let backups = store(); defer { try? FileManager.default.removeItem(at: backups.directory) }
        let existing = try backups.save(["home_title": "Only good copy"], initial: true)
        let exported = try backups.exportData(for: existing)
        let invalid = try [
            changed(exported) { $0["version"] = 99 },
            changed(exported) { $0["format"] = "another-app" },
            changed(exported) { $0["scope"] = "bookmarks" },
            changed(exported) { $0["includedKeys"] = ["is_incognito"] },
            changed(exported) { $0["includedKeys"] = ["home_title", "home_title"] },
            changed(exported) { $0["propertyList"] = try CloudSettingsSyncEngine.propertyList(["home_title": 42]).base64EncodedString() },
            changed(exported) { $0["propertyList"] = try CloudSettingsSyncEngine.propertyList([VideoPlaybackPreferences.holdSpeedKey: "2.5"]).base64EncodedString() },
            changed(exported) { $0["propertyList"] = try CloudSettingsSyncEngine.propertyList([VideoPlaybackPreferences.holdSpeedKey: true]).base64EncodedString() },
            changed(exported) { $0["propertyList"] = try CloudSettingsSyncEngine.propertyList([VideoPlaybackPreferences.holdSpeedKey: 99.0]).base64EncodedString() },
            changed(exported) { $0["propertyList"] = try CloudSettingsSyncEngine.propertyList([VideoPlaybackPreferences.holdSpeedKey: Double.nan]).base64EncodedString() },
            changed(exported) { $0["propertyList"] = Data("corrupt plist".utf8).base64EncodedString() }
        ]
        for data in invalid {
            XCTAssertThrowsError(try backups.importData(data, preserving: ["home_title": "Current"]))
            XCTAssertEqual(try backups.list().map(\.id), [existing.id])
            XCTAssertEqual(try backups.values(for: existing)["home_title"] as? String, "Only good copy")
        }
        XCTAssertThrowsError(try backups.importData(Data(repeating: 0, count: CloudSettingsBackupStore.maximumPortableBackupSize + 1), preserving: [:]))
        XCTAssertEqual(try backups.list().map(\.id), [existing.id])
    }
}
