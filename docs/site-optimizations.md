# Built-in website improvements

Baidu Search Improvements is enabled by default. It appears under Settings → Scripts & Extensions → Script Extensions. Its row opens the same read-only source viewer used by the reading-progress script, and its switch is enabled by default. These built-in scripts use a host-managed isolated navigation bridge, so they are not injected a second time by the optional user-script runtime. Turning it off removes its static stylesheet and document marker; it does not reload the page. The preference is included in settings backup and cloud sync.

Rules live in `Soulo/Resources/UserScripts/site-optimizations.json`, with one plain `.js` file per website. They are bundled with the app, run in separate `WKContentWorld`s, and do not download remote code. Plain `.js` avoids duplicating these entries in the optional `.user.js` sample catalog.

To add a website, add its descriptor, independent JavaScript file, localized name and description, and behavioral tests. Match exact hosts and search paths. The script implements `globalThis.__souloSiteOptimization.configure(options)` and `finishNavigation()`. It must reverse its own changes when disabled, leave other scripts intact, avoid unload handlers and document overlays, and request the latest configuration with `{action: "ready"}` on `pageshow` so cached documents honor preference changes.

Only trusted, unmodified result activations can request native navigation through the isolated bridge. The controller also checks the source frame, website scope and HTTP(S) destination. This does not add destinations to the global domain allowlist. Unrelated automatic redirects still follow the browser's existing policy.

Baidu's 2.0 rule supports `baidu.com`, `www.baidu.com` and `m.baidu.com`, including mobile `/from=…/s` paths. It has two responsibilities:

1. Refine normal web results with clearer title, summary and source typography. Preserve the website's layout, truncation, images, background and video cards.
2. Keep result activations in the browser without Baidu App-opening or third-party confirmation prompts. On a trusted, unmodified click, read only that result's explicit web metadata and navigate through the isolated native bridge. Unknown redirect tokens retain their original destination. Related-search chips use normal web search. Hide App-opening hints and the fixed App-promotion footer.

The rule does not rewrite document links, scan results, create source labels or loading indicators, install mutation observers, schedule timers, handle scrolling, or prefetch destinations. Dynamic results inherit static CSS and are resolved only when activated. Browser chrome provides loading feedback. Selection, modified clicks, downloads, search controls and video cards preserve their existing behavior.

## Validation

- `SouloTests/SiteOptimizationTests.swift`: WebKit isolation, source/destination scope, reversible styles without link mutations, preferences/backup and cached-page restoration.
- `SouloUITests/SiteOptimizationUITests.swift`: default-on switch and persistence after relaunch.
- `SOULO_PLAYWRIGHT_MODULE=/path/to/playwright node scripts/tests/test_baidu_search_optimization.cjs`: real browser clicks, keyboard activation, opaque fallback, dynamic clicks, scrolling without DOM writes and layout screenshots without remote traffic.
- `SOULO_PLAYWRIGHT_MODULE=/path/to/playwright node scripts/tests/test_web_video_fullscreen.cjs`: native video entry, independent document/native fullscreen events, and restoration after a real exit.
- `python3 scripts/check_localization.py --strict`
