import Foundation

@MainActor
final class DownloadManagerService: ObservableObject {
    static let shared = DownloadManagerService()

    @Published private(set) var downloads: [BrowserDownloadItem] = []

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let storageDirectory: URL

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "soulo_browser_downloads",
        storageDirectory: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.storageDirectory = storageDirectory ?? Self.downloadsDirectory
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        load()
    }

    func beginDownload(suggestedFilename: String, sourceURL: URL?) -> (BrowserDownloadItem, URL) {
        let fileName = uniqueFilename(for: sanitizedFilename(suggestedFilename))
        let destination = storageDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)

        let item = BrowserDownloadItem(
            id: UUID(),
            fileName: fileName,
            sourceURLString: sourceURL?.absoluteString ?? "",
            localPath: destination.path,
            startedAt: Date(),
            completedAt: nil,
            status: .inProgress,
            errorMessage: ""
        )
        downloads.insert(item, at: 0)
        save()
        return (item, destination)
    }

    func markFinished(id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].status == .inProgress else { return }
        downloads[index].status = .finished
        downloads[index].completedAt = Date()
        downloads[index].errorMessage = ""
        save()
    }

    func markFailed(id: UUID, error: Error) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].status == .inProgress else { return }
        downloads[index].status = .failed
        downloads[index].completedAt = Date()
        downloads[index].errorMessage = error.localizedDescription
        try? FileManager.default.removeItem(at: downloads[index].localURL)
        save()
    }

    func markCanceled(id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }),
              downloads[index].status == .inProgress else { return }
        downloads[index].status = .canceled
        downloads[index].completedAt = Date()
        downloads[index].errorMessage = ""
        try? FileManager.default.removeItem(at: downloads[index].localURL)
        save()
    }

    func cancelAllDownloads() {
        var changed = false
        for index in downloads.indices where downloads[index].status == .inProgress {
            downloads[index].status = .canceled
            downloads[index].completedAt = Date()
            downloads[index].errorMessage = ""
            try? FileManager.default.removeItem(at: downloads[index].localURL)
            changed = true
        }
        if changed {
            save()
        }
    }

    func delete(_ item: BrowserDownloadItem) {
        guard item.status != .inProgress else { return }
        try? FileManager.default.removeItem(at: item.localURL)
        downloads.removeAll { $0.id == item.id }
        save()
    }

    func clearFinished() {
        let finished = downloads.filter { $0.status != .inProgress }
        finished.forEach { try? FileManager.default.removeItem(at: $0.localURL) }
        downloads.removeAll { $0.status != .inProgress }
        save()
    }

    func removeMissingFiles() {
        downloads.removeAll { item in
            item.status == .finished && !FileManager.default.fileExists(atPath: item.localPath)
        }
        save()
    }

    private func uniqueFilename(for filename: String) -> String {
        let nsName = filename as NSString
        let base = nsName.deletingPathExtension.isEmpty ? "Download" : nsName.deletingPathExtension
        let ext = nsName.pathExtension
        let reservedNames = Set(
            downloads
                .filter { $0.status == .inProgress }
                .map(\.fileName)
        )

        var candidate = filename
        var counter = 1
        while reservedNames.contains(candidate)
            || FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Download" : trimmed
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return fallback.components(separatedBy: invalid).joined(separator: "-")
    }

    private func load() {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([BrowserDownloadItem].self, from: data) {
            downloads = decoded
        }
        var restoredInterruptedDownload = false
        for index in downloads.indices where downloads[index].status == .inProgress {
            downloads[index].status = .canceled
            downloads[index].completedAt = Date()
            downloads[index].errorMessage = ""
            try? FileManager.default.removeItem(at: downloads[index].localURL)
            restoredInterruptedDownload = true
        }
        if restoredInterruptedDownload {
            save()
        }
        removeMissingFiles()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(downloads) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    static var downloadsDirectory: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
