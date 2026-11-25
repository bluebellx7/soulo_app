import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoPlaybackSpeedToast: View {
    let rate: Double
    var body: some View {
        Label(String(format: "%g×", rate), systemImage: "forward.fill")
            .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(.black.opacity(0.85), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ToolText.text("web_media_speed") + " " + String(format: "%g×", rate))
            .allowsHitTesting(false)
    }
}

private struct NativeVideoHoldSpeedFeedback: View {
    @ObservedObject private var session = MediaSession.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack {
            if let rate = session.temporaryRateFeedback, session.player.rate > 0 {
                VideoPlaybackSpeedToast(rate: Double(rate))
                    .accessibilityIdentifier("media.video-hold-speed")
                    .padding(.top, 12).transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.temporaryRateFeedback)
        .overlay {
            if let feedback = session.gestureFeedback {
                VideoGestureFeedbackView(feedback: feedback, identifier: "media.native.gesture.feedback")
            }
        }
        .allowsHitTesting(false)
    }
}

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
    static func fullscreenLandscape(video: Bool?, scene: UIWindowScene?) -> Bool {
        fullscreenLandscape(video: video, isPad: UIDevice.current.userInterfaceIdiom == .pad,
                            currentLandscape: scene?.interfaceOrientation.isLandscape == true)
    }
    static func fullscreenLandscape(video: Bool?, isPad: Bool, currentLandscape: Bool) -> Bool {
        isPad ? currentLandscape : (video ?? currentLandscape)
    }
    private struct Restoration {
        let id: UUID
        let orientation: UIInterfaceOrientation
        let task: Task<Void, Never>
        weak var window: UIWindow?
        weak var controller: UIViewController?
    }
    private static var restorations: [ObjectIdentifier: Restoration] = [:]

    static func owningController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                var owner = controller
                while let parent = owner.parent { owner = parent }
                return owner
            }
            responder = current.next
        }
        return nil
    }

    static func capture(in scene: UIWindowScene, sourceView: UIView? = nil) -> (UIInterfaceOrientation, UIWindow?, UIViewController?, Bool) {
        // A quick re-entry inherits the page's orientation, not the landscape
        // geometry left over from a fullscreen session on the same window.
        let key = ObjectIdentifier(scene)
        // AVKit can make its own window key before a WebKit message reaches us.
        let window = sourceView?.window ?? scene.keyWindow
        if let pending = restorations[key], let window, pending.window === window {
            restorations.removeValue(forKey: key)
            pending.task.cancel()
            return (pending.orientation, pending.window, pending.controller, true)
        }
        let orientation = scene.interfaceOrientation == .unknown ? UIInterfaceOrientation.portrait : scene.interfaceOrientation
        var responder: UIResponder? = sourceView
        var owner: UIViewController?
        while let current = responder {
            if let controller = current as? UIViewController {
                owner = controller
                while let parent = owner?.parent { owner = parent }
                break
            }
            responder = current.next
        }
        return (orientation, window, owner ?? topController(in: window), false)
    }

    static func waitForRestoration(in scene: UIWindowScene) async {
        await restorations[ObjectIdentifier(scene)]?.task.value
    }

    static func topController(in window: UIWindow?) -> UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    static func isInForeground(_ scene: UIWindowScene) -> Bool {
        let state = scene.activationState
        return state == .foregroundActive || state == .foregroundInactive
    }

    static func restore(_ orientation: UIInterfaceOrientation, in scene: UIWindowScene,
                        sourceWindow: UIWindow?, sourceController: UIViewController?, handoff: Bool = false) {
        let key = ObjectIdentifier(scene), id = UUID()
        restorations.removeValue(forKey: key)?.task.cancel()
        let task = Task { @MainActor [weak scene, weak sourceWindow, weak sourceController] in
            // The replacement player consumes this restoration context. Give
            // its presentation a chance to mount before restoring the page.
            if handoff { do { try await Task.sleep(for: .milliseconds(500)) } catch { return } }
            var settled = 0
            var lastRequest = -10
            for attempt in 0..<120 {
                guard !Task.isCancelled, let scene, let sourceWindow else { break }
                let controller = topController(in: sourceWindow)
                // Never ask the dismissing AVKit/SwiftUI fullscreen controller
                // to restore the underlying page's orientation.
                let ready = isInForeground(scene)
                    && scene.keyWindow === sourceWindow && controller != nil
                    && controller === sourceController
                    && controller?.isBeingPresented == false
                    && controller?.isBeingDismissed == false
                    && controller?.transitionCoordinator == nil
                let mask = mask(for: orientation)
                if ready, controller?.supportedInterfaceOrientations.intersection(mask).isEmpty == false {
                    if lastRequest < 0 {
                        // Supersede a landscape request still in flight even
                        // when the scene currently reports the original geometry.
                        lastRequest = attempt
                        request(mask, in: scene) { _ in }
                    }
                    if scene.interfaceOrientation == orientation {
                        settled += 1
                        if settled >= 20 { break }
                    } else {
                        settled = 0
                        if attempt - lastRequest >= 10 {
                            lastRequest = attempt
                            // UIKit can reject a request while its geometry is
                            // changing. Keep checking and retry after it settles.
                            request(mask, in: scene) { _ in }
                        }
                    }
                } else { settled = 0 }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if restorations[key]?.id == id { restorations.removeValue(forKey: key) }
        }
        restorations[key] = Restoration(id: id, orientation: orientation, task: task, window: sourceWindow, controller: sourceController)
    }

    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    static func landscapeMask(device: UIDeviceOrientation, interface: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        // UIKit's interface and physical-device landscape names are reversed.
        switch device {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default:
            if interface == .landscapeLeft { return .landscapeLeft }
            if interface == .landscapeRight { return .landscapeRight }
            return .landscape
        }
    }

    static func landscapePresentation(in scene: UIWindowScene?) -> UIInterfaceOrientation {
        let mask = landscapeMask(device: UIDevice.current.orientation, interface: scene?.interfaceOrientation ?? .unknown)
        return mask == .landscapeLeft ? .landscapeLeft : .landscapeRight
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

struct LandscapeMotionDetector {
    private var candidate: UIDeviceOrientation?
    private var since: TimeInterval = 0

    mutating func direction(gravityX: Double, gravityY: Double, at time: TimeInterval) -> UIDeviceOrientation? {
        // Only follow a deliberate sideways hold. A flat or portrait device
        // leaves the last landscape side in place.
        guard abs(gravityX) >= 0.62, abs(gravityX) > abs(gravityY) * 1.25 else {
            candidate = nil
            return nil
        }
        let next: UIDeviceOrientation = gravityX < 0 ? .landscapeLeft : .landscapeRight
        if candidate != next {
            candidate = next
            since = time
        }
        return time - since >= 0.12 ? next : nil
    }
}

/// A fullscreen session may originate from any frame, but only that session
/// can rotate and restore its owning window. A failed entry never rotates.
@MainActor final class WebVideoFullscreenOrientation {
    private var token: String?
    private weak var scene: UIWindowScene?
    private weak var sourceWindow: UIWindow?
    private weak var sourceController: UIViewController?
    private var original: UIInterfaceOrientation = .portrait
    private(set) var prefersLandscape = true
    private var nativeWebKit = false
    private(set) var handingOff = false
    private var began = false
    private var inheritedRestoration = false
    private var transition: Task<Void, Never>?
    private var tracksDeviceOrientation = false
    private var orientationObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var motionObservation: UUID?
    private var motionDetector = LandscapeMotionDetector()
    private var lastLandscapeDirection: UIDeviceOrientation?
    private var orientationError: ((Error) -> Void)?
    var setReversedLandscape: ((Bool) -> Void)?
    private weak var explicitFullscreenController: UIViewController?
    private weak var fullscreenController: UIViewController?
    private weak var fullscreenWindow: UIWindow?
    private let deviceOrientation: @MainActor () -> UIDeviceOrientation
    private let followsDeviceMotion: Bool
    private let requestOrientation: @MainActor (UIInterfaceOrientationMask, UIWindowScene) -> Void

    init(deviceOrientation: @escaping @MainActor () -> UIDeviceOrientation = { UIDevice.current.orientation },
         followsDeviceMotion: Bool = false,
         requestOrientation: @escaping @MainActor (UIInterfaceOrientationMask, UIWindowScene) -> Void = {
             VideoOrientation.request($0, in: $1) { _ in }
         }) {
        self.deviceOrientation = deviceOrientation
        self.followsDeviceMotion = followsDeviceMotion
        self.requestOrientation = requestOrientation
    }

    func prepare(token: String, scene: UIWindowScene, prefersLandscape: Bool,
                 nativeWebKit: Bool = false, sourceView: UIView? = nil) {
        guard self.token == nil else { return }
        transition?.cancel()
        self.token = token
        self.scene = scene
        (original, sourceWindow, sourceController, inheritedRestoration) = VideoOrientation.capture(in: scene, sourceView: sourceView)
        self.prefersLandscape = prefersLandscape
        self.nativeWebKit = nativeWebKit
        handingOff = false
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        tracksDeviceOrientation = true
        began = false
    }

    func handOff() {
        handingOff = true
        stopTracking()
    }

    func stopTracking() {
        transition?.cancel()
        transition = nil
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        orientationObserver = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        stopMotionTracking()
        lastLandscapeDirection = nil
    }
    func rebaseSource(on view: UIView) {
        guard let scene, view.window?.windowScene === scene else { return }
        // Document fullscreen temporarily reparents WKWebView. Restore to the
        // browser controller it returns to, not the dismissed WebKit host.
        let owner = VideoOrientation.capture(in: scene, sourceView: view)
        sourceWindow = owner.1; sourceController = owner.2
    }
    func setFullscreenOrientation(_ landscape: Bool, in scene: UIWindowScene, sourceView: UIView?, fullscreenController: UIViewController? = nil, onError: @escaping (Error) -> Void) {
        if token == nil { prepare(token: "native-tools", scene: scene, prefersLandscape: landscape, nativeWebKit: true, sourceView: sourceView) }
        stopTracking()
        self.fullscreenController = nil; fullscreenWindow = nil
        prefersLandscape = landscape; began = false
        if let token { begin(token: token, controller: fullscreenController, requestPortrait: !landscape, onError: onError) }
    }

    func begin(token: String, controller: UIViewController? = nil, requestPortrait: Bool = false,
               initialLandscapeDirection: UIInterfaceOrientation? = nil,
               onError: @escaping (Error) -> Void) {
        guard self.token == token, !began else { return }
        began = true
        explicitFullscreenController = controller
        orientationError = onError
        guard prefersLandscape || requestPortrait else { return }
        if prefersLandscape {
            let initial = deviceOrientation()
            lastLandscapeDirection = initial.isLandscape ? initial : nil
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.token == token else { return }
                    self.followLandscapeDirection(self.deviceOrientation())
                }
            }
            if followsDeviceMotion {
                deactivationObserver = NotificationCenter.default.addObserver(
                    forName: UIScene.willDeactivateNotification, object: scene, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.token == token, self.scene?.activationState != .foregroundActive else { return }
                        self.transition?.cancel()
                        self.transition = nil
                        self.stopMotionTracking()
                    }
                }
                startMotionTracking()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: scene, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.token == token, self.began, self.activationObserver != nil, !self.handingOff,
                      let scene = self.scene, VideoOrientation.isInForeground(scene) else { return }
                if self.prefersLandscape {
                    let direction = self.deviceOrientation()
                    if direction.isLandscape { self.lastLandscapeDirection = direction }
                    self.startMotionTracking()
                }
                self.alignFullscreen(token: token, deviceDirection: self.lastLandscapeDirection)
            }
        }
        alignFullscreen(token: token, deviceDirection: lastLandscapeDirection, initialLandscapeDirection: initialLandscapeDirection)
    }

    private func startMotionTracking() {
        guard followsDeviceMotion, UIDevice.current.userInterfaceIdiom == .phone, motionObservation == nil,
              scene?.activationState == .foregroundActive else { return }
        motionObservation = DeviceMotionSource.shared.observe(interval: 0.05) { [weak self] motion in
            guard let self, self.motionObservation != nil, self.scene?.activationState == .foregroundActive else { return }
            self.receiveLandscapeGravity(x: motion.gravity.x, y: motion.gravity.y, at: motion.timestamp)
        }
    }

    private func stopMotionTracking() {
        if let motionObservation { DeviceMotionSource.shared.remove(motionObservation) }
        motionObservation = nil
        motionDetector = LandscapeMotionDetector()
    }

    func receiveLandscapeGravity(x: Double, y: Double, at time: TimeInterval) {
        guard let direction = motionDetector.direction(gravityX: x, gravityY: y, at: time) else { return }
        followLandscapeDirection(direction)
    }

    private func followLandscapeDirection(_ direction: UIDeviceOrientation) {
        guard let token, began, orientationObserver != nil, !handingOff, direction.isLandscape,
              lastLandscapeDirection != direction else { return }
        lastLandscapeDirection = direction
        alignFullscreen(token: token, deviceDirection: direction)
    }

    private func alignFullscreen(token: String, deviceDirection: UIDeviceOrientation? = nil,
                                 initialLandscapeDirection: UIInterfaceOrientation? = nil) {
        transition?.cancel()
        transition = Task { @MainActor [weak self] in
            // AVKit's video transform outlives the controller presentation
            // transition. Rotate its settled scene once, without invalidating
            // every browser and overlay controller during native entry.
            if self?.nativeWebKit == true {
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            }
            // WebKit reports begin before AVKit finishes presenting. During
            // that transition AVKit temporarily supports portrait only. Wait
            // for the fullscreen controller's actual supported orientations.
            let direction = deviceDirection ?? self?.deviceOrientation() ?? .unknown
            var lastRequest = -5
            var lastTarget: UIInterfaceOrientationMask?
            for attempt in 0..<60 {
                guard !Task.isCancelled, let self, self.token == token, !self.handingOff,
                      let scene = self.scene else { return }
                let window = self.explicitFullscreenController?.viewIfLoaded?.window ?? scene.keyWindow
                var controller = self.explicitFullscreenController ?? window?.rootViewController
                if self.explicitFullscreenController == nil {
                    while let presented = controller?.presentedViewController { controller = presented }
                }
                let fullscreenPresented = window !== self.sourceWindow
                    || controller !== self.sourceController
                let allowed: UIInterfaceOrientationMask = self.prefersLandscape ? .landscape : .portrait
                if VideoOrientation.isInForeground(scene), fullscreenPresented, let window, let controller,
                   (self.fullscreenController == nil || (controller === self.fullscreenController && window === self.fullscreenWindow)),
                   !controller.isBeingPresented, !controller.isBeingDismissed, controller.transitionCoordinator == nil,
                   !controller.supportedInterfaceOrientations.intersection(allowed).isEmpty {
                    self.fullscreenController = controller; self.fullscreenWindow = window
                    let preferred: UIInterfaceOrientationMask
                    if self.prefersLandscape, let initialLandscapeDirection {
                        preferred = VideoOrientation.mask(for: initialLandscapeDirection)
                    } else {
                        preferred = self.prefersLandscape
                            ? VideoOrientation.landscapeMask(device: direction, interface: scene.interfaceOrientation)
                            : .portrait
                    }
                    // If this fullscreen controller supports only one side,
                    // retain its supported landscape rather than failing entry.
                    let supported = preferred.intersection(controller.supportedInterfaceOrientations)
                    let target = supported.isEmpty ? allowed.intersection(controller.supportedInterfaceOrientations) : supported
                    lastTarget = target
                    if scene.interfaceOrientation != .unknown,
                       target.contains(VideoOrientation.mask(for: scene.interfaceOrientation)) {
                        self.setReversedLandscape?(false)
                        return
                    }
                    if attempt - lastRequest >= 5 {
                        lastRequest = attempt
                        // UIKit can reject or defer a request while scene geometry settles.
                        if self.nativeWebKit {
                            scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
                        } else {
                            self.requestOrientation(target, scene)
                        }
                    }
                    if attempt >= 14, self.setReversedLandscape != nil, scene.interfaceOrientation.isLandscape,
                       target == .landscapeLeft || target == .landscapeRight { break }
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            // Do not rotate the underlying page if presentation never finishes.
            guard let scene = self?.scene, VideoOrientation.isInForeground(scene),
                  !Task.isCancelled, self?.token == token, self?.handingOff == false,
                  lastRequest >= 0 || self?.explicitFullscreenController != nil else { return }
            if let target = lastTarget, target == .landscapeLeft || target == .landscapeRight,
               scene.interfaceOrientation.isLandscape, !target.contains(VideoOrientation.mask(for: scene.interfaceOrientation)),
               let setReversedLandscape = self?.setReversedLandscape {
                setReversedLandscape(true)
                // A late UIKit geometry update already rotated the canvas.
                // Keep watching until it settles, the user turns again, or the session ends.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    guard self?.token == token else { return }
                    if target.contains(VideoOrientation.mask(for: scene.interfaceOrientation)) {
                        setReversedLandscape(false)
                        return
                    }
                }
            } else {
                self?.orientationError?(CocoaError(.featureUnsupported))
            }
        }
    }

    func nativeFullscreenEnded() {
        if nativeWebKit, !handingOff { end() }
    }

    func end(token: String? = nil, handoff: Bool = false) {
        guard self.token != nil, token == nil || self.token == token else { return }
        stopTracking()
        orientationError = nil
        fullscreenController = nil; fullscreenWindow = nil; explicitFullscreenController = nil
        if tracksDeviceOrientation { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        tracksDeviceOrientation = false
        let scene = scene, source = sourceWindow, controller = sourceController, orientation = original,
            restore = began || inheritedRestoration || handingOff
        self.token = nil
        self.scene = nil
        self.sourceWindow = nil
        self.sourceController = nil
        began = false
        inheritedRestoration = false
        handingOff = false
        guard restore, let scene else { return }
        VideoOrientation.restore(orientation, in: scene, sourceWindow: source, sourceController: controller, handoff: handoff)
    }

    deinit {
        transition?.cancel()
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        if let motionObservation { Task { @MainActor in DeviceMotionSource.shared.remove(motionObservation) } }
        if tracksDeviceOrientation {
            Task { @MainActor in UIDevice.current.endGeneratingDeviceOrientationNotifications() }
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

/// Capture the playback page's window before presenting the fullscreen cover.
@MainActor final class VideoPlaybackWindow {
    weak var window: UIWindow?
}

struct VideoPlaybackWindowReader: UIViewRepresentable {
    let context: VideoPlaybackWindow
    final class Host: UIView {
        var context: VideoPlaybackWindow?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { context?.window = window }
        }
    }
    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.context = self.context
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Host, context: Context) {}
}

/// Present AVKit itself rather than embedding it inside a SwiftUI fullscreen
/// cover. AVKit owns the close button and the visibility of every native control.
private struct SessionPlayerController: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onDismiss: () -> Void
    var options: FileVideoOptions?
    var videoLandscape: Bool?

    func makeCoordinator() -> Presenter { Presenter() }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.onReady = { [weak host, weak presenter = context.coordinator] in
            guard let host else { return }; presenter?.synchronize(host)
        }
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.selection = $isPresented
        context.coordinator.onDismiss = onDismiss
        context.coordinator.options = options
        context.coordinator.videoLandscape = videoLandscape
        #if SOULO_ACCEPTANCE
        NSLog("[SouloEpisodeSource] native options %@", options?.playlist?.selectedSourceID ?? "none")
        #endif
        context.coordinator.synchronize(host)
    }
    static func dismantleUIViewController(_ host: Host, coordinator: Presenter) { coordinator.dismiss() }
    final class Host: UIViewController {
        var onReady: (() -> Void)?
        final class Anchor: UIView {
            var ready: (() -> Void)?
            override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { ready?() } }
        }
        override func loadView() {
            let anchor = Anchor(); anchor.ready = { [weak self] in self?.onReady?() }; view = anchor
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); onReady?() }
    }
    @MainActor final class Presenter {
        var selection: Binding<Bool>?
        var onDismiss: (() -> Void)?
        var options: FileVideoOptions?
        var videoLandscape: Bool?
        private let ownerID = UUID()
        private var sharedHost: SharedVideoFullscreenHost?
        private var presentedOptions: FileVideoOptions?
        private var presentationRetry: Task<Void, Never>?
        func synchronize(_ host: Host) {
            guard selection?.wrappedValue == true else { dismiss(); return }
            let landscape = options?.initialFullscreenLandscape ?? videoLandscape
            if let sharedHost, sharedHost.owner == ownerID {
                sharedHost.resolveVideoOrientation(owner: ownerID, landscape: landscape)
                if presentedOptions != options { sharedHost.update(owner: ownerID, content: AnyView(content())); presentedOptions = options }
                return
            }
            guard let window = SharedVideoFullscreenHost.window(for: host) else { return }
            sharedHost = SharedVideoFullscreenHost.present(owner: ownerID, in: window, content: AnyView(content()),
                identifier: "media.fullscreen.player",
                landscape: landscape,
                onClose: { [weak self] reason in self?.finish(reason: reason) })
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
            presentedOptions = options
        }
        private func content() -> NativeFullscreenContent {
            var actions = options
            if let original = options {
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
            return NativeFullscreenContent(options: actions, close: { [weak self] in
                guard let self else { return }; self.sharedHost?.dismiss(owner: self.ownerID, reason: .closePlayback)
            }, exitFullscreen: { [weak self] in
                guard let self else { return }; self.sharedHost?.dismiss(owner: self.ownerID, reason: .exitFullscreen)
            })
        }
        func dismiss() {
            presentationRetry?.cancel(); presentationRetry = nil
            sharedHost?.release(owner: ownerID)
        }
        private func finish(reason: VideoFullscreenDismissal) {
            sharedHost = nil; presentedOptions = nil
            MediaSession.shared.endTemporaryRate()
            options?.fullscreenChanged?(false)
            selection?.wrappedValue = false; onDismiss?()
            if reason == .closePlayback || options?.fullscreenOnly == true { options?.closePlayback?(reason) }
        }
    }
}

