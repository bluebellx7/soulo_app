import XCTest
import JavaScriptCore
import WebKit
@testable import Soulo

final class WebViewScriptsTests: XCTestCase {
    @MainActor
    func testEditingScriptCannotWidenAnEmptyScopeOrLoseExistingPreferences() throws {
        let service = BrowserExtensionService.shared
        let id = UUID()
        let first = try service.saveUserScript(id: id, fallbackName: id.uuidString,
            source: "console.log('original');", explicitPatterns: ["https://example.com/*"], injectionTime: .documentEnd)
        defer { service.deleteUserScript(first.id) }
        service.setUserScriptEnabled(first.id, enabled: false)
        try service.setStoredValues(["theme": #"{"value":"dark"}"#], scriptID: first.id)

        XCTAssertThrowsError(try service.saveUserScript(id: first.id, fallbackName: first.name,
            source: "console.log('edited');", explicitPatterns: ["  ", "\n"], injectionTime: .documentStart))
        XCTAssertEqual(service.userScript(id: first.id)?.source, first.source)
        XCTAssertEqual(service.userScript(id: first.id)?.matchPatterns, ["https://example.com/*"])

        let updated = try service.saveUserScript(id: first.id, fallbackName: first.name,
            source: "console.log('edited');", explicitPatterns: ["https://example.com/*"], injectionTime: .documentStart)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.storedValues?["theme"], #"{"value":"dark"}"#)
        XCTAssertEqual(updated.injectionTime, .documentStart)
    }

    @MainActor
    func testEditorEnforcesTheSameScriptSizeLimitAsImport() {
        let service = BrowserExtensionService.shared
        let before = service.userScripts
        // Multibyte input verifies the byte limit, not merely character count.
        let source = String(repeating: "字", count: BrowserExtensionService.maximumUserScriptSize / 3 + 1)
        XCTAssertThrowsError(try service.saveUserScript(id: UUID(), fallbackName: "Large script",
            source: source, explicitPatterns: ["https://example.com/*"], injectionTime: .documentEnd)) { error in
            guard case BrowserExtensionError.scriptTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(service.userScripts, before)
    }

    @MainActor
    func testNativeWebExtensionHostImplementsEveryWebKitInterface() throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("Native WebExtensions require iOS 18.4 or newer")
        }
        let coverage = NativeWebExtensionRuntime.shared.hostInterfaceCoverage()
        XCTAssertTrue(
            coverage.isComplete,
            "Missing controller: \(coverage.missingControllerSelectors); "
                + "window: \(coverage.missingWindowSelectors); "
                + "tab: \(coverage.missingTabSelectors)"
        )
    }

    @MainActor
    func testWebKitKeepsExtensionUsableWhenOneWebAccessibleResourceEntryIsInvalid() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("Native WebExtensions require iOS 18.4 or newer")
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloInvalidWARFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Soulo Recoverable Manifest Fixture",
          "version": "1.0.0",
          "web_accessible_resources": [{
            "resources": ["fixture.png"],
            "use_dynamic_url": true
          }]
        }
        """
        try Data(manifest.utf8).write(
            to: fixtureDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: fixtureDirectory.appendingPathComponent("fixture.png"),
            options: .atomic
        )

        let extensionObject = try await WKWebExtension(resourceBaseURL: fixtureDirectory)
        XCTAssertEqual(extensionObject.displayName, "Soulo Recoverable Manifest Fixture")
        XCTAssertTrue(extensionObject.errors.contains { error in
            let error = error as NSError
            return error.domain == WKWebExtension.errorDomain && error.code == 6
        })

        let service = BrowserExtensionService.shared
        let record = try await service.installWebExtension(from: fixtureDirectory)
        defer { service.deleteWebExtension(record.id) }
        XCTAssertGreaterThan(record.compatibilityWarningCount ?? 0, 0)
    }

    @MainActor
    func testInstalledWebExtensionExposesItsActionPopup() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("Native WebExtensions require iOS 18.4 or newer")
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloActionPopupFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Soulo Action Popup Fixture",
          "version": "1.0.0",
          "action": {
            "default_title": "Open Fixture",
            "default_popup": "popup.html"
          }
        }
        """
        try Data(manifest.utf8).write(
            to: fixtureDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data("<html><body>Popup</body></html>".utf8).write(
            to: fixtureDirectory.appendingPathComponent("popup.html"),
            options: .atomic
        )

        let service = BrowserExtensionService.shared
        let record = try await service.installWebExtension(from: fixtureDirectory)
        defer { service.deleteWebExtension(record.id) }

        let action = try XCTUnwrap(service.webExtensionAction(for: record.id))
        XCTAssertEqual(action.label, "Open Fixture")
        XCTAssertTrue(action.presentsPopup)
        XCTAssertTrue(action.isEnabled)
    }

