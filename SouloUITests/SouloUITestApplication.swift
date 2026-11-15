import Foundation

/// Physical acceptance uses a separately signed app, leaving the user's
/// installed browser and its data outside the automation target.
enum SouloUITestApplication {
    static var bundleIdentifier: String {
        ProcessInfo.processInfo.environment["SOULO_TEST_APP_BUNDLE_ID"] ?? "com.dkluge.Soulo"
    }
}
