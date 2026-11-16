#if SOULO_ACCEPTANCE
import SwiftUI
import UIKit
import CoreData

/// Compiled only into the isolated acceptance app. The published app has no
/// probe, synthetic job, diagnostic UI or acceptance environment switch.
@MainActor
final class DeviceAcceptanceRun: ObservableObject {
    static let shared = DeviceAcceptanceRun()
    @Published private(set) var phase = "idle"
    private(set) var nativeStarted = false
    private(set) var backgroundObserved = false
    private(set) var nativeProgress = 0.0
    private var operation: Task<Void, Never>?
    private var initializedPreferences = false
    private var playerFixtureService: BrowserExtensionService?
    private var historySeeded = false
    private var bookmarksSeeded = false
    private let historyPrefix = "exit-history-qa-" + UUID().uuidString

    func seedBookmarksIfRequested(in context: NSManagedObjectContext) {
        guard !bookmarksSeeded, ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_BOOKMARKS"] == "1" else { return }
        bookmarksSeeded = true
        for record in (try? context.fetch(BookmarkRecord.request(predicate: NSPredicate(format: "urlString BEGINSWITH %@", "https://quicklinks.soulo.test/")))) ?? [] { context.delete(record) }
        for (index, name) in ["One", "Two", "Three"].enumerated() {
            let record = BookmarkRecord(title: "Quicklink QA " + name, urlString: "https://quicklinks.soulo.test/" + name.lowercased())
            record.dateAdded = Date().addingTimeInterval(Double(10-index)); context.insert(record)
        }
        try? context.save()
    }

    func seedHistoryIfRequested(in context: NSManagedObjectContext) async {
        guard !historySeeded, ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_HISTORY"] == "1" else { return }
        historySeeded = true
        UserDefaults.standard.set(false, forKey: BrowsingHistoryExitPolicy.preferenceKey)
        try? await Task.sleep(for: .milliseconds(500))
        context.insert(SearchHistoryRecord(keyword: historyPrefix + "-visit", visitedURLString: "https://exit-history.soulo.test/" + historyPrefix))
        context.insert(SearchHistoryRecord(keyword: historyPrefix + "-query"))
        try? context.save()
    }

    func historyStatus(in context: NSManagedObjectContext) -> String {
        guard historySeeded else { return "" }
        let visits = SearchHistoryRecord.request(predicate: NSPredicate(format: "keyword == %@", historyPrefix + "-visit"))
        let queries = SearchHistoryRecord.request(predicate: NSPredicate(format: "keyword == %@", historyPrefix + "-query"))
        return ";history-visits=\((try? context.count(for: visits)) ?? -1);history-queries=\((try? context.count(for: queries)) ?? -1)"
    }
    @Published private(set) var fixtures = "idle"
    private(set) var extensionPlayerURL: URL?

    func seedPlayerIfRequested(tabs: TabManager) async {
        guard fixtures == "idle", ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_PLAYER"] == "1",
              let value = ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_PLAYER_MEDIA"],
              let media = URL(string: value), media.scheme == "http", media.host == "127.0.0.1",
              #available(iOS 18.4, *) else { return }
        fixtures = "installing-player"
        do {
            let fresh = ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_FRESH_PLAYER"] == "1"
            let service: BrowserExtensionService
            if fresh {
                service = BrowserExtensionService(extensionRoot: FileManager.default.temporaryDirectory.appendingPathComponent("player-acceptance-" + UUID().uuidString))
                playerFixtureService = service
            } else { service = .shared }
            let marker = "soulo.qa.faststream.player.id"
            let record: WebExtensionRecord
            if !fresh, let stored = UserDefaults.standard.string(forKey: marker), let id = UUID(uuidString: stored),
               let existing = service.webExtensions.first(where: { $0.id == id }) {
                record = existing
                if !existing.isEnabled { service.setWebExtensionEnabled(id, enabled: true) }
            } else {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                record = try await service.installWebExtension(from: documents.appendingPathComponent("faststream-compatibility-qa.crx"))
                if !fresh { UserDefaults.standard.set(record.id.uuidString, forKey: marker) }
            }
            // Restoring installed extensions is asynchronous. Do not race the
            // normal restore task when this fixture reuses its prior install.
            for _ in 0..<200 {
                if NativeWebExtensionRuntime.shared.controller.extensionContexts.contains(where: { $0.uniqueIdentifier == record.id.uuidString }),
                   !service.loadingWebExtensions.contains(record.id) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let context = NativeWebExtensionRuntime.shared.controller.extensionContexts.first(where: { $0.uniqueIdentifier == record.id.uuidString }) else {
                throw BrowserExtensionError.invalidExtension
            }
            var components = URLComponents(url: context.baseURL.appendingPathComponent("player/index.html"), resolvingAgainstBaseURL: false)!
            components.fragment = media.absoluteString
            extensionPlayerURL = components.url
            tabs.createTab(url: extensionPlayerURL)
            fixtures = "ready:player"
        } catch { fixtures = "failed:\(error.localizedDescription)" }
        persist()
    }

    func seedIfRequested(tabs: TabManager) async {
        guard fixtures == "idle", ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_SEED"] == "1" else { return }
        fixtures = "installing"
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            for name in ["catcatch-compatibility-qa.crx", "tyty-compatibility-qa.crx"] {
                _ = try await BrowserExtensionService.shared.installWebExtension(from: documents.appendingPathComponent(name))
            }
            while tabs.tabs.count < 48 {
                let count = tabs.tabs.count + 1
                tabs.createTab(url: URL(string: "https://example.com/acceptance/\(count)"), keyword: "Acceptance \(count)", switchTo: false)
            }
            tabs.saveToDisk()
            fixtures = "ready:tabs=\(tabs.tabs.count),extensions=\(BrowserExtensionService.shared.webExtensions.count)"
        } catch { fixtures = "failed:\(error.localizedDescription)" }
        persist()
    }

