import Foundation

/// Opt-in simulator diagnostics. Release builds never emit browsing timings or
/// honor the A/B switch; no benchmark preference is persisted in user settings.
enum BrowserStartupTrace {
    static var disablesWarmup: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOULO_DISABLE_WEBVIEW_WARMUP"] == "1"
        #else
        false
        #endif
    }

    static func mark(_ event: String, detail: String = "") {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SOULO_BROWSER_TRACE"] == "1" else { return }
        print("SOULO_TIMING|\(ProcessInfo.processInfo.systemUptime)|\(event)|\(detail)")
        fflush(stdout)
        #endif
    }
}
