import Foundation
import NaturalLanguage

enum ClipboardContentType: String {
    case url
    case productName
    case personName
    case generalText
}

struct ClipboardAnalyzer {
    static func analyze(_ text: String) -> (type: ClipboardContentType, suggestedPlatforms: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. URL detection
        if trimmed.isValidURL {
            return (.url, [])
        }

        // 2. Person name detection via NLTagger
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = trimmed
        var hasPersonName = false
        tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .word, scheme: .nameType) { tag, _ in
            if tag == .personalName { hasPersonName = true; return false }
            return true
        }
        if hasPersonName {
            return (.personName, ["platform_weibo", "platform_twitter", "platform_google", "platform_baidu"])
        }

        // 3. Product name heuristics
        let productKeywords = ["iPhone", "iPad", "MacBook", "Samsung", "Nike", "Adidas",
                               "手机", "电脑", "耳机", "平板", "相机", "鞋", "包"]
        let hasProductKeyword = productKeywords.contains { trimmed.localizedCaseInsensitiveContains($0) }
        if hasProductKeyword {
            return (.productName, ["platform_taobao", "platform_jd", "platform_amazon", "platform_google"])
        }

        // 4. General text
        return (.generalText, [])
    }
}
