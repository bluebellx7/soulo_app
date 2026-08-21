import Foundation
import UniformTypeIdentifiers

struct WebImageResource: Identifiable, Hashable {
    let url: URL
    let width: Int
    let height: Int
    let title: String

    var id: String { url.absoluteString }
}

struct WebMediaResource: Identifiable, Hashable {
    enum Kind: String {
        case video
        case audio
    }

    enum Delivery: String {
        case direct
        case hls
        case dash
        case youtubeSABR
        case separateTracks
    }

    let kind: Kind
    let url: URL
    let title: String
    let posterURL: URL?
    let delivery: Delivery
    let companionAudioURL: URL?

    init(
        kind: Kind,
        url: URL,
        title: String,
        posterURL: URL?,
        delivery: Delivery = .direct,
        companionAudioURL: URL? = nil
    ) {
        self.kind = kind
        self.url = url
        self.title = title
        self.posterURL = posterURL
        self.delivery = delivery
        self.companionAudioURL = companionAudioURL
    }

    var id: String { "\(kind.rawValue):\(url.absoluteString)" }

    var suggestedFilename: String {
        let decodedPathName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let defaultName = title.isEmpty ? (kind == .video ? "Video" : "Audio") : title
        let baseName = delivery == .youtubeSABR
            ? defaultName
            : (decodedPathName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? defaultName
                : decodedPathName)
        guard (baseName as NSString).pathExtension.isEmpty,
              let mediaExtension else {
            return baseName
        }
        return "\(baseName).\(mediaExtension)"
    }

    private var mediaExtension: String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let mimeValue = components.queryItems?
            .first(where: {
                ["mime", "mime_type", "type", "content-type", "content_type"]
                    .contains($0.name.lowercased())
            })?
            .value?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        let normalizedMIMEValue = mimeValue.map { value in
            if value.contains("/") { return value }
            if let separator = value.firstIndex(where: { $0 == "_" || $0 == "-" }) {
                return "\(value[..<separator])/\(value[value.index(after: separator)...])"
            }
            return value
        }
        if let normalizedMIMEValue,
           let filenameExtension = UTType(mimeType: normalizedMIMEValue)?.preferredFilenameExtension {
            return filenameExtension
        }
        return kind == .video ? "mp4" : "m4a"
    }
}

struct WebLinkResource: Identifiable, Hashable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

struct WebTextResource: Identifiable, Hashable {
    let text: String

    var id: String { text }
}

struct WebColorResource: Identifiable, Hashable {
    let value: String
    let count: Int

    var id: String { value }
}

struct WebDocumentResource: Identifiable, Hashable {
    let url: URL
    let title: String

    var id: String { url.absoluteString }
}

struct WebResourceSnapshot {
    let pageTitle: String
    let pageURL: URL?
    let images: [WebImageResource]
    let videos: [WebMediaResource]
    let audio: [WebMediaResource]
    let links: [WebLinkResource]
    let textFragments: [WebTextResource]
    let colors: [WebColorResource]
    let documents: [WebDocumentResource]

    static let empty = WebResourceSnapshot(
        pageTitle: "",
        pageURL: nil,
        images: [],
        videos: [],
        audio: [],
        links: [],
        textFragments: [],
        colors: [],
        documents: []
    )

    var isEmpty: Bool {
        images.isEmpty
            && videos.isEmpty
            && audio.isEmpty
            && links.isEmpty
            && textFragments.isEmpty
            && colors.isEmpty
            && documents.isEmpty
    }

    init(
        pageTitle: String,
        pageURL: URL?,
        images: [WebImageResource],
        videos: [WebMediaResource],
        audio: [WebMediaResource],
        links: [WebLinkResource],
        textFragments: [WebTextResource],
        colors: [WebColorResource],
        documents: [WebDocumentResource]
    ) {
        self.pageTitle = pageTitle
        self.pageURL = pageURL
        self.images = images
        self.videos = videos
        self.audio = audio
        self.links = links
        self.textFragments = textFragments
        self.colors = colors
        self.documents = documents
    }

