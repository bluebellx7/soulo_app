import XCTest
import zlib
@testable import Soulo

final class ExtensionArchiveTests: XCTestCase {
    private let manifest = Data(#"{"manifest_version":3,"name":"Archive fixture","version":"1.0"}"#.utf8)

    private func archive(extraPath: String = "scripts/test.js", badCRC: Bool = false, encrypted: Bool = false, declaredSize: UInt32? = nil) -> Data {
        var local = Data(), directory = Data()
        for (path, payload) in [("manifest.json", manifest), (extraPath, Data("var answer=42;".utf8))] {
            let name = Data(path.utf8), size = UInt32(payload.count)
            let crc = payload.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) } ^ (badCRC ? 1 : 0)
            let offset = UInt32(local.count), flags: UInt16 = encrypted ? 1 : 0
            local.u32(0x04034b50); local.u16(20); local.u16(flags); local.u16(0); local.u16(0); local.u16(0)
            local.u32(crc); local.u32(size); local.u32(declaredSize ?? size); local.u16(UInt16(name.count)); local.u16(0)
            local.append(name); local.append(payload)
            directory.u32(0x02014b50); directory.u16(20); directory.u16(20); directory.u16(flags); directory.u16(0)
            directory.u16(0); directory.u16(0); directory.u32(crc); directory.u32(size); directory.u32(declaredSize ?? size)
            directory.u16(UInt16(name.count)); directory.u16(0); directory.u16(0); directory.u16(0); directory.u16(0)
            directory.u32(0); directory.u32(offset); directory.append(name)
        }
        var result = local
        result.append(directory)
        result.u32(0x06054b50); result.u16(0); result.u16(0); result.u16(2); result.u16(2)
        result.u32(UInt32(directory.count)); result.u32(UInt32(local.count)); result.u16(0)
        return result
    }

    private func prepare(_ data: Data, at root: URL, suffix: String = "zip") throws -> URL {
        let install = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture." + suffix)
        try data.write(to: file)
        return try WebExtensionPackagePreparer.prepare(sourceURL: file, in: install)
    }

    func testZIPXPIAndBothCRXHeadersPreserveExtensionResources() throws {
        let zip = archive()
        var crx2 = Data("Cr24".utf8)
        crx2.u32(2); crx2.u32(2); crx2.u32(2); crx2.append(contentsOf: [0,0,0,0]); crx2.append(zip)
        var crx3 = Data("Cr24".utf8)
        crx3.u32(3); crx3.u32(4); crx3.append(contentsOf: [0,0,0,0]); crx3.append(zip)
        for (data, suffix) in [(zip,"zip"),(zip,"xpi"),(crx2,"crx"),(crx3,"crx")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let prepared = try prepare(data, at: root, suffix: suffix)
            XCTAssertEqual(try Data(contentsOf: prepared.appendingPathComponent("manifest.json")), manifest)
            XCTAssertEqual(try String(contentsOf: prepared.appendingPathComponent("scripts/test.js"), encoding: .utf8), "var answer=42;")
        }
    }

    func testCorruptionEncryptionTraversalAndOversizeEntriesAreRejected() throws {
        for data in [archive(extraPath:"../outside.js"), archive(extraPath:"/outside.js"), archive(badCRC:true), archive(encrypted:true), archive(declaredSize:256 * 1_024 * 1_024 + 1), Data("Cr24".utf8), Data(archive().dropLast(12))] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try prepare(data, at: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("installed/Extension").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.js").path))
        }
    }

    func testPopupQueryAndFragmentDoNotPreventCompatibilityInjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Popup query","version":"1.0","permissions":["notifications"],"action":{"default_popup":"popup.html?screen=main#fragment"}}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.json"))
        try Data("<html><head></head><body>Popup</body></html>".utf8).write(to: root.appendingPathComponent("popup.html"))
        try WebExtensionPackagePreparer.installCompatibilityLayer(in: root)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("popup.html"), encoding: .utf8).contains("__soulo_webextension_compatibility.js"))
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) { append(UInt8(truncatingIfNeeded:value)); append(UInt8(truncatingIfNeeded:value >> 8)) }
    mutating func u32(_ value: UInt32) { for shift in stride(from:0,through:24,by:8) { append(UInt8(truncatingIfNeeded:value >> shift)) } }
}
