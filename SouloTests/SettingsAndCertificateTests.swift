import XCTest
import Security
import UIKit
@testable import Soulo

final class SettingsAndCertificateTests: XCTestCase {
    func testShortcutOrderDefaultsAndRecovery() {
        XCTAssertEqual(AppQuickAction.resolvedOrder(nil), AppQuickAction.defaultOrder)
        XCTAssertEqual(AppQuickAction.resolvedOrder([]), [])
        let input = [AppQuickAction.search.rawValue, "obsolete", AppQuickAction.search.rawValue,
                     AppQuickAction.shareApp.rawValue, AppQuickAction.scan.rawValue]
        XCTAssertEqual(AppQuickAction.resolvedOrder(input), [.search, .scan])
        XCTAssertEqual(AppQuickAction.resolvedOrder(["obsolete"]), AppQuickAction.defaultOrder)
        XCTAssertEqual(AppQuickAction.resolvedOrder(AppQuickAction.availableActions.map(\.rawValue)).count, 4)
        XCTAssertEqual(AppQuickAction.files.librarySection, .files)
        XCTAssertEqual(AppQuickAction.bookmarks.librarySection, .bookmarks)
        XCTAssertEqual(AppQuickAction.downloads.librarySection, .downloads)
        XCTAssertEqual(AppQuickAction.history.librarySection, .history)
    }

    @MainActor
    func testSavedOrderUpdatesSystemShortcutsAndSurvivesReload() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppQuickAction.orderKey)
        let previousItems = UIApplication.shared.shortcutItems
        defer {
            if let previous { defaults.set(previous, forKey: AppQuickAction.orderKey) }
            else { defaults.removeObject(forKey: AppQuickAction.orderKey) }
            UIApplication.shared.shortcutItems = previousItems
        }
        let desired: [AppQuickAction] = [.files, .bookmarks, .downloads, .history]
        AppQuickActionService.shared.saveOrder(desired)
        XCTAssertEqual(defaults.stringArray(forKey: AppQuickAction.orderKey), desired.map(\.rawValue))
        AppQuickActionService.shared.configureShortcuts()
        XCTAssertEqual(UIApplication.shared.shortcutItems?.map(\.type), desired.map(\.rawValue))
        XCTAssertEqual(UIApplication.shared.shortcutItems?.map(\.localizedTitle), desired.map(\.title))
    }

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "site-certificate", withExtension: "der", subdirectory: "ReadingFixtures"))
        return try Data(contentsOf: url)
    }

    func testCertificateIdentityValidityDomainsKeyAndFingerprint() throws {
        let info = try XCTUnwrap(SiteCertificateInfo(data: try fixture()))
        XCTAssertTrue(info.subject.contains("CN=example.com"))
        XCTAssertTrue(info.subject.contains("O=Soulo Test"))
        XCTAssertEqual(info.issuer, info.subject)
        XCTAssertEqual(info.serial, "12:34")
        XCTAssertEqual(info.domains, ["example.com", "*.example.com", "127.0.0.1", "::1"])
        XCTAssertEqual(info.publicKey, "RSA · 2048 bit")
        XCTAssertEqual(info.fingerprint, "96:55:83:D1:88:8A:00:DB:F3:2D:6C:56:4E:BC:C7:07:FC:4A:2F:0D:33:F6:16:5A:0F:2A:36:B9:02:34:B7:85")
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(info.notBefore, formatter.date(from: "2026-09-16T02:55:02Z"))
        XCTAssertEqual(info.notAfter, formatter.date(from: "2054-02-01T02:55:02Z"))
    }

    func testChainSnapshotDoesNotPerformOrOverrideTrustEvaluation() throws {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try fixture() as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "example.com" as CFString), &trust), errSecSuccess)
        let chain = SiteCertificateInfo.chain(from: trust)
        XCTAssertEqual(chain.count, 1)
        XCTAssertTrue(chain[0].subject.contains("example.com"))
        XCTAssertTrue(SiteCertificateInfo.chain(from: nil).isEmpty)
        // Snapshotting details must never add trust exceptions for this self-signed fixture.
        var error: CFError?
        XCTAssertFalse(SecTrustEvaluateWithError(try XCTUnwrap(trust), &error))
    }

    func testMalformedAndOversizedCertificatesAreRejected() throws {
        let data = try fixture()
        for length in [0, 1, 3, data.count / 2, data.count - 1] {
            XCTAssertNil(SiteCertificateInfo(data: data.prefix(length)))
        }
        XCTAssertNil(SiteCertificateInfo(data: Data(repeating: 0, count: 1_048_577)))
        XCTAssertNil(SiteCertificateInfo(data: Data([0x30, 0x84, 0xff, 0xff, 0xff, 0xff])))
    }
}
