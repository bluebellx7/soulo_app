import SwiftUI

struct TermsOfServiceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    sectionTitle("Terms of Service")
                    Text("Last updated: March 2026")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    sectionTitle("1. Acceptance of Terms")
                    Text("By downloading, installing, or using Soulo, you agree to be bound by these Terms of Service. If you do not agree, please do not use the app.")

                    sectionTitle("2. Description of Service")
                    Text("Soulo is an aggregated search tool that allows you to search across multiple platforms through an embedded browser. Soulo does not host, create, or control the content displayed from third-party platforms.")

                    sectionTitle("3. User Conduct")
                    Text("You agree to use Soulo only for lawful purposes. You are solely responsible for your search queries and interactions with third-party platforms.")
                }

                Group {
                    sectionTitle("4. Intellectual Property")
                    Text("Soulo and its original content, features, and functionality are owned by DKluge. Third-party platform logos and trademarks belong to their respective owners.")

                    sectionTitle("5. Third-Party Services")
                    Text("Soulo provides access to third-party search platforms. We are not responsible for the content, privacy practices, or terms of these platforms. Your use of third-party services is at your own risk.")

                    sectionTitle("6. Disclaimer of Warranties")
                    Text("Soulo is provided \"as is\" without warranties of any kind. We do not guarantee that the app will be uninterrupted, error-free, or that search results from third-party platforms will be accurate.")

                    sectionTitle("7. Limitation of Liability")
                    Text("In no event shall DKluge be liable for any indirect, incidental, or consequential damages arising from your use of Soulo.")

                    sectionTitle("8. Changes to Terms")
                    Text("We reserve the right to modify these terms at any time. Continued use of the app after changes constitutes acceptance of the new terms.")

                    sectionTitle("9. Contact")
                    Text("For questions about these terms, contact us at contact@dkluge.com")
                }
            }
            .font(.system(size: 15))
            .padding(20)
        }
        .navigationTitle("Terms of Service")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .padding(.top, 4)
    }
}
