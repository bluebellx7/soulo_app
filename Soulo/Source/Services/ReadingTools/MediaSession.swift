import AVKit
import MediaPlayer
import Combine
import WebKit
import CryptoKit

/// One player shared by local files, resource previews, the mini-player and system controls.
@MainActor
final class MediaSession: ObservableObject {
    static let shared = MediaSession()
    lazy var player = AVPlayer()
    private var configured = false
    var retainedPiPController: AVPlayerViewController?
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var pageURL: URL?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published var error: String?
    @Published var expanded = false
    @Published private(set) var hasVideo = false
    @Published var playerSurfaces = 0
    @Published var loop = false
    @Published private(set) var rate: Float
    private var timer: Any?
    private var observations = Set<AnyCancellable>()
    private var itemObservation: NSKeyValueObservation?
    private var generation = UUID()
    private var preparation = UUID()
    func reservePreparation() -> UUID { preparation = UUID(); return preparation }
    func ownsPreparation(_ token: UUID) -> Bool { preparation == token }
    private var lastSavedSecond = -1
    private var wantsPlayback = false
    private var persistsPosition = true
    private weak var sourceWebView: WKWebView?

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
        player.publisher(for: \.timeControlStatus).sink { [weak self] status in
            self?.playing = status == .playing
            self?.updateNowPlaying()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).sink { [weak self] event in
            guard let self, event.object as? AVPlayerItem === self.player.currentItem else { return }
            self.seek(0)
            if self.loop { self.play() }
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] event in
            guard let type = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.pause()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] event in
            if (event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
        }.store(in: &observations)
        installRemoteControls()
    }

    static func validRate(_ value: Float) -> Bool { value.isFinite && (0.5...16).contains(value) }

    func open(url: URL, title: String? = nil, pageURL: URL? = nil, asset: AVURLAsset? = nil, webView: WKWebView? = nil, reservation: UUID? = nil) {
        if let reservation, !ownsPreparation(reservation) { return }
        preparation = UUID()
        configureIfNeeded()
        savePosition()
        generation = UUID()
        player.pause()
        sourceWebView = webView
        persistsPosition = webView?.configuration.websiteDataStore.isPersistent ?? true
        wantsPlayback = true
        // Pause page media only when explicitly handing this page's media to the player.
        webView?.evaluateJavaScript("document.querySelectorAll('audio,video').forEach(e=>e.pause()); true;", completionHandler: nil)
        self.url = url
        self.title = title?.isEmpty == false ? title! : url.lastPathComponent
        self.pageURL = pageURL
        elapsed = 0; duration = 0; error = nil; lastSavedSecond = -1
        hasVideo = false
        let item = AVPlayerItem(asset: asset ?? AVURLAsset(url: url))
        // Preserve pitch across the full speed range. The spectral algorithm also
        // avoids the observed time-domain clock stall when starting at 0.5×.
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        let token = generation
        Task {
            let tracks = try? await item.asset.loadTracks(withMediaType: .video)
            guard self.generation == token else { return }
            self.hasVideo = !(tracks?.isEmpty ?? true)
        }
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed {
                    self.error = item.error?.localizedDescription ?? ToolText.text("media_unavailable")
                } else if item.status == .readyToPlay {
                    let saved = self.persistsPosition ? UserDefaults.standard.double(forKey: self.positionKey(url)) : 0
                    if saved > 0, item.duration.seconds.isFinite, saved < item.duration.seconds - 2 { self.seek(saved) }
                    if self.rate > 2 && !item.canPlayFastForward { self.rate = 2 }
                    if self.wantsPlayback { self.play() }
                }
            }
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        wantsPlayback = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            // Allow AVPlayer to prepare enough data before advancing.
            player.defaultRate = rate
            player.play()
        } catch { self.error = error.localizedDescription }
    }
    func pause() { wantsPlayback = false; player.pause(); savePosition(); updateNowPlaying() }
    func toggle() { playing ? pause() : play() }
    func stop() {
        pause(); generation = UUID(); preparation = UUID(); itemObservation = nil
        retainedPiPController?.player = nil; retainedPiPController = nil
        player.replaceCurrentItem(with: nil); url = nil; expanded = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    @discardableResult func setRate(_ value: Float) -> Bool {
        guard Self.validRate(value) else { return false }
        guard value <= 2 || player.currentItem?.canPlayFastForward == true else {
            error = ToolText.text("media_rate_unavailable"); return false
        }
        rate = value
        UserDefaults.standard.set(value, forKey: "media.rate")
        if playing { player.rate = value }
        updateNowPlaying(); return true
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let limit = player.currentItem?.duration.seconds ?? 0
        guard limit.isFinite, limit > 0 else { return }
        let target = min(max(0, seconds), limit)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target
    }
    private func positionKey(_ url: URL) -> String {
        "media.position." + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func savePosition() {
        guard persistsPosition, let url, elapsed.isFinite else { return }
        UserDefaults.standard.set(elapsed, forKey: positionKey(url))
    }
    private func updateTime(_ time: CMTime) {
        elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0
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
            MPNowPlayingInfoPropertyPlaybackRate: playing ? player.rate : 0]
    }
    private func installRemoteControls() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
    }
}
