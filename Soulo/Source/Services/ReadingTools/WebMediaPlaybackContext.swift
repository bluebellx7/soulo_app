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
    private var episodeActionScope: String?
    weak var sourceWebView: WKWebView?

    init(resource: WebMediaResource, pageURL: URL?, sourceWebView: WKWebView?, episodeList: WebEpisodeList?) {
        self.resource = resource
        self.pageURL = pageURL
        self.sourceWebView = sourceWebView
        self.episodeList = episodeList
        episodePageURL = episodeList?.pageURL ?? sourceWebView?.url ?? pageURL
        episodeActionScope = episodeList?.actionScope
    }

    func accepts(_ list: WebEpisodeList) -> Bool {
        if let episodeActionScope {
            return list.actionScope == episodeActionScope && episodePageURL?.host == list.pageURL.host
                && episodePageURL?.path == list.pageURL.path
        }
        return episodePageURL.map { WebEpisodeList.matches($0, list.pageURL) } ?? true
    }

    func updateEpisodeList(_ list: WebEpisodeList?) {
        guard let list, accepts(list) else { return }
        episodeList = list
        episodeActionScope = list.actionScope
    }
}
