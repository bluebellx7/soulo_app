import AVFoundation
import Combine
import MobileVLCKit
import SwiftUI

/// The extended decoder is created only for MKV or unsupported file codecs. Ordinary web
/// video and native file playback continue to use the existing AVPlayer path.
@MainActor final class MatroskaPlayback: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var buffering = true
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var error: String?
    private(set) var player: VLCMediaPlayer?
    private weak var surface: UIView?
    private let awakeOwner = UUID()
    private var updates: Task<Void, Never>?
    private var resourceLease: AnyObject?

    func attach(_ view: UIView) {
        guard surface !== view else { return }
        surface = view; player?.drawable = view
    }
    func open(_ url: URL, resourceLease: AnyObject? = nil) {
        stop()
        MediaSession.shared.stop()
        self.resourceLease = resourceLease
        error = nil; elapsed = 0; duration = 0; buffering = true
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            // Reuse VLCKit's library; passing per-player global options creates
            // another decoder library in addition to VLCMedia's shared one.
            let player = VLCMediaPlayer()
            self.player = player; player.drawable = surface
            let media = VLCMedia(url: url)
            media.addOption(":network-caching=1500")
            media.addOption(":no-video-title-show")
            player.media = media; player.play()
            updates = Task { [weak self] in
                var stoppedSince: ContinuousClock.Instant?
                while !Task.isCancelled {
                    guard let self, let player = self.player else { return }
                    self.playing = player.isPlaying
                    self.buffering = player.state == .opening || player.state == .buffering
                    self.elapsed = max(0, Double(player.time.intValue) / 1000)
                    self.duration = max(0, Double(player.media?.length.intValue ?? 0) / 1000)
                    if player.state == .error { self.error = ToolText.text("media_unavailable"); self.buffering = false }
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
                    VideoScreenAwakeService.shared.setActive(self.playing, owner: self.awakeOwner)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch { self.error = error.localizedDescription; buffering = false }
    }
    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        player?.time = VLCTime(int: Int32(min(max(0, seconds), min(duration, Double(Int32.max) / 1000)) * 1000))
    }
    func stop() {
        let hadPlayer = player != nil
        updates?.cancel(); updates = nil
        player?.stop(); player?.drawable = nil; player = nil
        playing = false; buffering = false
        VideoScreenAwakeService.shared.setActive(false, owner: awakeOwner)
        resourceLease = nil
        if hadPlayer && !MediaSession.shared.playing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    deinit { updates?.cancel() }
}

private struct MatroskaSurface: UIViewRepresentable {
    @ObservedObject var playback: MatroskaPlayback
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black; playback.attach(view); return view
    }
    func updateUIView(_ view: UIView, context: Context) { playback.attach(view) }
}

struct MatroskaPlayerView: View {
    let url: URL
    var resourceLease: AnyObject?
    @StateObject private var playback = MatroskaPlayback()
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    private func time(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var body: some View {
        VStack(spacing: 0) {
            MatroskaSurface(playback: playback)
                .overlay {
                    if playback.buffering { ProgressView().tint(.white) }
                    if let error = playback.error {
                        VStack(spacing: 16) {
                            Text(error).foregroundStyle(.white).multilineTextAlignment(.center)
                            Button(ToolText.text("retry")) { playback.open(url, resourceLease: resourceLease) }
                        }.padding(24)
                    }
                }
                .accessibilityIdentifier("media.mkv.preview")
            VStack(spacing: 12) {
                Slider(value: Binding(get: { scrubbing ? scrubTime : min(playback.elapsed, max(1, playback.duration)) },
                                      set: { scrubTime = $0 }), in: 0...max(1, playback.duration)) { editing in
                    if editing { scrubTime = playback.elapsed }
                    scrubbing = editing
                    if !editing { playback.seek(scrubTime) }
                }
                .disabled(playback.duration <= 0).accessibilityIdentifier("media.mkv.timeline")
                HStack {
                    Text(time(playback.elapsed)).monospacedDigit().font(.caption)
                    Spacer()
                    Button { playback.seek(playback.elapsed - 10) } label: { Image(systemName: "gobackward.10") }
                    Button { playback.togglePlayback() } label: {
                        Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .frame(width: 52, height: 48).accessibilityIdentifier("media.mkv.play")
                    Button { playback.seek(playback.elapsed + 10) } label: { Image(systemName: "goforward.10") }
                    Spacer()
                    Text(time(playback.duration)).monospacedDigit().font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(20).background(Color(UIColor.secondarySystemGroupedBackground))
        }
        .task(id: url) { playback.open(url, resourceLease: resourceLease) }
        .onDisappear { playback.stop() }
        .toolbar { if url.isFileURL { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } } }
    }
}

struct TorrentFilePlaybackView: View {
    let id: UUID
    let file: TorrentFileEntry
    @State private var url: URL?
    @State private var lease: TorrentPlaybackLease?
    @State private var asset: AVURLAsset?
    @State private var useExtendedDecoder = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let url {
                if useExtendedDecoder {
                    MatroskaPlayerView(url: url, resourceLease: lease)
                } else {
                    MediaPlaybackContent().task(id: url) {
                        let source = DownloadPlaybackSource(asset: asset ?? AVURLAsset(url: url), pageURL: nil,
                                                            webView: nil, persistPosition: false)
                        source.resourceLease = lease
                        MediaSession.shared.open(url: url, title: (file.path as NSString).lastPathComponent,
                                                 asset: source.asset, persistPosition: false, downloadSource: source)
                    }
                }
            } else if let error {
                ContentUnavailableView(ToolText.text("media_unavailable"), systemImage: "play.slash", description: Text(error))
            } else { ProgressView(ToolText.text("loading")) }
        }
        .onReceive(MediaSession.shared.$error) { error in
            guard error != nil, !useExtendedDecoder, let url,
                  MediaSession.shared.url == url,
                  MediaSession.shared.player.currentItem?.status == .failed else { return }
            useExtendedDecoder = true
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("done")) { dismiss() } } }
        .task {
            do {
                let resolvedURL: URL
                let playbackLease: TorrentPlaybackLease?
                if let completed = TorrentDownloadService.shared.completedFileURL(id, file: file) {
                    resolvedURL = completed; playbackLease = nil
                } else {
                    let lease = try await TorrentDownloadService.shared.openStream(id, file: file)
                    playbackLease = lease; resolvedURL = lease.url
                }
                let asset = AVURLAsset(url: resolvedURL)
                let extended = try await TorrentFileDecoder.prefersExtended(asset, path: file.path)
                if extended { asset.cancelLoading() }
                try Task.checkCancellation()
                self.lease = playbackLease; self.asset = extended ? nil : asset
                useExtendedDecoder = extended; url = resolvedURL
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
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
