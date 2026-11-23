import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

/// Shared playback state for files, downloads and web media. Selects the decoder
/// for each source while keeping the same controls.
@MainActor final class MatroskaPlayback: NSObject, ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var buffering = true
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var hasVideo = true
    @Published private(set) var error: String?
    @Published private(set) var startupWarning: String?
    @Published private(set) var playbackStalled = false
    @Published private(set) var videoLoading: VideoLoadingStatus?
    @Published private(set) var videoCacheProgress = VideoCacheProgress()
    @Published var orientationError: String?
    @Published private(set) var gestureFeedback: VideoGestureFeedback?
    @Published private(set) var seekPreview: Double?
    @Published private(set) var rate: Float = {
        let saved = UserDefaults.standard.float(forKey: "media.rate")
        return MediaSession.validRate(saved) ? min(4, saved) : 1
    }()
    private var rateBeforeHold: Float?
    private var feedbackDismissal: Task<Void, Never>?
    private weak var adjustedScreen: UIScreen?
    private var originalBrightness: CGFloat?
    private(set) var player: (any PlaybackDecoder)?
    @Published private(set) var tracks: [PlaybackDecoderTrack] = []
    @Published private(set) var systemDecoderFailed = false
    private var preparation: Task<Void, Never>?
    private weak var surface: UIView?
    let drawable = UIView()
    private let awakeOwner = UUID()
    private var updates: Task<Void, Never>?
    private var resourceLease: AnyObject?
    private var requestContext: VideoPlaybackRequestContext?
    var preparedPlaybackSource: SouloMediaPlaybackSource? { resourceLease as? SouloMediaPlaybackSource }
    var playbackRequestContext: VideoPlaybackRequestContext? { requestContext }
    private var waitingForSurface = false
    private var wantsPlayback = true
    private(set) var sourceURL: URL?
    private weak var primarySurface: UIView?
    var hasVisibleSurface: Bool { primarySurface?.window != nil }
    var isPlaybackRequested: Bool { wantsPlayback }
    private var resumeAfterInterruption = false
    private var reportedEnd = false
    private(set) var persistsPosition = false
    private var lastSavedSecond = -1
    private var pendingStart: (seconds: Double, autoplay: Bool, explicit: Bool)?
    private var pendingSeek: VideoPlaybackSeek?

    func attach(_ view: UIView, primary: Bool = true) {
        if !primary, primarySurface?.window != nil { return }
        if primary { primarySurface = view }
        if drawable.superview !== view {
            drawable.removeFromSuperview()
            drawable.backgroundColor = .black
            drawable.isUserInteractionEnabled = false
            drawable.autoresizingMask = []
            view.addSubview(drawable)
        }
        surface = view
        layoutVideo()
        startWhenVisible()
    }
    func setMirrored(_ mirrored: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player?.layer.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
        CATransaction.commit()
    }
    private func layoutVideo() {
        guard let surface else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = player?.videoSize ?? .zero
        drawable.frame = size.width > 0 && size.height > 0
            ? AVMakeRect(aspectRatio: size, insideRect: surface.bounds) : surface.bounds
        if let layer = player?.layer {
            layer.bounds = drawable.bounds
            layer.position = CGPoint(x: drawable.bounds.midX, y: drawable.bounds.midY)
        }
        CATransaction.commit()
    }

    private func startWhenVisible() {
        guard waitingForSurface, let player else { return }
        if hasVideo {
            guard let surface, surface.window != nil, !surface.bounds.isEmpty else { return }
        }
        waitingForSurface = false
        if player.decodedFrameCount > 0, player.state != .buffering { buffering = false }
        if wantsPlayback { player.play() }
    }

    private func installDecoder(_ decoder: any PlaybackDecoder) {
        player?.layer.removeFromSuperlayer()
        player?.stop(retaining: resourceLease)
        player = decoder
        if let extended = decoder as? ExtendedPlaybackDecoder {
            extended.onFirstFrame = { [weak self, weak extended] in
                guard let self, let extended, self.player === extended, !self.waitingForSurface,
                      extended.state != .buffering else { return }
                self.buffering = false
            }
        }
        decoder.rate = rateBeforeHold == nil ? rate : Float(VideoPlaybackPreferences.holdSpeed())
        drawable.layer.addSublayer(decoder.layer)
        setMirrored(MediaSession.shared.mirrored)
        layoutVideo()
        waitingForSurface = true
        startWhenVisible()
    }

    func selectTrack(_ id: String?, kind: PlaybackDecoderTrack.Kind) {
        player?.selectTrack(id, kind: kind)
    }

    func open(_ url: URL, resourceLease: AnyObject? = nil, persistPosition: Bool = false,
              startAt: Double? = nil, autoplay: Bool = true, requestContext: VideoPlaybackRequestContext? = nil,
              title: String? = nil, originalURL: URL? = nil, systemAvailable: Bool = true, systemAvailabilityPending: Bool = false,
              forceReopen: Bool = false, initialRate: Float? = nil) {
        if !forceReopen, sourceURL == url, (player != nil || preparation != nil), error == nil, !reportedEnd {
            if !systemAvailabilityPending { MediaSession.shared.updateSouloSystemAvailability(systemAvailable, for: self) }
            return
        }
        stop(deactivateAudioSession: false)
        MediaSession.shared.stop(deactivateAudioSession: false)
        sourceURL = url
        self.resourceLease = resourceLease
        self.requestContext = requestContext
        #if SOULO_ACCEPTANCE
        DeviceAcceptanceRun.shared.recordMediaPlayback(stage: "soulo", url: url, pageURL: requestContext?.referrer,
            userAgent: requestContext?.userAgent, cookies: requestContext?.cookies.count ?? 0)
        #endif
        persistsPosition = persistPosition
        lastSavedSecond = -1
        let requested = startAt ?? (persistPosition ? UserDefaults.standard.double(forKey: MediaSession.positionKey(url)) : 0)
        let saved = requested.isFinite ? max(0, requested) : 0
        pendingStart = saved > 0 || !autoplay ? (saved, autoplay, startAt != nil) : nil
        wantsPlayback = autoplay
        if let initialRate, MediaSession.validRate(initialRate) { rate = min(4, initialRate) }
        reportedEnd = false
        systemDecoderFailed = false
        error = nil; elapsed = 0; duration = 0; buffering = true
        let prepared = resourceLease as? SouloMediaPlaybackSource
        let nativeSource = prepared?.native
        let resource = nativeSource?.webMediaContext?.resource
        let audioOnly = resource?.kind == .audio || FileVideoEpisodes.isAudio(originalURL?.path ?? url.path)
        hasVideo = !audioOnly
        let onlineVideo = VideoLoadingStatus.isOnline(url) && originalURL?.isFileURL != true
            && !(resourceLease is TorrentPlaybackLease) && !(nativeSource?.resourceLease is TorrentPlaybackLease)
        let progressiveCache = nativeSource.flatMap { ProgressiveVideoPlaybackBridge.transfer(for: $0.asset) }
        let cacheTransfer = progressiveCache ?? nativeSource.flatMap { HLSPlaybackBridge.transfer(for: $0.asset) }
        let hls = resource?.delivery == .hls || url.pathExtension.lowercased() == "m3u8"
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: hasVideo ? .moviePlayback : .default)
            try audio.setActive(true)
        } catch {
            self.error = error.localizedDescription
            buffering = false
            return
        }
        MediaSession.shared.adoptSoulo(self, url: originalURL ?? url, title: title,
            source: nativeSource, pageURL: requestContext?.referrer, systemAvailable: systemAvailable,
            systemAvailabilityPending: systemAvailabilityPending)
        preparation = Task { [weak self] in
            var options: [String: Any] = [:]
            if let requestContext {
                options[AVURLAssetHTTPUserAgentKey] = requestContext.userAgent
                options[AVURLAssetHTTPCookiesKey] = requestContext.cookies
            }
            let systemAsset: AVURLAsset?
            if let prepared { systemAsset = try? await prepared.systemAsset() }
            else { systemAsset = AVURLAsset(url: url, options: options) }
            let logicalPath = resource?.url.path ?? originalURL?.path ?? url.path
            var useNative = false
            if let systemAsset {
                if hls { useNative = true }
                else {
                    useNative = (try? await TorrentFileDecoder.prefersExtended(systemAsset, path: logicalPath)) == false
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.preparation = nil
            if useNative, let systemAsset {
                self.installDecoder(AVPlaybackDecoder(asset: systemAsset, online: onlineVideo))
            } else {
                self.installDecoder(ExtendedPlaybackDecoder(url: url, context: requestContext, hls: hls))
            }
        }
        observe(url: url, context: requestContext, hls: hls, online: onlineVideo, audioOnly: audioOnly, cacheTransfer: cacheTransfer)
    }

    private func observe(url: URL, context: VideoPlaybackRequestContext?, hls: Bool,
                         online: Bool, audioOnly: Bool, cacheTransfer: VideoPlaybackTransfer?) {
        updates = Task { [weak self] in
            var startup = VideoStartupWatch()
            var progress = VideoProgressWatch()
            var transfer = VideoTransferMeter()
            var nextSample: ContinuousClock.Instant = .now
            while !Task.isCancelled {
                guard let self else { return }
                let player = self.player
                player?.update()
                if !audioOnly, let hasVideo = player?.hasVideo, self.hasVideo != hasVideo { self.hasVideo = hasVideo }
                let frameReady = (player?.decodedFrameCount ?? 0) > 0
                let clock = player?.currentTime ?? 0
                let warning = startup.update(now: Date.timeIntervalSinceReferenceDate,
                    requested: self.wantsPlayback && self.hasVisibleSurface && UIApplication.shared.applicationState == .active,
                    ready: frameReady || (!self.hasVideo && clock > 0.1))
                let message = warning ? ToolText.text("media_start_timeout") : nil
                if self.startupWarning != message { self.startupWarning = message }
                // Probing a remote asset can wait for its first response. Count
                // that time as part of startup so a slow source gets feedback.
                guard let player else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                self.layoutVideo()
                let tracks = player.tracks
                if self.tracks != tracks { self.tracks = tracks }
                let playing = self.wantsPlayback && player.isPlaying
                if self.playing != playing { self.playing = playing }
                let failed = player.state == .failed
                let actual = failed && clock == 0 ? self.elapsed : clock
                let duration = failed && player.duration == 0 ? self.duration : player.duration
                if self.duration != duration { self.duration = duration }
                if let pending = self.pendingSeek, !pending.isPending(actual: actual) { self.pendingSeek = nil }
                let elapsed = self.pendingStart?.seconds ?? self.pendingSeek?.target ?? actual
                if self.elapsed != elapsed { self.elapsed = elapsed }
                if player is AVPlaybackDecoder, failed || (warning && self.hasVideo && playing && actual > 1 && !frameReady) {
                    if self.pendingStart == nil, actual > 0 {
                        self.pendingStart = (actual, self.wantsPlayback, true)
                    }
                    self.systemDecoderFailed = true
                    MediaSession.shared.updateSouloSystemAvailability(false, for: self)
                    self.pendingSeek = nil
                    startup = VideoStartupWatch()
                    self.installDecoder(ExtendedPlaybackDecoder(url: url, context: context, hls: hls))
                    continue
                }
                let buffering = self.wantsPlayback && self.error == nil
                    && (self.waitingForSurface || (player.state == .opening && !frameReady) || player.state == .buffering
                        || (self.hasVideo && !frameReady && !startup.completed && player.state != .ended))
                if self.buffering != buffering { self.buffering = buffering }
                if online, self.hasVideo, ContinuousClock.now >= nextSample {
                    nextSample = .now.advanced(by: .seconds(1))
                    let loading = cacheTransfer != nil ? cacheTransfer?.status
                        : (player as? ExtendedPlaybackDecoder)?.loadingRate ?? transfer.rate(totalBytes: player.receivedBytes)
                    if self.videoLoading != loading { self.videoLoading = loading }
                    let cacheProgress = VideoCacheProgress(duration: duration, buffered: player.loadedRanges,
                                                           cache: cacheTransfer?.coverage ?? .init())
                    if self.videoCacheProgress != cacheProgress { self.videoCacheProgress = cacheProgress }
                    let stalled = progress.stalled(at: actual,
                        requested: self.wantsPlayback && self.hasVisibleSurface && startup.completed
                            && UIApplication.shared.applicationState == .active && !self.resumeAfterInterruption
                            && self.pendingStart == nil && self.pendingSeek == nil && !self.reportedEnd,
                        receivingData: loading?.isTransferring == true)
                    if self.playbackStalled != stalled { self.playbackStalled = stalled }
                }
                if let pending = self.pendingStart, duration > 0, player.isSeekable {
                    self.pendingStart = nil
                    if pending.seconds > 0, pending.explicit || pending.seconds < duration - 2 {
                        self.seek(min(pending.seconds, max(0, duration - 0.1)))
                    }
                    if !pending.autoplay { player.pause() }
                }
                let second = Int(self.elapsed)
                if second > 0, second % 5 == 0, second != self.lastSavedSecond {
                    self.lastSavedSecond = second
                    self.savePosition()
                }
                if failed { self.error = ToolText.text("media_unavailable"); self.buffering = false }
                MediaSession.shared.updateSouloState(self)
                if player.state == .ended {
                    self.didEnd()
                    if self.player !== player { return }
                }
                VideoScreenAwakeService.shared.setActive(self.playing && self.hasVideo, owner: self.awakeOwner)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func togglePlayback() {
        guard player != nil || preparation != nil else { return }
        if wantsPlayback && !reportedEnd { pause() } else { play() }
    }

    private func didEnd() {
        guard !reportedEnd else { return }; reportedEnd = true
        wantsPlayback = false; playing = false; buffering = false
        VideoScreenAwakeService.shared.setActive(false, owner: awakeOwner)
        MediaSession.shared.updateSouloState(self)
        MediaSession.shared.souloEnded(self)
    }
    func play() {
        endTemporaryRate(); wantsPlayback = true; resumeAfterInterruption = false
        MediaSession.shared.pauseVideoIfBackgrounded()
        guard wantsPlayback else { return }
        if let pending = pendingStart { pendingStart = (pending.seconds, true, pending.explicit) }
        if reportedEnd, let sourceURL {
            open(sourceURL, resourceLease: resourceLease, persistPosition: persistsPosition,
                 startAt: 0, requestContext: requestContext, title: MediaSession.shared.title,
                 originalURL: MediaSession.shared.url, systemAvailable: MediaSession.shared.souloSystemAvailable,
                 systemAvailabilityPending: MediaSession.shared.souloSystemAvailabilityPending)
            return
        }
        if waitingForSurface { startWhenVisible() } else { player?.play() }
    }
    func pause() {
        #if DEBUG
        if MediaSession.shared.soulo === self { MediaSession.shared.recordVideoPauseInput() }
        #endif
        wantsPlayback = false; resumeAfterInterruption = false
        playing = false; buffering = false
        if let pending = pendingStart { pendingStart = (pending.seconds, false, pending.explicit) }
        player?.pause()
        endTemporaryRate(); savePosition()
        MediaSession.shared.updateSouloState(self)
    }
    func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = wantsPlayback
            endTemporaryRate(); player?.pause(); savePosition()
        } else {
            let resume = resumeAfterInterruption && wantsPlayback && shouldResume
            resumeAfterInterruption = false
            if resume { player?.play() } else { wantsPlayback = false }
        }
    }
    func retry() {
        guard let sourceURL else { return }
        let session = MediaSession.shared
        open(sourceURL, resourceLease: resourceLease, persistPosition: persistsPosition, startAt: duration > 0 ? elapsed : nil,
             requestContext: requestContext, title: session.title, originalURL: session.url, systemAvailable: session.souloSystemAvailable,
             systemAvailabilityPending: session.souloSystemAvailabilityPending, forceReopen: true)
    }
    func relocate(from old: URL, to target: URL, logicalURL: URL) {
        guard let sourceURL else { return }
        let next = LibraryFileActions.relocated(sourceURL, from: old, to: target) ?? sourceURL
        if next == sourceURL {
            MediaSession.shared.adoptSoulo(self, url: logicalURL, title: logicalURL.lastPathComponent,
                source: (resourceLease as? SouloMediaPlaybackSource)?.native, pageURL: requestContext?.referrer, systemAvailable: true)
        } else {
            open(next, resourceLease: resourceLease, persistPosition: persistsPosition,
                 startAt: elapsed, autoplay: wantsPlayback, requestContext: requestContext,
                 title: logicalURL.lastPathComponent, originalURL: logicalURL)
        }
    }
    func beginTemporaryRate() {
        let target = Float(VideoPlaybackPreferences.holdSpeed())
        guard gestureFeedback?.kind != .seek, let player, player.isPlaying, player.rate < target, rateBeforeHold == nil else { return }
        feedbackDismissal?.cancel()
        rateBeforeHold = player.rate
        player.rate = target
        gestureFeedback = VideoGestureFeedback(kind: .rate, value: Double(target))
    }
    func endTemporaryRate() {
        if let rateBeforeHold { player?.rate = rateBeforeHold }
        rateBeforeHold = nil
        if gestureFeedback?.kind == .rate { gestureFeedback = nil }
    }
    func setRate(_ value: Float) {
        guard value.isFinite, (0.5...4).contains(value) else { return }
        endTemporaryRate()
        rate = value; player?.rate = value
        UserDefaults.standard.set(value, forKey: "media.rate")
    }
    func adjustBrightness(_ value: CGFloat, screen: UIScreen) {
        if adjustedScreen == nil { adjustedScreen = screen; originalBrightness = screen.brightness }
        let value = min(1, max(0, value))
        screen.brightness = value
        showAdjustment(.brightness, value: Double(value))
    }
    func showAdjustment(_ kind: VideoGestureFeedback.Kind, value: Double) {
        feedbackDismissal?.cancel()
        gestureFeedback = VideoGestureFeedback(kind: kind, value: min(1, max(0, value)))
    }
    func showSeekPreview(_ target: Double, start: Double) {
        endTemporaryRate(); feedbackDismissal?.cancel()
        seekPreview = target
        gestureFeedback = VideoGestureFeedback(kind: .seek, value: target, delta: target - start)
    }
    func finishAdjustment(after delay: Duration = .milliseconds(1500)) {
        seekPreview = nil
        feedbackDismissal?.cancel()
        feedbackDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.gestureFeedback = nil
        }
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        pendingSeek = VideoPlaybackSeek(target: target)
        elapsed = target
        guard player?.isSeekable == true else {
            pendingStart = (target, wantsPlayback, true)
            return
        }
        player?.seek(to: target)
    }
    func stop(deactivateAudioSession: Bool = true) {
        startupWarning = nil; playbackStalled = false; videoLoading = nil
        videoCacheProgress = .init()
        savePosition()
        endTemporaryRate()
        feedbackDismissal?.cancel(); feedbackDismissal = nil; gestureFeedback = nil; seekPreview = nil
        if let originalBrightness { adjustedScreen?.brightness = originalBrightness }
        adjustedScreen = nil; originalBrightness = nil
        let hadPlayer = player != nil || preparation != nil
        waitingForSurface = false
        wantsPlayback = false
        preparation?.cancel(); preparation = nil
        updates?.cancel(); updates = nil
        player?.layer.removeFromSuperlayer()
        player?.stop(retaining: resourceLease)
        player = nil
        if !tracks.isEmpty { tracks = [] }
        playing = false; buffering = false
        VideoScreenAwakeService.shared.setActive(false, owner: awakeOwner)
        resourceLease = nil
        requestContext = nil
        sourceURL = nil
        pendingStart = nil
        pendingSeek = nil
        MediaSession.shared.releaseSoulo(self)
        if deactivateAudioSession && hadPlayer && !MediaSession.shared.playing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    private func savePosition() {
        guard persistsPosition, let sourceURL, elapsed.isFinite, elapsed > 0 else { return }
        guard !sourceURL.isFileURL || FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        UserDefaults.standard.set(elapsed, forKey: MediaSession.positionKey(sourceURL))
        if !UserDefaults.standard.bool(forKey: "is_incognito") { RecentLocalPlaybackStore.shared.record(url: sourceURL, title: MediaSession.shared.title) }
    }
    deinit { preparation?.cancel(); updates?.cancel(); feedbackDismissal?.cancel() }
}

final class MatroskaVideoSurface: UIView, UIGestureRecognizerDelegate {
    weak var playback: MatroskaPlayback?
    var primary = true
    var tapped: (() -> Void)? {
        didSet {
            let enabled = tapped != nil
            if tapRecognizer?.isEnabled != enabled { tapRecognizer?.isEnabled = enabled }
            if doubleTapRecognizer?.isEnabled != enabled { doubleTapRecognizer?.isEnabled = enabled }
        }
    }
    private var tapRecognizer: UITapGestureRecognizer?
    private var doubleTapRecognizer: UITapGestureRecognizer?
    private var lastDoubleTap: CFTimeInterval = 0
    private var verticalGesture: VideoVerticalGestureHandler?

    override init(frame: CGRect) {
        super.init(frame: frame)
        verticalGesture = VideoVerticalGestureHandler(in: self, enabled: { [weak self] in self?.playback?.hasVideo == true },
            brightness: { [weak self] value, screen in self?.playback?.adjustBrightness(value, screen: screen) },
            feedback: { [weak self] kind, value in self?.playback?.showAdjustment(kind, value: value) },
            position: { [weak self] in (self?.playback?.elapsed ?? 0, self?.playback?.duration ?? 0) },
            previewSeek: { [weak self] in self?.playback?.showSeekPreview($0, start: $1) },
            seek: { [weak self] in self?.playback?.seek($0) },
            ended: { [weak self] in self?.playback?.finishAdjustment() })
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedVideo))
        tap.isEnabled = false; tapRecognizer = tap
        tap.require(toFail: hold)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTappedVideo))
        doubleTap.numberOfTapsRequired = 2; doubleTap.isEnabled = false
        doubleTap.name = "SouloInlinePlaybackDoubleTap"
        doubleTapRecognizer = doubleTap; addGestureRecognizer(doubleTap)
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { playback?.attach(self, primary: primary) }
        else { playback?.endTemporaryRate() }
        Task { @MainActor in MediaSession.shared.objectWillChange.send() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil { playback?.attach(self, primary: primary) }
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { playback?.beginTemporaryRate() }
        else if [.ended, .cancelled, .failed].contains(gesture.state) { playback?.endTemporaryRate() }
    }
    @objc private func tappedVideo() {
        if CACurrentMediaTime() - lastDoubleTap > 0.25 { tapped?() }
    }
    @objc private func doubleTappedVideo() {
        lastDoubleTap = CACurrentMediaTime()
        playback?.togglePlayback()
    }

}

