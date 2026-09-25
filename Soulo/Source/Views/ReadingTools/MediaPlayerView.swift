import AVKit
import SwiftUI

struct VideoOrientationErrorAlert: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content.alert(ToolText.text("error"), isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button(ToolText.text("done")) { message = nil }
        } message: { Text(message ?? "") }
    }
}

@MainActor enum VideoOrientation {
    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    static func request(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene?,
                        onError: @escaping (Error) -> Void) {
        guard let scene else { onError(CocoaError(.featureUnsupported)); return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations), errorHandler: onError)
    }
}

/// A fullscreen session may originate from any frame, but only that session
/// can rotate and restore its owning window. A failed entry never rotates.
@MainActor final class WebVideoFullscreenOrientation {
    private var token: String?
    private weak var scene: UIWindowScene?
    private weak var sourceWindow: UIWindow?
    private var original: UIInterfaceOrientation = .portrait
    private var prefersLandscape = true
    private var began = false
    private var transition: Task<Void, Never>?

    func prepare(token: String, scene: UIWindowScene, prefersLandscape: Bool) {
        guard self.token == nil else { return }
        transition?.cancel()
        self.token = token
        self.scene = scene
        sourceWindow = scene.keyWindow
        original = scene.interfaceOrientation
        self.prefersLandscape = prefersLandscape
        began = false
    }

