import AVFoundation
import CommonCrypto
import Foundation
import SouloHLSMux

enum OfflineVideoConversionError: LocalizedError {
    case failed
    var errorDescription: String? { ToolText.text("video_export_failed") }
}

/// The local transmuxer keeps compressed H.264/AAC samples. AVFoundation then
/// writes a regular MP4 with a seek index, without encoding or replacing HLS.
@MainActor enum OfflineVideoConversionService {
    static func supports(_ url: URL) -> Bool {
        url.isFileURL && [OfflineHLSReference.fileExtension, "movpkg", "hls"].contains(url.pathExtension.lowercased())
    }

    static func exportMP4(from source: URL, into directory: URL,
                          preferredFilename: String? = nil,
                          allowTranscoding: Bool = true,
                          operation: FileOperationProgress = FileOperationProgress()) async throws -> URL {
        try await MediaExportBackgroundService.shared.perform(progress: operation.progress) {
            try await exportNativeMP4(from: source, into: directory, preferredFilename: preferredFilename,
                                      allowTranscoding: allowTranscoding, operation: operation)
        }
    }

    private static func exportNativeMP4(from source: URL, into directory: URL,
                                       preferredFilename: String?,
                                       allowTranscoding: Bool,
                                       operation: FileOperationProgress) async throws -> URL {
        guard supports(source) else { throw ReadingToolError.unsupported }
        try check(operation)
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("SouloMP4-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }
        let preparation = FileOperationProgress(), muxing = Progress(totalUnitCount: 1), finishing = Progress(totalUnitCount: 1000)
        operation.progress.totalUnitCount = 1000
        operation.progress.addChild(preparation.progress, withPendingUnitCount: 100)
        operation.progress.addChild(muxing, withPendingUnitCount: 800)
        operation.progress.addChild(finishing, withPendingUnitCount: 100)
        let fragmented = scratch.appendingPathComponent("fragmented.mp4")
        let work = Task.detached(priority: .userInitiated) { () async throws -> PreparedMedia in
            try preparation.check()
            let reference = source.pathExtension.lowercased() == OfflineHLSReference.fileExtension ? source : nil
            let package = try reference.map(OfflineHLSReference.packageURL(for:)) ?? source
            let origin = try reference.flatMap { try OfflineHLSReference.sourceURL(for: $0) }
            var encryption = try reference.flatMap { try OfflineHLSReference.encryptionMaterial(for: $0) }
            let portable = source.pathExtension.lowercased() == "hls"
            if encryption == nil, !portable {
                encryption = try await PortableHLSBundle.encryptionMaterial(packageURL: package, sourceURL: origin)
                if let reference, let encryption { try OfflineHLSReference.storeEncryption(encryption, for: reference) }
            }
            let bundle = portable ? source : try await PortableHLSBundle.export(packageURL: package, name: "Input", into: scratch,
                sourceURL: origin, operation: preparation, linkFragments: true, encryption: encryption)
            let playlist = try LocalHLSExport.playlists(in: bundle)
            if let media = try LocalHLSExport.stageFragments(playlist, in: scratch, operation: operation, progress: muxing) {
                return .fragmented(media)
            }
            guard playlist.audio == nil else { throw OfflineVideoConversionError.failed }
            do {
                let info = try HLSMP4Transmuxer.write(playlist: playlist.video, output: fragmented,
                    operation: operation, progress: muxing)
                return .transportStream(info)
            } catch {
                try operation.check()
                try Task.checkCancellation()
                guard allowTranscoding else { throw error }
                let parts = try HLSMP4Transmuxer.discontinuousParts(playlist: playlist.video, in: scratch,
                    operation: operation, progress: muxing)
                guard !parts.isEmpty else { throw error }
                return .discontinuous(parts)
            }
        }
        operation.progress.cancellationHandler = { work.cancel() }
        defer { operation.progress.cancellationHandler = nil }
        let media = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try check(operation)
        let output = scratch.appendingPathComponent("output.mp4")
        let asset: AVAsset
        let info: HLSMP4Transmuxer.Info
        var videoComposition: AVVideoComposition?
        switch media {
        case .transportStream(let transportInfo):
            asset = AVURLAsset(url: fragmented)
            info = transportInfo
        case .fragmented(let source):
            (asset, info) = try await prepareFragmentedMedia(source)
        case .discontinuous(let clips):
            (asset, videoComposition, info) = try await prepareDiscontinuousMedia(clips)
        }
        try await flatten(asset, to: output, operation: operation, progress: finishing, videoComposition: videoComposition)
        try await validate(output, info: info)
        try check(operation)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let reserved = directory.standardizedFileURL == DownloadManagerService.downloadsDirectory.standardizedFileURL
            ? Set(DownloadManagerService.shared.downloads.filter { [.inProgress, .paused].contains($0.status) }.map(\.fileName)) : []
        let name = preferredFilename.map { ($0 as NSString).deletingPathExtension + ".mp4" }
            ?? source.deletingPathExtension().lastPathComponent + ".mp4"
        let target = FileSafety.availableURL(name: name, directory: directory, excluding: reserved)
        try manager.moveItem(at: output, to: target)
        finishing.completedUnitCount = 1000
        return target
    }

    private struct ExportHandle: @unchecked Sendable { let session: AVAssetExportSession }
    private enum PreparedMedia: Sendable {
        case transportStream(HLSMP4Transmuxer.Info)
        case fragmented(LocalHLSExport.FragmentedMedia)
        case discontinuous([HLSMP4Transmuxer.Clip])
    }

    private static func prepareFragmentedMedia(_ source: LocalHLSExport.FragmentedMedia) async throws -> (AVAsset, HLSMP4Transmuxer.Info) {
        let main = AVURLAsset(url: source.video.url)
        let videoTracks = try await main.loadTracks(withMediaType: .video)
        let embeddedAudio = try await main.loadTracks(withMediaType: .audio)
        guard videoTracks.count == 1, let video = videoTracks.first, embeddedAudio.count <= 1,
              let videoRange = try await checkedRange(video, duration: source.video.duration) else {
            throw OfflineVideoConversionError.failed
        }
        guard let alternate = source.audio else {
            return (main, .init(duration: source.video.duration, audio: !embeddedAudio.isEmpty))
        }
        let audioAsset = AVURLAsset(url: alternate.url)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard audioTracks.count == 1, let audio = audioTracks.first,
              let audioRange = try await checkedRange(audio, duration: alternate.duration) else {
            throw OfflineVideoConversionError.failed
        }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OfflineVideoConversionError.failed
        }
        try picture.insertTimeRange(videoRange, of: video, at: .zero)
        picture.preferredTransform = try await video.load(.preferredTransform)
        try sound.insertTimeRange(audioRange, of: audio, at: .zero)
        return (composition, .init(duration: max(source.video.duration, alternate.duration), audio: true))
    }

