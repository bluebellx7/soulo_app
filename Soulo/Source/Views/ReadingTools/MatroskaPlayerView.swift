import AVFoundation
import Combine
import MobileVLCKit
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

/// Decoder state for Soulo mode. Files, downloads and web media share controls;
/// compatible sources can switch to the system decoder in the same host.
@MainActor final class MatroskaPlayback: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var buffering = true
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var hasVideo = true
    @Published private(set) var error: String?
    @Published var orientationError: String?
    @Published private(set) var gestureFeedback: VideoGestureFeedback?
    @Published private(set) var rate: Float = {
        let saved = UserDefaults.standard.float(forKey: "media.rate")
        return MediaSession.validRate(saved) ? min(4, saved) : 1
    }()
    private var rateBeforeHold: Float?
    private var feedbackDismissal: Task<Void, Never>?
    private weak var adjustedScreen: UIScreen?
    private var originalBrightness: CGFloat?
    private(set) var player: VLCMediaPlayer?
    private weak var surface: UIView?
    private let drawable = UIView()
    private let awakeOwner = UUID()
    private var updates: Task<Void, Never>?
    private var resourceLease: AnyObject?
    private var requestContext: VideoPlaybackRequestContext?
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
    private var videoPresentationSize = CGSize.zero
    private var reportedVideoSize = CGSize.zero
    private var resolvedTrackSize = false

    func attach(_ view: UIView, primary: Bool = true) {
        if !primary, primarySurface?.window != nil { return }
        if primary { primarySurface = view }
        if drawable.superview !== view {
            drawable.removeFromSuperview()
            drawable.backgroundColor = .black
            // VLC's output may install its own recognizers. All video gestures
            // belong to our surface, including taps that reveal the exit button.
            drawable.isUserInteractionEnabled = false
            drawable.autoresizingMask = []
            view.addSubview(drawable)
        }
        surface = view
        layoutVideo()
        startWhenVisible()
    }
    private func layoutVideo() {
        guard let surface else { return }
        if let player, !resolvedTrackSize || reportedVideoSize != player.videoSize {
            reportedVideoSize = player.videoSize
            videoPresentationSize = player.videoSize
            if let tracks = player.media?.tracksInformation as? [[String: Any]],
               let track = tracks.first(where: { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo }),
               let width = track[VLCMediaTracksInformationVideoWidth] as? NSNumber,
               let height = track[VLCMediaTracksInformationVideoHeight] as? NSNumber,
               width.doubleValue > 0, height.doubleValue > 0 {
                let numerator = (track[VLCMediaTracksInformationSourceAspectRatio] as? NSNumber)?.doubleValue ?? 1
                let denominator = (track[VLCMediaTracksInformationSourceAspectRatioDenominator] as? NSNumber)?.doubleValue ?? 1
                let pixelAspect = numerator > 0 && denominator > 0 ? numerator / denominator : 1
                var size = CGSize(width: width.doubleValue * pixelAspect, height: height.doubleValue)
                let orientation = (track[VLCMediaTracksInformationVideoOrientation] as? NSNumber)?.intValue ?? 0
                // VLC's four transposed orientations exchange the output axes.
                if (4...7).contains(orientation) { size = CGSize(width: size.height, height: size.width) }
                videoPresentationSize = size; resolvedTrackSize = true
            }
        }
        // A paused GL frame does not repaint when UIKit resizes its view.
        // Keep the drawable itself at the video's display ratio so rotation
        // cannot stretch the last frame, including anamorphic/rotated media.
        let size = videoPresentationSize
        let frame = size.width > 0 && size.height > 0 ? AVMakeRect(aspectRatio: size, insideRect: surface.bounds) : surface.bounds
        if drawable.frame != frame { drawable.frame = frame }
    }
    private func startWhenVisible() {
        guard waitingForSurface, let player else { return }
        // Audio queues also advance after the originating page has gone away.
        // Only video output needs a mounted drawable before starting VLC.
        if hasVideo {
            guard let surface, surface.window != nil, !surface.bounds.isEmpty else { return }
        }
        waitingForSurface = false
        player.play()
    }
    func open(_ url: URL, resourceLease: AnyObject? = nil, persistPosition: Bool = false,
              startAt: Double? = nil, autoplay: Bool = true, requestContext: VideoPlaybackRequestContext? = nil,
              title: String? = nil, originalURL: URL? = nil, systemAvailable: Bool = true) {
        if sourceURL == url, player != nil, error == nil, !reportedEnd { return }
        stop(deactivateAudioSession: false)
        MediaSession.shared.stop(deactivateAudioSession: false)
        sourceURL = url
        self.resourceLease = resourceLease
        self.requestContext = requestContext
        persistsPosition = persistPosition
        lastSavedSecond = -1
        let requested = startAt ?? (persistPosition ? UserDefaults.standard.double(forKey: MediaSession.positionKey(url)) : 0)
        let saved = requested.isFinite ? max(0, requested) : 0
        pendingStart = saved > 0 || !autoplay ? (saved, autoplay, startAt != nil) : nil
        wantsPlayback = autoplay
        reportedEnd = false
        error = nil; elapsed = 0; duration = 0; buffering = true
        hasVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) != true
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            // Reuse VLCKit's library; passing per-player global options creates
            // another decoder library in addition to VLCMedia's shared one.
            let player = VLCMediaPlayer()
            self.player = player; player.drawable = drawable; player.delegate = self
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=1500")
            media.addOption(":no-video-title-show")
            try requestContext?.apply(to: media)
            player.media = media
            player.rate = rate
            waitingForSurface = true
            MediaSession.shared.adoptSoulo(self, url: originalURL ?? url, title: title,
                source: (resourceLease as? SouloMediaPlaybackSource)?.native,
                pageURL: requestContext?.referrer, systemAvailable: systemAvailable)
            startWhenVisible()
            updates = Task { [weak self] in
                var stoppedSince: ContinuousClock.Instant?
                var lastProgress = 0.0
                while !Task.isCancelled {
                    guard let self, let player = self.player else { return }
                    let playing = self.wantsPlayback && player.isPlaying && player.state != .ended && player.state != .stopped
                    if self.playing != playing { self.playing = playing }
                    let buffering = self.waitingForSurface || ((self.wantsPlayback || self.pendingStart != nil)
                        && !player.isPlaying && (player.state == .opening || player.state == .buffering))
                    if self.buffering != buffering { self.buffering = buffering }
                    let clock = max(0, Double(player.time.intValue) / 1000)
                    if playing { lastProgress = clock }
                    // VLC clears its clock on stop. Keep the last decoded
                    // position so an unexpected stop is still diagnosed.
                    let actual = player.state == .stopped && self.wantsPlayback && !self.reportedEnd ? lastProgress : clock
                    if let pending = self.pendingSeek, !pending.isPending(actual: actual) { self.pendingSeek = nil }
                    self.elapsed = self.pendingStart?.seconds ?? self.pendingSeek?.target ?? actual
                    let duration = max(0, Double(player.media?.length.intValue ?? 0) / 1000)
                    if self.duration != duration { self.duration = duration }
                    self.layoutVideo()
                    if let tracks = player.media?.tracksInformation as? [[String: Any]], !tracks.isEmpty {
                        let hasVideo = tracks.contains { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo }
                        if self.hasVideo != hasVideo { self.hasVideo = hasVideo }
                    }
                    if let pending = self.pendingStart, self.duration > 0, player.isSeekable {
                        self.pendingStart = nil
                        if pending.seconds > 0, pending.explicit || pending.seconds < self.duration - 2 {
                            self.seek(min(pending.seconds, max(0, self.duration - 0.1)))
                        }
                        if !pending.autoplay { player.pause() }
                    }
                    let second = Int(self.elapsed)
                    if second > 0, second % 5 == 0, second != self.lastSavedSecond {
                        self.lastSavedSecond = second; self.savePosition()
                    }
                    if player.state == .error { self.error = ToolText.text("media_unavailable"); self.buffering = false }
                    MediaSession.shared.updateSouloState(self)
                    if player.state == .ended {
                        if self.player === player { self.didEnd() }
                        // Keep observing the same player so replay and repeat
                        // can resume its clock after end-of-file.
                        if self.player !== player { return }
                    }
                    // Some unsupported streams stop without a libvlc error.
                    // Keep an early decoder stop from becoming a silent black
                    // screen. Normal pause, buffering and end-of-file differ.
                    let stoppedEarly = player.state == .stopped && self.elapsed > 0
                        && self.duration > self.elapsed + 0.5 && player.position < 0.98
                    if stoppedEarly {
                        if let stoppedSince, stoppedSince.duration(to: .now) > .seconds(1) {
                            self.error = ToolText.text("media_unavailable"); self.buffering = false
                        } else if stoppedSince == nil { stoppedSince = .now }
                    } else { stoppedSince = nil }
                    VideoScreenAwakeService.shared.setActive(self.playing && self.hasVideo, owner: self.awakeOwner)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch { self.error = error.localizedDescription; buffering = false }
    }
    func togglePlayback() {
        endTemporaryRate()
        guard let player else { return }
        if reportedEnd { play(); return }
        wantsPlayback = !(pendingStart?.autoplay ?? player.isPlaying)
        if let pending = pendingStart { pendingStart = (pending.seconds, wantsPlayback, pending.explicit) }
        if wantsPlayback { play() } else { pause() }
    }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer, player.state == .ended else { return }
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.didEnd()
        }
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
            // libvlc's ended input cannot reliably be restarted with play().
            // Reopen it while retaining credentials and the user's mode.
            open(sourceURL, resourceLease: resourceLease, persistPosition: persistsPosition,
                 startAt: 0, requestContext: requestContext, title: MediaSession.shared.title,
                 originalURL: MediaSession.shared.url, systemAvailable: MediaSession.shared.souloSystemAvailable)
            return
        }
        player?.play()
    }
    func pause() {
        endTemporaryRate(); wantsPlayback = false; resumeAfterInterruption = false
        waitingForSurface = false
        playing = false; buffering = false
        if let pending = pendingStart { pendingStart = (pending.seconds, false, pending.explicit) }
        player?.pause(); savePosition()
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
        open(sourceURL, resourceLease: resourceLease, persistPosition: persistsPosition, startAt: elapsed, requestContext: requestContext)
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
        guard let player, player.isPlaying, player.rate < target, rateBeforeHold == nil else { return }
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
    func finishAdjustment() {
        feedbackDismissal?.cancel()
        feedbackDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            self?.gestureFeedback = nil
        }
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let target = min(max(0, seconds), min(duration, Double(Int32.max) / 1000))
        pendingSeek = VideoPlaybackSeek(target: target)
        elapsed = target
        guard player?.isSeekable == true else {
            pendingStart = (target, wantsPlayback, true)
            return
        }
        player?.time = VLCTime(int: Int32(target * 1000))
    }
    func stop(deactivateAudioSession: Bool = true) {
        savePosition()
        endTemporaryRate()
        feedbackDismissal?.cancel(); feedbackDismissal = nil; gestureFeedback = nil
        if let originalBrightness { adjustedScreen?.brightness = originalBrightness }
        adjustedScreen = nil; originalBrightness = nil
        let hadPlayer = player != nil
        waitingForSurface = false
        wantsPlayback = false
        updates?.cancel(); updates = nil
        player?.delegate = nil; player?.stop(); player?.drawable = nil; player = nil
        playing = false; buffering = false
        VideoScreenAwakeService.shared.setActive(false, owner: awakeOwner)
        resourceLease = nil
        requestContext = nil
        sourceURL = nil
        pendingStart = nil
        pendingSeek = nil
        MediaSession.shared.releaseSoulo(self)
        videoPresentationSize = .zero; reportedVideoSize = .zero; resolvedTrackSize = false
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
    deinit { updates?.cancel(); feedbackDismissal?.cancel() }
}