struct MatroskaSurface: UIViewRepresentable {
    @ObservedObject var playback: MatroskaPlayback
    var onTap: (() -> Void)?
    var primary = true
    func makeUIView(context: Context) -> MatroskaVideoSurface {
        let view = MatroskaVideoSurface(frame: .zero)
        view.backgroundColor = .black
        view.accessibilityIdentifier = "media.mkv.preview"
        view.playback = playback
        view.primary = primary
        view.tapped = onTap
        return view
    }
    func updateUIView(_ view: MatroskaVideoSurface, context: Context) {
        view.playback = playback
        view.tapped = onTap
        if view.window != nil { playback.attach(view, primary: primary) }
    }
}

struct FileVideoEpisode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct FileVideoPlaylist {
    struct Source: Equatable { let id: String; let title: String }
    let episodes: [FileVideoEpisode]
    let selectedID: String
    var sources: [Source] = []
    var selectedSourceID: String?
    var selectSource: ((String) -> Void)?
    var asynchronous = false
    var resolvingID: String?
    var failure: String?
    var retry: (() -> Void)? = nil
    var select: (String) -> Void
}

struct FileVideoOptions: Equatable {
    var usesSystem: Bool
    var systemAvailable: Bool
    var systemAvailabilityPending = false
    var playlist: FileVideoPlaylist?
    var requestAirPlay: ((Double, Bool) -> Void)?
    var requestPictureInPicture: ((Double, Bool) -> Void)?
    var download: (() -> Void)?
    var downloadIsVideo = true
    var airPlayPresentation: Binding<Bool>?
    var fullscreenChanged: ((Bool) -> Void)?
    var closePlayback: ((VideoFullscreenDismissal) -> Void)?
    var showsEpisodesOnAppear = false
    var fullscreenOnly = false
    var initialFullscreenLandscape: Bool?
    var shareURL: URL?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usesSystem == rhs.usesSystem && lhs.systemAvailable == rhs.systemAvailable
            && lhs.systemAvailabilityPending == rhs.systemAvailabilityPending
            && lhs.playlist?.selectedID == rhs.playlist?.selectedID
            && lhs.playlist?.episodes == rhs.playlist?.episodes
            && lhs.playlist?.sources == rhs.playlist?.sources
            && lhs.playlist?.selectedSourceID == rhs.playlist?.selectedSourceID
            && lhs.playlist?.resolvingID == rhs.playlist?.resolvingID
            && lhs.playlist?.failure == rhs.playlist?.failure
            && (lhs.playlist?.retry != nil) == (rhs.playlist?.retry != nil)
            && (lhs.requestAirPlay != nil) == (rhs.requestAirPlay != nil)
            && (lhs.requestPictureInPicture != nil) == (rhs.requestPictureInPicture != nil)
            && (lhs.download != nil) == (rhs.download != nil)
            && lhs.downloadIsVideo == rhs.downloadIsVideo
            && (lhs.airPlayPresentation != nil) == (rhs.airPlayPresentation != nil)
            && (lhs.closePlayback != nil) == (rhs.closePlayback != nil)
            && lhs.showsEpisodesOnAppear == rhs.showsEpisodesOnAppear
            && lhs.fullscreenOnly == rhs.fullscreenOnly
            && lhs.initialFullscreenLandscape == rhs.initialFullscreenLandscape
            && lhs.shareURL == rhs.shareURL
    }
}

