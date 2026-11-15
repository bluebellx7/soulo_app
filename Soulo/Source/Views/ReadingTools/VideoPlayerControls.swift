import SwiftUI
import AVFoundation
import MediaPlayer

struct VideoGestureFeedback {
    enum Kind: Equatable { case rate, brightness, volume, seek }
    let kind: Kind
    let value: Double
    var delta: Double? = nil
    var symbol: String {
        switch kind { case .rate: "speedometer"; case .brightness: "sun.max.fill"; case .volume: "speaker.wave.2.fill"; case .seek: (delta ?? 0) < 0 ? "gobackward" : "goforward" }
    }
    var text: String {
        if kind == .seek {
            let seconds = Int(max(0, value)), change = Int(abs(delta ?? 0))
            return String(format: "%d:%02d  %@%d:%02d", seconds / 60, seconds % 60, (delta ?? 0) < 0 ? "−" : "+", change / 60, change % 60)
        }
        return kind == .rate ? String(format: "%g×", value) : "\(Int((value * 100).rounded()))%"
    }
}

/// Keep adjustment feedback clear of the central transport controls.
struct VideoGestureFeedbackView: View {
    let feedback: VideoGestureFeedback
    let identifier: String
    var body: some View {
        GeometryReader { geometry in
            Label(feedback.text, systemImage: feedback.symbol)
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.black.opacity(0.72), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(feedback.text)
                .accessibilityIdentifier(identifier)
                .position(x: geometry.size.width / 2, y: max(32, geometry.size.height * 0.25))
        }
        .allowsHitTesting(false)
    }
}

/// Shared horizontal seek and vertical adjustment routing for both decoders. Player state owns brightness
/// restoration; moving an output surface between inline/fullscreen keeps it intact.
final class VideoVerticalGestureHandler: NSObject, UIGestureRecognizerDelegate {
    private weak var view: UIView?
    private let volumeControl = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 120, height: 40))
    private let enabled: () -> Bool
    private let brightness: (CGFloat, UIScreen) -> Void
    private let feedback: (VideoGestureFeedback.Kind, Double) -> Void
    private let ended: () -> Void
    private let position: () -> (elapsed: Double, duration: Double)
    private let previewSeek: (Double, Double) -> Void
    private let seek: (Double) -> Void
    private var seeking = false
    private var startTime = 0.0
    private var seekDuration = 0.0
    private var adjustingBrightness = false
    private var startingValue: CGFloat = 0
    private var volumeSlider: UISlider? { volumeControl.subviews.compactMap { $0 as? UISlider }.first }

    init(in view: UIView, enabled: @escaping () -> Bool, brightness: @escaping (CGFloat, UIScreen) -> Void,
         feedback: @escaping (VideoGestureFeedback.Kind, Double) -> Void,
         position: @escaping () -> (elapsed: Double, duration: Double), previewSeek: @escaping (Double, Double) -> Void,
         seek: @escaping (Double) -> Void, ended: @escaping () -> Void) {
        self.view = view; self.enabled = enabled; self.brightness = brightness; self.feedback = feedback; self.ended = ended
        self.position = position; self.previewSeek = previewSeek; self.seek = seek
        super.init()
        volumeControl.showsRouteButton = false
        volumeControl.isUserInteractionEnabled = false
        volumeControl.accessibilityElementsHidden = true
        view.addSubview(volumeControl)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(adjusted(_:)))
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        view.addGestureRecognizer(pan)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard enabled(), let view, view.bounds.width >= 100, view.bounds.height >= 80,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        if abs(velocity.x) > abs(velocity.y) * 1.2 {
            let state = position()
            return VideoSeekGesture.target(start: state.elapsed, duration: state.duration, translation: 0, width: view.bounds.width) != nil
        }
        return abs(velocity.y) > abs(velocity.x) * 1.2
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UILongPressGestureRecognizer
    }
    @objc private func adjusted(_ gesture: UIPanGestureRecognizer) {
        guard let view, let screen = view.window?.windowScene?.screen else { return }
        switch gesture.state {
        case .began:
            let velocity = gesture.velocity(in: view)
            seeking = abs(velocity.x) > abs(velocity.y)
            if seeking {
                let state = position(); startTime = state.elapsed; seekDuration = state.duration
                previewSeek(startTime, startTime)
                return
            }
            volumeControl.layoutIfNeeded()
            adjustingBrightness = gesture.location(in: view).x < view.bounds.midX
            startingValue = adjustingBrightness ? screen.brightness : CGFloat(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
            feedback(adjustingBrightness ? .brightness : .volume, Double(startingValue))
        case .changed:
            if seeking {
                if let target = VideoSeekGesture.target(start: startTime, duration: seekDuration,
                    translation: gesture.translation(in: view).x, width: view.bounds.width) { previewSeek(target, startTime) }
                return
            }
            let value = min(1, max(0, startingValue - gesture.translation(in: view).y / max(150, view.bounds.height * 0.7)))
            if adjustingBrightness { brightness(value, screen) }
            else {
                volumeSlider?.setValue(Float(value), animated: false)
                volumeSlider?.sendActions(for: .valueChanged)
                feedback(.volume, Double(value))
            }
        case .ended, .cancelled, .failed:
            if seeking {
                if gesture.state == .ended, let target = VideoSeekGesture.target(start: startTime, duration: seekDuration,
                    translation: gesture.translation(in: view).x, width: view.bounds.width) { seek(target) }
                seeking = false
            } else if !adjustingBrightness { volumeSlider?.sendActions(for: .touchUpInside) }
            ended()
        default: break
        }
    }
}

