# Soulo native torrent engine

A small, original Objective-C++ interface around **libtorrent 2.0.15**, statically linked with **OpenSSL 3.6.5**. The app supports BitTorrent v1/v2 metadata, magnet metadata exchange, selected-file downloads, hash verification and persistent fast resume. It does not implement a remote download service or use an audio keepalive.

`Artifacts/SouloTorrent.xcframework` contains iOS arm64 and iOS Simulator arm64/x86_64 slices, built with Xcode 26.2 for iOS 17+. The public module autolinks libc++, Foundation, CoreFoundation and SystemConfiguration. App archives do not contain the simulator slices.

The app links this static XCFramework directly from `project.yml` with `embed: false`. The optional `Package.swift` remains available for SwiftPM clients, but is not an app package dependency: Xcode can otherwise open this in-repository package as a folder before resolving it as a package, causing `Missing package product` in the GUI while command-line builds succeed. Regenerate the Xcode project after changing the dependency.

## Rebuilding

From the repository root, with Xcode and CMake installed:

```sh
python3 scripts/torrent/build_engine.py --package
```

The script fetches and SHA-256 verifies the pinned libtorrent, Boost, OpenSSL and try_signal archives. Downloads and builds stay in `~/Library/Caches/SouloTorrentBuild`, outside the repository. Use an empty cache when updating dependencies. Only Boost headers are used. All TLS libraries are built for the target SDK; no macOS Homebrew binary is embedded. `Bridge/` is Soulo's own source, not copied from another application's wrapper.

The CA bundle in `Soulo/Resources/Torrents/torrent-ca.pem` is Mozilla's CA data distributed by <https://curl.se/ca/cacert.pem>, retrieved on 2026-10-31. Keep its license header and refresh it deliberately. HTTPS certificate and hostname verification remain enabled. Local peer discovery, UPnP and NAT-PMP are disabled; DHT, tracker discovery, outgoing peers and metadata exchange remain available.

Third-party license texts ship in `TorrentThirdPartyNotices.txt` and appear in the app's licenses page. The pinned archive digests are in the build script; shipped artifact digests are in `artifacts.json`.

## Lifecycle

- Imported metadata is limited to 8 MiB and 5,000 files. Symbolic links and unsafe paths are rejected. Each task owns a separate destination directory.
- Magnet acquisition uses upload mode and zero default file priority. It does not use `stop_when_ready`, which also stops the metadata acquisition state in libtorrent.
- Swift owns user intent and queue state; all C++ calls run on one serial worker queue. At most three jobs resolve or download concurrently.
- Resume files include metadata and file priorities, are written atomically, and survive app restarts. Invalid resume data falls back to original metadata and disk rechecking. Failed transfers keep their partial files.
- Selection changes are asynchronous in libtorrent. Completion requires both the expected selected-file byte count and the verified completed byte count; an old zero-priority `is_finished` snapshot cannot finish a new selection.
- Task expiration pauses native work and waits for resume writes before completing the system task. Older iOS releases save and pause when backgrounded. The app never promises uninterrupted execution after force quit, low-memory termination or system expiration.

## Distribution

Adding OpenSSL changes the app's encryption inventory. The old hard-coded `ITSAppUsesNonExemptEncryption = false` declaration was removed from the app target so App Store Connect can request the appropriate encryption answers for this build. No exemption or regulatory classification is asserted by this package. See Apple's [export compliance documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).
