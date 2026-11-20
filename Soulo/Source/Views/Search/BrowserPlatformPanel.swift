import SwiftUI

struct BrowserPlatformPickerContext {
    let scope: SearchGroupScope
    let selectedPlatformID: UUID?
    let onSelect: (SearchGroupScope, SearchPlatform) -> Void
    var onManage: (() -> Void)? = nil
}

/// Browsing the groups is local to this panel. Only choosing a platform commits
/// the group and navigates, so inspecting another group never replaces the page.
struct BrowserPlatformPanel: View {
    static let inlineChromeHeight: CGFloat = 64
    let context: BrowserPlatformPickerContext
    let onSelect: (SearchGroupScope, SearchPlatform) -> Void
    let onManage: () -> Void
    let onClose: () -> Void
    private let inlineWidth: CGFloat?
    private let inlineHeight: CGFloat?
    private let inlineRowLimit: Int
    @ObservedObject private var store = PlatformDataStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var scope: SearchGroupScope
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 78

    init(context: BrowserPlatformPickerContext,
         inlineWidth: CGFloat? = nil,
         inlineHeight: CGFloat? = nil,
         inlineRowLimit: Int = 3,
         onSelect: @escaping (SearchGroupScope, SearchPlatform) -> Void,
         onManage: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.context = context; self.onSelect = onSelect; self.onManage = onManage; self.onClose = onClose
        self.inlineWidth = inlineWidth
        self.inlineHeight = inlineHeight
        self.inlineRowLimit = inlineRowLimit
        _scope = State(initialValue: context.scope)
    }

    private var currentScope: SearchGroupScope {
        if case .custom(let id) = scope, !store.customGroups.contains(where: { $0.id == id }) {
            return .region(.international)
        }
        return scope
    }
    private var scopes: [SearchGroupScope] {
        PlatformRegion.allCases.map(SearchGroupScope.region) + store.customGroups.map { .custom($0.id) }
    }
    private func platforms(in scope: SearchGroupScope) -> [SearchPlatform] {
        switch scope {
        case .region(let region): store.platforms(for: region)
        case .custom(let id): store.customGroups.first { $0.id == id }.map(store.platformsForGroup) ?? []
        }
    }
    private func title(_ scope: SearchGroupScope) -> String {
        switch scope {
        case .region(let region): store.regionDisplayName(for: region)
        case .custom(let id): store.customGroups.first { $0.id == id }?.name ?? ""
        }
    }

    var body: some View {
        let items = platforms(in: currentScope)
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : inlineWidth.map { min(7, max(2, Int(($0 - 20) / 72))) } ?? 4
        let rows = (items.count + columns - 1) / columns
        let rowSpacing: CGFloat = 6
        let contentHeight = if inlineWidth != nil {
            CGFloat(min(rows, inlineRowLimit)) * (rowHeight + rowSpacing)
        } else {
            CGFloat(rows) * (rowHeight + rowSpacing) + rowSpacing
        }
        let viewportHeight = inlineHeight.map { max(0, $0 - Self.inlineChromeHeight) } ?? .infinity
        let standardHeightLimit: CGFloat = verticalSizeClass == .compact ? 150 : 320
        let heightLimit = inlineWidth != nil && inlineRowLimit > 3 ? contentHeight : standardHeightLimit
        let gridHeight = min(contentHeight, viewportHeight, heightLimit)
        VStack(spacing: 12) {
            HStack {
                Menu {
                    ForEach(scopes) { group in
                        Button {
                            scope = group; HapticsManager.selection()
                        } label: {
                            if currentScope == group { Label(title(group), systemImage: "checkmark") }
                            else { Text(title(group)) }
                        }
                        .accessibilityIdentifier("browser.platformGroup." + group.id)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(title(currentScope)).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.frame(minHeight: 40).contentShape(Rectangle())
                }
                .accessibilityIdentifier("browser.platformGroupPicker")
                .accessibilityLabel(title(currentScope))
                Spacer(minLength: 4)
                Button(action: onManage) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 17))
                        .frame(width: 40, height: 40).contentShape(Circle())
                }
                .accessibilityLabel(LanguageManager.shared.localizedString("platform_management"))
                .accessibilityIdentifier("browser.platforms.settings")
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 40, height: 40).contentShape(Circle())
                }
                .accessibilityLabel(LanguageManager.shared.localizedString("done"))
                .accessibilityIdentifier("browser.platforms.close")
            }.padding(.horizontal, 12)

            if items.isEmpty {
                Text(LanguageManager.shared.localizedString("no_platforms_in_group"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: min(88, viewportHeight))
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: rowSpacing) {
                        ForEach(items) { platform in
                            platformButton(platform)
                        }
                    }.padding(.horizontal, 10).padding(.bottom, rowSpacing)
                }
                .frame(height: gridHeight)
            }
        }
        .buttonStyle(.plain).padding(.vertical, 6)
        .frame(minWidth: inlineWidth ?? 240, idealWidth: inlineWidth ?? 320, maxWidth: inlineWidth ?? 320)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .onCompatibleChange(of: context.scope) { _, initialScope in scope = initialScope }
    }

    private func platformButton(_ platform: SearchPlatform) -> some View {
        let selected = context.selectedPlatformID == platform.id
        return Button { HapticsManager.light(); onSelect(currentScope, platform) } label: {
            VStack(spacing: 7) {
                PlatformIconView(platform: platform, size: 30)
                Text(LanguageManager.shared.localizedString(platform.name))
                    .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: rowHeight)
            .padding(.horizontal, 3)
            .background(selected ? Color.themePrimary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .accessibilityIdentifier("browser.platform." + platform.id.uuidString)
        .accessibilityLabel(LanguageManager.shared.localizedString(platform.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
