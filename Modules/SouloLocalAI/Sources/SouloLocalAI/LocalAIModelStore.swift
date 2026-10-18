import Foundation
import Combine
import CryptoKit

public enum LocalAIModelSource: String, CaseIterable, Sendable {
    case huggingFace, modelScope
    public var title: String { self == .huggingFace ? "Hugging Face" : "ModelScope" }
    public static var preferred: LocalAIModelSource { AIL10n.language.hasPrefix("zh") ? .modelScope : .huggingFace }
}

public struct LocalAIModelAsset: Identifiable, Sendable, Decodable {
    public enum Kind: String, Decodable, Sendable { case gguf, expert, manifest }
    public let id: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL
    public let kind: Kind
    public init(id: String, filename: String, bytes: Int64, sha256: String, url: URL, kind: Kind = .gguf) {
        self.id = id; self.filename = filename; self.bytes = bytes; self.sha256 = sha256; self.url = url; self.kind = kind
    }
    static let revision = "9684c734cfb2e6aaccb0bb52ba58afa9aae92d90"
    public static let language = LocalAIModelAsset(id: "minicpm-v47-1b", filename: "MiniCPM-V-4_7-1B-Q4_K_M.gguf",
        bytes: 672_003_680, sha256: "588c6c94c82f756b86dba35c42ed9ba9ec187d65824eb52f039c347df563e63d",
        url: URL(string: "https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/resolve/\(revision)/MiniCPM-V-4_7-1B-Q4_K_M.gguf?download=true")!)
    public static let vision = LocalAIModelAsset(id: "minicpm-v47-vision", filename: "mmproj-model-f16.gguf",
        bytes: 1_110_117_984, sha256: "fb9cc047a3cdad5317fd8433a4aeda2d22f00f02ca4bd93b34ad84165b25a900",
        url: URL(string: "https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf/resolve/\(revision)/mmproj-model-f16.gguf?download=true")!)
    static let enhancedAssets: [LocalAIModelAsset] = {
        struct Catalog: Decodable { let files: [LocalAIModelAsset] }
        guard let url = Bundle.module.url(forResource: "Models35B", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.files
    }()
    public static var catalog: [LocalAIModelAsset] { [language, vision] + enhancedAssets }
    func downloadURL(source: LocalAIModelSource) -> URL {
        guard source == .modelScope, url.host == "huggingface.co" else { return url }
        if filename.hasPrefix("35B-A3B/") {
            return URL(string: "https://www.modelscope.cn/models/zerg13/MiniCPM-V-Apps-gguf/resolve/master/MiniCPM-V-4.7-35B-A3B/" + filename.dropFirst("35B-A3B/".count))!
        }
        return URL(string: "https://modelscope.cn/models/OpenBMB/MiniCPM-V-4.7-1B-gguf/resolve/master/\(filename)")!
    }
}

public enum LocalAIAssetStatus: Equatable {
    case missing, downloading(received: Int64, total: Int64), paused, verifying, installed, failed(String)
    public var isWorking: Bool {
        switch self { case .downloading, .verifying: true; default: false }
    }
}

private enum DownloadEvent: Sendable {
    case progress(String, Int, Int64, Int64), completed(String, Int?, URL, Int), failed(String, Int, String, Data?), waiting(String, Int), finishedEvents
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let directory: URL
    var receive: (@Sendable (DownloadEvent) -> Void)?
    init(directory: URL) { self.directory = directory }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        receive?(.progress(id, downloadTask.taskIdentifier, totalBytesWritten, totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let staged = directory.appendingPathComponent(id + "." + UUID().uuidString + ".download")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            try Data(staged.lastPathComponent.utf8).write(to: directory.appendingPathComponent(id + ".pending"), options: .atomic)
            receive?(.completed(id, downloadTask.taskIdentifier, staged, (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0))
        } catch {
            try? FileManager.default.removeItem(at: staged)
            receive?(.failed(id, downloadTask.taskIdentifier, error.localizedDescription, nil))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError?, let id = task.taskDescription, error.code != NSURLErrorCancelled else { return }
        receive?(.failed(id, task.taskIdentifier, error.localizedDescription, error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data))
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { receive?(.finishedEvents) }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let id = task.taskDescription else { return }
        receive?(.waiting(id, task.taskIdentifier))
    }
}

/// A separate, excluded-from-backup directory contains all model files and resume
/// data. Files become available only after size, GGUF header and SHA-256 checks.
@MainActor public final class LocalAIModelStore: ObservableObject {
    public static let shared = LocalAIModelStore()
    public static var sessionIdentifier: String { (Bundle.main.bundleIdentifier ?? "com.dkluge.Soulo") + ".local-ai.models" }
    @Published public private(set) var statuses: [String: LocalAIAssetStatus] = [:]
    @Published public var error: String?
    @Published public private(set) var waitingForConnectivity = Set<String>()
    @Published public private(set) var cellularDownloads = Set<String>()
    @Published public internal(set) var selectedProfile = LocalAIModelProfile(rawValue: UserDefaults.standard.string(forKey: "soulo.localAI.model") ?? "") ?? .light
    public var backgroundCompletion: (() -> Void)? { didSet { finishBackgroundEventsIfReady() } }
    public let assets: [LocalAIModelAsset]
    let directory: URL
    private let delegate: ModelDownloadDelegate
    private let configuration: URLSessionConfiguration
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var operations: [String: UUID] = [:]
    private var lastProgress: [String: Date] = [:]
    private var verifying = 0
    private var finishedBackgroundEvents = false
    private lazy var session: URLSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

    public convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SouloLocalAI/Models", isDirectory: true)
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        #else
        let config = URLSessionConfiguration.default
        #endif
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 24 * 60 * 60
        // Each request opts in separately, after the download UI obtains consent.
        config.allowsCellularAccess = true; config.waitsForConnectivity = true
        self.init(directory: directory, assets: LocalAIModelAsset.catalog, configuration: config)
    }

    init(directory: URL, assets: [LocalAIModelAsset], configuration: URLSessionConfiguration) {
        self.directory = directory; self.assets = assets; self.configuration = configuration
        configuration.httpMaximumConnectionsPerHost = 2
        self.delegate = ModelDownloadDelegate(directory: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        // A process can exit between staging a completed transfer/import and
        // writing its sidecar. Recover complete files; discard only our own
        // incomplete UUID-named staging files so they cannot consume GB forever.
        let stagedFiles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var referenced = Set(assets.compactMap { try? String(contentsOf: directory.appendingPathComponent($0.id + ".pending"), encoding: .utf8) })
        for file in stagedFiles where file.pathExtension == "download" && !referenced.contains(file.lastPathComponent) {
            let stem = file.deletingPathExtension().lastPathComponent
            let suffix = String(stem.suffix(36))
            guard UUID(uuidString: suffix) != nil else { continue }
            let recoveredID = stem.count > 37 ? String(stem.dropLast(37)) : nil
            let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let candidates = assets.filter { Int($0.bytes) == size && !Self.hasVerifiedFile($0, directory: directory)
                && !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.id + ".pending").path) }
            let matched = recoveredID.flatMap { id in candidates.first { $0.id == id } } ?? (recoveredID == nil && candidates.count == 1 ? candidates.first : nil)
            if let asset = matched,
               (try? Data(file.lastPathComponent.utf8).write(to: directory.appendingPathComponent(asset.id + ".pending"), options: .atomic)) != nil {
                referenced.insert(file.lastPathComponent)
            } else { try? FileManager.default.removeItem(at: file) }
        }
        for asset in assets {
            if (try? String(contentsOf: directory.appendingPathComponent(asset.id + ".network"), encoding: .utf8)) == "cellular" { cellularDownloads.insert(asset.id) }
            statuses[asset.id] = Self.hasVerifiedFile(asset, directory: directory) ? .installed
                : (FileManager.default.fileExists(atPath: resumeURL(asset.id).path) ? .paused : .missing)
        }
        delegate.receive = { [weak self] event in Task { @MainActor in await self?.receive(event) } }
        // Recover files whose transfer completed just before the process exited.
        // A completed 1 GB transfer must not be repeated merely because its
        // verification had not yet produced a marker.
        for asset in assets where statuses[asset.id] != .installed {
            let pending = directory.appendingPathComponent(asset.id + ".pending")
            let stagedName = try? String(contentsOf: pending, encoding: .utf8)
            let staged = stagedName.flatMap { name -> URL? in
                guard name == (name as NSString).lastPathComponent, name.hasSuffix(".download") else { return nil }
                let url = directory.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            let target = directory.appendingPathComponent(asset.filename)
            let unverified = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(asset.bytes) ? target : nil
            if let candidate = staged ?? unverified {
                let operation = UUID(); operations[asset.id] = operation
                statuses[asset.id] = .verifying
                Task { [weak self] in
                    guard let self, self.operations[asset.id] == operation else { return }
                    await self.receive(.completed(asset.id, nil, candidate, 200))
                }
            }
        }
    }

    public func reconnectBackgroundDownloads() {
        session.getAllTasks { [weak self] existing in
            Task { @MainActor in
                guard let self else { return }
                for case let task as URLSessionDownloadTask in existing {
                    guard let id = task.taskDescription, self.assets.contains(where: { $0.id == id }) else { task.cancel(); continue }
                    guard task.state == .running || task.state == .suspended else { continue }
                    guard self.statuses[id] != .verifying, self.statuses[id] != .installed else { task.cancel(); continue }
                    if let current = self.tasks[id], current.taskIdentifier != task.taskIdentifier { task.cancel(); continue }
                    self.tasks[id] = task
                    self.statuses[id] = .downloading(received: task.countOfBytesReceived, total: task.countOfBytesExpectedToReceive)
                }
            }
        }
    }

    public func installedURL(for asset: LocalAIModelAsset) -> URL? {
        guard statuses[asset.id] == .installed else { return nil }
        let url = directory.appendingPathComponent(asset.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    public func hasLocalData(for asset: LocalAIModelAsset) -> Bool {
        [directory.appendingPathComponent(asset.filename), resumeURL(asset.id), directory.appendingPathComponent(asset.id + ".pending")]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func hasResumeData(for asset: LocalAIModelAsset) -> Bool { FileManager.default.fileExists(atPath: resumeURL(asset.id).path) }
    func activeRequest(for asset: LocalAIModelAsset) -> URLRequest? { tasks[asset.id]?.originalRequest }
    public func resumeAllowsCellular(for asset: LocalAIModelAsset) -> Bool { hasResumeData(for: asset) && cellularDownloads.contains(asset.id) }
    public func download(_ asset: LocalAIModelAsset, source: LocalAIModelSource = .huggingFace, allowsCellular: Bool = false) {
        guard tasks[asset.id] == nil, statuses[asset.id]?.isWorking != true, statuses[asset.id] != .installed else { return }
        do {
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let free, free < asset.bytes + 150_000_000 { throw CocoaError(.fileWriteOutOfSpace) }
            operations[asset.id] = UUID()
            let sourceFile = directory.appendingPathComponent(asset.id + ".source")
            if (try? String(contentsOf: sourceFile, encoding: .utf8)) != source.rawValue || cellularDownloads.contains(asset.id) != allowsCellular {
                // System resume data retains the original request's network policy.
                // A change is explicitly disclosed by the download confirmation.
                try? FileManager.default.removeItem(at: resumeURL(asset.id))
            }
            try Data(source.rawValue.utf8).write(to: sourceFile, options: .atomic)
            try Data((allowsCellular ? "cellular" : "wifi").utf8).write(to: directory.appendingPathComponent(asset.id + ".network"), options: .atomic)
            if allowsCellular { cellularDownloads.insert(asset.id) } else { cellularDownloads.remove(asset.id) }
            waitingForConnectivity.remove(asset.id)
            let task: URLSessionDownloadTask
            if let resume = try? Data(contentsOf: resumeURL(asset.id)), !resume.isEmpty {
                task = session.downloadTask(withResumeData: resume)
            } else {
                var request = URLRequest(url: asset.downloadURL(source: source))
                request.allowsCellularAccess = allowsCellular
                request.allowsExpensiveNetworkAccess = allowsCellular
                task = session.downloadTask(with: request)
            }
            tasks[asset.id] = task; task.taskDescription = asset.id
            statuses[asset.id] = .downloading(received: 0, total: asset.bytes)
            task.resume()
        } catch { statuses[asset.id] = .failed(error.localizedDescription) }
    }

    public func pause(_ asset: LocalAIModelAsset) {
        guard let task = tasks.removeValue(forKey: asset.id) else { return }
        let operation = operations[asset.id]
        statuses[asset.id] = .paused
        waitingForConnectivity.remove(asset.id)
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self, self.operations[asset.id] == operation, self.statuses[asset.id] == .paused else { return }
                if let data { try? data.write(to: self.resumeURL(asset.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            }
        }
    }

    public func delete(_ asset: LocalAIModelAsset) async {
        operations[asset.id] = UUID()
        tasks.removeValue(forKey: asset.id)?.cancel()
        // Never unlink weights that a running Metal request is still using.
        LocalAIRuntime.shared.stop()
        await LocalAIEngine.shared.unload()
        let pending = directory.appendingPathComponent(asset.id + ".pending")
        if let name = try? String(contentsOf: pending, encoding: .utf8), name == (name as NSString).lastPathComponent, name.hasSuffix(".download") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        for url in [directory.appendingPathComponent(asset.filename), markerURL(asset.id), resumeURL(asset.id), directory.appendingPathComponent(asset.id + ".source"), directory.appendingPathComponent(asset.id + ".network"), directory.appendingPathComponent(asset.id + ".pending")] {
            try? FileManager.default.removeItem(at: url)
        }
        statuses[asset.id] = .missing
        cellularDownloads.remove(asset.id); waitingForConnectivity.remove(asset.id)
    }

    public func importFile(_ source: URL) async throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard let asset = assets.first(where: { $0.kind == .gguf && $0.bytes == Int64(size) }) else { throw LocalAIError.modelInvalid }
        guard statuses[asset.id]?.isWorking != true else { throw LocalAIError.busy }
        let operation = UUID(); operations[asset.id] = operation
        let staged = directory.appendingPathComponent(asset.id + "." + UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: source, to: staged) }.value
        guard operations[asset.id] == operation else {
            try? FileManager.default.removeItem(at: staged); throw CancellationError()
        }
        await receive(.completed(asset.id, nil, staged, 200))
        guard statuses[asset.id] == .installed else {
            if Self.hasVerifiedFile(asset, directory: directory) { statuses[asset.id] = .installed }
            throw LocalAIError.modelInvalid
        }
    }

    private func receive(_ event: DownloadEvent) async {
        switch event {
        case let .progress(id, taskID, bytes, expected):
            guard tasks[id]?.taskIdentifier == taskID, let asset = assets.first(where: { $0.id == id }) else { return }
            guard bytes <= asset.bytes, expected <= asset.bytes else {
                tasks.removeValue(forKey: id)?.cancel()
                operations[id] = UUID(); waitingForConnectivity.remove(id)
                try? FileManager.default.removeItem(at: resumeURL(id))
                statuses[id] = .failed(LocalAIError.modelInvalid.localizedDescription)
                return
            }
            guard Date().timeIntervalSince(lastProgress[id] ?? .distantPast) > 0.15 else { return }
            waitingForConnectivity.remove(id)
            lastProgress[id] = Date(); statuses[id] = .downloading(received: bytes, total: expected)
        case let .waiting(id, taskID):
            guard tasks[id]?.taskIdentifier == taskID else { return }
            waitingForConnectivity.insert(id)
        case let .completed(id, taskID, staged, statusCode):
            defer {
                if staged.pathExtension == "download" { try? FileManager.default.removeItem(at: staged) }
                let pending = directory.appendingPathComponent(id + ".pending")
                if (try? String(contentsOf: pending, encoding: .utf8)) == staged.lastPathComponent { try? FileManager.default.removeItem(at: pending) }
            }
            guard let asset = assets.first(where: { $0.id == id }) else { return }
            if let taskID, tasks[id]?.taskIdentifier != taskID, operations[id] != nil { return }
            tasks[id] = nil
            waitingForConnectivity.remove(id)
            let operation = operations[id] ?? UUID(); operations[id] = operation
            statuses[id] = .verifying; verifying += 1
            defer { verifying -= 1; finishBackgroundEventsIfReady() }
            do {
                guard [200, 206].contains(statusCode) else { throw URLError(.badServerResponse) }
                try await Task.detached(priority: .utility) { try Self.verify(staged, asset: asset) }.value
                guard operations[id] == operation else { return }
                let target = directory.appendingPathComponent(asset.filename)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if target == staged {
                    // A previous process moved the file but had not written its marker.
                } else if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
                } else { try FileManager.default.moveItem(at: staged, to: target) }
                try Data(asset.sha256.utf8).write(to: markerURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try? FileManager.default.removeItem(at: resumeURL(id))
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".network"))
                cellularDownloads.remove(id)
                statuses[id] = .installed
            } catch {
                guard operations[id] == operation else { return }
                statuses[id] = .failed(error.localizedDescription)
            }
        case let .failed(id, taskID, message, resume):
            guard tasks[id]?.taskIdentifier == taskID || operations[id] == nil else { return }
            tasks[id] = nil
            waitingForConnectivity.remove(id)
            if let resume { try? resume.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            statuses[id] = .failed(message)
        case .finishedEvents:
            finishedBackgroundEvents = true; finishBackgroundEventsIfReady()
        }
    }

    private func finishBackgroundEventsIfReady() {
        guard finishedBackgroundEvents, verifying == 0, let completion = backgroundCompletion else { return }
        backgroundCompletion = nil; finishedBackgroundEvents = false; completion()
    }
    private func markerURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".verified") }
    private func resumeURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".resume") }
    nonisolated private static func hasVerifiedFile(_ asset: LocalAIModelAsset, directory: URL) -> Bool {
        let file = directory.appendingPathComponent(asset.filename)
        return (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(asset.bytes)
            && (try? String(contentsOf: directory.appendingPathComponent(asset.id + ".verified"), encoding: .utf8)) == asset.sha256
    }
    nonisolated static func verify(_ url: URL, asset: LocalAIModelAsset) throws {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(asset.bytes) else { throw LocalAIError.modelInvalid }
        let stream = try FileHandle(forReadingFrom: url); defer { try? stream.close() }
        if asset.kind == .gguf, try stream.read(upToCount: 4) != Data("GGUF".utf8) { throw LocalAIError.modelInvalid }
        try stream.seek(toOffset: 0)
        var hash = SHA256()
        while let block = try stream.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw LocalAIError.modelInvalid }
    }
}
