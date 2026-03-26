import Foundation
import NaturalLanguage

struct TranslationService {
    // Detect dominant language
    static func detectLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    static func isChineseInput(_ text: String) -> Bool {
        guard let lang = detectLanguage(text) else { return false }
        return [.simplifiedChinese, .traditionalChinese].contains(lang)
    }

    static func isEnglishInput(_ text: String) -> Bool {
        detectLanguage(text) == .english
    }

    // Simple built-in dictionary for common search terms (top ~200 pairs)
    private static let enToCn: [String: String] = [
        "phone": "手机", "computer": "电脑", "laptop": "笔记本电脑", "tablet": "平板",
        "headphone": "耳机", "camera": "相机", "watch": "手表", "shoes": "鞋子",
        "clothes": "衣服", "bag": "包", "car": "汽车", "food": "美食",
        "restaurant": "餐厅", "hotel": "酒店", "travel": "旅行", "movie": "电影",
        "music": "音乐", "game": "游戏", "book": "书", "news": "新闻",
        "weather": "天气", "recipe": "食谱", "workout": "健身", "yoga": "瑜伽",
        "makeup": "化妆", "skincare": "护肤", "hairstyle": "发型", "fashion": "时尚",
        "coding": "编程", "programming": "编程", "design": "设计", "tutorial": "教程",
        "review": "评测", "compare": "对比", "price": "价格", "cheap": "便宜",
        "best": "最好", "top": "排行", "how to": "怎么", "what is": "是什么",
        "why": "为什么", "iphone": "iPhone", "samsung": "三星", "tesla": "特斯拉",
        "bitcoin": "比特币", "stock": "股票", "investment": "投资",
    ]

    private static let cnToEn: [String: String] = {
        var reversed: [String: String] = [:]
        for (en, cn) in enToCn { reversed[cn] = en }
        // Add extra Chinese-specific terms
        reversed["手机"] = "phone"
        reversed["电脑"] = "computer"
        reversed["好吃"] = "delicious food"
        reversed["好看"] = "beautiful"
        reversed["推荐"] = "recommendation"
        reversed["攻略"] = "guide"
        reversed["干货"] = "useful tips"
        return reversed
    }()

    static func translate(_ text: String) -> (translated: String, targetLanguageName: String)? {
        let isChinese = isChineseInput(text)
        let isEnglish = isEnglishInput(text)

        if isChinese {
            // Try dictionary lookup
            let lower = text.lowercased()
            if let translation = cnToEn[lower] ?? cnToEn[text] {
                return (translation, "English")
            }
            return nil
        } else if isEnglish {
            let lower = text.lowercased()
            if let translation = enToCn[lower] {
                return (translation, "中文")
            }
            // Try word-by-word for multi-word queries
            let words = lower.split(separator: " ").map(String.init)
            let translated = words.map { enToCn[$0] ?? $0 }
            let result = translated.joined(separator: "")
            if result != lower.replacingOccurrences(of: " ", with: "") {
                return (result, "中文")
            }
            return nil
        }
        return nil
    }
}
