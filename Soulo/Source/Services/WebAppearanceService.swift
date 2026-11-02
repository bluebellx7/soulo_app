import UIKit
import WebKit

@MainActor
final class WebAppearanceService: ObservableObject {
    static let shared = WebAppearanceService()

    @Published var followsAppColorScheme: Bool {
        didSet { persist(followsAppColorScheme, key: AppConstants.StorageKeys.webFollowsAppColorScheme) }
    }

    @Published var warmColorShift: Bool {
        didSet { persist(warmColorShift, key: AppConstants.StorageKeys.webWarmColorShift) }
    }

    @Published var forceDarkPages: Bool {
        didSet { persist(forceDarkPages, key: AppConstants.StorageKeys.webForceDarkPages) }
    }

    @Published var reducePageMotion: Bool {
        didSet { persist(reducePageMotion, key: AppConstants.StorageKeys.webReducePageMotion) }
    }

    @Published var underlineLinks: Bool {
        didSet { persist(underlineLinks, key: AppConstants.StorageKeys.webUnderlineLinks) }
    }

    private let defaults = UserDefaults.standard
    private var defaultsObserver: NSObjectProtocol?
    private let appliedScripts = NSMapTable<WKWebView, NSString>.weakToStrongObjects()
    private struct ScriptOptions: Equatable {
        let forceDark: Bool
        let reduceMotion: Bool
        let underlineLinks: Bool
        var isEnabled: Bool { forceDark || reduceMotion || underlineLinks }
    }
    private final class ScriptInstallation {
        let options: ScriptOptions
        let scripts: [WKUserScript]

        init(options: ScriptOptions, scripts: [WKUserScript]) {
            self.options = options
            // The imported array can share WebKit's mutable Objective-C storage.
            // Own a snapshot of the references so external edits invalidate it.
            self.scripts = scripts.map { $0 }
        }

        func matches(_ options: ScriptOptions, scripts: [WKUserScript]) -> Bool {
            self.options == options && self.scripts.count == scripts.count
                && zip(self.scripts, scripts).allSatisfy { pair in pair.0 === pair.1 }
        }
    }
    private let scriptInstallations = NSMapTable<WKUserContentController, ScriptInstallation>.weakToStrongObjects()
    private var cachedScriptOptions: ScriptOptions?
    private var cachedScriptSource = ""