    func recordMediaPlayback(stage: String, url: URL, pageURL: URL?, userAgent: String?, cookies: Int) {
        guard ProcessInfo.processInfo.environment["SOULO_VIDEO_VOLUME_TRACE"] == "1" else { return }
        let value: [String: Any] = ["stage": stage, "url": url.absoluteString,
            "referer": pageURL?.absoluteString ?? "", "userAgent": userAgent ?? "", "cookieCount": cookies]
        let target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("acceptance-media.json")
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: target, options: .atomic) }
    }

    func startIfRequested() {
        if !initializedPreferences {
            initializedPreferences = true
            if ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_VIDEO_TAKEOVER_RESET"] == "1" {
                UserDefaults.standard.removeObject(forKey: VideoPlaybackPreferences.takesOverWebPlayersKey)
            }
            if ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_PLATFORM_RESET"] == "1" {
                UserDefaults.standard.set(false, forKey: "auto_hide_platform_bar")
                UserDefaults.standard.set("list", forKey: "platform_management_layout")
            }
        }
        guard operation == nil, ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_EXPORT"] == "1" else { return }
        let progress = Progress(totalUnitCount: 200)
        phase = "running"
        operation = Task {
            do {
                try await MediaExportBackgroundService.shared.perform(progress: progress) {
                    for step in 1...200 {
                        try Task.checkCancellation()
                        if progress.isCancelled { throw CancellationError() }
                        progress.completedUnitCount = Int64(step)
                        nativeStarted = nativeStarted || MediaExportBackgroundService.shared.isRunning
                        backgroundObserved = backgroundObserved || UIApplication.shared.applicationState == .background
                        nativeProgress = max(nativeProgress, MediaExportBackgroundService.shared.acceptanceProgress ?? 0)
                        persist()
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                phase = "completed"
            } catch { phase = "failed: \(error.localizedDescription)" }
            persist()
        }
    }

    var status: String {
        "export=\(phase);native=\(nativeStarted ? 1 : 0);background=\(backgroundObserved ? 1 : 0);progress=\(nativeProgress);registration=\(String(describing: MediaExportBackgroundService.shared.acceptanceRegistration));submission=\(MediaExportBackgroundService.shared.acceptanceSubmissionError ?? "none");fixtures=\(fixtures)"
    }

    private func persist() {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("acceptance-background.txt")
        try? status.write(to: file, atomically: true, encoding: .utf8)
    }
}

