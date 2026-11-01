# Physical iPad browsing and trackerless-magnet verification

Device: iPad Air 11-inch (M3), iPadOS 26.6.1. Browsing measurements use the installed Release app, not a simulator or a Debug build. App version remains 1.2.7 (51). The baseline includes the user's existing working changes over `f53d52a`; these changes were preserved.

## Changes and regression boundaries

- Baidu's built-in extension is rewritten as static result typography and trusted-click handling for App/interstitial avoidance. It does not scan or rewrite results, observe mutations, animate loading feedback, or handle scrolling. Original links, layouts, video cards, selection and in-page controls are preserved. The default-on switch and source viewer remain in Script Extensions.
- Video controls are created when a player approaches the viewport. Scroll layout reads nearby players first, then writes control positions. Shared ancestor styles are read once per layout batch. Existing sizing, fullscreen entry and exit behavior remain intact.
- Accessibility metadata is written after reads and dynamic additions are processed as regions. Already-labelled results avoid repeated geometry reads.
- Text unlocking only overrides computed properties that actually prohibit selection. Pointer/touch handling stays passive and avoids duplicate listeners. A delayed-only approach was discarded; the final code retains touch-down compatibility with inline selection restrictions.

## Comparable local workload

The UI runner hosts an identical localhost page for Safari and Soulo: 100 result cards and 20 video posters, with no remote assets. Three result navigations, three Back-button restorations and eight scrolling gestures per browser are recorded. Baidu optimization and ad blocking are off for this workload.

These are document-side timing proxies, not hardware first-paint measurements: readiness is the second animation callback after `pageshow`; result time begins at the link's click; restoration time begins at the departing page's `pagehide`. They exclude parts of input handling and the navigation animation. Caches were not purged, and three trials do not establish a statistical performance guarantee.

| Metric (ms) | Safari final run | Soulo baseline | Soulo final run |
| --- | ---: | ---: | ---: |
| First document readiness within the run | 42 | 1691 | 259 |
| Median subsequent source readiness | 22.5 | 136.5 | 111.5 |
| Median result readiness after click | 32 | 104 | 148 |
| Median cached document restoration | 34 | 151 | 131 |

All measured Back-button returns retained the document (`pageshow.persisted == true`). Results are mixed: the current build has not met the goal of exceeding Safari, and the result-navigation gap remains open. Do not present the first-load difference as a universal cold-start improvement or the sample as an overall speed win.

A finite Animation Hitches capture of the earlier video-layout candidate recorded no hitch events in the fixed scrolling workload. That does not establish hitch-free browsing on arbitrary websites. Live `盐焗` searches were also scrolled in both apps and photographed; Baidu served different AI-summary states, so those pages were not used as a byte-identical timing comparison.

Native edge-gesture injection did not restore the document in the attempted Safari control or Soulo runs. Back-button restoration and text selection were tested separately. Native edge-gesture performance remains unverified by this automation; retain the explicit `--edge` diagnostic instead of treating it as a passed acceptance check.

## Trackerless magnet diagnosis

Input: `magnet:?xt=urn:btih:gw4bu44exlwh463cz3oqp6udgvw3ykfx`.

- The shipped native parser accepts lowercase and uppercase Base32 and produces `35b81a7384baec7e7b62cedd07fa83356dbc28b7`. This is not a Base32 parsing failure.
- Retrieved metainfo hashes to that exact SHA-1, passes the native path/metadata validator and describes one public file. No resource filename or file contents are included in this report.
- OpenTrackr's scrape reported active seed records during diagnosis. Tracker counts are observations, not a promise of reachable peers.
- The bare link contains no tracker. The former engine depended on DHT and one bootstrap provider. The original bootstrap did not answer the local connectivity probe; an independent Transmission entry point did. Adding that entry point alone still did not resolve this magnet in the iPad test window.
- In a fresh session with distinct info hashes, adding the metainfo's HTTP tracker resolved this exact resource in about two seconds. An early diagnostic that added the same info hash twice was discarded: libtorrent reused the first handle, so it was not a valid comparison of tracker configurations.
- The final engine uses two DHT entry providers and a bounded HTTP/UDP OpenTrackr fallback for bare magnets without explicit trackers or known private metainfo. Explicit tracker lists are preserved. Local-only sessions do not add external discovery.
- With the final production engine on the iPad, the **unchanged bare input** resolved metadata in 3 seconds in one run and 14 seconds in another. Metadata-only acquisition transferred zero payload bytes. After selection, a separate bounded test received **81,920 payload bytes reported by `total_wanted_done`**, then stopped and removed its temporary tasks/files. This confirms actual payload reception, not completion of a whole piece hash check or the entire resource.

No TLS verification was disabled, no remote metadata-cache service was added to the product, and the temporary verbose diagnostic engine is absent from production artifacts. Artifact hashes were regenerated with the native framework.

## Validation and reproduction

Local checks cover the native hash parser, selected-file transfer, metadata-only mode, restart/resume, document restoration, editable controls and JavaScript parsing (20 native tests); trusted Baidu activations and unchanged in-page controls; bounded video layout; batched accessibility; and ordinary touch gestures versus blocked-text selection. The 50-language strict runtime localization check passes.

The browsing driver builds independently from the app so a manually installed Release build is not replaced by a Debug build:

```sh
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/soulo-ipad-fixture --workload fixture
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/soulo-ipad-interaction --workload interaction
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/soulo-ipad-live --workload live --trace-browser soulo
```

Requires Xcode, XcodeGen, development signing and an unlocked physical iPad. Artifacts stay local. The optional edge diagnostic is `--workload interaction --edge`. It is separate from the button-based latency sample. No test publishes results or sends messages.

Session artifacts are under `/tmp/soulo-ipad-safari-20261101` and `/tmp/soulo-magnet-gw4bu44-20261101` on the development Mac, including `.xcresult` bundles and finite Instruments traces.
