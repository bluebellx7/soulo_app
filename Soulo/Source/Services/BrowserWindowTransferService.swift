import Foundation

/// Source removal is deferred until the new scene mounts and claims the tab.
/// Failed window creation therefore cannot lose a tab or its WebKit document.
@MainActor
final class BrowserWindowTransferService {
    static let shared = BrowserWindowTransferService()
    private struct Request {
        weak var source: TabManager?
        let tabID: UUID
        let isPrivate: Bool
    }
    private var requests: [UUID: Request] = [:]

    func prepare(from source: TabManager, tabID: UUID) -> BrowserWindowConfiguration? {
        guard source.tabs.contains(where: { $0.id == tabID }) else { return nil }
        requests = requests.filter { $0.value.source != nil }
        let configuration = BrowserWindowConfiguration()
        requests[configuration.id] = Request(source: source, tabID: tabID,
            isPrivate: UserDefaults.standard.bool(forKey: "is_incognito"))
        return configuration
    }

    @discardableResult
    func claim(windowID: UUID, into destination: TabManager) -> Bool {
        guard let request = requests.removeValue(forKey: windowID), let source = request.source,
              source !== destination,
              request.isPrivate == UserDefaults.standard.bool(forKey: "is_incognito") else { return false }
        return source.moveTab(request.tabID, to: destination)
    }
}
