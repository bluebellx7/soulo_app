import AVKit
import Combine

/// Owns the inline video surface for the entire PiP session, including after navigation away.
@MainActor
final class MediaPictureInPicture: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    let supported: Bool
    @Published private(set) var possible = false
    @Published private(set) var active = false
    @Published private(set) var launching = false
    @Published private(set) var errorMessage: String?
    private let startupTimeout: Duration
    private(set) var surface: Surface?
    private var controller: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?
    private var readinessObservation: NSKeyValueObservation?
    private var attached = false
    private var attachment: UUID?
    private var attachmentIsPrimary = false
    private var starting = false
    private var stopping = false
    private var requested = false
    var keepsPlaybackInBackground: Bool { active || starting || requested }
    private var startTimeout: Task<Void, Never>?
    private var restoration: ((Bool) -> Void)?
    private var restorationTimeout: Task<Void, Never>?

    init(supported: Bool = AVPictureInPictureController.isPictureInPictureSupported(), startupTimeout: Duration = .seconds(10)) {
        self.supported = supported
        self.startupTimeout = startupTimeout
        super.init()
    }

    func dismissError() { errorMessage = nil }

    func attach(id: UUID, primary: Bool = true) -> Surface? {
        // SwiftUI can briefly construct the mini-player while the full player's
        // surface count is being published. Never let that thumbnail steal the
        // primary layer and then detach it as the mini-player disappears.
        guard primary || !attached || !attachmentIsPrimary else { return nil }
        attachmentIsPrimary = primary
        attachment = id
        attached = true
        if let surface { return surface }
        let view = Surface()
        view.backgroundColor = .black
        view.playerLayer.player = MediaSession.shared.player
        view.playerLayer.videoGravity = .resizeAspect
        surface = view
        readinessObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak view] _, _ in
            Task { @MainActor in
                guard let self, let view, self.surface === view else { return }
                self.startIfReady()
            }
        }
        if supported {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.delegate = self
            // Switching apps pauses ordinary video. PiP is a deliberate action
            // from the player's floating-window control.
            pip?.canStartPictureInPictureAutomaticallyFromInline = false
            controller = pip
            observation = pip?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
                let possible = pip.isPictureInPicturePossible
                Task { @MainActor in
                    guard let self, self.controller === pip else { return }
                    self.possible = possible
                    self.startIfReady()
                }
            }
        }
        return view
    }

    func didMount() {
        guard surface?.window != nil else { return }
        finishRestoration(true)
        startIfReady()
    }

    func detach(id: UUID) {
        guard attachment == id else { return }
        attachment = nil
        attached = false
        if !active && !starting && !stopping && !requested { releaseSurface() }
    }

    func toggle() {
        if active { controller?.stopPictureInPicture() }
        else { requestStart() }
    }

    /// Decoder handoffs can precede the new AVPlayerLayer by a frame. Retain the
    /// user's request until that actual layer is mounted and ready for PiP.
    func requestStart() {
        guard supported else { errorMessage = ToolText.text("media_pip_unavailable"); return }
        guard !active, !starting, !requested else { return }
        errorMessage = nil; launching = true
        requested = true
        startTimeout?.cancel()
        startTimeout = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.startupTimeout) } catch { return }
            guard self.requested || self.starting else { return }
            self.stopping = self.stopping || (self.starting && self.controller != nil)
            self.requested = false; self.starting = false; self.launching = false
            self.controller?.stopPictureInPicture()
            MediaSession.shared.pauseVideoIfBackgrounded()
            self.errorMessage = ToolText.text("media_pip_unavailable")
            if !self.attached && !self.stopping { self.releaseSurface() }
        }
        // A paused, newly loaded item may not render its first frame until
        // playback starts. Prime it while waiting for the PiP source to be ready.
        MediaSession.shared.play()
        startIfReady()
    }
    private func startIfReady() {
        guard requested, !active, !starting, !stopping, surface?.window != nil,
              surface?.playerLayer.isReadyForDisplay == true,
              let controller, controller.isPictureInPicturePossible else { return }
        requested = false; starting = true
        MediaSession.shared.play()
        controller.startPictureInPicture()
    }

    func stop() {
        requested = false; startTimeout?.cancel(); startTimeout = nil
        launching = false; errorMessage = nil
        stopping = stopping || active || (starting && controller != nil) || controller?.isPictureInPictureActive == true
        controller?.stopPictureInPicture()
        starting = false
        active = false
        finishRestoration(false)
        if !attached && !stopping { releaseSurface() }
    }

    private func releaseSurface() {
        stopping = false
        observation = nil
        readinessObservation = nil
        controller?.delegate = nil
        controller = nil
        surface?.playerLayer.player = nil
        surface = nil
        possible = false
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController, !stopping, requested || starting || launching else { return }
        starting = true; launching = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController, !stopping, starting || launching else {
            pictureInPictureController.stopPictureInPicture(); return
        }
        starting = false
        active = true
        launching = false; startTimeout?.cancel(); startTimeout = nil
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        starting = false
        active = false
        if stopping && requested {
            stopping = false
            restartAfterStopCallback()
            return
        }
        stopping = false
        requested = false; launching = false; startTimeout?.cancel(); startTimeout = nil
        MediaSession.shared.pauseVideoIfBackgrounded()
        errorMessage = error.localizedDescription
        if !attached { releaseSurface() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        starting = false
        active = false
        stopping = false
        if requested { restartAfterStopCallback() }
        else { launching = false }
        MediaSession.shared.pauseVideoIfBackgrounded()
        if !attached && !requested && !starting { releaseSurface() }
    }

    private func restartAfterStopCallback() {
        // AVKit finishes its stop transition after returning from the delegate.
        // A synchronous restart here can be ignored even while possible is true.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startIfReady()
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if attached, surface?.window != nil { completionHandler(true); return }
        finishRestoration(false)
        restoration = completionHandler
        MediaSession.shared.expanded = true
        restorationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.finishRestoration(false)
        }
    }

    private func finishRestoration(_ success: Bool) {
        restorationTimeout?.cancel()
        restorationTimeout = nil
        let completion = restoration
        restoration = nil
        completion?(success)
    }
}
