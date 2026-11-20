import AVFoundation
import SouloDecoder
import UIKit

@MainActor final class ExtendedPlaybackDecoder: PlaybackDecoder {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let worker = DecoderWorker()
    private var snapshot = DecoderWorker.Snapshot()
    private var active = true
    private(set) var decodedFrameCount = 0
    var onFirstFrame: (() -> Void)?
    var layer: CALayer { videoLayer }

    init(url: URL, context: VideoPlaybackRequestContext?, hls: Bool) {
        videoLayer.videoGravity = .resizeAspect
        videoLayer.isOpaque = true
        var options: [String: String] = ["tls-verify": "yes"]
        if VideoLoadingStatus.isOnline(url) {
            if let context {
                options["user-agent"] = context.userAgent.filter { $0 != "\r" && $0 != "\n" }
                let request = context.resourceRequest(for: url, referrer: context.referrer)
                if let value = request.value(forHTTPHeaderField: "Referer"), let referrer = URL(string: value),
                   let host = referrer.host, let scheme = referrer.scheme {
                    // FFmpeg reuses custom headers on redirects. Pass only the page origin.
                    var origin = URLComponents()
                    origin.scheme = scheme
                    origin.host = host
                    origin.port = referrer.port
                    options["referrer"] = origin.url?.absoluteString
                }
                let cookies = WebResourceDownloadService.matchingCookies(from: context.cookies, for: url)
                    .filter { !($0.name + $0.value + $0.domain + $0.path).contains { "\r\n;".contains($0) } }
                    .map { cookie in
                        var entry = "\(cookie.name)=\(cookie.value); domain=\(cookie.domain); path=\(cookie.path)"
                        if !cookie.domain.hasPrefix(".") { entry += "; host-only=1" }
                        if cookie.isSecure { entry += "; secure=1" }
                        if let expiry = cookie.expiresDate {
                            let date = DateFormatter()
                            date.locale = Locale(identifier: "en_US_POSIX")
                            date.timeZone = TimeZone(secondsFromGMT: 0)
                            date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                            entry += "; expires=" + date.string(from: expiry)
                        }
                        return entry
                    }.joined(separator: "\n")
                if !cookies.isEmpty { options["stream-lavf-o"] = "cookies=%\(cookies.utf8.count)%\(cookies)" }
            }
            // A site's extensionless endpoint may return a playlist as text/plain.
            if hls { options["demuxer-lavf-format"] = "hls" }
        }
        worker.open(url, options: options) { [weak self] snapshot, frame in
            guard let self, self.active else { return }
            if let snapshot { self.snapshot = snapshot }
            if let frame {
                if self.videoLayer.status == .failed { self.videoLayer.flush() }
                if self.videoLayer.isReadyForMoreMediaData {
                    self.videoLayer.enqueue(frame)
                    self.decodedFrameCount += 1
                    if self.decodedFrameCount == 1 { self.onFirstFrame?() }
                }
            }
        }
    }

    var state: PlaybackDecoderState { snapshot.state }
    var currentTime: Double { snapshot.time }
    var duration: Double { snapshot.duration }
    var videoSize: CGSize { snapshot.size }
    var hasVideo: Bool? { snapshot.hasVideo }
    var isSeekable: Bool { snapshot.seekable }
    var isPlaying: Bool { state == .playing }
    var loadedRanges: [CMTimeRange] { [] }
    var receivedBytes: Int64? { nil }
    var loadingRate: VideoLoadingStatus? { snapshot.networkRate.map(VideoLoadingStatus.rate) }
    var tracks: [PlaybackDecoderTrack] { snapshot.tracks }
    var rate: Float = 1 {
        didSet { worker.set("speed", String(rate)) }
    }

