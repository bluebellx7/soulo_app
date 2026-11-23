import AVKit
import MediaPlayer
import Combine
import WebKit
import CryptoKit

@MainActor
final class VideoScreenAwakeService {
    static let shared = VideoScreenAwakeService()
    static let preferenceKey = "keep_screen_awake"
    private let preferenceOwner = UUID()
    private var userPreferenceEnabled = false
    private var owners = Set<UUID>()
    private var previousIdleTimerDisabled: Bool?

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadUserPreference() }
        }
        reloadUserPreference()
    }

    /// Use the same lease collection as playback, so disabling the setting
    /// never releases another player's request to keep the display awake.
    func reloadUserPreference() {
        let enabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        guard enabled != userPreferenceEnabled else { return }
        userPreferenceEnabled = enabled
        setActive(enabled, owner: preferenceOwner)
    }

    func setActive(_ active: Bool, owner: UUID) {
        if active {
            if owners.isEmpty { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }
        refresh()
    }

    private func refresh() {
        if owners.isEmpty {
            if let previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
                self.previousIdleTimerDisabled = nil
            }
        } else if UIApplication.shared.applicationState == .active {
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
    }

    private func suspend() {
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
    }
}

/// One player shared by local files, resource previews, the mini-player and system controls.
@MainActor
final class MediaSession: ObservableObject {
    static let shared = MediaSession()
    lazy var player = AVPlayer()
    private var configured = false
    #if DEBUG
    @Published private(set) var volumeObservationEvents = 0
    @Published private(set) var pauseInputLatency: TimeInterval?
    private var lastControlTouch: TimeInterval?
    func recordVideoControlTouch(timestamp: TimeInterval) {
        guard ProcessInfo.processInfo.environment["SOULO_VIDEO_VOLUME_TRACE"] == "1" else { return }
        lastControlTouch = timestamp
    }
    func recordVideoPauseInput() {
        guard let lastControlTouch else { pauseInputLatency = nil; return }
        let delay = ProcessInfo.processInfo.systemUptime - lastControlTouch
        pauseInputLatency = (0..<5).contains(delay) ? delay : nil
        self.lastControlTouch = nil
    }
    #endif
    private var playbackObservationTask: Task<Void, Never>?
    @Published private(set) var startupWarning: String?
    @Published private(set) var playbackStalled = false
    @Published private(set) var videoLoading: VideoLoadingStatus?
    @Published private(set) var videoCacheProgress = VideoCacheProgress()
    @Published var retainedPiPController: AVPlayerViewController?
    var retainedPiPDelegate: AnyObject?
    let pictureInPicture = MediaPictureInPicture()
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var pageURL: URL?
    @Published private(set) var elapsed = 0.0
    private var pendingSeek: VideoPlaybackSeek?
    private var observedNativeTime = 0.0
    private var latestSeekID: UUID?
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published var error: String?
    @Published var expanded = false
    @Published private(set) var hasVideo = false
    @Published private(set) var videoIsLandscape = false
    @Published var playerSurfaces = 0
    @Published var playerPages = 0
    @Published var musicPlayerPages = 0
    @Published private(set) var webMediaContext: WebMediaPlaybackContext?
    @Published private(set) var soulo: MatroskaPlayback?
    @Published private(set) var souloSystemAvailable = true
    @Published private(set) var souloSystemAvailabilityPending = false
    private var souloCompatibilityTask: Task<Void, Never>?
    @Published private(set) var localAudioPlaylist: [URL] = []
    var localAudioIndex: Int? {
        guard let url, !localAudioPlaylist.isEmpty else { return nil }
        if let index = localAudioPlaylist.firstIndex(of: url) { return index }
        let resolved = url.resolvingSymlinksInPath()
        return localAudioPlaylist.firstIndex { $0.resolvingSymlinksInPath() == resolved }
    }
    var isAudioPlayback: Bool {
        if retainedDownloadSource?.webMediaContext?.resource.kind == .audio { return true }
        return url.map { FileVideoEpisodes.isAudio($0.path) } ?? false
    }
    private var remoteControlsInstalled = false
    @Published var loop = false
    @Published var mirrored = false
    @Published private(set) var rate: Float
    @Published private(set) var temporaryRate = false
    @Published private(set) var temporaryRateFeedback: Float?
    private var rateFeedbackDismissal: Task<Void, Never>?
    private var rateBeforeTemporary: Float?
    @Published private(set) var gestureFeedback: VideoGestureFeedback?
    @Published private(set) var seekPreview: Double?
    private var gestureFeedbackDismissal: Task<Void, Never>?
    private weak var adjustedScreen: UIScreen?
    private var originalBrightness: CGFloat?
    private var interruptedGeneration: UUID?
    private var timer: Any?
    private var observations = Set<AnyCancellable>()
    private var itemObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var generation = UUID()
    private var preparation = UUID()
    func reservePreparation() -> UUID { preparation = UUID(); return preparation }
    func ownsPreparation(_ token: UUID) -> Bool { preparation == token }
    private var lastSavedSecond = -1
    private var wantsPlayback = false
    private(set) var playbackIntentRevision = 0
    private var isInBackground = UIApplication.shared.applicationState == .background
    private var foregroundVideoResume: (context: WebMediaPlaybackContext, generation: UUID, intent: Int)?
    var isPlaybackRequested: Bool { soulo?.isPlaybackRequested ?? wantsPlayback }
    private var persistsPosition = true
    private weak var sourceWebView: WKWebView?
    private var retainedDownloadSource: DownloadPlaybackSource?

