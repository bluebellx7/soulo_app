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
                ForEach(BrowserShakeIntensity.allCases) { intensity in
                    Button {
                        selectedIntensity = intensity.rawValue
                        HapticsManager.selection()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: intensity.systemImage)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            Text(LanguageManager.shared.localizedString(intensity.titleKey))
                                .foregroundStyle(.primary)

                            Spacer()

                            if selectedIntensity == intensity.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
