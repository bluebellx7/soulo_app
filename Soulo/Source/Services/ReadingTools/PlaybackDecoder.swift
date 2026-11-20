import AVFoundation
import UIKit

enum PlaybackDecoderState: Int, Sendable {
    case opening, buffering, playing, paused, ended, failed
}

struct PlaybackDecoderTrack: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case audio, subtitle }
    let id: String
    let kind: Kind
    let name: String
    var selected: Bool
}

@MainActor protocol PlaybackDecoder: AnyObject {
    var layer: CALayer { get }
    var state: PlaybackDecoderState { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var videoSize: CGSize { get }
    var hasVideo: Bool? { get }
    var decodedFrameCount: Int { get }
    var isSeekable: Bool { get }
    var isPlaying: Bool { get }
    var loadedRanges: [CMTimeRange] { get }
    var receivedBytes: Int64? { get }
    var tracks: [PlaybackDecoderTrack] { get }
    var rate: Float { get set }
    func play()
    func pause()
    func seek(to seconds: Double)
    func selectTrack(_ id: String?, kind: PlaybackDecoderTrack.Kind)
    func update()
    func stop(retaining lease: AnyObject?)
}

@MainActor final class AVPlaybackDecoder: PlaybackDecoder {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    private let videoLayer: AVPlayerLayer
    private var finished = false
    private var failed = false
    private var wantsPlayback = false
    private var trackGroups: [PlaybackDecoderTrack.Kind: AVMediaSelectionGroup] = [:]
    private var trackTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var frameTime = CMTime.invalid
    private var timeObserver: Any?
    private(set) var currentTime = 0.0
    private(set) var decodedFrameCount = 0
    var layer: CALayer { videoLayer }

    init(asset: AVURLAsset, online: Bool) {
        item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = online ? 24 : 0
        item.audioTimePitchAlgorithm = .spectral
        item.add(output)
        player = AVPlayer(playerItem: item)
        videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspect
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                if time.seconds.isFinite { self?.currentTime = max(0, time.seconds) }
            }
        }
        let events = NotificationCenter.default
        observers = [
            events.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finished = true }
            },
            events.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.failed = true }
            }
        ]
    }

    var state: PlaybackDecoderState {
        if failed || item.status == .failed { return .failed }
        if finished { return .ended }
        if item.status == .unknown { return .opening }
        if !wantsPlayback { return .paused }
        return player.timeControlStatus == .playing ? .playing : .buffering
    }
    var duration: Double { item.status == .readyToPlay ? finiteSeconds(item.duration) : 0 }
    var videoSize: CGSize { item.status == .readyToPlay ? item.presentationSize : .zero }
    var hasVideo: Bool? {
        if videoSize != .zero || decodedFrameCount > 0 { return true }
        guard item.status == .readyToPlay, !item.tracks.isEmpty else { return nil }
        return item.tracks.contains { $0.assetTrack?.mediaType == .video }
    }
    var isSeekable: Bool { item.status == .readyToPlay && duration > 0 }
    var isPlaying: Bool { state == .playing }
    var loadedRanges: [CMTimeRange] {
        item.status == .readyToPlay ? item.loadedTimeRanges.map(\.timeRangeValue) : []
    }
    var receivedBytes: Int64? {
        guard item.status == .readyToPlay else { return nil }
        let bytes = item.accessLog()?.events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) } ?? 0
        return bytes > 0 ? bytes : nil
    }
    var rate: Float = 1 {
        didSet { if wantsPlayback { player.defaultRate = rate; if player.rate > 0 { player.rate = rate } } }
    }
    var tracks: [PlaybackDecoderTrack] {
        [PlaybackDecoderTrack.Kind.audio, .subtitle].flatMap { kind -> [PlaybackDecoderTrack] in
            guard let group = trackGroups[kind] else { return [] }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            return group.options.enumerated().map { index, option in
                .init(id: String(index), kind: kind, name: option.displayName, selected: option == selected)
            }
        }
    }

    func play() {
        wantsPlayback = true
        player.defaultRate = rate
        player.play()
    }
    func pause() {
        wantsPlayback = false
        player.pause()
    }
    func seek(to seconds: Double) {
        finished = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func selectTrack(_ id: String?, kind: PlaybackDecoderTrack.Kind) {
        guard let group = trackGroups[kind] else { return }
        if let id, let index = Int(id), group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        } else if id == nil, group.allowsEmptySelection {
            item.select(nil, in: group)
        }
    }
    func update() {
        if videoLayer.isReadyForDisplay {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            var presentation = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &presentation) != nil,
               presentation.isValid, presentation != frameTime {
                frameTime = presentation
                decodedFrameCount += 1
            }
        }
        if trackTask == nil, item.status == .readyToPlay {
            trackTask = Task { [weak self, asset = item.asset] in
                let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
                guard let self, !Task.isCancelled else { return }
                self.trackGroups[.audio] = audio
                self.trackGroups[.subtitle] = subtitles
            }
        }
    }
    func stop(retaining lease: AnyObject?) {
        failed = true
        pause()
        trackTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
        videoLayer.player = nil
    }
    private func finiteSeconds(_ time: CMTime) -> Double { time.seconds.isFinite ? max(0, time.seconds) : 0 }
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
