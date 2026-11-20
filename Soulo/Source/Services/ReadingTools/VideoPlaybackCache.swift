import AVFoundation
import Foundation

/// Playback owns the lease. Cleanup can remove abandoned directories after an
/// app exit, while a minimized or fullscreen decoder keeps its files leased.
final class VideoPlaybackCacheDirectory: @unchecked Sendable {
    static let name = "SouloVideoPlayback"
    private static let freeSpaceReserve: Int64 = 128 * 1024 * 1024
    private static let storage = Storage()
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var active: [String: Int64] = [:]
    }

    let url: URL
    private var path: String { url.standardizedFileURL.path }

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    }

    init(reserving bytes: Int64) throws {
        let root = Self.root
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.storage.lock.withLock {
            let fm = FileManager.default
            guard bytes >= 0, bytes <= Self.availableForNewCacheBytes() else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ReadingToolError.unsafePath }
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            Self.storage.active[path] = bytes
        }
    }

    // The lock protects reservations for files that are filling concurrently.
    // Written bytes are already reflected in the volume's free-space reading.
    private static func availableForNewCacheBytes() -> Int64 {
        let values = try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free >= freeSpaceReserve else { return -1 }
        return free - freeSpaceReserve - storage.active.values.reduce(0, +)
    }

    var hasHeadroom: Bool { Self.storage.lock.withLock { Self.availableForNewCacheBytes() >= 0 } }

    func didWriteReservedBytes(_ bytes: Int64) {
        Self.storage.lock.withLock {
            if let remaining = Self.storage.active[path] { Self.storage.active[path] = max(0, remaining - bytes) }
        }
    }

    func releaseUnusedReservation() {
        Self.storage.lock.withLock { Self.storage.active[path] = 0 }
    }

    deinit {
        let url = url
        DispatchQueue.global(qos: .utility).async {
            Self.storage.lock.withLock {
                try? FileManager.default.removeItem(at: url)
                Self.storage.active.removeValue(forKey: url.standardizedFileURL.path)
            }
        }
    }

    static func clearUnused() throws -> StorageCleanupReport {
        try storage.lock.withLock {
            let root = root, fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return .init() }
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ReadingToolError.unsafePath }
            var report = StorageCleanupReport()
            for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
                if storage.active[entry.standardizedFileURL.path] != nil {
                    report.retainedCategories.insert(.videoPlaybackCache)
                } else {
                    do { try fm.removeItem(at: entry) }
                    catch { report.failures.append(error.localizedDescription) }
                }
            }
            return report
        }
    }
}

