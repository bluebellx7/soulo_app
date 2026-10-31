import SwiftUI
import UIKit

/// Observes the active vertical list without replacing its delegate or gestures.
struct LibraryScrollCollapseObserver: UIViewRepresentable {
    let active: Bool
    var onOffset: (CGFloat) -> Void
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        view.active = active; view.onOffset = onOffset
        if active { view.setNeedsLayout() } else { view.disconnect() }
    }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.disconnect() }
    final class Host: UIView {
        var active = false
        var onOffset: ((CGFloat) -> Void)?
        private weak var scroll: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var queued = false
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { disconnect() } else { setNeedsLayout() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard active, window != nil, scroll == nil else { return }
            // The marker is a sibling of the SwiftUI List, so search the nearest
            // hosting subtree before considering ancestors of the horizontal pager.
            var ancestor = superview
            while let parent = ancestor {
                if let found = findVerticalScroll(in: parent) { connect(found); return }
                ancestor = parent.superview
            }
        }
        private func findVerticalScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView,
               scroll.bounds.height > 100, scroll.bounds.width > 0,
               !scroll.isHidden, scroll.alpha > 0,
               scroll.contentSize.width <= scroll.bounds.width + 2 {
                let own = convert(bounds, to: window), candidate = scroll.convert(scroll.bounds, to: window)
                let intersection = own.intersection(candidate)
                if intersection.width > own.width * 0.8 && intersection.height > own.height * 0.7 { return scroll }
            }
            for child in view.subviews {
                if let found = findVerticalScroll(in: child) { return found }
            }
            return nil
        }
        private func connect(_ value: UIScrollView) {
            scroll = value
            observation = value.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.scheduleOffset()
            }
        }
        private func scheduleOffset() {
            guard active, !queued else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.queued = false
                guard self.active, let scroll = self.scroll else { return }
                self.onOffset?(max(0, scroll.contentOffset.y + scroll.adjustedContentInset.top))
            }
        }
        func disconnect() { observation?.invalidate(); observation = nil; scroll = nil }
    }
}