    func playbackTransferSource() -> DownloadPlaybackSource? {
        guard let asset = player.currentItem?.asset as? AVURLAsset else { return nil }
        if let retainedDownloadSource, retainedDownloadSource.asset === asset { return retainedDownloadSource }
        let source = DownloadPlaybackSource(asset: asset, pageURL: pageURL, webView: sourceWebView, persistPosition: persistsPosition)
        source.webMediaContext = webMediaContext
        return source
    }

    func deferDownloadPackageRemoval(for asset: AVURLAsset, at url: URL) -> Bool {
        guard let source = retainedDownloadSource,
              source.asset === asset || source.downloadAsset === asset else { return false }
        let souloSource = soulo?.preparedPlaybackSource?.native
        guard player.currentItem?.asset === source.asset || souloSource === source else { return false }
        source.removePackageWhenReleased(url)
        return true
    }
    private let screenAwakeOwner = UUID()
    lazy var sleepTimer = PlaybackSleepTimerService(pause: { [weak self] in self?.pause() })

    init() {
        let saved = UserDefaults.standard.float(forKey: "media.rate")
        rate = Self.validRate(saved) ? saved : 1
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        player.allowsExternalPlayback = true
        AVAudioSession.sharedInstance().publisher(for: \.outputVolume).dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] value in
                #if DEBUG
                self?.volumeObservationEvents += 1
                #endif
                self?.outputVolumeChanged(Double(value))
            }.store(in: &observations)
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.updateTime(time) }
        }
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.soulo == nil else { return }
            self.playing = self.wantsPlayback && self.player.timeControlStatus == .playing && self.player.currentItem != nil
            self.updateScreenAwake()
            self.updateNowPlaying()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self, event.object as? AVPlayerItem === self.player.currentItem else { return }
            self.endTemporaryRate()
            if self.sleepTimer.playbackEnded() { self.seek(0); return }
            if !self.loop, self.advanceLocalAudio(by: 1, wrapping: true) { return }
            self.seek(0)
            if self.loop { self.play() } else { self.pause() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let raw = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (event.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            self?.handleInterruption(began: type == .began,
                shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] event in
            if (event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.endTemporaryRate()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.setBackgrounded(true)
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.sleepTimer.refresh()
            self?.setBackgrounded(false)
        }.store(in: &observations)
        installRemoteControls()
    }

    static func validRate(_ value: Float) -> Bool { value.isFinite && (0.5...16).contains(value) }

    static func prefersLandscape(width: CGFloat, height: CGFloat) -> Bool {
        width.isFinite && height.isFinite && height > 0 && width > height * 1.1
    }

    func open(url: URL, title: String? = nil, pageURL: URL? = nil, asset: AVURLAsset? = nil, webView: WKWebView? = nil, reservation: UUID? = nil, persistPosition: Bool? = nil, downloadSource: DownloadPlaybackSource? = nil, startAt: Double? = nil, autoplay: Bool = true, initialRate: Float? = nil) {
        if let reservation, !ownsPreparation(reservation) { return }
        let audioOnly = downloadSource?.webMediaContext?.resource.kind == .audio || FileVideoEpisodes.isAudio(url.path)
        webMediaContext = downloadSource?.webMediaContext.flatMap { $0.resource.kind == .video ? $0 : nil }
        cancelSouloCompatibilityCheck()
        if let extended = soulo { soulo = nil; extended.stop(deactivateAudioSession: false) }
        if !localAudioPlaylist.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) { setLocalAudioPlaylist([]) }
        preparation = UUID()
        configureIfNeeded()
        savePosition()
        endTemporaryRate()
        clearTemporaryRateFeedback()
        interruptedGeneration = nil
        playbackObservationTask?.cancel(); startupWarning = nil; playbackStalled = false; videoLoading = nil
        videoCacheProgress = .init()
        generation = UUID()
        player.pause()
        sourceWebView = webView
        persistsPosition = persistPosition ?? webView?.configuration.websiteDataStore.isPersistent ?? true
        wantsPlayback = autoplay
        // Pause page media only when explicitly handing this page's media to the player.
        webView?.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(e=>e.pause()); true;", completionHandler: nil)
        self.url = url
        self.title = title?.isEmpty == false ? title! : url.lastPathComponent
        RecentLocalPlaybackStore.shared.beginPlayback(url: url,
            persistPosition: persistsPosition && !UserDefaults.standard.bool(forKey: "is_incognito"))
        self.pageURL = pageURL
        #if SOULO_ACCEPTANCE
        DeviceAcceptanceRun.shared.recordMediaPlayback(stage: "native", url: url, pageURL: pageURL,
            userAgent: webView?.customUserAgent, cookies: 0)
        #endif
        let savedRate = UserDefaults.standard.float(forKey: "media.rate")
        if let initialRate, Self.validRate(initialRate) { rate = initialRate }
        else if Self.validRate(savedRate) { rate = savedRate }
        elapsed = 0; duration = 0; error = nil; lastSavedSecond = -1
        pendingSeek = nil; observedNativeTime = 0
        latestSeekID = nil
        hasVideo = false
        videoIsLandscape = false
        mirrored = false
        updateScreenAwake()
        let playbackAsset: AVURLAsset
        if let asset {
            playbackAsset = asset
        } else if url.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
            do {
                playbackAsset = try OfflineHLSReference.playableAsset(for: url)
            } catch {
                player.replaceCurrentItem(with: nil)
                retainedDownloadSource = nil
                self.error = ToolText.text("media_unavailable")
                return
            }
        } else if url.pathExtension.lowercased() == "movpkg" {
            do {
                playbackAsset = try OfflineHLSReference.playablePackage(at: url)
            } catch {
                player.replaceCurrentItem(with: nil)
                retainedDownloadSource = nil
                self.error = ToolText.text("media_unavailable")
                return
            }
        } else {
            playbackAsset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: playbackAsset)
        // Preserve pitch across the full speed range. The spectral algorithm also
        // avoids the observed time-domain clock stall when starting at 0.5×.
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        retainedDownloadSource = downloadSource
        let cacheTransfer = HLSPlaybackBridge.transfer(for: playbackAsset) ?? ProgressiveVideoPlaybackBridge.transfer(for: playbackAsset)
        let onlineVideo = VideoLoadingStatus.isOnline(playbackAsset.url) && !url.isFileURL
            && !(downloadSource?.resourceLease is TorrentPlaybackLease)
        let observationStart = ContinuousClock.now
        let token = generation
        playbackObservationTask = Task { @MainActor [weak self, weak item] in
            var watch = VideoStartupWatch()
            var progress = VideoProgressWatch()
            var transfer = VideoTransferMeter()
            _ = transfer.rate(totalBytes: 0, now: observationStart)
            var nextSample = observationStart.advanced(by: .seconds(1))
            while !Task.isCancelled {
                guard let self, let item, self.generation == token, self.player.currentItem === item, self.soulo == nil else { return }
                let itemReady = item.status == .readyToPlay
                let frameReady = itemReady && self.hasVideo
                    && self.pictureInPicture.surface?.playerLayer.isReadyForDisplay == true
                let audioReady = !self.hasVideo && self.webMediaContext?.resource.kind != .video
                    && itemReady && self.playing && self.elapsed > 0.1
                let active = UIApplication.shared.applicationState == .active
                    && (self.playerSurfaces > 0 || self.playerPages > 0)
                let warning = watch.update(now: Date.timeIntervalSinceReferenceDate,
                    requested: self.wantsPlayback && active && self.interruptedGeneration == nil, ready: frameReady || audioReady || self.player.isExternalPlaybackActive)
                let message = warning ? ToolText.text("media_start_timeout") : nil
                if self.startupWarning != message { self.startupWarning = message }
                if watch.completed, !onlineVideo { return }
                if onlineVideo, ContinuousClock.now >= nextSample {
                    nextSample = .now.advanced(by: .seconds(1))
                    let isVideo = self.hasVideo || self.webMediaContext?.resource.kind == .video
                    let buffered = isVideo && itemReady ? item.loadedTimeRanges.map(\.timeRangeValue) : []
                    let length = itemReady ? item.duration : CMTime.invalid
                    let complete = isVideo && VideoLoadingStatus.coversVideo(buffered, duration: length)
                    let bytes = cacheTransfer != nil || !isVideo || !itemReady ? nil : item.accessLog()?.events.reduce(nil as Int64?) { total, event in
                        let count = event.numberOfBytesTransferred
                        return count >= 0 ? (total ?? 0) + count : total
                    }
                    let loadStatus = cacheTransfer?.status ?? transfer.rate(totalBytes: bytes)
                    let loading: VideoLoadingStatus? = complete ? .complete : loadStatus
                    if self.videoLoading != loading { self.videoLoading = loading }
                    let cacheProgress = isVideo ? VideoCacheProgress(duration: length.seconds, buffered: buffered,
                        cache: cacheTransfer?.coverage ?? .init()) : .init()
                    if self.videoCacheProgress != cacheProgress { self.videoCacheProgress = cacheProgress }
                    let position = self.observedNativeTime
                    let stalled = progress.stalled(at: position,
                        requested: isVideo && watch.completed && active && self.wantsPlayback && self.pendingSeek?.isPending(actual: position) != true
                            && self.interruptedGeneration == nil && !self.player.isExternalPlaybackActive,
                        receivingData: loadStatus?.isTransferring == true)
                    if self.playbackStalled != stalled { self.playbackStalled = stalled }
                }
                do { try await Task.sleep(for: watch.completed ? .seconds(1) : .milliseconds(250)) } catch { return }
            }
        }
        Task {
            guard !audioOnly else { return }
            let tracks = try? await item.asset.loadTracks(withMediaType: .video)
            guard self.generation == token else { return }
            if let track = tracks?.first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform),
               self.generation == token {
                let orientedSize = size.applying(transform)
                // The presentation size is authoritative for adaptive streams.
                // Publish the video surface and its orientation together so a
                // quick fullscreen tap cannot use the old portrait default.
                let presented = item.presentationSize
                let width = presented.width > 0 ? presented.width : abs(orientedSize.width)
                let height = presented.height > 0 ? presented.height : abs(orientedSize.height)
                if width > 0, height > 0 {
                    self.videoIsLandscape = Self.prefersLandscape(width: width, height: height)
                    self.hasVideo = true
                    self.pauseVideoIfBackgrounded()
                    self.updateScreenAwake()
                }
            }
        }
        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard !audioOnly, let self, self.generation == token,
                      item.presentationSize.width > 0, item.presentationSize.height > 0 else { return }
                self.videoIsLandscape = Self.prefersLandscape(
                    width: item.presentationSize.width, height: item.presentationSize.height
                )
                self.hasVideo = true
                self.pauseVideoIfBackgrounded()
                self.updateScreenAwake()
            }
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed {
                    self.error = item.error?.localizedDescription ?? ToolText.text("media_unavailable")
                    self.updateScreenAwake()
                } else if item.status == .readyToPlay {
                    if onlineVideo, item.duration.isNumeric,
                       self.hasVideo || self.webMediaContext?.resource.kind == .video || item.presentationSize.width > 0 {
                        // Build up a forward buffer for on-demand video. Live playback keeps AVPlayer's own target.
                        item.preferredForwardBufferDuration = 30
                    }
                    self.updateTime(self.player.currentTime())
                    let saved = startAt ?? (self.persistsPosition ? UserDefaults.standard.double(forKey: Self.positionKey(url)) : 0)
                    if saved.isFinite, saved > 0, item.duration.seconds.isFinite,
                       startAt != nil || saved < item.duration.seconds - 2 {
                        // A decoder handoff is an explicit position, including
                        // the final seconds. Only saved history restarts there.
                        self.seek(min(saved, max(0, item.duration.seconds - 0.1)))
                    }
                    if self.rate > 2 && !item.canPlayFastForward { self.rate = 2 }
                    self.pauseVideoIfBackgrounded()
                    if self.wantsPlayback && self.interruptedGeneration == nil { self.play() }
                }
            }
        }
    }

    func play() {
        playbackIntentRevision &+= 1
        if let soulo { soulo.play(); return }
        guard player.currentItem != nil else { return }
        wantsPlayback = true
        pauseVideoIfBackgrounded()
        guard wantsPlayback else { return }
        interruptedGeneration = nil
        do {
            // Playback supports AirPlay implicitly. Explicit .allowAirPlay is
            // only valid for playAndRecord and can throw OSStatus -50 on device,
            // preventing player.play() even though seeking still renders frames.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            player.defaultRate = rate
            // Let AVPlayer prime its decoding/time-pitch pipeline even for a
            // local file. Bypassing readiness can leave a cold 0.5× clock stalled.
            player.play()
            updateScreenAwake()
        } catch { self.error = error.localizedDescription }
    }
    func pause() {
        playbackIntentRevision &+= 1
        if let soulo { soulo.pause(); return }
        #if DEBUG
        recordVideoPauseInput()
        #endif
        wantsPlayback = false; interruptedGeneration = nil
        player.pause(); playing = false
        endTemporaryRate(); savePosition(); updateNowPlaying()
        updateScreenAwake()
    }
    func setBackgrounded(_ backgrounded: Bool) {
        let enteringBackground = backgrounded && !isInBackground
        isInBackground = backgrounded
        if backgrounded {
            let context = enteringBackground && isPlaybackRequested && SharedVideoFullscreenHost.isPresenting ? webMediaContext : nil
            pauseVideoIfBackgrounded()
            if let context, !isPlaybackRequested {
                foregroundVideoResume = (context, generation, playbackIntentRevision)
            }
        } else {
            let resume = foregroundVideoResume
            foregroundVideoResume = nil
            if let resume, resume.context === webMediaContext, resume.generation == generation,
               resume.intent == playbackIntentRevision, SharedVideoFullscreenHost.isPresenting {
                play()
            }
            updateScreenAwake()
        }
    }
    /// Background audio and an explicitly opened PiP/AirPlay session continue.
    /// A normal video pause also clears playback intent so delayed readiness,
    /// seek completion or an interruption cannot restart it offscreen.
    func pauseVideoIfBackgrounded() {
        guard isInBackground, hasVideo || webMediaContext?.resource.kind == .video, isPlaybackRequested,
              !pictureInPicture.keepsPlaybackInBackground,
              !player.isExternalPlaybackActive else { return }
        pause()
    }
    func handleInterruption(began: Bool, shouldResume: Bool) {
        if let soulo { soulo.handleInterruption(began: began, shouldResume: shouldResume); return }
        if began {
            if interruptedGeneration == nil { interruptedGeneration = wantsPlayback ? generation : nil }
            endTemporaryRate(); player.pause(); savePosition(); updateNowPlaying()
            updateScreenAwake()
        } else {
            let resume = shouldResume && interruptedGeneration == generation && wantsPlayback
            interruptedGeneration = nil
            if resume { play() } else { wantsPlayback = false; updateScreenAwake() }
        }
    }
    func beginTemporaryRate() {
        // HLS can report no fast-forward support while still accepting 2.5×.
        // Apply the shared setting and read back AVPlayer's rate for feedback.
        let target = Float(VideoPlaybackPreferences.holdSpeed())
        guard gestureFeedback?.kind != .seek, !temporaryRate, hasVideo, wantsPlayback, player.rate > 0, player.rate < target else { return }
        rateBeforeTemporary = player.rate
        temporaryRate = true
        player.rate = target
        rateFeedbackDismissal?.cancel()
        temporaryRateFeedback = player.rate
        updateNowPlaying()
    }
    func endTemporaryRate() {
        guard temporaryRate else { return }
        temporaryRate = false
        let restoredRate = rateBeforeTemporary ?? rate
        rateBeforeTemporary = nil
        if player.rate > 0 { player.rate = restoredRate }
        temporaryRateFeedback = player.rate > 0 ? player.rate : nil
        rateFeedbackDismissal?.cancel()
        rateFeedbackDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            self?.temporaryRateFeedback = nil
        }
        updateNowPlaying()
    }
    private func clearTemporaryRateFeedback() {
        rateFeedbackDismissal?.cancel()
        rateFeedbackDismissal = nil
        temporaryRateFeedback = nil
    }
    func adjustBrightness(_ value: CGFloat, screen: UIScreen) {
        if adjustedScreen == nil { adjustedScreen = screen; originalBrightness = screen.brightness }
        screen.brightness = min(1, max(0, value))
        showAdjustment(.brightness, value: Double(screen.brightness))
    }
    func showAdjustment(_ kind: VideoGestureFeedback.Kind, value: Double) {
        endTemporaryRate()
        gestureFeedbackDismissal?.cancel()
        gestureFeedback = VideoGestureFeedback(kind: kind, value: min(1, max(0, value)))
    }
    func showSeekPreview(_ target: Double, start: Double) {
        endTemporaryRate(); gestureFeedbackDismissal?.cancel()
        seekPreview = target
        gestureFeedback = VideoGestureFeedback(kind: .seek, value: target, delta: target - start)
    }
    func outputVolumeChanged(_ value: Double) {
        guard value.isFinite, !isInBackground, UIApplication.shared.applicationState == .active else { return }
        if musicPlayerPages > 0, !hasVideo, url != nil {
            showAdjustment(.volume, value: value)
            finishAdjustment(after: .milliseconds(2200))
        } else if let soulo {
            guard soulo.hasVisibleSurface else { return }
            soulo.showAdjustment(.volume, value: value); soulo.finishAdjustment(after: .milliseconds(2200))
        } else if player.currentItem != nil, playerSurfaces > 0 || playerPages > 0 {
            gestureFeedbackDismissal?.cancel()
            gestureFeedback = VideoGestureFeedback(kind: .volume, value: min(1, max(0, value)))
            finishAdjustment(after: .milliseconds(2200))
        }
    }
    func finishAdjustment(after delay: Duration = .milliseconds(1500)) {
        seekPreview = nil
        gestureFeedbackDismissal?.cancel()
        gestureFeedbackDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.gestureFeedback = nil
        }
    }
    func updateFileReference(from oldURL: URL, to newURL: URL) {
        let defaults = UserDefaults.standard
        let oldCurrent = url
        let current = oldCurrent.flatMap { LibraryFileActions.relocated($0, from: oldURL, to: newURL) }
        let positions = Set(localAudioPlaylist + [oldCurrent].compactMap { $0 }).compactMap { old -> (URL, URL, Any)? in
            guard let next = LibraryFileActions.relocated(old, from: oldURL, to: newURL),
                  let value = defaults.object(forKey: Self.positionKey(old)) else { return nil }
            return (old, next, value)
        }
        let queue = localAudioPlaylist.map { LibraryFileActions.relocated($0, from: oldURL, to: newURL) ?? $0 }
        setLocalAudioPlaylist(queue)
        if let current {
            let time = elapsed, resume = wantsPlayback
            if let soulo { soulo.relocate(from: oldURL, to: newURL, logicalURL: current) }
            else {
                let oldAsset = player.currentItem?.asset as? AVURLAsset
                let nextAsset = oldAsset.flatMap { LibraryFileActions.relocated($0.url, from: oldURL, to: newURL) }.map { AVURLAsset(url: $0) } ?? oldAsset
                let retained = retainedDownloadSource
                let source = nextAsset.map { DownloadPlaybackSource(asset: $0, pageURL: pageURL, webView: sourceWebView, persistPosition: persistsPosition) }
                source?.resourceLease = retained
                open(url: current, title: current.lastPathComponent, asset: nextAsset, persistPosition: persistsPosition,
                     downloadSource: source, startAt: time, autoplay: resume)
            }
            setLocalAudioPlaylist(queue)
        }
        for (old, next, value) in positions {
            defaults.set(value, forKey: Self.positionKey(next)); defaults.removeObject(forKey: Self.positionKey(old))
        }
    }

    func toggle() {
        if let soulo { playbackIntentRevision &+= 1; soulo.togglePlayback(); return }
        // Intent is authoritative even while readiness, interruption or a seek
        // leaves the decoder clock stopped. A second tap cancels that Play.
        wantsPlayback ? pause() : play()
    }
    func stop() { stop(deactivateAudioSession: true) }
    func stop(deactivateAudioSession: Bool) {
        playbackObservationTask?.cancel(); playbackObservationTask = nil; startupWarning = nil; playbackStalled = false; videoLoading = nil
        videoCacheProgress = .init()
        cancelSouloCompatibilityCheck()
        if let extended = soulo { soulo = nil; extended.stop(deactivateAudioSession: false) }
        if deactivateAudioSession { setLocalAudioPlaylist([]); sleepTimer.cancel(); webMediaContext = nil }
        pause(); generation = UUID(); preparation = UUID(); itemObservation = nil; presentationSizeObservation = nil
        clearTemporaryRateFeedback()
        pictureInPicture.stop()
        gestureFeedbackDismissal?.cancel(); gestureFeedbackDismissal = nil; gestureFeedback = nil; seekPreview = nil
        if let originalBrightness { adjustedScreen?.brightness = originalBrightness }
        adjustedScreen = nil; originalBrightness = nil
        retainedPiPController?.player = nil; retainedPiPController = nil; retainedPiPDelegate = nil
        player.replaceCurrentItem(with: nil); url = nil; expanded = false
        playing = false; elapsed = 0; duration = 0; error = nil
        pendingSeek = nil; observedNativeTime = 0
        latestSeekID = nil
        retainedDownloadSource = nil
        hasVideo = false; videoIsLandscape = false
        updateScreenAwake()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if deactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    @discardableResult func setRate(_ value: Float) -> Bool {
        if let soulo {
            guard value.isFinite, (0.5...4).contains(value) else { return false }
            soulo.setRate(value); updateSouloState(soulo); return true
        }
        guard Self.validRate(value) else { return false }
        let rateUnavailable = ToolText.text("media_rate_unavailable")
        guard value <= 2 || player.currentItem?.canPlayFastForward == true else {
            error = rateUnavailable; return false
        }
        if error == rateUnavailable { error = nil }
        endTemporaryRate()
        rate = value
        UserDefaults.standard.set(value, forKey: "media.rate")
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
        clearTemporaryRateFeedback()
        updateNowPlaying(); return true
    }
    func captureFrame() async throws -> UIImage {
        guard let item = player.currentItem, hasVideo else { throw ReadingToolError.unsupported }
        let token = generation
        let mirror = mirrored
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 3840, height: 3840)
        let time = player.currentTime()
        let result = try await withTaskCancellationHandler {
            try await generator.image(at: time)
        } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        return UIImage(cgImage: result.image, scale: 1, orientation: mirror ? .upMirrored : .up)
    }
    func seek(_ seconds: Double) {
        if let soulo { soulo.seek(seconds); return }
        guard seconds.isFinite else { return }
        let limit = player.currentItem?.duration.seconds ?? 0
        guard limit.isFinite, limit > 0 else { return }
        let target = min(max(0, seconds), limit)
        let request = VideoPlaybackSeek(target: target), token = generation
        pendingSeek = request
        latestSeekID = request.id
        let cacheTransfer = (player.currentItem?.asset as? AVURLAsset).flatMap {
            HLSPlaybackBridge.transfer(for: $0) ?? ProgressiveVideoPlaybackBridge.transfer(for: $0)
        }
        let streamingTorrent = retainedDownloadSource?.resourceLease is TorrentPlaybackLease
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token, self.latestSeekID == request.id else { return }
                self.latestSeekID = nil
                guard finished else { self.pendingSeek = nil; return }
                guard self.wantsPlayback, self.interruptedGeneration == nil else { return }
                if streamingTorrent {
                    self.play()
                } else if cacheTransfer?.status == .complete, !self.isInBackground,
                          self.player.reasonForWaitingToPlay == .toMinimizeStalls {
                    let resumeRate = self.player.rate > 0 ? self.player.rate : self.rate
                    self.player.playImmediately(atRate: resumeRate)
                }
            }
        }
        elapsed = target
    }
    static func positionKey(_ url: URL) -> String {
        "media.position." + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func savePosition() {
        guard persistsPosition, let url, elapsed.isFinite else { return }
        guard !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else { return }
        UserDefaults.standard.set(elapsed, forKey: Self.positionKey(url))
        if !UserDefaults.standard.bool(forKey: "is_incognito") { RecentLocalPlaybackStore.shared.record(url: url, title: title) }
    }
    private func updateTime(_ time: CMTime) {
        guard soulo == nil, let item = player.currentItem, item.status == .readyToPlay, time.seconds.isFinite else { return }
        // Reading AVPlayerItem.currentTime synchronously while a remote asset
        // opens can block the main queue. Use AVPlayer's clock callback.
        let actual = max(0, time.seconds)
        observedNativeTime = actual
        if let pendingSeek, !pendingSeek.isPending(actual: actual) { self.pendingSeek = nil }
        elapsed = pendingSeek?.target ?? actual
        let length = item.duration.seconds
        duration = length.isFinite ? max(0, length) : 0
        if Int(elapsed) / 5 != lastSavedSecond {
            lastSavedSecond = Int(elapsed) / 5; savePosition(); updateNowPlaying()
        }
    }
    private func updateNowPlaying() {
        guard url != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? (soulo?.player?.rate ?? player.rate) : 0]
    }
    private func updateScreenAwake() {
        guard soulo == nil else { VideoScreenAwakeService.shared.setActive(false, owner: screenAwakeOwner); return }
        let shouldStayAwake = UIApplication.shared.applicationState == .active
            && url != nil && hasVideo && wantsPlayback
            && player.currentItem?.status != .failed
            && player.timeControlStatus != .paused
        VideoScreenAwakeService.shared.setActive(shouldStayAwake, owner: screenAwakeOwner)
    }
    private func installRemoteControls() {
        guard !remoteControlsInstalled else { return }; remoteControlsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in _ = self?.advanceLocalAudio(by: 1) }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in _ = self?.advanceLocalAudio(by: -1) }; return .success
        }
    }

    /// Both decoders publish to one session, so navigation away, the mini player
    /// and lock-screen controls retain the same source and playback clock.
    func adoptSoulo(_ playback: MatroskaPlayback, url: URL, title: String?, source: DownloadPlaybackSource?,
                    pageURL: URL?, systemAvailable: Bool, systemAvailabilityPending: Bool = false) {
        cancelSouloCompatibilityCheck()
        configureIfNeeded()
        if let old = soulo, old !== playback { soulo = nil; old.stop(deactivateAudioSession: false) }
        playbackObservationTask?.cancel(); playbackObservationTask = nil; startupWarning = nil; playbackStalled = false; videoLoading = nil
        videoCacheProgress = .init()
        soulo = playback; self.url = url
        mirrored = false
        webMediaContext = source?.webMediaContext.flatMap { $0.resource.kind == .video ? $0 : nil }
        persistsPosition = playback.persistsPosition
        self.title = title?.isEmpty == false ? title! : url.lastPathComponent
        self.pageURL = pageURL; retainedDownloadSource = source
        souloSystemAvailable = systemAvailable
        // A file can begin playing before the page finishes its native-decoder
        // check. Keep this local check with the session, so leaving the page
        // cannot freeze the mini-player's capability at its initial false value.
        if systemAvailabilityPending, url.isFileURL, let sourceURL = playback.sourceURL, sourceURL.isFileURL {
            souloSystemAvailabilityPending = true
            let asset = AVURLAsset(url: sourceURL)
            souloCompatibilityTask = Task { @MainActor [weak self, weak playback] in
                do {
                    let extended = try await TorrentFileDecoder.prefersExtended(asset, path: sourceURL.path)
                    try Task.checkCancellation()
                    guard let self, let playback, self.soulo === playback else { return }
                    self.updateSouloSystemAvailability(!extended, for: playback)
                } catch { }
            }
        }
        if !localAudioPlaylist.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) { setLocalAudioPlaylist([]) }
        updateSouloState(playback)
    }
    func updateSouloSystemAvailability(_ available: Bool, for playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        cancelSouloCompatibilityCheck()
        if souloSystemAvailable != available { souloSystemAvailable = available }
    }
    private func cancelSouloCompatibilityCheck() {
        souloCompatibilityTask?.cancel(); souloCompatibilityTask = nil
        if souloSystemAvailabilityPending { souloSystemAvailabilityPending = false }
    }
    func updateSouloState(_ playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        if elapsed != playback.elapsed { elapsed = playback.elapsed }
        if duration != playback.duration { duration = playback.duration }
        if playing != playback.playing { playing = playback.playing }
        if hasVideo != playback.hasVideo { hasVideo = playback.hasVideo }
        if rate != playback.rate { rate = playback.rate }
        wantsPlayback = playback.isPlaybackRequested
        if error != playback.error { error = playback.error }
        updateNowPlaying()
        pauseVideoIfBackgrounded()
    }
    func releaseSoulo(_ playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        cancelSouloCompatibilityCheck()
        soulo = nil; url = nil; playing = false; hasVideo = false; elapsed = 0; duration = 0
        retainedDownloadSource = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func setLocalAudioPlaylist(_ files: [URL]) {
        if localAudioPlaylist != files { localAudioPlaylist = files }
        let enabled = files.count > 1
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = enabled
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = enabled
    }
    @discardableResult func advanceLocalAudio(by offset: Int, wrapping: Bool = false) -> Bool {
        guard let index = localAudioIndex, localAudioPlaylist.count > 1 else { return false }
        let (destination, overflow) = index.addingReportingOverflow(offset)
        guard !overflow else { return false }
        if wrapping, destination == localAudioPlaylist.count { return playLocalAudio(at: 0) }
        if wrapping, destination == -1 { return playLocalAudio(at: localAudioPlaylist.count - 1) }
        return playLocalAudio(at: destination)
    }
    @discardableResult func playLocalAudio(at index: Int) -> Bool {
        guard localAudioPlaylist.indices.contains(index), index != localAudioIndex else { return false }
        let next = localAudioPlaylist[index]
        if let soulo {
            let files = localAudioPlaylist
            soulo.open(next, persistPosition: true, startAt: 0, title: next.lastPathComponent)
            setLocalAudioPlaylist(files)
        } else { open(url: next, title: next.lastPathComponent, persistPosition: true, startAt: 0) }
        return true
    }
    func souloEnded(_ playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        if sleepTimer.playbackEnded() { return }
        if loop { playback.seek(0); playback.play() }
        else { _ = advanceLocalAudio(by: 1, wrapping: true) }
    }
    func restoreSystemFromSoulo(pictureInPicture: Bool = false) {
        guard let playback = soulo, let url else { return }
        let time = playback.elapsed, resume = playback.isPlaybackRequested, title = self.title, page = pageURL
        let source = retainedDownloadSource ?? DownloadPlaybackSource(asset: AVURLAsset(url: playback.sourceURL ?? url),
            pageURL: page, webView: nil, persistPosition: playback.persistsPosition)
        let queue = localAudioPlaylist
        open(url: url, title: title, pageURL: page, asset: source.asset, webView: source.webView,
             persistPosition: source.persistsPosition, downloadSource: source, startAt: time, autoplay: resume)
        setLocalAudioPlaylist(queue)
        if pictureInPicture { self.pictureInPicture.requestStart() }
    }
}