struct FileVideoMenus: View {
    let rate: Float
    let playbackState: () -> (time: Double, playing: Bool)
    let setRate: (Float) -> Void
    var options: FileVideoOptions?
    var videoLoading: VideoLoadingStatus?
    var showEpisodes: (() -> Void)?
    var menuInteraction: ((Bool) -> Void)?
    var interaction: (() -> Void)?
    @State private var showMirroringHelp = false
    @State private var speedPresented = false
    private var loadingText: String? {
        switch videoLoading {
        case .rate(let bytes): ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s"
        case .complete: ToolText.text("media_load_complete")
        case nil: nil
        }
    }
    private var rateRows: some View {
        VStack(spacing: 0) {
            ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4], id: \.self) { value in
                Button { setRate(value); speedPresented = false; interaction?() } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(rate == value ? 1 : 0).frame(width: 20)
                        Text(String(format: "%g×", value)); Spacer()
                    }.padding(.horizontal, 16).frame(height: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("media.file.rate.\(value)")
            }
        }.padding(.vertical, 6)
    }
    var body: some View {
        HStack(spacing: 8) {
            Button { speedPresented.toggle() } label: {
                Label(String(format: "%g×", rate), systemImage: "speedometer")
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(ToolText.text("video_speed"))
            .accessibilityValue(String(format: "%g×", rate))
            .accessibilityIdentifier("media.file.speed")
            .videoMenuPopover(isPresented: $speedPresented, arrowEdge: .bottom) {
                ViewThatFits(in: .vertical) {
                    rateRows
                    ScrollView { rateRows }
                        .accessibilityIdentifier("media.file.speed.options")
                }.frame(width: 180).frame(maxHeight: 280).buttonStyle(.plain)
            }
            .onCompatibleChange(of: speedPresented) { _, shown in menuInteraction?(shown) }
            if let loadingText {
                Text(loadingText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("media.video.loading")
            }
            Spacer(minLength: 0)
            if let playlist = options?.playlist, playlist.episodes.count > 1 || playlist.sources.count > 1 {
                Button { showEpisodes?(); interaction?() } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(ToolText.text("episodes"), systemImage: "list.bullet")
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "list.bullet").frame(width: 44)
                    }.frame(minHeight: 44)
                }
                .accessibilityLabel(ToolText.text("episodes"))
                .accessibilityIdentifier("media.file.episodes")
            }
            if let options {
                if !options.usesSystem {
                    Button {
                        if let request = options.requestAirPlay, options.systemAvailable {
                            let state = playbackState(); request(state.time, state.playing)
                        } else { showMirroringHelp = true }
                    } label: {
                        Image(systemName: "airplayvideo").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("AirPlay")
                    .accessibilityIdentifier("media.file.airplay")
                }
            }
        }
        .font(.subheadline.weight(.medium)).buttonStyle(.borderless)
        .alert("AirPlay", isPresented: $showMirroringHelp) {
            Button(ToolText.text("done"), role: .cancel) {}
        } message: { Text(ToolText.text("media_airplay_mirroring_hint")) }
    }
}