/// libvlc must receive a mounted surface with a real size before starting video output.
final class MatroskaVideoSurface: UIView, UIGestureRecognizerDelegate {
    weak var playback: MatroskaPlayback?
    var primary = true
    var tapped: (() -> Void)? {
        didSet {
            let enabled = tapped != nil
            if tapRecognizer?.isEnabled != enabled { tapRecognizer?.isEnabled = enabled }
        }
    }
    private var tapRecognizer: UITapGestureRecognizer?
    private var verticalGesture: VideoVerticalGestureHandler?

    override init(frame: CGRect) {
        super.init(frame: frame)
        verticalGesture = VideoVerticalGestureHandler(in: self, enabled: { [weak self] in self?.playback?.hasVideo == true },
            brightness: { [weak self] value, screen in self?.playback?.adjustBrightness(value, screen: screen) },
            feedback: { [weak self] kind, value in self?.playback?.showAdjustment(kind, value: value) },
            ended: { [weak self] in self?.playback?.finishAdjustment() })
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedVideo))
        tap.isEnabled = false; tapRecognizer = tap
        tap.require(toFail: hold)
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
        // VLC's OpenGL renderbuffer allocation can commit a layer transaction
        // from its render thread. UIKit layout must return to the main queue.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setNeedsLayout() }
            return
        }
        super.layoutSubviews()
        if window != nil { playback?.attach(self, primary: primary) }
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { playback?.beginTemporaryRate() }
        else if [.ended, .cancelled, .failed].contains(gesture.state) { playback?.endTemporaryRate() }
    }
    @objc private func tappedVideo() { tapped?() }

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
    var select: (String) -> Void
}

