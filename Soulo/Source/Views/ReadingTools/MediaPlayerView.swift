import AVKit
import SwiftUI

struct SessionPlayerController: UIViewControllerRepresentable {
    @ObservedObject var session = MediaSession.shared
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.player = session.player
        Task { @MainActor in session.playerSurfaces += 1 }
        view.delegate = context.coordinator
        view.allowsPictureInPicturePlayback = true
        view.canStartPictureInPictureAutomaticallyFromInline = true
        return view
    }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ view: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detached = true
        if !coordinator.pipActive { view.player = nil }
        Task { @MainActor in MediaSession.shared.playerSurfaces = max(0, MediaSession.shared.playerSurfaces - 1) }
    }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var pipActive = false
        var detached = false
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = true
            Task { @MainActor in MediaSession.shared.retainedPiPController = playerViewController }
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = false
            let detach = detached
            Task { @MainActor in
                if detach { playerViewController.player = nil }
                if MediaSession.shared.retainedPiPController === playerViewController {
                    MediaSession.shared.retainedPiPController = nil
                }
            }
        }
        func playerViewController(
            _ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error
        ) {
            pipActive = false
            Task { @MainActor in
                MediaSession.shared.retainedPiPController = nil
                MediaSession.shared.error = error.localizedDescription
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            Task { @MainActor in
                if playerViewController.view.window == nil { MediaSession.shared.expanded = true }
                completionHandler(true)
            }
        }
    }
}

