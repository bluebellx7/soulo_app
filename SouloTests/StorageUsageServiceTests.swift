import XCTest
import WebKit
@testable import Soulo

final class StorageUsageServiceTests: XCTestCase {
    @MainActor func testRealWebsitesExposeIndexedDBBytesAndClearOnlyTheChosenSitesDatabase() async throws {
        let server=try DownloadPlaybackHTTPFixture(files:["/index.html":Data("<body id='ready'>Storage fixture</body>".utf8)])
        let base=try await server.start();server.releaseDownloads();defer{server.stop()}
        var localhost=URLComponents(url:base,resolvingAgainstBaseURL:false)!;localhost.host="localhost"
        let first=WKWebView(),second=WKWebView()
        defer{first.stopLoading();second.stopLoading()}
        first.load(URLRequest(url:base.appendingPathComponent("index.html")))
        second.load(URLRequest(url:try XCTUnwrap(localhost.url).appendingPathComponent("index.html")))
        let seed=#"""
        localStorage.setItem('storage-fixture','keep');document.cookie='storage_fixture=keep;path=/';
        await new Promise((resolve,reject)=>{const r=indexedDB.open('website-storage-fixture',1);
          r.onupgradeneeded=()=>r.result.createObjectStore('files');r.onerror=()=>reject(r.error);
          r.onsuccess=()=>{const db=r.result,t=db.transaction('files','readwrite');t.objectStore('files').put(new Blob(['m'.repeat(700000)]),'media');t.oncomplete=()=>{db.close();resolve();};};});
        return true;
        """#
        for web in [first,second] {
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true {break}
                try await Task.sleep(for:.milliseconds(30))
            }
            _ = try await web.callAsyncJavaScript(seed,arguments:[:],in:nil,contentWorld:.page)
        }
        let entries=await WebsiteStorageService.entries()
        let firstEntry=try XCTUnwrap(entries.first{$0.domain=="127.0.0.1"}),secondEntry=try XCTUnwrap(entries.first{$0.domain=="localhost"})
        XCTAssertGreaterThanOrEqual(firstEntry.indexedDBBytes ?? -1,700000)
        XCTAssertGreaterThanOrEqual(secondEntry.indexedDBBytes ?? -1,700000)
        try await WebsiteStorageService.clear(firstEntry,types:[WKWebsiteDataTypeIndexedDBDatabases])
        let check="return {names:(await indexedDB.databases()).map(v=>v.name),local:localStorage.getItem('storage-fixture'),cookie:document.cookie};"
        let cleared=try await first.callAsyncJavaScript(check,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        let kept=try await second.callAsyncJavaScript(check,arguments:[:],in:nil,contentWorld:.page) as? [String:Any]
        XCTAssertFalse((cleared?["names"] as? [String] ?? []).contains("website-storage-fixture"))
        XCTAssertTrue((kept?["names"] as? [String] ?? []).contains("website-storage-fixture"))
        XCTAssertEqual(cleared?["local"] as? String,"keep")
        XCTAssertTrue((cleared?["cookie"] as? String ?? "").contains("storage_fixture=keep"))
        for entry in [firstEntry,secondEntry] {try await WebsiteStorageService.clear(entry,types:WKWebsiteDataStore.allWebsiteDataTypes())}
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
        XCTAssertEqual(StorageUsageCategory.allCases.filter(\.canClear), [.webData, .tabSnapshots, .favicons, .wallpaperCache, .otherCaches, .temporaryFiles, .ruleCache, .downloadTasks])
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
        for category: StorageUsageCategory in [.extensions,.downloadTasks,.wallpaperCache,.otherCaches,.temporaryFiles,.personalData,.webData,.sharedData,.otherData] {
            XCTAssertGreaterThan(try XCTUnwrap(report.records.first { $0.category == category }).bytes, 0, category.rawValue)
        }
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
            try StorageUsageService.clearAdditionalCache(category, locations: locations, olderThan: cutoff)
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