    private static func checkedRange(_ track: AVAssetTrack, duration: Double) async throws -> CMTimeRange? {
        let range = try await track.load(.timeRange)
        let seconds = range.duration.seconds
        guard seconds.isFinite, seconds > 0, abs(seconds - duration) <= max(0.5, duration * 0.0001) else { return nil }
        return range
    }

    private static func prepareDiscontinuousMedia(_ clips: [HLSMP4Transmuxer.Clip]) async throws
        -> (AVAsset, AVVideoComposition, HLSMP4Transmuxer.Info) {
        struct Part {
            let range: CMTimeRange
            let bounds: CGRect
            let transform: CGAffineTransform
        }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw OfflineVideoConversionError.failed }
        var parts: [Part] = [], renderSize = CGSize.zero
        var cursor = CMTime.zero
        var frameDuration = CMTime(value: 1, timescale: 30)
        let hasAudio = clips.first?.info.audio == true
        for clip in clips {
            try Task.checkCancellation()
            let source = AVURLAsset(url: clip.url)
            guard clip.info.audio == hasAudio, let video = try await source.loadTracks(withMediaType: .video).first,
                  let range = try await checkedRange(video, duration: clip.info.duration)
            else { throw OfflineVideoConversionError.failed }
            let transform = try await video.load(.preferredTransform)
            if parts.isEmpty {
                let rate = try await video.load(.nominalFrameRate)
                if rate.isFinite, (12...60).contains(rate) {
                    frameDuration = CMTime(seconds: 1 / Double(rate), preferredTimescale: 60_000)
                }
            }
            let bounds = CGRect(origin: .zero, size: try await video.load(.naturalSize)).applying(transform).standardized
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 2, bounds.height >= 2,
                  bounds.width <= 4096, bounds.height <= 4096 else { throw OfflineVideoConversionError.failed }
            renderSize.width = max(renderSize.width, bounds.width)
            renderSize.height = max(renderSize.height, bounds.height)
            try picture.insertTimeRange(range, of: video, at: cursor)
            if hasAudio {
                guard let audio = try await source.loadTracks(withMediaType: .audio).first else {
                    throw OfflineVideoConversionError.failed
                }
                let audioRange = try await audio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                guard overlap.duration.seconds > 0,
                      abs(overlap.duration.seconds - range.duration.seconds) <= 0.5
                else { throw OfflineVideoConversionError.failed }
                let audioStart = cursor + (overlap.start - range.start)
                if audioStart > sound.timeRange.end {
                    sound.insertEmptyTimeRange(CMTimeRange(start: sound.timeRange.end, end: audioStart))
                }
                try sound.insertTimeRange(overlap, of: audio, at: audioStart)
            }
            parts.append(Part(range: CMTimeRange(start: cursor, duration: range.duration), bounds: bounds, transform: transform))
            cursor = cursor + range.duration
        }
        if !hasAudio { composition.removeTrack(sound) }
        let video = AVMutableVideoComposition()
        renderSize = CGSize(width: ceil(renderSize.width / 2) * 2, height: ceil(renderSize.height / 2) * 2)
        video.renderSize = renderSize
        video.frameDuration = frameDuration
        video.instructions = parts.map { part in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = part.range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: picture)
            let x = (renderSize.width - part.bounds.width) / 2 - part.bounds.minX
            let y = (renderSize.height - part.bounds.height) / 2 - part.bounds.minY
            layer.setTransform(part.transform.concatenating(CGAffineTransform(translationX: x, y: y)), at: part.range.start)
            instruction.layerInstructions = [layer]
            return instruction
        }
        return (composition, video, .init(duration: clips.reduce(0) { $0 + $1.info.duration }, audio: hasAudio))
    }

    private static func flatten(_ asset: AVAsset, to target: URL, operation: FileOperationProgress, progress: Progress,
                                videoComposition: AVVideoComposition? = nil) async throws {
        let preset = videoComposition == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard try await asset.load(.isExportable), let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(.mp4) else { throw OfflineVideoConversionError.failed }
        session.outputURL = target; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition
        let handle = ExportHandle(session: session)
        operation.progress.cancellationHandler = { handle.session.cancelExport() }
        let updates = Task {
            while !Task.isCancelled {
                progress.completedUnitCount = Int64(min(950, max(0, session.progress * 950)))
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        defer { updates.cancel(); operation.progress.cancellationHandler = nil }
        try check(operation)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch handle.session.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: ReadingToolError.canceled)
                    default: continuation.resume(throwing: handle.session.error ?? OfflineVideoConversionError.failed)
                    }
                }
            }
        } onCancel: { handle.session.cancelExport() }
    }

    private static func check(_ operation: FileOperationProgress) throws {
        try Task.checkCancellation(); try operation.check()
    }

    private static func validate(_ url: URL, info: HLSMP4Transmuxer.Info) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        let tolerance = max(0.5, info.duration * 0.0001)
        // Transport timestamps can include a short encoder tail beyond EXTINF.
        guard try await asset.load(.isPlayable), duration.isFinite, duration > 0,
              duration >= info.duration - tolerance, duration <= info.duration + max(1, tolerance), video.count == 1,
              audio.count == (info.audio ? 1 : 0) else { throw OfflineVideoConversionError.failed }
        for track in video + audio {
            guard !(try await track.load(.formatDescriptions)).isEmpty else { throw OfflineVideoConversionError.failed }
        }
    }
}