private struct NativeFullscreenContent: View {
    var options: FileVideoOptions?
    let close: () -> Void
    let exitFullscreen: () -> Void
    @ObservedObject private var session = MediaSession.shared
    @ObservedObject private var pip = MediaSession.shared.pictureInPicture
    @StateObject private var controls = VideoControlsVisibility()
    @State private var buffering = false
    @State private var retryTask: Task<Void, Never>?
    @State private var automaticRetryURL: URL?
    private var waitingForPlayback: Bool {
        retryTask != nil || (session.isPlaybackRequested && session.error == nil && (buffering
            || session.playbackStalled
            || session.webMediaContext?.resource.kind == .video && session.pictureInPicture.surface?.playerLayer.isReadyForDisplay != true))
    }

    private func retryPlayback(automatic: Bool = false) {
        guard retryTask == nil, let source = session.playbackTransferSource(), let url = session.url else { return }
        let title = session.title, page = session.pageURL, reservation = session.reservePreparation()
        let intent = session.playbackIntentRevision
        retryTask = Task { @MainActor in
            defer { retryTask = nil }
            let retrySource: DownloadPlaybackSource
            if !automatic, let context = source.webMediaContext {
                let asset = await WebResourceMediaService.asset(for: context.resource, webView: source.webView, cacheForPlayback: true)
                let fresh = DownloadPlaybackSource(asset: asset, pageURL: source.pageURL, webView: source.webView,
                    persistPosition: source.persistsPosition, downloadAsset: source.downloadAsset)
                fresh.resourceLease = source.resourceLease; fresh.webMediaContext = context
                retrySource = fresh
            } else {
                // Recreate the player item without depending on the originating
                // web page or refreshing credentials for an in-flight stream.
                retrySource = source
            }
            guard !Task.isCancelled, session.ownsPreparation(reservation),
                  !automatic || (session.playbackIntentRevision == intent && session.isPlaybackRequested && session.playbackStalled) else { return }
            let position = session.duration > 0 ? session.elapsed : nil
            session.open(url: url, title: title, pageURL: page, asset: retrySource.asset, webView: source.webView,
                reservation: reservation, persistPosition: source.persistsPosition, downloadSource: retrySource,
                startAt: position, autoplay: true, initialRate: session.rate)
        }
    }
    @State private var audioGroup: AVMediaSelectionGroup?
    @State private var subtitleGroup: AVMediaSelectionGroup?
    @State private var selectedAudio: Int?
    @State private var selectedSubtitle: Int?

