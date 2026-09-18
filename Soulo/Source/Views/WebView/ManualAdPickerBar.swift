import SwiftUI

struct ManualAdPickerBar: View {
    @ObservedObject var model: WebViewModel
    @State private var wholeSite = true

    var body: some View {
        VStack(spacing: 10) {
            if let savedID = model.manualAdSavedRuleID {
                HStack {
                    Label(ToolText.text("manual_ad_saved"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                    Spacer()
                }
                HStack(spacing: 16) {
                    Button(LanguageManager.shared.localizedString("restore")) {
                        ManualAdBlockService.shared.remove(savedID)
                        model.manualAdSavedRuleID = nil
                    }
                    .frame(minHeight: 44)
                    Spacer(minLength: 0)
                    Button(ToolText.text("manual_ad_continue")) {
                        model.beginMarkingAdvertisement()
                    }
                    .frame(minHeight: 44)
                    .disabled(!model.canMarkAdvertisement)
                    .accessibilityIdentifier("browser.manualAdContinue")
                    Button(ToolText.text("done")) { model.manualAdSavedRuleID = nil }
                        .frame(minHeight: 44)
                }
            } else if let selection = model.manualAdSelection {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ToolText.text("manual_ad_mark")).font(.headline)
                        Text(ToolText.text(selection.invalid ? "manual_ad_invalid" : "manual_ad_hint"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(ToolText.text("cancel")) { model.cancelMarkingAdvertisement() }
                        .frame(minHeight: 44)
                }
                if selection.hasSelection {
                    HStack(spacing: 12) {
                        rangeButton("manual_ad_smaller", icon: "arrow.down.right.and.arrow.up.left", action: "smaller", enabled: selection.canShrink)
                        rangeButton("manual_ad_larger", icon: "arrow.up.left.and.arrow.down.right", action: "larger", enabled: selection.canExpand)
                        Spacer(minLength: 0)
                        Button {
                            model.adjustMarkedAdvertisement("preview")
                        } label: {
                            Label(ToolText.text("manual_ad_preview"), systemImage: selection.isPreviewing ? "eye.slash.fill" : "eye")
                                .frame(minHeight: 44)
                        }
                        .accessibilityValue(selection.isPreviewing ? LanguageManager.shared.localizedString("status_enabled") : LanguageManager.shared.localizedString("status_disabled"))
                    }
                    .disabled(model.manualAdBusy)

                    Picker(ToolText.text("manual_ad_scope"), selection: $wholeSite) {
                        Text(ToolText.text("manual_ad_page")).tag(false)
                        Text(ToolText.text("manual_ad_site")).tag(true)
                    }.pickerStyle(.segmented)
                    Button {
                        model.saveMarkedAdvertisement(wholeSite: wholeSite)
                    } label: {
                        Text(ToolText.text("manual_ad_hide"))
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.manualAdBusy)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.manualAdPicker")
        .onChange(of: model.manualAdSelection?.token) { _, _ in
            wholeSite = true
        }
    }

    private func rangeButton(_ key: String, icon: String, action: String, enabled: Bool) -> some View {
        Button { model.adjustMarkedAdvertisement(action) } label: {
            Image(systemName: icon).frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityLabel(ToolText.text(key))
    }
}

// Reserve the complete panel height as soon as picking begins. Selecting,
// previewing and saving must not trigger another responsive page relayout.
struct ManualAdPickerPanel: View {
    @ObservedObject var model: WebViewModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            ManualAdPickerBar(model: model)
        }
        .frame(height: verticalSizeClass == .compact ? 180 : 286, alignment: .top)
        .background(.regularMaterial)
    }
}
