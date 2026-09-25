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
    @Published var retainedPiPController: AVPlayerViewController?
    var retainedPiPDelegate: AnyObject?
    let pictureInPicture = MediaPictureInPicture()
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var pageURL: URL?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var playing = false
    @Published var error: String?
    @Published var expanded = false
    @Published private(set) var hasVideo = false
    @Published private(set) var videoIsLandscape = false
    @Published var playerSurfaces = 0
    @Published var loop = false
    @Published var mirrored = false
    @Published private(set) var rate: Float
    @Published private(set) var temporaryRate = false
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
        player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            self?.playing = status == .playing
            self?.updateNowPlaying()
        }.store(in: &observations)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self, event.object as? AVPlayerItem === self.player.currentItem else { return }
            self.endTemporaryRate()
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
        installRemoteControls()
    }

    static func validRate(_ value: Float) -> Bool { value.isFinite && (0.5...16).contains(value) }

    static func prefersLandscape(width: CGFloat, height: CGFloat) -> Bool {
        width.isFinite && height.isFinite && height > 0 && width > height * 1.1
    }

    func open(url: URL, title: String? = nil, pageURL: URL? = nil, asset: AVURLAsset? = nil, webView: WKWebView? = nil, reservation: UUID? = nil) {
        if let reservation, !ownsPreparation(reservation) { return }
        preparation = UUID()
        configureIfNeeded()
        savePosition()
        endTemporaryRate()
        interruptedGeneration = nil
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
        videoIsLandscape = false
        mirrored = false
        let item = AVPlayerItem(asset: asset ?? AVURLAsset(url: url))
        // Preserve pitch across the full speed range. The spectral algorithm also
        // avoids the observed time-domain clock stall when starting at 0.5×.
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
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
            }
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
                    if self.wantsPlayback && self.interruptedGeneration == nil { self.play() }
                }
            }
        }
    }

    func play() {
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
        } catch { self.error = error.localizedDescription }
    }
    func pause() {
        wantsPlayback = false; interruptedGeneration = nil
        endTemporaryRate(); player.pause(); savePosition(); updateNowPlaying()
    }
    func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            if interruptedGeneration == nil { interruptedGeneration = wantsPlayback ? generation : nil }
            endTemporaryRate(); player.pause(); savePosition(); updateNowPlaying()
        } else {
            let resume = shouldResume && interruptedGeneration == generation && wantsPlayback
            interruptedGeneration = nil
            if resume { play() } else { wantsPlayback = false }
        }
    }
    func beginTemporaryRate() {
        guard !temporaryRate, hasVideo, wantsPlayback, player.rate > 0, rate < 2 else { return }
        temporaryRate = true
        player.rate = 2
        updateNowPlaying()
    }
    func endTemporaryRate() {
        guard temporaryRate else { return }
        temporaryRate = false
        if player.rate > 0 { player.rate = rate }
        updateNowPlaying()
    }
    func updateFileReference(from oldURL: URL, to newURL: URL) {
        let defaults = UserDefaults.standard
        let isCurrent = url?.standardizedFileURL == oldURL.standardizedFileURL
        if isCurrent { savePosition() }
        let position = defaults.object(forKey: positionKey(oldURL))
        if isCurrent {
            let resume = wantsPlayback
            open(url: newURL, title: newURL.lastPathComponent)
            if !resume { pause() }
        }
        if let position {
            defaults.set(position, forKey: positionKey(newURL))
            defaults.removeObject(forKey: positionKey(oldURL))
        }
    }
    func toggle() { playing ? pause() : play() }
    func stop() {
        pause(); generation = UUID(); preparation = UUID(); itemObservation = nil; presentationSizeObservation = nil
        pictureInPicture.stop()
        retainedPiPController?.player = nil; retainedPiPController = nil; retainedPiPDelegate = nil
        player.replaceCurrentItem(with: nil); url = nil; expanded = false
        hasVideo = false; videoIsLandscape = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    @discardableResult func setRate(_ value: Float) -> Bool {
        guard Self.validRate(value) else { return false }
        guard value <= 2 || player.currentItem?.canPlayFastForward == true else {
            error = ToolText.text("media_rate_unavailable"); return false
        }
        endTemporaryRate()
        rate = value
        UserDefaults.standard.set(value, forKey: "media.rate")
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
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
