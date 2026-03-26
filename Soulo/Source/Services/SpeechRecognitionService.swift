import Speech
import AVFoundation
import SwiftUI

@MainActor
class SpeechRecognitionService: ObservableObject {

    @Published var isRecording: Bool = false
    @Published var recognizedText: String = ""
    @Published var isAvailable: Bool = false
    @Published var errorMessage: String?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private let languageCode: String

    init(languageCode: String = "en") {
        self.languageCode = languageCode
        let locale = Locale(identifier: languageCode)
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.isAvailable = speechRecognizer?.isAvailable ?? false
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

    func startRecording(locale: String? = nil) {
        // Update recognizer locale if provided
        if let locale, !locale.isEmpty {
            let newLocale = Locale(identifier: locale)
            speechRecognizer = SFSpeechRecognizer(locale: newLocale)
            isAvailable = speechRecognizer?.isAvailable ?? false
        }
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

        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
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
        recognitionRequest.shouldReportPartialResults = true

        // Configure audio engine input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
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
                    self.recognizedText = result.bestTranscription.formattedString
                }
            }

            if let error = error {
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
    }

    // MARK: - Stop Recording

    func stopRecording() {
        guard isRecording else { return }
        cleanUp()
        isRecording = false
    }

    // MARK: - Clean Up

    private func cleanUp() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