struct MatroskaPlayerView: View {
    @AppStorage(VideoPlaybackPreferences.showsWebDownloadControlsKey) private var showsVideoDownloadControls = true
    let url: URL
    var resourceLease: AnyObject?
    var requestContext: VideoPlaybackRequestContext?
    var title: String?
    var persistPosition = true
    var startAt: Double?
    var autoplay = true
    var initialRate: Float?
    var options: FileVideoOptions?
    var startsFullscreen = false
    var audioOnly = false
    @StateObject private var playback = MatroskaPlayback()
    @StateObject private var controls = VideoControlsVisibility()
    @State private var expanded = false
    @State private var startedFullscreen = false
    @State private var leavingPlayback = false
    @State private var episodesVisible = false
    @State private var settingsVisible = false
    private var showsMusic: Bool { audioOnly || FileVideoEpisodes.isAudio(options?.shareURL?.path ?? url.path) }
    private var playbackOptions: FileVideoOptions? {
        guard var options else { return nil }
        if playback.systemDecoderFailed {
            options.systemAvailable = false
            options.systemAvailabilityPending = false
        }
        if !playback.hasVideo { options.requestPictureInPicture = nil }
        if let request = options.requestAirPlay {
            options.requestAirPlay = { time, _ in
                leavingPlayback = true
                request(time, playback.isPlaybackRequested)
                if MediaSession.shared.soulo === playback { playback.stop(deactivateAudioSession: false) }
            }
        }
        if let request = options.requestPictureInPicture {
            options.requestPictureInPicture = { time, _ in
                leavingPlayback = true
                request(time, playback.isPlaybackRequested)
                if MediaSession.shared.soulo === playback { playback.stop(deactivateAudioSession: false) }
            }
        }
        if let playlist = options.playlist {
            var value = playlist
            value.select = { id in
                guard id != playlist.selectedID else { return }
                if !playlist.asynchronous { playback.stop(deactivateAudioSession: false) }
                playlist.select(id)
            }
            options.playlist = value
        }
        return options
    }
    init(url: URL, resourceLease: AnyObject? = nil, requestContext: VideoPlaybackRequestContext? = nil,
         title: String? = nil, persistPosition: Bool = true, startAt: Double? = nil, autoplay: Bool = true,
         initialRate: Float? = nil, options: FileVideoOptions? = nil, startsFullscreen: Bool = false,
         audioOnly: Bool = false) {
        self.url = url; self.resourceLease = resourceLease; self.requestContext = requestContext
        self.title = title; self.persistPosition = persistPosition; self.startAt = startAt; self.autoplay = autoplay
        self.initialRate = initialRate
        self.options = options; self.startsFullscreen = startsFullscreen; self.audioOnly = audioOnly
        _expanded = State(initialValue: startsFullscreen)
        let current = MediaSession.shared.soulo
        _playback = StateObject(wrappedValue: current?.sourceURL == url ? current! : MatroskaPlayback())
    }
    var body: some View {
        Group {
            if showsMusic {
                MusicPlaybackView(url: options?.shareURL ?? url, title: title, options: playbackOptions,
                    download: options?.download, close: options?.closePlayback.map { action in { action(.exitFullscreen) } })
            } else {
                videoContent
            }
        }
        .task(id: url) {
            guard !Task.isCancelled, !leavingPlayback else { return }
            playback.open(url, resourceLease: resourceLease, persistPosition: persistPosition,
                          startAt: startAt, autoplay: autoplay, requestContext: requestContext, title: title,
                          originalURL: options?.shareURL, systemAvailable: options?.systemAvailable ?? true,
                          systemAvailabilityPending: options?.systemAvailabilityPending ?? false, initialRate: initialRate)
        }
        .onCompatibleChange(of: options, initial: true) { _, options in
            guard options?.systemAvailabilityPending != true, !playback.systemDecoderFailed else { return }
            MediaSession.shared.updateSouloSystemAvailability(options?.systemAvailable ?? true, for: playback)
        }
        .onDisappear { playback.endTemporaryRate() }
    }
    private var videoContent: some View {
        VStack(spacing: 0) {
            if expanded || options?.fullscreenOnly == true { Color.black }
            else {
                MatroskaVideoContent(playback: playback, url: url, resourceLease: resourceLease, onTap: controls.toggle)
                    .modifier(VideoTransportOverlay(visibility: controls, playing: playback.playing, buffering: playback.buffering,
                        identifier: "media.mkv.play", toggle: playback.togglePlayback,
                        seek: { playback.seek(playback.elapsed + $0) }))
            }
            if !expanded && options?.fullscreenOnly != true {
                MatroskaControls(playback: playback, options: playbackOptions, showEpisodes: { episodesVisible = true },
                                 expand: { episodesVisible = false; expanded = true }, interactionChanged: controls.interaction)
                    .padding(20).background(Color(UIColor.secondarySystemGroupedBackground))
            }
        }
        .modifier(FileVideoEpisodeDrawer(isPresented: $episodesVisible, playlist: playbackOptions?.playlist))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !expanded, options?.fullscreenOnly != true, let options = playbackOptions {
                    MatroskaOptionsMenu(options: options, playback: playback,
                        settingsVisible: $settingsVisible, showsVideoDownloadControls: showsVideoDownloadControls,
                        language: LanguageManager.shared.currentLanguage)
                        .equatable()
                }
            }
        }
        .background {
            MatroskaFullscreenPresenter(isPresented: $expanded, playback: playback, url: url,
                                       resourceLease: resourceLease, title: title, options: playbackOptions)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            if startsFullscreen, !startedFullscreen { startedFullscreen = true; expanded = true }
            controls.show()
        }
        .onCompatibleChange(of: expanded) { _, full in if full { startedFullscreen = true } }
        .sheet(isPresented: $settingsVisible) {
            NavigationStack { VideoSettingsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { settingsVisible = false } }
            } }
        }
    }
}