struct FileVideoOptions: Equatable {
    var usesSystem: Bool
    var systemAvailable: Bool
    var souloAvailable = true
    var playlist: FileVideoPlaylist?
    var requestAirPlay: ((Double, Bool) -> Void)?
    var requestPictureInPicture: ((Double, Bool) -> Void)?
    var download: (() -> Void)?
    var airPlayPresentation: Binding<Bool>?
    var fullscreenChanged: ((Bool) -> Void)?
    var closePlayback: (() -> Void)?
    var showsEpisodesOnAppear = false
    var shareURL: URL?
    var selectPlayer: (Bool, Double, Bool) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usesSystem == rhs.usesSystem && lhs.systemAvailable == rhs.systemAvailable
            && lhs.souloAvailable == rhs.souloAvailable
            && lhs.playlist?.selectedID == rhs.playlist?.selectedID
            && lhs.playlist?.episodes == rhs.playlist?.episodes
            && lhs.playlist?.sources == rhs.playlist?.sources
            && lhs.playlist?.selectedSourceID == rhs.playlist?.selectedSourceID
            && lhs.playlist?.resolvingID == rhs.playlist?.resolvingID
            && lhs.playlist?.failure == rhs.playlist?.failure
            && (lhs.requestAirPlay != nil) == (rhs.requestAirPlay != nil)
            && (lhs.requestPictureInPicture != nil) == (rhs.requestPictureInPicture != nil)
            && (lhs.download != nil) == (rhs.download != nil)
            && (lhs.airPlayPresentation != nil) == (rhs.airPlayPresentation != nil)
            && (lhs.closePlayback != nil) == (rhs.closePlayback != nil)
            && lhs.showsEpisodesOnAppear == rhs.showsEpisodesOnAppear
            && lhs.shareURL == rhs.shareURL
    }
}

