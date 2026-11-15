import SwiftUI

enum BrowsingDisplayExample: String, Identifiable {
    case topSearch, fullscreen, background, aboveToolbar
    var id: String { rawValue }
    @MainActor var title: String {
        switch self {
        case .topSearch: LanguageManager.shared.localizedString("show_top_search_bar")
        case .fullscreen: LanguageManager.shared.localizedString("keep_fullscreen_browsing")
        case .background: ToolText.text("extend_page_background")
        case .aboveToolbar: LanguageManager.shared.localizedString("keep_page_above_toolbar")
        }
    }
    @MainActor var explanation: String {
        switch self {
        case .topSearch: LanguageManager.shared.localizedString("show_top_search_bar_desc")
        case .fullscreen: LanguageManager.shared.localizedString("keep_fullscreen_browsing_desc")
        case .background: ToolText.text("extend_page_background_desc")
        case .aboveToolbar: LanguageManager.shared.localizedString("keep_page_above_toolbar_desc")
        }
    }
}

struct BrowsingDisplayGuide: View {
    let example: BrowsingDisplayExample
    @Binding var enabled: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    illustration.frame(maxWidth: .infinity)
                    Text(example.explanation).font(.body)
                    Toggle(example.title, isOn: $enabled)
                        .accessibilityIdentifier("browsing-guide.enabled")
                    Text(LanguageManager.shared.localizedString("settings") + " → " + ToolText.text("browsing_display_settings"))
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(example.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                        .accessibilityIdentifier("browsing-guide.done")
                }
            }
        }
        .accessibilityIdentifier("browsing-guide." + example.id)
    }

    private var illustration: some View {
        let extended = example == .background
        return ZStack {
            RoundedRectangle(cornerRadius: 28).fill(extended ? Color(red: 0.8, green: 0.16, blue: 0.16) : Color(uiColor: .secondarySystemGroupedBackground))
            if extended {
                LinearGradient(colors: [.red, .indigo], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
            }
            VStack(spacing: 10) {
                HStack { Capsule().frame(width: 26, height: 5); Spacer(); Image(systemName: "wifi"); Image(systemName: "battery.100") }
                    .font(.system(size: 10)).foregroundStyle(extended ? .white : .secondary).padding(.horizontal, 13)
                if example == .topSearch {
                    HStack { Image(systemName: "magnifyingglass"); Text("Soulo"); Spacer() }
                        .font(.caption).padding(8).background(Color.accentColor.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2))
                }
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(extended ? Color.red.opacity(0.85) : Color.accentColor.opacity(0.18)).frame(height: 40)
                    ForEach(0..<4) { index in
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.15)).frame(width: 32, height: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Capsule().fill(Color.gray.opacity(0.25)).frame(height: 5)
                                Capsule().fill(Color.gray.opacity(0.15)).frame(width: index.isMultiple(of: 2) ? 60 : 90, height: 5)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if example == .aboveToolbar {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4])).frame(height: 22)
                    }
                }
                .padding(10).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    if example == .fullscreen { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.largeTitle).foregroundStyle(Color.accentColor) }
                }
                if example != .fullscreen {
                    HStack { Image(systemName: "house"); Spacer(); Capsule().frame(width: 60, height: 5); Spacer(); Image(systemName: "ellipsis") }
                        .font(.system(size: 12)).padding(10).background(.regularMaterial, in: Capsule())
                }
                Capsule().fill(extended ? .white : Color.primary).frame(width: 65, height: 4)
            }.padding(14)
            RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        }
        .frame(width: 215, height: 370).padding(4).accessibilityHidden(true)
    }
}
