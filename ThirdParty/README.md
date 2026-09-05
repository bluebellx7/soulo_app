# Reading and file tools dependencies

All parsing runs locally. No CDN or runtime script downloads.

- Foliate.js: https://github.com/johnfactotum/foliate-js, revision `78914aef4466eb960965702401634c2cb348e9b1`, MIT.
  - `view.js`: remove the unused generic loader; Soulo supplies validated books.
  - `paginator.js` / `fixed-layout.js`: remove `allow-scripts` from book iframe sandboxes.
  - `mobi.js`: reject encrypted books, bound decoding, extract Print Replica PDF using the container's offset/length fields. No DRM removal.
  - `soulo.js`: app bridge, TXT documents, appearance, search and cover thumbnails.
  - Vendor zip.js and fflate preserve upstream license files.
- Mozilla Readability: https://github.com/mozilla/readability, revision `ab4027a8b37669745016869a37a504727992b2ba`, Apache 2.0. Source is `Soulo/Source/Resources/SouloReadability.js`; license here.
- PLzmaSDK, ZipArchive and Unrar.swift use exact revisions in `project.yml`. They compile from source for device and simulator. UnRAR is extraction-only; its license prohibits using its code to develop a RAR compressor.
- All shipped notices: `Soulo/Source/Resources/ReadingToolsThirdPartyNotices.txt`, visible from Settings → Open-source notices.

Regenerate the bundled reader after source changes:

```sh
npx --yes esbuild@0.28.2 ThirdParty/foliate-js/soulo.js --bundle --format=iife --target=safari17 --minify --outfile=Soulo/Source/Resources/SouloBookEngine.js
```

Commit both source and generated bundle. Xcode does not require Node.js to build the app.

## Privacy resources

The built app includes `PLzmaSDK_PLzmaSDK.bundle/PrivacyInfo.xcprivacy` and `ZipArchive_ZipArchive.bundle/PrivacyInfo.xcprivacy`. SwiftPM may still print an upstream PLzmaSDK unhandled-resource message; both bundles were verified in the device build. Soulo declares disk-space reason `E174.1` for the extraction free-space check, which rejects work when storage is insufficient ([Apple required reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)).