struct MediaPlayerMenu: View {
    let options: FileVideoOptions
    let playbackState: () -> (time: Double, playing: Bool)
    var interactionChanged: ((Bool) -> Void)?
    @State private var presented = false
    @State private var pending: (system: Bool, time: Double, playing: Bool)?
    @State private var playbackWindow = VideoPlaybackWindow()
    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 17)).frame(width: 44, height: 44)
        }
        .accessibilityLabel(ToolText.text("media_player"))
        .accessibilityValue(options.usesSystem ? ToolText.text("media_player_system") : "Soulo")
        .accessibilityIdentifier("media.file.player")
        .popover(isPresented: $presented) {
            VStack(spacing: 0) {
                choice("Soulo", system: false, enabled: options.souloAvailable)
                Divider().padding(.leading, 44)
                choice(ToolText.text("media_player_system"), system: true, enabled: options.systemAvailable)
            }
            .frame(width: 220).padding(.vertical, 6).buttonStyle(.plain)
            .presentationCompactAdaptation(.popover)
            .onDisappear {
                guard let pending else { return }
                self.pending = nil
                Task { @MainActor in
                    // SwiftUI reports disappearance before UIKit has detached
                    // the popover. Switching then can dismiss only that popover
                    // and leave the next player attached to a retiring host.
                    for _ in 0..<24 {
                        let host = VideoOrientation.topController(in: playbackWindow.window)
                        if host?.modalPresentationStyle != .popover,
                           host?.isBeingDismissed != true, host?.transitionCoordinator == nil { break }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    options.selectPlayer(pending.system, pending.time, pending.playing)
                }
            }
        }
        .onChange(of: presented) { _, shown in interactionChanged?(shown) }
        .background(VideoPlaybackWindowReader(context: playbackWindow))
    }
    private func choice(_ title: String, system: Bool, enabled: Bool) -> some View {
        Button {
            let state = playbackState()
            pending = (system, state.time, state.playing); presented = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").opacity(options.usesSystem == system ? 1 : 0).frame(width: 20)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityIdentifier(system ? "media.file.engine.system" : "media.file.engine.soulo")
    }
}

