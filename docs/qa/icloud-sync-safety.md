# iCloud settings safety — 1.2.1 (30)

## Report and cause

A 1.2.0 (27) user reported that enabling sync after installing Soulo on a new phone immediately removed custom search sites, groups and settings from their old phone and iPad. The old implementation wrote one complete `soulo_settings_payload_v2` snapshot, then treated its `missingKeys` and collection replacements as authoritative. A new installation could publish defaults before iCloud's initial download and replace the established snapshot.

Apple documents that the initial key-value-store download can arrive asynchronously; calling `synchronize()` does not establish that all remote data has arrived. The fix must remain safe even when the first cloud download arrives after the new device's upload. See [NSUbiquitousKeyValueStore](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore).

## Implemented safeguards

- Each installation writes a separate `soulo_settings_v3.<writerID>` journal. Its identity combines a persisted installation ID with the device's vendor ID so restoring device backups cannot create two writers sharing a cloud key. New clients never replace the legacy v2 document.
- Factory preferences are excluded from migration baselines. Legacy documents contribute existing values only; missing keys and empty lists never imply deletions. Explicit v3 edits outrank migration baselines. Conflicts on the same setting use timestamp, sequence and writer ID; different settings and separate site/group/subscription additions merge independently.
- Deletions require an explicit per-item tombstone. Built-in sites use semantic identity, with device UUID aliases retained for group membership. Usage counters and subscription download statistics/errors remain local.
- Local edits made while sync is disabled or the app is closed are compared with a persisted anchor on the next start. Remote reloads do not become fresh user edits or echo uploads. Stable journal encoding prevents repeated uploads of unchanged records.
- Before first migration and before applying remote changes, the service saves a validated atomic local backup. It keeps the initial migration backup indefinitely plus 20 recent copies. Disk/backup errors prevent remote replacement. Invalid cloud documents fail closed without partially applying settings. Quota errors preserve local data; an iCloud account change disables syncing until the user chooses to enable it again.
- Settings → Settings Backups lets the user save and restore copies. Restore first backs up the current settings, disables iCloud, and records the restored differences locally. No restore upload happens until the user enables sync again.

Backups are device-local and contain configuration only. They do not recover data already erased by 1.2.0 before a surviving copy was captured. Keep the app installed and retain any unaffected/offline device or earlier backup. Updating every device to 1.2.1 prevents remaining 1.2.0 clients from continuing their unsafe v2 synchronization with one another.

## Automated verification

On 2026-10-08, Xcode 26.2 / iPhone 17 Pro / iOS 26.2 simulator:

- All 17 `CloudSyncSafetyTests` passed: late initial download, legacy default/empty documents, concurrent changes, explicit deletions, built-in group remapping at migration and after initial sync, exclusion of factory preferences, local usage/cache updates, custom subscription merge, restore without upload, backup retention, backup failure, corrupt journals, quota/account changes, offline changes, Foundation boolean-string preferences and cancellation of pending uploads.
- All four `SharedWebLinkTests`, five `SouloURLRouteTests`, and both selected existing payload/init tests passed. Total: 28 unit tests, zero failures.
- Final unit result: `/tmp/soulo-sync-share-final-unit-20261008.xcresult`; log: `/tmp/soulo-sync-share-final-unit-20261008.log`.
- All three `DefaultBrowserUITests` passed: system Settings handoff, exact URL-based launches and the real Save → Restore confirmation → Restore settings-backup flow. UI passes are in `/tmp/soulo-sync-share-final-tests-20261008.xcresult` and its matching `.log`. That combined bundle also contains unit failures from a test fixture registering process-wide defaults; the fixture was corrected to use its isolated suite and those unit results were superseded by the final successful unit run above.
- Metadata exporter/check passed for all 50 locales. Strict localization passed: 873 keys × 50 locales, with no invisible-character metadata warnings.

## Signed-device acceptance

Use disposable settings with two devices on the same test iCloud account. Test new installation with delayed/offline initial download, enable/disable/re-enable, simultaneous edits to different sites/settings, explicit deletion, and restore followed by deliberate re-enabling. Confirm the existing devices retain their custom sites and groups, the restored device keeps its copy with sync off, and unrelated local cache/usage updates do not create repeated uploads. These tests exercise the real iCloud service and are separate from the deterministic store tests above.
