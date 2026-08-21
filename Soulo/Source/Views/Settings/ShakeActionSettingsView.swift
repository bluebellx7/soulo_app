import SwiftUI

struct ShakeActionSettingsView: View {
    @AppStorage(AppConstants.StorageKeys.shakeAction) private var selectedAction = BrowserShakeAction.none.rawValue
    @AppStorage(AppConstants.StorageKeys.shakeIntensity) private var selectedIntensity = BrowserShakeIntensity.standard.rawValue

    var body: some View {
        List {
            Section {
                ForEach(BrowserShakeAction.allCases) { action in
                    Button {
                        selectedAction = action.rawValue
                        HapticsManager.selection()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.systemImage)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            Text(LanguageManager.shared.localizedString(action.titleKey))
                                .foregroundStyle(.primary)

                            Spacer()

                            if selectedAction == action.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(LanguageManager.shared.localizedString("shake_action_footer"))
            }

            Section {
                HStack(spacing: 7) {
                    ForEach(BrowserShakeIntensity.allCases) { intensity in
                        let isSelected = selectedIntensity == intensity.rawValue
                        Button {
                            selectedIntensity = intensity.rawValue
                            HapticsManager.selection()
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: intensity.systemImage)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(height: 22)

                                Text(LanguageManager.shared.localizedString(intensity.titleKey))
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                            }
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text(LanguageManager.shared.localizedString("shake_intensity"))
            } footer: {
                Text(LanguageManager.shared.localizedString("shake_intensity_footer"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LanguageManager.shared.localizedString("shake_action"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
