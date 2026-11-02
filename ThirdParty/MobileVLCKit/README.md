# MobileVLCKit 3.7.5

The official VideoLAN iOS XCFramework adds extended decoding to local files and torrent streams. It is embedded and signed as a dynamic framework by `project.yml`; the decoder is instantiated for MKV or media requiring the extended decoder. Web pages continue to use WKWebView and compatible files continue to use AVPlayer.

`artifacts.json` pins the upstream archive SHA-256 from the official CocoaPods specification and records the distributed binary digests. Run `python3 scripts/optimize_mobilevlckit.py` after extraction: the iOS 17+ device slice contains arm64 only, while both arm64 and x86_64 simulator slices remain. Debug/non-global symbols are stripped from the device binary. All decoder features are retained.

The original upstream device dSYM is retained in `Symbols/ios-arm64.dSYM.tar.xz`, thinned to arm64 with UUID `411F9415-74D5-32BD-86AB-C1C337978956`. The XCFramework declares its `DebugSymbolsPath`. XcodeGen's pre-generation step runs `python3 scripts/prepare_mobilevlckit_symbols.py` to restore and validate the dSYM before Xcode reads the XCFramework. `--check` validates the checksum and both UUIDs without restoring files. Keep the compressed symbol archive with this pinned framework; dSYMs belong in the Xcode archive and are not embedded in the installed app.

The full upstream LGPL notice and source locations are included in `Soulo/Source/Resources/MediaPlaybackThirdPartyNotices.txt` and the in-app licenses page. The upstream sources are VideoLAN VLCKit commit `a213fd11` and VLC commit `6de05adc`.
