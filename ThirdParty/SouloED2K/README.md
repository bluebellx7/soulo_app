# Soulo eD2K engine

The MIT-licensed [goed2k](https://github.com/monkeyWie/goed2k) library is pinned to `f2a71d599deeb1b60595d71aa662d48b205699ed`. `Bridge/go.sum` records the authenticated upstream module; `upstream.json` records original source hashes. The library-only snapshot is vendored in `Source/goed2k`, without the terminal UI. Its `connection.go` and the new `connection_dial.go` use cancellable, timeout-bounded asynchronous TCP dialing, handing socket ownership back to the serial protocol loop. Only the protocol library and Go standard library are linked. License texts ship in `ED2KThirdPartyNotices.txt` and appear in the app's licenses page.

Rebuild all iOS 17+ slices with:

```sh
python3 scripts/ed2k/build_engine.py
```

The static XCFramework has device arm64 and Simulator arm64/x86_64 slices. `artifacts.json` records their SHA-256 hashes. The app links this library without embedding it as a dynamic framework. Its uniquely named Clang module map avoids a public-header collision with the existing torrent XCFramework.

The original C/JSON bridge drives all transfer mutations on a serial loop. Kad callbacks queue results onto that loop. Discovery starts with user-created eD2K work, uses bundled server/Kad bootstrap data from `https://upd.emule-security.org/`, and refreshes it over certificate-verified HTTPS with a 1 MiB response limit. There are no sockets or timers started by the Swift service merely restoring the download ledger. The engine closes when its last active task is paused, removed or completed.

The bridge drains pending disk operations before writing an atomic resume checkpoint and closing files. Changed files are checked against cached piece hashes on restoration. Completed transfers undergo an independent, streaming eD2K whole-file hash check before the app marks them finished. Targets must be regular files, file sizes use 64-bit integers, and peer filenames never choose filesystem paths.

`thunder://` is decoded in Swift; only supported HTTP/HTTPS, BT magnet and eD2K destinations are accepted. Legacy pipe-separated eD2K links are preserved in a Foundation-compatible opaque URL in the ledger. Downloading still requires reachable peers with the requested file; accepting a link does not create a source.

The existing iOS continued-processing coordinator covers BT and eD2K work together. Save operations remain part of its outstanding work until resume checkpoints finish. System expiration pauses and saves tasks; the engine does not use an audio keepalive.

The host tests use a local eD2K seeder and a generated 12 MB payload to check actual transfer, pause/restart, byte equality and final hash validation under the Go race detector. Additional tests cover stale resume checkpoints, corruption, symlink rejection and file sizes above 4 GiB.