struct MediaControls: View {
    @ObservedObject var session = MediaSession.shared
    var body: some View {
        VStack(spacing: 20) {
            if session.duration > 0 {
                HStack {
                    Text(clock(session.elapsed))
                    Spacer()
                    Text(clock(session.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { session.elapsed }, set: { session.seek($0) }),
                    in: 0...max(1, session.duration)
                )
                .accessibilityLabel(ToolText.text("position"))
            }
            HStack(spacing: 8) {
                Button {
                    session.seek(session.elapsed - 15)
                } label: {
                    CompactIconLabel(systemImage: "gobackward.15")
                }
                Button {
                    session.toggle()
                } label: {
                    Image(systemName: session.playing ? "pause.fill" : "play.fill").font(.title).frame(
                        width: 44, height: 44)
                }
                Button {
                    session.seek(session.elapsed + 15)
                } label: {
                    CompactIconLabel(systemImage: "goforward.15")
                }
                Spacer()
                Button {
                    session.loop.toggle()
                } label: {
                    CompactIconLabel(systemImage: "repeat.1", emphasized: session.loop)
                }
                .accessibilityLabel(ToolText.text("loop"))
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8, 16], id: \.self) { value in
                        Button("\(value.formatted())×") { session.setRate(Float(value)) }
                    }
                    ControlGroup {
                        Button("−0.1") { session.setRate(max(0.5, session.rate - 0.1)) }
                        Button("+0.1") { session.setRate(min(16, session.rate + 0.1)) }
                    }
                } label: {
                    Text("\(session.rate.formatted())×").monospacedDigit().frame(minWidth: 44, minHeight: 44)
                }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            if let error = session.error {
                Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding()
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MediaPlayerPage: View {
    @ObservedObject var session = MediaSession.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {

        VStack(spacing: 0) {
            MediaPlaybackSurface()
            MediaControls()
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let url = session.url {
                        ShareLink(item: url) { Label(ToolText.text("share_media"), systemImage: "link") }
                    }
                    if let url = session.pageURL {
                        ShareLink(item: url) { Label(ToolText.text("share_page"), systemImage: "globe") }
                    }
                    Button(ToolText.text("stop"), role: .destructive) {
                        session.stop()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
            }
        }

    }
}

enum MiniPlayerDocking {
    static func shouldDock(center: CGFloat, width: CGFloat) -> Bool { center < 48 || center > width - 48 }
    static func verticalPosition(offset: CGFloat, height: CGFloat) -> CGFloat {
        min(max(40, height - 140 + offset), max(40, height - 100))
    }
}

struct MediaMiniPlayer: View {
    @ObservedObject var session = MediaSession.shared
    @State private var trailing = true
    @State private var docked = false
    @State private var y: CGFloat = 0
    @GestureState private var drag = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            if session.url != nil && session.playerSurfaces == 0 && !session.expanded {
                let width = min(320.0, max(44, geometry.size.width - 24))
                let center = docked ? (trailing ? geometry.size.width - 18 : 18)
                    : (trailing ? geometry.size.width - width / 2 - 12 : width / 2 + 12)
                Group {
                    if docked {
                        Button { withAnimation(.snappy) { docked = false } } label: {
                            Image(systemName: trailing ? "chevron.left" : "chevron.right")
                                .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 52)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .frame(width: 44, height: 58)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(ToolText.text("expand_player"))
                    } else {
                        HStack(spacing: 6) {
                            Button { withAnimation(.snappy) { docked = true } } label: {
                                Image(systemName: trailing ? "chevron.right" : "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(ToolText.text("dock_player"))
                            Button { session.expanded = true } label: {
                                HStack(spacing: 8) {
                                    if session.hasVideo {
                                        MiniVideoSurface().frame(width: 52, height: 38)
                                            .clipShape(RoundedRectangle(cornerRadius: 7))
                                    } else {
                                        Image(systemName: "waveform").foregroundStyle(Color.themePrimary)
                                    }
                                    Text(session.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                        .foregroundStyle(.primary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { session.toggle() } label: {
                                CompactIconLabel(systemImage: session.playing ? "pause.fill" : "play.fill")
                            }.buttonStyle(.plain)
                                .accessibilityLabel(ToolText.text(session.playing ? "pause" : "play"))
                            Button { session.stop() } label: {
                                CompactIconLabel(systemImage: "xmark")
                            }.buttonStyle(.plain).accessibilityLabel(ToolText.text("close"))
                        }
                        .padding(.horizontal, 4).frame(width: width, height: 58)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .position(x: center, y: MiniPlayerDocking.verticalPosition(offset: y, height: geometry.size.height))
                .offset(drag)
                .gesture(DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        withAnimation(.snappy) {
                            let end = center + value.translation.width
                            trailing = end > geometry.size.width / 2
                            docked = MiniPlayerDocking.shouldDock(center: end, width: geometry.size.width)
                            y = min(40, max(-geometry.size.height + 180, y + value.translation.height))
                        }
                    })
                .accessibilityAction(named: ToolText.text(docked ? "expand_player" : "dock_player")) {
                    withAnimation(.snappy) { docked.toggle() }
                }
            }
        }
    }
}

private struct MiniVideoSurface: UIViewRepresentable {
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        let layer = view.layer as! AVPlayerLayer
        layer.player = MediaSession.shared.player
        layer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {}
    static func dismantleUIView(_ view: Surface, coordinator: Void) { (view.layer as? AVPlayerLayer)?.player = nil }
}

struct MediaPlaybackSurface: View {
    @ObservedObject private var session = MediaSession.shared
    var body: some View {
        if session.hasVideo {
            SessionPlayerController()
        } else {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(Color.themePrimary)
                    .frame(width: 180, height: 180)
                    .background(Color.themePrimary.opacity(0.09), in: RoundedRectangle(cornerRadius: 36))
                VStack(spacing: 8) {
                    Text(session.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                    Text(
                        session.pageURL?.host
                            ?? (session.url?.isFileURL == true ? ToolText.text("local_media") : session.url?.host ?? "")
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal, 28)
                HStack(spacing: 4) {
                    AirPlayRoutePicker().frame(width: 44, height: 44)
                    Text("AirPlay").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { session.playerSurfaces += 1 }
                .onDisappear { session.playerSurfaces = max(0, session.playerSurfaces - 1) }
        }
    }
}
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.accessibilityLabel = "AirPlay"
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// Present from the visible page so expanding the floating player preserves
// the user's directory and the existing back stack.
private struct MediaPlayerNavigation: ViewModifier {
    @ObservedObject private var session = MediaSession.shared
    @State private var visible = false
    @State private var showingPlayer = false
    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .onChange(of: session.expanded) { _, requested in
                guard requested, visible, !showingPlayer else { return }
                session.expanded = false
                showingPlayer = true
            }
            .navigationDestination(isPresented: $showingPlayer) {
                MediaPlayerPage().toolbar(.visible, for: .navigationBar)
            }
    }
}
extension View {
    func mediaPlayerNavigation() -> some View { modifier(MediaPlayerNavigation()) }
}
