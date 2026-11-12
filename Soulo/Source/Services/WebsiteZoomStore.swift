import Combine
import Foundation

@MainActor final class WebsiteZoomStore: ObservableObject {
    static let shared = WebsiteZoomStore()
    static let sitesKey = "browser.websiteZoom.sites"
    static let enabledKey = "browser.websiteZoom.enabled"
    @Published private(set) var sites: [String: Double]
    @Published var isEnabled: Bool {
        didSet { if isEnabled != oldValue { defaults.set(isEnabled, forKey: Self.enabledKey) } }
    }
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sites = Self.readSites(defaults)
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    nonisolated static func host(for url: URL?) -> String? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.user == nil, parts.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    nonisolated static func normalized(_ zoom: Double) -> Double? {
        guard zoom.isFinite else { return nil }
        return min(2, max(0.5, (zoom * 10).rounded() / 10))
    }

    func zoom(for url: URL?) -> Double {
        guard isEnabled, let host = Self.host(for: url) else { return 1 }
        return sites[host] ?? 1
    }

    func set(_ zoom: Double, for url: URL?) {
        guard isEnabled, let host = Self.host(for: url), let value = Self.normalized(zoom) else { return }
        var next = sites
        if value == 1 { next[host] = nil } else { next[host] = value }
        if next.count > 512, let evicted = next.keys.sorted().first(where: { $0 != host }) { next[evicted] = nil }
        persist(next)
    }

    func reset(host: String) { var next = sites; next[host] = nil; persist(next) }
    func resetAll() { persist([:]) }

    private func persist(_ values: [String: Double]) {
        guard values != sites else { return }
        sites = values
        defaults.set(values, forKey: Self.sitesKey)
    }

    private func reload() {
        let next = Self.readSites(defaults)
        if sites != next { sites = next }
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if isEnabled != enabled { isEnabled = enabled }
    }

    private static func readSites(_ defaults: UserDefaults) -> [String: Double] {
        let values = defaults.dictionary(forKey: sitesKey) ?? [:]
        return Dictionary(uniqueKeysWithValues: values.keys.sorted().prefix(512).compactMap { host in
            guard let value = values[host] as? Double, value.isFinite, (0.5...2).contains(value), value != 1,
                  Self.host(for: URL(string: "https://" + host)) == host else { return nil }
            guard let normalized = Self.normalized(value), normalized != 1 else { return nil }
            return (host, normalized)
        })
    }
}
