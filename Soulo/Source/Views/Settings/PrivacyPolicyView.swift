import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    sectionTitle("Privacy Policy")
                    Text("Last updated: August 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    sectionTitle("1. Data Collection")
                    Text("Soulo does not collect, store, or transmit any personal data to external servers. All search queries, bookmarks, and preferences are stored locally on your device.")

                    sectionTitle("2. Search Queries")
                    Text("When you search, Soulo constructs a URL using your keyword and opens it within an embedded browser. Your search terms are sent directly to the selected platform (e.g., Google, Baidu, YouTube) — Soulo does not intercept or store these queries on any server.")

                    sectionTitle("3. Local Storage")
                    Text("The app stores the following data locally on your device:\n• Search history (can be cleared at any time)\n• Web pages visited in the last 3 days (cleared with browsing cache)\n• Bookmarked pages\n• Platform configuration and preferences\n• Language and appearance settings\n\nOnly the settings described below leave your device when you enable iCloud sync.")
                }

                Group {
                    sectionTitle("4. iCloud Sync")
                    Text("If enabled, appearance, home, browsing, privacy, wallpaper preferences, platform configuration, and site rules are synced via Apple's iCloud Key-Value Store. Search and browsing history, bookmarks, cache, cookies and login data, downloads, private-browsing state, and wallpaper image files are never synced. Synced settings are protected by Apple and accessible only through your Apple ID.")

                    sectionTitle("5. Camera & Microphone")
                    Text("Soulo uses microphone access for voice search. Soulo may also let a website request camera or microphone access for features such as calls, recording, scanning codes, or taking a photo. Secure websites reach the system permission prompt only when they request access, and Soulo never grants access automatically. Soulo does not record, store, or send captured audio or video to a Soulo server; a website you approve may process it under that website's privacy policy.")

                    sectionTitle("6. Third-Party Content")
                    Text("Search results are displayed from third-party platforms via WebView. These platforms have their own privacy policies. Soulo does not control their content. Optional ad filtering may block known advertising requests and hide matching page elements.")

                    sectionTitle("7. User-Installed Scripts")
                    Text("UserScript is an experimental, opt-in browser feature. A script you choose to install can read or modify matching web pages and may make network requests according to its code. Soulo does not install scripts automatically or send their data to a Soulo server. Only install and enable scripts from authors you trust.")

                    sectionTitle("8. Children's Privacy")
                    Text("Soulo does not knowingly collect any information from children under 13. The app does not require registration or personal information.")

                    sectionTitle("9. Contact")
                    Text("If you have questions about this privacy policy, please contact us at contact@dkluge.com")
                }
            }
            .font(.system(size: 15))
            .padding(20)
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .padding(.top, 4)
    }
}
