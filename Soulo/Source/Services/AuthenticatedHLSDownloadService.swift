import AVFoundation
import Foundation
import UIKit
import WebKit

/// Authenticated HLS uses scoped HTTP requests when AVAssetDownloadURLSession
/// drops asset credentials. Bodies go directly to temporary files, never a
/// whole-video Blob. The public/background HLS path remains available.
@MainActor
final class AuthenticatedHLSDownloadService {
    static let shared = AuthenticatedHLSDownloadService()
    private struct Resource: Sendable {
        let url: URL
        let filename: String
        let range: String?
        let key: Bool
        let segment: Bool
    }
    private struct Plan {
        var resources: [Resource] = []
        var resourceNames: [String: String] = [:]
        var playlists: [String: Data] = [:]
        var primaryMedia = "index.m3u8"
        var convertible = true
        var keyCount = 0
        var visiting = Set<URL>()

        var primaryDuration: Double? {
            guard let playlist = playlists[primaryMedia] else { return nil }
            return HLSDownloadTimeline.duration(of: String(decoding: playlist, as: UTF8.self))
        }
    }
    private typealias Variant = (bandwidth: Int, url: URL, audioGroup: String?)
    private struct OriginThrottle {
        var nextRequest: ContinuousClock.Instant
        let expires: ContinuousClock.Instant
    }
    private struct OriginRateLimit: LocalizedError {
        var errorDescription: String? { HTTPURLResponse.localizedString(forStatusCode: 429) }
    }
    private final class Job {
        let id: UUID
        let context: VideoPlaybackRequestContext
        let directory: URL
        let preferredName: String
        let continuation: CheckedContinuation<URL, Error>
        var operation: Task<Void, Never>?
        var paused = false
        var canceled = false
        var resumeRequested = false
        var plan: Plan?
        var completed = Set<String>()
        var received: Int64 = 0
        var progress = Progress(totalUnitCount: 1000)
        var assertion: UIBackgroundTaskIdentifier = .invalid
        var resumeOnActivation = false
        init(id: UUID, context: VideoPlaybackRequestContext, directory: URL, preferredName: String,
             continuation: CheckedContinuation<URL, Error>) {
            self.id = id; self.context = context; self.directory = directory
            self.preferredName = preferredName; self.continuation = continuation
        }
    }
    private var jobs: [UUID: Job] = [:]
    private var originThrottles: [String: OriginThrottle] = [:]
    var activeIDs: Set<UUID> { Set(jobs.keys) }
    private let startup: Task<Void, Never>
    private let root: URL
    private let session: URLSession
    private var activationObserver: NSObjectProtocol?
    private init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SouloAuthenticatedHLS", isDirectory: true)
        self.root = root
        startup = Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
        activationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for job in Array(self.jobs.values) where job.resumeOnActivation {
                    job.resumeOnActivation = false; self.resume(job.id)
                }
            }
        }
    }
    func owns(_ id: UUID) -> Bool { jobs[id] != nil }
    func download(resource: WebMediaResource, preferredName: String, pageURL: URL?, webView: WKWebView, sourceURL: URL? = nil) async throws -> URL {
        let manager = DownloadManagerService.shared
        let sourceURL = sourceURL ?? resource.url
        let context = await VideoPlaybackRequestContext.load(url: resource.url,
            pageURL: resource.sourcePageURL ?? pageURL, webView: webView)
        guard manager.activeDownload(for: sourceURL) == nil else { throw StreamingMediaDownloadError.alreadyInProgress }
        let (item, _) = manager.beginDownload(suggestedFilename: preferredName, sourceURL: sourceURL, transport: .hls,
            hlsUsesPersistentCookies: webView.configuration.websiteDataStore.isPersistent)
        let options = await WebResourceMediaService.networkAssetOptions(for: resource, webView: webView)
        let playback = AVURLAsset(url: resource.url, options: options), descriptor = AVURLAsset(url: resource.url, options: options)
        let loader = HLSKeyResourceLoader(context: context)
        playback.resourceLoader.setDelegate(loader, queue: .main); descriptor.resourceLoader.setDelegate(loader, queue: .main)
        manager.registerPlaybackSource(id: item.id, asset: playback,
            pageURL: pageURL, webView: webView, downloadAsset: descriptor, resourceLease: loader)
        return try await withCheckedThrowingContinuation { continuation in
            adopt(id: item.id, context: context, preferredName: preferredName, continuation: continuation)
        }
    }
    func adopt(id: UUID, context: VideoPlaybackRequestContext, preferredName: String, continuation: CheckedContinuation<URL, Error>) {
        let job = Job(id: id, context: context, directory: root.appendingPathComponent(id.uuidString + ".hls", isDirectory: true),
            preferredName: preferredName, continuation: continuation)
        jobs[id] = job; start(job)
    }
    func pause(_ id: UUID) {
        guard let job = jobs[id], !job.paused,
              !DownloadManagerService.shared.finalizingHLSDownloadIDs.contains(id) else { return }
        job.paused = true; job.operation?.cancel()
        job.resumeOnActivation = false
        DownloadManagerService.shared.markPaused(id: id)
    }
    func resume(_ id: UUID) {
        guard let job = jobs[id], job.paused else { return }
        job.paused = false; DownloadManagerService.shared.markResumed(id: id)
        if job.operation == nil { start(job) } else { job.resumeRequested = true }
    }
    func cancel(_ id: UUID) {
        guard let job = jobs[id], !job.canceled else { return }
        job.canceled = true; job.paused = false; job.operation?.cancel()
        if job.operation == nil { finish(job, error: CancellationError()) }
    }
    func cancelAll() { Array(jobs.keys).forEach(cancel) }
    private func start(_ job: Job) {
        if UIApplication.shared.applicationState == .active {
            job.assertion = UIApplication.shared.beginBackgroundTask(withName: "HLS download") { [weak self] in
                Task { @MainActor in
                    guard let self, self.jobs[job.id] === job else { return }
                    self.endAssertion(job)
                    if !MediaExportBackgroundService.shared.isRunning {
                        self.pause(job.id); job.resumeOnActivation = true
                    }
                }
            }
        }
        job.progress = Progress(totalUnitCount: 1000)
        let id = job.id
        job.progress.cancellationHandler = { [weak self] in Task { @MainActor in self?.pause(id) } }
        job.operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await MediaExportBackgroundService.shared.perform(progress: job.progress) {
                    try await self.run(job)
                }
            } catch {
                job.operation = nil
                endAssertion(job)
                job.progress.cancellationHandler = nil
                if job.resumeRequested, !job.canceled { job.resumeRequested = false; start(job); return }
                if job.paused, !job.canceled { return }
                finish(job, error: error)
            }
        }
    }
    private func run(_ job: Job) async throws {
        await startup.value
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true) }.value
        if job.plan == nil {
            var plan = Plan()
            _ = try await loadPlaylist(job.context.url, name: "index.m3u8", context: job.context, depth: 0, plan: &plan)
            job.plan = plan
            for (name, data) in plan.playlists {
                let url = job.directory.appendingPathComponent(name)
                try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
            }
        }
        guard let plan = job.plan else { throw StreamingMediaDownloadError.unsupportedManifest }
        let resources = plan.resources.filter { !job.completed.contains($0.filename) }
        try await withThrowingTaskGroup(of: (String, Int64).self) { group in
            var next = 0
            var nextProgressUpdate = ContinuousClock.now
            func enqueue() {
                guard next < resources.count else { return }
                let resource = resources[next]; next += 1
                group.addTask { @MainActor in
                    let bytes = try await self.fetch(resource, for: job)
                    return (resource.filename, bytes)
                }
            }
            for _ in 0..<min(4, resources.count) { enqueue() }
            while let (name, bytes) = try await group.next() {
                try Task.checkCancellation()
                if job.completed.insert(name).inserted { job.received += bytes }
                let now = ContinuousClock.now
                // A long VOD can finish several fragments between UI updates.
                // Dami Star sample (3,357 fragments): https://www.dm154.top/vodplay/418822-1-1.html
                if now >= nextProgressUpdate || job.completed.count == plan.resources.count {
                    let fraction = Double(job.completed.count) / Double(max(1, plan.resources.count))
                    job.progress.completedUnitCount = Int64(900 * fraction)
                    DownloadManagerService.shared.updateHLSProgress(id: job.id, fraction: fraction, receivedBytes: job.received)
                    nextProgressUpdate = now + .milliseconds(200)
                }
                enqueue()
            }
        }
        try Task.checkCancellation()
        let manager = DownloadManagerService.shared
        manager.setHLSFinalizing(true, for: job.id)
        defer { manager.setHLSFinalizing(false, for: job.id) }
        let result: URL
        if plan.convertible {
            let index = job.directory.appendingPathComponent("index.m3u8")
            if let primary = plan.playlists[plan.primaryMedia] { try primary.write(to: index, options: .atomic) }
            do { result = try await OfflineVideoConversionService.exportMP4(from: job.directory, into: DownloadManagerService.downloadsDirectory,
                preferredFilename: job.preferredName, allowTranscoding: false) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                if let original = plan.playlists["index.m3u8"] { try original.write(to: index, options: .atomic) }
                result = try await commitBundle(job)
            }
        } else { result = try await commitBundle(job) }
        let bytes = await Task.detached(priority: .utility, operation: { FileStorageSize.bytes(at: result) }).value
        if Task.isCancelled || job.canceled {
            try? FileManager.default.removeItem(at: result)
            throw CancellationError()
        }
        job.progress.completedUnitCount = 1000
        job.progress.cancellationHandler = nil
        manager.markFinished(id: job.id, savedURL: result, savedBytes: bytes)
        endAssertion(job)
        job.progress.cancellationHandler = nil
        jobs.removeValue(forKey: job.id); job.continuation.resume(returning: result)
        try? await Task.detached(priority: .utility) { try FileManager.default.removeItem(at: job.directory) }.value
    }
    private func finish(_ job: Job, error: Error) {
        guard jobs.removeValue(forKey: job.id) != nil else { return }
        endAssertion(job)
        let manager = DownloadManagerService.shared
        if job.canceled { manager.markCanceled(id: job.id) }
        else { manager.markFailed(id: job.id, error: error) }
        job.continuation.resume(throwing: error)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: job.directory) }
    }
    private func endAssertion(_ job: Job) {
        guard job.assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(job.assertion); job.assertion = .invalid
    }
    private func commitBundle(_ job: Job) async throws -> URL {
        let name = (job.preferredName as NSString).deletingPathExtension + ".hls"
        let directory = DownloadManagerService.downloadsDirectory
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = FileSafety.availableURL(name: name, directory: directory)
            try FileManager.default.moveItem(at: job.directory, to: target)
            return target
        }.value
    }
    private func fetch(_ resource: Resource, for job: Job) async throws -> Int64 {
        var last: Error = URLError(.unknown)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                if resource.key {
                    let (data, response) = try await requestWithRateLimit(for: resource.url) {
                        try await job.context.boundedData(for: resource.url,
                            referrer: job.context.referrer ?? job.context.url, maximumBytes: 16, session: session)
                    }
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count == 16 else { throw StreamingMediaDownloadError.invalidChunk }
                    let destination = job.directory.appendingPathComponent(resource.filename)
                    try await Task.detached(priority: .utility) { try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }.value
                    return Int64(data.count)
                }
                let (temporary, response) = try await requestWithRateLimit(for: resource.url, discard: { file in
                    try? FileManager.default.removeItem(at: file)
                }) {
                    try await job.context.download(for: resource.url, referrer: job.context.referrer ?? job.context.url,
                        range: resource.range, session: session)
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw WebResourceDownloadError.invalidResponse }
                guard !["text/html", "application/json"].contains(http.mimeType?.lowercased() ?? "") else { throw StreamingMediaDownloadError.invalidChunk }
                let bytes = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                guard bytes > 0, !resource.key || bytes == 16 else { throw StreamingMediaDownloadError.invalidChunk }
                if let range = resource.range {
                    let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int64($0) }
                    guard bounds.count == 2, http.statusCode == 206, bytes == bounds[1] - bounds[0] + 1,
                          http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(bounds[0])-\(bounds[1])/") == true else { throw StreamingMediaDownloadError.invalidChunk }
                }
                let destination = job.directory.appendingPathComponent(resource.filename)
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    if resource.segment && resource.range == nil { _ = try HLSTransportPrefix.normalizeFile(temporary) }
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }.value
                return bytes
            } catch is CancellationError { throw CancellationError() }
            catch let error as OriginRateLimit { throw error }
            catch { last = error; try await Task.sleep(for: .milliseconds(350 * (attempt + 1))) }
        }
        throw last
    }

    // Xigua Cartoon serves the playlist but can throttle its fragments with HTTP 429 and Retry-After.
    // Reproduce at https://www.cnxgct.com/video/doupocangqiongnianfanguoyu-tiancantudou/hJAQn8npav.html
    private func requestWithRateLimit<Body>(for url: URL, discard: (Body) -> Void = { _ in },
                                            request: () async throws -> (Body, URLResponse)) async throws -> (Body, URLResponse) {
        let scheme = url.scheme?.lowercased() ?? "https"
        let host = url.host?.lowercased() ?? ""
        let origin = "\(scheme)://\(host):\(url.port ?? (scheme == "http" ? 80 : 443))"
        var retries = 0
        while true {
            try await waitForOrigin(origin)
            let result = try await request()
            guard let response = result.1 as? HTTPURLResponse, response.statusCode == 429 else { return result }
            discard(result.0)
            let now = ContinuousClock.now
            let retry = now + .seconds(Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After")))
            originThrottles = originThrottles.filter { $0.value.expires > now }
            let next = max(originThrottles[origin]?.nextRequest ?? now, retry)
            originThrottles[origin] = OriginThrottle(nextRequest: next, expires: next + .seconds(10 * 60))
            guard retries < 3 else { throw OriginRateLimit() }
            retries += 1
        }
    }

    private func waitForOrigin(_ origin: String) async throws {
        while let throttle = originThrottles[origin] {
            let now = ContinuousClock.now
            if throttle.expires <= now {
                originThrottles[origin] = nil
                break
            }
            if throttle.nextRequest <= now {
                // Avoid releasing every waiting fragment into the same burst.
                originThrottles[origin]?.nextRequest = now + .seconds(1)
                break
            }
            guard now.duration(to: throttle.nextRequest) <= .seconds(120) else { throw OriginRateLimit() }
            try await Task.sleep(until: throttle.nextRequest, clock: .continuous)
        }
        try Task.checkCancellation()
    }

    private static func retryDelay(_ header: String?) -> Double {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 2 }
        if let seconds = Double(value), seconds.isFinite { return max(1, min(seconds, 86_400)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return 2 }
        return max(1, min(date.timeIntervalSinceNow, 86_400))
    }

    private func loadPlaylist(_ url: URL, name: String, context: VideoPlaybackRequestContext, depth: Int, plan: inout Plan) async throws -> String {
        guard depth <= 4, plan.visiting.insert(url).inserted, plan.playlists.count < 8 else { throw StreamingMediaDownloadError.unsupportedManifest }
        defer { plan.visiting.remove(url) }
        let (data, response) = try await requestWithRateLimit(for: url) {
            try await context.boundedData(for: url,
                referrer: context.referrer ?? context.url, maximumBytes: 4 * 1_024 * 1_024, session: session)
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 4 * 1_024 * 1_024,
              let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw StreamingMediaDownloadError.unsupportedManifest }
        let base = response.url ?? url
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func resolved(_ value: String) throws -> URL {
            guard let target = URL(string: value, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""), target.host != nil,
                  target.user == nil, target.password == nil else { throw StreamingMediaDownloadError.unsupportedManifest }
            return target
        }
        var variants: [Variant] = []
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            guard index+1 < lines.count else { throw StreamingMediaDownloadError.unsupportedManifest }
            guard let target = try? resolved(lines[index+1]) else { continue }
            let attrs = Self.attributes(lines[index])
            variants.append((Int(attrs["BANDWIDTH"] ?? "") ?? 0, target, attrs["AUDIO"]))
        }
        if let defaultVariant = variants.first {
            let child = "playlist-\(UUID().uuidString).m3u8"
            let chosen = try await loadVideoVariant(defaultVariant, alternatives: variants, name: child,
                context: context, depth: depth + 1, plan: &plan)
            var master = "#EXTM3U\n"
            if let audio = chosen.audioGroup, let line = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA:") && Self.attributes($0)["GROUP-ID"] == audio && Self.attributes($0)["TYPE"] == "AUDIO" }),
               let uri = Self.attributes(line)["URI"] {
                plan.convertible = false
                let audioName = "audio\(depth).m3u8"
                _ = try await loadPlaylist(resolved(uri), name: audioName, context: context, depth: depth+1, plan: &plan)
                master += Self.replaceURI(in: line, with: audioName) + "\n"
            }
            let audioAttribute = chosen.audioGroup.map { ",AUDIO=\"\($0)\"" } ?? ""
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(chosen.bandwidth)\(audioAttribute)\n\(child)\n"
            plan.playlists[name] = Data(master.utf8); return name
        }
        guard lines.contains("#EXT-X-ENDLIST") else { throw StreamingMediaDownloadError.unsupportedManifest }
        if !name.hasPrefix("audio") { plan.primaryMedia = name }
        var rewritten: [String] = [], pendingRange: String?, rangeEnd: Int64 = 0
        var rangeIsImplicit = false, previousRangeURL: URL?
        for line in lines {
            try Task.checkCancellation()
            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let raw = line.dropFirst(17).split(separator: "@", omittingEmptySubsequences: false)
                let values = raw.compactMap { Int64($0) }
                guard raw.count <= 2, values.count == raw.count, let length = values.first, length > 0 else { throw StreamingMediaDownloadError.unsupportedManifest }
                rangeIsImplicit = values.count == 1
                let start = values.count > 1 ? values[1] : rangeEnd
                guard start >= 0, length <= Int64.max-start else { throw StreamingMediaDownloadError.unsupportedManifest }
                pendingRange = "bytes=\(start)-\(start+length-1)"; rangeEnd = start+length
                continue
            }
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-MAP:") {
                let attrs = Self.attributes(line), isKey = line.hasPrefix("#EXT-X-KEY:")
                if isKey, attrs["METHOD"] == "NONE" { plan.convertible = false; rewritten.append(line); continue }
                guard !isKey || (attrs["METHOD"] == "AES-128" && (attrs["KEYFORMAT"] == nil || attrs["KEYFORMAT"] == "identity")), let uri = attrs["URI"] else { throw StreamingMediaDownloadError.unsupportedManifest }
                if !isKey { plan.convertible = false }
                if isKey { plan.keyCount += 1; if plan.keyCount > 1 { plan.convertible = false } }
                let remote = try resolved(uri)
                var mapRange: String?
                if !isKey, let raw = attrs["BYTERANGE"] {
                    let values = raw.split(separator: "@").compactMap { Int64($0) }
                    guard let length = values.first, length > 0 else { throw StreamingMediaDownloadError.unsupportedManifest }
                    let start = values.count > 1 ? values[1] : 0
                    guard start >= 0, length <= Int64.max - start else { throw StreamingMediaDownloadError.unsupportedManifest }
                    mapRange = "bytes=\(start)-\(start+length-1)"
                }
                let file = addResource(remote, range: mapRange, key: isKey, segment: false, plan: &plan)
                rewritten.append(Self.replaceURI(in: line, with: file).replacingOccurrences(of: #",?BYTERANGE="[^"]*""#, with: "", options: .regularExpression)); continue
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                guard plan.resources.count < 10_000 else { throw StreamingMediaDownloadError.unsupportedManifest }
                let remote = try resolved(line)
                if pendingRange != nil, rangeIsImplicit, previousRangeURL != remote { throw StreamingMediaDownloadError.unsupportedManifest }
                let file = addResource(remote, range: pendingRange, key: false, segment: true, plan: &plan)
                previousRangeURL = pendingRange == nil ? nil : remote
                pendingRange = nil; rewritten.append(file)
            } else { rewritten.append(line) }
        }
        plan.playlists[name] = Data(rewritten.joined(separator: "\n").utf8)
        return name
    }

    // Xigua Cartoon advertised a 112-minute highest rendition alongside the 24-minute episode.
    // Reproduce at https://www.cnxgct.com/video/doupocangqiongnianfanguoyu-tiancantudou/hJAQn8npav.html
    private func loadVideoVariant(_ defaultVariant: Variant, alternatives: [Variant], name: String,
                                  context: VideoPlaybackRequestContext, depth: Int, plan: inout Plan) async throws -> Variant {
        let ranked = alternatives.sorted { $0.bandwidth > $1.bandwidth }
        let highest = ranked.first ?? defaultVariant
        guard depth == 1, highest.url != defaultVariant.url else {
            _ = try await loadPlaylist(highest.url, name: name, context: context, depth: depth, plan: &plan)
            return highest
        }

        var reference = plan
        do {
            _ = try await loadPlaylist(defaultVariant.url, name: name, context: context, depth: depth, plan: &reference)
        } catch {
            try Task.checkCancellation()
            if error is OriginRateLimit { throw error }
            _ = try await loadPlaylist(highest.url, name: name, context: context, depth: depth, plan: &plan)
            return highest
        }

        for variant in ranked.prefix(8) where variant.url != defaultVariant.url {
            var candidate = plan
            do {
                _ = try await loadPlaylist(variant.url, name: name, context: context, depth: depth, plan: &candidate)
                if HLSDownloadTimeline.match(reference.primaryDuration, candidate.primaryDuration) {
                    plan = candidate
                    return variant
                }
            } catch {
                try Task.checkCancellation()
                if error is OriginRateLimit { break }
            }
        }
        plan = reference
        return defaultVariant
    }
    private func addResource(_ url: URL, range: String?, key: Bool, segment: Bool, plan: inout Plan) -> String {
        let identity = url.absoluteString + "|" + (range ?? "")
        if let existing = plan.resourceNames[identity] { return existing }
        let mediaExtension = ["m4s", "mp4", "m4a", "cmfv", "cmfa"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "ts"
        let file = key && !plan.resources.contains(where: \.key) ? "key.bin" : String(format: "%06d", plan.resources.count) + (key ? ".key" : segment ? "." + mediaExtension : ".mp4")
        plan.resources.append(.init(url: url, filename: file, range: range, key: key, segment: segment)); plan.resourceNames[identity] = file
        return file
    }
    nonisolated static func attributes(_ line: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))"#) else { return [:] }
        let range = NSRange(line.startIndex..., in: line)
        return Dictionary(expression.matches(in: line, range: range).compactMap { match in
            guard let key = Range(match.range(at: 1), in: line) else { return nil }
            let value = Range(match.range(at: 2), in: line) ?? Range(match.range(at: 3), in: line)
            return value.map { (String(line[key]), String(line[$0])) }
        }, uniquingKeysWith: { first, _ in first })
    }
    private static func replaceURI(in line: String, with filename: String) -> String {
        line.replacingOccurrences(of: #"URI="[^"]*""#, with: "URI=\"\(filename)\"", options: .regularExpression)
    }
}

enum HLSDownloadTimeline {
    static func duration(of playlist: String) -> Double? {
        var seconds = 0.0
        for line in playlist.split(whereSeparator: \.isNewline) {
            let tag = line.trimmingCharacters(in: .whitespaces)
            guard tag.hasPrefix("#EXTINF:") else { continue }
            guard let duration = Double(tag.dropFirst(8).prefix { $0 != "," }), duration.isFinite, duration > 0 else { return nil }
            seconds += duration
        }
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func match(_ first: Double?, _ second: Double?) -> Bool {
        guard let first, let second else { return true }
        return abs(first - second) <= max(2, first * 0.01)
    }
}
