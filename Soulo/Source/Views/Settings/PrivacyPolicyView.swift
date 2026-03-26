import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    sectionTitle("Privacy Policy")
                    Text("Last updated: March 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    sectionTitle("1. Data Collection")
                    Text("Soulo does not collect, store, or transmit any personal data to external servers. All search queries, bookmarks, and preferences are stored locally on your device.")

                    sectionTitle("2. Search Queries")
                    Text("When you search, Soulo constructs a URL using your keyword and opens it within an embedded browser. Your search terms are sent directly to the selected platform (e.g., Google, Baidu, YouTube) — Soulo does not intercept or store these queries on any server.")

                    sectionTitle("3. Local Storage")
                    Text("The app stores the following data locally on your device:\n• Search history (can be cleared at any time)\n• Bookmarked pages\n• Platform configuration and preferences\n• Language and appearance settings\n\nThis data never leaves your device unless you enable iCloud sync.")
                }

                Group {
                    sectionTitle("4. iCloud Sync")
                    Text("If enabled, your platform configuration and recent keywords are synced via Apple's iCloud Key-Value Store. This data is encrypted by Apple and only accessible by your Apple ID.")

                    sectionTitle("5. Camera & Microphone")
                    Text("Soulo uses microphone access solely for voice search. Audio is processed on-device using Apple's Speech framework. No audio data is recorded, stored, or transmitted.")

                    sectionTitle("6. Third-Party Content")
                    Text("Search results are displayed from third-party platforms via WebView. These platforms have their own privacy policies. Soulo does not control or modify the content displayed by these platforms beyond optional login popup removal.")

                    sectionTitle("7. Children's Privacy")
                    Text("Soulo does not knowingly collect any information from children under 13. The app does not require registration or personal information.")

                    sectionTitle("8. Contact")
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
