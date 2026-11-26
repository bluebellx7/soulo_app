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

extension View {
    func videoMenuPopover<Panel: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top,
                                      @ViewBuilder content: @escaping () -> Panel) -> some View {
        compatiblePopover(isPresented: isPresented, arrowEdge: arrowEdge,
                          tracksSourceView: true, backgroundColor: UIColor(white: 0.12, alpha: 1)) {
            content().environment(\.colorScheme, .dark).foregroundStyle(.white)
        }
    }
}

struct FullscreenVideoMenuLabel: View {
    let title: String
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .resizable()
                .symbolRenderingMode(.monochrome)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .frame(width: iconSize + 4)
                .accessibilityHidden(true)
            Text(title)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Size the popover to its rows, then let the scrollable variant take over
/// when the proposed height is shorter than the rows.
private struct FullscreenVideoMenuLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let menu = subviews.first else { return .zero }
        let ideal = menu.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
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
private struct VideoOrientationLockControl {
    let isLocked: Bool
    let toggle: () -> Void
}
private struct VideoOrientationLockKey: EnvironmentKey {
    static let defaultValue: VideoOrientationLockControl? = nil
}
private extension EnvironmentValues {
    var videoFullscreenRotation: ((Bool, @escaping (Error) -> Void) -> Void)? {
        get { self[VideoFullscreenRotationKey.self] }
        set { self[VideoFullscreenRotationKey.self] = newValue }
    }
    var videoOrientationLock: VideoOrientationLockControl? {
        get { self[VideoOrientationLockKey.self] }
        set { self[VideoOrientationLockKey.self] = newValue }
    }
}

@MainActor final class SharedVideoFullscreenHost {
    private final class SourceCover: UIView {
        private let snapshot: UIView
        private let sourceSize: CGSize
        private let sourceOrientation: UIInterfaceOrientation
        var targetOrientation: UIInterfaceOrientation?

        init?(source: UIView, orientation: UIInterfaceOrientation) {
            guard source.bounds.width > 0, source.bounds.height > 0,
                  let snapshot = source.snapshotView(afterScreenUpdates: false)
                    ?? source.snapshotView(afterScreenUpdates: true) else { return nil }
            self.snapshot = snapshot
            sourceSize = source.bounds.size
            sourceOrientation = orientation
            super.init(frame: source.bounds)
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            accessibilityIdentifier = "media.fullscreen.source-cover"
            clipsToBounds = true
            backgroundColor = .black
            addSubview(snapshot)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let orientation = window?.windowScene?.interfaceOrientation ?? .unknown
            let sourceIsLandscape = sourceSize.width > sourceSize.height
            let rotates = UIDevice.current.userInterfaceIdiom == .phone
                && sourceIsLandscape != (bounds.width > bounds.height)
            let available = rotates ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            let scale = min(available.width / sourceSize.width, available.height / sourceSize.height)
            // A replicant view preserves its captured pixels. Resize via its
            // transform so the bounds do not clip the captured content.
            snapshot.bounds = CGRect(origin: .zero, size: sourceSize)
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
            let scaled = CGAffineTransform(scaleX: scale, y: scale)
            if rotates {
                // Keep the captured screen upright as UIKit changes the window axes.
                // Filling the new bounds directly magnifies a strip of the source page.
                let landscape = sourceIsLandscape ? sourceOrientation
                    : orientation.isLandscape ? orientation : targetOrientation
                let quarterTurn: CGFloat = landscape == .landscapeLeft ? -.pi / 2 : .pi / 2
                snapshot.transform = scaled.rotated(by: sourceIsLandscape ? quarterTurn : -quarterTurn)
            } else {
                snapshot.transform = scaled
            }
        }
    }

