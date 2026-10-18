import Foundation

public struct LocalAIPageLink: Codable, Identifiable, Sendable, Equatable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public init(title: String, url: URL) { self.title = title; self.url = url }
}

public struct LocalAILinkResult: Codable, Sendable {
    public let links: [LocalAIPageLink]
    public let sourceURL: URL
    public let filter: String
    public let limited: Bool
    public init(links: [LocalAIPageLink], sourceURL: URL, filter: String, limited: Bool) {
        self.links = links; self.sourceURL = sourceURL; self.filter = filter; self.limited = limited
    }
}