/// System glass can be bright even above a dark video. Give video menus an
/// explicit surface and foreground pair instead of inheriting mismatched colors.
private struct VideoPopoverSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .compatiblePresentationBackground(colorScheme == .dark ? Color(white: 0.12) : Color.white)
    }
}
extension View {
    func videoPopoverSurface() -> some View { modifier(VideoPopoverSurface()) }
}

private struct VideoFullscreenInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}
extension EnvironmentValues {
    var videoFullscreenInsets: EdgeInsets {
        get { self[VideoFullscreenInsetsKey.self] }
        set { self[VideoFullscreenInsetsKey.self] = newValue }
    }
}

/// A fullscreen session survives decoder changes. Switching modes updates the
/// content of this controller, preserving its window, geometry and orientation.
enum VideoFullscreenDismissal { case closePlayback, exitFullscreen }
private struct VideoFullscreenRotationKey: EnvironmentKey {
    static let defaultValue: ((Bool, @escaping (Error) -> Void) -> Void)? = nil
}
private extension EnvironmentValues {
    var videoFullscreenRotation: ((Bool, @escaping (Error) -> Void) -> Void)? {
        get { self[VideoFullscreenRotationKey.self] }
        set { self[VideoFullscreenRotationKey.self] = newValue }
    }
}

