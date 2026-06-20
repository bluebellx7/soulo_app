import XCTest
@testable import Soulo

final class SpeechRecognitionServiceTests: XCTestCase {
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
