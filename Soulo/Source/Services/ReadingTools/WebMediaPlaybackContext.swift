import Foundation
import WebKit

/// Navigation metadata follows the live playback session rather than a player
/// page. It never enters download history or persisted browser settings.
@MainActor
final class WebMediaPlaybackContext {
    var resource: WebMediaResource
    private(set) var episodeList: WebEpisodeList?
    var selectedEpisodeID: String?
    var selectedSourceID: String?
    let pageURL: URL?
    private let episodePageURL: URL?
    weak var sourceWebView: WKWebView?

    init(resource: WebMediaResource, pageURL: URL?, sourceWebView: WKWebView?, episodeList: WebEpisodeList?) {
        self.resource = resource
        self.pageURL = pageURL
        self.sourceWebView = sourceWebView
        self.episodeList = episodeList
        episodePageURL = episodeList?.pageURL ?? sourceWebView?.url ?? pageURL
    }

    func accepts(_ list: WebEpisodeList) -> Bool {
        episodePageURL.map { WebEpisodeList.matches($0, list.pageURL) } ?? true
    }

    func updateEpisodeList(_ list: WebEpisodeList?) {
        guard let list, accepts(list) else { return }
        episodeList = list
    }
}