@MainActor final class SharedVideoFullscreenHost {
    final class Screen: UIHostingController<AnyView> {
        private var playerContent = AnyView(EmptyView())
        private var playerInsets = EdgeInsets()
        private var canvasLandscape: Bool?
        var closed: (() -> Void)?
        var rotate: ((Bool, @escaping (Error) -> Void) -> Void)?
        var openingOrientation: UIInterfaceOrientation = .portrait
        var allowedOrientations: UIInterfaceOrientationMask = .allButUpsideDown
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { openingOrientation }
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { allowedOrientations }
        override var prefersStatusBarHidden: Bool { true }
        func setContent(_ content: AnyView, initialInsets: UIEdgeInsets? = nil) {
            playerContent = content
            if let initialInsets { playerInsets = Self.insets(initialInsets) }
            rebuildCanvas()
        }
        func setCanvasLandscape(_ value: Bool?) { canvasLandscape = value; rebuildCanvas() }
        private func rebuildCanvas() {
            rootView = AnyView(VideoFullscreenCanvas(content: playerContent, landscape: canvasLandscape, insets: playerInsets)
                .environment(\.videoFullscreenRotation, rotate).preferredColorScheme(.dark))
        }
        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            guard view.window != nil else { return }
            let next = Self.insets(view.safeAreaInsets)
            guard next != playerInsets else { return }
            playerInsets = next; rebuildCanvas()
        }
        private static func insets(_ value: UIEdgeInsets) -> EdgeInsets {
            EdgeInsets(top: value.top, leading: value.left, bottom: value.bottom, trailing: value.right)
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed || presentingViewController == nil { closed?() }
        }
    }
    private static var sessions: [ObjectIdentifier: SharedVideoFullscreenHost] = [:]
    private let key: ObjectIdentifier
    private(set) var owner: UUID
    private(set) var screen: Screen?
    private var onClose: ((VideoFullscreenDismissal) -> Void)?
    private var handoffTask: Task<Void, Never>?
    private var handingOff = false
    private var rotationTask: Task<Void, Never>?
    private var rotationID = UUID()
    private weak var accessibilitySource: UIView?
    private var sourceAccessibilityWasHidden = false
    private let orientation = WebVideoFullscreenOrientation()
    private init(scene: UIWindowScene, owner: UUID) { key = ObjectIdentifier(scene); self.owner = owner }
    static func current(in window: UIWindow) -> SharedVideoFullscreenHost? {
        window.windowScene.flatMap { sessions[ObjectIdentifier($0)] }
    }
    static func window(for source: UIViewController) -> UIWindow? {
        var controller: UIViewController? = source
        while let current = controller {
            if let window = current.viewIfLoaded?.window ?? current.presentedViewController?.viewIfLoaded?.window { return window }
            controller = current.parent
        }
        return nil
    }
    static func present(owner: UUID, in window: UIWindow, content: AnyView, identifier: String,
                        landscape: Bool, onClose: @escaping (VideoFullscreenDismissal) -> Void) -> SharedVideoFullscreenHost? {
        guard let scene = window.windowScene else { return nil }
        if let current = current(in: window), let screen = current.screen {
            current.handoffTask?.cancel(); current.handoffTask = nil; current.handingOff = false
            current.owner = owner; current.onClose = onClose
            screen.view.accessibilityIdentifier = identifier; screen.setContent(content)
            return current
        }
        guard let source = VideoOrientation.topController(in: window),
              !source.isBeingPresented, !source.isBeingDismissed, source.transitionCoordinator == nil else { return nil }
        let current = SharedVideoFullscreenHost(scene: scene, owner: owner)
        let screen = Screen(rootView: content)
        // UIKit menus and popovers must share the fullscreen canvas appearance.
        screen.overrideUserInterfaceStyle = .dark
        screen.rotate = { [weak current] landscape, failure in
            guard let current else { failure(CocoaError(.featureUnsupported)); return }
            current.setLandscape(landscape, onError: failure)
        }
        screen.setContent(content, initialInsets: window.safeAreaInsets)
        screen.modalPresentationCapturesStatusBarAppearance = true
        screen.openingOrientation = UIDevice.current.userInterfaceIdiom == .pad ? scene.interfaceOrientation : (landscape ? VideoOrientation.landscapePresentation(in: scene) : .portrait)
        // Keep an explicitly landscape player landscape while iOS rebuilds
        // foreground geometry, even when the phone is held upright.
        screen.allowedOrientations = UIDevice.current.userInterfaceIdiom == .pad ? .allButUpsideDown : (landscape ? .landscape : .allButUpsideDown)
        // Keep the source mounted so the destination decoder can start while
        // this same fullscreen controller remains visible during a handoff.
        screen.modalPresentationStyle = .overFullScreen; screen.view.backgroundColor = .black
        screen.view.accessibilityIdentifier = identifier; screen.view.accessibilityViewIsModal = true
        screen.closed = { [weak current] in current?.finished(reason: .exitFullscreen) }
        current.screen = screen; current.onClose = onClose; sessions[current.key] = current
        current.accessibilitySource = source.view
        current.sourceAccessibilityWasHidden = source.view.accessibilityElementsHidden
        source.view.accessibilityElementsHidden = true
        current.orientation.prepare(token: "shared-video", scene: scene, prefersLandscape: landscape)
        source.present(screen, animated: false) {
            current.orientation.begin(token: "shared-video") { _ in }
        }
        return current
    }
    func update(owner: UUID, content: AnyView) {
        guard self.owner == owner else { return }
        handoffTask?.cancel(); handoffTask = nil; handingOff = false
        screen?.setContent(content)
    }
    func setLandscape(_ landscape: Bool, onError: @escaping (Error) -> Void = { _ in }) {
        guard let screen, !screen.isBeingDismissed, let scene = screen.view.window?.windowScene else {
            onError(CocoaError(.featureUnsupported)); return
        }
        rotationTask?.cancel(); rotationID = UUID()
        let request = rotationID, previous = screen.allowedOrientations
        screen.setCanvasLandscape(nil)
        screen.openingOrientation = landscape ? VideoOrientation.landscapePresentation(in: scene) : .portrait
        screen.allowedOrientations = landscape ? .landscape : .portrait
        screen.setNeedsUpdateOfSupportedInterfaceOrientations()
        let failed: (Error) -> Void = { [weak self, weak screen] error in
            guard let self, let screen, self.rotationID == request, !screen.isBeingDismissed else { return }
            self.rotationTask?.cancel(); screen.allowedOrientations = previous
            screen.setNeedsUpdateOfSupportedInterfaceOrientations()
            // Stage Manager/windowed iPad scenes can refuse scene rotation.
            // Rotate this same canvas instead of dismissing playback or alerting.
            screen.setCanvasLandscape(landscape)
        }
        rotationTask = Task { @MainActor [weak self, weak screen] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self, let screen, self.rotationID == request, !screen.isBeingDismissed else { return }
            self.orientation.setFullscreenOrientation(landscape, in: scene, sourceView: nil,
                fullscreenController: screen, onError: failed)
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard self.rotationID == request, !screen.isBeingDismissed else { return }
            if (screen.view.bounds.width > screen.view.bounds.height) != landscape { failed(CocoaError(.featureUnsupported)) }
        }
    }
    func beginHandoff(owner: UUID) {
        guard self.owner == owner else { return }
        handingOff = true; handoffTask?.cancel()
        handoffTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.owner == owner, self.handingOff else { return }
            self.handingOff = false; self.dismiss(owner: owner)
        }
    }
    func release(owner: UUID) {
        guard self.owner == owner, !handingOff else { return }
        dismiss(owner: owner)
    }
    func dismiss(owner: UUID, reason: VideoFullscreenDismissal = .exitFullscreen) {
        guard self.owner == owner, let screen, !screen.isBeingDismissed else { return }
        handoffTask?.cancel(); handoffTask = nil
        screen.closed = nil
        screen.dismiss(animated: false) { [weak self] in self?.finished(reason: reason) }
    }
    private func finished(reason: VideoFullscreenDismissal) {
        guard screen != nil else { return }
        rotationID = UUID(); rotationTask?.cancel(); rotationTask = nil
        screen?.closed = nil; screen = nil
        handoffTask?.cancel(); handoffTask = nil
        Self.sessions.removeValue(forKey: key)
        accessibilitySource?.accessibilityElementsHidden = sourceAccessibilityWasHidden
        accessibilitySource = nil
        orientation.end()
        let callback = onClose; onClose = nil; callback?(reason)
    }
}

struct VideoPlaybackControls: View {
    let elapsed: Double
    let duration: Double
    let rate: Float
    let playing: Bool
    let identifier: String
    var options: FileVideoOptions?
    var showEpisodes: (() -> Void)?
    var expand: (() -> Void)?
    var interactionChanged: ((Bool) -> Void)?
    let seek: (Double) -> Void
    let setRate: (Float) -> Void
    var body: some View {
        VStack(spacing: 6) {
            VideoPlaybackTimeline(elapsed: elapsed, duration: duration, identifier: identifier + ".timeline",
                                  seek: seek, interactionChanged: interactionChanged)
            HStack(spacing: 12) {
                FileVideoMenus(rate: rate, playbackState: { (elapsed, playing) }, setRate: setRate,
                    options: options, showEpisodes: showEpisodes, menuInteraction: interactionChanged,
                    interaction: { interactionChanged?(false) })
                if options?.usesSystem == true {
                    AirPlayRoutePicker(prioritizesVideoDevices: true, presentRequested: options?.airPlayPresentation)
                        .frame(width: 44, height: 44)
                }
                if let expand {
                    VideoPlayerIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: ToolText.text("media_fullscreen"),
                        identifier: identifier == "media.native" ? "media.fullscreen" : identifier + ".fullscreen", action: expand)
                        .frame(width: 44, height: 44)
                }
            }
        }
    }
}