/// Validate the range before receiving a body. A server that ignores Range
/// must not launch an unbounded download or fill memory with the whole video.
final class VideoRangeLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Info {
        let length: Int64
        let byteCount: Int
        let mimeType: String?
        let version: String?
    }
    private struct Request {
        let range: Range<Int64>
        let result: CheckedContinuation<(Data, Info), Error>
        var bytes = Data()
        var info: Info?
    }

    private let lock = NSLock()
    private let context: VideoPlaybackRequestContext
    private var requests: [Int: Request] = [:]
    private var session: URLSession?

    init(context: VideoPlaybackRequestContext) {
        self.context = context
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func stop() {
        let activeSession = lock.withLock {
            let activeSession = session
            session = nil
            return activeSession
        }
        activeSession?.invalidateAndCancel()
    }

    func read(_ range: Range<Int64>, probing: Bool = false) async throws -> (Data, Info) {
        var ranged = await context.resourceRequest(for: context.url, referrer: context.referrer ?? context.url)
        ranged.timeoutInterval = probing ? 4 : 15
        ranged.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        ranged.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        try Task.checkCancellation()
        // Foundation raises an Objective-C exception if task creation races
        // with session invalidation. Retire the session under the same lock.
        guard let task = lock.withLock({ session?.dataTask(with: ranged) }) else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let started = lock.withLock {
                    guard session != nil, !Task.isCancelled else { return false }
                    requests[task.taskIdentifier] = Request(range: range, result: continuation)
                    task.resume()
                    return true
                }
                if !started { task.cancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock {
            guard let request = requests[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
                  http.statusCode == 206, (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity",
                  let header = http.value(forHTTPHeaderField: "Content-Range") else { return false }
            let prefix = "bytes \(request.range.lowerBound)-"
            guard header.hasPrefix(prefix) else { return false }
            let bounds = header.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard bounds.count == 2, let last = Int64(bounds[0]), let total = Int64(bounds[1]),
                  last >= request.range.lowerBound, last < request.range.upperBound, last < total else { return false }
            let count = Int(last - request.range.lowerBound + 1)
            requests[dataTask.taskIdentifier]?.info = Info(length: total, byteCount: count, mimeType: http.mimeType?.lowercased(),
                version: http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified"))
            return true
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let keep = lock.withLock {
            guard let request = requests[dataTask.taskIdentifier], let info = request.info,
                  data.count <= info.byteCount - request.bytes.count else { return false }
            requests[dataTask.taskIdentifier]?.bytes.append(data)
            return true
        }
        if !keep { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = lock.withLock({ requests.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { request.result.resume(throwing: error) }
        else if let info = request.info, request.bytes.count == info.byteCount { request.result.resume(returning: (request.bytes, info)) }
        else { request.result.resume(throwing: URLError(.networkConnectionLost)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = newRequest.url, VideoLoadingStatus.isOnline(target), let original = task.originalRequest else {
            completionHandler(nil); return
        }
        Task { @MainActor in
            var scoped = context.resourceRequest(for: target, referrer: context.referrer ?? context.url)
            scoped.timeoutInterval = original.timeoutInterval
            scoped.setValue(original.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
            scoped.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            completionHandler(scoped)
        }
    }
}

/// Direct files play through the same range cache that fills in the background.
/// Only verified ranges are read from the sparse file.
private actor ProgressiveVideoCache {
    private static let chunkSize: Int64 = 512 * 1024
    let total: Int64
    let transfer = VideoPlaybackTransfer()
    private let directory: VideoPlaybackCacheDirectory
    private let network: VideoRangeLoader
    private let file: FileHandle
    private let version: String?
    private var cached: Set<Int64> = []
    private var cachedByteCount: Int64 = 0
    private var pending: [Int64: Task<Data, Error>] = [:]
    private var prefetch: Task<Void, Never>?
    private var stopped = false
    private var canFillCache = true
    private var streamedChunk: (index: Int64, bytes: Data)?

    init(total: Int64, version: String?, network: VideoRangeLoader) throws {
        self.total = total; self.version = version; self.network = network
        directory = try VideoPlaybackCacheDirectory(reserving: total)
        let url = directory.url.appendingPathComponent("media")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forUpdating: url)
    }

    deinit { network.stop(); try? file.close() }

    private var chunkCount: Int64 { (total - 1) / Self.chunkSize + 1 }

    func read(offset: Int64, count: Int) async throws -> Data {
        let index = offset / Self.chunkSize
        let data = try await chunk(index)
        if prefetch == nil, !stopped, canFillCache, cached.count < chunkCount {
            prefetch = Task(priority: .utility) { [weak self] in await self?.fill() }
        }
        let start = Int(offset % Self.chunkSize)
        return data.subdata(in: start..<min(data.count, start + count))
    }

    private func fill() async {
        defer { prefetch = nil }
        do {
            for index in 0..<chunkCount where !cached.contains(index) {
                guard canFillCache else { return }
                try await Task.sleep(for: .milliseconds(120))
                _ = try await chunk(index)
            }
        } catch { /* Playback requests can still retry their own range. */ }
    }

    private func chunk(_ index: Int64) async throws -> Data {
        guard !stopped else { throw CancellationError() }
        if let streamedChunk, streamedChunk.index == index { return streamedChunk.bytes }
        let offset = index * Self.chunkSize
        let count = Int(min(Self.chunkSize, total - offset))
        if cached.contains(index) {
            try file.seek(toOffset: UInt64(offset))
            if let data = try file.read(upToCount: count), data.count == count { return data }
            cached.remove(index)
            cachedByteCount -= Int64(count)
            transfer.setCachedBytes(cachedByteCount, total: total)
        }
        if let task = pending[index] { return try await task.value }
        let task = Task { try await fetch(index, offset: offset, count: count) }
        pending[index] = task
        defer { pending[index] = nil }
        return try await task.value
    }

    private func fetch(_ index: Int64, offset: Int64, count: Int) async throws -> Data {
        let end = offset + Int64(count)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var bytes = Data()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            guard started < deadline else { throw URLError(.timedOut) }
            let (part, info) = try await network.read((offset + Int64(bytes.count))..<end)
            guard !stopped, info.length == total, version == nil || info.version == version,
                  info.mimeType != "text/html", info.mimeType != "application/json" else { throw URLError(.badServerResponse) }
            transfer.record(bytes: Int64(part.count), started: started, finished: .now)
            bytes.append(part)
        }
        // A system purge or disk error must not turn successfully received media
        // into a playback error. Retain just the latest streamed chunk so
        // the player's smaller reads don't repeatedly request it from the origin.
        guard canFillCache else { streamedChunk = (index, bytes); return bytes }
        do {
            guard directory.hasHeadroom else { throw CocoaError(.fileWriteOutOfSpace) }
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: bytes)
            cached.insert(index)
            cachedByteCount += Int64(bytes.count)
            directory.didWriteReservedBytes(Int64(bytes.count))
            transfer.setCachedBytes(cachedByteCount, total: total)
        } catch {
            canFillCache = false
            streamedChunk = (index, bytes)
            directory.releaseUnusedReservation()
        }
        return bytes
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        directory.releaseUnusedReservation()
        prefetch?.cancel(); pending.values.forEach { $0.cancel() }
        network.stop()
    }
}

@MainActor enum ProgressiveVideoPlaybackBridge {
    private static var key: UInt8 = 0
    private static var downloadKey: UInt8 = 0
    private final class Lease: Sendable {
        let cache: ProgressiveVideoCache
        let server: TorrentStreamServer
        init(cache: ProgressiveVideoCache, server: TorrentStreamServer) { self.cache = cache; self.server = server }
        deinit { server.stop(); let cache = cache; Task { await cache.stop() } }
    }

    static func transfer(for asset: AVURLAsset) -> VideoPlaybackTransfer? {
        (objc_getAssociatedObject(asset, &key) as? Lease)?.cache.transfer
            ?? objc_getAssociatedObject(asset, &downloadKey) as? VideoPlaybackTransfer
    }

    static func associateDownloadTransfer(_ transfer: VideoPlaybackTransfer, with asset: AVURLAsset) {
        objc_setAssociatedObject(asset, &downloadKey, transfer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func asset(for resource: WebMediaResource, context: VideoPlaybackRequestContext) async -> AVURLAsset? {
        guard resource.kind == .video, resource.delivery == .direct, VideoLoadingStatus.isOnline(resource.url) else { return nil }
        let network = VideoRangeLoader(context: context)
        do {
            let (_, info) = try await network.read(0..<1, probing: true)
            let fileExtension: String
            switch info.mimeType {
            case "video/mp4", "application/mp4": fileExtension = "mp4"
            case "video/quicktime": fileExtension = "mov"
            case "video/x-matroska", "video/matroska": fileExtension = "mkv"
            case "video/webm": fileExtension = "webm"
            case "video/x-msvideo": fileExtension = "avi"
            case "video/x-flv": fileExtension = "flv"
            case "video/x-ms-wmv": fileExtension = "wmv"
            case "application/octet-stream", nil:
                fileExtension = resource.url.pathExtension.lowercased()
                guard TorrentMediaFile.extensions.contains(fileExtension),
                      FilePresentation.kind(forFileExtension: fileExtension) == .video else {
                    throw URLError(.unsupportedURL)
                }
            default: throw URLError(.unsupportedURL)
            }
            try Task.checkCancellation()
            let cache = try ProgressiveVideoCache(total: info.length, version: info.version, network: network)
            let server = try await TorrentStreamServer.start(size: info.length, name: "video." + fileExtension) { [weak cache] offset, count in
                guard let cache else { throw CancellationError() }
                return try await cache.read(offset: offset, count: count)
            }
            let asset = AVURLAsset(url: server.url)
            objc_setAssociatedObject(asset, &key, Lease(cache: cache, server: server), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return asset
        } catch {
            network.stop()
            return nil
        }
    }
}
