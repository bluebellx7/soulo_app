import SwiftUI

struct ShakeActionSettingsView: View {
    @AppStorage(AppConstants.StorageKeys.shakeAction) private var selectedAction = BrowserShakeAction.none.rawValue

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
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LanguageManager.shared.localizedString("shake_action"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
