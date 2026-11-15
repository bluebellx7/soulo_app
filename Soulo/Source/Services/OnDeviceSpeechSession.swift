import AVFoundation
import Speech

/// Owns the microphone and analyzer together so a dismissed search cannot leave
/// a tap, a pending start, or results belonging to an earlier recording alive.
@available(iOS 26.0, *)
@MainActor
final class OnDeviceSpeechSession {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var hasTap = false
    private var canceled = false
    private var ownsAudioSession = false

    static func installedLocale(equivalentTo locale: Locale) async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == supported.identifier })
        else { return nil }
        return supported
    }

    func start(locale: Locale, onText: @escaping (String) -> Void,
               onLevel: @escaping (Float) -> Void, onFailure: @escaping () -> Void) async throws -> Bool {
        guard let supported = await Self.installedLocale(equivalentTo: locale)
        else { return false }
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        // Installed locales are shared by the system; the app still needs
        // its own reservation and module configuration registered before use.
        // The installed-locale guard above avoids fetching an absent language.
        try await AssetInventory.reserve(locale: supported)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        ownsAudioSession = true
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural),
              let converter = AVAudioConverter(from: natural, to: format) else { return false }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(12))
        input = continuation
        var committed = ""
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !self.canceled, !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                    onText(committed + text)
                    if result.isFinal { committed += text }
                }
            } catch {
                if self?.canceled == false, !Task.isCancelled { onFailure() }
            }
        }
        try await analyzer.start(inputSequence: stream)
        node.installTap(onBus: 0, bufferSize: 2048, format: natural) { [weak self] buffer, _ in
            // AVAudioEngine reuses its buffers; conversion copies each packet
            // before handing ownership to the asynchronous analyzer.
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / natural.sampleRate)) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            guard status != .error, error == nil, output.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: output))
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                let rms = sqrt(sum / Float(buffer.frameLength))
                let level = max(0, min(1, (20 * log10(max(rms, 0.00001)) + 50) / 50))
                Task { @MainActor [weak self] in
                    guard self?.canceled == false else { return }
                    onLevel(level)
                }
            }
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        return true
    }

    func cancel() {
        canceled = true
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        input?.finish(); input = nil
        results?.cancel(); results = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}
