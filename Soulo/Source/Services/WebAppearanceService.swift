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

    private let defaults = UserDefaults.standard
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        followsAppColorScheme = defaults.object(
            forKey: AppConstants.StorageKeys.webFollowsAppColorScheme
        ) as? Bool ?? true
        warmColorShift = defaults.bool(forKey: AppConstants.StorageKeys.webWarmColorShift)
        forceDarkPages = defaults.bool(forKey: AppConstants.StorageKeys.webForceDarkPages)
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

    func apply(to webView: WKWebView) {
        if forceDarkPages {
            webView.overrideUserInterfaceStyle = .dark
        } else if followsAppColorScheme {
            webView.overrideUserInterfaceStyle = effectiveAppInterfaceStyle
        } else {
            webView.overrideUserInterfaceStyle = .light
        }

        webView.evaluateJavaScript(
            WebViewScripts.applyWebAppearance(
                warmColorShift: warmColorShift,
                forceDark: forceDarkPages
            ),
            completionHandler: nil
        )
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

    private func refreshFromDefaults() {
        let follows = defaults.object(forKey: AppConstants.StorageKeys.webFollowsAppColorScheme) as? Bool ?? true
        let warm = defaults.bool(forKey: AppConstants.StorageKeys.webWarmColorShift)
        let dark = defaults.bool(forKey: AppConstants.StorageKeys.webForceDarkPages)
        if followsAppColorScheme != follows { followsAppColorScheme = follows }
        if warmColorShift != warm { warmColorShift = warm }
        if forceDarkPages != dark { forceDarkPages = dark }
    }
}

extension Notification.Name {
    static let webAppearanceChanged = Notification.Name("soulo.webAppearanceChanged")
}
