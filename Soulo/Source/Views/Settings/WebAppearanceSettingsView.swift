import SwiftUI

struct WebAppearanceSettingsView: View {
    @ObservedObject private var appearance = WebAppearanceService.shared

    var body: some View {
        List {
            Section {
                appearanceToggle(
                    isOn: $appearance.followsAppColorScheme,
                    icon: "circle.lefthalf.filled",
                    titleKey: "web_follow_app_scheme",
                    descriptionKey: "web_follow_app_scheme_desc"
                )
            }

            Section {
                appearanceToggle(
                    isOn: $appearance.warmColorShift,
                    icon: "sun.haze.fill",
                    titleKey: "web_warm_color_shift",
                    descriptionKey: "web_warm_color_shift_desc"
                )

                appearanceToggle(
                    isOn: $appearance.forceDarkPages,
                    icon: "moon.stars.fill",
                    titleKey: "web_force_dark",
                    descriptionKey: "web_force_dark_desc"
                )
            } header: {
                Text(LanguageManager.shared.localizedString("web_page_colors"))
            } footer: {
                Text(LanguageManager.shared.localizedString("web_force_dark_footer"))
            }

            Section {
                appearanceToggle(
                    isOn: $appearance.reducePageMotion,
                    icon: "figure.walk.motion",
                    titleKey: "web_reduce_motion",
                    descriptionKey: "web_reduce_motion_desc"
                )

                appearanceToggle(
                    isOn: $appearance.underlineLinks,
                    icon: "link",
                    titleKey: "web_underline_links",
                    descriptionKey: "web_underline_links_desc"
                )
            } header: {
                Text(LanguageManager.shared.localizedString("web_readability"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LanguageManager.shared.localizedString("web_appearance"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func appearanceToggle(
        isOn: Binding<Bool>,
        icon: String,
        titleKey: String,
        descriptionKey: String
    ) -> some View {
        Toggle(isOn: isOn) {
            SettingsDescriptionLabel(
                icon: icon,
                color: isOn.wrappedValue ? .blue : Color(uiColor: .systemGray3),
                title: LanguageManager.shared.localizedString(titleKey),
                description: LanguageManager.shared.localizedString(descriptionKey)
            )
        }
        .tint(.blue)
    }
}
