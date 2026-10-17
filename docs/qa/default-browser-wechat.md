# WeChat → Soulo URL opening

The current source release is **1.2.1 (33)**. Build 30 added safe iCloud synchronization and configuration backups; build 31 added direct opening for shared links. Build 32 expanded content reading but failed physical-device WeChat acceptance. Build 33 replaces the preferences-based handoff after device diagnostics identified a false persistence failure. See [iCloud safety verification](icloud-sync-safety.md).

## Apple capability approval and configuration

The **Default Web Browser** managed capability was requested for team `7S2LBJA9VA` and bundle ID `com.dkluge.Soulo` using [Apple's browser capability instructions](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser).

Apple acknowledged the entitlement request on 2026-09-25. Request ID: `N62U6769DH`. On 2026-10-08, the developer supplied Apple's approval email confirming that the entitlement was assigned to the account and associated App ID.

Soulo already offers URL entry, navigation, tabs, bookmarks, search, and direct rendering of HTTP and HTTPS pages. `project.yml` now declares both web URL schemes. `SouloURLRoute` accepts the exact incoming web URL. The full photo-library permission has been removed because image selection uses `PhotosPicker` and saving uses add-only authorization.

`project.yml` now uses `Soulo/SouloBrowser.entitlements`, and the Xcode project has been regenerated with `xcodegen generate --spec project.yml`. The app, Widget and Share Extension remain at version **1.2.1**, with build **33**. The browser entitlement applies only to the main app. Settings → Browsing → **Default Browser** opens Soulo's system settings through the public `UIApplication.openSettingsURLString` API. The entry and its accessibility hint are localized in all 50 languages, including the English fallback table.

Explicit HTTP/HTTPS URLs also retain single-label intranet/device hosts (for example, `http://intranet:8080/docs`), rather than being sent to a search engine by the bare-host heuristic. Bare words still use search, unsupported schemes remain excluded, and encoded paths, queries and fragments are preserved.

### Xcode signing and device acceptance

The initial signed archive attempt on 2026-10-08 reported a missing browser capability in the cached development profile. After opening the regenerated project in Xcode, automatic signing refreshed the profile. Xcode's Release Signing & Capabilities page now shows **Default Web Browser** without a signing error, and the refreshed development profile contains `com.apple.developer.web-browser = true`.

1. Keep **Automatically manage signing** enabled for the Soulo target and team `7S2LBJA9VA`. The browser capability comes from `Soulo/SouloBrowser.entitlements`; Xcode refreshes eligible profiles following [Apple's managed-capability provisioning instructions](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities).
2. Build/archive in Xcode and verify that both the signed app and its provisioning profile contain `com.apple.developer.web-browser = true`. This verification now passes for the development archive and the App Store export. Keep `project.yml` as the source of engineering settings when making further changes.
3. On an iPhone, use Soulo's **Default Browser** entry and select Soulo as the browser. Test HTTP and HTTPS links from another app with Soulo terminated and already running, preserving path, query and fragment. Repeat from the Files/Settings screens, then test WeChat's **用其它应用打开网址** with Soulo.

All 50 metadata directories have updated promotional text, descriptions and release notes. Names, subtitles and keywords were reviewed and retained. `fastlane/app_store_metadata.json` was regenerated from these source files. Metadata export/check and strict localization checks pass, with no invisible-character export warnings.

### Historical build 29 verification (2026-10-08)

- Xcode 26.2, iPhone 17 Pro / iOS 26.2 simulator. App and test sources compile successfully. Built app, Widget and Share Extension each report version `1.2.1`, build `29`.
- 10 selected unit tests pass: all five `SouloURLRouteTests`, plus five `WebViewModelTests` for web-input classification, shared URL helpers, unsafe schemes and the single-label-host regression.
- Both `DefaultBrowserUITests` pass in the final UI run: the settings entry opens the Settings app and returns to Soulo; URL-based launches render a local HTTP page with exact query encoding and fragment. `XCUIApplication.open` launches the target each time, so this test does not claim to verify live URL delivery to an already-running app or system default-browser selection.
- Final UI result: `/tmp/soulo-default-browser-verified-ui-20261008.xcresult`; log: `/tmp/soulo-default-browser-verified-ui-tests-20261008.log`. The 10 unit passes are recorded in `/tmp/soulo-default-browser-final-tests-20261008.log`; that earlier run also contains UI harness failures superseded by the final UI run.
- `python3 scripts/export_metadata_json.py --check`, `python3 scripts/check_localization.py --strict` (867 keys × 50 locales), and `git diff --check` pass.

### Historical build 29 archive and App Store export (2026-10-08)

- `xcodebuild archive` with Release, generic iOS destination, automatic signing and `-allowProvisioningUpdates` succeeds.
- The archived main app and its embedded development profile each contain `com.apple.developer.web-browser = true`. Widget and Share Extension remain at `1.2.1 (29)` and do not carry the browser entitlement.
- `xcodebuild -exportArchive` with `method = app-store-connect`, `destination = export` and automatic signing succeeds. The exported app and App Store profile each contain the browser entitlement, and `get-task-allow = false`. `codesign --verify --deep --strict` passes for the archive and exported app.
- The archive is saved at `/Users/shunfei.z/Library/Developer/Xcode/Archives/2026-10-08/Soulo 1.2.1 (29) 11.45.25.xcarchive`. Xcode Organizer shows Soulo `1.2.1 (29)` selected with **Distribute App** available.
- The App Store IPA is saved at `build/default-browser-1.2.1-29/Soulo.ipa` (ignored build output). Archive/export logs are `/tmp/soulo-default-browser-archive-20261008.log` and `/tmp/soulo-default-browser-export-20261008.log`.

The archive and IPA are prepared locally; upload and review submission remain with the developer. Actual default-browser selection and cross-app/WeChat routing on a physical iPhone are not covered by the automated tests and remain the manual device acceptance steps above.

The standard `NSExtensionContext.open` API does not document Share Extension support. This restriction alone does not establish that browsers cannot foreground their app: Chromium implements a separate responder-based Open in path. Build 31 now includes that compatibility path and retains the App Group handoff if no opening responder is available. Record the WeChat/iOS versions and actual chooser entry during signed-device acceptance.

## Build 30 shared-link behavior

The Share Extension no longer offers separate Open Soulo / Private Search actions. It reads all URL attachments before plain text or titles, recognizes URLs embedded in shared text, and queues the exact web address for direct navigation. It attempts the public extension context opening API once. If the host rejects the request or omits the callback, a localized message explains that the link was saved and will open when the user returns to Soulo. A Done button dismisses the extension. The queued action is consumed once, validates its request ID and expires after seven days.

The main app consumes the queued link on activation, dismisses settings/reader destinations and navigates to the URL. Delivery is scoped to the consuming window. A new Open Webpage in Soulo App Intent accepts a URL and foregrounds the app from Shortcuts, providing a supported alternative for a user-configured shortcut that receives shared URLs.

Apple's [NSExtensionContext.open documentation](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)) does not provide Share Extensions with a supported route to foreground their containing application. The approved default-browser entitlement applies to the main app, not to Share Extensions. Build 30 introduced no responder opening path. Build 31 adds the public-selector compatibility path described below; it does not access `UIApplication.shared` or private selectors. Actual WeChat behavior and system default-browser selection still require the signed-device checks above.

## Historical build 30 verification and distribution files

- 28 final unit tests passed; see [iCloud safety verification](icloud-sync-safety.md) for coverage and logs. All three browser/backup UI tests passed, including the backup Save and Restore confirmation flow.
- All 50 metadata locales pass export/check, and strict localization passes 873 keys × 50 locales. `git diff --check` passes.
- Release archive and App Store export both succeeded. Main app, Widget and Share Extension each report `1.2.1 (30)`. The main app and its development/App Store profiles contain `com.apple.developer.web-browser = true`; extensions do not. App Group permissions match in each signed bundle and profile. All App Store bundles have `get-task-allow = false`, no development devices in their profiles, and valid unexpired team profiles. `codesign --verify --deep --strict` passes for the archive and extracted IPA.
- Historical archive: `/Users/shunfei.z/Library/Developer/Xcode/Archives/2026-10-08/Soulo 1.2.1 (30) 12.57.02.xcarchive`.
- Historical App Store upload package: `build/sync-share-1.2.1-30/Soulo.ipa` (ignored build output). Archive/export logs: `/tmp/soulo-sync-share-archive-20261008.log` and `/tmp/soulo-sync-share-export-20261008.log`.
- Upload/review submission was not performed. These build 30 artifacts have been superseded by build **31**. Build **29** lacks the sync fixes; build **30** lacks the new direct opening path. Real multi-device iCloud behavior and WeChat foreground opening have not been verified on physical devices.


## Build 31 opening implementation

The earlier conclusion treated the restriction of one API as a limitation of all browser opening paths. Chromium's current public source demonstrates another implementation: its [Open in controller](https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/open_extension/open_view_controller.mm) invokes a [responder-based URL opener](https://chromium.googlesource.com/chromium/src/+/main/ios/chrome/common/extension_open_url.mm), then immediately completes the extension request. Its Open in entry is an Action Extension (`com.apple.ui-services`); Soulo keeps its existing Share Extension entry.

Soulo now first walks the responder chain for the public `openURL:options:completionHandler:` selector. An Objective-C bridge checks the argument/return signature before invoking it and only accepts Soulo action links on the main thread. Options are nil: `UIScene` and `UIApplication` use different options types under the same selector, so passing a dictionary to a scene would crash. Apple's [scene URL-opening documentation](https://developer.apple.com/documentation/uikit/uiscene/open(_:options:completionhandler:)) describes the foreground handoff. A successful dispatch closes the extension immediately. If no matching responder exists, it retains the standard context-opening attempt and localized saved-link fallback. The queued action is synchronized before requesting foreground activation so the main process can read it immediately. This uses neither `UIApplication.shared` nor a private selector, but availability remains a compatibility behavior rather than an Apple guarantee for every Share Extension host.

Four new opener tests passed, verifying traversal, exact request delivery, nil options, missing-host fallback, invalid method signatures and rejection of unrelated URLs. The four existing shared-link tests also passed after the cross-process storage change. Final unit passes are in `/tmp/soulo-direct-share-31-scene-fix-20261008.xcresult` and its matching `.log`. That run's UI portion encountered Safari's stale accessibility session before reaching the extension; subsequent UI tests explicitly relaunch Safari and supersede it. The earlier dictionary-options crash was diagnosed from the extension's system log and corrected; it was not an Apple API rejection.

### Build 31 end-to-end simulator acceptance

Both actual Safari share-sheet tests pass on the dedicated iPhone 17 Pro / iOS 26.2 simulator:

- Soulo terminated: tap its Share Extension cell, observe the main app become foreground, then assert that its web view renders the shared page with the exact query encoding and fragment.
- Soulo in the background: the same share-sheet selection foregrounds Soulo and renders the original page without a second Open / Private Search choice.

The tests never call `app.activate()` or `app.open()` to perform this handoff. Foreground activation must come from the extension. Final result: `/tmp/soulo-direct-share-31-complete-ui-20261008.xcresult`; log: `/tmp/soulo-direct-share-31-complete-ui-20261008.log` (2 tests, 0 failures). Safari is restarted for each test to avoid its stale accessibility session after the earlier extension crash.

This verifies the real system Share Extension path in Safari, including cold launch and cross-process App Group delivery. It does not claim physical-device WeChat acceptance or multi-device iCloud acceptance. Test the same signed build from WeChat before release, recording the iOS and WeChat versions.

### Historical build 31 signed distribution files

- Release archive and local App Store export succeeded. Main app, Share Extension and Widget each report `1.2.1 (31)`. All three signed bundles and their profiles contain the expected App Group and valid team signing. Only the main app and its profile carry the browser entitlement. All App Store profiles have `get-task-allow = false` and no development-device list. Deep strict code-signature verification passes for both archive and extracted IPA.
- Historical archive: `/Users/shunfei.z/Library/Developer/Xcode/Archives/2026-10-08/Soulo 1.2.1 (31) 13.32.42.xcarchive`.
- Historical local App Store package: `build/direct-share-1.2.1-31/Soulo.ipa`. Logs: `/tmp/soulo-direct-share-31-archive-20261008.log` and `/tmp/soulo-direct-share-31-export-20261008.log`.
- Strict localization passes 873 keys × 50 locales; all 50 metadata directories pass export/check with no invisible-character warnings. `git diff --check` passes. No upload or review submission was performed. Build 32 supersedes these artifacts for the expanded content-reading fix.

## Build 32: shared-content reading

The developer supplied build 31 device screenshots from WeChat's **用其他应用打开** flow. Soulo showed **无法搜索该项目**; Doubao could display the original shared URL. This demonstrates that another share recipient can read useful content in the same user flow. It does not expose the actual registered identifiers or returned classes of WeChat's item provider. The same Soulo error was previously used for both unreadable input and failed App Group storage, so screenshots alone cannot distinguish these stages.

The build 31 reader had two confirmed gaps: it requested only `public.plain-text`, although [`public.text`](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/text) is its parent and need not conform to that child; it accepted only URL/String objects for `public.url`, omitting NSData representations. These gaps are reproduced using real `NSItemProvider` instances with the reported website address.

`SouloShareContentLoader` now reads the host's exact registered URL and text representations. It supports URL/NSString/NSData/NSAttributedString, UTF-8 and UTF-16 with BOM handling, rich-text link attributes, attributed item bodies, bounded temporary text files and explicit URL fields in JavaScript preprocessing results. Native URL attachments are checked across all items before text/title fallbacks. A data-representation request is attempted when legacy object loading fails. Images and generic file URLs are not searched. Input size, provider count and loading time are bounded; late completions cannot resume or navigate twice. Cancellation still prevents a pending action from being queued later.

Failure logs use `com.dkluge.Soulo` / `ShareInput`: unsupported input records representation identifiers, while failed App Group persistence is a separate error. No shared URL or content body is logged. The unsupported-item message now describes reading shared content rather than searching it, in all 50 languages and the five alias/fallback tables.

### Historical build 32 verification

**Physical-device acceptance failed; do not submit build 32 as the WeChat fix.** The developer installed it on the paired **iPhone 2026** (iPhone 17, iOS 26.6.1), using WeChat 8.0.78 (8.0.78.34), and reported **无法读取分享内容** from the same Other Apps path. On request, the developer reproduced the error and kept that page open. Simulator passes below do not supersede this result. The developer performs phone interactions; subsequent agent work is limited to code, debugging and installation.

A diagnostic **Debug** package retaining version/build `1.2.1 (32)` was subsequently built, signature-verified and installed in place on this device. `#if DEBUG` instrumentation writes `ShareInputDiagnostic.json` in the App Group with registered identifiers, input presence, returned classes/byte counts, error domains/codes and failure stage. It excludes shared text, URL addresses, filenames and error descriptions, and is omitted from Release. Build/install logs: `/tmp/soulo-share-input-32-diagnostic-final-build-20261008.log` and `/tmp/soulo-share-input-32-diagnostic-install-20261008.log`. A fresh developer-operated reproduction is required to generate the diagnostic; this package is not a release acceptance result.

- All 12 new real-provider tests pass, including generic `public.text` without plain-text conformance, URL data, title plus URL text, UTF-16, rich-text link attributes, body-only content, URL priority, temporary text files, JavaScript result dictionaries, unsupported file URLs, oversized/binary content, and timeout with late replies.
- The eight existing opener and shared-link tests pass. Both actual Safari share-sheet flows (Soulo terminated and backgrounded) also pass after replacing the reader: select Soulo, observe foreground activation, and verify the exact URL query encoding and fragment in the main app's web view.
- Final result: `/tmp/soulo-share-input-32-20261008.xcresult`; log: `/tmp/soulo-share-input-32-20261008.log`. **22 tests passed, 0 failed, 0 skipped.** These model supported host representations and verify the Safari system handoff; they do not claim WeChat's actual provider format has been captured or its physical-device flow has passed.
- All 50 metadata locales were reviewed and retained for version 1.2.1, with export/check passing and no invisible-character warnings. Strict localization passes 873 keys × 50 locales, including the revised read-error translations. The project was regenerated after adding the shared loader to the extension and setting all three components to build 32.

## Build 33: confirmed WeChat handoff failure

The diagnostic reproduction on **iPhone 2026 / iOS 26.6.1 / WeChat 8.0.78** produced `public.url`, a readable non-file `NSURL`, and then `storeFailed`. The device's App Group preferences also contained a fresh `.openURL` action with the exact reported URL. Content reading therefore succeeded; `UserDefaults.synchronize()` returned false and the share controller exited before dispatching its opening request. The previous read-error label concealed this persistence failure. Device trace: `/tmp/soulo-share-input-32-diagnostic-device-20261008.json` (representation metadata only).

Fresh actions now use an atomic JSON snapshot in the App Group, with `NSFileCoordinator` serializing writes, consumption and cancellation across processes/windows. The extension finishes this write before dispatching the opening request. Readers consume only the matching request, retain the seven-day expiry and write an empty snapshot after consumption, preventing repeat delivery. Pending requests from the previous preferences implementation can migrate once when no file snapshot exists; a stale preferences value cannot replay after migration or a newer file-backed share. A cancelled older request cannot erase a newer one. A genuine storage failure uses the existing localized **Save failed** string. App Intents do not dispatch when storage fails.

Apple documents [App Group shared containers](https://developer.apple.com/documentation/xcode/configuring-app-groups) and recommends [file coordination for shared data](https://developer.apple.com/documentation/technologyoverviews/shared-data). Its [preferences synchronization documentation](https://developer.apple.com/documentation/foundation/userdefaults/synchronize()) states that this method is unnecessary and should not be used. The file handoff avoids relying on that return value.

The project has been regenerated at `1.2.1 (33)` for the main app, Share Extension and Widget. The signed Debug package was installed in place on **iPhone 2026** and its installed version was verified using `devicectl`. All three bundles/profile entitlements and deep code signatures passed verification. Build/install logs: `/tmp/soulo-share-storage-33-final-device-build-20261008.log` and `/tmp/soulo-share-storage-33-device-install-20261008.log`.

**Physical-device WeChat acceptance passed.** The developer retried **用其他应用打开 → Soulo** on the same webpage and confirmed **已直接打开原网页**. The build 33 trace independently records a readable `NSURL` followed by `stored`: `/tmp/soulo-share-storage-33-diagnostic-device-20261008.json`. The agent did not operate the phone during this acceptance step. This verifies the reported WeChat flow for iPhone 17 / iOS 26.6.1 / WeChat 8.0.78; it does not claim every host/version or physical multi-device iCloud acceptance.

All **26 selected tests pass, 0 failed, 0 skipped**: 24 unit tests and both actual Safari share-sheet flows (Soulo terminated and backgrounded). The unit cases include fresh file readers, matching IDs, expiry, concurrent single consumption, cancellation of older requests, persistence failure and stale legacy-preferences replay prevention. Safari tests observe the extension foreground the main app and render the exact shared URL without another choice, using the new file handoff. Result: `/tmp/soulo-share-storage-33-20261008.xcresult`; log: `/tmp/soulo-share-storage-33-20261008.log`. Metadata export/check and strict localization pass for all 50 locales (873 keys), with no invisible-character export warnings. No upload or review submission was performed; the developer builds/uploads in Xcode.
