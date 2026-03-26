import Foundation
import NaturalLanguage

struct PageSummaryService {
    static func summarize(text: String, maxSentences: Int = 4) -> String {
        // --- Step 1: Better text cleaning ---
        let rawLines = text.components(separatedBy: .newlines)
        var seenLines = Set<String>()
        var cleanedLines: [String] = []
        let junkPattern = try? NSRegularExpression(pattern: "^[\\d\\s\\p{P}\\p{S}]+$")

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove lines shorter than 20 chars (navigation/menu items)
            guard trimmed.count >= 20 else { continue }
            // Remove lines that are just numbers/symbols
            if let junkPattern = junkPattern,
               junkPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                continue
            }
            // Remove duplicate lines
            let normalized = trimmed.lowercased()
            guard !seenLines.contains(normalized) else { continue }
            seenLines.insert(normalized)
            cleanedLines.append(trimmed)
        }

        let cleaned = cleanedLines.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        // --- Step 2: Split into sentences ---
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            let sentence = String(cleaned[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 20 { sentences.append(sentence) }
            return true
        }

        guard !sentences.isEmpty else { return String(cleaned.prefix(500)) }

        // --- Step 3: Extract a title (first sentence between 20-100 chars) ---
        let title = sentences.first(where: { $0.count >= 20 && $0.count <= 100 }) ?? sentences[0]

        // --- Step 4: TF-IDF-like keyword frequency scoring ---
        // Build word frequency map across all sentences
        let wordTokenizer = NLTokenizer(unit: .word)
        var globalWordFreq: [String: Int] = [:]
        var sentenceWords: [[String]] = []

        for sentence in sentences {
            wordTokenizer.string = sentence
            var words: [String] = []
            wordTokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
                let word = String(sentence[range]).lowercased()
                if word.count > 2 { // skip very short words
                    words.append(word)
                    globalWordFreq[word, default: 0] += 1
                }
                return true
            }
            sentenceWords.append(words)
        }

        // Score each sentence: sum of word frequencies / sentence word count
        var scored: [(index: Int, sentence: String, score: Double)] = []
        for (i, sentence) in sentences.enumerated() {
            // Skip the title sentence from key points
            if sentence == title { continue }

            let words = sentenceWords[i]
            guard !words.isEmpty else { continue }

            let freqSum = words.reduce(0.0) { $0 + Double(globalWordFreq[$1] ?? 0) }
            let tfScore = freqSum / Double(words.count)
            let positionBonus = i < 3 ? 0.3 : (i < 6 ? 0.1 : 0)
            scored.append((i, sentence, tfScore + positionBonus))
        }

        // --- Step 5: Build structured output (1 title + up to 4 key points) ---
        let topSentences = scored.sorted { $0.score > $1.score }
            .prefix(min(maxSentences, 4))
            .sorted { $0.index < $1.index }

        var result = "\u{1F4CC} \(title)"
        if !topSentences.isEmpty {
            result += "\n"
            for (idx, item) in topSentences.enumerated() {
                result += "\n\(idx + 1). \(item.sentence)"
            }
        }
        return result
    }
}
