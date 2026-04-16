import Foundation

/// Fetches live search suggestions from region-appropriate search engines.
/// All endpoints are free, no API key required, and return results in ~100ms.
enum SearchSuggestionService {

    // MARK: - Public API

    /// Fetch autocomplete suggestions for the given query.
    /// Respects task cancellation, so callers can cancel stale requests.
    static func fetch(query: String, region: PlatformRegion) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Select provider based on user's region
        let provider = Provider.forRegion(region)

        do {
            let results = try await provider.fetch(query: trimmed)
            // Dedupe (case-insensitive), remove empty, cap at 8
            return dedupe(results).prefix(8).map { $0 }
        } catch {
            return []
        }
    }

    // MARK: - Dedupe

    private static func dedupe(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}

// MARK: - Provider

private enum Provider {
    case baidu
    case google
    case yandex
    case naver

    static func forRegion(_ region: PlatformRegion) -> Provider {
        switch region {
        case .china:  return .baidu
        case .russia: return .yandex
        case .japan, .international: return .google
        }
    }

    func fetch(query: String) async throws -> [String] {
        switch self {
        case .baidu:   return try await Self.fetchBaidu(query: query)
        case .google:  return try await Self.fetchGoogle(query: query)
        case .yandex:  return try await Self.fetchYandex(query: query)
        case .naver:   return try await Self.fetchNaver(query: query)
        }
    }

    // MARK: - Baidu (JSONP)

    /// Baidu returns: `window.baidu.sug({q:"xx",p:false,s:["sug1","sug2"]});`
    private static func fetchBaidu(query: String) async throws -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestion.baidu.com/su?wd=\(encoded)&cb=&t=\(Int(Date().timeIntervalSince1970 * 1000))")
        else { return [] }

        let data = try await request(url: url)
        // Baidu returns GBK sometimes; try UTF-8 first, fall back to GBK (via CFStringConvertEncoding)
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            let cfEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            text = String(data: data, encoding: String.Encoding(rawValue: cfEncoding)) ?? ""
        }
        guard !text.isEmpty else { return [] }

        // Extract the s:[...] array from the JSONP wrapper
        guard let start = text.range(of: "s:["), let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else {
            return []
        }
        let arrayContent = text[start.upperBound..<end.lowerBound]
        // Split by commas, trim quotes
        return arrayContent
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Google

    /// Google returns: `["query",["sug1","sug2",...]]`
    private static func fetchGoogle(query: String) async throws -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)")
        else { return [] }

        let data = try await request(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let suggestions = json[1] as? [String]
        else { return [] }
        return suggestions
    }

    // MARK: - Yandex

    /// Yandex returns: `["query",["sug1","sug2"],[types],[descriptions]]`
    private static func fetchYandex(query: String) async throws -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggest.yandex.com/suggest-ff.cgi?part=\(encoded)")
        else { return [] }

        let data = try await request(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 2,
              let suggestions = json[1] as? [String]
        else { return [] }
        return suggestions
    }

    // MARK: - Naver (Korean)

    /// Naver returns complex nested JSON; we take the first items array.
    private static func fetchNaver(query: String) async throws -> [String] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://ac.search.naver.com/nx/ac?q=\(encoded)&st=100&r_format=json&r_enc=UTF-8&r_lt=1")
        else { return [] }

        let data = try await request(url: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[[Any]]],
              let firstList = items.first
        else { return [] }
        return firstList.compactMap { ($0.first as? String) }
    }

    // MARK: - Network helper with fast timeout

    private static func request(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.5 // suggestions must be fast
        req.setValue("Mozilla/5.0 (iPhone) Soulo/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
