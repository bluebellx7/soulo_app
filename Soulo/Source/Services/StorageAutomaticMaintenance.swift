import Darwin
import Foundation
import UIKit

/// Opportunistic maintenance has no scheduler, network request or WebKit work.
/// It uses at most the short execution time already available on backgrounding.
@MainActor
final class StorageAutomaticMaintenance {
    static let shared = StorageAutomaticMaintenance()
    private let sessionStartedAt = Date()
    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
    private var work: Task<Void, Never>?
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid
    private var managers: [WeakManager] = []
    private static let attemptKey = "soulo.storage.automaticMaintenance.lastProgress.v1"
    private static let completedKey = "soulo.storage.automaticMaintenance.completed.v1"
    private static let cursorKey = "soulo.storage.automaticMaintenance.cursor.v1"
    private static let pendingKey = "soulo.storage.automaticMaintenance.pending.v1"
    private final class WeakManager {
        weak var value: TabManager?
        init(_ value: TabManager) { self.value = value }
    }

    func start() {
        guard observers.isEmpty, NSClassFromString("XCTestCase") == nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.request() } })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel() } })
    }

    func register(_ manager: TabManager) {
        managers.removeAll { $0.value == nil }
        if !managers.contains(where: { $0.value === manager }) { managers.append(WeakManager(manager)) }
    }

    private func cancel() {
        work?.cancel()
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard backgroundID != .invalid else { return }
        let identifier = backgroundID
        backgroundID = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func request() {
        let application = UIApplication.shared, now = Date()
        guard work == nil, application.applicationState == .background,
              application.isProtectedDataAvailable,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue,
              now.timeIntervalSince(defaults.object(forKey: Self.attemptKey) as? Date ?? .distantPast) >= 86_400,
              application.backgroundTimeRemaining > 1.25 else { return }
        // Reading models does not activate an inactive tab or instantiate WebKit.
        guard !managers.compactMap(\.value).contains(where: { manager in
            manager.tabs.contains { tab in
                let model = tab.webViewModel
                return model.hasBottomVideoControls || model.isDownloading || model.activeDownloadCount > 0
                    || model.mediaSession.hasLiveExtensionMedia
            }
        }), MediaSession.shared.url == nil, !MediaExportBackgroundService.shared.hasJobsForStorageCleanup else { return }

        var protected = Set<String>()
        if #available(iOS 18.4, *) {
            protected.formUnion(WebExtensionBlobBridge.retainedTemporaryURLs.map(StorageAutomaticMaintenanceScan.path))
        }
        let options = StorageAutomaticMaintenanceScan.Options(now: now, sessionStartedAt: sessionStartedAt,
            maximumEntries: 2_000, maximumDuration: min(1, application.backgroundTimeRemaining - 0.25),
            protectedPaths: protected, resumeAfter: defaults.string(forKey: Self.cursorKey),
            pendingDirectory: defaults.string(forKey: Self.pendingKey))
        let root = FileManager.default.temporaryDirectory
        backgroundID = application.beginBackgroundTask(withName: "Expired temporary artifacts") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        guard backgroundID != .invalid else { return }
        let worker = Task.detached(priority: .utility) { StorageAutomaticMaintenanceScan.run(in: root, options: options) }
        work = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return }
            defer { self.work = nil; self.endBackgroundTime() }
            // A partial scan is not a completed pass. Remember where it stopped,
            // and resume the remaining roots on the next eligible background.
            if result.inspectedEntries > 0 || result.removedFiles > 0 {
                self.defaults.set(now, forKey: Self.attemptKey)
                self.defaults.set(result.resumeAfter, forKey: Self.cursorKey)
                self.defaults.set(result.pendingDirectory, forKey: Self.pendingKey)
            }
            if result.completed, !Task.isCancelled {
                self.defaults.set(now, forKey: Self.completedKey)
                self.defaults.set(now, forKey: Self.attemptKey)
                self.defaults.removeObject(forKey: Self.cursorKey)
                self.defaults.removeObject(forKey: Self.pendingKey)
            } else if result.inspectedEntries == 0, result.resumeAfter == nil, !Task.isCancelled {
                // A missing cursor or cancellation before work must not hold a
                // stale position forever or claim a successful maintenance day.
                self.defaults.removeObject(forKey: Self.cursorKey)
            }
        }
    }
}

enum StorageAutomaticMaintenanceScan {
    struct Options: Sendable {
        var now: Date
        var sessionStartedAt: Date
        var maximumEntries = 2_000
        var maximumDuration: TimeInterval = 1
        var protectedPaths: Set<String> = []
        var resumeAfter: String? = nil
        var pendingDirectory: String? = nil
    }
    struct Result: Sendable {
        var inspectedEntries = 0
        var removedFiles = 0
        var completed = false
        var resumeAfter: String?
        var pendingDirectory: String?
    }