    func play() { worker.set("pause", "no") }
    func pause() { worker.set("pause", "yes") }
    func seek(to seconds: Double) {
        worker.command(["seek", String(seconds), "absolute+exact"])
    }
    func selectTrack(_ id: String?, kind: PlaybackDecoderTrack.Kind) {
        worker.set(kind == .audio ? "aid" : "sid", id ?? "no")
    }
    func update() {}
    func stop(retaining lease: AnyObject?) {
        active = false
        snapshot = .init(state: .failed)
        videoLayer.flushAndRemoveImage()
        worker.stop(retaining: lease)
    }
    deinit { worker.stop(retaining: nil) }
}

private final class DecoderWorker: @unchecked Sendable {
    struct Snapshot: Sendable {
        var state: PlaybackDecoderState = .opening
        var time = 0.0
        var duration = 0.0
        var size = CGSize.zero
        var hasVideo: Bool? = nil
        var seekable = false
        var networkRate: Int64? = nil
        var tracks: [PlaybackDecoderTrack] = []
    }
    typealias Output = @MainActor @Sendable (Snapshot?, CMSampleBuffer?) -> Void
    private let queue = DispatchQueue(label: "com.soulo.extended-playback", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var renderer: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var snapshot = Snapshot()
    private var loaded = false
    private var needsTracks = false
    private var online = false
    private var bufferPool: CVPixelBufferPool?
    private var frameSize = CGSize.zero
    private var nextPoll: ContinuousClock.Instant = .now

    func open(_ url: URL, options: [String: String], output: @escaping Output) {
        queue.async { [self] in
            guard let handle = mpv_create() else {
                Task { @MainActor in output(Snapshot(state: .failed), nil) }
                return
            }
            self.handle = handle
            self.online = VideoLoadingStatus.isOnline(url)
            // The host owns the audio session, media controls, and playlist.
            let defaults = [
                "config": "no", "terminal": "no", "idle": "yes", "pause": "yes",
                "input-default-bindings": "no", "load-scripts": "no", "ao": "audiounit",
                "vo": "libmpv", "hwdec": "videotoolbox-copy", "hwdec-codecs": "all",
                "autoload-files": url.isFileURL ? "yes" : "no",
                "sub-auto": url.isFileURL ? "exact" : "no", "audio-file-auto": "no",
                "network-timeout": "25", "cache": "auto", "demuxer-readahead-secs": "15",
                "demuxer-max-bytes": "48MiB", "demuxer-max-back-bytes": "16MiB",
            ]
            for (name, value) in defaults.merging(options, uniquingKeysWith: { _, value in value }) {
                mpv_set_option_string(handle, name, value)
            }
            guard mpv_initialize(handle) >= 0 else {
                self.destroy()
                Task { @MainActor in output(Snapshot(state: .failed), nil) }
                return
            }
            let renderResult = "sw".withCString { api in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return mpv_render_context_create(&self.renderer, handle, &parameters)
            }
            guard renderResult >= 0 else {
                self.destroy()
                Task { @MainActor in output(Snapshot(state: .failed), nil) }
                return
            }
            mpv_observe_property(handle, 1, "track-list", MPV_FORMAT_NONE)
            self.send(["loadfile", url.isFileURL ? url.path : url.absoluteString])
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(12), leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.poll(output) }
            self.timer = timer
            timer.resume()
        }
    }

    func set(_ name: String, _ value: String) { command(["set", name, value]) }
    func command(_ values: [String]) { queue.async { self.send(values) } }
    private func send(_ values: [String]) {
        guard let handle else { return }
        let strings = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var arguments = strings.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        arguments.withUnsafeMutableBufferPointer { _ = mpv_command_async(handle, 0, $0.baseAddress) }
    }