    var body: some View {
        MediaPlaybackSurface()
            .overlay { NativeVideoHoldSpeedFeedback() }
            .modifier(VideoFullscreenChrome(visibility: controls, title: session.title,
                elapsed: session.seekPreview ?? session.elapsed, duration: session.duration, rate: session.rate,
                playing: session.playing, buffering: waitingForPlayback,
                error: retryTask == nil ? (session.error ?? session.startupWarning ?? (session.playbackStalled ? ToolText.text("media_playback_stalled") : nil)) : nil,
                identifier: "media.native", closeIdentifier: "media.fullscreen.close", options: options, videoLoading: session.videoLoading,
                cacheProgress: session.videoCacheProgress, retry: { retryPlayback() }, subtitlePlayer: session.player,
                close: close, exitFullscreen: exitFullscreen, toggle: session.toggle, seek: session.seek, setRate: { _ = session.setRate($0) },
                holdBegan: session.beginTemporaryRate, holdEnded: session.endTemporaryRate) {
                    if let audioGroup {
                        trackMenu(audioGroup, title: ToolText.text("media_audio_tracks"), symbol: "waveform", selected: $selectedAudio)
                    }
                    if let subtitleGroup {
                        trackMenu(subtitleGroup, title: ToolText.text("media_subtitles"), symbol: "captions.bubble", selected: $selectedSubtitle)
                    }
                    Toggle(isOn: $session.loop) {
                        FullscreenVideoMenuLabel(title: ToolText.text("loop"), symbol: "repeat.1")
                    }
                    Toggle(isOn: $session.mirrored) {
                        FullscreenVideoMenuLabel(title: ToolText.text("media_mirror"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                })
        .onCompatibleChange(of: session.playbackStalled) { _, stalled in
            guard stalled, session.isPlaybackRequested, options?.playlist?.resolvingID == nil,
                  let url = session.url, automaticRetryURL != url else { return }
            automaticRetryURL = url
            retryPlayback(automatic: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if session.webMediaContext != nil { automaticRetryURL = nil }
        }
        .onReceive(session.player.publisher(for: \.timeControlStatus)) { status in
            let waiting = status == .waitingToPlayAtSpecifiedRate
            if buffering != waiting { buffering = waiting }
        }
        .onDisappear { retryTask?.cancel() }
        .onCompatibleChange(of: pip.active) { _, active in if active { close() } }
        .task(id: session.player.currentItem.map(ObjectIdentifier.init)) {
            audioGroup = nil; subtitleGroup = nil; selectedAudio = nil; selectedSubtitle = nil
            guard let item = session.player.currentItem else { return }
            let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled, session.player.currentItem === item else { return }
            audioGroup = audio; subtitleGroup = subtitles
            if let audio { selectedAudio = audio.options.firstIndex { item.currentMediaSelection.selectedMediaOption(in: audio)?.isEqual($0) == true } }
            if let subtitles { selectedSubtitle = subtitles.options.firstIndex { item.currentMediaSelection.selectedMediaOption(in: subtitles)?.isEqual($0) == true } }
        }
    }
    private func trackMenu(_ group: AVMediaSelectionGroup, title: String, symbol: String, selected: Binding<Int?>) -> some View {
        Menu {
            if group.allowsEmptySelection {
                Button {
                    session.player.currentItem?.select(nil, in: group); selected.wrappedValue = nil; controls.show()
                } label: {
                    if selected.wrappedValue == nil { Label(ToolText.text("media_track_off"), systemImage: "checkmark") }
                    else { Text(ToolText.text("media_track_off")) }
                }
            }
            ForEach(group.options.indices, id: \.self) { index in
                Button {
                    session.player.currentItem?.select(group.options[index], in: group)
                    selected.wrappedValue = index; controls.show()
                } label: {
                    if selected.wrappedValue == index { Label(group.options[index].displayName, systemImage: "checkmark") }
                    else { Text(group.options[index].displayName) }
                }
            }
        } label: { FullscreenVideoMenuLabel(title: title, symbol: symbol) }
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
                    .disabled(pip.launching)
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
            HStack(spacing: 4) {
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
            if let error = session.error ?? session.startupWarning {
                Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding()
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// File/download entry points use the same fullscreen host and controls as
/// webpage playback, without exposing a compact player between orientations.
struct FullscreenMediaPlaybackContent: View {
    @Environment(\.dismiss) private var dismiss
    var resumesExistingSession = false
    @ObservedObject private var session = MediaSession.shared
    var body: some View {
        MediaPlaybackContent(restoredSoulo: session.soulo, initialFullscreen: true, fullscreenOnly: true,
            initialSystemPlayer: resumesExistingSession && session.soulo == nil, onFullscreenClose: { dismiss() })
            .toolbar(.hidden, for: .navigationBar)
    }
}

struct MediaPlayerPage: View {
    @ObservedObject var session = MediaSession.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let context = session.webMediaContext {
                WebResourceMediaPlayerView(resource: context.resource, pageURL: context.pageURL,
                    sourceWebView: context.sourceWebView,
                    assetProvider: { await WebResourceMediaService.asset(for: context.resource, webView: context.sourceWebView, cacheForPlayback: true) },
                    downloadAction: { try? await WebResourceDownloadService.shared.download(context.resource,
                        pageURL: context.resource.sourcePageURL ?? context.pageURL, webView: context.sourceWebView) },
                    souloStartAt: session.elapsed, souloPlaying: session.isPlaybackRequested, episodeList: context.episodeList,
                    restoredContext: context, embedded: true)
            } else if let url = session.url, url.isFileURL {
                FileMediaPlaybackView(url: url, initialSystemPlayer: session.soulo == nil)
            } else if let url = session.url, session.isAudioPlayback {
                MusicPlaybackView(url: url, title: session.title)
            } else if let playback = session.soulo, let source = playback.sourceURL {
                MatroskaPlayerView(url: source, title: session.title, options: restoredOptions, startsFullscreen: true)
            } else { FullscreenMediaPlaybackContent(resumesExistingSession: true) }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }
    private var restoredOptions: FileVideoOptions {
        var result = FileVideoOptions(usesSystem: false, systemAvailable: session.souloSystemAvailable)
        result.shareURL = session.url
        result.closePlayback = { _ in dismiss() }
        result.fullscreenOnly = true
        if session.hasVideo, session.pictureInPicture.supported {
            result.requestPictureInPicture = { _, _ in session.restoreSystemFromSoulo(pictureInPicture: true) }
        }
        return result
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
            if session.url != nil && session.playerSurfaces == 0 && session.playerPages == 0
                && session.musicPlayerPages == 0 && session.soulo?.hasVisibleSurface != true
                && !session.expanded && !pip.active && session.retainedPiPController == nil {
                let width = min(320.0, max(44, geometry.size.width - 24))
                let center = docked ? (trailing ? geometry.size.width - 18 : 18)
                    : (trailing ? geometry.size.width - width / 2 - 12 : width / 2 + 12)
                Group {
                    if docked {
                        Button { withAnimation(.compatibleSnappy) { docked = false } } label: {
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
                            Button { withAnimation(.compatibleSnappy) { docked = true } } label: {
                                Image(systemName: trailing ? "chevron.right" : "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary).frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel(ToolText.text("dock_player"))
                            if session.hasVideo {
                                Button { session.expanded = true } label: {
                                    Group {
                                        if let playback = session.soulo { MatroskaSurface(playback: playback, primary: false) }
                                        else { InlineVideoSurface(countsAsPlayerSurface: false) }
                                    }
                                    .allowsHitTesting(false)
                                    .frame(width: 52, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .frame(height: 44)
                                    .contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(ToolText.text("expand_player"))
                                    .accessibilityIdentifier("media.mini.open")
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
                            if session.hasVideo, pip.supported {
                                Button {
                                    if session.soulo != nil { session.restoreSystemFromSoulo(pictureInPicture: true) }
                                    else { pip.requestStart() }
                                } label: {
                                    Group {
                                        if session.souloSystemAvailabilityPending || pip.launching { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "pip.enter").font(.system(size: 17)) }
                                    }.frame(width: 44, height: 44)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(ToolText.text("media_pip"))
                                    .accessibilityValue(session.souloSystemAvailabilityPending ? ToolText.text("loading") : "")
                                    .accessibilityIdentifier("media.mini.picture-in-picture")
                                    .disabled(pip.launching || (session.soulo != nil && !session.souloSystemAvailable))
                            }
                            Button { session.toggle() } label: {
                                CompactIconLabel(systemImage: session.playing ? "pause.fill" : "play.fill")
                            }.buttonStyle(.plain)
                                .accessibilityLabel(ToolText.text(session.playing ? "pause" : "play"))
                            Button { session.stop() } label: {
                                CompactIconLabel(systemImage: "xmark")
                            }.buttonStyle(.plain).accessibilityLabel(ToolText.text("close"))
                        }
                        .padding(.horizontal, 4).frame(width: width, height: 58)
                        .accessibilityIdentifier("media.mini-player")
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
                .alert(ToolText.text("media_pip"), isPresented: Binding(
                    get: { pip.errorMessage != nil }, set: { if !$0 { pip.dismissError() } }
                )) { Button(ToolText.text("done")) { pip.dismissError() } } message: { Text(pip.errorMessage ?? "") }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .position(x: center, y: MiniPlayerDocking.verticalPosition(offset: y, height: geometry.size.height))
                .offset(drag)
                .gesture(DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        withAnimation(.compatibleSnappy) {
                            let end = center + value.translation.width
                            trailing = end > geometry.size.width / 2
                            docked = MiniPlayerDocking.shouldDock(center: end, width: geometry.size.width)
                            y = min(40, max(-geometry.size.height + 180, y + value.translation.height))
                        }
                    })
                .accessibilityAction(named: ToolText.text(docked ? "expand_player" : "dock_player")) {
                    withAnimation(.compatibleSnappy) { docked.toggle() }
                }
            }
        }
    }
}

struct MediaPlaybackSurface: View {
    @ObservedObject private var session = MediaSession.shared
    var onTap: (() -> Void)?
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
                InlineVideoSurface(onTap: onTap)
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
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle()).onTapGesture { onTap?() }
                .onAppear { session.playerSurfaces += 1 }
                .onDisappear { session.playerSurfaces = max(0, session.playerSurfaces - 1) }
        }
    }
}
struct AirPlayRoutePicker: UIViewRepresentable {
    var prioritizesVideoDevices = false
    var presentRequested: Binding<Bool>?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = prioritizesVideoDevices
        view.accessibilityLabel = "AirPlay"
        view.accessibilityIdentifier = "media.airplay.routePicker"
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.prioritizesVideoDevices = prioritizesVideoDevices
        if let presentRequested, presentRequested.wrappedValue { context.coordinator.present(view, request: presentRequested) }
    }
    static func dismantleUIView(_ view: AVRoutePickerView, coordinator: Coordinator) { coordinator.task?.cancel() }
    @MainActor final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var task: Task<Void, Never>?
        private var beganPresentation = false
        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor [weak self] in self?.beganPresentation = true }
        }
        func present(_ view: AVRoutePickerView, request: Binding<Bool>) {
            guard task == nil else { return }
            task = Task { @MainActor [weak self, weak view] in
                defer { self?.task = nil }
                for _ in 0..<40 {
                    guard !Task.isCancelled, request.wrappedValue, let view else { return }
                    if let window = view.window, window.windowScene?.activationState == .foregroundActive,
                       !view.bounds.isEmpty, !view.isHidden,
                       let controller = VideoOrientation.topController(in: window),
                       controller.transitionCoordinator == nil, !controller.isBeingPresented, !controller.isBeingDismissed,
                       let button = view.subviews.compactMap({ $0 as? UIButton }).first {
                        request.wrappedValue = false
                        self?.beganPresentation = false
                        button.sendActions(for: .touchUpInside)
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        if self?.beganPresentation == false { button.sendActions(for: .primaryActionTriggered) }
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                request.wrappedValue = false
            }
        }
        deinit { task?.cancel() }
    }
}

// Present from the visible page so expanding the floating player preserves
// the user's directory and the existing back stack.
private struct MediaPlayerNavigation: ViewModifier {
    var enabled: Bool
    @Environment(\.libraryPageIsActive) private var libraryPageIsActive
    @ObservedObject private var session = MediaSession.shared
    @StateObject private var presentation = MediaPlayerNavigationContext()
    @State private var showingPlayer = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *), !enabled { content } else { presenting(content) }
    }
    private func presenting(_ content: Content) -> some View {
        content
            .background { MediaPlayerNavigationAnchor(context: presentation).allowsHitTesting(false) }
            .task(id: session.expanded && libraryPageIsActive) {
                guard session.expanded, libraryPageIsActive else { return }
                // Retained pager content does not reliably receive another
                // onAppear after a destination is popped. Use the actual top
                // navigation controller, and allow an in-flight pop to finish.
                for _ in 0..<80 {
                    guard !Task.isCancelled, session.expanded else { return }
                    if !showingPlayer, presentation.canPresent {
                        if #unavailable(iOS 17.0) {
                            if presentation.presentLegacyPlayer() { session.expanded = false }
                            return
                        }
                        // Only the active page may consume the shared request.
                        session.expanded = false
                        showingPlayer = true
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                }
            }
            .modifier(NativePlayerDestination(isPresented: $showingPlayer))
    }
}

@MainActor private final class MediaPlayerNavigationContext: ObservableObject {
    weak var anchor: UIView?
    private var navigation: UINavigationController? {
        var responder: UIResponder? = anchor
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController { return navigation }
            responder = current.next
        }
        return nil
    }
    func presentLegacyPlayer() -> Bool {
        guard canPresent, let navigation else { return false }
        navigation.pushViewController(UIHostingController(rootView: LegacyPlayerPage()), animated: true)
        return true
    }
    var canPresent: Bool {
        guard let anchor, anchor.window?.isKeyWindow == true else { return false }
        var responder: UIResponder? = anchor
        while let current = responder {
            if let controller = current as? UIViewController, let navigation = controller.navigationController {
                guard let top = navigation.topViewController, navigation.transitionCoordinator == nil,
                      !top.isBeingDismissed, top.presentedViewController == nil,
                      let visibleView = top.viewIfLoaded else { return false }
                return anchor.isDescendant(of: visibleView)
            }
            responder = current.next
        }
        return false
    }
}

private struct MediaPlayerNavigationAnchor: UIViewRepresentable {
    let context: MediaPlayerNavigationContext
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        self.context.anchor = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { self.context.anchor = view }
}

extension View {
    func mediaPlayerNavigation(enabled: Bool = true) -> some View { modifier(MediaPlayerNavigation(enabled: enabled)) }
}

private struct NativePlayerDestination: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(isPresented: $isPresented) {
                MediaPlayerPage().toolbar(.hidden, for: .navigationBar)
            }
        } else { content }
    }
}

private struct LegacyPlayerPage: View {
    @ObservedObject private var language = LanguageManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    var body: some View {
        MediaPlayerPage().toolbar(.hidden, for: .navigationBar)
            .environmentObject(language).environmentObject(theme)
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
            .tint(Color.themePrimary)
            .accentColor(Color.themePrimary)
    }
}

struct InlineVideoSurface: UIViewRepresentable {
    @ObservedObject private var session = MediaSession.shared
    var countsAsPlayerSurface = true
    var onTap: (() -> Void)?
    init(countsAsPlayerSurface: Bool = true, onTap: (() -> Void)? = nil) {
        self.countsAsPlayerSurface = countsAsPlayerSurface; self.onTap = onTap
    }
    final class Host: UIView {
        let attachment = UUID()
        var countsAsPlayerSurface = true
        var onTap: (() -> Void)?
        var doubleTap: UITapGestureRecognizer?
        private var lastDoubleTap: CFTimeInterval = 0
        weak var video: MediaPictureInPicture.Surface?
        var verticalGesture: VideoVerticalGestureHandler?
        func mountVideoIfNeeded() {
            guard window != nil, video == nil,
                  let surface = MediaSession.shared.pictureInPicture.attach(id: attachment, primary: countsAsPlayerSurface) else { return }
            video = surface; addSubview(surface); setNeedsLayout()
            MediaSession.shared.pictureInPicture.didMount()
        }
        @objc func handleHold(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { MediaSession.shared.beginTemporaryRate() }
            else if [.ended, .cancelled, .failed].contains(gesture.state) { MediaSession.shared.endTemporaryRate() }
        }
        @objc func handleTap() {
            if CACurrentMediaTime() - lastDoubleTap > 0.25 { onTap?() }
        }
        @objc func handleDoubleTap() {
            lastDoubleTap = CACurrentMediaTime()
            MediaSession.shared.toggle()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            video?.transform = .identity
            video?.frame = bounds
            video?.transform = CGAffineTransform(scaleX: MediaSession.shared.mirrored ? -1 : 1, y: 1)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            mountVideoIfNeeded()
            MediaSession.shared.pictureInPicture.didMount()
        }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.countsAsPlayerSurface = countsAsPlayerSurface
        host.onTap = onTap
        let surface = MediaSession.shared.pictureInPicture.attach(id: host.attachment, primary: countsAsPlayerSurface)
        host.video = surface
        if let surface { host.addSubview(surface) }
        host.backgroundColor = .black
        if countsAsPlayerSurface {
            host.verticalGesture = VideoVerticalGestureHandler(in: host,
                enabled: { MediaSession.shared.hasVideo },
                brightness: { MediaSession.shared.adjustBrightness($0, screen: $1) },
                feedback: { MediaSession.shared.showAdjustment($0, value: $1) },
                position: { (MediaSession.shared.elapsed, MediaSession.shared.duration) },
                previewSeek: { MediaSession.shared.showSeekPreview($0, start: $1) },
                seek: { MediaSession.shared.seek($0) },
                ended: { MediaSession.shared.finishAdjustment() })
            let hold = UILongPressGestureRecognizer(target: host, action: #selector(Host.handleHold(_:)))
            hold.minimumPressDuration = 0.4
            host.addGestureRecognizer(hold)
            let tap = UITapGestureRecognizer(target: host, action: #selector(Host.handleTap))
            tap.require(toFail: hold)
            let doubleTap = UITapGestureRecognizer(target: host, action: #selector(Host.handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.name = "SouloInlinePlaybackDoubleTap"
            doubleTap.isEnabled = onTap != nil
            host.doubleTap = doubleTap; host.addGestureRecognizer(doubleTap)
            host.addGestureRecognizer(tap)
            Task { @MainActor in MediaSession.shared.playerSurfaces += 1 }
        }
        return host
    }
    func updateUIView(_ view: Host, context: Context) {
        view.onTap = onTap; view.doubleTap?.isEnabled = onTap != nil
        view.mountVideoIfNeeded(); view.setNeedsLayout()
    }
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
private struct ExtendedMediaTransfer {
    let source: DownloadPlaybackSource
    let originalURL: URL
    let title: String
    let context: VideoPlaybackRequestContext
    let prepared: SouloMediaPlaybackSource
    let time: Double
    let playing: Bool
    var rate: Float? = nil
}

private struct PendingSouloPlayback {
    let id = UUID()
    let time: Double
    let playing: Bool
    let reportsFailure: Bool
}

struct MediaPlaybackContent: View {
    var videoOptions: FileVideoOptions?
    var showEpisodes: (() -> Void)?
    var airPlayRequested: Binding<Bool>?
    var initialSouloPlayback: (time: Double, playing: Bool)?
    var initialSouloSource: DownloadPlaybackSource?
    var initialRate: Float?
    var restoredSoulo: MatroskaPlayback?
    var initialFullscreen = false
    var initialFullscreenLandscape: Bool?
    var fullscreenOnly = false
    var initialSystemPlayer = false
    var initialEpisodes = false
    var initialTitle: String?
    var audioOnly = false
    var ownsExplicitSource = false
    var externalPlaylist: FileVideoPlaylist?
    var onFullscreenClose: (() -> Void)?
    var downloadAction: (() -> Void)?
    var downloadIsVideo = true
    @AppStorage(VideoPlaybackPreferences.showsWebDownloadControlsKey) private var showsVideoDownloadControls = true
    @ObservedObject private var session = MediaSession.shared
    @ObservedObject private var pip = MediaSession.shared.pictureInPicture
    @StateObject private var controls = VideoControlsVisibility()
    @State private var transfer: ExtendedMediaTransfer?
    @State private var switchTask: Task<Void, Never>?
    @State private var pendingSouloPlayback: PendingSouloPlayback?
    @State private var isVisible = false
    @State private var switchError: String?
    @State private var ownAirPlayRequest = false
    @State private var appliedInitialPlayer = false
    @State private var appliedSource: ObjectIdentifier?
    @State private var preserveFullscreen = false
    @State private var episodesVisible = false
    @State private var showingFullScreen = false
    @State private var playbackWindow = VideoPlaybackWindow()
    @State private var frame: CapturedMediaFrame?
    @State private var capturing = false
    @State private var captureTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private func restoreExistingSouloPlayback() {
        guard !appliedInitialPlayer, let playback = restoredSoulo,
              let prepared = playback.preparedPlaybackSource else { return }
        let source = prepared.native
        transfer = ExtendedMediaTransfer(source: source, originalURL: session.url ?? prepared.url,
            title: session.title,
            context: playback.playbackRequestContext ?? VideoPlaybackRequestContext(
                url: prepared.url, referrer: source.pageURL, userAgent: AppConstants.mobileWebViewUserAgent, cookies: []),
            prepared: prepared, time: playback.elapsed, playing: playback.isPlaybackRequested)
        appliedInitialPlayer = true
    }

    private func fullscreen() {
        showingFullScreen = true
    }

    private var options: FileVideoOptions? {
        if var videoOptions {
            let notify = videoOptions.fullscreenChanged
            videoOptions.fullscreenChanged = { preserveFullscreen = $0; notify?($0) }
            if pip.supported, session.hasVideo { videoOptions.requestPictureInPicture = { _, _ in pip.requestStart() } }
            videoOptions.download = downloadAction
            videoOptions.downloadIsVideo = downloadIsVideo
            videoOptions.fullscreenOnly = fullscreenOnly || videoOptions.fullscreenOnly
            videoOptions.initialFullscreenLandscape = initialFullscreenLandscape ?? videoOptions.initialFullscreenLandscape
            return videoOptions
        }
        var result = FileVideoOptions(usesSystem: true, systemAvailable: true, playlist: externalPlaylist)
        result.fullscreenChanged = { preserveFullscreen = $0 }
        result.shareURL = session.url
        result.showsEpisodesOnAppear = initialEpisodes
        result.fullscreenOnly = fullscreenOnly
        result.initialFullscreenLandscape = initialFullscreenLandscape
        if let onFullscreenClose { result.closePlayback = { _ in onFullscreenClose() } }
        result.airPlayPresentation = airPlayRequested ?? $ownAirPlayRequest
        result.download = downloadAction
        result.downloadIsVideo = downloadIsVideo
        if pip.supported, session.hasVideo { result.requestPictureInPicture = { _, _ in pip.requestStart() } }
        return result
    }

    private func switchToSoulo(time: Double, playing: Bool, reportsFailure: Bool = true) {
        pendingSouloPlayback = PendingSouloPlayback(time: time, playing: playing, reportsFailure: reportsFailure)
        startPendingSouloPlayback()
    }

    private func startPendingSouloPlayback() {
        guard isVisible || transfer != nil || preserveFullscreen, let request = pendingSouloPlayback else { return }
        guard switchTask == nil, let source = initialSouloSource ?? session.playbackTransferSource() else { return }
        let intentRevision = session.playbackIntentRevision
        let explicitSource = initialSouloSource != nil, item = session.player.currentItem
        guard explicitSource || item != nil else { return }
        let explicitURL = source.asset.url.isFileURL ? source.asset.url : (source.webMediaContext?.resource.url ?? source.asset.url)
        let originalURL = explicitSource ? explicitURL : (session.url ?? source.asset.url)
        let title = explicitSource ? (initialTitle ?? source.pageURL?.host ?? source.asset.url.lastPathComponent) : session.title
        switchTask = Task { @MainActor in
            defer {
                switchTask = nil
                // A fullscreen dismissal can deliver onAppear before the
                // cancelled operation has unwound. Resume the pending choice
                // only after its owning playback view is visible again.
                if isVisible || transfer != nil || preserveFullscreen, pendingSouloPlayback != nil { startPendingSouloPlayback() }
            }
            do {
                let prepared = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: originalURL)
                let usesCache = HLSPlaybackBridge.usesLocalBridge(source.asset) || ProgressiveVideoPlaybackBridge.transfer(for: source.asset) != nil
                let context = await VideoPlaybackRequestContext.load(url: prepared.url, pageURL: usesCache ? nil : source.pageURL,
                    webView: usesCache ? nil : source.webView)
                try Task.checkCancellation()
                guard pendingSouloPlayback?.id == request.id else { return }
                guard explicitSource || session.player.currentItem === item else { pendingSouloPlayback = nil; return }
                // Keep the asset/cache/authentication context alive before the
                // native session releases it, including private playback leases.
                let next = ExtendedMediaTransfer(source: source, originalURL: originalURL, title: title,
                                                  context: context, prepared: prepared,
                                                  time: explicitSource ? request.time : session.elapsed,
                                                  playing: session.playbackIntentRevision == intentRevision ? request.playing : session.isPlaybackRequested,
                                                  rate: explicitSource ? initialRate : session.rate)
                pendingSouloPlayback = nil
                // The replacement stops the native session when it opens,
                // keeping its source leased until the new view takes ownership.
                transfer = next
            } catch is CancellationError { }
            catch {
                guard pendingSouloPlayback?.id == request.id else { return }
                pendingSouloPlayback = nil
                if request.reportsFailure { switchError = ToolText.text("media_unavailable") }
            }
        }
    }

    private func applyExplicitSouloSource() {
        guard let source = initialSouloSource, appliedSource != ObjectIdentifier(source),
              let initial = initialSouloPlayback else { return }
        appliedSource = ObjectIdentifier(source)
        appliedInitialPlayer = true
        switchTask?.cancel()
        switchToSoulo(time: initial.time, playing: initial.playing)
    }
    private func applyAutomaticPlayback() {
        guard !ownsExplicitSource, !appliedInitialPlayer, !initialSystemPlayer, videoOptions == nil,
              initialSouloPlayback == nil, session.playbackTransferSource() != nil else { return }
        appliedInitialPlayer = true
        switchToSoulo(time: session.elapsed, playing: session.isPlaybackRequested)
    }

    private func souloOptions(_ transfer: ExtendedMediaTransfer) -> FileVideoOptions {
        var result = FileVideoOptions(usesSystem: false, systemAvailable: true, playlist: externalPlaylist)
        result.requestAirPlay = { time, playing in
            (airPlayRequested ?? $ownAirPlayRequest).wrappedValue = true
            restoreSystem(transfer, time: time, playing: playing)
        }
        if pip.supported, UTType(filenameExtension: transfer.originalURL.pathExtension)?.conforms(to: .audio) != true {
            result.requestPictureInPicture = { time, playing in
                restoreSystem(transfer, time: time, playing: playing)
                pip.requestStart()
            }
        }
        result.fullscreenChanged = { preserveFullscreen = $0 }
        if let onFullscreenClose { result.closePlayback = { _ in onFullscreenClose() } }
        result.fullscreenOnly = fullscreenOnly
        result.initialFullscreenLandscape = initialFullscreenLandscape
        result.shareURL = transfer.originalURL
        result.download = downloadAction
        result.downloadIsVideo = downloadIsVideo
        return result
    }
    private func restoreSystem(_ transfer: ExtendedMediaTransfer, time: Double, playing: Bool) {
        switchTask?.cancel(); pendingSouloPlayback = nil
        session.open(url: transfer.originalURL, title: transfer.title, pageURL: transfer.source.pageURL,
                     asset: transfer.source.asset, webView: transfer.source.webView,
                     persistPosition: transfer.source.persistsPosition, downloadSource: transfer.source,
                     startAt: time, autoplay: playing, initialRate: session.soulo?.rate ?? session.rate)
        self.transfer = nil
        // Present the destination immediately; resolving HLS metadata must not
        // expose a portrait preview between two landscape players.
        if preserveFullscreen { fullscreen() }
    }

    private var playbackControls: some View {
        VStack(spacing: 6) {
            VideoPlaybackControls(elapsed: session.elapsed, duration: session.duration, rate: session.rate,
                playing: session.playing, identifier: "media.native", options: options, videoLoading: session.videoLoading,
                cacheProgress: session.videoCacheProgress, showEpisodes: showEpisodes ?? { episodesVisible = true }, expand: fullscreen,
                interactionChanged: controls.interaction, seek: session.seek, setRate: { _ = session.setRate($0) })
            if let error = session.error ?? session.startupWarning { VideoPlaybackStatus(message: error, identifier: "media.native.status").foregroundStyle(.secondary) }
        }.padding(20).background(Color(UIColor.secondarySystemGroupedBackground))
    }

    private var playbackPreview: some View {
        MediaPlaybackSurface(onTap: controls.toggle).overlay { NativeVideoHoldSpeedFeedback() }
    }

    var body: some View {
        ZStack {
            if let transfer {
                MatroskaPlayerView(url: transfer.prepared.url, resourceLease: transfer.prepared,
                                   requestContext: transfer.context, title: transfer.title,
                                   persistPosition: transfer.source.persistsPosition, startAt: transfer.time,
                                   autoplay: transfer.playing, initialRate: transfer.rate, options: souloOptions(transfer),
                                   startsFullscreen: preserveFullscreen, audioOnly: audioOnly)
                    .navigationTitle(transfer.title)
            } else if audioOnly, let url = options?.shareURL ?? session.url ?? initialSouloSource?.asset.url {
                MusicPlaybackView(url: url, title: initialTitle ?? session.title, options: options,
                    download: downloadAction, close: onFullscreenClose)
            } else {
                VStack(spacing: 0) {
                    if !showingFullScreen && !fullscreenOnly {
                        playbackPreview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("media.preview")
                            .modifier(VideoTransportOverlay(visibility: controls, playing: session.playing,
                                identifier: "media.native.play", toggle: session.toggle,
                                seek: { session.seek(session.elapsed + $0) }))
                        playbackControls
                    }
                    else {
                        Color.black.overlay {
                            if fullscreenOnly && !showingFullScreen && !ownsExplicitSource { ProgressView().tint(.white) }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if pip.launching {
                HStack(spacing: 8) { ProgressView(); Text(ToolText.text("media_pip")) }
                    .font(.subheadline).padding(12).background(.regularMaterial, in: Capsule())
                    .padding(12).allowsHitTesting(false)
                    .accessibilityIdentifier("media.pip.preparing")
            }
        }
        .alert(ToolText.text("media_pip"), isPresented: Binding(
            get: { pip.errorMessage != nil }, set: { if !$0 { pip.dismissError() } }
        )) { Button(ToolText.text("done")) { pip.dismissError() } } message: { Text(pip.errorMessage ?? "") }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if transfer == nil && !audioOnly {
                    Menu {
                        PlaybackSleepTimerMenu()
                        if let request = options?.requestPictureInPicture {
                            Button { request(session.elapsed, session.playing) } label: {
                                ToolMenuLabel(key: "media_pip", symbol: "pip.enter")
                            }.accessibilityIdentifier("media.picture-in-picture")
                        }
                        if let downloadAction, showsVideoDownloadControls || !downloadIsVideo {
                            Button(action: downloadAction) { Label(LanguageManager.shared.localizedString("download"), systemImage: "arrow.down.circle") }
                                .accessibilityIdentifier("media.compact.download")
                        }
                        if session.hasVideo {
                            Toggle(isOn: $session.loop) { ToolMenuLabel(key: "loop", symbol: "repeat.1") }
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
                        if let url = transfer?.originalURL ?? session.url {
                            ShareLink(item: url) { ToolMenuLabel(key: "share_media", symbol: "square.and.arrow.up") }
                        }
                        if let url = transfer?.source.pageURL ?? session.pageURL {
                            ShareLink(item: url) { ToolMenuLabel(key: "share_page", symbol: "globe") }
                        }
                        Button(ToolText.text("stop"), role: .destructive) { session.stop(); dismiss() }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityIdentifier("media.options")
                }
            }
        }
        .background(VideoPlaybackWindowReader(context: playbackWindow))
        .background {
            if !audioOnly {
                SessionPlayerController(isPresented: Binding(
                    get: { showingFullScreen },
                    set: { showingFullScreen = $0 }
                ), onDismiss: {}, options: options, videoLandscape: session.hasVideo ? session.videoIsLandscape : nil)
                    .frame(width: 0, height: 0)
            }
        }
        .onDisappear {
            if isVisible { session.playerPages = max(0, session.playerPages - 1) }
            isVisible = false
            captureTask?.cancel(); switchTask?.cancel(); session.endTemporaryRate()
        }
        .onAppear {
            if !isVisible { session.playerPages += 1 }
            isVisible = true
            if !appliedInitialPlayer && initialFullscreen { preserveFullscreen = true }
            restoreExistingSouloPlayback()
            if initialSystemPlayer, initialFullscreen, !appliedInitialPlayer {
                appliedInitialPlayer = true; fullscreen()
            }
            applyExplicitSouloSource()
            applyAutomaticPlayback()
            startPendingSouloPlayback()
        }
        .task(id: initialSouloSource.map(ObjectIdentifier.init)) { applyExplicitSouloSource() }
        .onCompatibleChange(of: session.url) { _, _ in if isVisible { applyAutomaticPlayback() } }
        .onCompatibleChange(of: session.hasVideo, initial: true) { _, hasVideo in
            guard !audioOnly, hasVideo, (isVisible || showingFullScreen || preserveFullscreen), !appliedInitialPlayer else { return }
            guard !ownsExplicitSource || initialSouloSource != nil else { return }
            if initialSystemPlayer {
                appliedInitialPlayer = true
                if initialFullscreen { preserveFullscreen = true; fullscreen() }
                return
            }
            guard initialSouloPlayback == nil || initialSouloSource != nil else { return }
            let initial = initialSouloPlayback ?? (videoOptions == nil
                ? (time: session.elapsed, playing: session.isPlaybackRequested) : nil)
            guard let initial else { return }
            appliedInitialPlayer = true
            switchToSoulo(time: initial.time, playing: initial.playing, reportsFailure: initialSouloPlayback != nil)
        }
        .modifier(VideoOrientationErrorAlert(message: $switchError))
        .modifier(FileVideoEpisodeDrawer(isPresented: $episodesVisible, playlist: externalPlaylist))
        .sheet(item: $frame) { item in MediaFrameShare(image: item.image) }

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