    init(dictionary: [String: Any]) {
        pageTitle = dictionary["pageTitle"] as? String ?? ""
        pageURL = (dictionary["pageURL"] as? String).flatMap(URL.init(string:))

        images = Self.unique((dictionary["images"] as? [[String: Any]] ?? []).compactMap { value in
            guard let url = Self.webURL(value["url"] as? String) else { return nil }
            return WebImageResource(
                url: url,
                width: Self.integer(value["width"]),
                height: Self.integer(value["height"]),
                title: Self.cleanText(value["title"] as? String)
            )
        }, id: \.id)

        videos = Self.mediaResources(dictionary["videos"], kind: .video)
        audio = Self.mediaResources(dictionary["audio"], kind: .audio)

        links = Self.uniqueLinks((dictionary["links"] as? [[String: Any]] ?? []).compactMap { value in
            guard let url = Self.webURL(value["url"] as? String) else { return nil }
            return WebLinkResource(
                url: url,
                title: Self.cleanText(value["title"] as? String)
            )
        })

        textFragments = Self.unique((dictionary["texts"] as? [String] ?? []).compactMap { value in
            let text = Self.cleanText(value)
            return text.isEmpty ? nil : WebTextResource(text: text)
        }, id: \.id)

        colors = Self.unique((dictionary["colors"] as? [[String: Any]] ?? []).compactMap { value in
            guard let color = value["value"] as? String, !color.isEmpty else { return nil }
            return WebColorResource(value: color.uppercased(), count: Self.integer(value["count"]))
        }, id: \.id)

        documents = Self.unique((dictionary["documents"] as? [[String: Any]] ?? []).compactMap { value in
            guard let url = Self.webURL(value["url"] as? String) else { return nil }
            return WebDocumentResource(
                url: url,
                title: Self.cleanText(value["title"] as? String)
            )
        }, id: \.id)
    }

    private static func mediaResources(_ rawValue: Any?, kind: WebMediaResource.Kind) -> [WebMediaResource] {
        unique((rawValue as? [[String: Any]] ?? []).compactMap { value in
            guard let url = webURL(value["url"] as? String) else { return nil }
            return WebMediaResource(
                kind: kind,
                url: url,
                title: cleanText(value["title"] as? String),
                posterURL: webURL(value["poster"] as? String),
                delivery: WebMediaResource.Delivery(
                    rawValue: value["delivery"] as? String ?? ""
                ) ?? inferredDelivery(for: url),
                companionAudioURL: webURL(value["audioURL"] as? String)
            )
        }, id: \.id)
    }

    private static func inferredDelivery(for url: URL) -> WebMediaResource.Delivery {
        let value = url.absoluteString.lowercased()
        if value.contains(".m3u8") { return .hls }
        if value.contains(".mpd") { return .dash }
        return .direct
    }

    private static func webURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private static func cleanText(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func unique<Element, ID: Hashable>(
        _ values: [Element],
        id: KeyPath<Element, ID>
    ) -> [Element] {
        var seen = Set<ID>()
        return values.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private static func uniqueLinks(_ values: [WebLinkResource]) -> [WebLinkResource] {
        var seen = Set<String>()
        return values.filter { seen.insert(normalizedLinkKey($0.url)).inserted }
    }

    private static func normalizedLinkKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }

        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        } else if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        return components.string ?? url.absoluteString
    }
}

struct WebContextResource: Equatable {
    enum Kind: String {
        case image
        case video
        case audio
        case file

        var allowsDirectDownload: Bool {
            true
        }
    }

    let kind: Kind
    let url: URL
    let suggestedFilename: String

    init?(dictionary: [String: Any]) {
        guard let rawKind = dictionary["kind"] as? String,
              let kind = Kind(rawValue: rawKind),
              let urlString = dictionary["url"] as? String,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        self.kind = kind
        self.url = url
        suggestedFilename = (dictionary["filename"] as? String) ?? url.lastPathComponent
    }
}