struct DeviceAcceptanceProbe: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var tabs: TabManager
    @EnvironmentObject private var search: SearchViewModel
    @ObservedObject var speech: SpeechRecognitionService
    var openVoice: () -> Void = {}
    @ObservedObject private var run = DeviceAcceptanceRun.shared
    @State private var diagnostics = ""
    @State private var writtenSpeechState = ""
    @State private var extensionState = "{}"
    var body: some View {
        Text("QA")
            .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
            .accessibilityLabel("QA acceptance")
            .accessibilityValue(diagnostics + run.historyStatus(in: context) + ";extension=" + extensionState)
            .accessibilityIdentifier("qa.acceptance")
            .allowsHitTesting(false)
            .task {
                // A synthetic acceptance job follows the same foreground
                // requirement as an export started by a real button tap.
                while UIApplication.shared.applicationState != .active, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                run.startIfRequested()
                await run.seedHistoryIfRequested(in: context)
                run.seedBookmarksIfRequested(in: context)
                if ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_VOICE"] == "1" { openVoice() }
                await run.seedIfRequested(tabs: tabs)
                await run.seedPlayerIfRequested(tabs: tabs)
                if run.extensionPlayerURL != nil { search.isSearching = true }
                while !Task.isCancelled {
                    diagnostics = "transparency=\(UIAccessibility.isReduceTransparencyEnabled ? 1 : 0);motion=\(UIAccessibility.isReduceMotionEnabled ? 1 : 0);contrast=\(UIAccessibility.isDarkerSystemColorsEnabled ? 1 : 0);recording=\(speech.isRecording ? 1 : 0);analyzer=\(speech.usesAnalyzerForAcceptance ? 1 : 0);analyzerStarted=\(speech.acceptanceAnalyzerStarted ? 1 : 0);speechError=\(speech.errorMessage ?? "none");speechState=\(speech.acceptanceSpeechState);scenes=\(UIApplication.shared.connectedScenes.count);\(run.status)"
                    if diagnostics != writtenSpeechState {
                        writtenSpeechState = diagnostics
                        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("acceptance-speech.txt")
                        // Status only: never write microphone audio or recognized text.
                        try? diagnostics.write(to: file, atomically: true, encoding: .utf8)
                    }
                    if let expected = run.extensionPlayerURL, let web = tabs.activeWebViewModel?.webView,
                       web.url == expected,
                       let state = try? await web.evaluateJavaScript("""
                       (()=>{const p=globalThis.fastStream,v=p?.player?.getVideo?.(),bar=document.querySelector('.fluid_controls_progress_container'),full=document.querySelector('.fluid_control_fullscreen');return {time:p?.currentTime??0,duration:p?.duration??0,ready:v?.readyState??0,paused:v?.paused??true,bar:bar?.getBoundingClientRect().toJSON()??null,full:full?.getBoundingClientRect().toJSON()??null,controlsVisible:Number(getComputedStyle(document.querySelector('.fluid_controls_container')||document.body).opacity)>.7,fullscreen:!!document.fullscreenElement,download:document.querySelector('.main_download')?.getBoundingClientRect().toJSON()??null,error:v?.error?.message??'',environment:{downloadSource:String(chrome?.downloads?.download).slice(0,110),extension:typeof chrome?.extension,downloads:typeof chrome?.downloads?.download,serviceWorker:typeof navigator.serviceWorker,documentRouting:!!globalThis.__souloFrameMessagingCore?.documentInstalled},saveState:{making:p?.interfaceController?.saveManager?.makingDownload??null,reuse:p?.interfaceController?.saveManager?.reuseDownloadURL??null},text:document.body.innerText.slice(-600)};})()
                       """) as? [String: Any] {
                        var result = state
                        if #available(iOS 18.4, *), let owner = NativeWebExtensionRuntime.shared.controller.extensionContexts.first(where: { $0.baseURL.host == expected.host }) {
                            result["contextErrors"] = owner.errors.map(\.localizedDescription)
                        }
                        result["originX"] = web.convert(.zero, to: nil).x
                        result["originY"] = web.convert(.zero, to: nil).y
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) {
                            extensionState = String(decoding: data, as: UTF8.self)
                        }
                    } else if ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_LIVE_VIDEO"] == "1",
                              let model = tabs.activeWebViewModel, let web = model.webView {
                        // Read-only live-site evidence. Never synthesize a play
                        // gesture or change a publisher's media/source state.
                        if var state = try? await web.evaluateJavaScript("""
                        (()=>{const rect=e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}};
                        return {url:location.href,title:document.title,text:(document.body?.innerText||'').slice(0,1200),
                        videos:[...document.querySelectorAll('video')].map(v=>({time:v.currentTime,duration:Number.isFinite(v.duration)?v.duration:0,ready:v.readyState,paused:v.paused,width:v.videoWidth,height:v.videoHeight,fullscreen:!!(v.webkitDisplayingFullscreen||v.webkitPresentationMode==='fullscreen'||document.fullscreenElement),error:v.error?.message||'',rect:rect(v)})),
                        controls:[...document.querySelectorAll('button,[role=button],[class*=play],[class*=fullscreen],[data-soulo-video-rotate]')].filter(e=>{const r=e.getBoundingClientRect();return r.width>10&&r.height>10&&r.top<innerHeight&&r.bottom>0&&getComputedStyle(e).visibility!=='hidden'}).slice(0,100).map(e=>({label:e.getAttribute('aria-label')||e.getAttribute('title')||(e.textContent||'').slice(0,50),classes:typeof e.className==='string'?e.className:'',rect:rect(e)}))};})()
                        """) as? [String: Any] {
                            state["originX"] = web.convert(.zero, to: nil).x
                            state["originY"] = web.convert(.zero, to: nil).y
                            state["handoffError"] = model.videoOrientationError ?? ""
                            if let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys) {
                                extensionState = String(decoding: data, as: UTF8.self)
                            }
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
    }
}
#endif