/// The offline downloader stores byte ranges as separate local files. Rebuild
/// their fragmented MP4 tracks in playlist order without fetching the origin.
private enum LocalHLSExport {
    struct Playlists {
        let root: URL
        let video: URL
        let audio: URL?
    }
    private struct Rendition {
        let files: [URL]
        let duration: Double
    }
    struct Track: Sendable {
        let url: URL
        let duration: Double
    }
    struct FragmentedMedia: Sendable {
        let video: Track
        let audio: Track?
    }

    static func playlists(in bundle: URL) throws -> Playlists {
        let playlist = try LocalHLSMedia.playlistURL(for: bundle)
        let root = bundle.standardizedFileURL.resolvingSymlinksInPath()
        let lines = try read(playlist)
        // A saved master already describes the rendition(s) downloaded by Soulo.
        let variants = lines.indices.filter { lines[$0].hasPrefix("#EXT-X-STREAM-INF:") }
        guard let selected = variants.first else { return .init(root: root, video: playlist, audio: nil) }
        guard variants.count == 1, lines.indices.contains(selected + 1) else { throw OfflineVideoConversionError.failed }
        let video = try localFile(lines[selected + 1], relativeTo: playlist, root: root)
        let audioGroup = AuthenticatedHLSDownloadService.attributes(lines[selected])["AUDIO"]
        guard let audioGroup else { return .init(root: root, video: video, audio: nil) }
        let audio = lines.lazy.filter { $0.hasPrefix("#EXT-X-MEDIA:") }
            .map(AuthenticatedHLSDownloadService.attributes)
            .first { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == audioGroup }
        guard let audioURI = audio?["URI"] else { throw OfflineVideoConversionError.failed }
        return try .init(root: root, video: video, audio: localFile(audioURI, relativeTo: playlist, root: root))
    }

