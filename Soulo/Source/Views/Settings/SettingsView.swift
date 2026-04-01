import SwiftUI
import PhotosUI
import StoreKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var selectedAppearance: String = ThemeManager.shared.appearance
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = false
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = ""
    @State private var showHomeTitleEdit = false
    @State private var showHomeSubtitleEdit = false
    @State private var editingHomeTitle = ""
    @State private var editingHomeSubtitle = ""
    @State private var showFeedback = false
    @Environment(\.requestReview) private var requestReview

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var currentLanguageName: String {
        LanguageManager.shared.currentLanguageName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemBackground),
                        Color(uiColor: .secondarySystemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                List {
                    // MARK: - Platform Management
                    Section {
                        NavigationLink(destination: PlatformManagementView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_platforms"))
                            } icon: {
                                IconBadge(systemName: "square.grid.2x2.fill", color: .indigo)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_platforms"))
                    }

                    // MARK: - Appearance
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_appearance"))
                            } icon: {
                                IconBadge(systemName: "paintbrush.fill", color: .orange)
                            }
                            .padding(.top, 2)

                            HStack(spacing: 8) {
                                ForEach(["system", "light", "dark"], id: \.self) { mode in
                                    let sel = selectedAppearance == mode
                                    let icon = mode == "system" ? "circle.lefthalf.filled" : mode == "light" ? "sun.max.fill" : "moon.fill"
                                    let name = LanguageManager.shared.localizedString("theme_\(mode)")
                                    Button {
                                        selectedAppearance = mode
                                        HapticsManager.selection()
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            ThemeManager.shared.setAppearance(mode)
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: icon).font(.system(size: 11))
                                            Text(name).font(.system(size: 12, weight: .medium))
                                        }
                                        .foregroundStyle(sel ? .white : .secondary)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .frame(maxWidth: .infinity)
                                        .background(Capsule().fill(sel ? Color.blue : Color(uiColor: .secondarySystemFill)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_appearance"))
                    }

                    // MARK: - Language
                    Section {
                        NavigationLink(destination: LanguageSettingsView()) {
                            Label {
                                HStack {
                                    Text(LanguageManager.shared.localizedString("settings_language"))
                                    Spacer()
                                    Text(currentLanguageName)
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }
                            } icon: {
                                IconBadge(systemName: "globe", color: .blue)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_language"))
                    }

                    // MARK: - Background / Wallpaper
                    Section {
                        NavigationLink(destination: WallpaperSettingsView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_wallpaper"))
                            } icon: {
                                IconBadge(systemName: "photo.fill", color: .teal)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_background"))
                    }

                    // MARK: - Home Customization
                    Section {
                        HStack {
                            Label {
                                Text(LanguageManager.shared.localizedString("edit_title"))
                            } icon: {
                                IconBadge(systemName: "pencil.line", color: .purple)
                            }
                            Spacer()
                            Text(homeTitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showHomeTitleEdit = true }

                        HStack {
                            Label {
                                Text(LanguageManager.shared.localizedString("edit_subtitle"))
                            } icon: {
                                IconBadge(systemName: "text.alignleft", color: .cyan)
                            }
                            Spacer()
                            Text(homeSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showHomeSubtitleEdit = true }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("home_customization"))
                    }

                    // MARK: - Ad Block
                    Section {
                        Toggle(isOn: $adBlockEnabled) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LanguageManager.shared.localizedString("ad_block"))
                                        .font(.body)
                                    Text(LanguageManager.shared.localizedString("ad_block_desc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                IconBadge(systemName: "shield.checkered", color: .green)
                            }
                        }
                        .tint(.green)
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("browsing"))
                    }

                    // MARK: - Home Bookmarks
                    Section {
                        Toggle(isOn: $showBookmarksOnHome) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LanguageManager.shared.localizedString("show_bookmarks_home"))
                                        .font(.body)
                                    Text(LanguageManager.shared.localizedString("show_bookmarks_home_desc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                IconBadge(systemName: "bookmark.fill", color: .orange)
                            }
                        }
                        .tint(.orange)

                        Toggle(isOn: $showGroupPickerOnHome) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LanguageManager.shared.localizedString("show_group_picker_home"))
                                        .font(.body)
                                    Text(LanguageManager.shared.localizedString("show_group_picker_home_desc"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                IconBadge(systemName: "folder.fill", color: .indigo)
                            }
                        }
                        .tint(.indigo)
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("home_screen"))
                    }

                    // MARK: - Privacy
                    Section {
                        NavigationLink(destination: PrivacySettingsView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_privacy"))
                            } icon: {
                                IconBadge(systemName: "hand.raised.fill", color: .green)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_privacy"))
                    }

                    // MARK: - Support
                    Section {
                        Button { requestReview() } label: {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_rate"))
                                    .foregroundStyle(.primary)
                            } icon: {
                                IconBadge(systemName: "star.bubble.fill", color: .yellow)
                            }
                        }

                        Button { showFeedback = true } label: {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_feedback"))
                                    .foregroundStyle(.primary)
                            } icon: {
                                IconBadge(systemName: "envelope.fill", color: .orange)
                            }
                        }

                        NavigationLink {
                            HelpCenterView()
                        } label: {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_help"))
                            } icon: {
                                IconBadge(systemName: "questionmark.circle.fill", color: .teal)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_support"))
                    }

                    // MARK: - About
                    Section {
                        HStack {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_version"))
                            } icon: {
                                IconBadge(systemName: "info.circle.fill", color: .gray)
                            }
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                                .monospacedDigit()
                        }

                        NavigationLink(destination: PrivacyPolicyView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_privacy_policy"))
                            } icon: {
                                IconBadge(systemName: "doc.text.fill", color: .blue)
                            }
                        }

                        NavigationLink(destination: TermsOfServiceView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_terms"))
                            } icon: {
                                IconBadge(systemName: "checkmark.seal.fill", color: .purple)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_about"))
                    } footer: {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Text("Soulo")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                Text("Made with \u{2764}\u{FE0F}")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(LanguageManager.shared.localizedString("settings_title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert(LanguageManager.shared.localizedString("edit_title"), isPresented: $showHomeTitleEdit) {
                TextField("Soulo", text: $editingHomeTitle)
                Button(LanguageManager.shared.localizedString("save")) {
                    let t = editingHomeTitle.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { homeTitle = t }
                }
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            }
            .alert(LanguageManager.shared.localizedString("edit_subtitle"), isPresented: $showHomeSubtitleEdit) {
                TextField("", text: $editingHomeSubtitle)
                Button(LanguageManager.shared.localizedString("save")) {
                    homeSubtitle = editingHomeSubtitle
                }
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            }
            .onAppear {
                editingHomeTitle = homeTitle
                editingHomeSubtitle = homeSubtitle
            }
            .sheet(isPresented: $showFeedback) {
                FeedbackView()
            }
            // Appearance controlled by UIKit via ThemeManager.applyAppearance()
        }
    }
}

// MARK: - Shared Sub-views

struct IconBadge: View {
    let systemName: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.gradient)
                .frame(width: 30, height: 30)
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Identifiable Image Wrapper

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

#Preview {
    SettingsView()
}
