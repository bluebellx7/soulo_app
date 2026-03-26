import Foundation
import NaturalLanguage
import UIKit

struct SpellCorrectionService {
    static func suggest(for keyword: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(keyword)
        guard let lang = recognizer.dominantLanguage else { return nil }

        // Skip spell check for Chinese, Japanese, Korean
        if [.simplifiedChinese, .traditionalChinese, .japanese, .korean].contains(lang) {
            return nil
        }

        let checker = UITextChecker()
        let range = NSRange(location: 0, length: keyword.utf16.count)
        let langCode = lang == .english ? "en" : lang.rawValue

        let misspelledRange = checker.rangeOfMisspelledWord(
            in: keyword, range: range, startingAt: 0, wrap: false, language: langCode
        )

        guard misspelledRange.location != NSNotFound else { return nil }

        let guesses = checker.guesses(forWordRange: misspelledRange, in: keyword, language: langCode)
        guard let firstGuess = guesses?.first else { return nil }

        // Replace the misspelled word with the suggestion
        let nsString = keyword as NSString
        return nsString.replacingCharacters(in: misspelledRange, with: firstGuess)
    }
}
