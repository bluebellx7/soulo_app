import Foundation

/// Opt-in simulator diagnostics. Release builds never emit browsing timings or
/// honor the A/B switch; no benchmark preference is persisted in user settings.
enum BrowserStartupTrace {
    #if DEBUG
    private static let traceLock = NSLock()
    private static var traceHandle: FileHandle?
    private static var traceSize = 0
    @MainActor private static var submittedBenchmark = false
    #endif
    static var disablesWarmup: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOULO_DISABLE_WEBVIEW_WARMUP"] == "1"
        #else
        false
        #endif
    }

    /// Drive the normal search path in opt-in DEBUG benchmarks, without the
    /// OS confirmation sheet introduced by launching a custom URL scheme.
    @MainActor static func scheduleBenchmarkSearch(_ model: SearchViewModel) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard !submittedBenchmark, environment["SOULO_BROWSER_TRACE"] == "1",
              let value = environment["SOULO_BENCHMARK_URL"], value.utf8.count <= 4096,
              let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return }
        submittedBenchmark = true
        let proposedDelay = Double(environment["SOULO_BENCHMARK_DELAY"] ?? "2.5") ?? 2.5
        let delay = proposedDelay.isFinite ? min(10, max(0, proposedDelay)) : 2.5
        Task { @MainActor [weak model] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let model else { return }
            model.searchText = url.absoluteString
            model.performSearch()
        }
        #endif
    }

    static func mark(_ event: String, detail: String = "") {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["SOULO_BROWSER_TRACE"] == "1" else { return }
        let line = "SOULO_TIMING|\(ProcessInfo.processInfo.systemUptime)|\(event)|\(detail)"
        print(line)
        fflush(stdout)
        // UI-test applications have a separate stdout from their runner. Keep
        // this opt-in, bounded copy available in the app's temporary directory.
        traceLock.lock()
        defer { traceLock.unlock() }
        if traceHandle == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("soulo-browser-trace.log")
            try? Data().write(to: url)
            traceHandle = try? FileHandle(forWritingTo: url)
        }
        if let data = (line + "\n").data(using: .utf8), traceSize + data.count <= 262_144 {
            try? traceHandle?.write(contentsOf: data)
            traceSize += data.count
        }
        #endif
    }
}