    private func poll(_ output: @escaping Output) {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = true
                needsTracks = true
            case MPV_EVENT_END_FILE:
                let detail = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                loaded = false
                snapshot.state = detail?.reason == MPV_END_FILE_REASON_EOF ? .ended : .failed
                Task { @MainActor [snapshot] in output(snapshot, nil) }
            case MPV_EVENT_PROPERTY_CHANGE:
                needsTracks = true
            default:
                break
            }
        }
        if loaded, .now >= nextPoll {
            nextPoll = .now.advanced(by: .milliseconds(100))
            snapshot.time = number("time-pos") ?? snapshot.time
            snapshot.duration = number("duration") ?? snapshot.duration
            snapshot.seekable = flag("seekable")
            snapshot.state = flag("pause") ? .paused : (flag("paused-for-cache") ? .buffering : .playing)
            if let width = number("dwidth"), let height = number("dheight"), width > 0, height > 0 {
                snapshot.size = CGSize(width: width, height: height)
            }
            let rate = online ? number("demuxer-cache-state/raw-input-rate") : nil
            snapshot.networkRate = rate.flatMap { $0 > 0 && $0 < Double(Int64.max) ? Int64($0) : nil }
            if needsTracks { readTracks() }
            Task { @MainActor [snapshot] in output(snapshot, nil) }
        }
        if loaded, let renderer, mpv_render_context_update(renderer) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0,
           let frame = render(renderer) {
            Task { @MainActor in output(nil, frame) }
        }
    }

    private func readTracks() {
        needsTracks = false
        let count = min(256, Int(number("track-list/count") ?? 0))
        var foundVideo = false
        var tracks: [PlaybackDecoderTrack] = []
        for index in 0..<count {
            let path = "track-list/\(index)/"
            let type = string(path + "type")
            if type == "video" {
                if !flag(path + "albumart") { foundVideo = true }
                continue
            }
            guard let id = string(path + "id"), type == "audio" || type == "sub" else { continue }
            let language = string(path + "lang")
            let name = string(path + "title") ?? language.flatMap(Locale.current.localizedString(forLanguageCode:))
                ?? language ?? "#\(id)"
            tracks.append(.init(id: id, kind: type == "audio" ? .audio : .subtitle, name: name,
                                selected: flag(path + "selected")))
        }
        if count > 0 { snapshot.hasVideo = foundVideo }
        snapshot.tracks = tracks
    }

    private func render(_ renderer: OpaquePointer) -> CMSampleBuffer? {
        let size = snapshot.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, 1920 / max(size.width, size.height))
        let width = max(2, Int(size.width * scale))
        let height = max(2, Int(size.height * scale))
        let dimensions = CGSize(width: width, height: height)
        if dimensions != frameSize {
            frameSize = dimensions
            bufferPool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &bufferPool)
        }
        guard let bufferPool else { return nil }
        var pixel: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, bufferPool, limit, &pixel) == kCVReturnSuccess,
              let pixel, CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { return nil }
        var stride = CVPixelBufferGetBytesPerRow(pixel)
        var sizeValues = [Int32(width), Int32(height)]
        var block: Int32 = 0
        let result = "bgr0".withCString { format in
            withUnsafeMutablePointer(to: &stride) { stride in
                withUnsafeMutablePointer(to: &block) { block in
                    sizeValues.withUnsafeMutableBufferPointer { size in
                        var parameters = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: size.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stride),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: CVPixelBufferGetBaseAddress(pixel)),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: block),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        return mpv_render_context_render(renderer, &parameters)
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard result >= 0 else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var frame: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format,
                  sampleTiming: &timing, sampleBufferOut: &frame) == noErr, let frame else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0, let value = CFArrayGetValueAtIndex(attachments, 0) {
            let item = Unmanaged<CFMutableDictionary>.fromOpaque(value).takeUnretainedValue()
            CFDictionarySetValue(item, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return frame
    }

    private func number(_ property: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        return mpv_get_property(handle, property, MPV_FORMAT_DOUBLE, &value) >= 0 && value.isFinite ? value : nil
    }
    private func flag(_ property: String) -> Bool {
        guard let handle else { return false }
        var value: Int32 = 0
        return mpv_get_property(handle, property, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }
    private func string(_ property: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, property) else { return nil }
        defer { mpv_free(value) }
        return String(validatingUTF8: value)
    }
    func stop(retaining lease: AnyObject?) { queue.async { withExtendedLifetime(lease) { self.destroy() } } }
    private func destroy() {
        timer?.cancel()
        timer = nil
        if let renderer { mpv_render_context_free(renderer) }
        renderer = nil
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
    }
}
