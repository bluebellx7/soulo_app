import UIKit

/// A web URL delivered back to this app after an explicit external-open action
/// means the system routed it to Soulo. Consume that one handoff before normal
/// URL handling can create another tab, then use Safari instead.
@MainActor
final class ExternalBrowserService {
    static let shared = ExternalBrowserService()
    private let openURL: (URL) async -> Bool
    private let now: () -> Date
    private var pending: Request?
    private var expiry: Task<Void, Never>?

    private struct Request {
        let id = UUID()
        let url: URL
        let expires: Date
        let safariFallback: () -> Void
    }

    init(openURL: @escaping (URL) async -> Bool = { await UIApplication.shared.open($0, options: [:]) },
         now: @escaping () -> Date = Date.init) {
        self.openURL = openURL
        self.now = now
    }

    func open(_ url: URL, safariFallback: @escaping () -> Void, onFailure: @escaping () -> Void) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            onFailure(); return
        }
        clearPending()
        let request = Request(url: url, expires: now().addingTimeInterval(5),
            safariFallback: safariFallback)
        pending = request
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if self?.pending?.id == request.id { self?.clearPending() }
        }
        Task { [weak self] in
            guard let self else { return }
            let success = await openURL(url)
            guard !success, pending?.id == request.id else { return }
            clearPending()
            await openSafari(request)
        }
    }

    @discardableResult
    func consumeReturnedURL(_ url: URL) -> Bool {
        guard let request = pending else { return false }
        guard now() <= request.expires else { clearPending(); return false }
        guard url == request.url else { return false }
        clearPending()
        Task { await openSafari(request) }
        return true
    }

    private func openSafari(_ request: Request) async {
        if let safariURL = Self.safariURL(for: request.url), await openURL(safariURL) { return }
        // Safari's registered external scheme is HTTPS-only. Preserve HTTP
        // and unavailable-Safari URLs exactly using the system Safari view.
        request.safariFallback()
    }

    static func safariURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "x-safari-https"
        return parts.url
    }

    private func clearPending() {
        expiry?.cancel(); expiry = nil
        pending = nil
    }

    deinit { expiry?.cancel() }
}
