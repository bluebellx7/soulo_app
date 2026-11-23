import AVFoundation
import ImageIO
import SwiftUI

struct MusicTrackMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: UIImage?

    static func load(from asset: AVAsset) async -> Self {
        guard let items = try? await asset.load(.commonMetadata) else { return Self() }
        func text(_ key: AVMetadataKey) async -> String? {
            guard let item = items.first(where: { $0.commonKey == key }),
                  let value = try? await item.load(.stringValue) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let cover = items.first { $0.commonKey == .commonKeyArtwork }
        let artwork: UIImage?
        if let cover, let data = try? await cover.load(.dataValue), data.count <= 20 * 1024 * 1024 {
            artwork = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil as UIImage? }
                return UIImage(cgImage: image)
            }.value
        } else {
            artwork = nil
        }
        return await Self(title: text(.commonKeyTitle), artist: text(.commonKeyArtist),
                          album: text(.commonKeyAlbumName), artwork: artwork)
    }
}

struct MusicPlaybackView: View {
    private struct MetadataRequest: Equatable {
        let url: URL
        let asset: ObjectIdentifier?
    }

    let url: URL
    var title: String?
    var options: FileVideoOptions?
    var download: (() -> Void)?
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var session = MediaSession.shared
    @State private var metadata: (url: URL, value: MusicTrackMetadata)?
    @State private var scrubbing: Double?
    @State private var showsQueue = false
    @State private var showsAirPlayHelp = false
    @State private var countedAppearance = false

