import XCTest
import UIKit
import Speech
import FoundationModels
import AVFoundation
@testable import Soulo

@MainActor
final class DeviceFeatureAcceptanceTests: XCTestCase {
    func testPhysicalDeviceCapabilities() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device capability acceptance")
        #else
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires iOS 26") }
        let report: [String: Any] = [
            "system": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "localModel": String(describing: SystemLanguageModel.default.availability),
            "englishModelLocale": SystemLanguageModel.default.supportsLocale(Locale(identifier: "en-US")),
            "speechTranscriberAvailable": SpeechTranscriber.isAvailable,
            "installedSpeechLocales": await SpeechTranscriber.installedLocales.map(\.identifier).sorted(),
            "speechAuthorization": SFSpeechRecognizer.authorizationStatus().rawValue,
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
            "reduceMotion": UIAccessibility.isReduceMotionEnabled
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "physical-device-capabilities"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

    func testAvailableModelGeneratesThroughProductionSummary() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical on-device model")
        #else
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires iOS 26") }
        let model = SystemLanguageModel.default
        guard model.availability == .available else { throw XCTSkip("Local model: \(model.availability)") }
        let locale = Locale(identifier: "en-US")
        guard model.supportsLocale(locale) else { throw XCTSkip("English model locale unavailable") }
        let source = "Soulo supports separate browser windows on iPad. A tab can move to another window while keeping its current document. Bookmarks can be saved locally. Private pages are excluded from webpage donations. Page summaries are processed on the device."
        let result = try await PageSummaryService.summarizeLocally(text: source, locale: locale)
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(result, PageSummaryService.summarize(text: source), "Model errors must not silently count as successful generation through the extractive fallback")
        let attachment = XCTAttachment(string: result)
        attachment.name = "physical-local-model-summary"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

    func testInstalledSpeechModelTranscribesAudioFixture() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device speech model acceptance")
        #else
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechTranscriber unavailable") }
        let installedLocales = await SpeechTranscriber.installedLocales
        let candidates = [("en-US", "speech", ["browser", "bookmark"]), ("zh-CN", "speech-zh", ["浏览器", "书签"])]
        var selection: (Locale, String, [String])?
        for candidate in candidates {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: candidate.0)),
               installedLocales.contains(where: { $0.identifier == locale.identifier }) {
                selection = (locale, candidate.1, candidate.2); break
            }
        }
        guard let (locale, fixture, expectedWords) = selection else { throw XCTSkip("No installed speech locale matches an acceptance fixture") }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let installed = await AssetInventory.status(forModules: [transcriber])
        XCTAssertEqual(installed, .installed)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "wav", subdirectory: "ReadingFixtures/DeviceAcceptance"))
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let output = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal { parts.append(String(result.text.characters)) }
            return parts.joined(separator: " ")
        }
        defer { output.cancel(); Task { await analyzer.cancelAndFinishNow() } }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let text = try await output.value
        for word in expectedWords { XCTAssertTrue(text.lowercased().contains(word), text) }
        let attachment = XCTAttachment(string: text)
        attachment.name = "physical-speech-transcription"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

    func testAuthorizedMicrophoneProducesLiveBuffersAndCancels() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical microphone")
        #else
        guard #available(iOS 26.0, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechTranscriber unavailable") }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            XCTFail("Grant microphone access through the normal app before hardware acceptance")
            return
        }
        var selectedLocale: Locale?
        for identifier in ["zh-CN", "en-US"] {
            if let installed = await OnDeviceSpeechSession.installedLocale(equivalentTo: Locale(identifier: identifier)) {
                selectedLocale = installed; break
            }
        }
        let locale = try XCTUnwrap(selectedLocale, "An installed speech model is required")
        let backend = OnDeviceSpeechSession()
        defer { backend.cancel() }
        let receivedAudio = expectation(description: "Real microphone delivers an audio level")
        var levels = 0
        var failures = 0
        let started = try await backend.start(locale: locale, onText: { _ in }, onLevel: { level in
            XCTAssertTrue(level.isFinite)
            levels += 1
            if levels == 1 { receivedAudio.fulfill() }
        }, onFailure: { failures += 1 })
        XCTAssertTrue(started)
        await fulfillment(of: [receivedAudio], timeout: 3)
        backend.cancel()
        let countAtCancellation = levels
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(countAtCancellation, 0)
        XCTAssertEqual(levels, countAtCancellation, "Canceled audio taps must not publish queued levels")
        XCTAssertEqual(failures, 0)
        #endif
    }
}
