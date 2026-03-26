import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var themeManager: ThemeManager

    @State private var selectedAppearance: String = ThemeManager.shared.appearance
    @State private var wallpaperMode: WallpaperMode = WallpaperMode(rawValue: UserDefaults.standard.string(forKey: "wallpaper_mode") ?? "bing") ?? .bing
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedDynamicTheme: DynamicTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight
    @State private var wallpaperToEdit: IdentifiableImage? = nil
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = false
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = ""
    @State private var showHomeTitleEdit = false
    @State private var showHomeSubtitleEdit = false
    @State private var editingHomeTitle = ""
    @State private var editingHomeSubtitle = ""
    @State private var customWallpaperImage: Image? = nil
    @State private var showPhotoPicker = false

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

                            Picker("", selection: $selectedAppearance) {
                                Label("System", systemImage: "circle.lefthalf.filled")
                                    .tag("system")
                                Label("Light", systemImage: "sun.max.fill")
                                    .tag("light")
                                Label("Dark", systemImage: "moon.fill")
                                    .tag("dark")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: selectedAppearance) { _, newValue in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    ThemeManager.shared.setAppearance(newValue)
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
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_wallpaper"))
                            } icon: {
                                IconBadge(systemName: "photo.fill", color: .teal)
                            }
                            .padding(.top, 2)

                            Picker("", selection: $wallpaperMode) {
                                Text("Bing").tag(WallpaperMode.bing)
                                Text(LanguageManager.shared.localizedString("wallpaper_custom")).tag(WallpaperMode.custom)
                                Text(LanguageManager.shared.localizedString("wallpaper_none")).tag(WallpaperMode.none)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: wallpaperMode) { _, newValue in
                                BingWallpaperService.shared.setMode(newValue)
                                if newValue == .custom {
                                    showPhotoPicker = true
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        // Custom wallpaper: pick + adjust position
                        if wallpaperMode == .custom {
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                HStack {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .foregroundStyle(.blue)
                                    Text(LanguageManager.shared.localizedString("wallpaper_choose_photo"))
                                        .foregroundStyle(.blue)
                                    Spacer()
                                    if customWallpaperImage != nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .onChange(of: selectedPhotoItem) { _, newItem in
                                Task {
                                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                                       let uiImage = UIImage(data: data) {
                                        await MainActor.run {
                                            wallpaperToEdit = IdentifiableImage(image: uiImage)
                                        }
                                    }
                                }
                            }
                        }

                        // Dynamic theme picker (when mode = none)
                        if wallpaperMode == .none {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(LanguageManager.shared.localizedString("dynamic_theme"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(DynamicTheme.allCases) { theme in
                                            Button {
                                                selectedDynamicTheme = theme
                                                UserDefaults.standard.set(theme.rawValue, forKey: "dynamic_theme")
                                            } label: {
                                                VStack(spacing: 4) {
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(theme.baseColor)
                                                        .overlay(
                                                            ZStack {
                                                                let colors = theme.blobColors
                                                                Circle()
                                                                    .fill(colors[0].0.opacity(colors[0].1 * 2))
                                                                    .frame(width: 20, height: 20)
                                                                    .offset(x: -8, y: -5)
                                                                Circle()
                                                                    .fill(colors[1].0.opacity(colors[1].1 * 2))
                                                                    .frame(width: 16, height: 16)
                                                                    .offset(x: 8, y: 5)
                                                            }
                                                        )
                                                        .frame(width: 52, height: 36)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 8)
                                                                .stroke(selectedDynamicTheme == theme ? Color.blue : Color.clear, lineWidth: 2)
                                                        )

                                                    Text(LanguageManager.shared.localizedString(theme.nameKey))
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(2) // space for selection border
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
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
            .fullScreenCover(item: $wallpaperToEdit) { item in
                WallpaperEditorView(image: item.image) { adjusted in
                    BingWallpaperService.shared.setCustomWallpaper(adjusted)
                    customWallpaperImage = Image(uiImage: adjusted)
                }
            }
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
