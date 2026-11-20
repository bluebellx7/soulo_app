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
                          operation: FileOperationProgress = FileOperationProgress()) async throws -> URL {
        try await MediaExportBackgroundService.shared.perform(progress: operation.progress) {
            try await exportNativeMP4(from: source, into: directory, preferredFilename: preferredFilename, operation: operation)
        }
    }

    private static func exportNativeMP4(from source: URL, into directory: URL,
                                       preferredFilename: String?,
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
        let work = Task.detached(priority: .userInitiated) {
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
            return try HLSMP4Transmuxer.write(bundle: bundle, output: fragmented, operation: operation, progress: muxing)
        }
        operation.progress.cancellationHandler = { work.cancel() }
        defer { operation.progress.cancellationHandler = nil }
        let info = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try check(operation)
        let output = scratch.appendingPathComponent("output.mp4")
        try await flatten(fragmented, to: output, operation: operation, progress: finishing)
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

    private static func flatten(_ source: URL, to target: URL, operation: FileOperationProgress, progress: Progress) async throws {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isExportable), let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.mp4) else { throw OfflineVideoConversionError.failed }
        session.outputURL = target; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
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
        guard try await asset.load(.isPlayable), duration.isFinite, duration > 0,
              abs(duration - info.duration) <= max(0.5, info.duration * 0.0001), video.count == 1,
              audio.count == (info.audio ? 1 : 0) else { throw OfflineVideoConversionError.failed }
        for track in video + audio {
            guard !(try await track.load(.formatDescriptions)).isEmpty else { throw OfflineVideoConversionError.failed }
        }
    }
}

/// One synchronous worker runs the bundled script in an interpreter without JIT.
/// Only media chunks cross the bridge. The worker owns the destination file.
private final class HLSMP4Transmuxer {
    struct Info: Sendable { let duration: Double; let audio: Bool }
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

    static func write(bundle: URL, output: URL, operation: FileOperationProgress, progress: Progress) throws -> Info {
        let mux = try HLSMP4Transmuxer(output: output)
        let lines = try String(contentsOf: bundle.appendingPathComponent("index.m3u8"), encoding: .utf8).components(separatedBy: .newlines)
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
