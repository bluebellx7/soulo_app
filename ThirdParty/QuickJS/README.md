# QuickJS

Soulo runs its bundled HLS transmuxing script in QuickJS without JIT compilation. This build has no shell, filesystem or network bindings. The bridge accepts TS bytes and emits MP4 bytes to the conversion service.

`Source/` contains the unmodified core files from [QuickJS 2026-06-04](https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz). The release archive SHA-256 is `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`. The upstream [MIT license](LICENSE) is included in the app's media playback notices.
