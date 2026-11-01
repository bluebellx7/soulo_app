# Browser state synchronization: physical iPad follow-up

Continues `988f319` on an iPad Air 11-inch (M3), iPadOS 26.6.1. Both app packages use Release configuration and retain the same existing user working changes. Version remains 1.2.7 (51).

## Scope and evidence

WebKit can publish a state value more than once. Assigning the same value to `@Published` still invalidates the SwiftUI browser tree. The isolated regression produced 50 redundant notifications for five identical state rounds before this change, and zero afterwards. Actual value changes still publish. Completion continues to normalize progress and dismiss restoration snapshots even when the input loading flag is unchanged. Same-URL navigations still increment `pageRevision`; navigation requests still clear prior errors.

The ad preference previously used `object(forKey:) as? Bool ?? true` in eight native call sites. Foundation argument-domain `NO` is a string, so those paths could incorrectly enable filtering while AppStorage considered it disabled. All eight now use one reader with UserDefaults boolean semantics, preserving default-on when the key is absent. Tests cover native booleans, numbers, and YES/NO and true/false strings. This also corrects the benchmark configuration; it is not evidence that every normal user's typed boolean setting was broken.

No page scripts, navigation policy, history traversal, snapshot scheduling, or media controls were changed in this follow-up.

## Corrected recorder and timing comparison

`/_mark` diagnostic responses now use `Cache-Control: no-store`, and fixture fetches use `cache: 'no-store'`. Real WKWebView requests proved the old recorder saw only one of two identical requests; the corrected recorder sees both. HTML and poster caching remain unchanged.

The local workload contains 100 cards and 20 video posters. Each run navigates to a result and returns using the Back button five times. Baidu optimization is disabled for the fixture. Ad-on uses two separate five-trial runs per package; ad-off and Safari use five trials each. All measured returns preserve the document (`pageshow.persisted == true`). Thermal state was nominal and Low Power Mode was off.

| Mode | Result readiness median, range (ms) | Cached return median, range (ms) |
| --- | ---: | ---: |
| Starting package, filtering on (n=10) | 71, 53–91 | 75.5, 70–86 |
| Updated package, filtering on (n=10) | 70, 63–85 | 82, 28–115 |
| Starting package, nominal filtering off (n=5) | 161, 95–170 | 138, 135–149 |
| Updated package, filtering off (n=5) | 61, 34–66 | 36, 24–46 |
| Safari (n=5) | 33, 27–37 | 36, 35–39 |

The old nominal-off package still installed the ad runtime while reporting it disabled at sampling time. The corrected off package does not install that runtime. The large off-mode difference includes removal of that inconsistent configuration, not just fewer state publications. On-mode latency ranges overlap, and the return median is higher in the updated sample. These samples do not establish an overall speed improvement, a statistically significant regression, or superiority to Safari.

These are document-side proxies: result time starts at a link click; return time starts at the departing document's `pagehide`; readiness is the second animation callback after `pageshow`. They exclude parts of input handling and navigation animation; the second animation callback can also precede completion of native scroll restoration. Caches were not purged. Do not describe them as full user-perceived navigation or cold-launch times.

## Regression boundaries

The final isolated candidate passes 23 selected native checks: the four new state/preference regressions plus loading, live filter changes, early filtering, warm tabs, script reuse, media-document history, abandoned-navigation failures, same-document error recovery, remounting, text selection, translation, and network recovery. The strict localization check passes 894 keys across 50 languages. The physical Release build succeeds.

One existing simulator assertion is unresolved: `testBackRestoresTheSameDocumentWithoutReloading` intermittently restores offset 0 instead of 600, while retaining document identity, form data and page cache. Repeating the unchanged starting model reproduced the same failure in two of three iterations; the candidate also failed two of three. A bare WKWebView in a full scene window also showed unstable restoration in diagnostic runs. Waiting two frames or waiting for visible content did not reliably fix the production fixture. The original test and its assertions are retained; this failure is not counted as a passing regression or dismissed as harmless.

Physical Release acceptance passes live Baidu `盐焗` scrolling in Safari and Soulo (four gestures down and four up), native long-press selection, and cached Back-button restoration. A new scrolled-history diagnostic initially read offset 0 at the early pageshow marker even though the attached screenshot showed the original scrolled content. Its check now waits for WebKit to restore the expected position using passive scroll observation, without changing the offset. The corrected check passes against the starting package (510 → 510 points; native restoration observed after 69 ms) and the updated package (470 → 470 points; restoration observed after 46 ms). Native edge-gesture injection remains unverified; the automated history acceptance uses the Back button.

## Profiling limits

A complete 35.8-second starting-package Time Profiler recording identified SwiftUI update work and repeated script installation while the nominal off configuration was inconsistent. It guided the preference and state audit. Two later recordings ended after about 0.7–0.8 seconds with `Device disconnected`, despite xctrace reporting exit code zero. Those recordings are rejected; no CPU before/after reduction is claimed. The driver now verifies the exported trace duration and termination reason before accepting a recording.

## Reproduction and local artifacts

The driver builds independently and tests the installed app without replacing its Release package:

```sh
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/browser-on --browser soulo --ads YES --trials 5 --scrolls 0
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/browser-off --browser soulo --ads NO --trials 5 --scrolls 0
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/browser-history --workload history
python3 scripts/benchmark_ipad_browsing.py --device IPAD_UDID --team DEVELOPMENT_TEAM --output /tmp/browser-recorder --workload recorder
```

Opt-in UI tests require an unlocked development iPad. The tests use private Soulo pages and close only the Safari tabs they create. Session logs, immutable starting/updated app packages, rejected traces, and xcresult bundles stay under `/tmp/soulo-performance-20261101-2` on the development Mac. No diagnostic launch arguments are added to the installed production app.