    @MainActor
    func testWebExtensionCompatibilityLayerLoadsBeforeNotificationBackgroundWorker() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("Native WebExtensions require iOS 18.4 or newer")
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloCompatibilityFixture-\(UUID().uuidString)", isDirectory: true)
        let installDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloCompatibilityInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fixtureDirectory)
            try? FileManager.default.removeItem(at: installDirectory)
        }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Soulo Notification Compatibility Fixture",
          "version": "1.0.0",
          "permissions": ["notifications", "offscreen"],
          "background": { "service_worker": "background/worker.js" },
          "action": { "default_popup": "popup.html" }
        }
        """
        try Data(manifest.utf8).write(
            to: fixtureDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory.appendingPathComponent("background", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("""
        globalThis.__originalWorkerLoaded = true;
        chrome.notifications.onClicked.addListener(function() {});
        chrome.commands.onCommand.addListener(function() {});
        """.utf8).write(
            to: fixtureDirectory.appendingPathComponent("background/worker.js"),
            options: .atomic
        )
        try Data("<html><head></head><body>Popup</body></html>".utf8).write(
            to: fixtureDirectory.appendingPathComponent("popup.html"),
            options: .atomic
        )

        let preparedURL = try WebExtensionPackagePreparer.prepare(
            sourceURL: fixtureDirectory,
            in: installDirectory
        )
        let preparedManifestData = try Data(
            contentsOf: preparedURL.appendingPathComponent("manifest.json")
        )
        let preparedManifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: preparedManifestData) as? [String: Any]
        )
        let background = try XCTUnwrap(preparedManifest["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__soulo_webextension_background_v3.js")
        XCTAssertTrue((preparedManifest["permissions"] as? [String])?.contains("nativeMessaging") == true)

        let wrapper = try String(
            contentsOf: preparedURL.appendingPathComponent("__soulo_webextension_background_v3.js"),
            encoding: .utf8
        )
        XCTAssertTrue(wrapper.contains("__soulo_webextension_compatibility.js"))
        XCTAssertTrue(wrapper.contains("background/worker.js"))

        let preparedWorker = try String(
            contentsOf: preparedURL.appendingPathComponent("background/worker.js"),
            encoding: .utf8
        )
        XCTAssertTrue(preparedWorker.contains("notifications?.onClicked?.addListener"))
        XCTAssertTrue(preparedWorker.contains("commands?.onCommand?.addListener"))

        let compatibility = try String(
            contentsOf: preparedURL.appendingPathComponent("__soulo_webextension_compatibility.js"),
            encoding: .utf8
        )
        XCTAssertTrue(compatibility.contains("chrome.notifications"))
        XCTAssertTrue(compatibility.contains("chrome.offscreen"))

        let popup = try String(
            contentsOf: preparedURL.appendingPathComponent("popup.html"),
            encoding: .utf8
        )
        XCTAssertTrue(popup.contains("/__soulo_webextension_compatibility.js"))

        let extensionObject = try await WKWebExtension(resourceBaseURL: preparedURL)
        XCTAssertEqual(extensionObject.displayName, "Soulo Notification Compatibility Fixture")
        XCTAssertNil(NativeWebExtensionIssuePolicy.firstFatalIssue(in: extensionObject.errors))
    }

    func testWebExtensionCompatibilityCompletesPartialNotificationAPI() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var chrome = {
          runtime: {
            sendNativeMessage: function(identifier, message, callback) {
              if (callback) callback({ success: true, id: 'fixture' });
            },
            sendMessage: function() {}
          },
          notifications: {}
        };
        """)

        context.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        XCTAssertNil(context.exception)
        XCTAssertEqual(
            context.evaluateScript("typeof chrome.notifications.onClicked.addListener")?.toString(),
            "function"
        )
        XCTAssertEqual(
            context.evaluateScript("typeof chrome.notifications.create")?.toString(),
            "function"
        )
        XCTAssertEqual(
            context.evaluateScript("typeof chrome.offscreen.hasDocument")?.toString(),
            "function"
        )

        let browserOnlyContext = try XCTUnwrap(JSContext())
        browserOnlyContext.evaluateScript("""
        var browser = {
          runtime: {
            sendNativeMessage: function() { return Promise.resolve({ success: true }); },
            sendMessage: function() { return Promise.resolve(); }
          },
          notifications: {}
        };
        """)
        browserOnlyContext.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        XCTAssertNil(browserOnlyContext.exception)
        XCTAssertEqual(
            browserOnlyContext.evaluateScript("typeof browser.notifications.onClicked.addListener")?.toString(),
            "function"
        )
    }

    func testWebExtensionCompatibilityProvidesTomatoClockTimerContract() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var localValues = {};
        var chrome = {
          runtime: {
            getManifest: function() { return { commands: {
              'start-tomato': {}, 'start-short-break': {}, 'start-long-break': {}
            } }; },
            sendMessage: function() {}
          },
          storage: { local: {
            get: function(key, callback) {
              var result = {}; result[key] = localValues[key]; callback(result);
            },
            set: function(values, callback) {
              Object.assign(localValues, values); if (callback) callback();
            },
            remove: function(key, callback) {
              delete localValues[key]; if (callback) callback();
            }
          } }
        };
        """)
        context.evaluateScript(WebExtensionPackagePreparer.compatibilitySourceForTesting)
        context.evaluateScript("""
        chrome.runtime.sendMessage({ action: 'setTimer', data: { type: 'tomato' } }, function() {});
        """)
        // Give JavaScriptCore's resolved promise jobs an evaluation boundary.
        context.evaluateScript("0")
        context.evaluateScript("0")

        XCTAssertEqual(
            context.evaluateScript("localValues.timer && localValues.timer.status")?.toString(),
            "running"
        )
        XCTAssertEqual(
            context.evaluateScript("localValues.timer && localValues.timer.type")?.toString(),
            "tomato"
        )
        XCTAssertGreaterThan(
            context.evaluateScript("localValues.timer && localValues.timer.scheduledTime")?.toDouble() ?? 0,
            Date().timeIntervalSince1970 * 1_000
        )
    }

    func testWebExtensionManifestIssuePolicyKeepsOnlyKnownRecoverableIssues() {
        let domain = "WKWebExtensionErrorDomain"
        let recoverable = NSError(domain: domain, code: 6)
        let missingResource = NSError(domain: domain, code: 2)
        let fatal = NSError(domain: domain, code: 4)

        XCTAssertNil(NativeWebExtensionIssuePolicy.firstFatalIssue(in: [recoverable, missingResource]))
        XCTAssertEqual(
            NativeWebExtensionIssuePolicy.recoverableIssueCount(in: [recoverable, missingResource]),
            2
        )
        XCTAssertEqual(
            (NativeWebExtensionIssuePolicy.firstFatalIssue(in: [recoverable, fatal]) as NSError?)?.code,
            4
        )
    }

    @MainActor
    func testManifestV3WebExtensionCanBeInstalledLocally() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("Native WebExtensions require iOS 18.4 or newer")
        }

        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SouloWebExtensionFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let manifest = """
        {
          "manifest_version": 3,
          "name": "Soulo Test Extension",
          "description": "A local fixture for validating native WebExtension loading.",
          "version": "1.0.0",
          "content_scripts": [{
            "matches": ["https://example.com/*"],
            "js": ["content.js"]
          }]
        }
        """
        try Data(manifest.utf8).write(
            to: fixtureDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data("globalThis.__souloWebExtensionFixture = true;".utf8).write(
            to: fixtureDirectory.appendingPathComponent("content.js"),
            options: .atomic
        )

        let service = BrowserExtensionService.shared
        let record = try await service.installWebExtension(from: fixtureDirectory)
        defer { service.deleteWebExtension(record.id) }

        XCTAssertEqual(record.name, "Soulo Test Extension")
        XCTAssertEqual(record.version, "1.0.0")
        XCTAssertTrue(record.isEnabled)
        XCTAssertTrue(service.webExtensions.contains { $0.id == record.id })
        XCTAssertNil(service.webExtensionAction(for: record.id))
    }

    func testAdHidingScriptPublishesHiddenElementStats() {
        let script = AdBlockService.adHidingScript(cosmetic: true)

        XCTAssertTrue(script.contains("souloAdBlocker"))
        XCTAssertTrue(script.contains("hiddenCount"))
        XCTAssertTrue(script.contains("trackerHosts"))
        XCTAssertTrue(script.contains("location.hostname"))
        XCTAssertTrue(script.contains("__souloAdBlockInstalled"))
        XCTAssertTrue(script.contains("__souloAdBlockObserver"))
        XCTAssertTrue(script.contains("__souloAdBlockRemoveAds"))
    }

    func testAdHidingScriptCoversChineseVideoSiteFloatingAds() {
        let script = AdBlockService.adHidingScript(cosmetic: true)

        XCTAssertTrue(script.contains(".cpcad"))
        XCTAssertTrue(script.contains("gudingwei"))
        XCTAssertFalse(script.contains("isLikelyFloatingAd"))
        XCTAssertFalse(script.contains("div, section, aside, iframe, a, img"))
        XCTAssertTrue(script.contains("isAuthenticationElement"))
        XCTAssertFalse(script.contains("text.includes('ad')"))
        XCTAssertFalse(script.contains("iframe[src*=\"ad\"]"))
        XCTAssertFalse(script.contains("img[src*=\"ad\"]"))
        XCTAssertFalse(script.contains("a[href*=\"ad\"]"))
        XCTAssertFalse(script.contains("[class*=\"interstitial\"]"))
    }

    func testPrivacyProtectionScriptIncludesGPCResourceObservationAndCookieHandling() {
        let script = WebViewScripts.privacyProtection(
            gpcEnabled: true,
            cookieBannerHandling: true,
            disabledHosts: ["example.com"]
        )

        XCTAssertTrue(script.contains("globalPrivacyControl"))
        XCTAssertTrue(script.contains("souloPrivacy"))
        XCTAssertTrue(script.contains("resourceObserved"))
        XCTAssertTrue(script.contains("isSensitiveChallengePage"))
        XCTAssertTrue(script.contains("observations"))
        XCTAssertTrue(script.contains("resourceType"))
        XCTAssertTrue(script.contains("__souloPrivacyProtectionInstalled"))
        XCTAssertTrue(script.contains("__souloPrivacyObserver"))
        XCTAssertTrue(script.contains("resourceURLForElement"))
        XCTAssertTrue(script.contains("observations.length < 120"))
        XCTAssertFalse(script.contains("a[href]"))
        XCTAssertTrue(script.contains("cookieBanner"))
        XCTAssertTrue(script.contains("isProtectedPageElement"))
        XCTAssertTrue(script.contains("hasCookieConsentLanguage"))
        XCTAssertTrue(script.contains("isOverlayLike"))
        XCTAssertFalse(script.contains("rect.bottom > window.innerHeight * 0.65"))
        XCTAssertFalse(script.contains("dialog, footer"))
        XCTAssertTrue(script.contains("example.com"))
        XCTAssertTrue(script.contains("MutationObserver"))
    }

    func testPrivacyProtectionScriptCanDisableGPCAndCookieHandling() {
        let script = WebViewScripts.privacyProtection(gpcEnabled: false, cookieBannerHandling: false)

        XCTAssertTrue(script.contains("var souloGPCEnabled = false"))
        XCTAssertTrue(script.contains("var souloCookieBannerHandling = false"))
    }

    func testDownloadBridgeCapturesGeneratedFilesAndReportsProgress() {
        let script = WebViewScripts.downloadBridge

        XCTAssertTrue(script.contains("souloDownload"))
        XCTAssertTrue(script.contains("blob:"))
        XCTAssertTrue(script.contains("data:"))
        XCTAssertTrue(script.contains("type: 'started'"))
        XCTAssertTrue(script.contains("type: 'chunk'"))
        XCTAssertTrue(script.contains("type: 'finished'"))
        XCTAssertTrue(script.contains("type: 'failed'"))
        XCTAssertTrue(script.contains("__souloCancelDownloads"))
        XCTAssertTrue(script.contains("__souloCancelDownload"))
        XCTAssertTrue(script.contains("blob.slice"))
        XCTAssertTrue(script.contains("FileReader"))
        XCTAssertFalse(script.contains("readAsDataURL"))
    }

    func testAccessibilityEnhancementsAreConservativeAndIdempotent() {
        let script = WebViewScripts.accessibilityEnhancements

        XCTAssertTrue(script.contains("__souloAccessibilityInstalled"))
        XCTAssertTrue(script.contains("__souloAccessibilityScan"))
        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("data-soulo-accessible-result"))
        XCTAssertTrue(script.contains("aria-label"))
        XCTAssertTrue(script.contains("aria-level"))
        XCTAssertTrue(script.contains("role', 'button"))
        XCTAssertFalse(script.contains("style.display = '"))
        XCTAssertFalse(script.contains("style.setProperty"))
        XCTAssertFalse(script.contains("removeChild"))
    }

    func testAccessibilityPlatformNavigationStopsAtBoundaries() {
        XCTAssertEqual(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 1,
                count: 3,
                direction: .previous
            ),
            0
        )
        XCTAssertEqual(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 1,
                count: 3,
                direction: .next
            ),
            2
        )
        XCTAssertNil(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 0,
                count: 3,
                direction: .previous
            )
        )
        XCTAssertNil(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 2,
                count: 3,
                direction: .next
            )
        )
    }

    func testAccessibilityWebPagingClampsAndReportsPosition() {
        XCTAssertEqual(
            WebAccessibilityPaging.targetOffset(
                current: 100,
                minimum: 0,
                maximum: 1_000,
                viewportHeight: 500,
                direction: .forward
            ),
            510
        )
        XCTAssertEqual(
            WebAccessibilityPaging.targetOffset(
                current: 900,
                minimum: 0,
                maximum: 1_000,
                viewportHeight: 500,
                direction: .forward
            ),
            1_000
        )
        XCTAssertNil(
            WebAccessibilityPaging.targetOffset(
                current: 1_000,
                minimum: 0,
                maximum: 1_000,
                viewportHeight: 500,
                direction: .forward
            )
        )

        let position = WebAccessibilityPaging.pagePosition(
            offset: 820,
            minimum: 0,
            maximum: 1_640,
            viewportHeight: 500
        )
        XCTAssertEqual(position.current, 3)
        XCTAssertEqual(position.total, 5)
    }

    func testInjectedBrowserScriptsAreParsableJavaScript() {
        assertJavaScriptParses(AdBlockService.adHidingScript(cosmetic: true))
        assertJavaScriptParses(WebViewScripts.blankPageProbe)
        assertJavaScriptParses(WebViewScripts.privacyProtection(gpcEnabled: true, cookieBannerHandling: true))
        assertJavaScriptParses(WebViewScripts.downloadBridge)
        assertJavaScriptParses(WebViewScripts.contextMenuResourceTracking)
        assertJavaScriptParses(WebViewScripts.mediaResourceTracking)
        assertJavaScriptParses(WebResourceInspectionService.extractionScript)
        assertJavaScriptParses(
            WebViewScripts.extensionInstallBridge(
                title: "Install with Soulo",
                message: "Soulo can install this extension directly.",
                installButton: "Install",
                installingButton: "Installing…",
                logoDataURL: "data:image/png;base64,AA=="
            )
        )
        assertJavaScriptParses(WebViewScripts.accessibilityEnhancements)
        assertJavaScriptParses(WebViewScripts.webAppearanceBootstrap)
        assertJavaScriptParses(
            WebViewScripts.applyWebAppearance(
                warmColorShift: true,
                forceDark: true,
                reduceMotion: true,
                underlineLinks: true
            )
        )
        assertJavaScriptParses(WebViewScripts.synchronizeViewport)
        assertJavaScriptParses(WebViewScripts.compensatePageZoomWidth(scale: 1.2))
    }

    func testResourceSnapshotParsesSupportedWebResourcesAndRejectsUnsafeSchemes() {
        let snapshot = WebResourceSnapshot(dictionary: [
            "pageTitle": "Resource Test",
            "pageURL": "https://example.com/page",
            "images": [
                ["url": "https://example.com/photo.jpg", "width": 640, "height": 480, "title": "Photo"],
                ["url": "data:image/png;base64,abc", "width": 1, "height": 1, "title": "Inline"]
            ],
            "videos": [["url": "https://cdn.example.com/movie.mp4", "title": "Movie"]],
            "audio": [["url": "https://cdn.example.com/audio.mp3", "title": "Audio"]],
            "links": [
                ["url": "https://EXAMPLE.com/story/#intro", "title": "Story"],
                ["url": "https://example.com/story", "title": "Duplicate"],
                ["url": "https://example.com/story?chapter=2", "title": "Distinct query"]
            ],
            "texts": ["  Useful   text  ", "Useful text"],
            "colors": [["value": "#aabbcc", "count": 4]],
            "documents": [["url": "https://example.com/file.pdf", "title": "PDF"]]
        ])

        XCTAssertEqual(snapshot.images.count, 1)
        XCTAssertEqual(snapshot.images.first?.width, 640)
        XCTAssertEqual(snapshot.videos.count, 1)
        XCTAssertEqual(snapshot.videos.first?.suggestedFilename, "movie.mp4")
        XCTAssertEqual(snapshot.audio.count, 1)
        XCTAssertEqual(snapshot.links.count, 2)
        XCTAssertEqual(snapshot.links.first?.title, "Story")
        XCTAssertEqual(snapshot.textFragments.map(\.text), ["Useful text"])
        XCTAssertEqual(snapshot.colors.first?.value, "#AABBCC")
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testResourceInspectorDefaultsAndExtractionKeepOnlyLoadedImages() {
        XCTAssertEqual(WebResourceInspectorDefaults.minimumImageWidth, 200)
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("image.complete"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("image.naturalWidth <= 0"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("performance.getEntriesByType('resource')"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("window.__souloObservedResourceURLs"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("window.ytInitialPlayerResponse"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("collectYouTubeStreamingData"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("window.__playinfo__"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("script#RENDER_DATA"))
        XCTAssertFalse(WebResourceInspectionService.extractionScript.contains("sourceSet.split"))
    }

    func testYouTubePlaybackURLsUseOfficialEmbedPlayer() throws {
        let watchURL = try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=oi2QgPH61JM&ra=m"))
        let shortURL = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        let shortsURL = try XCTUnwrap(URL(string: "https://www.youtube.com/shorts/jNQXAC9IVRw"))
        let mediaURL = try XCTUnwrap(URL(string: "https://rr1---sn.example.com/videoplayback?id=fixture"))

        XCTAssertTrue(WebResourceMediaService.isYouTubePageURL(watchURL))
        XCTAssertTrue(WebResourceMediaService.isYouTubePageURL(shortURL))
        XCTAssertTrue(WebResourceMediaService.isYouTubePageURL(shortsURL))
        XCTAssertFalse(WebResourceMediaService.isYouTubePageURL(mediaURL))
        XCTAssertEqual(
            WebResourceMediaService.youtubeEmbedURL(for: watchURL)?.host,
            "www.youtube.com"
        )
        XCTAssertEqual(
            WebResourceMediaService.youtubeEmbedURL(for: watchURL)?.path,
            "/embed/oi2QgPH61JM"
        )
        XCTAssertEqual(
            WebResourceMediaService.youtubeEmbedURL(for: shortURL)?.path,
            "/embed/dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            WebResourceMediaService.youtubeEmbedURL(for: shortsURL)?.path,
            "/embed/jNQXAC9IVRw"
        )
        XCTAssertNil(WebResourceMediaService.youtubeEmbedURL(for: mediaURL))

        let resource = WebMediaResource(
            kind: .video,
            url: mediaURL,
            title: "Fixture",
            posterURL: nil,
            delivery: .youtubeSABR
        )
        XCTAssertEqual(
            WebResourceMediaService.downloadIdentityURL(for: resource, pageURL: watchURL).absoluteString,
            "https://www.youtube.com/watch?v=oi2QgPH61JM"
        )
    }

    @MainActor
    func testResourceInspectorExtractsStructuredPlayerMedia() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <html><body><script>
            window.ytInitialPlayerResponse = {
              videoDetails: {
                title: 'Fixture video',
                thumbnail: { thumbnails: [{ url: 'https://media.example.com/poster.jpg' }] }
              },
              streamingData: {
                formats: [
                  { mimeType: 'video/mp4', url: 'https://media.example.com/videoplayback?mime=video%2Fmp4' },
                  {
                    mimeType: 'video/mp4',
                    signatureCipher: 'url=https%3A%2F%2Fmedia.example.com%2Fciphered-videoplayback%3Fmime%3Dvideo%252Fmp4&sp=sig&sig=signed'
                  }
                ],
                adaptiveFormats: [
                  { mimeType: 'audio/mp4', url: 'https://media.example.com/videoplayback?mime=audio%2Fmp4' },
                  {
                    mimeType: 'video/mp4',
                    signatureCipher: 'url=https%3A%2F%2Fmedia.example.com%2Fencrypted-videoplayback%3Fmime%3Dvideo%252Fmp4&sp=sig&s=requires-player-decipher'
                  }
                ]
              }
            };
            window.__souloObservedResourceURLs = [
              'https://runtime.example.com/videoplayback?mime=video%2Fmp4&range=0-999'
            ];
            window.__playinfo__ = {
              play_addr: {
                url_list: [
                  'https://cdn-a.example.com/video/tos/example?mime_type=video_mp4',
                  'https://cdn-b.example.com/video/tos/example?mime_type=video_mp4'
                ]
              }
            };
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/watch"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(snapshot.videos.map(\.url.absoluteString), [
            "https://runtime.example.com/videoplayback?mime=video%2Fmp4&range=0-999",
            "https://media.example.com/videoplayback?mime=video%2Fmp4",
            "https://media.example.com/ciphered-videoplayback?mime=video%2Fmp4&sig=signed",
            "https://cdn-a.example.com/video/tos/example?mime_type=video_mp4"
        ])
        XCTAssertEqual(snapshot.audio.map(\.url.absoluteString), [
            "https://media.example.com/videoplayback?mime=audio%2Fmp4"
        ])
    }

    @MainActor
    func testResourceInspectorCreatesYouTubeSABRVideoWithoutLegacyFormatURLs() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <html><head><title>Modern fixture - YouTube</title></head><body>
            <video poster="https://i.ytimg.com/vi/fixture/hq720.jpg"></video>
            <script>
            window.ytInitialPlayerResponse = {
              videoDetails: {
                videoId: 'fixture',
                title: 'Modern fixture',
                thumbnail: { thumbnails: [{ url: 'https://i.ytimg.com/vi/fixture/hq720.jpg' }] }
              },
              streamingData: {
                serverAbrStreamingUrl: 'https://rr.example.googlevideo.com/videoplayback?sabr=1',
                adaptiveFormats: [
                  { itag: 136, mimeType: 'video/mp4; codecs="avc1.4d401f"', height: 720 },
                  { itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 129000 }
                ]
              }
            };
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=fixture"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(snapshot.videos.count, 1)
        XCTAssertEqual(snapshot.videos.first?.url.absoluteString, "https://m.youtube.com/watch?v=fixture")
        XCTAssertEqual(snapshot.videos.first?.delivery, .youtubeSABR)
        XCTAssertEqual(snapshot.videos.first?.title, "Modern fixture")
        XCTAssertEqual(snapshot.videos.first?.suggestedFilename, "Modern fixture.mp4")
        XCTAssertTrue(snapshot.audio.isEmpty)
    }

    @MainActor
    func testResourceInspectorCreatesYouTubeSABRVideoFromObservedPlayback() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <html><head><title>Observed fixture - YouTube</title></head><body>
            <video poster="https://i.ytimg.com/vi/observed/hq720.jpg"></video>
            <script>
            window.__souloObservedResourceURLs = [
              'https://rr.example.googlevideo.com/videoplayback?sabr=1&foo=bar'
            ];
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=observed"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(snapshot.videos.count, 1)
        XCTAssertEqual(snapshot.videos.first?.url.absoluteString, "https://m.youtube.com/watch?v=observed")
        XCTAssertEqual(snapshot.videos.first?.delivery, .youtubeSABR)
        XCTAssertTrue(snapshot.audio.isEmpty)
    }

    @MainActor
    func testResourceInspectorIgnoresPreviousYouTubeVideoAfterSPANavigation() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <html><head><title>Current fixture - YouTube</title></head><body>
            <video poster="https://i.ytimg.com/vi/current/hq720.jpg"></video>
            <script>
            const previousResponse = {
              videoDetails: { videoId: 'previous', title: 'Previous fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://old.example.googlevideo.com/videoplayback?sabr=1',
                formats: [
                  { mimeType: 'video/mp4', url: 'https://old.example.googlevideo.com/videoplayback?itag=18' }
                ],
                adaptiveFormats: [
                  { mimeType: 'video/mp4; codecs="avc1.4d401f"', height: 720 }
                ]
              }
            };
            const currentResponse = {
              videoDetails: { videoId: 'current', title: 'Current fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://current.example.googlevideo.com/videoplayback?sabr=1',
                adaptiveFormats: [
                  { mimeType: 'video/mp4; codecs="avc1.4d401f"', height: 720 },
                  { mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 129000 }
                ]
              }
            };
            window.__souloYouTubePlayerResponses = { current: currentResponse };
            window.__souloYouTubePlayerResponse = previousResponse;
            window.ytInitialPlayerResponse = previousResponse;
            window.__souloObservedResourceURLs = [
              'https://old.example.googlevideo.com/videoplayback?itag=18'
            ];
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=current"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(snapshot.videos.count, 1)
        XCTAssertEqual(snapshot.videos.first?.url.absoluteString, "https://m.youtube.com/watch?v=current")
        XCTAssertEqual(snapshot.videos.first?.title, "Current fixture")
        XCTAssertEqual(snapshot.videos.first?.delivery, .youtubeSABR)
        XCTAssertTrue(snapshot.audio.isEmpty)
    }

    @MainActor
    func testMediaTrackingCachesPlayerResponseFromYouTubeNextSPANavigation() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewScripts.mediaResourceTracking,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            """
            <html><body><script>
            const nextPlayerResponse = {
              videoDetails: { videoId: 'current', title: 'Current SPA fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://current.example.googlevideo.com/videoplayback?sabr=1',
                adaptiveFormats: [
                  { itag: 136, mimeType: 'video/mp4; codecs="avc1.4d401f"', height: 720 },
                  { itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 129000 }
                ]
              }
            };
            window.fetch = async function() {
              return new Response(JSON.stringify({
                navigationData: { nested: { playerResponse: nextPlayerResponse } }
              }), { headers: { 'Content-Type': 'application/json' } });
            };
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=previous"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        _ = try await webView.evaluateJavaScript("""
            history.pushState({}, '', '/watch?v=current');
            void fetch('/youtubei/v1/next');
            true;
        """)
        try await Task.sleep(for: .milliseconds(200))

        let cachedVideoID = try await webView.evaluateJavaScript(
            "window.__souloYouTubePlayerResponses?.current?.videoDetails?.videoId || ''"
        ) as? String
        let currentTitle = try await webView.evaluateJavaScript(
            "window.__souloYouTubePlayerResponse?.videoDetails?.title || ''"
        ) as? String

        XCTAssertEqual(cachedVideoID, "current")
        XCTAssertEqual(currentTitle, "Current SPA fixture")
    }

    @MainActor
    func testMediaTrackingReadsLiveYouTubePlayerAfterSPANavigation() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebViewScripts.mediaResourceTracking,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            """
            <html><head><title>Live player fixture - YouTube</title></head><body>
            <div id="movie_player"></div>
            <video></video>
            <script>
            const previousResponse = {
              videoDetails: { videoId: 'previous', title: 'Previous live fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://old.example.googlevideo.com/videoplayback?sabr=1',
                adaptiveFormats: [
                  { itag: 136, mimeType: 'video/mp4; codecs="avc1.4d401f"', height: 720 },
                  { itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 129000 }
                ]
              }
            };
            const currentResponse = {
              videoDetails: { videoId: 'current', title: 'Current live fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://current.example.googlevideo.com/videoplayback?sabr=1',
                adaptiveFormats: [
                  { itag: 136, mimeType: 'video/mp4; codecs="avc1.4d401f"', height: 720 },
                  { itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 129000 }
                ]
              }
            };
            window.activePlayerResponse = previousResponse;
            document.getElementById('movie_player').getPlayerResponse = function() {
              return window.activePlayerResponse;
            };
            window.ytInitialPlayerResponse = previousResponse;
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=previous"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        _ = try await webView.evaluateJavaScript("""
            window.__souloPreparedYouTubePlayerResponse = window.activePlayerResponse;
            window.__souloLatestPageSABR = {
              url: 'https://old.example.googlevideo.com/videoplayback?sabr=1',
              videoID: 'previous'
            };
            history.pushState({}, '', '/watch?v=current');
            window.activePlayerResponse = currentResponse;
            window.dispatchEvent(new Event('yt-navigate-finish'));
            window.__souloResolveCurrentYouTubePlayerResponse();
            true;
        """)

        let resolvedVideoID = try await webView.evaluateJavaScript(
            "window.__souloYouTubePlayerResponses?.current?.videoDetails?.videoId || ''"
        ) as? String
        let preparedWasInvalidated = try await webView.evaluateJavaScript(
            "window.__souloPreparedYouTubePlayerResponse === null"
        ) as? Bool
        let staleSABRWasInvalidated = try await webView.evaluateJavaScript(
            "window.__souloLatestPageSABR === null"
        ) as? Bool
        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(resolvedVideoID, "current")
        XCTAssertEqual(preparedWasInvalidated, true)
        XCTAssertEqual(staleSABRWasInvalidated, true)
        XCTAssertEqual(snapshot.videos.first?.title, "Current live fixture")
        XCTAssertEqual(snapshot.videos.first?.delivery, .youtubeSABR)
    }

    @MainActor
    func testResourceInspectorDoesNotDuplicateYouTubeSABRVideoWhenFormatURLExists() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <html><head><title>Hybrid fixture - YouTube</title></head><body>
            <video></video>
            <script>
            window.ytInitialPlayerResponse = {
              videoDetails: { videoId: 'hybrid', title: 'Hybrid fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://rr.example.googlevideo.com/videoplayback?sabr=1',
                formats: [
                  { mimeType: 'video/mp4', url: 'https://rr.example.googlevideo.com/videoplayback?itag=18' }
                ]
              }
            };
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=hybrid"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(snapshot.videos.count, 1)
        XCTAssertEqual(
            snapshot.videos.first?.url.absoluteString,
            "https://rr.example.googlevideo.com/videoplayback?itag=18"
        )
        XCTAssertEqual(snapshot.videos.first?.delivery, .youtubeSABR)
    }

    @MainActor
    func testResourceInspectorKeepsAdaptiveOnlyYouTubeVideoOnSABRTransport() async throws {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            """
            <html><head><title>Adaptive fixture - YouTube</title></head><body>
            <video></video>
            <script>
            window.ytInitialPlayerResponse = {
              videoDetails: { videoId: 'adaptive', title: 'Adaptive fixture' },
              streamingData: {
                serverAbrStreamingUrl: 'https://rr.example.googlevideo.com/videoplayback?sabr=1',
                adaptiveFormats: [
                  {
                    mimeType: 'video/mp4; codecs="avc1.4d401f"',
                    height: 720,
                    url: 'https://rr.example.googlevideo.com/videoplayback?itag=136'
                  },
                  {
                    mimeType: 'audio/mp4; codecs="mp4a.40.2"',
                    bitrate: 129000,
                    url: 'https://rr.example.googlevideo.com/videoplayback?itag=140'
                  }
                ]
              }
            };
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=adaptive"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)

        XCTAssertEqual(snapshot.videos.count, 1)
        XCTAssertEqual(
            snapshot.videos.first?.url.absoluteString,
            "https://rr.example.googlevideo.com/videoplayback?itag=136"
        )
        XCTAssertEqual(snapshot.videos.first?.delivery, .youtubeSABR)
    }

    func testSABRNativeFetchBridgeRestrictsAllowedHTTPSURLs() throws {
        XCTAssertTrue(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create"))
        ))
        XCTAssertFalse(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "http://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create"))
        ))
        XCTAssertFalse(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "https://jnn-pa.googleapis.com.example.com/steal"))
        ))
        XCTAssertFalse(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=fixture"))
        ))
        XCTAssertTrue(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "https://rr1---sn.example.googlevideo.com/videoplayback?sabr=1&rn=0"))
        ))
        XCTAssertFalse(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "https://rr1---sn.example.googlevideo.com/videoplayback?itag=18"))
        ))
        XCTAssertFalse(StreamingMediaDownloadService.isAllowedNativeFetchURL(
            try XCTUnwrap(URL(string: "https://googlevideo.com.example.com/videoplayback?sabr=1"))
        ))
    }

    func testSABRMediaFetchStaysInWebKitPlayerSession() {
        let bridge = StreamingMediaDownloadService.nativeFetchBridgeScript

        XCTAssertTrue(bridge.contains("if (isGoogleVideoSABR)"))
        XCTAssertTrue(bridge.contains("pageInit.credentials = 'include'"))
        XCTAssertTrue(bridge.contains("return originalFetch(input, pageInit)"))
    }

    func testSABREngineUsesPageResolvedEndpointAndDedicatedNativeFetch() {
        let source = """
        function gn(e){return performance.getEntriesByType("resource").map(r=>r.name).reverse().find(r=>/[?&]sabr=1(?:&|$)/.test(r))||e.streamingData?.serverAbrStreamingUrl||""}
        const first={fetch:window.fetch.bind(window)};
        const second={fetch:window.fetch.bind(window)};
        """

        let prepared = StreamingMediaDownloadService.preparedSABREngineSource(source)

        XCTAssertTrue(prepared.contains(
            "n&&n.videoID===e.videoDetails?.videoId?n.url:e.streamingData?.serverAbrStreamingUrl"
        ))
        XCTAssertTrue(prepared.contains("window.__souloLatestPageSABR"))
        XCTAssertTrue(prepared.contains("n.videoID===e.videoDetails?.videoId"))
        XCTAssertFalse(prepared.contains("performance.getEntriesByType(\"resource\")"))
        XCTAssertEqual(
            prepared.components(separatedBy: "fetch:window.__souloNativeFetch.bind(window)").count - 1,
            2
        )
        XCTAssertFalse(prepared.contains("fetch:window.fetch.bind(window)"))
    }

    func testSABREngineUsesCachedAndMobilePlayerResponseSources() {
        let source = """
        function xn(){let e=[window.ytInitialPlayerResponse,window.ytplayer?.bootstrapPlayerResponse,window.ytplayer?.config?.args?.raw_player_response];for(let n of e)if(n){if(typeof n=="string")try{return JSON.parse(n)}catch{continue}return n}throw new Error("YouTube player response unavailable")}
        async function download(e){let t=xn(),r=t.videoDetails?.videoId;return r}
        """

        let prepared = StreamingMediaDownloadService.preparedSABREngineSource(source)

        XCTAssertTrue(prepared.contains("window.__souloYouTubePlayerResponse"))
        XCTAssertTrue(prepared.contains("window.__souloPreparedYouTubePlayerResponse"))
        XCTAssertTrue(prepared.contains("window.__souloYouTubePlayerResponses?.[e]"))
        XCTAssertTrue(prepared.contains("if(e&&n!==e)continue"))
        XCTAssertTrue(prepared.contains("!Array.isArray(r.adaptiveFormats)"))
        XCTAssertTrue(prepared.contains(
            "let t=e?.playerResponseJSON?JSON.parse(e.playerResponseJSON):xn(),r="
        ))
        XCTAssertTrue(prepared.contains("window.getInitialData?.()?.playerResponse"))
        XCTAssertTrue(prepared.contains("window.ytcfg?.get?.(\"PLAYER_RESPONSE\")"))
    }

    func testMediaTrackingKeepsYouTubeResolvedSABREndpoint() {
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("__souloLatestPageSABR"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("videoID:"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("pageHost.endsWith('.youtube.com')"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("__souloYouTubePlayerResponse"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("__souloYouTubePlayerResponses"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("(?:player|next)"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("cacheYouTubePlayerResponsesDeep"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("getPlayerResponse"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("yt-navigate-finish"))
        XCTAssertTrue(WebViewScripts.mediaResourceTracking.contains("syncYouTubeVideoState"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("__souloYouTubePlayerResponse"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("__souloResolveCurrentYouTubePlayerResponse"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("candidateVideoID !== currentVideoID"))
        XCTAssertTrue(WebResourceInspectionService.extractionScript.contains("isGoogleVideoURL"))
    }

    func testStreamingJavaScriptErrorKeepsOriginalExceptionMessage() {
        let source = NSError(
            domain: "WKErrorDomain",
            code: 4,
            userInfo: ["WKJavaScriptExceptionMessage": "YouTube player response unavailable"]
        )

        let surfaced = StreamingMediaDownloadService.surfacedStreamingError(source)

        XCTAssertEqual(surfaced.localizedDescription, "YouTube player response unavailable")
    }

    func testPageVideoFrameDataURLDecoding() throws {
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let data = try XCTUnwrap(sourceImage.pngData())
        let dataURL = "data:image/png;base64,\(data.base64EncodedString())"

        let decoded = try XCTUnwrap(WebResourceMediaService.image(fromDataURL: dataURL))

        XCTAssertEqual(decoded.cgImage?.width, sourceImage.cgImage?.width)
        XCTAssertEqual(decoded.cgImage?.height, sourceImage.cgImage?.height)
        XCTAssertNil(WebResourceMediaService.image(fromDataURL: "https://example.com/frame.png"))
    }

    func testContextResourceRecognizesDownloadableKinds() throws {
        let image = try XCTUnwrap(WebContextResource(dictionary: [
            "kind": "image",
            "url": "https://example.com/photo.jpg",
            "filename": "photo.jpg"
        ]))

        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.suggestedFilename, "photo.jpg")
        XCTAssertTrue(image.kind.allowsDirectDownload)
        XCTAssertTrue(WebContextResource.Kind.video.allowsDirectDownload)
        XCTAssertTrue(WebContextResource.Kind.audio.allowsDirectDownload)
        XCTAssertTrue(WebContextResource.Kind.file.allowsDirectDownload)
        XCTAssertTrue(WebViewScripts.contextMenuResourceTracking.contains("csv|epub"))
        XCTAssertFalse(WebViewScripts.contextMenuResourceTracking.contains("epub|mp4"))
        XCTAssertNil(WebContextResource(dictionary: [
            "kind": "image",
            "url": "javascript:alert(1)"
        ]))
    }

    func testMediaResourceFilenameInfersExtensionFromMIMEQuery() throws {
        let video = WebMediaResource(
            kind: .video,
            url: try XCTUnwrap(URL(string: "https://media.example.com/videoplayback?mime=video%2Fmp4&token=abc")),
            title: "Example",
            posterURL: nil
        )
        let audio = WebMediaResource(
            kind: .audio,
            url: try XCTUnwrap(URL(string: "https://media.example.com/audio?type=audio%2Fmpeg")),
            title: "Example",
            posterURL: nil
        )
        let alternateQueryName = WebMediaResource(
            kind: .video,
            url: try XCTUnwrap(URL(string: "https://media.example.com/play?mime_type=video%2Fmp4")),
            title: "Example",
            posterURL: nil
        )
        let extensionlessVideo = WebMediaResource(
            kind: .video,
            url: try XCTUnwrap(URL(string: "https://m.douyin.com/aweme/v1/playwm/?video_id=example")),
            title: "Example",
            posterURL: nil
        )
        let underscoredMIMEVideo = WebMediaResource(
            kind: .video,
            url: try XCTUnwrap(URL(string: "https://media.example.com/video/tos/file?mime_type=video_mp4")),
            title: "Example",
            posterURL: nil
        )

        XCTAssertEqual(video.suggestedFilename, "videoplayback.mp4")
        XCTAssertEqual(audio.suggestedFilename, "audio.mp3")
        XCTAssertEqual(alternateQueryName.suggestedFilename, "play.mp4")
        XCTAssertEqual(extensionlessVideo.suggestedFilename, "playwm.mp4")
        XCTAssertEqual(underscoredMIMEVideo.suggestedFilename, "file.mp4")
    }

    func testMediaDeliveryMetadataParsesStreamingProtocolsAndCompanionAudio() throws {
        let snapshot = WebResourceSnapshot(dictionary: [
            "videos": [
                [
                    "url": "https://cdn.example.com/master.m3u8",
                    "delivery": "hls"
                ],
                [
                    "url": "https://cdn.example.com/video.m4s",
                    "delivery": "separateTracks",
                    "audioURL": "https://cdn.example.com/audio.m4s"
                ],
                [
                    "url": "https://rr.example.com/videoplayback?itag=134",
                    "delivery": "youtubeSABR"
                ]
            ]
        ])

        XCTAssertEqual(snapshot.videos.map(\.delivery), [.hls, .separateTracks, .youtubeSABR])
        XCTAssertEqual(
            snapshot.videos[1].companionAudioURL?.absoluteString,
            "https://cdn.example.com/audio.m4s"
        )
    }

    @MainActor
    func testResourceInspectorRecognizesGenericSeparatedDASHTracks() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(
            """
            <html><head><title>Separated media</title></head><body><script>
            window.__playinfo__ = { data: { dash: {
              video: [
                { height: 720, width: 1280, codecid: 7, bandwidth: 800000,
                  baseUrl: 'https://cdn.example.com/video-720.m4s' },
                { height: 1080, width: 1920, codecid: 12, bandwidth: 1200000,
                  baseUrl: 'https://cdn.example.com/video-hevc.m4s' }
              ],
              audio: [
                { id: 30280, bandwidth: 192000,
                  baseUrl: 'https://cdn.example.com/audio.m4s' }
              ]
            } } };
            </script></body></html>
            """,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/watch"))
        )
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            if !webView.isLoading { break }
        }

        let snapshot = try await WebResourceInspectionService.inspect(webView: webView)
        let video = try XCTUnwrap(snapshot.videos.first)
        XCTAssertEqual(video.delivery, .separateTracks)
        XCTAssertEqual(video.url.absoluteString, "https://cdn.example.com/video-720.m4s")
        XCTAssertEqual(video.companionAudioURL?.absoluteString, "https://cdn.example.com/audio.m4s")
    }

    func testWebAppearanceReadabilityPreferencesCanBeAppliedAndRemoved() {
        let enabled = WebViewScripts.applyWebAppearance(
            warmColorShift: false,
            forceDark: false,
            reduceMotion: true,
            underlineLinks: true
        )
        let disabled = WebViewScripts.applyWebAppearance(
            warmColorShift: false,
            forceDark: false,
            reduceMotion: false,
            underlineLinks: false
        )

        XCTAssertTrue(WebViewScripts.webAppearanceBootstrap.contains("soulo-reduce-motion-style"))
        XCTAssertTrue(WebViewScripts.webAppearanceBootstrap.contains("soulo-underline-links-style"))
        XCTAssertTrue(WebViewScripts.webAppearanceBootstrap.contains("style.remove()"))
        XCTAssertTrue(enabled.contains("reduceMotion: true"))
        XCTAssertTrue(enabled.contains("underlineLinks: true"))
        XCTAssertTrue(disabled.contains("reduceMotion: false"))
        XCTAssertTrue(disabled.contains("underlineLinks: false"))
    }

    func testPageZoomCompensationKeepsTheRenderedDocumentAtViewportWidth() {
        let enlarged = WebViewScripts.compensatePageZoomWidth(scale: 1.2)
        let reset = WebViewScripts.compensatePageZoomWidth(scale: 1)

        XCTAssertTrue(enlarged.contains("var scale = 1.20000"))
        XCTAssertTrue(enlarged.contains("100 / scale"))
        XCTAssertTrue(enlarged.contains("root.style.setProperty('width'"))
        XCTAssertTrue(enlarged.contains("'important'"))
        XCTAssertTrue(reset.contains("Math.abs(scale - 1)"))
        XCTAssertTrue(reset.contains("delete window[stateKey]"))
    }

    func testUserScriptURLMatchingSupportsManifestGlobsAndAllURLs() {
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://news.example.com/article/42")!,
                patterns: ["*://*.example.com/*"]
            )
        )
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "http://localhost/page")!,
                patterns: ["<all_urls>"]
            )
        )
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.com/article")!,
                patterns: ["*://*.example.com/*"]
            )
        )
        XCTAssertFalse(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.org/")!,
                patterns: ["*://*.example.com/*"]
            )
        )
        XCTAssertTrue(UserScriptURLMatcher.isValid(pattern: "/^https:\\/\\/example\\.com\\//"))
        XCTAssertFalse(UserScriptURLMatcher.isValid(pattern: "ftp://example.com/*"))
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.com:8443/path")!,
                patterns: ["*://example.com/*"]
            )
        )
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.com/path")!,
                patterns: ["http*://example.com/*"]
            )
        )
    }

    func testUserScriptCompatibilityBridgeAndDocumentEndSchedulingAreValidJavaScript() {
        let script = UserScriptRecord(
            name: "Load Timing",
            source: "window.onload = function() { window.__loaded = true; };",
            injectionTime: .documentEnd
        )
        let bridgeToken = "private-token"
        let bootstrap = UserScriptRuntime.compatibilityBootstrap(
            bridgeToken: bridgeToken,
            script: script
        )
        let wrapped = UserScriptRuntime.wrappedSource(for: script, bridgeToken: bridgeToken)

        XCTAssertTrue(wrapped.contains("DOMContentLoaded"))
        XCTAssertTrue(wrapped.contains("document.readyState === 'loading'"))
        XCTAssertTrue(wrapped.contains("__souloIncludes"))
        XCTAssertTrue(bootstrap.contains("GM_xmlhttpRequest"))
        XCTAssertTrue(bootstrap.contains("souloUserScriptXHR"))
        XCTAssertTrue(bootstrap.contains("GM_getValue"))
        XCTAssertTrue(bootstrap.contains("GM_addStyle"))
        XCTAssertTrue(bootstrap.contains("GM_info"))
        XCTAssertTrue(bootstrap.contains("unsafeWindow"))
        XCTAssertTrue(bootstrap.contains(bridgeToken))
        XCTAssertFalse(bootstrap.contains("window.GM_xmlhttpRequest"))
        assertJavaScriptParses(wrapped)
        assertJavaScriptParses(bootstrap)
    }

    func testUserScriptExplicitGrantsLimitRuntimeAPIsAndRestoreStoredValues() {
        let script = UserScriptRecord(
            name: "Storage",
            source: "",
            grants: ["GM_getValue", "GM_setValue"],
            storedValues: ["theme": #"{"value":"dark"}"#]
        )
        let bootstrap = UserScriptRuntime.compatibilityBootstrap(bridgeToken: "token", script: script)

        XCTAssertTrue(bootstrap.contains("GM_getValue"))
        XCTAssertTrue(bootstrap.contains("GM_setValue"))
        XCTAssertTrue(bootstrap.contains(#""theme":{"value":"dark"}"#))
        XCTAssertFalse(bootstrap.contains("var GM_addStyle"))
        XCTAssertFalse(bootstrap.contains("var GM_xmlhttpRequest"))
        assertJavaScriptParses(bootstrap)
    }

    @MainActor
    func testUserScriptMetadataParsesIdentityDescriptionAndRequirements() {
        let metadata = BrowserExtensionService.parseMetadata(from: """
        // ==UserScript==
        // @name Metadata Probe
        // @description Improves the page
        // @author Soulo
        // @homepageURL https://example.com/home
        // @updateURL https://example.com/update.user.js
        // @downloadURL https://example.com/download.user.js
        // @match https://example.com/*
        // @match https://example.com/*
        // @require https://cdn.example.com/helper.js
        // @resource theme https://cdn.example.com/theme.css
        // ==/UserScript==
        """)

        XCTAssertEqual(metadata.description, "Improves the page")
        XCTAssertEqual(metadata.author, "Soulo")
        XCTAssertEqual(metadata.homepageURL, "https://example.com/home")
        XCTAssertEqual(metadata.updateURL, "https://example.com/update.user.js")
        XCTAssertEqual(metadata.downloadURL, "https://example.com/download.user.js")
        XCTAssertEqual(metadata.patterns, ["https://example.com/*"])
        XCTAssertEqual(metadata.requiredURLs, ["https://cdn.example.com/helper.js"])
        XCTAssertEqual(metadata.resources, ["theme": "https://cdn.example.com/theme.css"])
    }

    @MainActor
    func testFullPageCapturePreparationLoadsLazyResourcesAndRestoresScrollPosition() {
        let script = WebPageCaptureService.resourcePreparationScript

        XCTAssertTrue(script.contains("document.images"))
        XCTAssertTrue(script.contains("document.fonts"))
        XCTAssertTrue(script.contains("window.scrollTo(originalX, originalY)"))
        assertAsyncJavaScriptParses(script)
    }

    @MainActor
    func testUserScriptRuntimeActuallyExecutesInsideWKWebView() async throws {
        let webView = WKWebView(frame: .zero)
        _ = try await evaluate("globalThis.__souloUserScriptProbe = 0", in: webView)
        let script = UserScriptRecord(
            name: "Runtime Probe",
            source: "globalThis.__souloUserScriptProbe += 1;",
            matchPatterns: ["*"]
        )

        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { result in
                continuation.resume(returning: result)
            }
        }
        if case let .failure(error) = result { throw error }

        let value = try await evaluate("globalThis.__souloUserScriptProbe", in: webView)
        XCTAssertEqual((value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    func testExpandedUserScriptDOMStorageAndURLAPIsExecuteInsideWKWebView() async throws {
        let webView = WKWebView(frame: .zero)
        let script = UserScriptRecord(
            name: "Expanded API Probe",
            source: """
            var __changes = [];
            var __listener = GM_addValueChangeListener('theme', function(key, oldValue, newValue, remote) {
                __changes.push([key, oldValue, newValue, remote]);
            });
            GM_setValues({ theme: 'dark', count: 2 });
            var __values = GM_getValues({ theme: 'light', missing: 7 });
            GM_deleteValues(['count']);
            GM_removeValueChangeListener(__listener);
            var __element = GM_addElement('button', { id: 'soulo-expanded-probe', textContent: 'Ready' });
            globalThis.__expandedResult = {
                values: __values,
                keys: GM_listValues(),
                changes: __changes,
                elementText: __element.textContent
            };
            """,
            matchPatterns: ["*"],
            grants: [
                "GM_getValues", "GM_setValues", "GM_deleteValues", "GM_listValues",
                "GM_addValueChangeListener", "GM_removeValueChangeListener",
                "GM_addElement", "window.onurlchange"
            ]
        )

        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { continuation.resume(returning: $0) }
        }
        if case let .failure(error) = result { throw error }

        let rawProbe = try await evaluate("globalThis.__expandedResult", in: webView)
        let probe = try XCTUnwrap(rawProbe as? [String: Any])
        let values = try XCTUnwrap(probe["values"] as? [String: Any])
        XCTAssertEqual(values["theme"] as? String, "dark")
        XCTAssertEqual((values["missing"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(probe["elementText"] as? String, "Ready")
        XCTAssertEqual((probe["changes"] as? [Any])?.count, 1)
        XCTAssertEqual(probe["keys"] as? [String], ["theme"])
        let bootstrap = UserScriptRuntime.compatibilityBootstrap(bridgeToken: "", script: script)
        XCTAssertTrue(bootstrap.contains("window.dispatchEvent(new CustomEvent('urlchange'"))
        XCTAssertTrue(bootstrap.contains("['pushState', 'replaceState']"))
    }

    @MainActor
    func testExpandedUserScriptAPIsArePermissionScopedAndParseAsJavaScript() {
        let grants = [
            "GM_registerMenuCommand", "GM_unregisterMenuCommand", "GM_notification",
            "GM_openInTab", "GM_closeTab", "GM_focusTab", "GM_download",
            "GM_getTab", "GM_saveTab", "GM_getTabs", "GM_cookie",
            "GM_getResourceText", "GM_getResourceURL"
        ]
        let script = UserScriptRecord(
            name: "Native API Probe",
            source: "",
            grants: grants,
            connectDomains: ["example.com"],
            resources: ["fixture": "https://example.com/fixture.txt"]
        )
        let bootstrap = UserScriptRuntime.compatibilityBootstrap(
            bridgeToken: "native-api-token",
            script: script
        )
        XCTAssertTrue(script.unsupportedGrants.isEmpty)

        for symbol in [
            "GM_registerMenuCommand", "GM_notification", "GM_openInTab", "GM_closeTab",
            "GM_focusTab", "GM_download", "GM_getTab", "GM_cookie",
            "GM_getResourceText", "GM_getResourceURL"
        ] {
            XCTAssertTrue(bootstrap.contains(symbol), "Missing \(symbol)")
        }
        XCTAssertTrue(bootstrap.contains("fixture.txt"))
        assertJavaScriptParses(bootstrap)
    }

    @MainActor
    func testUserScriptBulkStorageIsValidatedAtomically() throws {
        let marker = UUID().uuidString
        let source = """
        // ==UserScript==
        // @name Bulk Storage \(marker)
        // @namespace com.soulo.tests.bulk.\(marker)
        // @match https://example.com/*
        // @grant GM_setValues
        // ==/UserScript==
        """
        let service = BrowserExtensionService.shared
        let record = try service.saveUserScript(
            id: nil,
            fallbackName: marker,
            source: source,
            explicitPatterns: nil,
            injectionTime: nil
        )
        defer { service.deleteUserScript(record.id) }

        try service.setStoredValues(
            ["theme": #"{"value":"dark"}"#, "count": #"{"value":2}"#],
            scriptID: record.id
        )
        XCTAssertEqual(service.userScript(id: record.id)?.storedValues?.count, 2)

        XCTAssertThrowsError(
            try service.setStoredValues(
                ["valid": #"{"value":true}"#, "invalid": "not-json"],
                scriptID: record.id
            )
        )
        XCTAssertNil(service.userScript(id: record.id)?.storedValues?["valid"])
        XCTAssertEqual(service.userScript(id: record.id)?.storedValues?.count, 2)
    }

    @MainActor
    func testBuiltInReadingProgressSampleIsDisabledAndRunsInWKWebView() async throws {
        let service = BrowserExtensionService.shared
        let definition = try XCTUnwrap(BuiltInUserScripts.definition(
            namespace: "com.dkluge.soulo.examples.reading-progress"
        ))
        let installed = try XCTUnwrap(service.userScripts.first {
            $0.namespace == definition.namespace
        })
        XCTAssertTrue(installed.isBuiltIn == true)
        XCTAssertFalse(installed.isEnabled)
        XCTAssertEqual(installed.matchPatterns, ["*://*/*"])
        XCTAssertEqual(installed.grants, ["GM_addStyle"])

        let webView = WKWebView(frame: .zero)
        let script = UserScriptRecord(
            name: installed.name,
            source: definition.source,
            matchPatterns: ["*"],
            grants: ["GM_addStyle"],
            injectionTime: .documentStart
        )
        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { result in
                continuation.resume(returning: result)
            }
        }
        if case let .failure(error) = result { throw error }

        let exists = try await evaluate(
            "document.getElementById('soulo-reading-progress') !== null",
            in: webView
        )
        XCTAssertEqual(exists as? Bool, true)
    }

    @MainActor
    func testBuiltInAreaTextExtractorShowsLauncherAndStartsPicking() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        _ = try await evaluate(
            "document.open(); document.write('<p>Important text for this page.</p>'); document.close();",
            in: webView
        )
        let definition = try XCTUnwrap(BuiltInUserScripts.definition(
            namespace: "com.dkluge.soulo.examples.page-marker"
        ))
        var script = definition.makeRecord()
        script.matchPatterns = ["*"]
        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { result in
                continuation.resume(returning: result)
            }
        }
        if case let .failure(error) = result { throw error }

        let launcherExists = try await evaluate(
            "document.getElementById('soulo-area-text-extractor-host')?.shadowRoot.querySelector('.launcher') !== null",
            in: webView
        )
        XCTAssertEqual(launcherExists as? Bool, true)
        _ = try await evaluate(
            "document.getElementById('soulo-area-text-extractor-host').shadowRoot.querySelector('.launcher').click()",
            in: webView
        )
        let pickingIsActive = try await evaluate(
            "document.getElementById('soulo-area-text-extractor-host').shadowRoot.querySelector('.guide').classList.contains('visible')",
            in: webView
        )
        XCTAssertEqual(pickingIsActive as? Bool, true)
    }

    @MainActor
    func testBuiltInAreaTextExtractorExtractsTappedRegion() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        _ = try await evaluate(
            "document.open(); document.write('<section id=content><h2>Important title</h2><p>Text from this region.</p></section>'); document.close();",
            in: webView
        )
        let definition = try XCTUnwrap(BuiltInUserScripts.definition(
            namespace: "com.dkluge.soulo.examples.page-marker"
        ))
        var script = definition.makeRecord()
        script.matchPatterns = ["*"]
        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { result in
                continuation.resume(returning: result)
            }
        }
        if case let .failure(error) = result { throw error }

        _ = try await evaluate(
            """
            (function() {
              var host = document.getElementById('soulo-area-text-extractor-host');
              host.shadowRoot.querySelector('.launcher').click();
              document.getElementById('content').dispatchEvent(new MouseEvent('click', {
                bubbles: true,
                cancelable: true,
                clientX: 20,
                clientY: 20
              }));
            })();
            """,
            in: webView
        )

        let extractedText = try await evaluate(
            "document.getElementById('soulo-area-text-extractor-host').shadowRoot.querySelector('.preview').textContent",
            in: webView
        )
        XCTAssertEqual(extractedText as? String, "Important title\nText from this region.")
        let panelIsVisible = try await evaluate(
            "document.getElementById('soulo-area-text-extractor-host').shadowRoot.querySelector('.panel').classList.contains('visible')",
            in: webView
        )
        XCTAssertEqual(panelIsVisible as? Bool, true)
    }

    @MainActor
    func testBuiltInAreaTextExtractorLauncherCanBeDragged() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        _ = try await evaluate(
            "document.open(); document.write('<p>Drag test</p>'); document.close();",
            in: webView
        )
        let definition = try XCTUnwrap(BuiltInUserScripts.definition(
            namespace: "com.dkluge.soulo.examples.page-marker"
        ))
        var script = definition.makeRecord()
        script.matchPatterns = ["*"]
        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { result in
                continuation.resume(returning: result)
            }
        }
        if case let .failure(error) = result { throw error }

        let position = try await evaluate(
            """
            (function() {
              var button = document.getElementById('soulo-area-text-extractor-host').shadowRoot.querySelector('.launcher');
              var rect = button.getBoundingClientRect();
              button.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerId: 9, button: 0, clientX: rect.left + 20, clientY: rect.top + 20 }));
              button.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, pointerId: 9, button: 0, clientX: 90, clientY: 160 }));
              button.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 9, button: 0, clientX: 90, clientY: 160 }));
              return { left: parseFloat(button.style.left), top: parseFloat(button.style.top) };
            })();
            """,
            in: webView
        ) as? [String: Any]
        XCTAssertNotNil(position?["left"] as? Double)
        XCTAssertNotNil(position?["top"] as? Double)
    }

    @MainActor
    func testBuiltInScriptRefreshPreservesUserState() throws {
        let definition = try XCTUnwrap(BuiltInUserScripts.definition(
            namespace: "com.dkluge.soulo.examples.page-marker"
        ))
        var existing = definition.makeRecord()
        existing.isEnabled = true
        existing.storedValues = ["theme": #"{"value":"dark"}"#]
        let refreshed = definition.makeRecord(preserving: existing)

        XCTAssertEqual(refreshed.id, existing.id)
        XCTAssertTrue(refreshed.isEnabled)
        XCTAssertEqual(refreshed.storedValues, existing.storedValues)
        XCTAssertEqual(refreshed.source, definition.source)
        XCTAssertEqual(refreshed.version, "2.0.0")
    }

    @MainActor
    func testUserScriptInstallParsesMetadataAndEnableSwitchControlsSelection() throws {
        let marker = UUID().uuidString
        let source = """
        // ==UserScript==
        // @name Selection Probe \(marker)
        // @namespace com.soulo.tests.\(marker)
        // @version 1.2.3
        // @match https://example.com/*
        // @exclude https://example.com/private/*
        // @grant GM_xmlhttpRequest
        // @connect api.example.com
        // @run-at document-start
        // ==/UserScript==
        globalThis.__souloSelectionProbe = true;
        """
        let service = BrowserExtensionService.shared
        let record = try service.saveUserScript(
            id: nil,
            fallbackName: "Fallback",
            source: source,
            explicitPatterns: nil,
            injectionTime: nil
        )
        defer { service.deleteUserScript(record.id) }

        XCTAssertEqual(record.name, "Selection Probe \(marker)")
        XCTAssertEqual(record.namespace, "com.soulo.tests.\(marker)")
        XCTAssertEqual(record.version, "1.2.3")
        XCTAssertEqual(record.excludePatterns, ["https://example.com/private/*"])
        XCTAssertEqual(record.grants, ["GM_xmlhttpRequest"])
        XCTAssertEqual(record.connectDomains, ["api.example.com"])
        XCTAssertEqual(record.injectionTime, .documentStart)
        XCTAssertTrue(service.scripts(
            for: URL(string: "https://example.com/article")!,
            at: .documentStart
        ).contains { $0.id == record.id })
        XCTAssertFalse(service.scripts(
            for: URL(string: "https://example.com/private/account")!,
            at: .documentStart
        ).contains { $0.id == record.id })

        service.setUserScriptEnabled(record.id, enabled: false)
        XCTAssertFalse(service.scripts(
            for: URL(string: "https://example.com/article")!,
            at: .documentStart
        ).contains { $0.id == record.id })
    }

    @MainActor
    func testUserScriptReinstallUpdatesNamespacedRecordWithoutCreatingADuplicate() throws {
        let marker = UUID().uuidString
        let service = BrowserExtensionService.shared
        let firstSource = """
        // ==UserScript==
        // @name Update Probe \(marker)
        // @namespace com.soulo.update.\(marker)
        // @version 1.0
        // @match https://example.com/*
        // ==/UserScript==
        globalThis.__version = 1;
        """
        let first = try service.saveUserScript(
            id: nil,
            fallbackName: "Probe",
            source: firstSource,
            explicitPatterns: nil,
            injectionTime: nil
        )
        defer { service.deleteUserScript(first.id) }

        let updated = try service.saveUserScript(
            id: nil,
            fallbackName: "Probe",
            source: firstSource.replacingOccurrences(of: "@version 1.0", with: "@version 2.0"),
            explicitPatterns: nil,
            injectionTime: nil
        )

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.version, "2.0")
        XCTAssertEqual(service.userScripts.filter { $0.id == first.id }.count, 1)
    }

    @MainActor
    func testUserScriptRejectsInvalidWebsiteRule() {
        XCTAssertThrowsError(
            try BrowserExtensionService.shared.saveUserScript(
                id: nil,
                fallbackName: "Invalid",
                source: "globalThis.invalid = true;",
                explicitPatterns: ["ftp://example.com/*"],
                injectionTime: .documentEnd
            )
        )
    }

    func testUserScriptConnectPolicyHonorsDeclaredDomains() {
        let script = UserScriptRecord(
            name: "Network",
            source: "",
            connectDomains: ["api.example.com", "self"]
        )
        XCTAssertTrue(UserScriptConnectPolicy.allows(
            url: URL(string: "https://v2.api.example.com/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertTrue(UserScriptConnectPolicy.allows(
            url: URL(string: "https://www.example.org/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertFalse(UserScriptConnectPolicy.allows(
            url: URL(string: "https://tracker.invalid/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertFalse(UserScriptHTTPBridge.isAllowedTarget(
            URL(string: "http://127.0.0.1/private")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertFalse(UserScriptHTTPBridge.isAllowedTarget(
            URL(string: "https://api.example.com.evil.invalid/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
    }

    func testUserScriptWithoutConnectIsRestrictedToCurrentHost() {
        let script = UserScriptRecord(name: "Same Site", source: "")
        let pageURL = URL(string: "https://www.example.org/article")!

        XCTAssertTrue(UserScriptConnectPolicy.allows(
            url: URL(string: "https://www.example.org/api")!,
            script: script,
            pageURL: pageURL
        ))
        XCTAssertFalse(UserScriptConnectPolicy.allows(
            url: URL(string: "https://api.example.org/data")!,
            script: script,
            pageURL: pageURL
        ))
    }

    private func assertJavaScriptParses(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let context = JSContext()!
        context.evaluateScript("new Function(\(javaScriptStringLiteral(script)))")
        XCTAssertNil(context.exception, file: file, line: line)
    }

    private func assertAsyncJavaScriptParses(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let context = JSContext()!
        let wrapped = "return (async () => {\n\(script)\n})();"
        context.evaluateScript("new Function(\(javaScriptStringLiteral(wrapped)))")
        XCTAssertNil(context.exception, file: file, line: line)
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let arrayLiteral = String(data: data, encoding: .utf8)!
        return "(\(arrayLiteral))[0]"
    }

    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

}