    private var trackURL: URL { session.isAudioPlayback ? session.url ?? url : url }
    private var isCurrentTrack: Bool { session.url == trackURL }
    private var remoteMetadataAsset: AVAsset? {
        guard isCurrentTrack, !trackURL.isFileURL else { return nil }
        return session.soulo?.preparedPlaybackSource?.native.asset ?? session.player.currentItem?.asset
    }
    private var trackMetadata: MusicTrackMetadata? { metadata?.url == trackURL ? metadata?.value : nil }
    private var playing: Bool { isCurrentTrack && session.playing }
    private var duration: Double { isCurrentTrack && session.duration.isFinite ? max(0, session.duration) : 0 }
    private var elapsed: Double { min(duration, max(0, session.elapsed.isFinite ? session.elapsed : 0)) }
    private var trackTitle: String {
        trackMetadata?.title ?? (trackURL == url ? title.map { name in
            name == url.lastPathComponent ? url.deletingPathExtension().lastPathComponent : name
        } : nil) ?? trackURL.deletingPathExtension().lastPathComponent
    }
    private var queueAvailable: Bool { session.localAudioIndex != nil && session.localAudioPlaylist.count > 1 }
    private var palette: MusicCoverPalette { MusicCoverPalette(url: trackURL) }
    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? Color(hex: "F2EFF9") : Color(hex: "222136") }
    private var accent: Color { dark ? palette.highlight : palette.accent }
    private var background: Color { dark ? Color(hex: "191922") : Color(hex: "F3F1F7") }
    private var card: Color { dark ? Color(hex: "252432") : .white }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 580 && geometry.size.height < 530
            let size = max(0, min(352, wide ? max(116, geometry.size.height - 103) : max(136, geometry.size.height * 0.50),
                                  wide ? geometry.size.width * 0.40 : geometry.size.width - 70))
            let extraSpacing = !wide && geometry.size.width <= 580 && dynamicTypeSize <= .large
                ? min(96, max(0, geometry.size.height - size - 350)) : 0
            VStack(spacing: 8) {
                header
                ScrollView {
                    Group {
                        if wide {
                            HStack(spacing: 24) {
                                cover(size: size)
                                VStack(spacing: 0) { timeline; details(extraSpacing: 0) }
                                    .frame(maxWidth: 360)
                            }
                        } else {
                            VStack(spacing: 0) {
                                cover(size: size)
                                timeline.padding(.top, extraSpacing * 0.10)
                                details(extraSpacing: extraSpacing)
                            }
                            .frame(maxWidth: 382)
                        }
                    }
                    .padding(wide ? 14 : 18)
                    .padding(.bottom, extraSpacing * 0.20)
                    .background(card, in: RoundedRectangle(cornerRadius: 30))
                    .overlay { RoundedRectangle(cornerRadius: 30).strokeBorder(ink.opacity(0.06)) }
                    .shadow(color: .black.opacity(dark ? 0.22 : 0.06), radius: 18, y: 8)
                    .padding(.horizontal, 16).padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity)
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(ink)
        .tint(accent)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if let feedback = session.gestureFeedback, feedback.kind == .volume {
                VideoGestureFeedbackView(feedback: feedback, identifier: "media.music.volume")
            }
        }
        .onAppear {
            if !countedAppearance {
                countedAppearance = true
                session.musicPlayerPages += 1
            }
        }
        .onDisappear {
            if countedAppearance {
                countedAppearance = false
                session.musicPlayerPages = max(0, session.musicPlayerPages - 1)
            }
        }
        .onCompatibleChange(of: trackURL) { _, _ in scrubbing = nil }
        .task(id: MetadataRequest(url: trackURL, asset: remoteMetadataAsset.map(ObjectIdentifier.init))) {
            let current = trackURL
            guard let asset = remoteMetadataAsset ?? (current.isFileURL ? AVURLAsset(url: current) : nil) else { return }
            let value = await MusicTrackMetadata.load(from: asset)
            guard !Task.isCancelled else { return }
            metadata = (current, value)
        }
        .sheet(isPresented: $showsQueue) { queue }
        .alert("AirPlay", isPresented: $showsAirPlayHelp) {
            Button(ToolText.text("done"), role: .cancel) {}
        } message: { Text(ToolText.text("media_airplay_mirroring_hint")) }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button { leave() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(ToolText.text("close"))
                .accessibilityIdentifier("media.music.close")
            Spacer()
            if let options, !options.usesSystem {
                Button {
                    if let request = options.requestAirPlay, options.systemAvailable {
                        request(session.elapsed, session.isPlaybackRequested)
                    } else { showsAirPlayHelp = true }
                } label: {
                    Image(systemName: "airplayaudio").frame(width: 44, height: 44)
                }
                .accessibilityLabel("AirPlay")
            } else {
                AirPlayRoutePicker(presentRequested: options?.airPlayPresentation).frame(width: 44, height: 44)
            }
            Menu {
                Menu(ToolText.text("video_speed")) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { rate in
                        Button { session.setRate(rate) } label: {
                            if rate == session.rate { Label("\(rate.formatted())×", systemImage: "checkmark") }
                            else { Text("\(rate.formatted())×") }
                        }
                    }
                }
                PlaybackSleepTimerMenu()
                if let download {
                    Button(action: download) {
                        Label(LanguageManager.shared.localizedString("download"), systemImage: "arrow.down.circle")
                    }
                }
                ShareLink(item: trackURL) { Label(ToolText.text("share_media"), systemImage: "square.and.arrow.up") }
                if let pageURL = session.pageURL {
                    ShareLink(item: pageURL) { Label(ToolText.text("share_page"), systemImage: "globe") }
                }
                if !trackURL.isFileURL {
                    Button { UIPasteboard.general.url = trackURL; HapticsManager.success() } label: {
                        Label(LanguageManager.shared.localizedString("copy_link"), systemImage: "link")
                    }
                }
                Button(ToolText.text("stop"), role: .destructive) { session.stop(); leave() }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel(ToolText.text("media_options"))
        }
        .font(.system(size: 18, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(maxWidth: 760)
    }

    private func cover(size: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if let artwork = trackMetadata?.artwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFit()
                    .frame(width: width, height: width)
                    .background(palette.paper)
            } else {
                ZStack {
                    LinearGradient(colors: [palette.paper, palette.wash], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(palette.highlight.opacity(0.55)).frame(width: width * 0.68).blur(radius: width * 0.13)
                    ForEach(0..<3) { ring in
                        Circle()
                            .strokeBorder(palette.accent.opacity(0.12), lineWidth: 1)
                            .frame(width: width * (0.55 + 0.11 * Double(ring)))
                            .offset(x: width * palette.orbitOffset, y: -width * 0.07)
                    }
                    Image(ToolIllustration.Scene.playback.rawValue)
                        .resizable().scaledToFit()
                        .frame(width: width * 0.93)
                }
                .frame(width: width, height: width)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(true)
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(
                get: { min(duration, scrubbing ?? elapsed) },
                set: { value in
                    if scrubbing != nil { scrubbing = value }
                    else { session.seek(value) }
                }), in: 0...max(0.01, duration), onEditingChanged: { editing in
                    if editing { scrubbing = elapsed }
                    else if let scrubbing { session.seek(scrubbing); self.scrubbing = nil }
                })
            .disabled(duration <= 0)
            .accessibilityLabel(ToolText.text("position"))
            .accessibilityIdentifier("media.music.timeline")
            HStack {
                Text(clock(scrubbing ?? elapsed)).accessibilityIdentifier("media.music.elapsed")
                Spacer()
                Text(duration > 0 ? clock(duration) : "–:––")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(ink.opacity(0.68))
        }
        .padding(.top, 12)
    }

    private func details(extraSpacing: CGFloat) -> some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trackTitle)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .lineLimit(2)
                    .accessibilityIdentifier("media.music.title")
                if let secondary = trackMetadata?.artist ?? trackMetadata?.album {
                    Text(secondary).font(.subheadline).foregroundStyle(ink.opacity(0.68)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                Button { session.loop.toggle() } label: {
                    Image(systemName: session.loop || !queueAvailable ? "repeat.1" : "repeat")
                        .foregroundStyle(session.loop ? accent : ink.opacity(0.72))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(ToolText.text("loop"))
                .accessibilityAddTraits(session.loop ? .isSelected : [])
                Spacer(minLength: 0)
                stepButton(forward: false)
                Spacer(minLength: 0)
                Button { session.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .offset(x: playing ? 0 : 1)
                        .foregroundStyle(dark ? background : .white)
                        .frame(width: 62, height: 62)
                        .background(accent, in: Circle())
                }
                .accessibilityLabel(ToolText.text(playing ? "pause" : "play"))
                .accessibilityIdentifier("media.music.play")
                Spacer(minLength: 0)
                stepButton(forward: true)
                Spacer(minLength: 0)
                Button { showsQueue = true } label: {
                    Image(systemName: "music.note.list").frame(width: 44, height: 44)
                }
                .disabled(!queueAvailable)
                .accessibilityLabel(ToolText.text("music_queue"))
                .accessibilityIdentifier("media.music.queue")
            }
            .font(.system(size: 18, weight: .medium))
            .buttonStyle(.plain)
            .padding(.top, extraSpacing * 0.42)
            .disabled(!isCurrentTrack)
            if let error = session.error ?? session.startupWarning, isCurrentTrack {
                VideoPlaybackStatus(message: error, identifier: "media.music.status", retry: session.soulo?.retry)
            }
        }
        .padding(.top, 14 + extraSpacing * 0.28)
    }

    private func stepButton(forward: Bool) -> some View {
        let label = queueAvailable
            ? ToolText.text(forward ? "music_next_track" : "music_previous_track")
            : ToolText.text("position") + (forward ? " +15 s" : " −15 s")
        return Button {
            if queueAvailable { session.advanceLocalAudio(by: forward ? 1 : -1, wrapping: true) }
            else { session.seek(elapsed + (forward ? 15 : -15)) }
        } label: {
            Image(systemName: queueAvailable ? (forward ? "forward.end.fill" : "backward.end.fill")
                : (forward ? "goforward.15" : "gobackward.15"))
                .frame(width: 44, height: 44)
        }
        .disabled(!queueAvailable && duration <= 0)
        .accessibilityLabel(label)
        .accessibilityIdentifier(forward ? "media.music.next" : "media.music.previous")
    }

    private var queue: some View {
        NavigationStack {
            List(Array(session.localAudioPlaylist.enumerated()), id: \.offset) { index, track in
                Button {
                    session.playLocalAudio(at: index)
                    showsQueue = false
                } label: {
                    HStack {
                        Text(track.deletingPathExtension().lastPathComponent).lineLimit(2)
                        Spacer()
                        if index == session.localAudioIndex { Image(systemName: "speaker.wave.2.fill").foregroundStyle(accent) }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityAddTraits(index == session.localAudioIndex ? .isSelected : [])
                .accessibilityIdentifier("media.music.queue.\(index)")
            }
            .navigationTitle(ToolText.text("music_queue"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ToolText.text("done")) { showsQueue = false }
                }
            }
        }
    }

    private func leave() {
        if let close { close() } else { dismiss() }
    }

    private func clock(_ value: Double) -> String {
        let seconds = Int(exactly: value.rounded(.towardZero)) ?? 0
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MusicCoverPalette {
    let paper: Color
    let wash: Color
    let accent: Color
    let highlight: Color
    let orbitOffset: CGFloat

    init(url: URL) {
        let colors = [
            ("F0E9F4", "C8C1E5", "625190", "C4B6F2"),
            ("F6E9DE", "E6BCAC", "854E51", "ECB8AC"),
            ("ECF2F6", "B7CDE6", "385A89", "9CC9F3"),
            ("EFF3E9", "BBD5C1", "365F55", "A5D1B7"),
            ("F7EDD9", "E9C9A5", "7D5235", "EBC397")
        ]
        let identity = url.isFileURL ? url.lastPathComponent : url.absoluteString
        let hash = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let selected = colors[Int(hash % UInt64(colors.count))]
        paper = Color(hex: selected.0); wash = Color(hex: selected.1)
        accent = Color(hex: selected.2); highlight = Color(hex: selected.3)
        orbitOffset = CGFloat((hash >> 16) % 31) / 100 - 0.15
    }
}