/// The native menu only changes when its available actions change. Decoding
/// ticks must not repeatedly replace and animate a menu the user is tapping.
private struct MatroskaOptionsMenu: View, Equatable {
    let options: FileVideoOptions
    let playback: MatroskaPlayback
    @Binding var settingsVisible: Bool
    let showsVideoDownloadControls: Bool
    let language: String
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.options == rhs.options && lhs.playback === rhs.playback
            && lhs.showsVideoDownloadControls == rhs.showsVideoDownloadControls && lhs.language == rhs.language
    }
    var body: some View {
        Menu {
            SouloPlaybackMenuOptions(playback: playback)
            PlaybackSleepTimerMenu()
            if let request = options.requestPictureInPicture {
                Button { request(playback.elapsed, playback.playing) } label: {
                    Label(ToolText.text("media_pip"), systemImage: "pip.enter")
                }.disabled(!options.systemAvailable)
                    .accessibilityIdentifier("media.picture-in-picture")
            }
            if let download = options.download, showsVideoDownloadControls || !options.downloadIsVideo {
                Button(action: download) { Label(LanguageManager.shared.localizedString("download"), systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("media.compact.download")
            }
            if let url = options.shareURL { ShareLink(item: url) { Label(ToolText.text("share_media"), systemImage: "square.and.arrow.up") } }
            Button { settingsVisible = true } label: { Label(LanguageManager.shared.localizedString("settings"), systemImage: "gearshape") }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityIdentifier("media.options")
    }
}

private struct SouloPlaybackMenuOptions: View {
    @ObservedObject var playback: MatroskaPlayback
    @ObservedObject private var session = MediaSession.shared

    var body: some View {
        trackMenu(.audio, title: ToolText.text("media_audio_tracks"), symbol: "waveform")
        trackMenu(.subtitle, title: ToolText.text("media_subtitles"), symbol: "captions.bubble")
        Toggle(isOn: $session.loop) {
            FullscreenVideoMenuLabel(title: ToolText.text("loop"), symbol: "repeat.1")
        }
        if playback.hasVideo {
            Toggle(isOn: Binding(get: { session.mirrored }, set: { value in
                session.mirrored = value
                playback.setMirrored(value)
            })) {
                FullscreenVideoMenuLabel(title: ToolText.text("media_mirror"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
        }
    }

    @ViewBuilder private func trackMenu(_ kind: PlaybackDecoderTrack.Kind, title: String, symbol: String) -> some View {
        let tracks = playback.tracks.filter { $0.kind == kind }
        if !tracks.isEmpty && (kind == .subtitle || tracks.count > 1) {
            Menu {
                if kind == .subtitle {
                    Button { playback.selectTrack(nil, kind: kind) } label: {
                        row(ToolText.text("media_track_off"), selected: !tracks.contains(where: \.selected))
                    }
                }
                ForEach(tracks) { track in
                    Button { playback.selectTrack(track.id, kind: kind) } label: { row(track.name, selected: track.selected) }
                }
            } label: { FullscreenVideoMenuLabel(title: title, symbol: symbol) }
        }
    }

    @ViewBuilder private func row(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }
}

private struct MatroskaVideoContent: View {
    @ObservedObject var playback: MatroskaPlayback
    let url: URL
    var resourceLease: AnyObject?
    var onTap: (() -> Void)?
    private var tapAction: (() -> Void)? {
        guard let onTap else { return nil }
        return {
            guard playback.gestureFeedback == nil else { return }
            onTap()
        }
    }
    var body: some View {
        MatroskaSurface(playback: playback, onTap: tapAction)
            .contentShape(Rectangle())
            .overlay {
                if !playback.hasVideo {
                    Image(systemName: "waveform").font(.system(size: 72, weight: .light))
                        .foregroundStyle(.white.opacity(0.55)).allowsHitTesting(false)
                }
            }
            .overlay {
                if let feedback = playback.gestureFeedback {
                    VideoGestureFeedbackView(feedback: feedback, identifier: "media.mkv.gesture.feedback")
                }
            }
    }
}

private struct MatroskaControls: View {
    @ObservedObject var playback: MatroskaPlayback
    var options: FileVideoOptions?
    var showEpisodes: (() -> Void)?
    var expand: (() -> Void)?
    var interactionChanged: ((Bool) -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            VideoPlaybackControls(elapsed: playback.seekPreview ?? playback.elapsed, duration: playback.duration, rate: playback.rate,
                playing: playback.playing, identifier: "media.mkv", options: options, videoLoading: playback.videoLoading,
                cacheProgress: playback.videoCacheProgress, showEpisodes: showEpisodes,
                expand: expand, interactionChanged: interactionChanged, seek: playback.seek, setRate: playback.setRate)
            if let error = playback.error ?? playback.startupWarning {
                VideoPlaybackStatus(message: error, identifier: "media.mkv.status", retry: playback.retry)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MatroskaFullscreenContent: View {
    @ObservedObject var playback: MatroskaPlayback
    let url: URL
    var resourceLease: AnyObject?
    var title: String?
    var options: FileVideoOptions?
    let close: () -> Void
    let exitFullscreen: () -> Void
    @StateObject private var controls = VideoControlsVisibility()
    @State private var automaticRetryURL: URL?

    var body: some View {
        MatroskaVideoContent(playback: playback, url: url, resourceLease: resourceLease)
            .modifier(VideoFullscreenChrome(visibility: controls, title: title ?? url.lastPathComponent,
                elapsed: playback.seekPreview ?? playback.elapsed, duration: playback.duration, rate: playback.rate,
                playing: playback.playing, buffering: playback.buffering || playback.playbackStalled,
                error: playback.error ?? playback.startupWarning ?? (playback.playbackStalled ? ToolText.text("media_playback_stalled") : nil),
                identifier: "media.mkv", closeIdentifier: "media.mkv.fullscreen.close", options: options, videoLoading: playback.videoLoading,
                cacheProgress: playback.videoCacheProgress, retry: playback.retry,
                close: close, exitFullscreen: exitFullscreen, toggle: playback.togglePlayback, seek: playback.seek, setRate: playback.setRate,
                holdBegan: playback.beginTemporaryRate, holdEnded: playback.endTemporaryRate) { SouloPlaybackMenuOptions(playback: playback) })
            .modifier(VideoOrientationErrorAlert(message: $playback.orientationError))
            .onCompatibleChange(of: playback.playbackStalled) { _, stalled in
                guard stalled, playback.isPlaybackRequested, options?.playlist?.resolvingID == nil,
                      let source = playback.sourceURL, automaticRetryURL != source else { return }
                automaticRetryURL = source
                playback.retry()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                if MediaSession.shared.webMediaContext != nil { automaticRetryURL = nil }
            }
    }
}

/// Keep the decoder and its drawable alive while UIKit presents or dismisses fullscreen.
private struct MatroskaFullscreenPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let playback: MatroskaPlayback
    let url: URL
    var resourceLease: AnyObject?
    var title: String?
    var options: FileVideoOptions?
    func makeCoordinator() -> Presenter { Presenter(playback: playback) }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.ready = { [weak host, weak presenter = context.coordinator] in
            if let host { presenter?.synchronize(host) }
        }
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.selection = $isPresented
        context.coordinator.url = url
        context.coordinator.resourceLease = resourceLease
        context.coordinator.title = title
        context.coordinator.options = options
        context.coordinator.synchronize(host)
    }
    static func dismantleUIViewController(_ host: Host, coordinator: Presenter) { coordinator.teardown() }
    final class Host: UIViewController {
        var ready: (() -> Void)?
        final class Anchor: UIView {
            var ready: (() -> Void)?
            override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { ready?() } }
        }
        override func loadView() {
            let anchor = Anchor()
            anchor.ready = { [weak self] in self?.ready?() }
            view = anchor
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); ready?() }
    }
    @MainActor final class Presenter {
        let playback: MatroskaPlayback
        var selection: Binding<Bool>?
        var url: URL?
        var resourceLease: AnyObject?
        var title: String?
        var options: FileVideoOptions?
        private let ownerID = UUID()
        private var sharedHost: SharedVideoFullscreenHost?
        private var presentedURL: URL?
        private var presentedOptions: FileVideoOptions?
        private var handingOff = false
        private var presentationRetry: Task<Void, Never>?
        init(playback: MatroskaPlayback) { self.playback = playback }
        func synchronize(_ host: Host) {
            guard selection?.wrappedValue == true else { dismiss(); return }
            if let sharedHost, sharedHost.owner == ownerID, let url {
                if presentedURL != url || presentedOptions != options {
                    sharedHost.update(owner: ownerID, content: AnyView(content(url: url)))
                    presentedURL = url; presentedOptions = options
                }
                return
            }
            guard let url, let window = SharedVideoFullscreenHost.window(for: host), let scene = window.windowScene else { return }
            let size = playback.player?.videoSize ?? .zero
            handingOff = false
            sharedHost = SharedVideoFullscreenHost.present(owner: ownerID, in: window, content: AnyView(content(url: url)),
                identifier: "media.mkv.fullscreen.player", landscape: options?.initialFullscreenLandscape
                    ?? VideoOrientation.fullscreenLandscape(video: size.width > size.height, scene: scene),
                onClose: { [weak self] reason in self?.finish(reason: reason) })
            if sharedHost == nil {
                if presentationRetry == nil {
                    presentationRetry = Task { @MainActor [weak self, weak host] in
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        self?.presentationRetry = nil
                        if let host { self?.synchronize(host) }
                    }
                }
                return
            }
            presentedURL = url; presentedOptions = options
        }
        private func content(url: URL) -> MatroskaFullscreenContent {
            var actions = options
            if let original = options {
                if let request = original.requestAirPlay {
                    actions?.requestAirPlay = { [weak self] time, playing in
                        original.fullscreenChanged?(true)
                        self?.handoff { request(time, playing) }
                    }
                }
                if let request = original.requestPictureInPicture {
                    actions?.requestPictureInPicture = { [weak self] time, playing in
                        original.fullscreenChanged?(true)
                        self?.handoff { request(time, playing) }
                    }
                }
                if let playlist = original.playlist {
                    var value = playlist
                    value.select = { id in
                        guard id != playlist.selectedID else { return }
                        original.fullscreenChanged?(true)
                        playlist.select(id)
                    }
                    actions?.playlist = value
                }
            }
            return MatroskaFullscreenContent(playback: playback, url: url, resourceLease: resourceLease,
                                            title: title, options: actions, close: { [weak self] in
                guard let self else { return }; self.sharedHost?.dismiss(owner: self.ownerID, reason: .closePlayback)
            }, exitFullscreen: { [weak self] in
                guard let self else { return }; self.sharedHost?.dismiss(owner: self.ownerID, reason: .exitFullscreen)
            })
        }
        func dismiss() {
            presentationRetry?.cancel(); presentationRetry = nil
            guard !handingOff else { return }
            sharedHost?.release(owner: ownerID)
        }
        private func handoff(_ action: () -> Void) {
            handingOff = true; sharedHost?.beginHandoff(owner: ownerID)
            selection?.wrappedValue = false
            action()
        }
        private func finish(reason: VideoFullscreenDismissal) {
            sharedHost = nil; presentedURL = nil; presentedOptions = nil; handingOff = false
            selection?.wrappedValue = false
            options?.fullscreenChanged?(false)
            if reason == .closePlayback || options?.fullscreenOnly == true { options?.closePlayback?(reason) }
        }
        func teardown() {
            presentationRetry?.cancel(); presentationRetry = nil
            selection = nil
            sharedHost?.release(owner: ownerID); sharedHost = nil
            playback.endTemporaryRate()
        }
    }
}

/// File and torrent video share the default player, episode menu and safe native fallback.
struct FileMediaPlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var path: String?
    var resourceLease: AnyObject?
    var persistPosition = true
    var playlist: FileVideoPlaylist?
    var initialSystemPlayer = false
    @State private var usingSystemForPictureInPicture = false
    @State private var preserveFullscreen = true
    @State private var selectedURL: URL?
    @State private var siblings: [URL] = []
    @State private var asset: AVURLAsset?
    @State private var preparedSource: SouloMediaPlaybackSource?
    @State private var resolvedURL: URL?
    @State private var resolvingURL: URL?
    @State private var episodeTask: Task<Void, Never>?
    @State private var episodeFailure: String?
    @State private var nativeAvailable: Bool?
    @State private var nativeFailed = false
    @State private var handoff: (time: Double, playing: Bool)?
    @State private var episodesVisible = false
    @State private var airPlayRequested = false
    @State private var airPlayActive = false
    @State private var pictureInPictureRequested = false
    @ObservedObject private var native = MediaSession.shared

    private var currentURL: URL { selectedURL ?? url }
    private var needsSystemPresentation: Bool { initialSystemPlayer || usingSystemForPictureInPicture || airPlayActive }
    private var currentPath: String { selectedURL?.path ?? path ?? url.path }
    private var isVideo: Bool { FileVideoEpisodes.isVideo(currentPath) }
    private var isAudio: Bool { FileVideoEpisodes.isAudio(currentPath) }
    private var usesSystem: Bool { needsSystemPresentation && nativeAvailable == true && !nativeFailed }
    private var videoPlaylist: FileVideoPlaylist? {
        guard isVideo || FileVideoEpisodes.isAudio(currentPath) else { return nil }
        if let playlist { return playlist }
        guard siblings.count > 1 else { return nil }
        return FileVideoPlaylist(episodes: siblings.map { FileVideoEpisode(id: $0.absoluteString, title: $0.lastPathComponent) },
                                 selectedID: currentURL.absoluteString, asynchronous: true,
                                 resolvingID: resolvingURL?.absoluteString, failure: episodeFailure) { id in
            guard let next = siblings.first(where: { $0.absoluteString == id }), next != currentURL else { return }
            episodeTask?.cancel(); resolvingURL = next; episodeFailure = nil
            episodeTask = Task { @MainActor in
                defer { if resolvingURL == next { resolvingURL = nil; episodeTask = nil } }
                do {
                    let prepared = try await prepare(next, path: next.path)
                    try Task.checkCancellation()
                    native.stop(deactivateAudioSession: false)
                    handoff = (0, true); nativeFailed = false
                    asset = prepared.asset; nativeAvailable = prepared.nativeAvailable
                    preparedSource = prepared.soulo; resolvedURL = next; selectedURL = next
                } catch is CancellationError { }
                catch { episodeFailure = error.localizedDescription }
            }
        }
    }
    private var options: FileVideoOptions {
        var result = FileVideoOptions(usesSystem: usesSystem, systemAvailable: nativeAvailable == true && !nativeFailed,
                         playlist: videoPlaylist)
        result.systemAvailabilityPending = currentURL.isFileURL && nativeAvailable == nil
        result.requestAirPlay = { time, _ in
            handoff = (time, native.isPlaybackRequested)
            airPlayRequested = true
            airPlayActive = true
            native.stop(deactivateAudioSession: false)
        }
        if MediaSession.shared.pictureInPicture.supported, isVideo {
            result.requestPictureInPicture = { time, _ in
                handoff = (time, native.isPlaybackRequested)
                pictureInPictureRequested = true
                native.stop(deactivateAudioSession: false)
                usingSystemForPictureInPicture = true
                airPlayActive = false
            }
        }
        result.fullscreenChanged = { preserveFullscreen = $0 }
        result.airPlayPresentation = $airPlayRequested
        result.shareURL = currentURL
        result.closePlayback = { reason in
            if reason == .closePlayback, native.url == currentURL { native.pause() }
            dismiss()
        }
        result.fullscreenOnly = true
        return result
    }
    var body: some View {
        ZStack {
            if (needsSystemPresentation && nativeAvailable == nil)
                || (["movpkg", "hls", "m3u8", OfflineHLSReference.fileExtension].contains(currentURL.pathExtension.lowercased()) && resolvedURL != currentURL) {
                ProgressView(ToolText.text("loading"))
            } else if usesSystem {
                MediaPlaybackContent(videoOptions: options, showEpisodes: { episodesVisible = true }, airPlayRequested: $airPlayRequested,
                                     initialFullscreen: !isAudio, fullscreenOnly: !isAudio, initialSystemPlayer: true,
                                     initialTitle: (currentPath as NSString).lastPathComponent, audioOnly: isAudio,
                                     onFullscreenClose: { dismiss() })
                    .task(id: resolvedURL) {
                        guard resolvedURL == currentURL else { return }
                        guard native.soulo != nil || native.url != currentURL || native.player.currentItem == nil else { return }
                        let source = DownloadPlaybackSource(asset: asset ?? AVURLAsset(url: currentURL), pageURL: nil,
                                                            webView: nil, persistPosition: persistPosition)
                        source.resourceLease = preparedSource ?? resourceLease
                        native.open(url: currentURL, title: (currentPath as NSString).lastPathComponent,
                                    asset: source.asset, persistPosition: persistPosition, downloadSource: source,
                                    startAt: handoff?.time, autoplay: handoff?.playing ?? true)
                        if pictureInPictureRequested {
                            pictureInPictureRequested = false
                            native.pictureInPicture.requestStart()
                        }
                    }
            } else {
                MatroskaPlayerView(url: preparedSource?.url ?? currentURL, resourceLease: preparedSource ?? resourceLease,
                                   title: (currentPath as NSString).lastPathComponent, persistPosition: persistPosition,
                                   startAt: handoff?.time, autoplay: handoff?.playing ?? true, options: options, startsFullscreen: preserveFullscreen)
            }
        }
        .modifier(FileVideoEpisodeDrawer(isPresented: $episodesVisible, playlist: videoPlaylist))
        .navigationTitle((currentPath as NSString).lastPathComponent)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(native.$error) { error in
            guard error != nil, usesSystem, native.url == currentURL,
                  native.player.currentItem?.status == .failed else { return }
            handoff = (native.elapsed, true)
            native.stop(deactivateAudioSession: false)
            nativeFailed = true
        }
        .task(id: currentURL) {
            guard resolvedURL != currentURL else { return }
            do {
                let prepared = try await prepare(currentURL, path: currentPath)
                try Task.checkCancellation()
                asset = prepared.asset; nativeAvailable = prepared.nativeAvailable
                preparedSource = prepared.soulo; resolvedURL = currentURL
            } catch is CancellationError { }
            catch { nativeAvailable = false; resolvedURL = currentURL; episodeFailure = error.localizedDescription }
        }
        .task(id: url) {
            guard isVideo || FileVideoEpisodes.isAudio(currentPath), playlist == nil, url.isFileURL else { return }
            let directory = url.deletingLastPathComponent()
            let activeDownloads = Set(DownloadManagerService.shared.downloads.filter {
                [.inProgress, .paused].contains($0.status)
            }.map { $0.localURL.standardizedFileURL })
            let result = await Task.detached {
                FileVideoEpisodes.localURLs(in: directory, excluding: activeDownloads, audio: FileVideoEpisodes.isAudio(url.path))
            }.value
            guard !Task.isCancelled else { return }
            siblings = result
            if FileVideoEpisodes.isAudio(url.path) { native.setLocalAudioPlaylist(result) }
        }
        .onReceive(native.$url) { next in
            guard FileVideoEpisodes.isAudio(currentPath), let next, siblings.contains(next), next != currentURL else { return }
            handoff = (0, true); resolvedURL = nil; preparedSource = nil; selectedURL = next
        }
    }

    private func prepare(_ url: URL, path: String) async throws -> (asset: AVURLAsset?, nativeAvailable: Bool, soulo: SouloMediaPlaybackSource?) {
        if native.url == url, let playback = native.soulo, let prepared = playback.preparedPlaybackSource {
            let asset = try? await prepared.systemAsset()
            return (asset, asset != nil && native.souloSystemAvailable, prepared)
        }
        if url.isFileURL, LocalHLSMedia.extensions.contains(url.pathExtension.lowercased())
            || (url.pathExtension.lowercased() == OfflineHLSReference.fileExtension
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) {
            let playlist = try await Task.detached { try LocalHLSMedia.playlistURL(for: url) }.value
            let asset = AVURLAsset(url: playlist)
            let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, persistPosition: persistPosition)
            source.resourceLease = resourceLease
            let soulo = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: url)
            let system = try? await soulo.systemAsset()
            return (system, system != nil, soulo)
        }
        if url.isFileURL, ["movpkg", OfflineHLSReference.fileExtension].contains(url.pathExtension.lowercased()) {
            let asset = try url.pathExtension.lowercased() == "movpkg"
                ? OfflineHLSReference.playablePackage(at: url) : OfflineHLSReference.playableAsset(for: url)
            let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, persistPosition: persistPosition)
            source.resourceLease = resourceLease
            let soulo = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: url)
            let system = try? await soulo.systemAsset()
            return (system, system != nil, soulo)
        }
        let candidate = AVURLAsset(url: url)
        let extended = try await TorrentFileDecoder.prefersExtended(candidate, path: path)
        if extended { candidate.cancelLoading() }
        return (extended ? nil : candidate, !extended, nil)
    }
}