    static func stageFragments(_ playlists: Playlists, in directory: URL, operation: FileOperationProgress,
                               progress: Progress) throws -> FragmentedMedia? {
        guard let video = try rendition(playlists.video, root: playlists.root) else { return nil }
        let audio = try playlists.audio.flatMap { try rendition($0, root: playlists.root) }
        guard playlists.audio == nil || audio != nil else { throw OfflineVideoConversionError.failed }
        progress.totalUnitCount = Int64(video.files.count + (audio?.files.count ?? 0))
        let picture = try stage(video, at: directory.appendingPathComponent("picture.mp4"), operation: operation, progress: progress)
        let sound = try audio.map { try stage($0, at: directory.appendingPathComponent("sound.m4a"), operation: operation, progress: progress) }
        return FragmentedMedia(video: picture, audio: sound)
    }

    private static func rendition(_ playlist: URL, root: URL) throws -> Rendition? {
        let lines = try read(playlist)
        let maps = lines.filter { $0.hasPrefix("#EXT-X-MAP:") }
        guard let map = maps.first else { return nil }
        let attributes = AuthenticatedHLSDownloadService.attributes(map)
        guard maps.count == 1, let initialization = attributes["URI"], attributes["BYTERANGE"] == nil,
              lines.contains("#EXT-X-ENDLIST"), !lines.contains(where: {
                  $0.hasPrefix("#EXT-X-BYTERANGE:") || $0 == "#EXT-X-DISCONTINUITY"
                      || ($0.hasPrefix("#EXT-X-KEY:") && AuthenticatedHLSDownloadService.attributes($0)["METHOD"] != "NONE")
              }) else { throw OfflineVideoConversionError.failed }
        let names = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap { $0.dropFirst(8).split(separator: ",").first.flatMap(Double.init) }
        let duration = durations.reduce(0, +)
        guard names.count == durations.count, !names.isEmpty, names.count <= 10_000,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }), duration.isFinite else { throw OfflineVideoConversionError.failed }
        let files = try ([initialization] + names).map { try localFile($0, relativeTo: playlist, root: root) }
        return Rendition(files: files, duration: duration)
    }

    private static func stage(_ rendition: Rendition, at url: URL, operation: FileOperationProgress,
                              progress: Progress) throws -> Track {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        for file in rendition.files {
            try autoreleasepool {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let bytes = try input.read(upToCount: 256 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation(); try operation.check()
                    try output.write(contentsOf: bytes)
                }
            }
            progress.completedUnitCount += 1
        }
        try output.synchronize()
        return Track(url: url, duration: rendition.duration)
    }

    private static func read(_ playlist: URL) throws -> [String] {
        guard let size = try playlist.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1_024 * 1_024 else {
            throw OfflineVideoConversionError.failed
        }
        let text = try String(contentsOf: playlist, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U" else { throw OfflineVideoConversionError.failed }
        return lines
    }

    private static func localFile(_ name: String, relativeTo playlist: URL, root: URL) throws -> URL {
        let path = try FileSafety.relativePath(name.removingPercentEncoding ?? name)
        let url = playlist.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else {
            throw ReadingToolError.unsafePath
        }
        return url
    }
}

