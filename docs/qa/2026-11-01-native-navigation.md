# WebKit navigation boundary

The user requested native Back/Forward/edge-swipe behavior and asked to stop automated device testing on 2026-11-01. The final navigation changes are compiled for manual device review; no post-change performance claim against Safari is made.

Removed from normal browsing:

- App-managed Back/Forward traversal, redirect skipping, child-frame history skipping, and cancel/reissue of a native history request.
- History recovery that called `go(to:)` again while a native transition was running.
- Cancel/reissue of ordinary main-frame links and cross-domain scripted navigations. They now keep the original WebKit request, redirect/replacement semantics, and page lifecycle. Only new-window GET requests need app routing; automatic redirects also bypass optional privacy URL/header reissue.
- Baidu result-card click interception (`preventDefault` / `stopImmediatePropagation`) and native video-detail URL replacement.
- Clearing `src` / `srcObject` and calling `load()` when leaving a web page.
- Web-view-wide media suspension for foreground navigation. Inactive-tab suspension remains separate.
- DOM-empty heuristics that reloaded an apparently blank page after navigation.
- A second six-image history cache competing with WebKit's native previews. Tab overview covers remain available.

Back and Forward buttons now call `WKWebView.goBack()` / `goForward()`. A `.backForward` policy action is allowed without URL rewriting or an extra request. WebKit's built-in swipe recognizer remains enabled. The existing iOS 26 stable-frame / obscured-insets layout is retained.

The user clarified that the first blank history page becomes the expected second page after an explicit refresh. This is evidence of a page-restoration/display failure, not proof of an unwanted empty history entry. Cancel/reissue was found in the cross-domain navigation policy and removed. After the Release build was installed on the iPhone, the user confirmed on 2026-11-01: “已经正常返回了” (Back now works normally). This confirms the reported return scenario by manual review; it does not establish broader performance or regression coverage. Existing history is not skipped or silently refreshed to mask it.

The navigation-intent observer is read-only and uses passive event listeners. Other app features still involve custom code: content-blocking rules and cosmetic hiding; optional privacy URL/header rules; video/episode tools; translation and user scripts; download interception; and `WKUIDelegate` handling for new windows and external apps. Tab suspension/cold-start restoration also remains app-managed: it recreates a WKWebView from the saved URL/cover. Page appearance/zoom/viewport synchronization is another app feature. Explicit refresh and recovery after an actual WebContent process termination still reload the page; the old DOM-empty automatic refresh is removed.

## Download and file changes in the same work

- MKV files use the pinned VideoLAN MobileVLCKit 3.7.5 decoder, isolated from web playback. Its dynamic framework is embedded and signed.
- Selected torrent media have a Play/Play While Downloading action. Partial files opened in the file manager use the same torrent stream instead of reading sparse placeholders.
- The loopback range server serves only hash-verified pieces, waits for unavailable pieces, and prioritizes bounded windows near playback/seek offsets. Playback leases keep it alive for the active player.
- The reported MP3 magnet parses successfully. During the diagnostic, OpenTrackr reported zero seeders and one leecher; OpenBitTorrent timed out. An independent libtorrent client acquired a Debian control magnet but not the reported MP3's metadata. This establishes the observed lack of an available source, not permanent invalidity of the torrent.

The earlier checks found and corrected framework embedding and Objective-C/Swift buffering-result issues. The final native-navigation change and torrent seek-resumption change were not re-tested after the user's stop-testing instruction.
