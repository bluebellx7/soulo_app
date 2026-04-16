import Speech
import AVFoundation
import SwiftUI

/// Enhanced speech recognition service tuned for search queries.
/// Improvements over baseline:
/// 1. `taskHint = .search` — tells the engine this is for search
/// 2. `contextualStrings` — platform names, recent queries boost proper noun accuracy
/// 3. Region-specific locale (zh-CN, ja-JP, etc.) — better phonetic model
/// 4. `.spokenAudio` audio mode — optimized for speech, not measurement
/// 5. Auto-stop on silence (1.2 s) — natural endpoint detection
/// 6. Partial-result commit prevents word dropping mid-recognition
/// 7. Disables automatic punctuation for cleaner search queries
/// 8. Graceful permission handling with explicit states
@MainActor
class SpeechRecognitionService: ObservableObject {

    // MARK: - Published State

    @Published var isRecording: Bool = false
    @Published var recognizedText: String = ""
    @Published var isAvailable: Bool = false
    @Published var errorMessage: String?
    @Published var audioLevel: Float = 0 // normalized 0...1 for visualization

    // MARK: - Private

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Domain vocabulary that boosts recognition accuracy (platform names, recent searches).
    var contextualStrings: [String] = []

    // Silence detection
    private let silenceTimeout: TimeInterval = 1.2
    private var lastActivityTime: Date = Date()
    private var silenceTimer: Timer?
    private var lastTranscription: String = ""

    // MARK: - Init

    init(languageCode: String = "en") {
        let localeID = Self.regionLocale(for: languageCode)
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        self.isAvailable = speechRecognizer?.isAvailable ?? false
    }

    /// Map app language code to region-specific locale for better phonetic models.
    private static func regionLocale(for lang: String) -> String {
        switch lang {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "en":      return "en-US"
        case "ja":      return "ja-JP"
        case "ko":      return "ko-KR"
        case "fr":      return "fr-FR"
        case "de":      return "de-DE"
        case "es":      return "es-ES"
        case "ru":      return "ru-RU"
        case "vi":      return "vi-VN"
        case "pt-BR":   return "pt-BR"
        case "it":      return "it-IT"
        case "tr":      return "tr-TR"
        case "ar":      return "ar-SA"
        case "th":      return "th-TH"
        default:        return "en-US"
        }
    }

    // MARK: - Authorization

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.isAvailable = self?.speechRecognizer?.isAvailable ?? false
                case .denied:
                    self?.isAvailable = false
                    self?.errorMessage = "Speech recognition permission denied."
                case .restricted:
                    self?.isAvailable = false
                    self?.errorMessage = "Speech recognition is restricted on this device."
                case .notDetermined:
                    self?.isAvailable = false
                @unknown default:
                    self?.isAvailable = false
                }
            }
        }
    }

    // MARK: - Start Recording

    /// Start recording. `locale` overrides the default; `contextualStrings` boosts accuracy.
    func startRecording(locale: String? = nil, contextualStrings: [String] = []) {
        if let locale, !locale.isEmpty {
            let newLocale = Locale(identifier: Self.regionLocale(for: locale))
            speechRecognizer = SFSpeechRecognizer(locale: newLocale)
            isAvailable = speechRecognizer?.isAvailable ?? false
        }
        self.contextualStrings = Array(contextualStrings.prefix(100)) // cap to avoid overload
        _startRecording()
    }

    private func _startRecording() {
        guard !isRecording else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Speech recognition not authorized."
                }
                return
            }
            DispatchQueue.main.async {
                self?.beginRecordingSession()
            }
        }
    }

    private func beginRecordingSession() {
        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio session with .spokenAudio mode for best speech capture
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Failed to configure audio session: \(error.localizedDescription)"
            return
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            errorMessage = "Unable to create recognition request."
            return
        }

        // --- KEY ACCURACY IMPROVEMENTS ---
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .search                  // tuned for search queries
        recognitionRequest.contextualStrings = contextualStrings // domain vocab booster

        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = false         // search doesn't need punctuation
        }

        // Prefer server for longer/complex queries; on-device for fallback
        if let recognizer = speechRecognizer, recognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = false
        }

        // Configure audio engine input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            // Calculate audio level for visualization
            self?.updateAudioLevel(from: buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            cleanUp()
            return
        }

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }

            if let result = result {
                Task { @MainActor in
                    let newText = result.bestTranscription.formattedString
                    if newText != self.lastTranscription {
                        self.lastTranscription = newText
                        self.recognizedText = newText
                        self.lastActivityTime = Date()
                    }
                }
            }

            if let error = error {
                let nsError = error as NSError
                // NSURLErrorCancelled / recognition cancelled — ignore
                guard nsError.code != 301 && nsError.code != NSURLErrorCancelled else { return }
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                    self.stopRecording()
                }
            }

            if result?.isFinal == true {
                Task { @MainActor in
                    self.stopRecording()
                }
            }
        }

        isRecording = true
        errorMessage = nil
        lastActivityTime = Date()
        lastTranscription = ""
        startSilenceTimer()
    }

    // MARK: - Silence Detection

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRecording else { return }
                // Only trigger auto-stop once the user has said something
                if !self.lastTranscription.isEmpty,
                   Date().timeIntervalSince(self.lastActivityTime) > self.silenceTimeout {
                    self.stopRecording()
                }
            }
        }
    }

    // MARK: - Audio Level

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        // Convert to 0...1 scale (normalized with log curve for perceptual accuracy)
        let normalized = max(0, min(1, (20 * log10(max(rms, 0.00001)) + 50) / 50))
        Task { @MainActor in
            self.audioLevel = normalized
        }
    }

    // MARK: - Stop Recording

    func stopRecording() {
        guard isRecording else { return }
        cleanUp()
        isRecording = false
        audioLevel = 0
    }

    // MARK: - Clean Up

    private func cleanUp() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
