# Xcode device install dependency fix — 2026-11-01

## Failure and cause

The Xcode Run result at 07:35 reported `Missing package product 'SouloTorrent'` before installation. Command-line dependency resolution and signed iPhone builds succeeded, and CoreDevice could install the signed app.

Xcode's GUI log exposed the underlying container collision:

- It tried to open `ThirdParty/SouloTorrent/.swiftpm/xcode` as an Xcode project, expecting a nonexistent `project.pbxproj`.
- It then rejected the package with `Cannot open "SouloTorrent" as a "Swift Package Dependency" because it is already open as a "Folder"`.

Reloading the workspace and resolving locked package versions did not remove that conflicting reference. This explains why command-line-only builds did not catch the GUI failure.

## Change

`project.yml` now links `ThirdParty/SouloTorrent/Artifacts/SouloTorrent.xcframework` directly with `embed: false`, and removes the app's redundant local SwiftPM wrapper dependency. XcodeGen regenerates the project with an XCFramework reference rather than a package-folder reference. The optional package manifest and reproducible engine sources remain available.

The native libraries, module name, signing configuration, version and app data model are unchanged. As a static library, the artifact is linked into the executable instead of embedding the archive in the app bundle. The XCFramework retains its device and simulator slices.

## Validation

Build and install logs are stored outside the repository under `/tmp/soulo-device-install-20261101/`; signing/device identifiers are not included in this note.

- XcodeGen generation: passed.
- Signed Debug build for iPhone 17 / iOS 26.6.1 in a new DerivedData directory: passed. The build explicitly processed the XCFramework's device slice; no prior SwiftPM build products were required.
- `codesign --verify --deep --strict` on the fresh signed app: passed.
- CoreDevice install: succeeded without uninstalling the existing app or clearing its data.
- Xcode GUI Run after regenerating the project: succeeded; the activity status reported `Running Soulo on iPhone 2026`. The device process inventory confirmed the app and widget extension running.

No app version or App Store metadata changes are required for this dependency-reference correction.
