# SouloDecoder

The app source uses AVFoundation for native playback and this framework for
extended demuxing and decoding. The framework exposes the libmpv client and
software-render APIs. Its iOS 16 XCFramework contains an arm64 device slice
and arm64 and x86_64 simulator slices.

Run `scripts/build_soulo_decoder.sh` to rebuild it with Xcode, Python,
pkg-config and the pinned upstream sources. The script checks all source
archives before applying the patches in this directory. It prints the path to
the generated XCFramework. Each slice ships with a matching dSYM generated
before stripping the release binary. Replace the entire XCFramework in
`Artifacts` after a rebuild so Xcode archives the matching symbols.

The mpv build disables GPL features. FFmpeg is built without GPL or nonfree
configuration switches. The app signs and embeds the dynamic framework.
[In-app notices](../../Soulo/Source/Resources/MediaPlaybackThirdPartyNotices.txt)
include the sources and licenses.
