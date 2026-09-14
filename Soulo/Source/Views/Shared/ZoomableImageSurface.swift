import SwiftUI

/// UIKit owns pinch/pan arbitration; downward dismissal only starts at fit scale.
struct ZoomableImageSurface: UIViewRepresentable {
    let image: Image
    var uiImage: UIImage?
    var onDismiss: () -> Void
    init(image: Image, onDismiss: @escaping () -> Void) { self.image = image; self.onDismiss = onDismiss }
    init(uiImage: UIImage, onDismiss: @escaping () -> Void) { self.image = Image(uiImage: uiImage); self.uiImage = uiImage; self.onDismiss = onDismiss }
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    func makeUIView(context: Context) -> ImageZoomScrollView {
        let scroll = ImageZoomScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator
        if let uiImage {
            let native = UIImageView(image: uiImage)
            native.contentMode = .scaleAspectFit
            scroll.addSubview(native)
            scroll.imageView = native
        } else {
            let host = UIHostingController(rootView: AnyView(image.resizable().scaledToFit()))
            host.view.backgroundColor = .clear
            scroll.addSubview(host.view)
            scroll.imageView = host.view
            context.coordinator.host = host
        }
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissPan(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = context.coordinator
        scroll.addGestureRecognizer(swipe)
        scroll.panGestureRecognizer.require(toFail: swipe)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        scroll.accessibilityIdentifier = "image.zoomSurface"
        scroll.accessibilityValue = "100%"
        return scroll
    }
    func updateUIView(_ scroll: ImageZoomScrollView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.host?.rootView = AnyView(image.resizable().scaledToFit())
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var host: UIHostingController<AnyView>?
        var onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { scrollView.accessibilityValue = "\(Int(scrollView.zoomScale * 100))%" }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageZoomScrollView)?.imageView }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let scroll = pan.view as? UIScrollView else { return true }
            let velocity = pan.velocity(in: scroll)
            return scroll.zoomScale <= 1.01 && velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.3
        }
        @objc func dismissPan(_ pan: UIPanGestureRecognizer) {
            guard let scroll = pan.view as? UIScrollView else { return }
            if pan.state == .ended, scroll.zoomScale <= 1.01 {
                let translation = pan.translation(in: scroll)
                if translation.y > 100 || (translation.y > 35 && pan.velocity(in: scroll).y > 650) { onDismiss() }
            }
        }
        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = tap.location(in: (scroll as? ImageZoomScrollView)?.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x-size.width/2, y: point.y-size.height/2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class ImageZoomScrollView: UIScrollView {
    weak var imageView: UIView?
    private var viewport = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != viewport, bounds.width > 0, bounds.height > 0 else { return }
        viewport = bounds.size
        setZoomScale(1, animated: false)
        imageView?.frame = CGRect(origin: .zero, size: viewport)
        contentSize = viewport
    }
}