/// Both playback engines use this chrome. Decoder state and actions are the
/// only differences between web, download and file fullscreen playback.
/// Keeps the decoder mounted when a window cannot change its orientation.
/// The logical canvas, chrome and touch targets rotate together inside that window.
private struct VideoFullscreenCanvas: View {
    let content: AnyView
    let landscape: Bool?
    let insets: EdgeInsets
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let rotated = landscape.map { $0 != wide } ?? false
            let logicalInsets = rotated ? EdgeInsets(top: insets.trailing, leading: insets.top, bottom: insets.leading, trailing: insets.bottom) : insets
            content
                .environment(\.videoFullscreenInsets, logicalInsets)
                .frame(width: rotated ? geometry.size.height : geometry.size.width,
                       height: rotated ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(rotated ? 90 : 0))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media.fullscreen.canvas")
                .accessibilityValue((landscape ?? wide) ? "landscape" : "portrait")
        }
        .ignoresSafeArea().background(.black)
    }
}

struct VideoFullscreenChrome<More: View>: ViewModifier {
    @AppStorage(VideoPlaybackPreferences.showsWebDownloadControlsKey) private var showsVideoDownloadControls = true
    @Environment(\.videoFullscreenInsets) private var windowInsets
    @Environment(\.videoFullscreenRotation) private var rotateFullscreen
    @State private var rotationError: String?
    @ObservedObject var visibility: VideoControlsVisibility
    let title: String
    let elapsed: Double
    let duration: Double
    let rate: Float
    let playing: Bool
    var buffering = false
    var error: String?
    let identifier: String
    let closeIdentifier: String
    var options: FileVideoOptions?
    var retry: (() -> Void)?
    var subtitlePlayer: AVPlayer? = nil
    let close: () -> Void
    var exitFullscreen: (() -> Void)? = nil
    let toggle: () -> Void
    let seek: (Double) -> Void
    let setRate: (Float) -> Void
    var holdBegan: (() -> Void)? = nil
    var holdEnded: (() -> Void)? = nil
    @ViewBuilder var more: () -> More
    @State private var episodesVisible = false
    @State private var settingsVisible = false
    @State private var morePresented = false
    @State private var opensSettings = false
    @State private var pendingAction: (() -> Void)?
    @State private var playbackWindow = VideoPlaybackWindow()