    static func path(_ url: URL) -> String {
        let value = url.standardizedFileURL.path
        return value.hasPrefix("/private/var/") || value.hasPrefix("/private/tmp/") ? String(value.dropFirst(8)) : value
    }

    /// Only these nonpersistent, UUID-named export/import/preview artifacts are
    /// owned here. No download, player bundle or extension data directory is.
    static func ownsDirectory(_ name: String) -> Bool {
        for prefix in ["extension-cache-", "WallpaperExport-", "SouloPreview-", "SouloPhotoImport-", "soulo-import-"] {
            if name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }

    static func run(in suppliedRoot: URL, options: Options,
                    uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    cancelled: () -> Bool = { Task.isCancelled }) -> Result {
        let manager = FileManager.default, started = uptime()
        var result = Result(resumeAfter: options.resumeAfter, pendingDirectory: options.pendingDirectory)
        let cutoff = min(options.now.addingTimeInterval(-86_400), options.sessionStartedAt)
        let root = suppliedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = path(root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .creationDateKey, .contentModificationDateKey]
        func outOfTime() -> Bool {
            cancelled() || result.inspectedEntries >= max(0, options.maximumEntries)
                || uptime() - started >= max(0, options.maximumDuration)
        }
        guard options.maximumEntries > 0, options.maximumDuration > 0,
              (try? suppliedRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let enumeration = manager.enumerator(at: root, includingPropertiesForKeys: nil,
                  options: [.skipsSubdirectoryDescendants]) else { return result }
        var protected = options.protectedPaths
        // Reopened Blob leases were captured on the main actor; open descriptors
        // are inspected only in our process, without reading any file contents.
        for fd in 0..<getdtablesize() {
            if fd % 128 == 0, outOfTime() { return result }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buffer) == 0 { protected.insert(path(URL(fileURLWithPath: String(cString: buffer)))) }
        }
        func isProtected(_ value: String) -> Bool {
            protected.contains { $0 == value || $0.hasPrefix(value + "/") }
        }
        func walk(_ directory: URL, depth: Int = 0) -> Bool {
            // Keep pathological directory trees rather than grow the stack.
            guard depth < 32 else { return true }
            guard !outOfTime(), !isProtected(path(directory)),
                  let info = try? directory.resourceValues(forKeys: keys), info.isDirectory == true,
                  info.isSymbolicLink != true, let created = info.creationDate, created < cutoff,
                  let children = manager.enumerator(at: directory, includingPropertiesForKeys: nil,
                      options: [.skipsSubdirectoryDescendants]) else { return !outOfTime() }
            while let file = children.nextObject() as? URL {
                guard !outOfTime() else { return false }
                result.inspectedEntries += 1
                let filePath = path(file)
                guard filePath.hasPrefix(rootPath + "/"), !isProtected(filePath),
                      let values = try? file.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if !walk(file, depth: depth + 1) { return false }
                } else if values.isRegularFile == true {
                    let name = file.lastPathComponent.lowercased()
                    guard !["sqlite", "sqlite3", "db", "mdb"].contains(file.pathExtension.lowercased()),
                          !name.hasSuffix("-wal"), !name.hasSuffix("-shm"), !name.hasSuffix("-journal"),
                          let birth = values.creationDate, birth < cutoff,
                          let changed = values.contentModificationDate, changed < cutoff else { continue }
                    guard !outOfTime() else { return false }
                    do { try manager.removeItem(at: file); result.removedFiles += 1 } catch { }
                }
            }
            // Atomic empty-directory removal cannot swallow a concurrent write.
            if !outOfTime() { _ = directory.path.withCString { rmdir($0) } }
            return !outOfTime()
        }
        if let pending = options.pendingDirectory, ownsDirectory(pending) {
            if !walk(root.appendingPathComponent(pending, isDirectory: true)) { return result }
            result.pendingDirectory = nil
        }
        var passedCursor = options.resumeAfter == nil
        while let child = enumeration.nextObject() as? URL {
            guard !outOfTime() else { return result }
            let name = child.lastPathComponent
            if !passedCursor {
                if name == options.resumeAfter { passedCursor = true }
                continue
            }
            result.inspectedEntries += 1
            result.resumeAfter = name
            guard ownsDirectory(name) else { continue }
            if !walk(child) { result.pendingDirectory = name; return result }
        }
        if passedCursor { result.completed = true; result.resumeAfter = nil; result.pendingDirectory = nil }
        else { result.resumeAfter = nil }
        return result
    }
}