    private init() {
        followsAppColorScheme = defaults.object(
            forKey: AppConstants.StorageKeys.webFollowsAppColorScheme
        ) as? Bool ?? true
        warmColorShift = defaults.bool(forKey: AppConstants.StorageKeys.webWarmColorShift)
        forceDarkPages = defaults.bool(forKey: AppConstants.StorageKeys.webForceDarkPages)
        reducePageMotion = defaults.bool(forKey: AppConstants.StorageKeys.webReducePageMotion)
        underlineLinks = defaults.bool(forKey: AppConstants.StorageKeys.webUnderlineLinks)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromDefaults()
            }
        }
    }

    func toggleForceDarkPages() {
        forceDarkPages.toggle()
        HapticsManager.selection()
    }

    func apply(to webView: WKWebView, force: Bool = false) {
        if forceDarkPages {
            webView.overrideUserInterfaceStyle = .dark
        } else if followsAppColorScheme {
            webView.overrideUserInterfaceStyle = effectiveAppInterfaceStyle
        } else {
            webView.overrideUserInterfaceStyle = .light
        }

        let overlay = webView.subviews.first { $0 is WebWarmColorOverlay }
        if warmColorShift {
            let tint = overlay ?? WebWarmColorOverlay(frame: webView.bounds)
            tint.frame = webView.bounds
            if tint.superview == nil { webView.addSubview(tint) }
            webView.bringSubviewToFront(tint)
        } else {
            overlay?.removeFromSuperview()
        }

        let options = ScriptOptions(forceDark: forceDarkPages, reduceMotion: reducePageMotion, underlineLinks: underlineLinks)
        let needsDOMAppearance = options.isEnabled
        if cachedScriptOptions != options {
            cachedScriptSource = needsDOMAppearance ? Self.scriptPrefix + WebViewScripts.applyWebAppearance(
                forceDark: options.forceDark, reduceMotion: options.reduceMotion, underlineLinks: options.underlineLinks
            ) : ""
            cachedScriptOptions = options
        }
        let source = cachedScriptSource
        let controller = webView.configuration.userContentController
        let scripts = controller.userScripts
        // Scripts are immutable. Comparing the retained objects detects additions,
        // removals and replacements without reading every source on each update.
        if scriptInstallations.object(forKey: controller)?.matches(options, scripts: scripts) != true {
            let existing = scripts.filter { $0.source.hasPrefix(Self.scriptPrefix) }
            if existing.count != (source.isEmpty ? 0 : 1) || existing.first?.source != (source.isEmpty ? nil : source) {
                let others = scripts.filter { !$0.source.hasPrefix(Self.scriptPrefix) }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
                if !source.isEmpty {
                    controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                }
            }
            scriptInstallations.setObject(ScriptInstallation(options: options, scripts: controller.userScripts), forKey: controller)
        }
        let previous = appliedScripts.object(forKey: webView) as String?
        guard needsDOMAppearance || previous != nil else { return }
        guard force || previous != source else { return }
        if source.isEmpty { appliedScripts.removeObject(forKey: webView) }
        else { appliedScripts.setObject(source as NSString, forKey: webView) }
        let update = source.isEmpty
            ? "window.__souloApplyWebAppearance?.({forceDark:false,reduceMotion:false,underlineLinks:false});true;"
            : source
        webView.evaluateJavaScript(update) { [weak self, weak webView] _, error in
            guard error != nil, let self, let webView,
                  self.appliedScripts.object(forKey: webView) as String? == source else { return }
            self.appliedScripts.removeObject(forKey: webView)
        }
    }

    static let scriptPrefix = "// soulo-web-appearance\n"

    static func hasWarmOverlay(on webView: WKWebView) -> Bool {
        webView.subviews.contains { $0 is WebWarmColorOverlay }
    }

    /// WebKit snapshots contain webpage pixels, so apply the native viewing
    /// tint explicitly when exporting a screenshot or saving a tab preview.
    static func applyingWarmColor(to image: UIImage, enabled: Bool) -> UIImage {
        guard enabled else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            WebWarmColorOverlay.tint.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
        }
    }

    private var effectiveAppInterfaceStyle: UIUserInterfaceStyle {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)?.traitCollection.userInterfaceStyle
            ?? windows.first?.traitCollection.userInterfaceStyle
            ?? .unspecified
    }

    private func persist(_ value: Bool, key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .webAppearanceChanged, object: nil)
    }

    func refreshFromDefaults() {
        let follows = defaults.object(forKey: AppConstants.StorageKeys.webFollowsAppColorScheme) as? Bool ?? true
        let warm = defaults.bool(forKey: AppConstants.StorageKeys.webWarmColorShift)
        let dark = defaults.bool(forKey: AppConstants.StorageKeys.webForceDarkPages)
        let reduceMotion = defaults.bool(forKey: AppConstants.StorageKeys.webReducePageMotion)
        let links = defaults.bool(forKey: AppConstants.StorageKeys.webUnderlineLinks)
        if followsAppColorScheme != follows { followsAppColorScheme = follows }
        if warmColorShift != warm { warmColorShift = warm }
        if forceDarkPages != dark { forceDarkPages = dark }
        if reducePageMotion != reduceMotion { reducePageMotion = reduceMotion }
        if underlineLinks != links { underlineLinks = links }
    }
}

extension Notification.Name {
    static let webAppearanceChanged = Notification.Name("soulo.webAppearanceChanged")
}

private final class WebWarmColorOverlay: UIView {
    static let tint = UIColor(red: 1, green: 154.0 / 255, blue: 61.0 / 255, alpha: 0.055)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.tint
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "browser.web.warmOverlay"
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layer.zPosition = 1_000
    }

    required init?(coder: NSCoder) { return nil }
}
