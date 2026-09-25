# WeChat → Soulo URL opening

## Apple capability request

Request the **Default Web Browser** managed capability for team `7S2LBJA9VA` and bundle ID `com.dkluge.Soulo` using [Apple's browser capability instructions](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser). The current provisioning profile does not contain this capability; a signed device build with `com.apple.developer.web-browser` fails until Apple grants it.

Apple acknowledged the entitlement request on 2026-09-25. Request ID: `N62U6769DH`. Approval is still pending; the acknowledgement does not grant the capability.

Soulo already offers URL entry, navigation, tabs, bookmarks, search, and direct rendering of HTTP and HTTPS pages. `project.yml` now declares both web URL schemes. `SouloURLRoute` accepts the exact incoming web URL. The full photo-library permission has been removed because image selection uses `PhotosPicker` and saving uses add-only authorization.

After Apple grants the capability:

1. Change the Soulo target's `CODE_SIGN_ENTITLEMENTS` in `project.yml` from `Soulo/Soulo.entitlements` to `Soulo/SouloBrowser.entitlements`.
2. Run `xcodegen generate --spec project.yml`, refresh the provisioning profile, and verify a signed iPhone archive/build.
3. On an iPhone, select Soulo under Settings → Apps → Default Apps → Browser App. Test opening an HTTP and HTTPS link from another app, then test WeChat's **用其它应用打开网址** with Soulo.

If WeChat still invokes Soulo's Share Extension instead of the system browser route, it cannot be made to foreground the containing app through a supported Share Extension API. Keep the App Group handoff for that entry and record the WeChat/iOS versions and the app chooser screen to identify the remaining integration path.