    private var awaitingEpisode: Bool { options?.playlist?.resolvingID != nil }

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(VideoTransportOverlay(visibility: visibility, playing: playing, buffering: buffering || awaitingEpisode,
                    identifier: identifier + ".play", toggle: toggle, seek: { seek(elapsed + $0) }))
                .overlay(alignment: .top) {
                    if visibility.visible && !episodesVisible {
                        HStack(spacing: 12) {
                            VideoPlayerIconButton(symbol: "xmark", label: ToolText.text("close"), identifier: closeIdentifier, action: close)
                                .frame(width: 44, height: 44).background(.black.opacity(0.45), in: Circle())
                            Text(title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if geometry.size.width > geometry.size.height {
                                VideoFullscreenClock()
                            }
                            if let options { MediaPlayerMenu(options: options, playbackState: { (elapsed, playing) }, interactionChanged: visibility.interaction) }
                            Button { morePresented.toggle() } label: {
                                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(ToolText.text("media_options"))
                            .accessibilityIdentifier("media.fullscreen.options")
                            .compatiblePopover(isPresented: $morePresented) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let request = options?.requestPictureInPicture {
                                        Button {
                                            pendingAction = { request(elapsed, playing) }
                                            morePresented = false
                                        } label: {
                                            Label(ToolText.text("media_pip"), systemImage: "pip.enter")
                                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        }
                                        .disabled(options?.systemAvailable == false)
                                        .accessibilityIdentifier("media.picture-in-picture")
                                    }
                                    more()
                                    PlaybackSleepTimerMenu()
                                    if let download = options?.download, showsVideoDownloadControls || options?.downloadIsVideo == false {
                                        Button { morePresented = false; download() } label: {
                                            Label(LanguageManager.shared.localizedString("download"), systemImage: "arrow.down.circle")
                                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        }.accessibilityIdentifier("media.download")
                                    }
                                    if let url = options?.shareURL {
                                        ShareLink(item: url) { Label(ToolText.text("share_media"), systemImage: "square.and.arrow.up") }
                                    }
                                    Divider()
                                    Button { opensSettings = true; morePresented = false } label: {
                                        Label(LanguageManager.shared.localizedString("settings"), systemImage: "gearshape")
                                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    }
                                    .accessibilityIdentifier("media.fullscreen.settings")
                                }
                                .padding(16).frame(width: 280).buttonStyle(.plain)
                                .compatiblePopoverAdaptation().videoPopoverSurface()
                                .onDisappear {
                                    if opensSettings { opensSettings = false; DispatchQueue.main.async { settingsVisible = true } }
                                    if let action = pendingAction {
                                        pendingAction = nil
                                        Task { @MainActor in
                                            // A mode handoff must wait for UIKit to
                                            // remove the menu that owns this action.
                                            for _ in 0..<24 {
                                                let host = VideoOrientation.topController(in: playbackWindow.window)
                                                if host?.modalPresentationStyle != .popover,
                                                   host?.isBeingDismissed != true, host?.transitionCoordinator == nil { break }
                                                try? await Task.sleep(for: .milliseconds(25))
                                            }
                                            action()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.leading, max(16, max(windowInsets.leading, geometry.safeAreaInsets.leading)))
                        .padding(.trailing, max(16, max(windowInsets.trailing, geometry.safeAreaInsets.trailing)))
                        .padding(.top, max(12, max(windowInsets.top, geometry.safeAreaInsets.top))).padding(.bottom, 20)
                        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if visibility.visible && !episodesVisible {
                        VStack(spacing: 6) {
                            VideoPlaybackTimeline(elapsed: elapsed, duration: duration, identifier: identifier + ".timeline",
                                seek: seek, interactionChanged: visibility.interaction)
                                .offset(y: 8)
                            HStack(spacing: 12) {
                                FileVideoMenus(rate: rate, playbackState: { (elapsed, playing) }, setRate: setRate,
                                    options: options, showEpisodes: { episodesVisible = true }, showsPlayerMenu: false, menuInteraction: visibility.interaction,
                                    interaction: visibility.show)
                                if options?.usesSystem == true {
                                    AirPlayRoutePicker(prioritizesVideoDevices: true, presentRequested: options?.airPlayPresentation)
                                        .frame(width: 44, height: 44)
                                }
                                if let subtitlePlayer { SystemSubtitleMenu(player: subtitlePlayer, interaction: visibility.show) }
                                let landscape = geometry.size.width > geometry.size.height
                                VideoPlayerIconButton(symbol: UIDevice.current.userInterfaceIdiom == .pad
                                    ? (landscape ? "ipad" : "ipad.landscape") : (landscape ? "iphone" : "iphone.landscape"),
                                    label: ToolText.text(landscape ? "media_portrait" : "media_landscape"),
                                    identifier: "media.fullscreen.rotate") {
                                        guard let rotateFullscreen else { rotationError = CocoaError(.featureUnsupported).localizedDescription; return }
                                        rotateFullscreen(!landscape) { rotationError = $0.localizedDescription }
                                        visibility.show()
                                    }
                                    .frame(width: 44, height: 44)
                                if let exitFullscreen, options?.fullscreenOnly != true {
                                    VideoPlayerIconButton(symbol: "arrow.down.right.and.arrow.up.left",
                                        label: LanguageManager.shared.localizedString("exit_fullscreen"),
                                        identifier: closeIdentifier.replacingOccurrences(of: ".close", with: ".exit"),
                                        action: exitFullscreen)
                                        .frame(width: 44, height: 44)
                                }
                            }
                        }
                        .padding(.leading, max(24, max(windowInsets.leading, geometry.safeAreaInsets.leading)))
                        .padding(.trailing, max(24, max(windowInsets.trailing, geometry.safeAreaInsets.trailing)))
                        .padding(.top, 28).padding(.bottom, max(16, max(windowInsets.bottom, geometry.safeAreaInsets.bottom)))
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                        .transition(.opacity)
                    }
                }
        }
        // Status belongs to the video surface. It must never change the
        // canvas height or move the timeline and transport controls.
        .overlay(alignment: .top) {
            if let error, !awaitingEpisode {
                VideoPlaybackStatus(message: error, identifier: identifier + ".status", retry: retry)
                    .padding(12).background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 600).padding(.horizontal, 24).padding(.top, max(64, windowInsets.top + 52))
            }
        }
        .modifier(VideoOrientationErrorAlert(message: $rotationError))
        .modifier(FileVideoEpisodeDrawer(isPresented: $episodesVisible, playlist: options?.playlist, fullscreen: true))
        .ignoresSafeArea().foregroundStyle(.white.opacity(0.9)).tint(.white).background(.black)
        .preferredColorScheme(.dark)
        .background(VideoFullscreenTapReader(controlsVisible: visibility.visible, action: visibility.toggle,
            doubleTap: { toggle(); visibility.show() }, holdBegan: holdBegan, holdEnded: holdEnded))
        .background(VideoPlaybackWindowReader(context: playbackWindow))
        #if DEBUG
        .overlay(alignment: .topLeading) { VideoVolumeDiagnostics() }
        #endif
        .onAppear { if options?.showsEpisodesOnAppear == true { episodesVisible = true } }
        .onCompatibleChange(of: error) { _, message in visibility.interaction(message != nil) }
        .onCompatibleChange(of: rotationError) { _, message in visibility.interaction(message != nil) }
        .onCompatibleChange(of: episodesVisible) { _, shown in visibility.interaction(shown) }
        .onCompatibleChange(of: settingsVisible) { _, shown in visibility.interaction(shown) }
        .onCompatibleChange(of: morePresented) { _, shown in visibility.interaction(shown) }
        .sheet(isPresented: $settingsVisible) {
            NavigationStack { VideoSettingsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { settingsVisible = false } }
            } }
        }
    }
}