struct FileVideoMenus: View {
    let rate: Float
    let playbackState: () -> (time: Double, playing: Bool)
    let setRate: (Float) -> Void
    var options: FileVideoOptions?
    var showEpisodes: (() -> Void)?
    var showsPlayerMenu = true
    var menuInteraction: ((Bool) -> Void)?
    var interaction: (() -> Void)?
    @State private var showMirroringHelp = false
    @State private var speedPresented = false
    @ViewBuilder private func checkedLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }
    private func selectPlayer(_ system: Bool, options: FileVideoOptions) {
        let state = playbackState()
        options.selectPlayer(system, state.time, state.playing)
    }
    var body: some View {
        HStack(spacing: 12) {
            Button { speedPresented.toggle() } label: {
                Label(String(format: "%g×", rate), systemImage: "speedometer").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(ToolText.text("video_speed"))
            .accessibilityValue(String(format: "%g×", rate))
            .accessibilityIdentifier("media.file.speed")
            .popover(isPresented: $speedPresented) {
                ScrollView {
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
                }.frame(width: 180, height: 280).buttonStyle(.plain).presentationCompactAdaptation(.popover)
            }
            .onChange(of: speedPresented) { _, shown in menuInteraction?(shown) }
            Spacer(minLength: 0)
            if let playlist = options?.playlist, playlist.episodes.count > 1 || playlist.sources.count > 1 {
                Button { showEpisodes?(); interaction?() } label: {
                    Label(ToolText.text("episodes"), systemImage: "list.bullet").frame(minHeight: 44)
                }
                .accessibilityIdentifier("media.file.episodes")
            }
            if let options {
                if showsPlayerMenu { MediaPlayerMenu(options: options, playbackState: playbackState, interactionChanged: menuInteraction) }
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
    let url: URL
    var resourceLease: AnyObject?
    var requestContext: VideoPlaybackRequestContext?
    var title: String?
    var persistPosition = true
    var startAt: Double?
    var autoplay = true
    var options: FileVideoOptions?
    var startsFullscreen = false
    @StateObject private var playback = MatroskaPlayback()
    @StateObject private var controls = VideoControlsVisibility()
    @State private var expanded = false
    @State private var startedFullscreen = false
    @State private var leavingPlayback = false
    @State private var episodesVisible = false
    @State private var settingsVisible = false
    private var playbackOptions: FileVideoOptions? {
        guard var options else { return nil }
        if !playback.hasVideo { options.requestPictureInPicture = nil }
        let selectPlayer = options.selectPlayer
        options.selectPlayer = { system, time, _ in
            guard system else { return }
            leavingPlayback = true
            selectPlayer(system, time, playback.isPlaybackRequested)
            if MediaSession.shared.soulo === playback { playback.stop(deactivateAudioSession: false) }
        }
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
         options: FileVideoOptions? = nil, startsFullscreen: Bool = false) {
        self.url = url; self.resourceLease = resourceLease; self.requestContext = requestContext
        self.title = title; self.persistPosition = persistPosition; self.startAt = startAt; self.autoplay = autoplay
        self.options = options; self.startsFullscreen = startsFullscreen
        let current = MediaSession.shared.soulo
        _playback = StateObject(wrappedValue: current?.sourceURL == url ? current! : MatroskaPlayback())
    }
    var body: some View {
        VStack(spacing: 0) {
            if expanded { Color.black }
            else {
                MatroskaVideoContent(playback: playback, url: url, resourceLease: resourceLease, onTap: controls.toggle)
                    .modifier(VideoTransportOverlay(visibility: controls, playing: playback.playing, buffering: playback.buffering,
                        identifier: "media.mkv.play", toggle: playback.togglePlayback,
                        seek: { playback.seek(playback.elapsed + $0) }))
            }
            if !expanded {
                MatroskaControls(playback: playback, options: playbackOptions, showEpisodes: { episodesVisible = true },
                                 expand: { episodesVisible = false; expanded = true }, interactionChanged: controls.interaction)
                    .padding(20).background(Color(UIColor.secondarySystemGroupedBackground))
            }
        }
        .modifier(FileVideoEpisodeDrawer(isPresented: $episodesVisible, playlist: playbackOptions?.playlist))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !expanded, let options = playbackOptions {
                    Menu {
                        PlaybackSleepTimerMenu()
                        if let request = options.requestPictureInPicture {
                            Button { request(playback.elapsed, playback.playing) } label: {
                                Label(ToolText.text("media_pip"), systemImage: "pip.enter")
                            }.disabled(!options.systemAvailable)
                                .accessibilityIdentifier("media.picture-in-picture")
                        }
                        if let download = options.download {
                            Button(action: download) { Label(LanguageManager.shared.localizedString("download"), systemImage: "arrow.down.circle") }
                        }
                        if let url = options.shareURL { ShareLink(item: url) { Label(ToolText.text("share_media"), systemImage: "square.and.arrow.up") } }
                        Button { settingsVisible = true } label: { Label(LanguageManager.shared.localizedString("settings"), systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityIdentifier("media.options")
                }
            }
        }
        .background {
            MatroskaFullscreenPresenter(isPresented: $expanded, playback: playback, url: url,
                                       resourceLease: resourceLease, title: title, options: playbackOptions)
                .frame(width: 0, height: 0)
        }
        .task(id: url) {
            guard !Task.isCancelled, !leavingPlayback else { return }
            playback.open(url, resourceLease: resourceLease, persistPosition: persistPosition,
                                     startAt: startAt, autoplay: autoplay, requestContext: requestContext, title: title,
                                     originalURL: options?.shareURL, systemAvailable: options?.systemAvailable ?? true) }
        .onAppear {
            if startsFullscreen, !startedFullscreen { startedFullscreen = true; expanded = true }
            controls.show()
        }
        .onChange(of: expanded) { _, full in if full { startedFullscreen = true } }
        .onDisappear { playback.endTemporaryRate() }
        .sheet(isPresented: $settingsVisible) {
            NavigationStack { VideoSettingsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { settingsVisible = false } }
            } }
        }
    }
}

private struct MatroskaVideoContent: View {
    @ObservedObject var playback: MatroskaPlayback
    let url: URL
    var resourceLease: AnyObject?
    var onTap: (() -> Void)?
    var body: some View {
        MatroskaSurface(playback: playback, onTap: {
                guard playback.gestureFeedback == nil else { return }
                onTap?()
            })
            .contentShape(Rectangle())
            .overlay {
                if !playback.hasVideo {
                    Image(systemName: "waveform").font(.system(size: 72, weight: .light))
                        .foregroundStyle(.white.opacity(0.55)).allowsHitTesting(false)
                }
            }
            .overlay {
                if let error = playback.error {
                    VStack(spacing: 16) {
                        Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
                        Button(ToolText.text("retry")) { playback.retry() }
                    }.padding(24)
                } else if playback.buffering && playback.gestureFeedback == nil {
                    ProgressView().tint(.white).controlSize(.large)
                        .padding(18).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("media.mkv.buffering")
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let feedback = playback.gestureFeedback {
                    Label(feedback.text, systemImage: feedback.symbol)
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(.black.opacity(0.65), in: Capsule())
                        .accessibilityIdentifier("media.mkv.gesture.feedback")
                        .allowsHitTesting(false)
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
        VideoPlaybackControls(elapsed: playback.elapsed, duration: playback.duration, rate: playback.rate,
            playing: playback.playing, identifier: "media.mkv", options: options, showEpisodes: showEpisodes,
            expand: expand, interactionChanged: interactionChanged, seek: playback.seek, setRate: playback.setRate)
    }
}

private struct MatroskaFullscreenContent: View {
    @ObservedObject var playback: MatroskaPlayback
    let url: URL
    var resourceLease: AnyObject?
    var title: String?
    var options: FileVideoOptions?
    let close: () -> Void
    @StateObject private var controls = VideoControlsVisibility()

    var body: some View {
        MatroskaVideoContent(playback: playback, url: url, resourceLease: resourceLease)
            .modifier(VideoFullscreenChrome(visibility: controls, title: title ?? url.lastPathComponent,
                elapsed: playback.elapsed, duration: playback.duration, rate: playback.rate,
                playing: playback.playing, buffering: playback.buffering, error: playback.error,
                identifier: "media.mkv", closeIdentifier: "media.mkv.fullscreen.close", options: options,
                close: close, toggle: playback.togglePlayback, seek: playback.seek, setRate: playback.setRate,
                holdBegan: playback.beginTemporaryRate, holdEnded: playback.endTemporaryRate) { EmptyView() })
            .modifier(VideoOrientationErrorAlert(message: $playback.orientationError))
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
                identifier: "media.mkv.fullscreen.player", landscape: size.width > size.height || scene.interfaceOrientation.isLandscape,
                onClose: { [weak self] in self?.finish() })
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
                actions?.selectPlayer = { [weak self] system, time, playing in
                    guard system != original.usesSystem else { return }
                    original.fullscreenChanged?(true)
                    self?.handoff { original.selectPlayer(system, time, playing) }
                }
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
                guard let self else { return }; self.sharedHost?.dismiss(owner: self.ownerID)
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
        private func finish() {
            sharedHost = nil; presentedURL = nil; presentedOptions = nil; handingOff = false
            selection?.wrappedValue = false
            options?.fullscreenChanged?(false)
            options?.closePlayback?()
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
    let url: URL
    var path: String?
    var resourceLease: AnyObject?
    var persistPosition = true
    var playlist: FileVideoPlaylist?
    var initialSystemPlayer: Bool? = nil
    @AppStorage(VideoPlaybackPreferences.defaultPlayerKey) private var defaultPlayer = "soulo"
    @State private var selectedSystemPlayer: Bool?
    @State private var preserveFullscreen = false
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
    private var prefersSystem: Bool { selectedSystemPlayer ?? initialSystemPlayer ?? (defaultPlayer == "system") }
    private var currentPath: String { selectedURL?.path ?? path ?? url.path }
    private var isVideo: Bool { FileVideoEpisodes.isVideo(currentPath) }
    private var usesSystem: Bool { (prefersSystem || airPlayActive) && nativeAvailable == true && !nativeFailed }
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
                         playlist: videoPlaylist) { system, time, _ in
            guard system != usesSystem else { return }
            handoff = (time, native.isPlaybackRequested)
            native.stop(deactivateAudioSession: false)
            airPlayActive = false
            selectedSystemPlayer = system
        }
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
                selectedSystemPlayer = true
                airPlayActive = false
            }
        }
        result.fullscreenChanged = { preserveFullscreen = $0 }
        result.airPlayPresentation = $airPlayRequested
        result.shareURL = currentURL
        return result
    }
    var body: some View {
        Group {
            if ((prefersSystem || airPlayActive) && nativeAvailable == nil)
                || (["movpkg", "hls", "m3u8", OfflineHLSReference.fileExtension].contains(currentURL.pathExtension.lowercased()) && resolvedURL != currentURL) {
                ProgressView(ToolText.text("loading"))
            } else if usesSystem {
                MediaPlaybackContent(videoOptions: options, showEpisodes: { episodesVisible = true }, airPlayRequested: $airPlayRequested,
                                     initialFullscreen: preserveFullscreen, initialSystemPlayer: true)
                    .task(id: resolvedURL) {
                        guard resolvedURL == currentURL else { return }
                        guard native.soulo != nil || native.url != currentURL || native.player.currentItem == nil else { return }
                        let source = DownloadPlaybackSource(asset: asset ?? AVURLAsset(url: currentURL), pageURL: nil,
                                                            webView: nil, persistPosition: persistPosition)
                        source.resourceLease = resourceLease
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
        .toolbar { if currentURL.isFileURL { ShareLink(item: currentURL) { Image(systemName: "square.and.arrow.up") } } }
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
        if url.isFileURL, LocalHLSMedia.extensions.contains(url.pathExtension.lowercased())
            || (url.pathExtension.lowercased() == OfflineHLSReference.fileExtension
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) {
            let playlist = try await Task.detached { try LocalHLSMedia.playlistURL(for: url) }.value
            let asset = AVURLAsset(url: playlist)
            let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, persistPosition: persistPosition)
            source.resourceLease = resourceLease
            return (asset, true, try await SouloMediaPlaybackSource.prepare(native: source, originalURL: url))
        }
        if url.isFileURL, ["movpkg", OfflineHLSReference.fileExtension].contains(url.pathExtension.lowercased()) {
            let asset = try url.pathExtension.lowercased() == "movpkg"
                ? OfflineHLSReference.playablePackage(at: url) : OfflineHLSReference.playableAsset(for: url)
            let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, persistPosition: persistPosition)
            source.resourceLease = resourceLease
            let soulo = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: url)
            return (asset, true, soulo)
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
        return ["mkv", "soulohls", "movpkg", "hls", "m3u8"].contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }
    static func isAudio(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "m4b", "aac", "wav", "flac", "ogg", "oga", "opus", "wma", "aiff", "aif", "ape", "alac", "amr"].contains(ext)
            || UTType(filenameExtension: ext)?.conforms(to: .audio) == true
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
                ContentUnavailableView(ToolText.text("media_unavailable"), systemImage: "play.slash", description: Text(error))
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