enum FileVideoEpisodes {
    static func isVideo(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return FilePresentation.kind(forFileExtension: ext) == .video
    }
    static func isAudio(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "m4b", "aac", "wav", "flac", "ogg", "oga", "opus", "wma", "aiff", "aif", "ape", "alac", "amr"].contains(ext)
            || FilePresentation.kind(forFileExtension: ext) == .audio
    }
    /// Inspect only direct children. Never enumerate a library or follow a symlink.
    static func localURLs(in directory: URL, excluding: Set<URL> = [], audio: Bool = false) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        // iOS can return /private/var URLs for a directory supplied as /var.
        // Canonicalize only the parent; never follow an individual file link.
        let parent = directory.resolvingSymlinksInPath().standardizedFileURL
        let excluded = Set(excluding.map {
            $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                .appendingPathComponent($0.lastPathComponent).path
        })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? []
        return files.filter { file in
            guard (audio ? isAudio(file.path) : isVideo(file.path)), !excluded.contains(parent.appendingPathComponent(file.lastPathComponent).path),
                  let values = try? file.resourceValues(forKeys: keys) else { return false }
            return values.isSymbolicLink != true && (values.isRegularFile == true
                || (["movpkg", "soulohls", "hls", "m3u8"].contains(file.pathExtension.lowercased()) && values.isDirectory == true))
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    static func torrentFiles(_ job: TorrentDownloadJob, directory: String? = nil) -> [TorrentFileEntry] {
        job.files.filter { !($0.pad) && $0.size > 0 && job.selected.contains($0.index)
            && (directory == nil || ($0.path as NSString).deletingLastPathComponent == directory)
            && TorrentMediaFile.supports($0.path) && isVideo($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

struct TorrentFilePlaybackView: View {
    let id: UUID
    let file: TorrentFileEntry
    @State private var selectedFile: TorrentFileEntry?
    @State private var requestedFile: TorrentFileEntry?
    @State private var streamRequestID = UUID()
    @State private var url: URL?
    @State private var lease: TorrentPlaybackLease?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var currentFile: TorrentFileEntry { selectedFile ?? file }
    private var playlist: FileVideoPlaylist? {
        guard FileVideoEpisodes.isVideo(currentFile.path), let job = TorrentDownloadService.shared.job(id) else { return nil }
        let files = FileVideoEpisodes.torrentFiles(job, directory: (currentFile.path as NSString).deletingLastPathComponent)
        return FileVideoPlaylist(episodes: files.map { FileVideoEpisode(id: String($0.index), title: ($0.path as NSString).lastPathComponent) },
                                 selectedID: String(currentFile.index), asynchronous: true,
                                 resolvingID: requestedFile.map { String($0.index) }, failure: error) { index in
            guard let next = files.first(where: { String($0.index) == index }), next.index != currentFile.index else { return }
            error = nil; requestedFile = next; streamRequestID = UUID()
        }
    }
    var body: some View {
        Group {
            if let url {
                FileMediaPlaybackView(url: url, path: currentFile.path, resourceLease: lease,
                                      persistPosition: false, playlist: playlist)
            } else if let error {
                CompatibleUnavailableView(ToolText.text("media_unavailable"), systemImage: "play.slash", description: Text(error))
            } else { ProgressView(ToolText.text("loading")) }
        }
        .navigationTitle((currentFile.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("done")) { dismiss() } } }
        .task(id: streamRequestID) {
            let file = requestedFile ?? currentFile
            do {
                // Finish the old stream before opening the next episode. A late
                // deinit must not reset the new stream's torrent priorities.
                if let previous = lease { await previous.finish(); lease = nil }
                try Task.checkCancellation()
                let resolvedURL: URL
                let playbackLease: TorrentPlaybackLease?
                if let completed = TorrentDownloadService.shared.completedFileURL(id, file: file) {
                    resolvedURL = completed; playbackLease = nil
                } else {
                    let lease = try await TorrentDownloadService.shared.openStream(id, file: file)
                    playbackLease = lease; resolvedURL = lease.url
                }
                try Task.checkCancellation()
                self.lease = playbackLease; selectedFile = file; url = resolvedURL; requestedFile = nil
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; requestedFile = nil }
        }
    }
}

enum TorrentFileDecoder {
    static func prefersExtended(_ asset: AVURLAsset, path: String) async throws -> Bool {
        if (path as NSString).pathExtension.lowercased() == "mkv" { return true }
        return try await withTaskCancellationHandler {
            do {
                guard try await asset.load(.isPlayable) else { return true }
                // A .mp4 suffix alone does not establish native compatibility.
                // HEVC torrents often use hev1 instead of Apple's hvc1.
                for track in try await asset.loadTracks(withMediaType: .video) {
                    guard try await track.load(.isDecodable) else { return true }
                    for format in try await track.load(.formatDescriptions) {
                        if CMFormatDescriptionGetMediaSubType(format) == 0x68657631 { return true } // hev1
                    }
                }
                return false
            } catch {
                try Task.checkCancellation()
                return true // Native inspection failed; try the existing extended decoder.
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }
}
