import SwiftUI

struct LanguageSettingsView: View {
    @State private var selectedLanguageCode: String = {
        UserDefaults.standard.string(forKey: AppConstants.StorageKeys.selectedLanguage)
        ?? Locale.current.language.languageCode?.identifier
        ?? "en"
    }()
    @State private var animatingCode: String? = nil

    var body: some View {
        ZStack {
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
                Section {
                    ForEach(AppConstants.supportedLanguages, id: \.code) { language in
                        LanguageRowView(
                            language: language,
                            isSelected: selectedLanguageCode == language.code,
                            isAnimating: animatingCode == language.code
                        ) {
                            selectLanguage(language.code)
                        }
                    }
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("language_select_title"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LanguageManager.shared.localizedString("language_footer"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(LanguageManager.shared.localizedString("settings_language"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func selectLanguage(_ code: String) {
        guard code != selectedLanguageCode else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            animatingCode = code
            selectedLanguageCode = code
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            animatingCode = nil
        }

        LanguageManager.shared.setLanguage(code)
    }
}

// MARK: - Language Row View

struct LanguageRowView: View {
    let language: (code: String, name: String, flag: String)
    let isSelected: Bool
    let isAnimating: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Flag emoji in a rounded container
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(uiColor: .tertiarySystemFill),
                                    Color(uiColor: .quaternarySystemFill)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                    ? Color.blue.opacity(0.4)
                                    : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                    Text(language.flag)
                        .font(.system(size: 24))
                }
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
                .scaleEffect(isAnimating ? 1.15 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isAnimating)

                // Language name
                Text(language.name)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(.primary)

                Spacer()

                // Selected checkmark with animation
                if isSelected {
                    ZStack {
                        Circle()
                            .fill(Color.blue.gradient)
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale.combined(with: .opacity))
                    .shadow(color: .blue.opacity(0.4), radius: 4, x: 0, y: 2)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.blue.opacity(0.05) : Color.clear)
                .padding(.horizontal, -4)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

#Preview {
    NavigationStack {
        LanguageSettingsView()
    }
}
