import SwiftUI

struct HelpCenterView: View {
    @Environment(\.dismiss) private var dismiss
    private let lm = LanguageManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lm.localizedString("help_welcome_title"))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(lm.localizedString("help_welcome_subtitle"))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    guideSection(title: lm.localizedString("help_getting_started"), icon: "star.fill", color: .orange) {
                        guideRow(icon: "magnifyingglass", title: lm.localizedString("help_search_title"), desc: lm.localizedString("help_search_desc"))
                        guideRow(icon: "globe", title: lm.localizedString("help_platforms_title"), desc: lm.localizedString("help_platforms_desc"))
                    }

                    guideSection(title: lm.localizedString("help_features"), icon: "sparkles", color: .blue) {
                        guideRow(icon: "bookmark.fill", title: lm.localizedString("help_bookmarks_title"), desc: lm.localizedString("help_bookmarks_desc"))
                        guideRow(icon: "photo.fill", title: lm.localizedString("help_wallpaper_title"), desc: lm.localizedString("help_wallpaper_desc"))
                        guideRow(icon: "shield.checkered", title: lm.localizedString("help_adblock_title"), desc: lm.localizedString("help_adblock_desc"))
                    }

                    guideSection(title: lm.localizedString("help_contact"), icon: "envelope.fill", color: .green) {
                        guideRow(icon: "envelope", title: lm.localizedString("help_email_title"), desc: "contact@dkluge.com")
                    }
                }
                .padding(.vertical)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(lm.localizedString("help_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lm.localizedString("done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func guideSection<Content: View>(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal)

            VStack(spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .padding(.horizontal)
        }
    }

    private func guideRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(desc).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .overlay(Divider().padding(.leading, 52), alignment: .bottom)
    }
}