/// One synchronous worker runs the bundled script in an interpreter without JIT.
/// Only media chunks cross the bridge. The worker owns the destination file.
private final class HLSMP4Transmuxer {
    struct Info: Sendable { let duration: Double; let audio: Bool }
    struct Clip: Sendable { let url: URL; let info: Info }
    private final class Output {
        let file: FileHandle
        var failure: Error?
        var written = 0

        init(file: FileHandle) { self.file = file }
        deinit { try? file.close() }

        static let write: SouloHLSMuxWrite = { context, bytes, count in
            guard let context, let bytes else { return false }
            let output = Unmanaged<Output>.fromOpaque(context).takeUnretainedValue()
            do {
                try output.file.write(contentsOf: Data(bytes: bytes, count: count))
                output.written += count
                return true
            } catch {
                output.failure = error
                return false
            }
        }
    }

    private let engine: OpaquePointer
    private let output: Output
    private var formats = MPEGTSExportFormats()

    private init(output: URL) throws {
        guard let url = Bundle.main.url(forResource: "mux-7.1.0.min", withExtension: "js") else {
            throw OfflineVideoConversionError.failed
        }
        let library = try String(contentsOf: url, encoding: .utf8)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = Output(file: try FileHandle(forWritingTo: output))
        let writerContext = Unmanaged.passUnretained(writer).toOpaque()
        let handle = library.withCString { script in
            Self.setupScript.withCString { setup in
                soulo_hls_mux_create(script, library.utf8.count, setup, Self.setupScript.utf8.count, Output.write, writerContext)
            }
        }
        guard let handle else { throw OfflineVideoConversionError.failed }
        self.output = writer
        engine = handle
    }