    private struct EntryCover: UIViewRepresentable {
        let cover: SourceCover
        func makeUIView(context: Context) -> UIView {
            let container = UIView()
            cover.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(cover)
            NSLayoutConstraint.activate([
                cover.topAnchor.constraint(equalTo: container.topAnchor),
                cover.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                cover.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                cover.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
            return container
        }
        func updateUIView(_ view: UIView, context: Context) {}
    }

    private struct FirstFrameCover: ViewModifier {
        let cover: AnyView?
        let isReady: (() -> Bool)?
        @State private var revealed = false

        func body(content: Content) -> some View {
            let waiting = isReady != nil && !revealed
            content
                .opacity(waiting && cover == nil ? 0.001 : 1)
                .accessibilityHidden(waiting)
                .overlay {
                    if waiting {
                        cover?.ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
                .task {
                    guard let isReady, !revealed else { return }
                    // A snapshot hides the drawable handoff. If decoding takes
                    // longer, let the actual player report progress immediately.
                    for _ in 0..<6 {
                        if isReady() {
                            // Give the newly attached video layer a display cycle.
                            do { try await Task.sleep(for: .milliseconds(17)) } catch { return }
                            break
                        }
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    }
                    revealed = true
                }
        }
    }

    final class Screen: UIHostingController<AnyView> {
        private var playerContent = AnyView(EmptyView())
        private var playerInsets = EdgeInsets()
        private(set) var canvasLandscape: Bool?
        private var pendingEntryOrientation: UIInterfaceOrientation?
        var entryLandscapeDirection: UIInterfaceOrientation? {
            pendingEntryOrientation?.isLandscape == true ? pendingEntryOrientation : nil
        }
        var waitingForVideoDimensions = false { didSet { if oldValue != waitingForVideoDimensions { rebuildCanvas() } } }
        fileprivate var entryCover: AnyView?
        fileprivate var isFirstFrameReady: (() -> Bool)?
        private var reversedLandscape = false
        var closed: (() -> Void)?
        var rotate: ((Bool, @escaping (Error) -> Void) -> Void)?
        var toggleOrientationLock: (() -> Void)?
        var directionLocked = false { didSet { if oldValue != directionLocked { rebuildCanvas() } } }
        var openingOrientation: UIInterfaceOrientation = .portrait
        var allowedOrientations: UIInterfaceOrientationMask = .allButUpsideDown
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { openingOrientation }
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { allowedOrientations }
        override var prefersStatusBarHidden: Bool { true }
        func setContent(_ content: AnyView, initialInsets: UIEdgeInsets? = nil,
                        initialCanvasLandscape: Bool? = nil,
                        entryOrientation: UIInterfaceOrientation? = nil) {
            playerContent = content
            if let initialInsets { playerInsets = Self.insets(initialInsets) }
            if let initialCanvasLandscape { canvasLandscape = initialCanvasLandscape }
            if let entryOrientation { pendingEntryOrientation = entryOrientation }
            rebuildCanvas()
        }
        func setCanvasLandscape(_ value: Bool?, entryOrientation: UIInterfaceOrientation? = nil) {
            pendingEntryOrientation = entryOrientation
            canvasLandscape = value
            rebuildCanvas()
        }
        func setReversedLandscape(_ value: Bool) {
            guard reversedLandscape != value else { return }
            reversedLandscape = value
            rebuildCanvas()
        }
        func useCanvasIfGeometryIsUnavailable() {
            guard let pendingEntryOrientation else { return }
            setCanvasLandscape(pendingEntryOrientation.isLandscape)
        }
        private func rebuildCanvas() {
            let content = playerContent
            if pendingEntryOrientation != nil || waitingForVideoDimensions {
                rootView = AnyView((entryCover ?? AnyView(Color.clear))
                    .ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false))
                return
            }
            let frameReady: (() -> Bool)? = isFirstFrameReady == nil ? nil : { [weak self] in
                self?.isFirstFrameReady?() ?? true
            }
            rootView = AnyView(VideoFullscreenCanvas(landscape: canvasLandscape,
                                                     entryLandscapeDirection: canvasLandscape == true ? openingOrientation : nil,
                                                     reversedLandscape: reversedLandscape, insets: playerInsets) { _ in
                content
            }
                .modifier(FirstFrameCover(cover: entryCover, isReady: frameReady))
                .environment(\.videoOrientationLock, toggleOrientationLock.map { .init(isLocked: directionLocked, toggle: $0) })
                .environment(\.videoFullscreenRotation, rotate).preferredColorScheme(.dark))
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard let target = pendingEntryOrientation,
                  let interfaceOrientation = view.window?.windowScene?.interfaceOrientation,
                  interfaceOrientation != .unknown, interfaceOrientation.isLandscape == target.isLandscape,
                  (view.bounds.width > view.bounds.height) == target.isLandscape else { return }
            pendingEntryOrientation = nil
            rebuildCanvas()
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
    private var dismissalOrientation: UIInterfaceOrientationMask?
    private var awaitsVideoOrientation = false
    private var videoOrientationTimeout: Task<Void, Never>?
    private var detectedVideoLandscape: Bool?
    private var sceneActivation: NSObjectProtocol?
    private weak var sourceWindow: UIWindow?
    private var exitCover: SourceCover?
    private weak var accessibilitySource: UIView?
    private var sourceAccessibilityWasHidden = false
    private let orientation = WebVideoFullscreenOrientation(followsDeviceMotion: true)
    private init(scene: UIWindowScene, owner: UUID) { key = ObjectIdentifier(scene); self.owner = owner }
    static func current(in window: UIWindow) -> SharedVideoFullscreenHost? {
        window.windowScene.flatMap { sessions[ObjectIdentifier($0)] }
    }
    static var isPresenting: Bool { sessions.values.contains { $0.screen?.isBeingDismissed == false } }
    static func supportedOrientationMask(in window: UIWindow) -> UIInterfaceOrientationMask? {
        guard let host = current(in: window), host.sourceWindow === window, let screen = host.screen else { return nil }
        return host.dismissalOrientation ?? (screen.isBeingDismissed ? nil : screen.allowedOrientations)
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
                        landscape: Bool?, isFirstFrameReady: (() -> Bool)? = nil,
                        onClose: @escaping (VideoFullscreenDismissal) -> Void) -> SharedVideoFullscreenHost? {
        guard let scene = window.windowScene else { return nil }
        if let current = current(in: window), let screen = current.screen {
            guard current.dismissalOrientation == nil else { return nil }
            current.handoffTask?.cancel(); current.handoffTask = nil; current.handingOff = false
            if current.owner != owner { current.detectedVideoLandscape = nil }
            current.owner = owner; current.onClose = onClose
            screen.isFirstFrameReady = isFirstFrameReady
            screen.view.accessibilityIdentifier = identifier; screen.setContent(content)
            current.resolveVideoOrientation(owner: owner, landscape: landscape)
            return current
        }
        guard let source = VideoOrientation.topController(in: window),
              !source.isBeingPresented, !source.isBeingDismissed, source.transitionCoordinator == nil else { return nil }
        let current = SharedVideoFullscreenHost(scene: scene, owner: owner)
        current.sourceWindow = window
        let screen = Screen(rootView: content)
        screen.isFirstFrameReady = isFirstFrameReady
        let cover = SourceCover(source: window, orientation: scene.interfaceOrientation)
        if let cover {
            screen.entryCover = AnyView(EntryCover(cover: cover))
        }
        // UIKit menus and popovers must share the fullscreen canvas appearance.
        screen.overrideUserInterfaceStyle = .dark
        screen.rotate = { [weak current] landscape, failure in
            guard let current else { failure(CocoaError(.featureUnsupported)); return }
            current.setLandscape(landscape, onError: failure)
        }
        screen.toggleOrientationLock = { [weak current] in current?.toggleOrientationLock() }
        current.orientation.setReversedLandscape = { [weak screen] in screen?.setReversedLandscape($0) }
        screen.modalPresentationCapturesStatusBarAppearance = true
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let startsLandscape = VideoOrientation.fullscreenLandscape(video: landscape, scene: scene)
        current.awaitsVideoOrientation = isPhone && landscape == nil
        screen.waitingForVideoDimensions = current.awaitsVideoOrientation
        let requestsPortrait = isPhone && !startsLandscape
        screen.openingOrientation = isPhone ? (startsLandscape ? VideoOrientation.landscapePresentation(in: scene) : .portrait)
            : scene.interfaceOrientation
        cover?.targetOrientation = screen.openingOrientation
        // Let UIKit settle the landscape window before revealing the video.
        // A provisional rotated canvas would animate again with the scene.
        let entryOrientation = isPhone && screen.openingOrientation.isLandscape != scene.interfaceOrientation.isLandscape
            ? screen.openingOrientation : nil
        screen.setContent(content, initialInsets: window.safeAreaInsets, initialCanvasLandscape: requestsPortrait ? false : nil,
                          entryOrientation: entryOrientation)
        screen.allowedOrientations = startsLandscape ? .landscape : (requestsPortrait ? .portrait : .allButUpsideDown)
        // Keep the source mounted so the destination decoder can start while
        // this same fullscreen controller remains visible during a handoff.
        screen.modalPresentationStyle = .overFullScreen; screen.view.backgroundColor = .clear
        screen.view.accessibilityIdentifier = identifier; screen.view.accessibilityViewIsModal = true
        screen.closed = { [weak current] in current?.finished(reason: .exitFullscreen) }
        current.screen = screen; current.onClose = onClose; sessions[current.key] = current
        current.sceneActivation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak current, weak scene] _ in
                Task { @MainActor in
                    if let scene { current?.restoreLockedDirection(in: scene) }
                }
            }
        current.accessibilitySource = source.view
        current.sourceAccessibilityWasHidden = source.view.accessibilityElementsHidden
        source.view.accessibilityElementsHidden = true
        current.orientation.prepare(token: "shared-video", scene: scene, prefersLandscape: startsLandscape, sourceView: source.view)
        source.present(screen, animated: false) {
            guard current.screen === screen, current.dismissalOrientation == nil else { return }
            current.orientation.begin(token: "shared-video", controller: screen, requestPortrait: requestsPortrait,
                                      initialLandscapeDirection: screen.entryLandscapeDirection) { [weak screen] _ in
                screen?.useCanvasIfGeometryIsUnavailable()
            }
            current.resolveVideoOrientation(owner: current.owner, landscape: current.detectedVideoLandscape)
            if current.awaitsVideoOrientation {
                current.videoOrientationTimeout = Task { @MainActor [weak current, weak screen] in
                    do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                    guard let current, let screen, current.screen === screen, current.awaitsVideoOrientation else { return }
                    current.awaitsVideoOrientation = false
                    screen.waitingForVideoDimensions = false
                }
            }
        }
        return current
    }
    func update(owner: UUID, content: AnyView) {
        guard self.owner == owner else { return }
        handoffTask?.cancel(); handoffTask = nil; handingOff = false
        screen?.setContent(content)
    }
    func resolveVideoOrientation(owner: UUID, landscape: Bool?) {
        guard self.owner == owner, dismissalOrientation == nil, awaitsVideoOrientation,
              let screen, let landscape else { return }
        detectedVideoLandscape = landscape
        guard screen.viewIfLoaded?.window != nil, !screen.isBeingPresented else { return }
        awaitsVideoOrientation = false
        videoOrientationTimeout?.cancel(); videoOrientationTimeout = nil
        if landscape != screen.openingOrientation.isLandscape { setLandscape(landscape, resolvingVideo: true) }
        screen.waitingForVideoDimensions = false
    }
    private func toggleOrientationLock() {
        guard dismissalOrientation == nil, let screen, let scene = screen.viewIfLoaded?.window?.windowScene,
              !screen.isBeingDismissed, scene.interfaceOrientation != .unknown else { return }
        rotationTask?.cancel(); rotationID = UUID()
        awaitsVideoOrientation = false
        orientation.stopTracking()
        screen.directionLocked.toggle()
        if screen.directionLocked {
            let surfaceIsLandscape = screen.canvasLandscape
                ?? (screen.entryLandscapeDirection != nil || screen.view.bounds.width > screen.view.bounds.height)
            let direction = surfaceIsLandscape == scene.interfaceOrientation.isLandscape ? scene.interfaceOrientation
                : surfaceIsLandscape ? (screen.entryLandscapeDirection ?? VideoOrientation.landscapePresentation(in: scene)) : .portrait
            screen.openingOrientation = direction
            screen.allowedOrientations = VideoOrientation.mask(for: direction)
            BrowserStartupTrace.mark("video_orientation_locked", detail: "\(direction.rawValue)")
        } else {
            screen.allowedOrientations = screen.openingOrientation.isLandscape ? .landscape : .portrait
            if screen.canvasLandscape == nil, screen.openingOrientation.isLandscape {
                orientation.setFullscreenOrientation(true, in: scene, sourceView: nil,
                    fullscreenController: screen) { _ in }
            }
        }
        screen.setNeedsUpdateOfSupportedInterfaceOrientations()
        if screen.directionLocked { restoreLockedDirection(in: scene) }
    }
    private func restoreLockedDirection(in scene: UIWindowScene) {
        guard let screen, dismissalOrientation == nil, screen.directionLocked else { return }
        rotationTask?.cancel()
        let request = UUID(), mask = screen.allowedOrientations
        BrowserStartupTrace.mark("video_orientation_restore_lock", detail: "\(mask.rawValue)")
        rotationID = request
        rotationTask = Task { @MainActor [weak self, weak screen, weak scene] in
            for attempt in 0..<12 {
                do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
                guard let self, let screen, let scene, self.rotationID == request, screen.directionLocked,
                      screen.viewIfLoaded?.window?.windowScene === scene, !screen.isBeingDismissed else { return }
                if attempt % 3 == 0, !mask.contains(VideoOrientation.mask(for: scene.interfaceOrientation)) {
                    VideoOrientation.request(mask, in: scene) {
                        BrowserStartupTrace.mark("video_orientation_restore_lock_error", detail: $0.localizedDescription)
                    }
                }
            }
        }
    }
    func setLandscape(_ landscape: Bool, resolvingVideo: Bool = false,
                      onError: @escaping (Error) -> Void = { _ in }) {
        guard dismissalOrientation == nil, let screen, !screen.directionLocked,
              !screen.isBeingDismissed, let scene = screen.view.window?.windowScene else {
            onError(CocoaError(.featureUnsupported)); return
        }
        rotationTask?.cancel(); rotationID = UUID()
        awaitsVideoOrientation = false
        let request = rotationID, previous = screen.allowedOrientations
        screen.setReversedLandscape(false)
        screen.openingOrientation = landscape ? VideoOrientation.landscapePresentation(in: scene) : .portrait
        screen.setCanvasLandscape(resolvingVideo && !landscape ? false : nil,
            entryOrientation: resolvingVideo ? screen.openingOrientation : nil)
        screen.allowedOrientations = landscape ? .landscape : .portrait
        screen.setNeedsUpdateOfSupportedInterfaceOrientations()
        orientation.setFullscreenOrientation(landscape, in: scene, sourceView: nil,
            fullscreenController: screen) { [weak self, weak screen] _ in
            guard let self, let screen, self.rotationID == request, !screen.isBeingDismissed else { return }
            self.orientation.stopTracking()
            screen.allowedOrientations = previous
            screen.setNeedsUpdateOfSupportedInterfaceOrientations()
            // Stage Manager/windowed iPad scenes can refuse scene rotation.
            // Rotate this same canvas instead of dismissing playback or alerting.
            screen.setCanvasLandscape(landscape)
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
        guard self.owner == owner, let screen, dismissalOrientation == nil, !screen.isBeingDismissed else { return }
        // Keep the source visible through the first correctly laid-out frame
        // after dismissal, including a return from landscape to portrait.
        let current = sourceWindow?.windowScene?.interfaceOrientation
        let mask = current.flatMap { $0 == .unknown ? nil : VideoOrientation.mask(for: $0) } ?? screen.allowedOrientations
        dismissalOrientation = mask
        screen.allowedOrientations = mask
        rotationID = UUID(); rotationTask?.cancel(); rotationTask = nil
        orientation.stopTracking()
        awaitsVideoOrientation = false
        videoOrientationTimeout?.cancel(); videoOrientationTimeout = nil
        handoffTask?.cancel(); handoffTask = nil
        screen.closed = nil
        if let sourceWindow, !orientation.isSourceOrientationRestored(in: sourceWindow),
           let cover = SourceCover(source: screen.view, orientation: current ?? .unknown) {
            // Keep the player on screen while the browser or library returns.
            // The entry snapshot can contain a preparation spinner or sheet.
            exitCover = cover
            cover.frame = sourceWindow.bounds
            sourceWindow.addSubview(cover)
        }
        screen.dismiss(animated: false) { [weak self] in self?.finished(reason: reason) }
    }
    private func finished(reason: VideoFullscreenDismissal) {
        guard screen != nil else { return }
        videoOrientationTimeout?.cancel(); videoOrientationTimeout = nil
        rotationID = UUID(); rotationTask?.cancel(); rotationTask = nil
        if let sceneActivation { NotificationCenter.default.removeObserver(sceneActivation) }
        sceneActivation = nil
        screen?.closed = nil; screen = nil
        handoffTask?.cancel(); handoffTask = nil
        Self.sessions.removeValue(forKey: key)
        accessibilitySource?.accessibilityElementsHidden = sourceAccessibilityWasHidden
        accessibilitySource = nil
        let cover = exitCover
        exitCover = nil
        orientation.end(restorePreparedPresentation: dismissalOrientation != nil) {
            cover?.removeFromSuperview()
        }
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
    var videoLoading: VideoLoadingStatus?
    var cacheProgress = VideoCacheProgress()
    var showEpisodes: (() -> Void)?
    var expand: (() -> Void)?
    var interactionChanged: ((Bool) -> Void)?
    let seek: (Double) -> Void
    let setRate: (Float) -> Void
    var body: some View {
        VStack(spacing: 6) {
            VideoPlaybackTimeline(elapsed: elapsed, duration: duration, identifier: identifier + ".timeline", cacheProgress: cacheProgress,
                                  seek: seek, interactionChanged: interactionChanged)
            HStack(spacing: 12) {
                FileVideoMenus(rate: rate, playbackState: { (elapsed, playing) }, setRate: setRate,
                    options: options, videoLoading: videoLoading, showEpisodes: showEpisodes, menuInteraction: interactionChanged,
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
struct VideoFullscreenCanvas<Content: View>: View {
    var landscape: Bool? = nil
    var entryLandscapeDirection: UIInterfaceOrientation? = nil
    var reversedLandscape = false
    let insets: EdgeInsets
    var identifier = "media.fullscreen.canvas"
    @ViewBuilder var content: (EdgeInsets) -> Content
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let logicalLandscape = landscape ?? (entryLandscapeDirection != nil || wide)
            let rotated = logicalLandscape != wide
            let counterclockwise = entryLandscapeDirection == .landscapeLeft
            let reversed = wide && !rotated && reversedLandscape
            let logicalInsets = if rotated {
                counterclockwise
                    ? EdgeInsets(top: insets.leading, leading: insets.bottom, bottom: insets.trailing, trailing: insets.top)
                    : EdgeInsets(top: insets.trailing, leading: insets.top, bottom: insets.leading, trailing: insets.bottom)
            } else if reversed {
                EdgeInsets(top: insets.bottom, leading: insets.trailing, bottom: insets.top, trailing: insets.leading)
            } else {
                insets
            }
            content(logicalInsets)
                .environment(\.videoFullscreenInsets, logicalInsets)
                .frame(width: rotated ? geometry.size.height : geometry.size.width,
                       height: rotated ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(rotated ? (counterclockwise ? -90 : 90) : reversed ? 180 : 0))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(logicalLandscape ? "landscape" : "portrait")
        }
        .ignoresSafeArea().background(.black)
    }
}

struct VideoFullscreenChrome<More: View>: ViewModifier {
    @AppStorage(VideoPlaybackPreferences.showsWebDownloadControlsKey) private var showsVideoDownloadControls = true
    @Environment(\.videoFullscreenInsets) private var windowInsets
    @Environment(\.videoFullscreenRotation) private var rotateFullscreen
    @Environment(\.videoOrientationLock) private var orientationLock
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
    var videoLoading: VideoLoadingStatus?
    var cacheProgress = VideoCacheProgress()
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
                .modifier(VideoTransportOverlay(visibility: visibility, playing: playing, buffering: buffering,
                    identifier: identifier + ".play", toggle: toggle, seek: { seek(elapsed + $0) }))
                .overlay(alignment: .top) {
                    if visibility.visible && !episodesVisible {
                        HStack(spacing: 12) {
                            VideoFullscreenBackTitle(title: title, identifier: closeIdentifier, action: close)
                            Spacer(minLength: 0)
                            if geometry.size.width > geometry.size.height {
                                VideoFullscreenClock()
                            }
                            if let orientationLock {
                                VideoPlayerIconButton(symbol: orientationLock.isLocked ? "lock.fill" : "lock.open",
                                    label: ToolText.text(orientationLock.isLocked ? "media_unlock_orientation" : "media_lock_orientation"),
                                    identifier: "media.fullscreen.orientation-lock") {
                                        visibility.show()
                                        orientationLock.toggle()
                                    }
                                    .frame(width: 44, height: 44)
                            }
                            Button { morePresented.toggle() } label: {
                                Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(ToolText.text("media_options"))
                            .accessibilityIdentifier("media.fullscreen.options")
                            .videoMenuPopover(isPresented: $morePresented) {
                                let rows = VStack(alignment: .leading, spacing: 8) {
                                    if let request = options?.requestPictureInPicture {
                                        Button {
                                            pendingAction = { request(elapsed, playing) }
                                            morePresented = false
                                        } label: {
                                            FullscreenVideoMenuLabel(title: ToolText.text("media_pip"), symbol: "pip.enter")
                                        }
                                        .disabled(options?.systemAvailable == false)
                                        .accessibilityIdentifier("media.picture-in-picture")
                                    }
                                    more()
                                    PlaybackSleepTimerMenu(fullscreen: true)
                                    if let download = options?.download, showsVideoDownloadControls || options?.downloadIsVideo == false {
                                        Button { morePresented = false; download() } label: {
                                            FullscreenVideoMenuLabel(title: LanguageManager.shared.localizedString("download"), symbol: "arrow.down.circle")
                                        }.accessibilityIdentifier("media.download")
                                    }
                                    if let url = options?.shareURL {
                                        ShareLink(item: url) {
                                            FullscreenVideoMenuLabel(title: ToolText.text("share_media"), symbol: "square.and.arrow.up")
                                        }
                                        .accessibilityIdentifier("media.fullscreen.share")
                                    }
                                    Button { opensSettings = true; morePresented = false } label: {
                                        FullscreenVideoMenuLabel(title: LanguageManager.shared.localizedString("settings"), symbol: "gearshape")
                                    }
                                    .accessibilityIdentifier("media.fullscreen.settings")
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10).buttonStyle(.plain)
                                FullscreenVideoMenuLayout(maximumHeight: min(420, max(100, geometry.size.height - 92))) {
                                    ViewThatFits(in: .vertical) {
                                        rows.fixedSize(horizontal: false, vertical: true)
                                        ScrollView { rows }
                                            .accessibilityIdentifier("media.fullscreen.options.scroll")
                                    }
                                }
                                .frame(width: 280)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("media.fullscreen.options.panel")
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
                        VStack(spacing: 0) {
                            VideoPlaybackTimeline(elapsed: elapsed, duration: duration, identifier: identifier + ".timeline", cacheProgress: cacheProgress,
                                seek: seek, interactionChanged: visibility.interaction, compact: true)
                            HStack(spacing: 8) {
                                FileVideoMenus(rate: rate, playbackState: { (elapsed, playing) }, setRate: setRate,
                                    options: options, videoLoading: videoLoading, showEpisodes: { episodesVisible = true },
                                    menuInteraction: visibility.interaction,
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
                                    .disabled(orientationLock?.isLocked == true)
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
        if let playback = session.soulo { return (playback.player?.decodedFrameCount ?? 0) > 0 }
        return session.pictureInPicture.surface?.playerLayer.isReadyForDisplay == true
    }
    var body: some View {
        if ProcessInfo.processInfo.environment["SOULO_VIDEO_VOLUME_TRACE"] == "1" {
            Text("clock=\(session.soulo.map { ($0.player?.currentTime ?? 0) } ?? session.player.currentTime().seconds) pauseDelay=\(session.pauseInputLatency ?? -1) events=\(session.volumeObservationEvents) raw=\(AVAudioSession.sharedInstance().outputVolume) state=\(UIApplication.shared.applicationState.rawValue) video=\(session.hasVideo) nativeSurfaces=\(session.playerSurfaces) soulo=\(session.soulo != nil) souloVideo=\(session.soulo?.hasVideo == true) visible=\(session.soulo?.hasVisibleSurface == true) frameReady=\(frameReady) duration=\(session.duration) page=\(session.pageURL?.lastPathComponent ?? "") episode=\(session.webMediaContext?.selectedEpisodeID ?? "")")
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
            // SwiftUI can update the anchor while the presenting view and its
            // responder chain are being torn down.
            guard let window = view.window else { return }
            var candidate = window.rootViewController
            var fullscreen: UIViewController?
            while let current = candidate {
                if ["media.fullscreen.player", "media.mkv.fullscreen.player"].contains(current.viewIfLoaded?.accessibilityIdentifier ?? "") {
                    fullscreen = current
                }
                candidate = current.presentedViewController
            }
            guard let owner = fullscreen ?? VideoOrientation.owningController(of: view),
                  owner.viewIfLoaded?.window === window, !owner.isBeingDismissed, controller !== owner else { return }
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

struct VideoFullscreenBackTitle: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: -5) {
            VideoPlayerIconButton(symbol: "chevron.left", label: ToolText.text("close"),
                identifier: identifier, tintColor: .white, action: action)
                .frame(width: 44, height: 44)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .allowsHitTesting(false)
        }
    }
}

struct VideoPlayerIconButton: UIViewRepresentable {
    let symbol: String
    let label: String
    let identifier: String
    var tintColor: UIColor? = nil
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
        if let tintColor { button.tintColor = tintColor }
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
        if !visible && (becameReady || !playing || buffering || voiceOver) { visible = true }
        scheduleHide()
    }
    func toggle() {
        guard enabled else { return }
        withAnimation(.easeInOut(duration: 0.18)) { visible.toggle() }
        scheduleHide()
    }
    func show() {
        if !visible { visible = true }
        scheduleHide()
    }
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
    var cacheProgress = VideoCacheProgress()
    let seek: (Double) -> Void
    var interactionChanged: ((Bool) -> Void)?
    var compact = false
    @State private var scrubTime: Double?

    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var times: some View {
        HStack {
            Text(clock(scrubTime ?? elapsed))
                .accessibilityIdentifier(identifier + ".elapsed")
            Spacer()
            Text(duration.isFinite && duration > 0 ? clock(duration) : "—:—")
        }
        .font(.caption.monospacedDigit()).opacity(0.8)
    }

    private var slider: some View {
        PlaybackTimelineSlider(elapsed: elapsed, duration: duration, identifier: identifier, cacheProgress: cacheProgress,
            trackOffset: compact ? 10 : 0, seek: seek, preview: { scrubTime = $0 }, interaction: { active in
                if !active { scrubTime = nil }
                interactionChanged?(active)
            })
            .frame(height: 44)
    }

    var body: some View {
        if compact {
            slider.overlay(alignment: .top) {
                times.padding(.top, 6).allowsHitTesting(false)
            }
        } else {
            VStack(spacing: 0) {
                times
                slider
            }
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
    private final class Slider: UISlider {
        var trackOffset: CGFloat = 0

        override func trackRect(forBounds bounds: CGRect) -> CGRect {
            super.trackRect(forBounds: bounds).offsetBy(dx: 0, dy: trackOffset)
        }
    }

    private static let compactThumb = {
        let size = CGSize(width: 24, height: 15)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 5).fill()
        }.withRenderingMode(.alwaysOriginal)
    }()

    let slider: UISlider
    private let trackBackground = CAShapeLayer()
    private let cacheTrack = CAShapeLayer()
    var cacheProgress = VideoCacheProgress() {
        didSet {
            guard oldValue != cacheProgress else { return }
            setNeedsLayout()
        }
    }
    private var trackingOffset: CGFloat = 0
    init(trackOffset: CGFloat) {
        let slider = Slider()
        slider.trackOffset = trackOffset
        self.slider = slider
        super.init(frame: .zero)
        slider.setThumbImage(Self.compactThumb, for: .normal)
        slider.setThumbImage(Self.compactThumb, for: .highlighted)
        // Keep the native played segment and thumb above the buffered ranges.
        slider.maximumTrackTintColor = .clear
        addSubview(slider)
        layer.insertSublayer(cacheTrack, below: slider.layer)
        layer.insertSublayer(trackBackground, below: cacheTrack)
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(track(_:)))
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(gesture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        slider.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        trackBackground.path = nil
        cacheTrack.path = nil
        let track = slider.trackRect(forBounds: slider.bounds)
        guard track.width > 0, track.height > 0 else { return }
        trackBackground.fillColor = UIColor.label.withAlphaComponent(0.17).resolvedColor(with: traitCollection).cgColor
        trackBackground.path = UIBezierPath(roundedRect: track, cornerRadius: track.height / 2).cgPath

        let fractions: [Range<Double>]
        if !cacheProgress.timeFractions.isEmpty {
            fractions = cacheProgress.timeFractions
        } else if let fraction = cacheProgress.fileFraction, fraction > 0 {
            fractions = [0..<min(fraction, 1)]
        } else { return }

        cacheTrack.fillColor = UIColor.systemGreen.resolvedColor(with: traitCollection).cgColor
        let thumbs = thumbCenters(track)
        let reversed = thumbs.start > thumbs.end
        let path = UIBezierPath()
        func x(_ fraction: Double) -> CGFloat {
            if fraction <= 0 { return reversed ? track.maxX : track.minX }
            if fraction >= 1 { return reversed ? track.minX : track.maxX }
            return min(track.maxX, max(track.minX, thumbs.start + (thumbs.end - thumbs.start) * CGFloat(fraction)))
        }
        for range in fractions {
            let start = x(range.lowerBound), end = x(range.upperBound)
            let rect = CGRect(x: min(start, end), y: track.minY, width: abs(end - start), height: track.height)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: min(rect.height, rect.width) / 2))
        }
        cacheTrack.path = path.cgPath
    }
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
        let (start, end) = thumbCenters(track)
        guard abs(end - start) > .ulpOfOne else { return }
        let fraction = min(1, max(0, (point.x - trackingOffset - start) / (end - start)))
        slider.setValue(slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue), animated: false)
    }
    private func thumbCenters(_ track: CGRect) -> (start: CGFloat, end: CGFloat) {
        (slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.minimumValue).midX,
         slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.maximumValue).midX)
    }
}

private struct PlaybackTimelineSlider: UIViewRepresentable {
    let elapsed: Double
    let duration: Double
    let identifier: String
    let cacheProgress: VideoCacheProgress
    let trackOffset: CGFloat
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
        let control = PlaybackPositionControl(trackOffset: trackOffset)
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
        control.cacheProgress = cacheProgress
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
