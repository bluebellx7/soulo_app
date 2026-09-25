import XCTest
import Speech
@testable import Soulo

final class SpeechRecognitionServiceTests: XCTestCase {
    @MainActor private final class RecordingProbe: SpeechRecognitionService {
        var starts = 0
        override func beginRecordingSession() { starts += 1 }
    }

    @MainActor
    func testDismissalCancelsPendingSpeechAuthorization() async throws {
        var reply: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
        let service = RecordingProbe(authorize: { reply = $0 })
        service.startRecording()
        XCTAssertNotNil(reply)
        service.stopRecording()
        reply?(.authorized)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(service.starts, 0, "Closing the sheet before authorization returns must not start the microphone")
    }

    @MainActor
    func testRapidStartRequestsOnlyOneAuthorization() async throws {
        var replies: [(SFSpeechRecognizerAuthorizationStatus) -> Void] = []
        let service = RecordingProbe(authorize: { replies.append($0) })
        service.startRecording()
        service.startRecording()
        XCTAssertEqual(replies.count, 1)
        replies.first?(.authorized)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(service.starts, 1, "Repeated taps must not install multiple engine taps")
    }

    @MainActor
    func testCanceledAuthorizationCannotAffectNextRecording() async throws {
        var replies: [(SFSpeechRecognizerAuthorizationStatus) -> Void] = []
        let service = RecordingProbe(authorize: { replies.append($0) })
        service.startRecording()
        service.stopRecording()
        service.startRecording()
        XCTAssertEqual(replies.count, 2)
        replies[0](.denied)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(service.starts, 0)
        replies[1](.authorized)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(service.starts, 1)
    }

    @MainActor
    func testDeniedAuthorizationAllowsAnotherAttempt() async throws {
        var replies: [(SFSpeechRecognizerAuthorizationStatus) -> Void] = []
        let service = RecordingProbe(authorize: { replies.append($0) })
        service.startRecording()
        replies[0](.denied)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(service.errorMessage)
        service.startRecording()
        XCTAssertEqual(replies.count, 2)
    }

    func testLocaleIdentifierAcceptsAppLanguageCodesAndFullLocales() {
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: "zh-Hans"), "zh-CN")
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: "zh-Hans-CN"), "zh-CN")
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: "zh_Hans_CN"), "zh-CN")
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: "zh-Hant-TW"), "zh-TW")
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: "pt-BR"), "pt-BR")
    }

    func testLocaleIdentifierFallsBackForInvalidInput() {
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: ""), "en-US")
        XCTAssertEqual(SpeechRecognitionService.localeIdentifier(for: "not-a-locale"), "en-US")
    }

    func testAutomaticLocaleUsesSystemLanguageWhenContextIsEmpty() {
        let locale = SpeechRecognitionService.automaticLocaleIdentifier(
            appLanguage: "en",
            systemLanguages: ["zh-Hans-CN"],
            contextStrings: []
        )

        XCTAssertEqual(locale, "zh-CN")
    }

    func testAutomaticLocaleUsesContextBeforeSystemLanguage() {
        let locale = SpeechRecognitionService.automaticLocaleIdentifier(
            appLanguage: "en",
            systemLanguages: ["en-US"],
            contextStrings: ["天气预报", "小红书 搜索", "附近的咖啡"]
        )

        XCTAssertEqual(locale, "zh-CN")
    }

    func testAutomaticLocaleFallsBackToAppLanguageWhenSystemLanguageIsUnsupported() {
        let locale = SpeechRecognitionService.automaticLocaleIdentifier(
            appLanguage: "ja",
            systemLanguages: ["not-a-locale"],
            contextStrings: []
        )

        XCTAssertEqual(locale, "ja-JP")
    }
}