    private static let setupScript = """
            var souloMux = new muxjs.mp4.Transmuxer();
            var souloFirst = true, souloFormat = null, souloSequence = 1;
            // Read box types directly as FourCC integers.
            var mvhd = 0x6d766864, tkhd = 0x746b6864, mdhd = 0x6d646864, mfhd = 0x6d666864;
            var moov = 0x6d6f6f76, trak = 0x7472616b, mdia = 0x6d646961, moof = 0x6d6f6f66;
            function souloNormalize(bytes, initialization) {
                var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
                function boxes(start, end) {
                    while (start + 8 <= end) {
                        var size = view.getUint32(start), type = view.getUint32(start + 4);
                        if (size < 8 || start + size > end) throw new Error('Invalid box');
                        if (initialization && (type === mvhd || type === tkhd || type === mdhd)) {
                            var durationOffset = type === tkhd ? 28 : 24;
                            if (size < durationOffset + 4 || view.getUint8(start + 8) !== 0) throw new Error('Unsupported header');
                            // mux.js uses UINT32_MAX for MSE's unknown duration.
                            // A file must use zero, so AVFoundation derives it from its fragments.
                            view.setUint32(start + durationOffset, 0);
                        } else if (!initialization && type === mfhd) {
                            // Audio and video moofs share a sequence in MSE output.
                            // A single MP4 file needs an increasing sequence across both tracks.
                            if (size < 16) throw new Error('Invalid fragment header');
                            view.setUint32(start + 12, souloSequence++);
                        }
                        if (type === moov || type === trak || type === mdia || type === moof) boxes(start + 8, start + size);
                        start += size;
                    }
                    if (start !== end) throw new Error('Invalid box boundary');
                }
                boxes(0, bytes.byteLength);
                return bytes;
            }
            souloMux.on('data', function(segment) {
                var format = JSON.stringify(segment.info);
                if (souloFormat !== null && format !== souloFormat) throw new Error('Format changed');
                souloFormat = format;
                if (souloFirst) { souloWrite(souloNormalize(segment.initSegment, true)); souloFirst = false; }
                souloWrite(souloNormalize(segment.data, false));
            });
            """

    deinit { soulo_hls_mux_destroy(engine) }

    static func write(playlist: URL, output: URL, operation: FileOperationProgress, progress: Progress) throws -> Info {
        let lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
        return try write(lines: lines, bundle: playlist.deletingLastPathComponent(), output: output,
                         operation: operation, progress: progress)
    }

