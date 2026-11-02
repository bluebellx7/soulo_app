import CoreSpotlight
import SwiftData
import XCTest
@testable import Soulo

@MainActor
final class AppFunctionalAuditTests: XCTestCase {
    func testPathSearchKeepsReservedCharactersInsideOneKeywordSegment() throws {
        let platform = fixturePlatform(template: "https://example.com/search/%@")
        for keyword in ["AC/DC", "猫?狗", "a#b", "a%2Fb", "C++", "a&b=c"] {
            let url = try XCTUnwrap(platform.searchURL(for: keyword))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.percentEncodedPath.split(separator: "/").count, 2, keyword)
            XCTAssertEqual(components.percentEncodedPath.removingPercentEncoding, "/search/" + keyword)
            XCTAssertNil(components.query, keyword)
            XCTAssertNil(components.fragment, keyword)
        }
    }

    func testQuerySearchPreservesExactKeywordWithoutAddingParameters() throws {
        let platform = fixturePlatform(template: "https://example.com/?q=%@&type=search")
        for keyword in ["AC/DC?C++ & #中文", "a%2Fb", "line\nnext", "a=b&c=d"] {
            let url = try XCTUnwrap(platform.searchURL(for: keyword))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.count, 2)
            XCTAssertEqual(components.queryItems?.first?.value, keyword)
            XCTAssertNil(components.fragment)
        }
    }

    func testAllSuggestionProvidersReceiveTheExactKeyword() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditSuggestionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let keyword = "C++ & 猫#狗?x=1/a%2Fb"
        let fixtures: [(PlatformRegion, String, String, Int)] = [
            (.china, "wd", #"({q:"test",p:false,s:["term"]});"#, 3),
            (.international, "q", #"["test",["term"]]"#, 2),
            (.russia, "part", #"["test",["term"]]"#, 1),
            (.korea, "q", #"{"items":[[["term","metadata"]]]}"#, 5)
        ]
        for (region, name, body, parameterCount) in fixtures {
            AuditSuggestionProtocol.prepare(body: Data(body.utf8))
            let suggestions = await SearchSuggestionService.fetch(query: keyword, region: region, session: session)
            XCTAssertEqual(suggestions, ["term"])
            let url = try XCTUnwrap(AuditSuggestionProtocol.requests().first)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == name })?.value, keyword)
            XCTAssertEqual(components.queryItems?.count, parameterCount)
            XCTAssertNil(components.fragment)
        }
    }

    func testBaiduSuggestionsDecodePunctuationEscapesAndBothObjectFormats() {
        let expected = ["a,b", "a]b", "quoted\"text", "C++", "猫与狗"]
        XCTAssertEqual(SearchSuggestionService.baiduSuggestions(from:
            #"({q:"x",p:false,s:["a,b","a]b","quoted\"text","C++","\u732b\u4e0e\u72d7"]});"#), expected)
        XCTAssertEqual(SearchSuggestionService.baiduSuggestions(from:
            #"window.baidu.sug({"s":["a,b","a]b","quoted\"text","C++","猫与狗"]});"#), expected)
        for invalid in ["", "{s:[", "({s:42});", "({s:[1,2]});"] {
            XCTAssertTrue(SearchSuggestionService.baiduSuggestions(from: invalid).isEmpty)
        }
    }

    func testSuggestionServerFailureIsNotShownAsResults() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditSuggestionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        AuditSuggestionProtocol.prepare(body: Data(#"["test",["Do not display"]]"#.utf8), status: 503)
        let suggestions = await SearchSuggestionService.fetch(query: "test", region: .international, session: session)
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testInvalidPlatformImportDoesNotCreatePlatformsOrEmptyGroups() throws {
        try withIsolatedPlatforms { store in
            let input = #"[{"name":" ","url":"https://example.com/?q=%@"},{"name":"Script","url":"javascript:alert('%@')"},{"name":"Missing placeholder","url":"https://example.com"},{"name":"Missing host","url":"https:///%@"}]"#
            XCTAssertEqual(store.importPlatformsFromJSON(input, groupName: "Empty"), 0)
            XCTAssertTrue(store.platforms.isEmpty)
            XCTAssertTrue(store.customGroups.isEmpty)
        }
    }

    func testPlatformImportTrimsValidValuesDeduplicatesAndPreservesHomePort() throws {
        try withIsolatedPlatforms { store in
            let input = #"[{"name":" Example ","url":" https://localhost:8443/search?q=%@ "},{"name":"Duplicate","url":"https://localhost:8443/search?q=%@"},{"name":"Invalid","url":"file:///%@"}]"#
            XCTAssertEqual(store.importPlatformsFromJSON(input, groupName: " Group "), 1)
            let platform = try XCTUnwrap(store.platforms.first)
            XCTAssertEqual(platform.name, "Example")
            XCTAssertEqual(platform.homeURL, "https://localhost:8443")
            XCTAssertEqual(store.customGroups.first?.name, "Group")
            XCTAssertEqual(store.customGroups.first?.platformIDs, [platform.id])
            XCTAssertEqual(store.importPlatformsFromJSON(input, groupName: "Unneeded"), 0)
            XCTAssertEqual(store.customGroups.count, 1)
        }
    }

    func testPlatformImportUsesSelectedGroupIdentityWithDuplicateNames() throws {
        try withIsolatedPlatforms { store in
            let first = CustomGroup(name: "Same"), selected = CustomGroup(name: "Same")
            store.customGroups = [first, selected]
            let input = #"[{"name":"Example","url":"https://example.com/?q=%@"}]"#
            XCTAssertEqual(store.importPlatformsFromJSON(input, groupName: nil, intoGroupID: selected.id), 1)
            XCTAssertTrue(store.customGroups[0].platformIDs.isEmpty)
            XCTAssertEqual(store.customGroups[1].platformIDs, [try XCTUnwrap(store.platforms.first).id])
        }
    }

    func testRemovedImportDestinationDoesNotSilentlyImportElsewhere() throws {
        try withIsolatedPlatforms { store in
            let input = #"[{"name":"Example","url":"https://example.com/?q=%@"}]"#
            XCTAssertEqual(store.importPlatformsFromJSON(input, groupName: "Fallback", intoGroupID: UUID()), 0)
            XCTAssertTrue(store.platforms.isEmpty)
            XCTAssertTrue(store.customGroups.isEmpty)
        }
    }

    func testRestoredUsageCountsCannotOverflowWhenSearching() throws {
        try withIsolatedPlatforms { store in
            var platform = fixturePlatform(template: "https://example.com/?q=%@")
            platform.usageCount = -5
            platform.recordUse()
            XCTAssertEqual(platform.usageCount, 1)
            platform.usageCount = Int.max
            platform.recordUse()
            XCTAssertEqual(platform.usageCount, Int.max)
            store.platforms = [platform]
            store.incrementUsage(for: platform.id)
            XCTAssertEqual(store.platforms.first?.usageCount, Int.max)
            let model = SearchViewModel()
            model.selectedRegion = platform.region
            model.selectedPlatform = platform
            model.searchText = "query"
            model.performSearch()
            XCTAssertEqual(model.selectedPlatform?.usageCount, Int.max)
            XCTAssertEqual(store.platforms.first?.usageCount, Int.max)
            model.clearSearch()
        }
    }

    func testDeletingHistoryRemovesItsSystemSearchEntryAndKeepsOtherData() throws {
        let container = try modelContainer()
        let context = container.mainContext
        let history = SearchHistoryItem(keyword: "Removed query")
        let kept = SearchHistoryItem(keyword: "Kept query")
        let identifier = "search-history-\(history.id.uuidString)"
        context.insert(history); context.insert(kept); try context.save()
        let index = AuditSearchableIndex(name: UUID().uuidString)
        SearchHistoryService.deleteEntry(history, context: context, index: index)
        XCTAssertEqual(index.removedIdentifiers, [identifier])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SearchHistoryItem>()).map(\.keyword), ["Kept query"])
        XCTAssertTrue(index.removedDomains.isEmpty)
    }

    func testBothHistoryClearEntrypointsRemoveSystemSearchDomainAndKeepBookmarks() throws {
        for throwingEntry in [true, false] {
            let container = try modelContainer()
            let context = container.mainContext
            context.insert(SearchHistoryItem(keyword: "Removed query"))
            context.insert(BookmarkItem(title: "Keep", urlString: "https://example.com"))
            try context.save()
            let index = AuditSearchableIndex(name: UUID().uuidString)
            if throwingEntry { try SearchHistoryService.clearAll(in: context, index: index) }
            else { SearchHistoryService.clearAll(context: context, index: index) }
            XCTAssertTrue(try context.fetch(FetchDescriptor<SearchHistoryItem>()).isEmpty)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkItem>()), 1)
            XCTAssertEqual(index.removedDomains, ["soulo.history"])
        }
    }

    func testBookmarkClearRemovesFoldersAndSystemIndexWithoutDeletingHistory() throws {
        let container = try modelContainer()
        let context = container.mainContext
        context.insert(BookmarkItem(title: "Remove", urlString: "https://example.com"))
        context.insert(BookmarkFolder(title: "Remove folder"))
        context.insert(SearchHistoryItem(keyword: "Keep query"))
        try context.save()
        let index = AuditSearchableIndex(name: UUID().uuidString)
        try BookmarkService.clearAll(in: context, index: index)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkFolder>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SearchHistoryItem>()), 1)
        XCTAssertEqual(index.removedDomains, ["soulo.bookmarks"])
    }

    func testHistoryRemovesCredentialsAndPreservesCaseAndEscapedBusinessQuery() throws {
        let input = try XCTUnwrap(URL(string: "https://reader:secret@EXAMPLE.com:8443/Case?q=C%2B%2B&token=a%2Fb%3D&%75tm_source=x#part"))
        let expected = "https://example.com:8443/Case?q=C%2B%2B&token=a%2Fb%3D"
        XCTAssertEqual(SearchHistoryService.canonicalHistoryURLString(for: input), expected)
        XCTAssertNotEqual(SearchHistoryService.canonicalHistoryURLString(for:
            try XCTUnwrap(URL(string: "https://example.com:8443/case?q=C%2B%2B&token=a%2Fb%3D"))), expected)
        let container = try modelContainer(), context = container.mainContext
        context.insert(SearchHistoryItem(keyword: "Legacy", visitedURLString: input.absoluteString))
        try context.save()
        SearchHistoryService.purgeExpiredBrowsingHistory(context: context)
        SearchHistoryService.recordWebVisit(url: input, title: "Updated", context: context)
        let history = try context.fetch(FetchDescriptor<SearchHistoryItem>())
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.visitedURLString, expected)
        XCTAssertEqual(history.first?.keyword, "Updated")
    }

    func testTrackingRemovalPreservesCredentialsFragmentAndEncodedBusinessValues() throws {
        let suite = "audit-url-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "privacy_strip_tracking_parameters")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        let input = try XCTUnwrap(URL(string: "https://reader:secret@privacy-audit.example:8443/Case?q=C%2B%2B&token=a%2Fb%3D&%75tm_source=x&gclid=y#part"))
        let service = PrivacyNavigationService(userDefaults: defaults)
        let transformed = try XCTUnwrap(service.transformedURL(for: input))
        XCTAssertEqual(transformed.absoluteString,
            "https://reader:secret@privacy-audit.example:8443/Case?q=C%2B%2B&token=a%2Fb%3D#part")
        XCTAssertEqual(service.strippedTrackingParameterCount(from: input, to: transformed), 2)
    }

    func testCloudSeedUsesActualOptInPrivacyDefaults() throws {
        let stock: CloudSettingsSyncEngine.Values = [
            "privacy_https_upgrade_enabled": PrivacyFeatureDefaults.httpsUpgradeEnabled,
            "privacy_strip_tracking_parameters": PrivacyFeatureDefaults.stripTrackingParameters,
            "privacy_gpc_enabled": PrivacyFeatureDefaults.gpcEnabled,
            "privacy_cookie_banner_enabled": PrivacyFeatureDefaults.cookieBannerHandling
        ]
        let date = Date(timeIntervalSince1970: 1_000_000)
        let fresh = try CloudSettingsSyncEngine.seed(stock, writerID: "fresh", date: date)
        XCTAssertTrue(fresh.records.isEmpty, "Stock opt-in values must not become cloud edits")
        var enabled = stock
        for (key, value) in stock { enabled[key] = !(try XCTUnwrap(value as? Bool)) }
        let customized = try CloudSettingsSyncEngine.seed(enabled, writerID: "custom", date: date)
        XCTAssertEqual(customized.records.keys.sorted(), stock.keys.map { "setting." + $0 }.sorted())
        let merged = try CloudSettingsSyncEngine.merged([customized, fresh], onto: stock)
        for key in stock.keys { XCTAssertEqual(merged[key] as? Bool, enabled[key] as? Bool) }
    }

    private func fixturePlatform(template: String) -> SearchPlatform {
        SearchPlatform(id: UUID(), name: "Fixture", iconName: "globe", searchURLTemplate: template,
            homeURL: "https://example.com", region: .international, isBuiltIn: false,
            isVisible: true, sortOrder: 0, usageCount: 0, isCustom: true)
    }

    private func modelContainer() throws -> ModelContainer {
        try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func withIsolatedPlatforms(_ action: (PlatformDataStore) throws -> Void) throws {
        let store = PlatformDataStore.shared
        let original = (store.platforms, store.customGroups, store.regionNameOverrides)
        let defaults = UserDefaults.standard
        let keys = ["platform_config", "platform_config_version", "custom_groups", "region_name_overrides", LiveActivityService.enabledKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            store.platforms = original.0; store.customGroups = original.1; store.regionNameOverrides = original.2
        }
        store.platforms = []; store.customGroups = []; store.regionNameOverrides = [:]
        defaults.set(false, forKey: LiveActivityService.enabledKey)
        try action(store)
    }
}

private final class AuditSearchableIndex: CSSearchableIndex {
    var removedIdentifiers: [String] = []
    var removedDomains: [String] = []

    override func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: ((Error?) -> Void)? = nil) {
        removedIdentifiers += identifiers
        completionHandler?(nil)
    }

    override func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String], completionHandler: ((Error?) -> Void)? = nil) {
        removedDomains += domainIdentifiers
        completionHandler?(nil)
    }
}

private final class AuditSuggestionProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var status = 200
    private static var urls: [URL] = []

    static func prepare(body: Data, status: Int = 200) {
        lock.withLock { self.body = body; self.status = status; urls = [] }
    }

    static func requests() -> [URL] { lock.withLock { urls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> (Data, Int) in
            if let url = request.url { Self.urls.append(url) }
            return (Self.body, Self.status)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.1, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
