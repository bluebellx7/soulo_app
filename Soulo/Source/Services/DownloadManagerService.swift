import Foundation

enum DownloadFilenameSanitizer {
    static let maximumUTF8ByteCount = 180

    static func sanitize(
        _ filename: String,
        fallbackBaseName: String = "Download",
        preferredExtension: String? = nil
    ) -> String {
        let decoded = decodePercentEncoding(filename)
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nsFilename = decoded as NSString
        let originalExtension = safeExtension(nsFilename.pathExtension)
        let fileExtension = originalExtension ?? safeExtension(preferredExtension ?? "")

        var baseName = safeBaseName(nsFilename.deletingPathExtension)
        if baseName.isEmpty {
            baseName = safeBaseName(fallbackBaseName)
        }
        if baseName.isEmpty {
            baseName = "Download"
        }

        let suffix = fileExtension.map { ".\($0)" } ?? ""
        let byteBudget = max(1, maximumUTF8ByteCount - suffix.utf8.count)
        baseName = prefix(baseName, fittingUTF8ByteCount: byteBudget)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".-_")
            ))
        if baseName.isEmpty {
            baseName = "Download"
        }
        return baseName + suffix
    }

    private static func decodePercentEncoding(_ value: String) -> String {
        var result = value
        for _ in 0..<2 {
            guard let decoded = result.removingPercentEncoding, decoded != result else { break }
            result = decoded
        }
        return result
    }

    private static func safeBaseName(_ value: String) -> String {
        let allowedPunctuation = Set<Character>(["-", "_", "(", ")", "[", "]"])
        var result = ""
        for character in value {
            let scalars = character.unicodeScalars
            if scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                result.append(character)
            } else if allowedPunctuation.contains(character) {
                result.append(character)
            } else if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                result.append(" ")
            } else {
                result.append("-")
            }
        }

        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".-_")
        ))
    }

    private static func safeExtension(_ value: String) -> String? {
        let extensionValue = value.lowercased()
        guard (1...12).contains(extensionValue.count),
              extensionValue.unicodeScalars.allSatisfy({ scalar in
                  (97...122).contains(scalar.value)
                      || (48...57).contains(scalar.value)
              }) else {
            return nil
        }
        return extensionValue
    }

    private static func prefix(_ value: String, fittingUTF8ByteCount limit: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= limit else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}

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
        let fileName = uniqueFilename(for: DownloadFilenameSanitizer.sanitize(suggestedFilename))
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
