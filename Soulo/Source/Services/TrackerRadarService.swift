import Foundation
import Compression
import CryptoKit

struct TrackerRadarService {
    static let shared = TrackerRadarService()

    private let trackersByDomain: [String: TrackerRadarEntry]

    init(data: Data? = nil, bundle: Bundle = .main) {
        let sourceData = data
            ?? TrackerRadarResource.load(in: bundle)
        if let sourceData,
           let decoded = try? JSONDecoder().decode(TrackerRadarRoot.self, from: sourceData) {
            trackersByDomain = decoded.trackers.reduce(into: [:]) { result, pair in
                result[Self.normalizedHost(pair.key)] = pair.value
            }
        } else {
            trackersByDomain = [:]
        }
    }

    func classify(observation: ResourceObservation, protectionEnabled: Bool) -> TrackerRequest? {
        guard let requestURL = URL(string: observation.urlString),
              let pageURL = URL(string: observation.pageURLString),
              let requestHost = requestURL.host else {
            return nil
        }

        let requestETLDplus1 = Self.registrableDomain(for: requestHost)
        let pageETLDplus1 = Self.registrableDomain(for: pageURL.host ?? "")
        guard !requestETLDplus1.isEmpty, requestETLDplus1 != pageETLDplus1 else {
            return nil
        }

        let trackerMatch = trackerEntry(for: requestHost)
        let pageOwner = trackerEntry(for: pageURL.host ?? "")?.owner?.displayNameOrName
        let ownerName = trackerMatch?.owner?.displayNameOrName ?? requestETLDplus1
        let state: TrackerRequestState

        if let trackerMatch {
            if trackerMatch.defaultAction == "block", protectionEnabled {
                state = .blocked
            } else if !protectionEnabled {
                state = .allowedProtectionDisabled
            } else if pageOwner == ownerName {
                state = .allowedOwnedByFirstParty
            } else {
                state = .allowedOtherThirdPartyRequest
            }
        } else if pageOwner == ownerName {
            state = .allowedOwnedByFirstParty
        } else {
            state = .allowedOtherThirdPartyRequest
        }

        return TrackerRequest(
            urlString: observation.urlString,
            host: Self.normalizedHost(requestHost),
            eTLDplus1: requestETLDplus1,
            pageURLString: observation.pageURLString,
            ownerName: ownerName,
            entityName: ownerName,
            category: Self.category(from: trackerMatch?.categories ?? []),
            prevalence: trackerMatch?.prevalence,
            state: state
        )
    }

    func trackerEntry(for host: String) -> TrackerRadarEntry? {
        let cleanHost = Self.normalizedHost(host)
        guard !cleanHost.isEmpty else { return nil }
        var labels = cleanHost.split(separator: ".")
        while labels.count >= 2 {
            let candidate = labels.joined(separator: ".")
            if let entry = trackersByDomain[candidate] {
                return entry
            }
            labels.removeFirst()
        }
        return trackersByDomain[cleanHost]
    }

    static func category(from categories: [String]) -> TrackerCategory {
        let combined = categories.joined(separator: " ").lowercased()
        if combined.contains("advertis") || combined.contains("ad motivated") || combined.contains("ad fraud") {
            return .advertising
        }
        if combined.contains("analytics") || combined.contains("audience") || combined.contains("measurement") {
            return .analytics
        }
        if combined.contains("social") {
            return .social
        }
        if combined.contains("content") {
            return .content
        }
        return .unknown
    }

    static func registrableDomain(for host: String) -> String {
        let cleanHost = normalizedHost(host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !cleanHost.isEmpty, !cleanHost.contains(":") else { return cleanHost }
        let labels = cleanHost.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return cleanHost }

        let publicSuffixLikePairs: Set<String> = [
            "co.uk", "org.uk", "ac.uk", "gov.uk",
            "com.au", "net.au", "org.au",
            "co.jp", "ne.jp", "or.jp",
            "com.cn", "net.cn", "org.cn",
            "com.br", "com.mx"
        ]
        let suffix = labels.suffix(2).joined(separator: ".")
        if publicSuffixLikePairs.contains(suffix), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}

/// The shared service decodes this once. Request classification uses the
/// existing in-memory map; compressed data is never read on each web request.
enum TrackerRadarResource {
    static let magic = Data("SOULOTR1".utf8)
    static let headerSize = 48
    static let maximumDecodedSize = 16 * 1024 * 1024

    static func load(in bundle: Bundle) -> Data? {
        if let url = bundle.url(forResource: "trackerData", withExtension: "lzfse"),
           let payload = try? Data(contentsOf: url), let original = decode(payload) {
            return original
        }
        // Retain compatibility with raw-data fixture and older resource bundles.
        return bundle.url(forResource: "trackerData", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }

    static func decode(_ payload: Data) -> Data? {
        guard payload.count > headerSize, payload.prefix(8) == magic else { return nil }
        let start = payload.startIndex
        let size = payload[(start + 8)..<(start + 16)].enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        guard size > 0, size <= UInt64(maximumDecodedSize) else { return nil }
        var original = Data(count: Int(size))
        let decoded = original.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, Int(size),
                    source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: headerSize),
                    payload.count - headerSize, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == Int(size), Data(SHA256.hash(data: original)) == payload[(start + 16)..<(start + headerSize)] else { return nil }
        return original
    }
}

struct TrackerRadarRoot: Decodable {
    let trackers: [String: TrackerRadarEntry]
}

struct TrackerRadarEntry: Decodable {
    let domain: String?
    let owner: TrackerRadarOwner?
    let prevalence: Double?
    let categories: [String]
    let defaultAction: String?

    enum CodingKeys: String, CodingKey {
        case domain
        case owner
        case prevalence
        case categories
        case defaultAction = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        owner = try container.decodeIfPresent(TrackerRadarOwner.self, forKey: .owner)
        prevalence = try container.decodeIfPresent(Double.self, forKey: .prevalence)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        defaultAction = try container.decodeIfPresent(String.self, forKey: .defaultAction)
    }
}

struct TrackerRadarOwner: Decodable {
    let name: String?
    let displayName: String?

    var displayNameOrName: String {
        displayName ?? name ?? ""
    }
}
