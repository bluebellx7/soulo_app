# Built-in website improvements

Baidu Search Improvements is enabled by default. It appears under Settings → Scripts & Extensions → Script Extensions. Its row opens the same read-only source viewer used by the reading-progress script, and its switch is enabled by default. These built-in scripts use a host-managed isolated navigation bridge, so they are not injected a second time by the optional user-script runtime. Turning it off restores the current document's original attributes and removes injected styles and source labels; it does not reload the page. The preference is included in settings backup and cloud sync.

Rules live in `Soulo/Resources/UserScripts/site-optimizations.json`, with one plain `.js` file per website. They are bundled with the app, run in separate `WKContentWorld`s, and do not download remote code. Plain `.js` avoids duplicating these entries in the optional `.user.js` sample catalog.

To add a website, add its descriptor, independent JavaScript file, localized name and description, and behavioral tests. Match exact hosts and search paths. The script implements `globalThis.__souloSiteOptimization.configure(options)` and `finishNavigation()`. It must reverse its own changes when disabled, leave other scripts intact, avoid unload handlers and document overlays, and request the latest configuration with `{action: "ready"}` on `pageshow` so cached documents honor preference changes.

Only trusted, unmodified result activations can request native navigation through the isolated bridge. The controller also checks the source frame, website scope and HTTP(S) destination. This does not add destinations to the global domain allowlist. Unrelated automatic redirects still follow the browser's existing policy.

Baidu's rule supports `baidu.com`, `www.baidu.com` and `m.baidu.com`, including mobile `/from=…/s` paths. Normal web results use a quieter layout, source domains and tap/loading feedback. Explicit destination metadata takes priority over opaque redirect tokens; unresolved tokens retain their original URL and open through browser navigation. Recommendation search chips open a normal Baidu search in the browser; bottom app-promotion banners and app-only hints are hidden. No publisher or redirect prefetch is performed. Video and other interactive Baidu cards keep their existing controls. Result changes are processed in small batches, only affected cards are revisited, and layout updates wait until scrolling stops. The rule does not recolor the whole document or force its dark appearance.

## Validation

- `SouloTests/SiteOptimizationTests.swift`: WebKit isolation, source/destination scope, reversible changes, dynamic results, preferences/backup and cached-page restoration.
- `SouloUITests/SiteOptimizationUITests.swift`: default-on switch and persistence after relaunch.
- `SOULO_PLAYWRIGHT_MODULE=/path/to/playwright node scripts/tests/test_baidu_search_optimization.cjs`: real browser clicks, keyboard activation, opaque fallback, loading feedback, scrolling and layout screenshots without remote traffic.
- `SOULO_PLAYWRIGHT_MODULE=/path/to/playwright node scripts/tests/test_web_video_fullscreen.cjs`: native video entry, independent document/native fullscreen events, and restoration after a real exit.
- `python3 scripts/check_localization.py --strict`
