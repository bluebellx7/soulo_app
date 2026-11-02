# eD2K, package size and download form

## Changes

- Added native eD2K server/Kad source discovery and downloads, connected to the existing download list, pause/resume, deletion and background checkpoint coordinator. The pinned Go engine is isolated from web playback/navigation. The app starts its networking only for active eD2K work.
- Added eD2K/thunder parsing, UTF-8/legacy text decoding, 64-bit file sizes and safe filenames. A thunder wrapper can resolve to eD2K, HTTP/HTTPS or BT magnet links. The engine independently checks the final file hash before reporting completion.
- Added atomic resume checkpoints, queued disk-operation draining, and rechecking cached verified pieces if the file changed after its checkpoint. Checkpoints count as outstanding background work until they finish.
- The new-download form dismisses its keyboard on blank taps, places a full-width blue creation button at the bottom and moves local torrent-file import into the top toolbar. The file-type toggle is removed. Recognizable `.torrent` URLs open directly; ambiguous background downloads are checked after their single transfer and valid metadata creates a BT task. Normal downloads are not consumed by a probing GET.
- The shared keyboard behavior also covers platform editing/creation, group search settings, batch import, feedback and script editing. It leaves editor touches, embedded web content and other controls' gestures intact.
- Bilibili video/bangumi/festival HTTPS links (and b23.tv links) to an installed Bilibili app now use the app-jump confirmation route. The user can choose to open the web page. Ordinary web navigation and native Back/Forward remain unchanged. Exact host checks exclude lookalike domains and media CDN subresources.
- Video controls now receive native scroll-view zoom directly. Their sizing gives that value precedence over `visualViewport.scale`, which can be stale during page-cache restoration. This removes the extra async scale-read round trip and prevents that old value overriding the supplied native scale.

## Size reduction

The previous local Release app directory used about 159 MiB on disk; the final build including eD2K uses about 72 MiB. Summed file lengths are 165,501,746 → 74,191,253 bytes (157.83 → 70.75 MiB), a 55.17% reduction. This is a local bundle comparison, not an App Store download-size report. All 55 bundle localization directories are retained (the strict app-localization check covers 50 supported locales).

MobileVLCKit's device framework included armv7/armv7s, which iOS 17+ does not support. Retaining arm64 and stripping debug/non-global symbols reduces the source device framework from about 99 MiB to 35 MiB. All codecs and both simulator architectures remain. Release executable stripping is enabled in `project.yml`; all language resources remain. The upstream source archive and shipped binary hashes are recorded in the artifact manifests.

The 30 data/code sections in the original arm64 decoder and the optimized binary have identical SHA-256 hashes. No decoder instructions or codec tables were removed. The Go simulator object also declares the correct IOSSIMULATOR platform and iOS 17 minimum.

Native decoder/engine code remains bundled. App Store Review Guideline 2.5.2 does not provide a general mechanism to add these native features by downloading executable modules after installation. Network discovery data can be refreshed separately.

## Validation and boundaries

- Go race-detector integration test passed: 12,000,000 payload bytes transferred through a real local eD2K peer, paused, restarted with 194,560 bytes restored, and completed with matching bytes/hash. No public media payload was used.
- Focused tests passed for stale checkpoints, changed/corrupt file bytes, symlink targets and 5,263,316,776-byte metadata.
- Standalone Swift probes passed for Unicode/plus/percent filenames, eD2K ledger round trips, thunder decoding, >4 GiB lengths and Bilibili host boundaries. Regression test sources are included for the Xcode suite.
- JavaScript checks passed for native zoom taking precedence over a stale cached viewport, pinch zoom and invalid scale inputs.
- Strict localization check passed: 894 keys across 50 locales. Download hints/error messages were maintained in the tool-localization resources.
- The prior web return fix was already confirmed by the user. Per their instruction, no new iPad or automated phone UI tests were run. Bilibili confirmation, restored control size and the revised form await their manual phone review. No claim that Soulo is faster than Safari is made.
- The final Release build passed, native artifact checksums matched, and code signing verified. It was installed in place and launched normally on the connected iPhone 17 on 2026-11-01. Existing staged changes were preserved; no commit or push was made.

The reported eD2K media link was parsed, but its availability on the public network has not been established. An eD2K download needs reachable sources and may wait in a remote peer's queue.