    /// A decoder configuration change at an HLS discontinuity cannot share
    /// the first MP4 initialization segment. Build independently decodable
    /// sections and let AVFoundation normalize them into a single track.
    static func discontinuousParts(playlist: URL, in directory: URL, operation: FileOperationProgress,
                                   progress: Progress) throws -> [Clip] {
        let lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
        let parts = lines.split(separator: "#EXT-X-DISCONTINUITY").filter { part in
            part.contains { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        guard (2...64).contains(parts.count) else { return [] }
        let sequence = lines.first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }.flatMap { UInt64($0.dropFirst(22)) } ?? 0
        let keys = lines.filter { $0.hasPrefix("#EXT-X-KEY:") }
        guard keys.count <= 1 else { return [] }
        let bundle = playlist.deletingLastPathComponent()
        let count = lines.filter({ $0.hasPrefix("#EXTINF:") }).count
        progress.completedUnitCount = 0
        progress.totalUnitCount = Int64(count)
        var offset: UInt64 = 0
        var result: [Clip] = []
        for part in parts {
            try Task.checkCancellation()
            try operation.check()
            guard sequence <= UInt64.max - offset else { throw OfflineVideoConversionError.failed }
            let section = part.filter { !$0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") && !$0.hasPrefix("#EXT-X-KEY:") }
            let video = directory.appendingPathComponent("section-\(result.count).mp4")
            let segmentCount = section.filter({ $0.hasPrefix("#EXTINF:") }).count
            guard segmentCount > 0 else { throw OfflineVideoConversionError.failed }
            let partProgress = Progress(totalUnitCount: Int64(segmentCount))
            progress.addChild(partProgress, withPendingUnitCount: Int64(segmentCount))
            let info = try write(lines: ["#EXT-X-MEDIA-SEQUENCE:\(sequence + offset)"] + keys + section,
                bundle: bundle, output: video, operation: operation, progress: partProgress)
            result.append(Clip(url: video, info: info))
            offset += UInt64(segmentCount)
        }
        return result
    }

    private static func write(lines: [String], bundle: URL, output: URL, operation: FileOperationProgress,
                              progress: Progress) throws -> Info {
        let mux = try HLSMP4Transmuxer(output: output)
        let names = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap { $0.dropFirst(8).split(separator: ",").first.flatMap { Double($0) } }
        guard names.count == durations.count, !names.isEmpty else { throw OfflineVideoConversionError.failed }
        let keyLine = lines.first { $0.hasPrefix("#EXT-X-KEY:") }
        let key = try keyLine.map { _ in try Data(contentsOf: bundle.appendingPathComponent("key.bin")) }
        if let key, key.count != 16 { throw OfflineVideoConversionError.failed }
        let iv = keyLine.flatMap { $0.components(separatedBy: "IV=").dropFirst().first }.map { String($0.prefix(34)) }
        let sequence = lines.first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }.flatMap { UInt64($0.dropFirst(22)) } ?? 0
        progress.totalUnitCount = Int64(names.count)
        var index = 0, discontinuity = false, elapsed = 0.0
        for line in lines {
            try Task.checkCancellation(); try operation.check()
            if line == "#EXT-X-DISCONTINUITY" { discontinuity = true }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard line.range(of: #"^\d{6}\.ts$"#, options: .regularExpression) != nil,
                  index < names.count, sequence <= UInt64.max - UInt64(index) else { throw OfflineVideoConversionError.failed }
            if discontinuity {
                try mux.check(soulo_hls_mux_set_decode_time(mux.engine, (elapsed * 90000).rounded()))
                discontinuity = false
            }
            let input = bundle.appendingPathComponent(line)
            guard (try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw ReadingToolError.limit }
            try autoreleasepool {
                try mux.append(input, key: key, iv: try initializationVector(iv, sequence: sequence + UInt64(index)), operation: operation)
                try mux.check(soulo_hls_mux_flush(mux.engine))
            }
            elapsed += durations[index]; index += 1
            progress.completedUnitCount = Int64(index)
        }
        guard elapsed.isFinite, elapsed > 0, mux.output.written > 0, mux.formats.hasVideo else { throw OfflineVideoConversionError.failed }
        try mux.output.file.synchronize()
        return Info(duration: elapsed, audio: mux.formats.hasAudio)
    }

    private static func initializationVector(_ value: String?, sequence: UInt64) throws -> Data {
        if let value {
            guard value.hasPrefix("0x"), value.count == 34 else { throw OfflineVideoConversionError.failed }
            let chars = Array(value.dropFirst(2))
            let bytes = stride(from: 0, to: 32, by: 2).compactMap { UInt8(String(chars[$0...($0 + 1)]), radix: 16) }
            guard bytes.count == 16 else { throw OfflineVideoConversionError.failed }
            return Data(bytes)
        }
        return Data(repeating: 0, count: 8) + withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
    }

    private func append(_ url: URL, key: Data?, iv: Data, operation: FileOperationProgress) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var cryptor: CCCryptorRef?
        if let key {
            let status = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress, &cryptor)
                }
            }
            guard status == kCCSuccess else { throw OfflineVideoConversionError.failed }
        }
        defer { if let cryptor { CCCryptorRelease(cryptor) } }
        let capacity = 64 * 1024 + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: capacity)
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); try operation.check()
            if let cryptor {
                var count = 0
                let status = chunk.withUnsafeBytes { bytes in
                    buffer.withUnsafeMutableBytes { out in
                        CCCryptorUpdate(cryptor, bytes.baseAddress, chunk.count, out.baseAddress, capacity, &count)
                    }
                }
                guard status == kCCSuccess else { throw OfflineVideoConversionError.failed }
                if count > 0 { try push(Data(buffer.prefix(count))) }
            } else { try push(chunk) }
        }
        if let cryptor {
            var count = 0
            let status = buffer.withUnsafeMutableBytes { CCCryptorFinal(cryptor, $0.baseAddress, capacity, &count) }
            guard status == kCCSuccess else { throw OfflineVideoConversionError.failed }
            if count > 0 { try push(Data(buffer.prefix(count))) }
        }
        try formats.finishSegment()
    }

    private func push(_ data: Data) throws {
        try formats.append(data)
        try data.withUnsafeBytes { buffer in
            try check(soulo_hls_mux_push(engine, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count))
        }
    }

    private func check(_ succeeded: Bool) throws {
        guard succeeded else { throw output.failure ?? OfflineVideoConversionError.failed }
    }
}