#if DEBUG
private struct VideoVolumeDiagnostics: View {
    @ObservedObject private var session = MediaSession.shared
    private var frameReady: Bool {
        if let playback = session.soulo { return (playback.player?.media?.statistics.displayedPictures ?? 0) > 0 }
        return session.pictureInPicture.surface?.playerLayer.isReadyForDisplay == true
    }
    var body: some View {
        if ProcessInfo.processInfo.environment["SOULO_VIDEO_VOLUME_TRACE"] == "1" {
            Text("clock=\(session.soulo.map { Double($0.player?.time.intValue ?? 0) / 1000 } ?? session.player.currentTime().seconds) pauseDelay=\(session.pauseInputLatency ?? -1) events=\(session.volumeObservationEvents) raw=\(AVAudioSession.sharedInstance().outputVolume) state=\(UIApplication.shared.applicationState.rawValue) video=\(session.hasVideo) nativeSurfaces=\(session.playerSurfaces) soulo=\(session.soulo != nil) souloVideo=\(session.soulo?.hasVideo == true) visible=\(session.soulo?.hasVisibleSurface == true) frameReady=\(frameReady) duration=\(session.duration) page=\(session.pageURL?.lastPathComponent ?? "") episode=\(session.webMediaContext?.selectedEpisodeID ?? "")")
                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.3))
                .accessibilityIdentifier("media.volume.diagnostics")
                .allowsHitTesting(false)
        }
    }
}
#endif

private struct VideoFullscreenClock: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.medium).monospacedDigit())
                .fixedSize()
                .accessibilityIdentifier("media.fullscreen.clock")
        }
    }
}

/// Own fullscreen taps at the common controller, above either rendering
/// surface. Decoder subviews cannot consume the tap that reveals the controls.
private struct VideoFullscreenTapReader: UIViewRepresentable {
    let controlsVisible: Bool
    let action: () -> Void
    let doubleTap: () -> Void
    var holdBegan: (() -> Void)?
    var holdEnded: (() -> Void)?
    final class Anchor: UIView {
        var ready: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { ready?() } }
        override func layoutSubviews() { super.layoutSubviews(); if window != nil { ready?() } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor(); view.isUserInteractionEnabled = false
        view.ready = { [weak view, weak coordinator = context.coordinator] in if let view { coordinator?.attach(from: view) } }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.controlsVisible = controlsVisible; context.coordinator.action = action; context.coordinator.doubleTapAction = doubleTap
        context.coordinator.holdBegan = holdBegan; context.coordinator.holdEnded = holdEnded
        context.coordinator.attach(from: view)
    }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.detach() }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var controlsVisible = true
        var action: (() -> Void)?
        var doubleTapAction: (() -> Void)?
        var holdBegan: (() -> Void)?
        var holdEnded: (() -> Void)?
        private weak var controller: UIViewController?
        private var tap: UITapGestureRecognizer?
        private var doubleTap: UITapGestureRecognizer?
        private var lastDoubleTap: CFTimeInterval = 0
        private var hold: UILongPressGestureRecognizer?
        func attach(from view: UIView) {
            var candidate = view.window?.rootViewController
            var fullscreen: UIViewController?
            while let current = candidate {
                if ["media.fullscreen.player", "media.mkv.fullscreen.player"].contains(current.viewIfLoaded?.accessibilityIdentifier ?? "") {
                    fullscreen = current
                }
                candidate = current.presentedViewController
            }
            guard let owner = fullscreen ?? VideoOrientation.owningController(of: view), controller !== owner else { return }
            detach(); controller = owner
            let tap = UITapGestureRecognizer(target: self, action: #selector(activate))
            tap.name = "SouloFullscreenControlsTap"
            tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delegate = self
            owner.view.addGestureRecognizer(tap); self.tap = tap
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
            doubleTap.numberOfTapsRequired = 2; doubleTap.delegate = self
            doubleTap.name = "SouloFullscreenPlaybackDoubleTap"
            doubleTap.cancelsTouchesInView = false
            doubleTap.delaysTouchesBegan = false; doubleTap.delaysTouchesEnded = false
            owner.view.addGestureRecognizer(doubleTap); self.doubleTap = doubleTap
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.4; hold.delegate = self
            hold.cancelsTouchesInView = false
            hold.delaysTouchesBegan = false; hold.delaysTouchesEnded = false
            hold.name = "SouloFullscreenHoldSpeed"
            owner.view.addGestureRecognizer(hold); self.hold = hold
            tap.require(toFail: hold)
        }
        func detach() {
            if let tap { tap.view?.removeGestureRecognizer(tap) }
            if let hold { hold.view?.removeGestureRecognizer(hold) }
            if let doubleTap { doubleTap.view?.removeGestureRecognizer(doubleTap) }
            holdEnded?(); tap = nil; doubleTap = nil; hold = nil; controller = nil
        }
        @objc private func activate() {
            guard CACurrentMediaTime() - lastDoubleTap > 0.25 else { return }
            action?()
        }
        @objc private func doubleTapped() {
            lastDoubleTap = CACurrentMediaTime()
            doubleTapAction?()
        }
        @objc private func held(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { holdBegan?() }
            else if [.ended, .cancelled, .failed].contains(gesture.state) { holdEnded?() }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let controller, controller.presentedViewController == nil else { return false }
            let view = controller.view!, point = touch.location(in: view)
            #if DEBUG
            if controlsVisible, gestureRecognizer === tap,
               CGRect(x: view.bounds.midX - 140, y: view.bounds.midY - 48, width: 280, height: 96).contains(point) {
                MediaSession.shared.recordVideoControlTouch(timestamp: touch.timestamp)
            }
            #endif
            // Neither recognizer may delay or cancel a control's touch. In
            // particular, long-press speed must not compete with Pause.
            var target = touch.view
            while let node = target {
                if node is UIControl, node.bounds.width * node.bounds.height < view.bounds.width * view.bounds.height / 2 { return false }
                target = node.superview
            }
            let insets = view.safeAreaInsets
            if gestureRecognizer === hold || controlsVisible {
                if point.y < max(12, insets.top) + 64 || point.y > view.bounds.height - max(16, insets.bottom) - 120 { return false }
            }
            guard controlsVisible else { return true }
            let transport = CGRect(x: view.bounds.midX - 140, y: view.bounds.midY - 48, width: 280, height: 96)
            return !transport.contains(point)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

struct VideoPlayerIconButton: UIViewRepresentable {
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void
    final class Button: UIButton {
        var action: (() -> Void)?
        @objc func activate() { action?() }
    }
    func makeUIView(context: Context) -> Button {
        let button = Button(type: .system)
        button.addTarget(button, action: #selector(Button.activate), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: Button, context: Context) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(
            pointSize: symbol == "arrow.up.left.and.arrow.down.right" ? 17 : 20), forImageIn: .normal)
        button.accessibilityLabel = label; button.accessibilityIdentifier = identifier; button.action = action
    }
}

struct VideoTransportButtons: View {
    let playing: Bool
    var buffering = false
    let identifier: String
    let toggle: () -> Void
    let seek: (Double) -> Void
    var interaction: (() -> Void)?

    var body: some View {
        HStack(spacing: 28) {
            Button { seek(-10); interaction?() } label: {
                Image(systemName: "gobackward.10").font(.system(size: 27, weight: .medium))
                    .frame(width: 64, height: 64).background(.black.opacity(0.22), in: Circle())
            }
            Button { toggle(); interaction?() } label: {
                ZStack {
                    if buffering {
                        ProgressView().tint(.white).controlSize(.large)
                            .accessibilityIdentifier(identifier + ".buffering")
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 40, weight: .semibold))
                    }
                }
                .frame(width: 80, height: 80).background(.black.opacity(0.22), in: Circle())
            }
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(ToolText.text(playing || buffering ? "pause" : "play"))
            Button { seek(10); interaction?() } label: {
                Image(systemName: "goforward.10").font(.system(size: 27, weight: .medium))
                    .frame(width: 64, height: 64).background(.black.opacity(0.22), in: Circle())
            }
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.94))
        .fixedSize().shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

