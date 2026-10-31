# Downloads and navigation verification — 2026-10-31

Version: 1.2.7 (51). Xcode 26.2; iPhone 17 simulator, iOS 26.2.

## Delivered behavior

- Native BitTorrent v1/v2 downloads using pinned libtorrent 2.0.15 and OpenSSL 3.6.5. Users can create HTTP, magnet or remote torrent tasks, import local `.torrent` files, select payload files, pause/resume/retry and remove tasks. Progress, speed, peers and persisted resume data are real engine state.
- iOS 26 continued processing requests cover user-started torrent work when the system permits. Expiration saves resume data and pauses; older iOS versions save and pause on backgrounding. No audio keepalive is used. Actual device scheduling remains to be checked on a signed build; simulator checks do not establish uninterrupted background execution.
- Four configurable home shortcuts, empty by default, with smaller glass buttons; settings uses a single disclosure arrow. Library tabs contract on scroll with unchanged text size, compact 36-point faces and 4 points below the selected background.
- Each built-in/custom group has an editable fallback engine independent of visible platforms. All-disabled configurations still support home/new-tab searches and opening saved URLs after relaunch. Built-in defaults are Baidu, Google, Google Japan, Google Korea and Yandex. New custom groups use Baidu for Chinese app languages and Google otherwise.
- Kimi uses its current Lexical editor and dedicated send control. The migration respects an all-disabled configuration. Pending interactions cancel on leaving/replacing the page, and disabled send controls are respected.
- Batch import opens `https://soulo.dkluge.com/sources.html` as its example and initially selects a new, named group. Existing names receive a numeric suffix.
- Back/forward restoration bypasses request URL/header rewriting, preserving original history entries and unsaved form state. Fresh navigations still apply configured privacy transformations. Long-press recognition immediately excludes the two 24-point history-swipe edges. The inactive fullscreen-reveal gesture uses `.subviews` so child gestures remain enabled, following [Apple GestureMask semantics](https://developer.apple.com/documentation/swiftui/gesturemask/subviews).
- Long-press image viewing gains ordered, deduplicated paging, original-image links, image count and a Web Resources action. The selected frame's referrer and fetch context stay attached to its images. Only the active full-size page is decoded; zoomed images pan internally and fit-scale images page horizontally.

## Evidence

Validation uses an isolated checkout of the task's staged files, excluding unrelated local work. `project.yml` was regenerated with XcodeGen.

- Generic iOS device build with `CODE_SIGNING_ALLOWED=NO`: passed.
- `TorrentDownloadTests`: metadata validation, actual local peer transfers, magnet metadata → file selection → payload download, pause/restart/resume and path rejection passed. Test discovery is isolated from public DHT traffic.
- `NewDownloadTaskUITests`: HTTP transfer, invalid input/cancel and torrent selection/removal passed.
- `GroupDefaultSearchTests`, `HomeToolbarConfigurationTests`, `KimiInteractionTests` and library scroll-collapse tests passed.
- `HomeToolbarUITests`: four shortcuts persist and open their pages, passed. Library paging/selection/left-edge dismissal and row/folder state tests passed.
- All-platforms-disabled UI flow: home search, new-tab search, direct URL, saved bookmark and relaunch/open passed.
- Real Kimi DOM probe: query appears once and its send control receives one attempted click. The probe intercepted that click, so it sent no live AI message. Account-authenticated behavior still depends on the site's login/session state.
- `HistoryRestorationTests`: changed privacy preferences do not replace history, lose a draft, or discard forward navigation, passed.
- `WebImageGalleryTests`: DOM order, deduplication, thumbnail-to-original selection, lazy images and unavailable-source fallback passed.
- `GroupDefaultSearchUITests`: default engine editing, invalid-template rejection, saving/restoring an engine, and the named new-group import default passed.
- `WebImageGalleryUITests`: long press → selected second image → third image → double-tap zoom/reset → previous image → Web Resources passed.

Physical edge-swipe motion remains a real-device check. On this simulator, synthesized edge drags also failed to navigate in a standalone, unmodified UIKit `WKWebView` control with `allowsBackForwardNavigationGestures = true` and no Soulo code (`PlainWebKitControl.xcresult`). This establishes a limitation of this automated acceptance path, not that real-device swipe performance is verified. Automated app acceptance therefore uses the public `goBack`/`goForward` restoration regression; the synthesized drag is recorded as unverified, not passed. Manual check: browse two pages, cancel a short edge drag, then complete a drag after editing a form; verify the draft, scroll position and forward history in normal and fullscreen modes.

Local result bundles: `FinalVerification.xcresult`, `SearchUIFinal.xcresult`, `ImageNavigationVerification.xcresult`, `LastInteractionVerification.xcresult`, and `FinalImageAndHistory.xcresult` under `/tmp/soulo-torrent-20261031/`. Each result is reported by individual case; earlier failed UI fixture attempts are superseded only by passing cases.

## Metadata and dependency checks

All 50 metadata source locales have updated descriptions and release notes. Their names, subtitles, promotional text and keywords remain within limits and were checked by the exporter. `python3 scripts/export_metadata_json.py --check` and `python3 scripts/check_localization.py --strict` passed. The generated JSON version equals `MARKETING_VERSION` (1.2.7). No zero-width-character warnings were reported.

`ThirdParty/SouloTorrent/artifacts.json` SHA-256 digests match the shipped device/simulator libraries and CA bundle. Rebuild instructions and pinned source digests are in [the native package](../../ThirdParty/SouloTorrent/README.md). Third-party notices ship in the app and its licenses page.

Adding OpenSSL changes the encryption inventory. The app target's previous hard-coded `ITSAppUsesNonExemptEncryption = false` was removed; App Store Connect may request encryption classification answers when uploading. No exemption is asserted. See [Apple export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).
