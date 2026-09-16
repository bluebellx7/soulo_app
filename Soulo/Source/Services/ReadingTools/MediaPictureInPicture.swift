import AVKit
import Combine

/// Owns the inline video surface for the entire PiP session, including after navigation away.
@MainActor
final class MediaPictureInPicture: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var possible = false
    @Published private(set) var active = false
    private(set) var surface: Surface?
    private var controller: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?
    private var attached = false
    private var attachment: UUID?
    private var attachmentIsPrimary = false
    private var starting = false
    private var restoration: ((Bool) -> Void)?
    private var restorationTimeout: Task<Void, Never>?

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
        if supported {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.delegate = self
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            controller = pip
            observation = pip?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] pip, _ in
                let possible = pip.isPictureInPicturePossible
                Task { @MainActor in
                    guard let self, self.controller === pip else { return }
                    self.possible = possible
                }
            }
        }
        return view
    }

    func didMount() {
        guard surface?.window != nil else { return }
        finishRestoration(true)
    }

    func detach(id: UUID) {
        guard attachment == id else { return }
        attachment = nil
        attached = false
        if !active && !starting { releaseSurface() }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            MediaSession.shared.play()
            controller.startPictureInPicture()
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
        starting = false
        active = false
        finishRestoration(false)
        if !attached { releaseSurface() }
    }

    private func releaseSurface() {
        observation = nil
        controller?.delegate = nil
        controller = nil
        surface?.playerLayer.player = nil
        surface = nil
        possible = false
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        starting = true
        active = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        starting = false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        starting = false
        active = false
        MediaSession.shared.error = error.localizedDescription
        if !attached { releaseSurface() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        starting = false
        active = false
        if !attached { releaseSurface() }
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