@MainActor final class VideoControlsVisibility: ObservableObject {
    @Published private(set) var visible = true
    private var enabled = true, playing = false, buffering = false, voiceOver = false, interacting = false
    private var hideTask: Task<Void, Never>?

    func update(enabled: Bool, playing: Bool, buffering: Bool, voiceOver: Bool) {
        let becameReady = playing && (!self.playing || self.buffering)
        self.enabled = enabled; self.playing = playing; self.buffering = buffering; self.voiceOver = voiceOver
        if becameReady || !playing || buffering || voiceOver { visible = true }
        scheduleHide()
    }
    func toggle() {
        guard enabled else { return }
        withAnimation(.easeInOut(duration: 0.18)) { visible.toggle() }
        scheduleHide()
    }
    func show() { visible = true; scheduleHide() }
    func interaction(_ active: Bool) { interacting = active; show() }
    func cancel() { hideTask?.cancel(); interacting = false }
    private func scheduleHide() {
        hideTask?.cancel()
        guard enabled, visible, playing, !buffering, !voiceOver, !interacting else { return }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) { self?.visible = false }
        }
    }
    deinit { hideTask?.cancel() }
}

struct VideoTransportOverlay: ViewModifier {
    @ObservedObject var visibility: VideoControlsVisibility
    var enabled = true
    let playing: Bool
    var buffering = false
    let identifier: String
    let toggle: () -> Void
    let seek: (Double) -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content.overlay {
            if enabled && visibility.visible {
                VideoTransportButtons(playing: playing, buffering: buffering, identifier: identifier, toggle: toggle, seek: seek,
                                      interaction: visibility.show)
            }
        }
        .onAppear { visibility.show(); update() }
        .onDisappear { visibility.cancel() }
        .onCompatibleChange(of: playing) { _, _ in update() }
        .onCompatibleChange(of: buffering) { _, _ in update() }
        .onCompatibleChange(of: voiceOver) { _, _ in update() }
        .onCompatibleChange(of: enabled) { _, _ in update() }
    }
    private func update() { visibility.update(enabled: enabled, playing: playing, buffering: buffering, voiceOver: voiceOver) }
}

struct VideoPlaybackTimeline: View {
    let elapsed: Double
    let duration: Double
    let identifier: String
    let seek: (Double) -> Void
    var interactionChanged: ((Bool) -> Void)?
    @State private var scrubTime: Double?

    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(clock(scrubTime ?? elapsed))
                    .accessibilityIdentifier(identifier + ".elapsed")
                Spacer()
                Text(duration.isFinite && duration > 0 ? clock(duration) : "—:—")
            }
            .font(.caption.monospacedDigit()).opacity(0.8)
            PlaybackTimelineSlider(elapsed: elapsed, duration: duration, identifier: identifier,
                seek: seek, preview: { scrubTime = $0 }, interaction: { active in
                    if !active { scrubTime = nil }
                    interactionChanged?(active)
                })
                .frame(height: 44)
        }
    }
}

