import UIKit

/// Keep the native pull gesture and refresh lifecycle, with a quiet monochrome ring.
/// Core Animation runs the rotation without a display link or per-frame Swift work.
final class BrowserRefreshControl: UIRefreshControl {
    private let indicator = UIView(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var pullProgress: CGFloat = 0
    private var isApplicationActive = true

    override init() {
        super.init()
        tintColor = .clear
        indicator.isUserInteractionEnabled = false
        indicator.alpha = 0
        indicator.accessibilityIdentifier = "browser.refresh-indicator"
        indicator.isAccessibilityElement = true
        indicator.accessibilityLabel = LanguageManager.shared.localizedString("loading")
        addSubview(indicator)

        let circle = UIBezierPath(arcCenter: CGPoint(x: 13, y: 13), radius: 10.5,
                                  startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        track.path = circle
        track.frame = indicator.bounds
        track.fillColor = UIColor.clear.cgColor
        track.lineWidth = 2
        indicator.layer.addSublayer(track)

        arc.path = circle
        arc.frame = indicator.bounds
        arc.fillColor = UIColor.clear.cgColor
        arc.lineWidth = 2
        arc.lineCap = .round
        indicator.layer.addSublayer(arc)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (control: BrowserRefreshControl, _: UITraitCollection) in
            control.updateColors()
        }

        addTarget(self, action: #selector(refreshStarted), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameInactive),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        indicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
        bringSubviewToFront(indicator)
        updateIndicator()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateIndicator()
    }

    override func beginRefreshing() {
        super.beginRefreshing()
        updateIndicator()
    }

    override func endRefreshing() {
        super.endRefreshing()
        pullProgress = 0
        updateIndicator()
    }

    func updatePull(distance: CGFloat) {
        guard !isRefreshing else { return }
        let progress = min(1, max(0, distance / 90))
        guard progress != pullProgress else { return }
        pullProgress = progress
        updateIndicator()
    }

    @objc private func refreshStarted() { updateIndicator() }
    @objc private func motionChanged() { updateIndicator() }
    @objc private func becameInactive() {
        isApplicationActive = false
        updateIndicator()
    }
    @objc private func becameActive() {
        isApplicationActive = true
        updateIndicator()
    }

    private func updateColors() {
        track.strokeColor = UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.08).cgColor
        arc.strokeColor = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
    }

    private func updateIndicator() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = isRefreshing ? 0.78 : max(0.025, pullProgress * 0.95)
        indicator.alpha = isRefreshing ? 1 : min(1, pullProgress * 3)
        let scale = isRefreshing || UIAccessibility.isReduceMotionEnabled ? 1 : 0.7 + pullProgress * 0.3
        indicator.transform = CGAffineTransform(scaleX: scale, y: scale)
        CATransaction.commit()

        if isRefreshing && window != nil && isApplicationActive && !UIAccessibility.isReduceMotionEnabled {
            if arc.animation(forKey: "orbit") == nil {
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = 0
                rotation.toValue = CGFloat.pi * 2
                rotation.duration = 1.1
                rotation.repeatCount = .infinity
                arc.add(rotation, forKey: "orbit")
            }
        } else {
            arc.removeAnimation(forKey: "orbit")
        }
    }
}
