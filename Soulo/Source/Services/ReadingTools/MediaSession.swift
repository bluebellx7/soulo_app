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
    @Published var retainedPiPController: AVPlayerViewController?
    var retainedPiPDelegate: AnyObject?
    let pictureInPicture = MediaPictureInPicture()
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var pageURL: URL?
    @Published private(set) var elapsed = 0.0
    private var pendingSeek: VideoPlaybackSeek?
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published var error: String?
    @Published var expanded = false
    @Published private(set) var hasVideo = false
    @Published private(set) var videoIsLandscape = false
    @Published var playerSurfaces = 0
    @Published var playerPages = 0
    @Published private(set) var soulo: MatroskaPlayback?
    private(set) var souloSystemAvailable = true
    private var localAudioPlaylist: [URL] = []
    private var remoteControlsInstalled = false
    @Published var loop = false
    @Published var mirrored = false
    @Published private(set) var rate: Float
    @Published private(set) var temporaryRate = false
    @Published private(set) var temporaryRateFeedback: Float?
    private var rateFeedbackDismissal: Task<Void, Never>?
    private var rateBeforeTemporary: Float?
    @Published private(set) var gestureFeedback: VideoGestureFeedback?
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
    var isPlaybackRequested: Bool { soulo?.isPlaybackRequested ?? wantsPlayback }
    private var persistsPosition = true
    private weak var sourceWebView: WKWebView?
    private var retainedDownloadSource: DownloadPlaybackSource?

    func playbackTransferSource() -> DownloadPlaybackSource? {
        guard let asset = player.currentItem?.asset as? AVURLAsset else { return nil }
        if let retainedDownloadSource, retainedDownloadSource.asset === asset { return retainedDownloadSource }
        return DownloadPlaybackSource(asset: asset, pageURL: pageURL, webView: sourceWebView, persistPosition: persistsPosition)
    }

    func deferDownloadPackageRemoval(for asset: AVURLAsset, at url: URL) -> Bool {
        guard let source = retainedDownloadSource, source.asset === asset,
              player.currentItem?.asset === asset else { return false }
        source.removePackageWhenReleased(url)
        return true
    }
    private let screenAwakeOwner = UUID()

    init() {
        let saved = UserDefaults.standard.float(forKey: "media.rate")
        rate = Self.validRate(saved) ? saved : 1
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        player.allowsExternalPlayback = true
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.updateTime(time) }
        }
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.soulo == nil else { return }
            self.playing = self.player.timeControlStatus == .playing && self.player.currentItem != nil
            self.updateScreenAwake()
            self.updateNowPlaying()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self, event.object as? AVPlayerItem === self.player.currentItem else { return }
            self.endTemporaryRate()
            if !self.loop, self.advanceLocalAudio(by: 1) { return }
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
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateScreenAwake()
        }.store(in: &observations)
        installRemoteControls()
    }

    static func validRate(_ value: Float) -> Bool { value.isFinite && (0.5...16).contains(value) }

    static func prefersLandscape(width: CGFloat, height: CGFloat) -> Bool {
        width.isFinite && height.isFinite && height > 0 && width > height * 1.1
    }

    func open(url: URL, title: String? = nil, pageURL: URL? = nil, asset: AVURLAsset? = nil, webView: WKWebView? = nil, reservation: UUID? = nil, persistPosition: Bool? = nil, downloadSource: DownloadPlaybackSource? = nil, startAt: Double? = nil, autoplay: Bool = true) {
        if let reservation, !ownsPreparation(reservation) { return }
        if let extended = soulo { soulo = nil; extended.stop(deactivateAudioSession: false) }
        if !localAudioPlaylist.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) { setLocalAudioPlaylist([]) }
        preparation = UUID()
        configureIfNeeded()
        savePosition()
        endTemporaryRate()
        clearTemporaryRateFeedback()
        interruptedGeneration = nil
        generation = UUID()
        player.pause()
        sourceWebView = webView
        persistsPosition = persistPosition ?? webView?.configuration.websiteDataStore.isPersistent ?? true
        wantsPlayback = autoplay
        // Pause page media only when explicitly handing this page's media to the player.
        webView?.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(e=>e.pause()); true;", completionHandler: nil)
        self.url = url
        self.title = title?.isEmpty == false ? title! : url.lastPathComponent
        self.pageURL = pageURL
        let savedRate = UserDefaults.standard.float(forKey: "media.rate")
        if Self.validRate(savedRate) { rate = savedRate }
        elapsed = 0; duration = 0; error = nil; lastSavedSecond = -1
        pendingSeek = nil
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
        let token = generation
        Task {
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
                    self.updateScreenAwake()
                }
            }
        }
        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token,
                      item.presentationSize.width > 0, item.presentationSize.height > 0 else { return }
                self.videoIsLandscape = Self.prefersLandscape(
                    width: item.presentationSize.width, height: item.presentationSize.height
                )
                self.hasVideo = true
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
                    self.updateTime(self.player.currentTime())
                    let saved = startAt ?? (self.persistsPosition ? UserDefaults.standard.double(forKey: Self.positionKey(url)) : 0)
                    if saved > 0, item.duration.seconds.isFinite, saved < item.duration.seconds - 2 { self.seek(saved) }
                    if self.rate > 2 && !item.canPlayFastForward { self.rate = 2 }
                    if self.wantsPlayback && self.interruptedGeneration == nil { self.play() }
                }
            }
        }
    }

    func play() {
        if let soulo { soulo.play(); return }
        guard player.currentItem != nil else { return }
        wantsPlayback = true
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
        if let soulo { soulo.pause(); return }
        wantsPlayback = false; interruptedGeneration = nil
        endTemporaryRate(); player.pause(); savePosition(); updateNowPlaying()
        updateScreenAwake()
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
        guard !temporaryRate, hasVideo, wantsPlayback, player.rate > 0, player.rate < target else { return }
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
    func finishAdjustment() {
        gestureFeedbackDismissal?.cancel()
        gestureFeedbackDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
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

    func toggle() { playing ? pause() : play() }
    func stop() { stop(deactivateAudioSession: true) }
    func stop(deactivateAudioSession: Bool) {
        if let extended = soulo { soulo = nil; extended.stop(deactivateAudioSession: false) }
        if deactivateAudioSession { setLocalAudioPlaylist([]) }
        pause(); generation = UUID(); preparation = UUID(); itemObservation = nil; presentationSizeObservation = nil
        clearTemporaryRateFeedback()
        pictureInPicture.stop()
        gestureFeedbackDismissal?.cancel(); gestureFeedbackDismissal = nil; gestureFeedback = nil
        if let originalBrightness { adjustedScreen?.brightness = originalBrightness }
        adjustedScreen = nil; originalBrightness = nil
        retainedPiPController?.player = nil; retainedPiPController = nil; retainedPiPDelegate = nil
        player.replaceCurrentItem(with: nil); url = nil; expanded = false
        playing = false; elapsed = 0; duration = 0; error = nil
        pendingSeek = nil
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
        guard value <= 2 || player.currentItem?.canPlayFastForward == true else {
            error = ToolText.text("media_rate_unavailable"); return false
        }
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
        let streamingTorrent = retainedDownloadSource?.resourceLease is TorrentPlaybackLease
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token, self.pendingSeek?.id == request.id else { return }
                if !finished { self.pendingSeek = nil }
                if finished, streamingTorrent, self.wantsPlayback, self.interruptedGeneration == nil { self.play() }
            }
        }
        elapsed = target
    }
    static func positionKey(_ url: URL) -> String {
        "media.position." + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func savePosition() {
        guard persistsPosition, let url, elapsed.isFinite else { return }
        UserDefaults.standard.set(elapsed, forKey: Self.positionKey(url))
    }
    private func updateTime(_ time: CMTime) {
        guard soulo == nil else { return }
        let current = player.currentTime().seconds
        let actual = current.isFinite ? max(0, current) : 0
        if let pendingSeek, !pendingSeek.isPending(actual: actual) { self.pendingSeek = nil }
        elapsed = pendingSeek?.target ?? actual
        let length = player.currentItem?.duration.seconds ?? 0
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
                    pageURL: URL?, systemAvailable: Bool) {
        configureIfNeeded()
        if let old = soulo, old !== playback { soulo = nil; old.stop(deactivateAudioSession: false) }
        soulo = playback; self.url = url
        persistsPosition = playback.persistsPosition
        self.title = title?.isEmpty == false ? title! : url.lastPathComponent
        self.pageURL = pageURL; retainedDownloadSource = source
        souloSystemAvailable = systemAvailable
        if !localAudioPlaylist.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) { setLocalAudioPlaylist([]) }
        updateSouloState(playback)
    }
    func updateSouloState(_ playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        elapsed = playback.elapsed; duration = playback.duration; playing = playback.playing
        hasVideo = playback.hasVideo; rate = playback.rate
        wantsPlayback = playback.isPlaybackRequested
        error = playback.error
        updateNowPlaying()
    }
    func releaseSoulo(_ playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        soulo = nil; url = nil; playing = false; hasVideo = false; elapsed = 0; duration = 0
        retainedDownloadSource = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func setLocalAudioPlaylist(_ files: [URL]) {
        localAudioPlaylist = files
        let enabled = files.count > 1
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = enabled
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = enabled
    }
    @discardableResult func advanceLocalAudio(by offset: Int) -> Bool {
        guard let url, let index = localAudioPlaylist.firstIndex(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }),
              localAudioPlaylist.indices.contains(index + offset) else { return false }
        let next = localAudioPlaylist[index + offset]
        if let soulo {
            let files = localAudioPlaylist
            soulo.open(next, persistPosition: true, startAt: 0, title: next.lastPathComponent)
            setLocalAudioPlaylist(files)
        } else { open(url: next, title: next.lastPathComponent, persistPosition: true, startAt: 0) }
        return true
    }
    func souloEnded(_ playback: MatroskaPlayback) {
        guard soulo === playback else { return }
        if loop { playback.seek(0); playback.play() }
        else { _ = advanceLocalAudio(by: 1) }
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
