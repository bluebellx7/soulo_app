import XCTest
@testable import Soulo

@MainActor final class ExtensionLifecycleTests: XCTestCase {
    func testFailedEnableRestoresOffStateAndExplainsFailure() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(#"{"manifest_version":3,"name":"Load failure fixture","version":"1.0"}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        let service = BrowserExtensionService.shared
        let record = try await service.installWebExtension(from: source)
        defer { service.deleteWebExtension(record.id) }
        service.setWebExtensionEnabled(record.id, enabled: false)
        let installed = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SouloExtensions/WebExtensions/\(record.id.uuidString)")
        try FileManager.default.removeItem(at: installed)
        service.setWebExtensionEnabled(record.id, enabled: true)
        for _ in 0..<100 where service.loadingWebExtensions.contains(record.id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(service.loadingWebExtensions.contains(record.id))
        XCTAssertEqual(service.webExtensions.first { $0.id == record.id }?.isEnabled, false)
        XCTAssertNotNil(service.webExtensionErrors[record.id])
        service.deleteWebExtension(record.id)
        XCTAssertNil(service.webExtensionErrors[record.id])
    }

    func testUserScriptUpdateKeepsValuesAndOffStateThenDeleteRemovesAccess() throws {
        let service = BrowserExtensionService.shared
        let source = """
        // ==UserScript==
        // @name Lifecycle \(UUID().uuidString)
        // @namespace soulo.lifecycle
        // @version 1
        // @match https://example.com/*
        // @grant GM_getValue
        // @grant GM_setValue
        // ==/UserScript==
        """
        let record = try service.saveUserScript(id: nil, fallbackName: "Lifecycle", source: source, explicitPatterns: nil, injectionTime: nil)
        defer { service.deleteUserScript(record.id) }
        try service.setStoredValue(#"{"value":"retained"}"#, forKey: "state", scriptID: record.id)
        service.setUserScriptEnabled(record.id, enabled: false)
        let updated = try service.saveUserScript(id: nil, fallbackName: "Lifecycle", source: source.replacingOccurrences(of: "@version 1", with: "@version 2"), explicitPatterns: nil, injectionTime: nil)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.storedValues?["state"], #"{"value":"retained"}"#)
        service.deleteUserScript(record.id)
        XCTAssertNil(service.userScript(id: record.id))
        XCTAssertThrowsError(try service.setStoredValue(#"{"value":1}"#, forKey: "state", scriptID: record.id))
    }
}