    func begin(token: String, onError: @escaping (Error) -> Void) {
        guard self.token == token, !began else { return }
        began = true
        guard prefersLandscape else { return }
        transition = Task { @MainActor [weak self] in
            // WebKit reports begin before AVKit finishes presenting. During
            // that transition AVKit temporarily supports portrait only. Wait
            // for the fullscreen controller's actual supported orientations.
            for _ in 0..<60 {
                guard !Task.isCancelled, let self, self.token == token, let scene = self.scene else { return }
                let window = scene.keyWindow
                var controller = window?.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                let fullscreenPresented = window !== self.sourceWindow
                    || self.sourceWindow?.rootViewController?.presentedViewController != nil
                if fullscreenPresented, let controller,
                   !controller.isBeingPresented, controller.transitionCoordinator == nil,
                   !controller.supportedInterfaceOrientations.intersection(.landscape).isEmpty {
                    VideoOrientation.request(.landscape, in: scene, onError: onError)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Do not rotate the underlying page if presentation never finishes.

        }
    }

    func end(token: String? = nil) {
        guard self.token != nil, token == nil || self.token == token else { return }
        transition?.cancel()
        let scene = scene, source = sourceWindow, orientation = original, restore = began
        self.token = nil
        self.scene = nil
        self.sourceWindow = nil
        began = false
        guard restore else { return }
        transition = Task { @MainActor in
            // AVKit also pins the current orientation while dismissing. Restore
            // only once the original window has become key again.
            for _ in 0..<60 {
                guard !Task.isCancelled, let scene else { return }
                var controller = source?.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                let mask = VideoOrientation.mask(for: orientation)
                if scene.keyWindow === source, let controller,
                   !controller.isBeingDismissed, controller.transitionCoordinator == nil,
                   !controller.supportedInterfaceOrientations.intersection(mask).isEmpty {
                    if scene.interfaceOrientation != orientation {
                        VideoOrientation.request(mask, in: scene) { _ in }
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

    }
}

/// Phone and rotation arrow, matching the inline web player control.
struct LandscapePlaybackIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.scaleBy(x: scale, y: scale)
            var phone = Path(roundedRect: CGRect(x: 3, y: 3, width: 10, height: 18), cornerRadius: 2.5)
            phone.move(to: CGPoint(x: 6.5, y: 6)); phone.addLine(to: CGPoint(x: 9.5, y: 6))
            phone.addEllipse(in: CGRect(x: 7.1, y: 16.6, width: 1.8, height: 1.8))
            phone.move(to: CGPoint(x: 16, y: 12)); phone.addLine(to: CGPoint(x: 18.5, y: 12))
            phone.addQuadCurve(to: CGPoint(x: 21, y: 14.5), control: CGPoint(x: 21, y: 12))
            phone.addLine(to: CGPoint(x: 21, y: 18.5))
            phone.addQuadCurve(to: CGPoint(x: 18.5, y: 21), control: CGPoint(x: 21, y: 21))
            phone.addLine(to: CGPoint(x: 16, y: 21))
            phone.move(to: CGPoint(x: 16, y: 3))
            phone.addCurve(to: CGPoint(x: 21, y: 9), control1: CGPoint(x: 19, y: 3.5), control2: CGPoint(x: 20.5, y: 6))
            phone.move(to: CGPoint(x: 18, y: 8)); phone.addLine(to: CGPoint(x: 21, y: 9))
            phone.addLine(to: CGPoint(x: 21.5, y: 6))
            context.stroke(phone, with: .foreground, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}

/// A mounted control uses its own scene, including when another iPad window is open.
private struct VideoRotationButton: UIViewRepresentable {
    final class Button: UIButton {
        override func layoutSubviews() {
            super.layoutSubviews()
            let landscape = window?.windowScene?.interfaceOrientation.isLandscape == true
            accessibilityLabel = ToolText.text(landscape ? "media_portrait" : "media_landscape")
            setImage(UIImage(systemName: landscape ? "iphone" : "iphone.landscape"), for: .normal)
        }
        @objc func rotateVideo() {
            guard let scene = window?.windowScene else { return }
            VideoOrientation.request(scene.interfaceOrientation.isLandscape ? .portrait : .landscape, in: scene) {
                MediaSession.shared.error = $0.localizedDescription
            }
        }
    }
    func makeUIView(context: Context) -> Button {
        let button = Button(type: .system)
        button.setImage(UIImage(systemName: "iphone.landscape"), for: .normal)
        button.tintColor = .white
        button.accessibilityIdentifier = "media.rotate"
        button.addTarget(button, action: #selector(Button.rotateVideo), for: .touchUpInside)
        return button
    }
    func updateUIView(_ view: Button, context: Context) { view.setNeedsLayout() }
}

private struct FullScreenVideoOrientation: UIViewControllerRepresentable {
    let landscape: Bool
    final class Controller: UIViewController {
        var landscape = false
        weak var playbackScene: UIWindowScene?
        var originalOrientation: UIInterfaceOrientation?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard originalOrientation == nil, let scene = view.window?.windowScene else { return }
            playbackScene = scene
            originalOrientation = scene.interfaceOrientation
            if landscape {
                VideoOrientation.request(.landscape, in: scene) { MediaSession.shared.error = $0.localizedDescription }
            }
        }
        func restore() {
            guard let scene = playbackScene, let orientation = originalOrientation,
                  scene.interfaceOrientation != orientation else { return }
            VideoOrientation.request(VideoOrientation.mask(for: orientation), in: scene) {
                MediaSession.shared.error = $0.localizedDescription
            }
        }
    }
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.landscape = landscape
        controller.view.isUserInteractionEnabled = false
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {}
    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        // Let dismissal finish before requesting the previous page's geometry.
        Task { @MainActor in controller.restore() }
    }
}

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
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.4
        hold.delegate = context.coordinator
        view.view.addGestureRecognizer(hold)
        return view
    }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ view: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detached = true
        if !coordinator.pipActive { view.player = nil }
        Task { @MainActor in
            MediaSession.shared.endTemporaryRate()
            MediaSession.shared.playerSurfaces = max(0, MediaSession.shared.playerSurfaces - 1)
        }
    }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        @objc func handleHold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { MediaSession.shared.beginTemporaryRate() }
            else if [.ended, .cancelled, .failed].contains(gesture.state) { MediaSession.shared.endTemporaryRate() }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }
        var pipActive = false
        var detached = false
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = true
            Task { @MainActor in
                MediaSession.shared.retainedPiPController = playerViewController
                MediaSession.shared.retainedPiPDelegate = self
            }
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pipActive = false
            let detach = detached
            Task { @MainActor in
                if detach { playerViewController.player = nil }
                if MediaSession.shared.retainedPiPController === playerViewController {
                    MediaSession.shared.retainedPiPController = nil
                    MediaSession.shared.retainedPiPDelegate = nil
                }
            }
        }
        func playerViewController(
            _ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error
        ) {
            pipActive = false
            Task { @MainActor in
                MediaSession.shared.retainedPiPController = nil
                MediaSession.shared.retainedPiPDelegate = nil
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
    @ObservedObject private var pip = MediaSession.shared.pictureInPicture
    var fullScreen: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 20) {
            if session.hasVideo {
                HStack {
                    if pip.supported {
                    Button { pip.toggle() } label: {
                        Label(ToolText.text("media_pip"), systemImage: pip.active ? "pip.exit" : "pip.enter")
                            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                    }
                    .disabled(!pip.possible && !pip.active)
                    .accessibilityIdentifier("media.picture-in-picture")
                    .accessibilityHint(ToolText.text("media_pip_hint"))
                    }
                    Spacer()
                    AirPlayRoutePicker().frame(width: 44, height: 44)
                    if let fullScreen {
                        Button(action: fullScreen) {
                            Group {
                                if session.videoIsLandscape {
                                    LandscapePlaybackIcon()
                                } else {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                }
                            }
                            .frame(width: 44, height: 44)
                        }
                        .disabled(pip.active)
                        .accessibilityLabel(ToolText.text(session.videoIsLandscape ? "media_landscape" : "media_fullscreen"))
                        .accessibilityIdentifier("media.fullscreen")
                    }
                }
                .foregroundStyle(.primary)
                .buttonStyle(.borderless)
            }
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
    var body: some View {
        MediaPlaybackContent()
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum MiniPlayerDocking {
    static func shouldDock(center: CGFloat, width: CGFloat) -> Bool { center < 48 || center > width - 48 }
    static func verticalPosition(offset: CGFloat, height: CGFloat) -> CGFloat {
        min(max(40, height - 140 + offset), max(40, height - 100))
    }

    static func seekTarget(current: Double, duration: Double, translation: CGFloat) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(duration, max(0, current + Double(translation) / 3))
    }
}

struct MediaMiniPlayer: View {
    @ObservedObject var session = MediaSession.shared
    @ObservedObject private var pip = MediaSession.shared.pictureInPicture
    @State private var trailing = true
    @State private var docked = false
    @State private var y: CGFloat = 0
    @State private var seekPreview: Double?
    @GestureState private var drag = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            if session.url != nil && session.playerSurfaces == 0 && !session.expanded && !pip.active && session.retainedPiPController == nil {
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
                            if session.hasVideo {
                                InlineVideoSurface(countsAsPlayerSurface: false)
                                    .frame(width: 52, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                    .onTapGesture { session.expanded = true }
                                    .highPriorityGesture(
                                        DragGesture(minimumDistance: 12)
                                            .onChanged { value in
                                                guard abs(value.translation.width) > abs(value.translation.height),
                                                      let target = MiniPlayerDocking.seekTarget(
                                                        current: session.elapsed,
                                                        duration: session.duration,
                                                        translation: value.translation.width
                                                      ) else { return }
                                                seekPreview = target
                                            }
                                            .onEnded { value in
                                                if abs(value.translation.width) > abs(value.translation.height),
                                                   let target = MiniPlayerDocking.seekTarget(
                                                    current: session.elapsed,
                                                    duration: session.duration,
                                                    translation: value.translation.width
                                                   ) {
                                                    session.seek(target)
                                                }
                                                seekPreview = nil
                                            }
                                    )
                                    .accessibilityHint(ToolText.text("position"))
                            } else {
                                Image(systemName: "waveform").foregroundStyle(Color.themePrimary)
                            }
                            Button { session.expanded = true } label: {
                                Text(session.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .overlay(alignment: .top) {
                    if let seekPreview {
                        Text("\(Int(seekPreview) / 60):\(String(format: "%02d", Int(seekPreview) % 60))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .offset(y: -38)
                            .allowsHitTesting(false)
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

struct MediaPlaybackSurface: View {
    @ObservedObject private var session = MediaSession.shared
    var body: some View {
        if session.hasVideo {
            if session.retainedPiPController != nil {
                // A native full-screen player's PiP still owns video rendering.
                // Attaching a second AVPlayerLayer here would interrupt that window.
                Label(ToolText.text("media_pip"), systemImage: "pip")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            } else {
                InlineVideoSurface()
            }
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

private struct InlineVideoSurface: UIViewRepresentable {
    @ObservedObject private var session = MediaSession.shared
    var countsAsPlayerSurface = true
    final class Host: UIView {
        let attachment = UUID()
        var countsAsPlayerSurface = true
        weak var video: MediaPictureInPicture.Surface?
        @objc func handleHold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { MediaSession.shared.beginTemporaryRate() }
            else if [.ended, .cancelled, .failed].contains(gesture.state) { MediaSession.shared.endTemporaryRate() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            video?.transform = .identity
            video?.frame = bounds
            video?.transform = CGAffineTransform(scaleX: MediaSession.shared.mirrored ? -1 : 1, y: 1)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            MediaSession.shared.pictureInPicture.didMount()
        }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.countsAsPlayerSurface = countsAsPlayerSurface
        let surface = MediaSession.shared.pictureInPicture.attach(id: host.attachment, primary: countsAsPlayerSurface)
        host.video = surface
        if let surface { host.addSubview(surface) }
        host.backgroundColor = .black
        if countsAsPlayerSurface {
            let hold = UILongPressGestureRecognizer(target: host, action: #selector(Host.handleHold(_:)))
            hold.minimumPressDuration = 0.4
            host.addGestureRecognizer(hold)
            Task { @MainActor in MediaSession.shared.playerSurfaces += 1 }
        }
        return host
    }
    func updateUIView(_ view: Host, context: Context) { view.setNeedsLayout() }
    static func dismantleUIView(_ view: Host, coordinator: Void) {
        // The session keeps the source layer alive while system PiP is active.
        if view.video?.superview === view { view.video?.removeFromSuperview() }
        Task { @MainActor in
            MediaSession.shared.pictureInPicture.detach(id: view.attachment)
            if view.countsAsPlayerSurface {
                MediaSession.shared.endTemporaryRate()
                MediaSession.shared.playerSurfaces = max(0, MediaSession.shared.playerSurfaces - 1)
            }
        }
    }
}

/// The same controls and PiP source are used by file, download and web-resource previews.
struct MediaPlaybackContent: View {
    @ObservedObject private var session = MediaSession.shared
    @State private var showingFullScreen = false
    @State private var landscapeFullScreen = false
    @State private var frame: CapturedMediaFrame?
    @State private var capturing = false
    @State private var captureTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compact: Bool { verticalSizeClass == .compact && session.hasVideo }

    private var playbackControls: some View {
        MediaControls(fullScreen: {
            landscapeFullScreen = session.videoIsLandscape
            showingFullScreen = true
        })
    }

    private var playbackPreview: some View {
        MediaPlaybackSurface().overlay(alignment: .top) {
            if session.temporaryRate {
                Text("2×").font(.callout.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding().allowsHitTesting(false)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = compact ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if !showingFullScreen {
                    playbackPreview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("media.preview")
                }
                if compact {
                    ScrollView {
                        playbackControls
                    }
                    .frame(width: min(340, geometry.size.width * 0.43))
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                } else {
                    playbackControls
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if session.hasVideo {
                        Toggle(isOn: $session.mirrored) {
                            ToolMenuLabel(key: "media_mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        }
                        Button {
                            capturing = true
                            captureTask = Task {
                                defer { capturing = false; captureTask = nil }
                                do { frame = CapturedMediaFrame(image: try await session.captureFrame()) }
                                catch is CancellationError { }
                                catch { session.error = error.localizedDescription }
                            }
                        } label: { ToolMenuLabel(key: "media_snapshot", symbol: "camera") }
                        .disabled(capturing)
                    }
                    if let url = session.url {
                        ShareLink(item: url) { ToolMenuLabel(key: "share_media", symbol: "square.and.arrow.up") }
                    }
                    if let url = session.pageURL {
                        ShareLink(item: url) { ToolMenuLabel(key: "share_page", symbol: "globe") }
                    }
                    Button(ToolText.text("stop"), role: .destructive) { session.stop(); dismiss() }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityIdentifier("media.options")
            }
        }
        .onDisappear { captureTask?.cancel(); session.endTemporaryRate() }
        .sheet(item: $frame) { item in MediaFrameShare(image: item.image) }
        .fullScreenCover(isPresented: $showingFullScreen) {
            Group {
                if session.mirrored {
                    VStack(spacing: 0) {
                        MediaPlaybackSurface()
                        MediaControls()
                    }.background(.black).preferredColorScheme(.dark)
                } else { SessionPlayerController().ignoresSafeArea() }
            }
                .background(FullScreenVideoOrientation(landscape: landscapeFullScreen))
                .overlay(alignment: .topTrailing) {
                    VideoRotationButton().frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle()).padding()
                }
                .overlay(alignment: .topLeading) {
                    Button { showingFullScreen = false } label: {
                        Image(systemName: "xmark").font(.headline).padding(14)
                            .background(.regularMaterial, in: Circle())
                    }.padding().accessibilityLabel(ToolText.text("close"))
                }
        }
    }
}

private struct CapturedMediaFrame: Identifiable {
    let id = UUID()
    let image: UIImage
}
private struct MediaFrameShare: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ view: UIActivityViewController, context: Context) {}
}

/// Menu icons use the same neutral colors as the rest of the browser's menus.
struct ToolMenuLabel: View {
    let key: String
    let symbol: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Label {
            Text(ToolText.text(key))
        } icon: {
            if let image = UIImage(systemName: symbol)?.withTintColor(colorScheme == .dark ? .white : .black, renderingMode: .alwaysOriginal) {
                Image(uiImage: image)
            } else { Image(systemName: symbol).foregroundStyle(.primary) }
        }
    }
}
