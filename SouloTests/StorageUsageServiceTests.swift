import XCTest
import UIKit
import WebKit
@testable import Soulo

final class StorageUsageServiceTests: XCTestCase {
    @MainActor func testWebsiteCleanupTimeoutReturnsWithoutUnlockingOrRepeatingTheNativeWork() async {
        let coordinator = WebsiteDataCleanupCoordinator()
        var resume: CheckedContinuation<Void, Never>?
        var calls = 0
        let report = await coordinator.clearAll(timeoutNanoseconds: 10_000_000) {
            calls += 1
            await withCheckedContinuation { resume = $0 }
            return .init()
        }
        XCTAssertNotNil(resume)
        XCTAssertTrue(report.retainedCategories.contains(.websiteStorage))
        XCTAssertFalse(report.failures.isEmpty, "A timeout must not be displayed as successful cleanup")
        let repeated = await coordinator.clearAll { calls += 1; return .init() }
        XCTAssertFalse(repeated.failures.isEmpty)
        XCTAssertEqual(calls, 1, "A pending WebKit callback must not allow another removal")
        let queued = Task { @MainActor in await coordinator.perform { calls += 10 } }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls, 1, "The native worker must keep ownership after the UI deadline")
        resume?.resume(); resume = nil
        await queued.value
        _ = await coordinator.clearAll { calls += 1; return .init() }
        XCTAssertEqual(calls, 12, "The real callback must release the lock for future cleanup")
    }

    @MainActor func testSiteCleanupTimeoutKeepsOtherScopesQueuedUntilWebKitFinishes() async {
        let coordinator = WebsiteDataCleanupCoordinator()
        let domain = "first.example"
        var finishNative: CheckedContinuation<Void, Never>?
        var order: [String] = []
        let timedOut = await coordinator.clearSite(domain: domain, types: [WKWebsiteDataTypeFetchCache],
                                                   timeoutNanoseconds: 30_000_000) {
            order.append("start")
            await withCheckedContinuation { finishNative = $0 }
            order.append("finish")
            return .init()
        }
        XCTAssertNotNil(finishNative)
        XCTAssertTrue(timedOut.retainedCategories.contains(.websiteStorage))
        XCTAssertFalse(timedOut.failures.isEmpty)

        let repeated = await coordinator.clearSite(domain: domain, types: [WKWebsiteDataTypeFetchCache]) {
            order.append("duplicate")
            return .init()
        }
        XCTAssertEqual(repeated.failures, timedOut.failures)
        let distinct = Task { @MainActor in
            await coordinator.clearSite(domain: domain, types: [WKWebsiteDataTypeIndexedDBDatabases]) {
                order.append("different types")
                return .init()
            }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(order, ["start"])
        finishNative?.resume()
        let report = await distinct.value
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(order, ["start", "finish", "different types"])
    }

    @MainActor func testWebsiteCleanupCoalescesRepeatedRequestsAndSerializesOtherMutations() async throws {
        let coordinator = WebsiteDataCleanupCoordinator()
        var calls = 0, ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
            }
        }
        defer { heartbeat.cancel() }
        let requests = (0..<32).map { _ in Task { @MainActor in
            await coordinator.clearAll {
                calls += 1
                try? await Task.sleep(for: .milliseconds(200))
                return StorageCleanupReport()
            }
        } }
        for request in requests { _ = await request.value }
        XCTAssertEqual(calls, 1, "Repeated taps must not launch concurrent WebKit clear operations")
        XCTAssertGreaterThan(ticks, 5, "Waiting on WebKit must leave the UI actor responsive")
        var order: [String] = []
        let first = Task { @MainActor in await coordinator.perform {
            order.append("begin"); try? await Task.sleep(for: .milliseconds(80)); order.append("end")
        } }
        while order.isEmpty { await Task.yield() }
        let second = Task { @MainActor in await coordinator.perform { order.append("next") } }
        await first.value; await second.value
        XCTAssertEqual(order, ["begin", "end", "next"])
        do { try await coordinator.perform { throw CocoaError(.fileReadUnknown) }; XCTFail("Expected fixture error") }
        catch { }
        _ = await coordinator.clearAll { calls += 1; return .init() }
        XCTAssertEqual(calls, 2, "A completed or failed operation must release its coordination state")
    }

    @MainActor func testSeedLargeWebsiteCacheForStorageCleanupAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_WEBSITE_LARGE_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in 512 MiB fixture in the disposable acceptance app")
        }
        executionTimeAllowance = 180
        let server = try DownloadPlaybackHTTPFixture(files: ["/index.html": Data("<body id='ready'>Large cache fixture</body>".utf8)])
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let web = WKWebView()
        defer { web.stopLoading() }
        web.load(URLRequest(url: base.appendingPathComponent("index.html")))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let count = try await web.callAsyncJavaScript(#"""
        const cache=await caches.open('soulo-large-storage-acceptance');
        const data=new Uint8Array(4*1024*1024);
        for(let i=0;i<data.length;i+=65536)crypto.getRandomValues(data.subarray(i,i+65536));
        for(let i=0;i<128;i++)await cache.put('/soulo-cache-fixture-'+i,new Response(data));
        localStorage.setItem('soulo-storage-acceptance','clear me');
        return (await cache.keys()).length;
        """#, arguments: [:], in: nil, contentWorld: .page) as? Int
        XCTAssertEqual(count, 128)
        let snapshot = try await WebsiteStorageService.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.totalBytes, 512 * 1024 * 1024)
        XCTAssertEqual(snapshot.entries.reduce(snapshot.unattributedBytes) { $0 + ($1.bytes?.total ?? 0) }, snapshot.totalBytes)
        let report = XCTAttachment(string: "total=\(snapshot.totalBytes);shared=\(snapshot.unattributedBytes);sites=\(snapshot.entries.map { ($0.domain,$0.bytes?.total) })")
        report.name = "large-website-cache-seeded"; report.lifetime = .keepAlways; add(report)
        // Deliberately keep this test-only store for the following real UI
        // clear action. No synthetic bytes are added to reported sizes.
    }

    @MainActor func testRealWebsitesExposeIndexedDBBytesAndClearOnlyTheChosenSitesDatabase() async throws {
        let server=try DownloadPlaybackHTTPFixture(files:["/index.html":Data("<body id='ready'>Storage fixture</body>".utf8)])
        let base=try await server.start();server.releaseDownloads();defer{server.stop()}
        var localhost=URLComponents(url:base,resolvingAgainstBaseURL:false)!;localhost.host="localhost"
        let first=WKWebView(),second=WKWebView()
        // Keep real origins attached, like browser tabs during cleanup. A
        // detached WebKit process can freeze while the simulator is idle.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let views = UIStackView(arrangedSubviews: [first, second])
        views.axis = .vertical
        views.distribution = .fillEqually
        views.frame = controller.view.bounds
        views.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(views)
        window.makeKeyAndVisible()
        defer {
            first.stopLoading(); second.stopLoading()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        first.load(URLRequest(url:base.appendingPathComponent("index.html")))
        second.load(URLRequest(url:try XCTUnwrap(localhost.url).appendingPathComponent("index.html")))
        let database = "website-storage-fixture-" + UUID().uuidString
        let seed=#"""
        localStorage.setItem('storage-fixture','keep');document.cookie='storage_fixture=keep;path=/';
        await new Promise((resolve,reject)=>{const r=indexedDB.open(database,1);
          r.onupgradeneeded=()=>r.result.createObjectStore('files');r.onerror=()=>reject(r.error);
          r.onblocked=()=>reject(new Error('IndexedDB open blocked'));
          r.onsuccess=()=>{const db=r.result,t=db.transaction('files','readwrite');
            t.onabort=()=>{db.close();reject(t.error||new Error('IndexedDB transaction aborted'));};
            t.oncomplete=()=>{db.close();resolve();};
            t.objectStore('files').put(new Blob(['m'.repeat(700000)]),'media');};});
        if (window.caches) { const c=await caches.open('storage-cache-fixture'); await c.put('/fixture-media',new Response('x'.repeat(100000))); }
        return true;
        """#
        func evaluate(_ script: String, in web: WKWebView, stage: String) async throws -> Any {
            let finished = expectation(description: stage)
            var result: Result<Any, Error>?
            web.callAsyncJavaScript(script, arguments: ["database": database], in: nil, in: .page) {
                result = $0
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 15)
            return try XCTUnwrap(result, stage).get()
        }
        for web in [first,second] {
            var ready = false
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true {
                    ready = true
                    break
                }
                try await Task.sleep(for:.milliseconds(30))
            }
            let host = web.url?.host ?? "unknown"
            guard ready else { XCTFail("Storage fixture did not load for \(host)"); return }
            _ = try await evaluate(seed, in: web, stage: "Write website data for \(host)")
        }
        print("Website storage regression: enumerate website records")
        let entries=try await WebsiteStorageService.entries()
        let firstEntry=try XCTUnwrap(entries.first{$0.domain=="127.0.0.1"}),secondEntry=try XCTUnwrap(entries.first{$0.domain=="localhost"})
        XCTAssertGreaterThanOrEqual(firstEntry.indexedDBBytes ?? -1,700000)
        XCTAssertGreaterThanOrEqual(secondEntry.indexedDBBytes ?? -1,700000)
        print("Website storage regression: clear only 127.0.0.1 IndexedDB")
        try await WebsiteStorageService.clear(firstEntry,types:[WKWebsiteDataTypeIndexedDBDatabases])
        let check="return {names:(await indexedDB.databases()).map(v=>v.name),local:localStorage.getItem('storage-fixture'),cookie:document.cookie};"
        let cleared = try await evaluate(check, in: first, stage: "Read selectively cleared origin") as? [String:Any]
        let kept = try await evaluate(check, in: second, stage: "Read the untouched origin") as? [String:Any]
        XCTAssertFalse((cleared?["names"] as? [String] ?? []).contains(database))
        XCTAssertTrue((kept?["names"] as? [String] ?? []).contains(database))
        XCTAssertEqual(cleared?["local"] as? String,"keep")
        XCTAssertTrue((cleared?["cookie"] as? String ?? "").contains("storage_fixture=keep"))
        try await WebsiteStorageService.clearCurrentSite(host: "127.0.0.1", in: first.configuration.websiteDataStore)
        let panelCleared = try await evaluate(check, in: first, stage: "Read the site after clearing through the site panel") as? [String: Any]
        let panelKept = try await evaluate(check, in: second, stage: "Verify the panel left the second site alone") as? [String: Any]
        XCTAssertTrue(panelCleared?["local"] is NSNull)
        XCTAssertFalse((panelCleared?["cookie"] as? String ?? "").contains("storage_fixture=keep"))
        XCTAssertEqual(panelKept?["local"] as? String, "keep")
        XCTAssertTrue((panelKept?["names"] as? [String] ?? []).contains(database))
        let report = await StorageUsageService.clearWebsiteData()
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        for web in [first, second] {
            let value = try await evaluate("return {names:(await indexedDB.databases()).map(v=>v.name),local:localStorage.getItem('storage-fixture'),cookie:document.cookie,caches:window.caches?await caches.keys():[]};", in: web, stage: "Verify full cleanup for \(web.url?.host ?? "unknown")") as? [String: Any]
            XCTAssertFalse((value?["names"] as? [String] ?? []).contains(database))
            XCTAssertTrue(value?["local"] is NSNull)
            XCTAssertFalse((value?["cookie"] as? String ?? "").contains("storage_fixture=keep"))
            XCTAssertFalse((value?["caches"] as? [String] ?? []).contains("storage-cache-fixture"))
        }
    }
    func testWebsiteDiskEstimatesAttributePartitionsKeepLegacySupportAndRejectUnknownMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        func origin(_ scheme:String,_ host:String)->Data {
            var data=Data()
            for value in [scheme,host] {
                var length=UInt32(value.utf8.count).littleEndian
                withUnsafeBytes(of:&length){data.append(contentsOf:$0)}
                data.append(1);data.append(Data(value.utf8))
            }
            data.append(0);return data
        }
        let directory=root.appendingPathComponent("WebsiteData/Default/top/client")
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("IndexedDB/database"),withIntermediateDirectories:true)
        try (origin("https","embedding.example")+origin("https","cdn.video.example")).write(to:directory.appendingPathComponent("origin"))
        try Data(repeating:1,count:120_000).write(to:directory.appendingPathComponent("IndexedDB/database/video.blob"))
        let legacy=root.appendingPathComponent("WebsiteData/IndexedDB/v1/https_legacy.example_0/database")
        try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true)
        try Data(repeating:2,count:60_000).write(to:legacy.appendingPathComponent("IndexedDB.sqlite3"))
        let measured=WebsiteStorageService.measure(root:root,domains:["embedding.example","video.example","legacy.example"])
        XCTAssertNil(measured["embedding.example"],"An embedded origin's media must not be charged to the top page")
        XCTAssertGreaterThanOrEqual(measured["video.example"]?.indexedDB ?? 0,120_000)
        XCTAssertGreaterThanOrEqual(measured["legacy.example"]?.indexedDB ?? 0,60_000)
        XCTAssertNil(WebsiteStorageService.decodeOrigin(Data([255,0,1])))
        var trailing=origin("https","one.example")+origin("https","two.example");trailing.append(0)
        XCTAssertNil(WebsiteStorageService.decodeOrigin(trailing),"Unknown formats must not create made-up origin mappings")
        let before=try Data(contentsOf:directory.appendingPathComponent("IndexedDB/database/video.blob"))
        XCTAssertEqual(before.count,120_000,"Usage collection never mutates website files")
    }
    private var root: URL!
    private var locations: StorageUsageLocations!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-usage-" + UUID().uuidString)
        locations = StorageUsageLocations(downloads: root.appendingPathComponent("Documents/Downloads"),
            applicationSupport: root.appendingPathComponent("ApplicationSupport"), caches: root.appendingPathComponent("Caches"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        locations = nil
    }

    @discardableResult
    private func write(_ name: String, under base: URL) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8192).write(to: url)
        return url
    }

    private func websiteOrigin(_ host: String, scheme: String = "https") -> Data {
        var origin = Data()
        for value in [scheme, host] {
            var length = UInt32(value.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { origin.append(contentsOf: $0) }
            origin.append(1); origin.append(Data(value.utf8))
        }
        origin.append(0)
        return origin + origin
    }

    private func allocatedWebsiteBytes(_ files: [URL]) throws -> Int64 {
        try files.reduce(Int64(0)) { sum, file in
            let values = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
            return sum + Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
    }

    func testWebsiteSnapshotKeepsGlobalCachesAndCookiesAsUnattributedBytes() throws {
        var places = try XCTUnwrap(locations)
        places.library = root.appendingPathComponent("Library")
        let webkit = places.library!.appendingPathComponent("WebKit")
        let site = webkit.appendingPathComponent("WebsiteData/Default/top/site")
        let origin = try write("origin", under: site)
        try websiteOrigin("video.example").write(to: origin)
        // Mirror a large video cache across the real directory shapes using
        // small allocated fixtures rather than writing hundreds of megabytes.
        let owned = try ["IndexedDB/video.blob", "CacheStorage/fragment", "NetworkCache/owned-response",
            "ServiceWorkers/script", "ApplicationCache/response", "LocalStorage/localstorage.sqlite3",
            "FileSystem/media", "BackgroundFetch/part", "SessionStorage/session", ".hidden-index"].map { try write($0, under: site) }
        let shared = try [
            write("NetworkCache/Blobs/shared-video", under: webkit),
            write("UnknownLayout/orphan.bin", under: webkit),
            write("Cookies/Cookies.binarycookies", under: places.library!),
            write("HTTPStorages/com.example.browser/httpstorages.sqlite", under: places.library!),
            write("WebKit/NetworkCache/Blobs/global-video", under: places.caches),
            write("com.example.browser/fsCachedData/url-response", under: places.caches)]
        try write("ContentRuleLists/compiled-rule", under: webkit)
        let measured = WebsiteStorageService.measure(root: webkit, domains: ["video.example"])
        let bytes = try XCTUnwrap(measured["video.example"])
        XCTAssertEqual(bytes.total, try allocatedWebsiteBytes(owned + [origin]))
        XCTAssertEqual(bytes.cache, try allocatedWebsiteBytes(Array(owned[1...4])))
        let inventory = StorageUsageService.measureInventory(locations: places)
        let total = inventory.records.filter { [.webData, .websiteStorage].contains($0.category) }.reduce(Int64(0)) { $0 + $1.bytes }
        let snapshot = WebsiteStorageSnapshot(entries: [.init(domain: "video.example", dataTypes: [], bytes: bytes)], totalBytes: total)
        XCTAssertEqual(snapshot.unattributedBytes, try allocatedWebsiteBytes(shared))
        XCTAssertEqual(snapshot.entries.reduce(Int64(0)) { $0 + ($1.bytes?.total ?? 0) } + snapshot.unattributedBytes, total)
        XCTAssertEqual(inventory.records.first { $0.category == .ruleCache }?.bytes, 8192)
    }

    func testWebsiteMeasurementUsesNearestNestedOriginWithoutCountingItTwice() throws {
        let webkit = root.appendingPathComponent("WebKit")
        let outer = webkit.appendingPathComponent("WebsiteData/Default/outer")
        let outerOrigin = try write("origin", under: outer)
        try websiteOrigin("parent.example").write(to: outerOrigin)
        let parentFile = try write("LocalStorage/parent.sqlite3", under: outer)
        let nested = outer.appendingPathComponent("Embedded/inner")
        let nestedOrigin = try write("origin", under: nested)
        try websiteOrigin("video.example").write(to: nestedOrigin)
        let video = try write("IndexedDB/video.blob", under: nested)
        let opaque = outer.appendingPathComponent("Embedded/unknown")
        let opaqueOrigin = try write("origin", under: opaque)
        try Data([255, 0, 1]).write(to: opaqueOrigin)
        try write("IndexedDB/foreign.blob", under: opaque)
        let outside = try write("external.bin", under: root)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("external-link"), withDestinationURL: outside)
        let measured = WebsiteStorageService.measure(root: webkit, domains: ["parent.example", "video.example"])
        XCTAssertEqual(measured["parent.example"]?.total, try allocatedWebsiteBytes([outerOrigin, parentFile]))
        XCTAssertEqual(measured["video.example"]?.total, try allocatedWebsiteBytes([nestedOrigin, video]))
        XCTAssertEqual(measured["parent.example"]?.indexedDB, 0, "A child site's video must not also be charged to the parent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testWebsiteMeasurementIncludesLegacyLocalStorageSidecarsAndHiddenBlobs() throws {
        let webkit = root.appendingPathComponent("WebKit")
        let local = try ["LocalStorage/https_legacy.example_0.localstorage",
            "LocalStorage/https_legacy.example_0.localstorage-wal", "LocalStorage/https_legacy.example_0.localstorage-shm"].map { try write($0, under: webkit) }
        let database = try write("IndexedDB/v1/https_legacy.example_0/database.sqlite3", under: webkit)
        let hidden = try write("IndexedDB/v1/https_legacy.example_0/.hidden/video.blob", under: webkit)
        let measured = try XCTUnwrap(WebsiteStorageService.measure(root: webkit, domains: ["legacy.example"])["legacy.example"])
        XCTAssertEqual(measured.localStorage, try allocatedWebsiteBytes(local))
        XCTAssertEqual(measured.indexedDB, try allocatedWebsiteBytes([database, hidden]))
    }

    func testWebsiteSnapshotKeepsUnknownAndConcurrentDeletionSizesHonest() {
        let unknown = WebsiteStorageEntry(domain: "cookies.example", dataTypes: [WKWebsiteDataTypeCookies], bytes: nil)
        let stable = WebsiteStorageSnapshot(entries: [unknown], totalBytes: 512)
        XCTAssertNil(stable.entries.first?.bytes)
        XCTAssertEqual(stable.unattributedBytes, 512)
        let stale = WebsiteStorageEntry(domain: "video.example", dataTypes: [WKWebsiteDataTypeIndexedDBDatabases], bytes: .init(indexedDB: 2048))
        let afterDeletion = WebsiteStorageSnapshot(entries: [stale, unknown], totalBytes: 256)
        XCTAssertTrue(afterDeletion.entries.allSatisfy { $0.bytes == nil })
        XCTAssertEqual(afterDeletion.entries.first?.dataTypes, stale.dataTypes)
        XCTAssertEqual(afterDeletion.totalBytes, 256)
        XCTAssertEqual(afterDeletion.unattributedBytes, 256)
    }

    func testPhysicalDevicePrivateVarAliasesKeepUserFilesOutOfOtherData() throws {
        let base = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/StorageFixture")
        let places = StorageUsageLocations(downloads: base.appendingPathComponent("Documents/Downloads"),
            applicationSupport: base.appendingPathComponent("Library/Application Support"), caches: base.appendingPathComponent("Library/Caches"),
            documents: base.appendingPathComponent("Documents"), library: base.appendingPathComponent("Library"), temporary: base.appendingPathComponent("tmp"))
        let classifier = StoragePathClassifier(locations: places)
        let fixtures: [(String, StorageUsageCategory)] = [
            ("Documents/Downloads/video.mp4", .downloads), ("Documents/Downloads/music.flac", .downloads),
            ("tmp/CFNetworkDownload_fixture.tmp", .temporaryFiles), ("tmp/000260.ts", .temporaryFiles),
            ("Library/WebKit/ContentRuleLists/ContentRuleListFixture", .ruleCache),
            ("Library/WebKit/WebsiteData/Default/site/LocalStorage/localstorage.sqlite3-wal", .websiteStorage),
            ("Library/Caches/CurrentWallpaper/fixture.image", .wallpaperCache)]
        for (suffix, category) in fixtures {
            let raw = base.appendingPathComponent(suffix).path
            let privatePath = "/private" + raw
            XCTAssertEqual(classifier.category(raw), category, suffix)
            XCTAssertEqual(classifier.category(privatePath), category, suffix)
            XCTAssertEqual(classifier.normalizedPath(raw), classifier.normalizedPath(privatePath))
            XCTAssertTrue(classifier.bucket(privatePath).1.contains("/"), "Paths must show their real category folder, not just a bare filename")
        }
    }

    func testAliasedSandboxRootsCountEachFileOnceAndCanClearTheRightCache() throws {
        let real = root.appendingPathComponent("actual"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let places = StorageUsageLocations(downloads: alias.appendingPathComponent("Documents/Downloads"),
            applicationSupport: alias.appendingPathComponent("Library/Application Support"), caches: alias.appendingPathComponent("Library/Caches"),
            documents: real.appendingPathComponent("Documents"), library: real.appendingPathComponent("Library"), temporary: real.appendingPathComponent("tmp"))
        let download = try write("video.mp4", under: places.downloads)
        try write("ContentRuleLists/ContentRuleListFixture", under: places.library!.appendingPathComponent("WebKit"))
        try write("000260.ts", under: places.temporary!)
        try write("fixture.cache", under: places.caches.appendingPathComponent("misc"))
        let report = StorageUsageService.measureInventory(locations: places)
        for category: StorageUsageCategory in [.downloads, .ruleCache, .temporaryFiles, .otherCaches] {
            XCTAssertGreaterThan(report.records.first { $0.category == category }?.bytes ?? 0, 0, category.rawValue)
        }
        XCTAssertEqual(report.records.first { $0.category == .otherData }?.bytes, 0)
        XCTAssertEqual(report.entries.reduce(0) { $0 + $1.bytes }, report.dataBytes)
        try StorageUsageService.clearAdditionalCache(.otherCaches, locations: places, olderThan: .distantFuture)
        let cleared = StorageUsageService.measureInventory(locations: places)
        XCTAssertEqual(cleared.records.first { $0.category == .otherCaches }?.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path), "Fixing cache cleanup must never delete a downloaded video")
    }

    @MainActor func testStorageGroupsPartitionAllDataAndKeepWebsiteDeletionOptIn() {
        let categories = StorageUsageGroup.allCases.flatMap { $0.categories }
        XCTAssertEqual(Set(categories), Set(StorageUsageCategory.allCases))
        XCTAssertEqual(categories.count, StorageUsageCategory.allCases.count)
        XCTAssertEqual(StorageUsageGroup.allCases.count, 5)
        XCTAssertEqual(StorageUsageGroup.websites.cleanupChoices, [.websiteData])
        XCTAssertFalse(StorageCleanupChoice.safeDefaults.contains(.websiteData))
        XCTAssertEqual(StorageUsageGroup.other.cleanupChoices, [.systemCaches, .offlineMedia])
        XCTAssertTrue(StorageCleanupChoice.safeDefaults.contains(.systemCaches))
        XCTAssertFalse(StorageCleanupChoice.safeDefaults.contains(.offlineMedia))
        XCTAssertFalse(StorageCleanupChoice.offlineMedia.requiresTypedConfirmation)
        XCTAssertTrue(StorageCleanupChoice.bookmarks.requiresTypedConfirmation)
        XCTAssertTrue(StorageCleanupChoice.saved.contains(.offlineMedia))
        XCTAssertEqual(Set(StorageCleanupChoice.saved.map(\.title)).count, StorageCleanupChoice.saved.count,
                       "Wallpaper favorites and bookmarks must have distinct cleanup labels")
    }

    func testDiskCategoriesIncludeReadingListAndKeepUserDataReadOnly() throws {
        try write("movie.mp4", under: locations.downloads)
        try write("SouloTabSnapshots/page.jpg", under: locations.applicationSupport)
        try write("wallpaper_hd/nature.jpg", under: locations.caches)
        try write("ReadingList.json", under: locations.applicationSupport)
        try write("Soulo/SettingsBackups/saved.json", under: locations.applicationSupport)
        try write("AdBlock/subscription-rules.json", under: locations.applicationSupport)
        let records = StorageUsageService.measureDiskUsage(locations: locations)
        for category: StorageUsageCategory in [.downloads, .tabSnapshots, .wallpapers, .readingData, .backups, .filterRules] {
            let record = try XCTUnwrap(records.first { $0.category == category })
            XCTAssertGreaterThan(record.bytes, 0, category.rawValue)
            XCTAssertFalse(record.isEstimated)
        }
        XCTAssertEqual(StorageUsageCategory.allCases.filter(\.canClear), [.webData, .tabSnapshots, .favicons, .wallpaperCache,
            .videoPlaybackCache, .otherCaches, .temporaryFiles, .ruleCache, .downloadTasks])
        for category: StorageUsageCategory in [.wallpapers, .downloads, .readingData, .backups, .filterRules] {
            XCTAssertThrowsError(try StorageUsageService.clearDiskCache(category, locations: locations))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.downloads.appendingPathComponent("movie.mp4").path))
    }

    func testInventoryAccountsForEverySandboxFileOnceAndSeparatesInstalledProgram() throws {
        var locations = try XCTUnwrap(self.locations)
        locations.documents = root.appendingPathComponent("Documents")
        locations.library = root.appendingPathComponent("Library")
        locations.temporary = root.appendingPathComponent("Temporary")
        locations.sharedContainer = root.appendingPathComponent("Shared")
        locations.appBundle = root.appendingPathComponent("Soulo.app")
        let saved = try [write("movie.mp4", under: locations.downloads),
            write("SouloExtensions/WebExtensions/original/manifest.json", under: locations.applicationSupport),
            write("DownloadResumeData/resume.bin", under: locations.applicationSupport),
            write("CurrentWallpaper/image.jpg", under: locations.caches),
            write("WallpaperSourcePreviews/bing.jpg", under: locations.caches),
            write("misc/image.bin", under: locations.caches),
            write("com.example.app/WebKit/NetworkCache/cache.bin", under: locations.caches),
            write("custom_wallpaper_light.image", under: locations.documents!),
            write("export.txt", under: locations.documents!),
            write("temporary.bin", under: locations.temporary!),
            write("Preferences/settings.plist", under: locations.library!),
            write("WebKit/WebsiteData/origin/IndexedDB/database.sqlite3", under: locations.library!),
            write("widget.json", under: locations.sharedContainer!),
            write("unclassified.bin", under: locations.applicationSupport)]
        let installed = try write("program", under: locations.appBundle!)
        let outside = try write("must-not-count.bin", under: root.appendingPathComponent("Outside"))
        try FileManager.default.createSymbolicLink(at: locations.documents!.appendingPathComponent("external-link"), withDestinationURL: outside)
        let report = StorageUsageService.measureInventory(locations: locations)
        func bytes(_ url: URL) throws -> Int64 {
            let info = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey,.fileAllocatedSizeKey,.fileSizeKey])
            return Int64(info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0)
        }
        XCTAssertEqual(report.dataBytes, try saved.reduce(0) { try $0 + bytes($1) }, "Nested roots must not double count; unclassified files must not be omitted")
        XCTAssertEqual(report.appBytes, try bytes(installed))
        XCTAssertEqual(report.entries.reduce(0) { $0 + $1.bytes }, report.dataBytes)
        XCTAssertNotNil(report.entries.first { $0.category == .webData && $0.displayPath == "Caches/com.example.app" },
            "WebKit's bundle-nested cache must be assigned to website data, not generic caches")
        for category: StorageUsageCategory in [.extensions,.downloadTasks,.wallpaperCache,.otherCaches,.temporaryFiles,.personalData,.webData,.websiteStorage,.sharedData,.otherData] {
            XCTAssertGreaterThan(try XCTUnwrap(report.records.first { $0.category == category }).bytes, 0, category.rawValue)
        }
    }

    func testWebsiteCacheAndSavedWebsiteDataHaveDifferentCleanupScopes() throws {
        var places = try XCTUnwrap(locations)
        places.library = root.appendingPathComponent("Library")
        let db = try write("WebKit/WebsiteData/Default/top/origin/IndexedDB/database.sqlite3", under: places.library!)
        let cache = try write("WebKit/WebsiteData/Default/top/origin/CacheStorage/media.bin", under: places.library!)
        let liveCatalog = try write("com.example.app/Cache.db", under: places.caches)
        let disposable = try write("previews/image.bin", under: places.caches)
        let before = StorageUsageService.measureInventory(locations: places)
        XCTAssertEqual(before.entries.first { $0.category == .websiteStorage }?.bytes, 8192)
        XCTAssertGreaterThan(before.records.first { $0.category == .webData }?.bytes ?? 0, 0)
        XCTAssertFalse(StorageUsageCategory.websiteStorage.canClear, "Saved IndexedDB data requires its own explicit deletion")
        XCTAssertTrue(before.entries.contains { $0.category == .otherData && $0.url.lastPathComponent == "com.example.app" })
        try StorageUsageService.clearAdditionalCache(.otherCaches, locations: places, olderThan: .distantFuture)
        let after = StorageUsageService.measureInventory(locations: places)
        XCTAssertLessThan(after.dataBytes, before.dataBytes)
        XCTAssertEqual(after.records.first { $0.category == .otherCaches }?.bytes, 0)
        for file in [db, cache, liveCatalog] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.path))
    }

    func testAllActiveTemporaryFilesAreReportedAndKept() throws {
        var places = try XCTUnwrap(locations)
        places.temporary = root.appendingPathComponent("Temporary")
        let active = try write("active.tmp", under: places.temporary!)
        let report = try StorageUsageService.clearAdditionalCache(.temporaryFiles, locations: places, olderThan: Date(timeIntervalSinceNow: -30))
        XCTAssertEqual(report.retainedCategories, [.temporaryFiles])
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    }

    @MainActor func testInventoryCacheCoalescesReadsAndRefreshesAfterDeletion() async throws {
        let file = try write("movie.mp4", under: locations.downloads)
        let places = try XCTUnwrap(locations)
        let cache = StorageInventoryCache { knownAppBytes in
            StorageUsageService.measureInventory(locations: places, knownAppBytes: knownAppBytes)
        }
        async let first = cache.inventory(forceRefresh: true)
        async let second = cache.inventory(forceRefresh: true)
        let (a, b) = await (first, second)
        XCTAssertEqual(a.dataBytes, b.dataBytes)
        XCTAssertGreaterThan(a.dataBytes, 0)
        try FileManager.default.removeItem(at: file)
        // This is the same forced refresh used by onAppear after returning
        // from file management, even while a recent inventory is cached.
        let refreshed = await cache.inventory(forceRefresh: true)
        XCTAssertEqual(refreshed.records.first { $0.category == .downloads }?.bytes, 0)
        cache.invalidate()
        XCTAssertNil(cache.value)
    }

    @MainActor func testDeletionInvalidatesAScanAlreadyInFlight() async throws {
        let file = try write("movie.mp4", under: locations.downloads)
        let places = try XCTUnwrap(locations), gate = StorageScanGate()
        let cache = StorageInventoryCache { knownAppBytes in
            let first = gate.isFirst()
            let value = StorageUsageService.measureInventory(locations: places, knownAppBytes: knownAppBytes)
            if first { gate.started.signal(); _ = gate.resume.wait(timeout: .now() + 2) }
            return value
        }
        let old = Task { await cache.inventory(forceRefresh: true) }
        await Task.detached { _ = gate.started.wait(timeout: .now() + 2) }.value
        try FileManager.default.removeItem(at: file)
        cache.invalidate()
        let fresh = await cache.inventory(forceRefresh: true)
        gate.resume.signal()
        let staleReader = await old.value
        XCTAssertEqual(fresh.dataBytes, 0)
        XCTAssertEqual(staleReader.dataBytes, 0, "An older scan must not restore the size of a deleted file")
        XCTAssertEqual(cache.value?.dataBytes, 0)
        XCTAssertEqual(gate.count, 2)
    }

    func testInventoryScansLargeExtensionTreesAndPreservesCategoryTotals() throws {
        for index in 0..<2500 {
            try write("SouloExtensions/extension/scripts/dir\(index / 25)/file\(index).js", under: locations.applicationSupport)
        }
        let start = Date()
        let report = StorageUsageService.measureInventory(locations: locations)
        print("STORAGE_SCAN files=2500 elapsed=\(Date().timeIntervalSince(start))")
        XCTAssertGreaterThan(report.records.first { $0.category == .extensions }?.bytes ?? 0, 0)
        XCTAssertEqual(report.entries.reduce(0) { $0 + $1.bytes }, report.dataBytes)
    }

    func testNewCacheCleanupKeepsFavoritesDownloadsActiveFilesAndExternalSymlinks() throws {
        var locations = try XCTUnwrap(self.locations)
        locations.temporary = root.appendingPathComponent("Temporary")
        let disposable = try write("misc/old.cache", under: locations.caches)
        let preview = try write("WallpaperSourcePreviews/bing.jpg", under: locations.caches)
        let current = try write("CurrentWallpaper/current.jpg", under: locations.caches)
        let retained = try [write("wallpaper_hd/favorite.jpg", under: locations.caches),
            write("BackgroundDownloadStaging/active.download", under: locations.caches),
            write("WebKit/cache.db", under: locations.caches),
            write("com.example.app/Cache.db", under: locations.caches),
            write("movie.mp4", under: locations.downloads),
            write("active.tmp", under: locations.temporary!)]
        let stale = try write("stale.tmp", under: locations.temporary!)
        let cutoff = Date(timeIntervalSinceNow: -30)
        try FileManager.default.setAttributes([.modificationDate: cutoff.addingTimeInterval(-30)], ofItemAtPath: stale.path)
        let outside = try write("keep.bin", under: root.appendingPathComponent("Outside"))
        try FileManager.default.createSymbolicLink(at: locations.caches.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent())
        for category: StorageUsageCategory in [.otherCaches,.wallpaperCache,.temporaryFiles] {
            let report = try StorageUsageService.clearAdditionalCache(category, locations: locations, olderThan: cutoff)
            if category == .temporaryFiles { XCTAssertEqual(report.retainedCategories, [.temporaryFiles]) }
        }
        for url in [disposable, preview, current, stale] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        for url in retained + [outside] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path) }
    }

    func testOrphanDownloadCleanupKeepsPausedJobsLedgersAndRecentFiles() throws {
        let retained=UUID(),orphan=UUID(),recent=UUID()
        let paused=try write("DownloadResumeData/\(retained).resume",under:locations.applicationSupport)
        let stale=try write("DownloadResumeData/\(orphan).resume",under:locations.applicationSupport)
        let live=try write("BackgroundDownloadStaging/\(recent).download",under:locations.caches)
        let ledger=try write("TorrentTasks/tasks.json",under:locations.applicationSupport)
        let saved=try write("movie.mp4",under:locations.downloads)
        let cutoff=Date(timeIntervalSinceNow:-10)
        for file in [paused,stale,ledger] {try FileManager.default.setAttributes([.modificationDate:cutoff.addingTimeInterval(-10)],ofItemAtPath:file.path)}
        try StorageUsageService.clearUnusedDownloadData(locations:locations,retainedIDs:[retained],olderThan:cutoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath:stale.path))
        for file in [paused,live,ledger,saved] {XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))}
    }

    @MainActor func testCompiledRuleCleanupRemovesOnlySouloListsAndKeepsLoadedRules() async throws {
        let directory=root.appendingPathComponent("RuleStore")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let store=try XCTUnwrap(WKContentRuleListStore(url:directory))
        let own="SouloAdBlockV6-"+UUID().uuidString,foreign="ThirdParty-"+UUID().uuidString
        let json="[{\"trigger\":{\"url-filter\":\"blocked\"},\"action\":{\"type\":\"block\"}}]"
        func compile(_ id:String) async throws -> WKContentRuleList {
            try await withCheckedThrowingContinuation { continuation in
                store.compileContentRuleList(forIdentifier:id,encodedContentRuleList:json) { list,error in
                    if let list {continuation.resume(returning:list)}else{continuation.resume(throwing:error ?? URLError(.unknown))}
                }
            }
        }
        let active=try await compile(own);_ = try await compile(foreign)
        let config=WKWebViewConfiguration();config.userContentController.add(active)
        let web=WKWebView(frame:.zero,configuration:config)
        try await StorageUsageService.clearCompiledRuleCache(in:store)
        func lookup(_ id:String) async -> WKContentRuleList? {
            await withCheckedContinuation { continuation in store.lookUpContentRuleList(forIdentifier:id) {list,_ in continuation.resume(returning:list)} }
        }
        let removed=await lookup(own),kept=await lookup(foreign)
        XCTAssertNil(removed);XCTAssertNotNil(kept);XCTAssertEqual(active.identifier,own)
        let server=try DownloadPlaybackHTTPFixture(files:["/index.html":Data("<img src='/blocked.jpg' onerror='window.done=true'>".utf8),"/blocked.jpg":Data([0])])
        let base=try await server.start();server.releaseDownloads();defer{server.stop();web.stopLoading()}
        web.load(URLRequest(url:base.appendingPathComponent("index.html")))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.done===true")) as? Bool == true {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        XCTAssertTrue(server.receivedRequests.contains{$0.path=="/index.html"})
        XCTAssertFalse(server.receivedRequests.contains{$0.path=="/blocked.jpg"},"An already loaded blocker remains active after its disk cache is removed")
    }

    func testClearingNamedCachesPreservesCurrentWallpaperAndAllSavedContent() throws {
        let hd = try write("wallpaper_hd/nature.jpg", under: locations.caches)
        let favorite = try write("WallpaperFavorites/other.jpg", under: locations.applicationSupport)
        let snapshot = try write("SouloTabSnapshots/page.jpg", under: locations.applicationSupport)
        let legacySnapshot = try write("SouloTabSnapshots/old.jpg", under: locations.caches)
        let retained = try [write("CurrentWallpaper/selected.jpg", under: locations.caches),
            write("custom_wallpaper.jpg", under: root.appendingPathComponent("Documents")),
            write("keep.mp3", under: locations.downloads),
            write("ReadingList.json", under: locations.applicationSupport),
            write("BookCovers/cover.jpg", under: locations.applicationSupport),
            write("Soulo/SettingsBackups/keep.json", under: locations.applicationSupport),
            write("AdBlock/merged-rules.json", under: locations.applicationSupport)]
        XCTAssertThrowsError(try StorageUsageService.clearDiskCache(.wallpapers, locations: locations))
        XCTAssertEqual(try Data(contentsOf: hd), Data(repeating: 0xAB, count: 8192))
        XCTAssertEqual(try Data(contentsOf: favorite), Data(repeating: 0xAB, count: 8192))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        try StorageUsageService.clearDiskCache(.tabSnapshots, locations: locations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySnapshot.path))
        for url in retained { XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 0xAB, count: 8192), url.path) }
    }

    func testFavoriteWallpaperMigrationDoesNotCountTheSameOriginalTwice() throws {
        let original = try write("wallpaper_hd/nature.jpg", under: locations.caches)
        let before = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .wallpapers })
        let saved = locations.applicationSupport.appendingPathComponent("WallpaperFavorites/nature.jpg")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: saved)
        let after = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .wallpapers })
        XCTAssertEqual(after.bytes, before.bytes)
        XCTAssertFalse(after.canClear)
    }

    func testMeasurementAndClearDoNotFollowCacheRootSymlinks() throws {
        let external = root.appendingPathComponent("external")
        let retained = try write("keep.jpg", under: external)
        try FileManager.default.createDirectory(at: locations.caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: locations.caches.appendingPathComponent("wallpaper_hd"), withDestinationURL: external)
        let record = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .wallpapers })
        XCTAssertEqual(record.bytes, 0)
        XCTAssertThrowsError(try StorageUsageService.clearDiskCache(.wallpapers, locations: locations))
        XCTAssertEqual(try Data(contentsOf: retained), Data(repeating: 0xAB, count: 8192))
    }

    func testReleasedTemporaryCleanupKeepsOpenFilesNewWritesAndExtensionState() throws {
        var places = try XCTUnwrap(locations)
        places.temporary = root.appendingPathComponent("Temporary")
        let temporary = try XCTUnwrap(places.temporary)
        let closed = try write("closed.tmp", under: temporary)
        let open = try write("playing.tmp", under: temporary)
        let fresh = try write("new-write.tmp", under: temporary)
        let extensionState = try write("storage.sqlite", under: temporary.appendingPathComponent("extension-script-host-fixture"))
        let systemCache = try write("Cache.db", under: temporary.appendingPathComponent("WebKit"))
        let saved = try write("saved.mp4", under: places.downloads)
        let link = temporary.appendingPathComponent("linked-download")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: saved)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fresh.path)
        let handle = try FileHandle(forReadingFrom: open)
        defer { try? handle.close() }
        let protected = StorageMediaCleanup.openFilePaths()
        XCTAssertTrue(protected.contains(open.standardizedFileURL.resolvingSymlinksInPath().path))
        let report = try StorageMediaCleanup.removeReleasedFiles(at: temporary, category: .temporaryFiles,
            locations: places, protectedPaths: protected, olderThan: Date(), removeRoot: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: closed.path))
        for file in [open, fresh, extensionState, systemCache, saved, link] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent) }
        XCTAssertTrue(report.retainedCategories.contains(.temporaryFiles))
        try handle.close()
        _ = try StorageMediaCleanup.removeReleasedFiles(at: temporary, category: .temporaryFiles,
            locations: places, protectedPaths: StorageMediaCleanup.openFilePaths(), olderThan: Date(), removeRoot: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: open.path), "A released handle must become reclaimable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testManagedMediaDeletionRejectsOtherLibraryFoldersAndClearsReleasedFiles() throws {
        var places = try XCTUnwrap(locations)
        places.library = root.appendingPathComponent("Library")
        let library = try XCTUnwrap(places.library)
        let managed = library.appendingPathComponent("com.apple.UserManagedAssets.fixture")
        let media = try write("movie.movpkg/segment.ts", under: managed)
        let unowned = try write("keep.db", under: library.appendingPathComponent("OtherSystemData"))
        let handle = try FileHandle(forReadingFrom: media)
        let first = try StorageMediaCleanup.removeReleasedFiles(at: managed, category: .otherData,
            locations: places, protectedPaths: StorageMediaCleanup.openFilePaths(), olderThan: Date(), removeRoot: true)
        XCTAssertTrue(first.retainedCategories.contains(.otherData)); XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        try handle.close()
        _ = try StorageMediaCleanup.removeReleasedFiles(at: managed, category: .otherData,
            locations: places, protectedPaths: StorageMediaCleanup.openFilePaths(), olderThan: Date(), removeRoot: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unowned.path))
        XCTAssertThrowsError(try StorageMediaCleanup.removeReleasedFiles(at: unowned.deletingLastPathComponent(), category: .otherData,
            locations: places, protectedPaths: [], olderThan: Date(), removeRoot: true))
        let alias = library.appendingPathComponent("com.apple.UserManagedAssets.link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unowned.deletingLastPathComponent())
        XCTAssertFalse(StorageMediaCleanup.isManagedContainer(alias, locations: places))
    }

    func testManagedMediaCleanupRemovesOnlyReferencesWhosePackagesWereDeleted() throws {
        var places = try XCTUnwrap(locations)
        places.library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        places.documents = root.appendingPathComponent("Documents")
        let managed = places.library!.appendingPathComponent("com.apple.UserManagedAssets.test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managed) }
        let first = managed.appendingPathComponent("released.movpkg"), second = managed.appendingPathComponent("playing.movpkg")
        try write("segment.ts", under: first)
        let openFile = try write("segment.ts", under: second)
        let unopenedSegment = try write("next-segment.ts", under: second)
        let docs = try XCTUnwrap(places.documents)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let firstRef = docs.appendingPathComponent("released.soulohls"), secondRef = docs.appendingPathComponent("playing.soulohls")
        try OfflineHLSReference.write(packageURL: first, to: firstRef)
        try OfflineHLSReference.write(packageURL: second, to: secondRef)
        let handle = try FileHandle(forReadingFrom: openFile); defer { try? handle.close() }
        let result = try StorageMediaCleanup.removeFilesAndReferences(at: managed, category: .otherData, locations: places,
            protectedPaths: StorageMediaCleanup.openFilePaths(), olderThan: Date(), removeRoot: true)
        XCTAssertEqual(result.1.map(\.lastPathComponent), [firstRef.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRef.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRef.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: openFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unopenedSegment.path), "An in-use HLS package must remain intact")
    }

    func testOtherCleanupRemovesRebuildableCachesButKeepsDatabasesCloudTokensAndOpenFiles() throws {
        var places = try XCTUnwrap(locations)
        places.library = root.appendingPathComponent("Library")
        let system = places.caches.appendingPathComponent("com.example.app")
        let released = try write("com.apple.metal/libraries.data", under: system)
        let opened = try write("com.apple.metal/functions.data", under: system)
        let db = try write("Cache.db", under: system)
        let wal = try write("Cache.db-wal", under: system)
        let cloud = try write("SyncedPreferences/token", under: places.library!)
        let saved = try write("settings.json", under: places.applicationSupport)
        let splash = try write("Snapshots/scene.png", under: places.library!.appendingPathComponent("SplashBoard"))
        let future = try write("future.data", under: system)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: future.path)
        let outside = try write("external.data", under: root)
        try FileManager.default.createSymbolicLink(at: system.appendingPathComponent("link"), withDestinationURL: outside)
        let handle = try FileHandle(forReadingFrom: opened); defer { try? handle.close() }
        let report = try StorageOtherCleanup.removeCacheFiles(at: system, locations: places,
            protectedPaths: StorageMediaCleanup.openFilePaths(), olderThan: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: released.path))
        for file in [opened, db, wal, cloud, saved, outside, future] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertEqual(report.retainedCategories, [.otherData])
        _ = try StorageOtherCleanup.removeCacheFiles(at: splash.deletingLastPathComponent().deletingLastPathComponent(),
            locations: places, protectedPaths: [], olderThan: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: splash.path))
        XCTAssertEqual(StoragePathClassifier(locations: places).category(cloud.path), .personalData)
        XCTAssertFalse(StorageOtherCleanup.canClearCache(cloud.deletingLastPathComponent(), locations: places))
        XCTAssertThrowsError(try StorageOtherCleanup.removeCacheFiles(at: places.applicationSupport, locations: places,
            protectedPaths: [], olderThan: Date()))
    }

    func testOtherMediaCleanupKeepsSavedPackagesAndDoesNotDoubleCountThem() throws {
        var places = try XCTUnwrap(locations)
        places.library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        places.documents = root.appendingPathComponent("Documents")
        let managed = places.library!.appendingPathComponent("com.apple.UserManagedAssets.saved-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: managed) }
        let saved = managed.appendingPathComponent("saved.movpkg"), orphan = managed.appendingPathComponent("orphan.movpkg")
        let savedData = try write("segment.frag", under: saved), orphanData = try write("segment.frag", under: orphan)
        let reference = places.downloads.appendingPathComponent("saved.soulohls")
        try FileManager.default.createDirectory(at: places.downloads, withIntermediateDirectories: true)
        try OfflineHLSReference.write(packageURL: saved, to: reference)
        let preserved = Set(StorageMediaCleanup.references(in: places.documents, under: managed).map { $0.1.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/var/", with: "/var/") })
        let result = try StorageMediaCleanup.removeFilesAndReferences(at: managed, category: .otherData, locations: places,
            protectedPaths: [], olderThan: Date(), removeRoot: true, preservedPackages: preserved)
        XCTAssertTrue(result.0.retainedCategories.isEmpty)
        XCTAssertTrue(result.1.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedData.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanData.path))
        var measured = places
        measured.library = managed // Scan only this fixture, not the test host's live Library.
        let inventory = StorageUsageService.measureInventory(locations: measured)
        XCTAssertEqual(inventory.records.first { $0.category == .otherData }?.bytes, 0)
        XCTAssertGreaterThan(inventory.records.first { $0.category == .downloads }?.bytes ?? 0, 0)
        XCTAssertEqual(inventory.entries.reduce(0) { $0 + $1.bytes }, inventory.dataBytes)
    }

    func testOfflineHLSReferencesIncludeThePackageOnlyOnce() throws {
        let packageRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/StorageHLS-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        let package = packageRoot.appendingPathComponent("movie.movpkg")
        try write("segment.ts", under: package)
        try FileManager.default.createDirectory(at: locations.downloads, withIntermediateDirectories: true)
        let first = locations.downloads.appendingPathComponent("one.soulohls")
        try OfflineHLSReference.write(packageURL: package, to: first)
        let before = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .downloads }).bytes
        let second = locations.downloads.appendingPathComponent("two.soulohls")
        try OfflineHLSReference.write(packageURL: package, to: second)
        let after = try XCTUnwrap(StorageUsageService.measureDiskUsage(locations: locations).first { $0.category == .downloads }).bytes
        let size = try second.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        XCTAssertGreaterThan(before, 8192)
        XCTAssertEqual(after - before, Int64(size.totalFileAllocatedSize ?? size.fileAllocatedSize ?? size.fileSize ?? 0))
    }
}

private final class StorageScanGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func isFirst() -> Bool { lock.lock(); defer { lock.unlock() }; calls += 1; return calls == 1 }
}
