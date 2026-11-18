import SwiftUI

struct GesturesFeedbackSettingsView: View {
    @AppStorage(AppConstants.StorageKeys.shakeAction) private var shakeAction = BrowserShakeAction.none.rawValue

    var body: some View {
        List {
            Section {
                SettingsSubpageLink {
                    ShakeActionSettingsView()
                } label: {
                    SettingsDescriptionLabel(icon: "iphone.radiowaves.left.and.right", color: Color(uiColor: .secondaryLabel),
                        title: LanguageManager.shared.localizedString("shake_action"),
                        description: LanguageManager.shared.localizedString(BrowserShakeAction(rawValue: shakeAction)?.titleKey ?? BrowserShakeAction.none.titleKey))
                }.accessibilityIdentifier("settings.interaction.shake")
                SettingsSubpageLink {
                    BrowserGestureSettingsView()
                } label: {
                    SettingsNavigationLabel(icon: "hand.draw", color: Color(uiColor: .secondaryLabel), title: ToolText.text("gesture_settings_title"))
                }.accessibilityIdentifier("settings.interaction.gestures")
                SettingsSubpageLink {
                    AppFeedbackSettingsView()
                } label: {
                    SettingsNavigationLabel(icon: "speaker.wave.2", color: Color(uiColor: .secondaryLabel), title: ToolText.text("feedback_settings"))
                }.accessibilityIdentifier("settings.interaction.feedback")
                SettingsSubpageLink {
                    AppQuickActionSettingsView()
                } label: {
                    SettingsNavigationLabel(icon: "hand.tap", color: Color(uiColor: .secondaryLabel), title: ToolText.text("app_icon_shortcuts"))
                }.accessibilityIdentifier("settings.interaction.quickActions")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(ToolText.text("gestures_shortcuts_settings"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BrowserGestureSettingsView: View {
    @AppStorage(BrowserSwipePreferences.enabledKey) private var enabled = BrowserSwipePreferences.enabledByDefault
    @AppStorage(BrowserSwipePreferences.executionKey) private var execution = BrowserSwipeExecution.release.rawValue
    @AppStorage(BrowserSwipePreferences.rightKey) private var right = BrowserSwipeDirection.right.defaultAction.rawValue
    @AppStorage(BrowserSwipePreferences.leftKey) private var left = BrowserSwipeDirection.left.defaultAction.rawValue
    @AppStorage(BrowserSwipePreferences.menuKey) private var menuValue = BrowserSwipePreferences.defaultMenuValue
    @AppStorage(BrowserSwipePreferences.noHistoryKey) private var noHistoryAction = BrowserSwipeAction.closeTab.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preview: BrowserSwipeRequest?
    @State private var showsFeedbackSettings = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 18) {
                    TwoFingerSwipeIllustration()
                    Text(ToolText.text("gesture_hint"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8).padding(.bottom, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 8, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle(isOn: $enabled) {
                    SettingsRowLabel(icon: "hand.draw", color: .themePrimary, title: ToolText.text("gesture_title"))
                }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("settings.gestures.enabled")
                directionRow(.right, value: $right)
                    .disabled(!enabled)
                directionRow(.left, value: $left)
                    .disabled(!enabled)
            }

            Section {
                actionRow(.right, symbol: "arrow.right.to.line", value: $noHistoryAction,
                          choices: BrowserSwipeAction.allCases.filter { $0 != .back }, identifier: "noHistory")
            } header: { Text(ToolText.text("gesture_no_history")) }
              footer: { Text(ToolText.text("gesture_no_history_hint")) }

            Section {
                Menu {
                    ForEach(BrowserSwipeExecution.allCases) { mode in
                        Button { execution = mode.rawValue } label: {
                            if execution == mode.rawValue { Label(mode.title, systemImage: "checkmark") }
                            else { Text(mode.title) }
                        }
                    }
                } label: {
                    choiceLabel(title: ToolText.text("gesture_execution"),
                                value: (BrowserSwipeExecution(rawValue: execution) ?? .release).title,
                                symbol: "hand.tap")
                }.accessibilityIdentifier("settings.gestures.execution")
                    .accessibilityLabel(ToolText.text("gesture_execution"))
                    .accessibilityValue((BrowserSwipeExecution(rawValue: execution) ?? .release).title)
                    .buttonStyle(.plain)
            }

            Section {
                if #available(iOS 17.0, *) {
                    NavigationLink {
                        AppFeedbackSettingsView()
                    } label: {
                        SettingsRowLabel(icon: "speaker.wave.2", color: .themePrimary, title: ToolText.text("feedback_settings"))
                    }.accessibilityIdentifier("settings.gestures.feedback")
                } else {
                    Button { showsFeedbackSettings = true } label: {
                        HStack {
                            SettingsRowLabel(icon: "speaker.wave.2", color: .themePrimary, title: ToolText.text("feedback_settings"))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("settings.gestures.feedback")
                }
            }

            if right == BrowserSwipeAction.menu.rawValue || left == BrowserSwipeAction.menu.rawValue || noHistoryAction == BrowserSwipeAction.menu.rawValue {
                Section(ToolText.text("gesture_quick_menu")) {
                    ForEach(BrowserSwipeAction.menuChoices) { action in
                        let selected = BrowserSwipePreferences.menu(value: menuValue)
                        Toggle(isOn: Binding(get: { selected.contains(action) }, set: { include in
                            var items = selected
                            if include { items.append(action) } else { items.removeAll { $0 == action } }
                            menuValue = items.map(\.rawValue).joined(separator: ",")
                        })) { SettingsRowLabel(icon: action.symbol, color: .themePrimary, title: action.title) }
                        .disabled(selected.count == 1 && selected.contains(action))
                    }
                }
            }
        }
        .listStyle(.insetGrouped).compatibleListSectionSpacing(24).tint(.themePrimary)
        .compatibleScrollTopMargin(8)
        .navigationTitle(ToolText.text("gesture_settings_title"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let preview {
                ZStack {
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: dismissPreview)
                    BrowserSwipeHint(request: preview, menu: BrowserSwipePreferences.menu(value: menuValue),
                        automaticallyExecute: false, onAction: { performPreview($0, request: preview) })
                }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: preview.direction == .right ? -24 : 24)).combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(reduceMotion ? nil : preview == nil ? .easeOut(duration: 0.14) : .spring(response: 0.25, dampingFraction: 0.88), value: preview?.id)
        .onDisappear { preview = nil }
        .sheet(isPresented: $showsFeedbackSettings) {
            // A separate hosting boundary avoids iOS 16's nested settings
            // NavigationStack invalidation loop.
            NavigationStack { AppFeedbackSettingsView(showsDoneButton: true) }
        }
    }

    private func dismissPreview() { preview = nil }

    private func performPreview(_ action: BrowserSwipeAction, request: BrowserSwipeRequest) {
        guard request.phase == .ready else { return }
        BrowserSwipeFeedback.executed()
        if action == .closeTab && !reduceMotion {
            request.phase = .executing
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                if preview?.id == request.id { dismissPreview() }
            }
        } else { dismissPreview() }
    }

    private func directionRow(_ direction: BrowserSwipeDirection, value: Binding<String>) -> some View {
        actionRow(direction, symbol: direction.symbol, value: value,
                  choices: BrowserSwipeAction.allCases, identifier: direction.rawValue)
    }

    private func actionRow(_ direction: BrowserSwipeDirection, symbol: String, value: Binding<String>,
                           choices: [BrowserSwipeAction], identifier: String) -> some View {
        let selected = BrowserSwipeAction(rawValue: value.wrappedValue) ?? direction.defaultAction
        return HStack(spacing: 8) {
            Menu {
                ForEach(choices) { action in
                    Button { value.wrappedValue = action.rawValue } label: {
                        Label(action.title, systemImage: selected == action ? "checkmark" : action.symbol)
                    }
                }
            } label: { choiceLabel(title: direction.title, value: selected.title, symbol: symbol) }
                .buttonStyle(.plain)
                .accessibilityLabel(direction.title).accessibilityValue(selected.title)
                .accessibilityIdentifier("settings.gestures.\(identifier)")
            Button {
                preview = BrowserSwipeRequest(direction: direction, action: selected, url: nil, execution: .tap)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.themePrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.themePrimary.opacity(0.08), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(selected == .none)
            .accessibilityLabel("\(direction.title), \(ToolText.text("gesture_preview"))")
            .accessibilityIdentifier("settings.gestures.preview.\(identifier)")
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 44 }
    }

    private func choiceLabel(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: symbol, color: .themePrimary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(value).font(.subheadline).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct AppFeedbackSettingsView: View {
    @AppStorage(AppFeedbackPreferences.hapticsKey) private var haptics = true
    @AppStorage(AppFeedbackPreferences.soundKey) private var sound = false
    var showsDoneButton = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $haptics) {
                    SettingsRowLabel(icon: "waveform.path", color: .themePrimary, title: ToolText.text("gesture_haptics"))
                }.accessibilityIdentifier("settings.feedback.haptics")
                Toggle(isOn: $sound) {
                    SettingsRowLabel(icon: "speaker.wave.2", color: .themePrimary, title: ToolText.text("gesture_sound"))
                }.accessibilityIdentifier("settings.feedback.sound")
            } footer: {
                Text(ToolText.text("feedback_settings_hint"))
            }
            Section {
                Button { BrowserSwipeFeedback.executed() } label: {
                    SettingsRowLabel(icon: "play", color: .themePrimary, title: ToolText.text("gesture_feedback_preview"))
                }
                .disabled(!haptics && !sound)
                .accessibilityIdentifier("settings.feedback.preview")
            }
        }
        .listStyle(.insetGrouped).compatibleListSectionSpacing(24).tint(.themePrimary)
        .navigationTitle(ToolText.text("feedback_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) { FeedbackSettingsDoneButton() }
            }
        }
    }
}

private struct FeedbackSettingsDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button(LanguageManager.shared.localizedString("done")) { dismiss() }
    }
}

/// Vector artwork stays sharp in every display scale and follows the app theme.
struct TwoFingerSwipeIllustration: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color.themePrimary.opacity(0.35)).frame(width: 5, height: 5)
                Capsule().fill(Color.themePrimary.opacity(0.12)).frame(width: 75, height: 6)
                Spacer()
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
            Divider().opacity(0.5)
            ZStack {
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.themePrimary.opacity(0.16)).frame(width: 96, height: 9)
                    ForEach(0..<3) { index in
                        Capsule().fill(Color.primary.opacity(0.06)).frame(width: index == 2 ? 118 : 156, height: 5)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                HStack(spacing: 20) {
                    Image(systemName: "arrow.left").font(.system(size: 20, weight: .medium))
                    VStack(spacing: 12) {
                        ForEach(0..<2) { _ in
                            HStack(spacing: 0) {
                                Capsule().fill(Color.themePrimary.opacity(0.12)).frame(width: 44, height: 3)
                                Circle().fill(Color(uiColor: .systemBackground)).frame(width: 29, height: 29)
                                    .overlay(Circle().stroke(Color.themePrimary, lineWidth: 2))
                                    .overlay(Circle().fill(Color.themePrimary.opacity(0.15)).padding(6))
                            }
                        }
                    }
                    Image(systemName: "arrow.right").font(.system(size: 20, weight: .medium))
                }.foregroundStyle(Color.themePrimary)
            }.frame(height: 104)
        }
        .frame(maxWidth: 264)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.themePrimary.opacity(0.18), lineWidth: 1))
        .shadow(color: Color.themePrimary.opacity(0.08), radius: 16, y: 6)
        .accessibilityHidden(true)
    }
}