/// Keep the playback clock authoritative whenever no finger is tracking the
/// native slider. Touch cancellation cannot leave a separate SwiftUI drag
/// flag pinning the thumb while decoded video continues to advance.
/// Keep UIKit's slider appearance and adjustable accessibility, while a single
/// gesture on its 44 pt control owns the complete touch sequence. Native slider
/// tracking can drop the end event when a new touch starts away from its thumb.
private final class PlaybackPositionControl: UIControl {
    let slider = UISlider()
    private var trackingOffset: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(slider)
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(track(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(gesture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); slider.frame = bounds }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Route physical touches to this control's single recognizer while the
        // slider remains enabled for VoiceOver and accessibility adjustment.
        super.hitTest(point, with: event) == nil ? nil : self
    }
    @objc private func track(_ gesture: UILongPressGestureRecognizer) {
        guard isEnabled else { return }
        let point = gesture.location(in: slider)
        switch gesture.state {
        case .began:
            let track = slider.trackRect(forBounds: slider.bounds)
            let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.value)
            trackingOffset = thumb.insetBy(dx: -8, dy: -8).contains(point) ? point.x - thumb.midX : 0
            updateValue(at: point)
            slider.sendActions(for: .touchDown)
        case .changed:
            updateValue(at: point)
            slider.sendActions(for: .valueChanged)
        case .ended:
            updateValue(at: point)
            slider.sendActions(for: .touchUpInside)
            trackingOffset = 0
        case .cancelled, .failed:
            slider.sendActions(for: .touchCancel)
            trackingOffset = 0
        default: break
        }
    }
    private func updateValue(at point: CGPoint) {
        let track = slider.trackRect(forBounds: slider.bounds)
        let start = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.minimumValue).midX
        let end = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.maximumValue).midX
        guard abs(end - start) > .ulpOfOne else { return }
        let fraction = min(1, max(0, (point.x - trackingOffset - start) / (end - start)))
        slider.setValue(slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue), animated: false)
    }
}

private struct PlaybackTimelineSlider: UIViewRepresentable {
    let elapsed: Double
    let duration: Double
    let identifier: String
    let seek: (Double) -> Void
    let preview: (Double?) -> Void
    let interaction: (Bool) -> Void

    final class Coordinator: NSObject {
        var parent: PlaybackTimelineSlider
        var editing = false
        private var lastCommit: (value: Float, time: ContinuousClock.Instant)?
        init(_ parent: PlaybackTimelineSlider) { self.parent = parent }
        @objc func began(_ slider: UISlider) {
            lastCommit = nil
            editing = true; parent.preview(Double(slider.value)); parent.interaction(true)
        }
        @objc func changed(_ slider: UISlider) {
            if editing || slider.isTracking { parent.preview(Double(slider.value)) }
            else { commit(slider.value); parent.interaction(false) }
        }
        @objc func ended(_ slider: UISlider) {
            guard editing else { return }
            editing = false; commit(slider.value); parent.preview(nil); parent.interaction(false)
        }
        @objc func cancelled(_ slider: UISlider) {
            editing = false; parent.preview(nil); parent.interaction(false)
        }
        private func commit(_ value: Float) {
            // UIKit can send a final valueChanged after touchUpInside. Submit
            // that release once so an adaptive stream is not asked to seek twice.
            if let lastCommit, lastCommit.value == value, lastCommit.time.duration(to: .now) < .milliseconds(500) { return }
            lastCommit = (value, .now)
            parent.seek(Double(value))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PlaybackPositionControl {
        let control = PlaybackPositionControl()
        let slider = control.slider
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(context.coordinator, action: #selector(Coordinator.cancelled(_:)), for: .touchCancel)
        return control
    }
    func updateUIView(_ control: PlaybackPositionControl, context: Context) {
        let slider = control.slider
        context.coordinator.parent = self
        slider.minimumValue = 0
        slider.maximumValue = Float(duration.isFinite && duration > 0 ? duration : 1)
        slider.isEnabled = duration.isFinite && duration > 0
        control.isEnabled = slider.isEnabled
        slider.accessibilityLabel = ToolText.text("position")
        slider.accessibilityIdentifier = identifier
        // UIKit can stop reporting isTracking before its final release action.
        // Keep the preview until that action commits or explicitly cancels it.
        guard !slider.isTracking, !context.coordinator.editing else { return }
        // Unknown duration is unavailable, never a fictitious one-second video.
        let value = slider.isEnabled ? Float(min(max(0, elapsed.isFinite ? elapsed : 0), Double(slider.maximumValue))) : 0
        if slider.value != value { slider.setValue(value, animated: abs(slider.value - value) < 2) }
    }
    static func dismantleUIView(_ control: PlaybackPositionControl, coordinator: Coordinator) {
        if coordinator.editing { coordinator.cancelled(control.slider) }
    }
}

/// Status text gets its own row, outside the video/transport overlay stack.
struct VideoPlaybackStatus: View {
    let message: String
    let identifier: String
    var retry: (() -> Void)?
    var body: some View {
        HStack(spacing: 16) {
            Text(message).font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
            if let retry {
                Button(ToolText.text("retry"), action: retry)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier(identifier + ".retry")
            }
        }
    }
}