/// Read PAT/PMT sections before accepting a segment. Unknown audio/video codecs
/// must fail instead of quietly exporting a silent or incomplete movie.
private struct MPEGTSExportFormats {
    private var remainder = Data(), sections: [Int: Data] = [:], pids = Set<Int>()
    private(set) var hasVideo = false, hasAudio = false

    mutating func append(_ data: Data) throws {
        remainder.append(data)
        let count = remainder.count / 188
        let buffer = remainder
        try buffer.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for packet in 0..<count {
                let start = packet * 188
                guard bytes[start] == 0x47, bytes[start + 1] & 0x80 == 0 else { throw OfflineVideoConversionError.failed }
                let pid = Int(bytes[start + 1] & 31) << 8 | Int(bytes[start + 2])
                guard pid == 0 || pids.contains(pid) else { continue }
                let control = (bytes[start + 3] >> 4) & 3
                guard control & 1 != 0 else { continue }
                var offset = start + 4
                if control == 3 { offset += Int(bytes[offset]) + 1 }
                guard offset < start + 188 else { continue }
                if bytes[start + 1] & 0x40 != 0 {
                    let pointer = Int(bytes[offset]); offset += 1
                    guard offset + pointer <= start + 188 else { throw OfflineVideoConversionError.failed }
                    if pointer > 0, sections[pid] != nil {
                        sections[pid]!.append(contentsOf: bytes[offset..<(offset + pointer)])
                        try consume(pid)
                    }
                    offset += pointer; sections[pid] = Data()
                } else if sections[pid] == nil {
                    continue
                }
                sections[pid, default: Data()].append(contentsOf: bytes[offset..<(start + 188)])
                try consume(pid)
            }
        }
        remainder.removeFirst(count * 188)
    }

    private mutating func consume(_ pid: Int) throws {
        while var section = sections[pid], section.count >= 3, section.first != 0xff {
            let length = Int(section[1] & 15) << 8 | Int(section[2])
            guard length >= 4, length <= 1021 else { throw OfflineVideoConversionError.failed }
            guard section.count >= length + 3 else { return }
            let body = Array(section.prefix(length + 3)), end = body.count - 4
            section.removeFirst(length + 3); sections[pid] = Data(section)
            if pid == 0, body[0] == 0, end >= 8 {
                for index in stride(from: 8, to: end - 3, by: 4) where body[index] != 0 || body[index + 1] != 0 {
                    pids.insert(Int(body[index + 2] & 31) << 8 | Int(body[index + 3]))
                }
            } else if body[0] == 2, end >= 12 {
                var index = 12 + (Int(body[10] & 15) << 8 | Int(body[11]))
                var video = 0, audio = 0
                while index + 5 <= end {
                    switch body[index] {
                    case 0x1b: video += 1
                    case 0x0f: audio += 1
                    case 0x15, 0x86: break // Timed metadata, not an audio or video track.
                    default: throw OfflineVideoConversionError.failed
                    }
                    index += 5 + (Int(body[index + 3] & 15) << 8 | Int(body[index + 4]))
                }
                guard index == end, video == 1, audio <= 1 else { throw OfflineVideoConversionError.failed }
                if hasVideo, hasAudio != (audio == 1) { throw OfflineVideoConversionError.failed }
                hasVideo = true; hasAudio = audio == 1
            }
        }
        if sections[pid]?.first == 0xff { sections[pid] = nil }
    }

    func finishSegment() throws {
        guard remainder.isEmpty, hasVideo else { throw OfflineVideoConversionError.failed }
    }
}
