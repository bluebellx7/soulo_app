import XCTest
@testable import Soulo

final class FileBrowserRefinementTests: XCTestCase {
    func testLinkDomainsGroupWithoutReorderingWithinEachDomain() throws {
        let links = try ["https://example.com/a", "https://developer.apple.com/a", "https://example.com/b"].map {
            WebLinkResource(url: try XCTUnwrap(URL(string: $0)), title: $0)
        }
        let groups = WebLinkDomainGroup.group(links)
        XCTAssertEqual(groups.map(\.domain), ["example.com", "developer.apple.com"])
        XCTAssertEqual(groups[0].links.map(\.url), [links[0].url, links[2].url])
        XCTAssertEqual(WebLinkDomainGroup.group(Array(links.prefix(1))).count, 1)
        XCTAssertTrue(WebLinkDomainGroup.group([]).isEmpty)
    }

    @MainActor func testSavedBooksToolbarActionMigratesToFiles() throws {
        let suite = "Soulo.FilesMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["books", "back", "tabs", "more"], forKey: BrowserToolbarConfigurationService.actionsKey)
        defaults.set("books", forKey: BrowserToolbarConfigurationService.addressActionKey)
        let service = BrowserToolbarConfigurationService(defaults: defaults)
        XCTAssertEqual(service.actions, [.files, .back, .tabs, .more])
        XCTAssertEqual(service.addressAction, .files)
        XCTAssertEqual(LibrarySection.allCases.map(\.rawValue), ["bookmarks", "history", "downloads", "files"])
    }
}
