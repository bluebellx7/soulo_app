import SwiftUI

// MARK: - Browser Tab Bar (Scrollable Strip)

struct BrowserTabBar: View {
    @ObservedObject var tabManager: TabManager
    let onNewTab: () -> Void

    @Namespace private var tabNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        BrowserTabChip(
                            webViewModel: tab.webViewModel,
                            keyword: tab.keyword,
                            isActive: index == tabManager.activeTabIndex,
                            position: index + 1,
                            total: tabManager.tabs.count,
                            onTap: {
                                HapticsManager.selection()
                                tabManager.switchToTab(at: index)
                            },
                            onClose: {
                                HapticsManager.light()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    tabManager.closeTab(at: index)
                                }
                            }
                        )
                        .id(tab.id)
                        .matchedGeometryEffect(id: tab.id, in: tabNamespace)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                    }

                    // New Tab Button
                    Button {
                        HapticsManager.light()
                        onNewTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(UIColor.tertiarySystemFill), in: Circle())
                    }
                    .accessibilityLabel(LanguageManager.shared.localizedString("tab_new_tab"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 42)
            .onAppear {
                if let id = tabManager.activeTab?.id { proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: tabManager.activeTabIndex) { _, _ in
                if let id = tabManager.activeTab?.id {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Single Tab Chip (observes WebViewModel directly)

private struct BrowserTabChip: View {
    @ObservedObject var webViewModel: WebViewModel
    let keyword: String?
    let isActive: Bool
    let position: Int
    let total: Int
    let onTap: () -> Void
    let onClose: () -> Void

    private var displayTitle: String {
        let title = webViewModel.pageTitle
        if !title.isEmpty { return title }
        if let host = webViewModel.currentURL?.host { return host }
        if let kw = keyword, !kw.isEmpty { return kw }
        return LanguageManager.shared.localizedString("tab_new_tab")
    }

    private var chipVisual: some View {
        HStack(spacing: 6) {
            Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.primary.opacity(0.86) : Color.secondary)
                .frame(width: 14, height: 14)

            Text(displayTitle)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary.opacity(0.9) : Color.primary.opacity(0.6))
                .lineLimit(1)
                .frame(maxWidth: 100)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? Color.primary.opacity(0.58) : Color.secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(
                            isActive
                                ? Color.primary.opacity(0.09)
                                : Color(UIColor.tertiarySystemFill)
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule().fill(
                        isActive
                            ? Color.primary.opacity(0.10)
                            : Color.primary.opacity(0.025)
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(
                    isActive
                        ? Color.primary.opacity(0.18)
                        : Color(UIColor.separator).opacity(0.22),
                    lineWidth: isActive ? 0.8 : 0.5
                )
        )
        .contentShape(Capsule())
    }

    var body: some View {
        chipVisual
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppAccessibility.formatted(
                "accessibility_tab_position",
                displayTitle,
                position,
                total
            )
        )
        .accessibilityValue(
            isActive
                ? LanguageManager.shared.localizedString("accessibility_active_tab")
                : ""
        )
        .accessibilityHint(LanguageManager.shared.localizedString("accessibility_open_tab_hint"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text(LanguageManager.shared.localizedString("tab_close"))) {
            onClose()
        }
        .contextMenu {
            Button(role: .destructive) {
                onClose()
            } label: {
                Label(LanguageManager.shared.localizedString("tab_close"), systemImage: "xmark")
            }
        }
    }
}

// MARK: - Tab Switcher Overlay

struct TabSwitcherOverlay: View {
    @AppStorage("show_top_tab_bar") private var showTopTabBar = true
    @AppStorage("tab_overview_grouped") private var showsDomainGroups = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTabOptions = false
    @State private var orderedTabIDs: [UUID] = []
    @ObservedObject var tabManager: TabManager
    let onSelectTab: (Int) -> Void
    let onNewTab: () -> Void
    let onDismiss: () -> Void

    @State private var isExpanding: Bool = false
    @State private var expandingIndex: Int? = nil

    private var orderedTabs: [BrowserTab] {
        guard !orderedTabIDs.isEmpty else { return tabManager.tabsForOverview }
        let byID = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        let known = Set(orderedTabIDs)
        return tabManager.tabs.filter { !known.contains($0.id) } + orderedTabIDs.compactMap { byID[$0] }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .background(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.12))
                    .opacity(isExpanding ? 0.0 : 1.0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isExpanding {
                            dismiss()
                        }
                    }
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    if showsDomainGroups && !tabManager.tabs.isEmpty {
                        TabSwitcherDomainGroups(tabManager: tabManager, tabs: orderedTabs, onSelect: selectTab, onClose: closeTab)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 0) {
                            Spacer(minLength: max(geo.safeAreaInsets.top, 12) + 36)
                            if tabManager.tabs.isEmpty {
                                emptyState
                            } else {
                                TabSwitcherCarousel(
                                    tabManager: tabManager,
                                    tabs: orderedTabs,
                                    isExpanding: $isExpanding,
                                    expandingIndex: $expandingIndex,
                                    onSelect: selectTab,
                                    onClose: closeTab
                                )
                                .frame(height: carouselHeight(in: geo))
                                .offset(y: -16)
                            }
                            Spacer(minLength: 18)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                    }

                    bottomDock
                        .opacity(isExpanding ? 0 : 1)
                        .scaleEffect(isExpanding ? 0.9 : 1.0)
                        .padding(.top, 16)
                        .padding(.bottom, 22)
                }
            }
        }
        .onAppear { orderedTabIDs = tabManager.tabsForOverview.map(\.id) }
        .onChange(of: tabManager.tabs.map(\.id)) { _, ids in
            let liveIDs = Set(ids), knownIDs = Set(orderedTabIDs)
            orderedTabIDs.removeAll { !liveIDs.contains($0) }
            let added = tabManager.tabsForOverview.map(\.id).filter { !knownIDs.contains($0) }
            orderedTabIDs.insert(contentsOf: added, at: 0)
        }
        .transition(.opacity)
        .zIndex(500)
    }

    private var bottomDock: some View {
        HStack(spacing: 14) {
            Button {
                HapticsManager.selection()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    showsDomainGroups.toggle()
                }
            } label: {
                Image(systemName: showsDomainGroups ? "rectangle.stack" : "rectangle.3.group")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(showsDomainGroups ? Color.black.opacity(0.85) : .white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(showsDomainGroups ? .white.opacity(0.94) : .black.opacity(0.34), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString(showsDomainGroups ? "tab_view_carousel" : "tab_view_grouped"))
            .accessibilityValue(LanguageManager.shared.localizedString(showsDomainGroups ? "tab_view_grouped" : "tab_view_carousel"))
            .accessibilityIdentifier("tabs.view-mode")

            iconButton("plus", label: "tab_new_tab") {
                HapticsManager.light()
                onNewTab()
                dismiss()
            }

            if let closed = tabManager.recentlyClosed.first {
                iconButton("arrow.uturn.backward", label: "tab_restore_last") {
                    HapticsManager.selection()
                    tabManager.restoreClosedTab(closed)
                    dismiss()
                }
            }

            Button { showTabOptions = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.34), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
            .accessibilityIdentifier("tabs.options")
            .popover(isPresented: $showTabOptions, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                tabOptionsPanel
                    .presentationCompactAdaptation(.popover)
            }

            iconButton("xmark", label: "done") {
                dismiss()
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabs.dock")
    }

    private func selectTab(_ index: Int) {
        HapticsManager.selection()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            onSelectTab(index)
            onDismiss()
        }
    }

    private func closeTab(_ index: Int) {
        guard tabManager.tabs.indices.contains(index) else { return }
        let closedID = tabManager.tabs[index].id
        let nextID = closedID == tabManager.activeTab?.id ? orderedTabs.first(where: { $0.id != closedID })?.id : nil
        HapticsManager.light()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
            tabManager.closeTab(at: index, nextActiveTabID: nextID)
        }
    }

    private var tabOptionsPanel: some View {
        VStack(spacing: 14) {
            Toggle(isOn: $showTopTabBar) {
                Text(ToolText.text("show_top_tab_bar"))
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Color.themePrimary)
            .accessibilityIdentifier("tabs.show-top-bar")

            HStack(spacing: 12) {
                tabBarPreview(isVisible: true)
                tabBarPreview(isVisible: false)
            }
            .accessibilityHidden(true)
            Text(ToolText.text("top_tab_bar_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            if tabManager.tabs.count > 1 {
                Button {
                    showTabOptions = false
                    tabManager.closeOtherTabs()
                } label: {
                    Label(LanguageManager.shared.localizedString("tab_close_others"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
                .foregroundStyle(.primary)
            }
            Button(role: .destructive) {
                showTabOptions = false
                tabManager.closeAllTabs()
            } label: {
                Label(LanguageManager.shared.localizedString("tab_close_all"), systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: 300)
    }

    private func tabBarPreview(isVisible: Bool) -> some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 7) {
                if isVisible {
                    HStack(spacing: 4) {
                        Capsule().fill(Color.themePrimary.opacity(0.65))
                        Capsule().fill(Color.primary.opacity(0.14))
                    }
                    .frame(height: 12)
                }
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.16)).frame(height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)).frame(height: 5)
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.09)).frame(width: 55, height: 5)
                Spacer(minLength: 0)
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 10)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                showTopTabBar == isVisible ? Color.themePrimary.opacity(0.65) : Color.primary.opacity(0.12), lineWidth: 1))
            Text(LanguageManager.shared.localizedString(isVisible ? "accessibility_enabled" : "accessibility_disabled"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
            Text(LanguageManager.shared.localizedString("tab_no_tabs"))
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func iconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.34), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString(label))
        .accessibilityIdentifier("tabs.\(label)")
    }

    private func dismiss() {
        HapticsManager.light()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            onDismiss()
        }
    }

    private func carouselHeight(in geo: GeometryProxy) -> CGFloat {
        min(max(geo.size.height * 0.70, 440), max(geo.size.height - 130, 360))
    }
}

// MARK: - Domain Groups

@MainActor
struct TabOverviewDomainGroup: Identifiable {
    let id: String
    let title: String
    var tabs: [BrowserTab]

    /// Keep the supplied overview order within each site and the first-seen order of
    /// sites. Only the conventional www alias is folded; unrelated subdomains,
    /// hosted sites and IP addresses must never be merged by a suffix guess.
    static func make(from tabs: [BrowserTab], preservingGroupOrder order: [String] = []) -> [Self] {
        var groups: [Self] = []
        var positions: [String: Int] = [:]
        for tab in tabs {
            let url = tab.webViewModel.currentURL ?? tab.suspendedURL
            let key: String
            let title: String
            if url?.isFileURL == true {
                key = "local-files"
                title = LanguageManager.shared.localizedString("library_files_tab")
            } else if var host = url?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty {
                if host.hasPrefix("www.") { host.removeFirst(4) }
                key = "host:\(host)"
                title = host
            } else if let scheme = url?.scheme {
                key = "scheme:\(scheme.lowercased())"
                title = scheme + ":"
            } else {
                key = "new-tabs"
                title = LanguageManager.shared.localizedString("tab_new_tab")
            }
            if let position = positions[key] {
                groups[position].tabs.append(tab)
            } else {
                positions[key] = groups.count
                groups.append(Self(id: key, title: title, tabs: [tab]))
            }
        }
        guard !order.isEmpty else { return groups }
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let known = Set(order)
        return order.compactMap { byID[$0] } + groups.filter { !known.contains($0.id) }
    }
}

private struct TabSwitcherDomainGroups: View {
    @ObservedObject var tabManager: TabManager
    let tabs: [BrowserTab]
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var orderedGroupIDs: [String] = []

    var body: some View {
        GeometryReader { geometry in
            let groups = TabOverviewDomainGroup.make(from: tabs, preservingGroupOrder: orderedGroupIDs)
            let positions = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset + 1) })
            let columns: CGFloat = dynamicTypeSize.isAccessibilitySize ? 2 : 3
            let cardWidth = min(156, max(90, (geometry.size.width - 48 - (columns - 1) * 12) / columns))
            let previewHeight = min(132, max(96, geometry.size.height / 3.5 - 58))
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(groups) { group in
                        TabDomainGroupRow(
                            group: group, tabManager: tabManager,
                            positions: positions,
                            cardWidth: cardWidth, previewHeight: previewHeight,
                            onSelect: onSelect, onClose: onClose
                        )
                        .id(group.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .accessibilityIdentifier("tabs.groups")
            .onAppear {
                if orderedGroupIDs.isEmpty { orderedGroupIDs = groups.map(\.id) }
            }
            .defaultScrollAnchor(.top)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                }
            }
        }
    }
}

private struct TabDomainGroupRow: View {
    let group: TabOverviewDomainGroup
    @ObservedObject var tabManager: TabManager
    let positions: [UUID: Int]
    let cardWidth: CGFloat
    let previewHeight: CGFloat
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    @State private var focusedID: UUID?
    @ScaledMetric(relativeTo: .caption) private var titleHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text("\(group.tabs.count)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("tabs.group.\(group.id)")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(group.tabs) { tab in
                        TabOverviewCard(
                            webViewModel: tab.webViewModel,
                            keyword: tab.keyword,
                            isActive: tab.id == tabManager.activeTab?.id,
                            isExpanding: false,
                            position: positions[tab.id] ?? 1,
                            total: tabManager.tabCount,
                            onTap: { select(tab.id, action: onSelect) },
                            onClose: { select(tab.id, action: onClose) },
                            compactPreviewHeight: previewHeight
                        )
                        .frame(width: cardWidth)
                        .id(tab.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .defaultScrollAnchor(.leading)
            .scrollPosition(id: $focusedID, anchor: .leading)
            .frame(height: previewHeight + 7 + titleHeight + 4)
            .accessibilityIdentifier("tabs.group-row.\(group.id)")
        }
    }

    private func select(_ id: UUID, action: (Int) -> Void) {
        if let index = tabManager.tabs.firstIndex(where: { $0.id == id }) { action(index) }
    }
}

// MARK: - Tab Switcher Carousel

private struct TabSwitcherCarousel: View {
    @ObservedObject var tabManager: TabManager
    let tabs: [BrowserTab]
    @Binding var isExpanding: Bool
    @Binding var expandingIndex: Int?
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isHorizontalDragging = false
    @State private var focusedTabID: UUID?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var focusedIndex: Int {
        focusedTabID.flatMap { id in tabs.firstIndex { $0.id == id } }
            ?? 0
    }

    private func previewIndices(stepDistance: CGFloat) -> Range<Int> {
        guard !tabs.isEmpty else { return 0..<0 }
        let offset = stepDistance > 0 ? Int((dragOffset / stepDistance).rounded()) : 0
        let center = min(max(focusedIndex - offset, 0), tabs.count - 1)
        return max(0, center - 3)..<min(tabs.count, center + 4)
    }

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(max(geo.size.width * 0.64, 220), 340)
            let cardSpacing = -cardWidth * 0.24
            let stepDistance = cardWidth + cardSpacing

            ZStack {
                // Only nearby cards participate in layout, image loading and
                // gestures, regardless of the number of saved tabs.
                ForEach(previewIndices(stepDistance: stepDistance).map { ($0, tabs[$0]) }, id: \.1.id) { index, tab in
                    TabSwitcherCardItem(
                        index: index,
                        tab: tab,
                        isActive: tab.id == tabManager.activeTab?.id,
                        focusedIndex: focusedIndex,
                        isExpanding: isExpanding,
                        isAnyExpanding: isExpanding,
                        expandingIndex: expandingIndex,
                        cardWidth: cardWidth,
                        stepDistance: stepDistance,
                        dragOffset: dragOffset,
                        viewportWidth: geo.size.width,
                        onSelect: { _ in
                            if let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) { onSelect(index) }
                        },
                        onClose: { _ in
                            guard let actualIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                            if index == focusedIndex {
                                let neighbor = index + 1 < tabs.count ? index + 1 : index - 1
                                focusedTabID = tabs.indices.contains(neighbor) ? tabs[neighbor].id : nil
                            }
                            onClose(actualIndex)
                        },
                        tabManager: tabManager
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard !voiceOverEnabled,
                              !isExpanding,
                              tabs.count > 1 else { return }
                        let isHorizontal = abs(value.translation.width) > abs(value.translation.height)

                        if !isHorizontalDragging && isHorizontal {
                            isHorizontalDragging = true
                        }

                        if isHorizontalDragging {
                            dragOffset = resistedOffset(value.translation.width, stepDistance: stepDistance)
                        }
                    }
                    .onEnded { value in
                        guard !voiceOverEnabled else {
                            resetDrag()
                            return
                        }
                        guard isHorizontalDragging else {
                            resetDrag()
                            return
                        }

                        let projected = resistedOffset(value.predictedEndTranslation.width, stepDistance: stepDistance)
                        let targetIndex = targetIndex(for: projected, stepDistance: stepDistance)

                        if targetIndex != focusedIndex {
                            HapticsManager.selection()
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                                focusedTabID = tabs[targetIndex].id
                                dragOffset = 0
                            }
                        } else {
                            resetDrag()
                        }
                        isHorizontalDragging = false
                    }
            )
            .onAppear { focusedTabID = tabs.first?.id }
            .onChange(of: tabs.map(\.id)) { _, ids in
                if let focusedTabID, ids.contains(focusedTabID) { return }
                focusedTabID = tabs.first?.id
                resetDrag()
            }
            .accessibilityScrollAction { direction in
                let delta = direction == .leading ? 1 : -1
                let index = min(max(focusedIndex + delta, 0), tabs.count - 1)
                if tabs.indices.contains(index) { focusedTabID = tabs[index].id }
            }
            .overlay(alignment: .bottom) {
                if tabs.count > 20 {
                    VStack(spacing: 0) {
                        Text("\(focusedIndex + 1) / \(tabs.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                        Slider(value: Binding(
                            get: { Double(focusedIndex) },
                            set: { value in
                                let index = Int(value)
                                if tabs.indices.contains(index) { focusedTabID = tabs[index].id }
                            }
                        ), in: 0...Double(tabs.count - 1), step: 1)
                        .tint(.white)
                        .accessibilityLabel(LanguageManager.shared.localizedString("tab_tabs"))
                        .accessibilityValue("\(focusedIndex + 1) / \(tabs.count)")
                        .accessibilityIdentifier("tabs.position")
                    }
                    .padding(.horizontal, 40)
                    .offset(y: 42)
                }
            }
        }
    }

    private func resetDrag() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            dragOffset = 0
        }
        isHorizontalDragging = false
    }

    private func resistedOffset(_ proposed: CGFloat, stepDistance: CGFloat) -> CGFloat {
        let activeIndex = focusedIndex
        let rightLimit = CGFloat(activeIndex) * stepDistance
        let leftLimit = CGFloat(max(tabs.count - 1 - activeIndex, 0)) * stepDistance

        if proposed > rightLimit {
            return rightLimit + (proposed - rightLimit) * 0.24
        }
        if proposed < -leftLimit {
            return -leftLimit + (proposed + leftLimit) * 0.24
        }
        return proposed
    }

    private func targetIndex(for projectedOffset: CGFloat, stepDistance: CGFloat) -> Int {
        guard stepDistance > 0 else { return focusedIndex }
        let rawDelta = -projectedOffset / stepDistance
        var delta = Int(rawDelta.rounded())

        if delta == 0, abs(projectedOffset) > stepDistance * 0.22 {
            delta = projectedOffset < 0 ? 1 : -1
        }

        let proposedIndex = focusedIndex + delta
        return min(max(proposedIndex, 0), max(tabs.count - 1, 0))
    }
}

// MARK: - Tab Switcher Card Item (Extracted to prevent compiler timeout)

private struct TabSwitcherCardItem: View {
    let index: Int
    let tab: BrowserTab
    let isActive: Bool
    let focusedIndex: Int
    let isExpanding: Bool
    let isAnyExpanding: Bool
    let expandingIndex: Int?
    let cardWidth: CGFloat
    let stepDistance: CGFloat
    let dragOffset: CGFloat
    let viewportWidth: CGFloat
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    @ObservedObject var tabManager: TabManager

    var body: some View {
        let isThisExpanding = isExpanding && index == expandingIndex
        let scaleValMultiplier: CGFloat = 1.0
        let baseOffsetX = CGFloat(index - focusedIndex) * stepDistance + dragOffset
        let layerDistance = stepDistance > 0 ? abs(baseOffsetX / stepDistance) : 0
        let zIndexVal: Double = isThisExpanding ? 200.0 : Double(100.0 - min(layerDistance, 5.0))

        GeometryReader { _ in
            let normalizedDistance = stepDistance > 0 ? (baseOffsetX / stepDistance) : 0.0
            let clampedDistance = min(abs(normalizedDistance), 1.4)
            let centeredness = max(0.0, 1.0 - clampedDistance / 1.4)

            let scaleVal: CGFloat = {
                if isThisExpanding { return 1.08 }
                return CGFloat(0.82 + centeredness * 0.18)
            }()

            let offsetValX: CGFloat = isThisExpanding ? 0.0 : CGFloat(normalizedDistance) * cardWidth * -0.14
            let offsetValY: CGFloat = isThisExpanding ? 0.0 : CGFloat(1.0 - centeredness) * 22.0

            let opacityVal: Double = {
                if isAnyExpanding { return isThisExpanding ? 1.0 : 0.0 }
                return 0.74 + centeredness * 0.26
            }()

            ZStack {
                CardSwipeWrapper(
                    index: index,
                    onClose: { onClose(index) },
                    onTap: { onSelect(index) }
                ) {
                    TabOverviewCard(
                        webViewModel: tab.webViewModel,
                        keyword: tab.keyword,
                        isActive: isActive,
                        isExpanding: isThisExpanding,
                        position: index + 1,
                        total: tabManager.tabs.count,
                        onTap: { onSelect(index) },
                        onClose: { onClose(index) }
                    )
                }
                .scaleEffect(scaleVal)
                .offset(x: baseOffsetX + offsetValX, y: offsetValY)
                .opacity(opacityVal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: cardWidth)
        .zIndex(zIndexVal)
        .scaleEffect(scaleValMultiplier)
    }
}

// MARK: - Card Swipe Wrapper for Gesture dismiss

struct CardSwipeWrapper<Content: View>: View {
    let index: Int
    let onClose: () -> Void
    let onTap: () -> Void
    let content: Content

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissed = false
    @State private var isDraggingVertically = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    init(index: Int, onClose: @escaping () -> Void, onTap: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.index = index
        self.onClose = onClose
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        content
            .offset(y: dragOffset.height)
            .opacity(isDismissed ? 0 : (1.0 - min(max(0, -dragOffset.height) / 250.0, 0.85)))
            .scaleEffect(isDismissed ? 0.8 : (1.0 - min(max(0, -dragOffset.height) / 1000.0, 0.15)))
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard !voiceOverEnabled else { return }
                        let isVertical = abs(value.translation.height) > abs(value.translation.width)

                        if !isDraggingVertically && isVertical {
                            isDraggingVertically = true
                        }

                        if isDraggingVertically {
                            // Only allow dragging upwards (or tiny bit down with resistance)
                            let previousHeight = dragOffset.height
                            if value.translation.height < 0 {
                                dragOffset = value.translation

                                // Haptic feedback when crossing the threshold
                                if value.translation.height < -120 && previousHeight >= -120 {
                                    HapticsManager.light()
                                }
                            } else {
                                dragOffset = CGSize(width: 0, height: value.translation.height * 0.15)
                            }
                        }
                    }
                    .onEnded { value in
                        guard !voiceOverEnabled else {
                            dragOffset = .zero
                            isDraggingVertically = false
                            return
                        }
                        if isDraggingVertically {
                            let velocity = value.predictedEndLocation.y - value.location.y
                            if value.translation.height < -100 || velocity < -150 {
                                // Fly away animation
                                HapticsManager.light()
                                withAnimation(.easeOut(duration: 0.22)) {
                                    dragOffset = CGSize(width: 0, height: -600)
                                    isDismissed = true
                                }
                                // Call onClose after animation
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                    onClose()
                                }
                            } else {
                                // Snap back
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                        isDraggingVertically = false
                    }
            )
    }
}

// MARK: - Tab Overview Card (observes WebViewModel directly)

private struct TabOverviewCard: View {
    @ObservedObject var webViewModel: WebViewModel
    let keyword: String?
    let isActive: Bool
    let isExpanding: Bool
    let position: Int
    let total: Int
    let onTap: () -> Void
    let onClose: () -> Void
    var compactPreviewHeight: CGFloat? = nil
    @ScaledMetric(relativeTo: .caption) private var compactTitleHeight: CGFloat = 30

    private var displayTitle: String {
        let title = webViewModel.pageTitle
        if !title.isEmpty { return title }
        if let host = webViewModel.currentURL?.host { return host }
        if let kw = keyword, !kw.isEmpty { return kw }
        return LanguageManager.shared.localizedString("tab_new_tab")
    }

    private var subtitle: String {
        if let host = webViewModel.currentURL?.host { return host }
        if let kw = keyword, !kw.isEmpty { return kw }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compactPreviewHeight == nil ? 10 : 7) {
            if let compactPreviewHeight {
                previewSurface
                    .frame(height: compactPreviewHeight)
                    .overlay(alignment: .topTrailing) {
                        closeButton(size: 26)
                    }
                Text(displayTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(isActive ? 1 : 0.78))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: compactTitleHeight, maxHeight: compactTitleHeight, alignment: .topLeading)
                    .padding(.horizontal, 2)
            } else {
                cardHeader
                    .padding(.horizontal, 4)
                    .frame(height: 44)
                previewSurface
                    .aspectRatio(0.56, contentMode: .fit)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isExpanding {
                onTap()
            }
        }
        .contextMenu {
            if !isExpanding {
                Button(role: .destructive) {
                    onClose()
                } label: {
                    Label(LanguageManager.shared.localizedString("tab_close"), systemImage: "xmark")
                }

                if let url = webViewModel.currentURL {
                    Button {
                        UIPasteboard.general.url = url
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        NotificationCenter.default.post(name: .linkCopied, object: nil)
                    } label: {
                        tabContextLabel("copy_link", systemImage: "doc.on.doc")
                    }

                    Button {
                        NotificationCenter.default.post(
                            name: .openInNewTab,
                            object: nil,
                            userInfo: ["url": url]
                        )
                    } label: {
                        tabContextLabel("tab_duplicate", systemImage: "plus.square.on.square")
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppAccessibility.formatted(
                "accessibility_tab_position",
                displayTitle,
                position,
                total
            )
        )
        .accessibilityValue(
            isActive
                ? LanguageManager.shared.localizedString("accessibility_active_tab")
                : subtitle
        )
        .accessibilityHint(LanguageManager.shared.localizedString("accessibility_open_tab_hint"))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction {
            if !isExpanding { onTap() }
        }
        .accessibilityAction(named: Text(LanguageManager.shared.localizedString("tab_close"))) {
            if !isExpanding { onClose() }
        }
        .accessibilityIdentifier(webViewModel.snapshot == nil ? "tabs.card.placeholder" : "tabs.card.preview")
        .task(id: webViewModel.snapshotRevision) { await webViewModel.loadSnapshotIfNeeded() }
        .onDisappear {
            if !webViewModel.showSnapshotWhileRestoring { webViewModel.releaseSnapshotMemory() }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 32, height: 32)

                Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.24), radius: 2, y: 1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            closeButton(size: 30)
        }
    }

    private func closeButton(size: CGFloat) -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: size, height: size)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("tab_close"))
    }

    private var previewSurface: some View {
        let radius: CGFloat = compactPreviewHeight == nil ? 18 : 12
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(UIColor.secondarySystemBackground))
            // The card owns the aspect ratio. Snapshot dimensions must never
            // participate in layout because WKWebView can briefly report a
            // transitional viewport while the switcher is opening.
            .overlay {
                GeometryReader { proxy in
                    preview
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if compactPreviewHeight != nil {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(isActive ? 0.92 : 0.12), lineWidth: isActive ? 1.5 : 0.5)
                }
            }
            .shadow(
                color: .black.opacity(isActive ? 0.34 : 0.24),
                radius: compactPreviewHeight == nil ? (isActive ? 30 : 18) : 6,
                y: compactPreviewHeight == nil ? (isActive ? 18 : 10) : 3
            )
    }

    @ViewBuilder
    private var preview: some View {
        if let snapshot = webViewModel.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color(UIColor.tertiarySystemFill).opacity(0.5))
                .overlay {
                    if webViewModel.currentURL == nil {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.quaternary)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: webViewModel.errorMessage == nil ? "globe" : "wifi.exclamationmark")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.quaternary)
                            if let host = webViewModel.currentURL?.host {
                                Text(host)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                            }
                            Text(LanguageManager.shared.localizedString(webViewModel.errorMessage == nil ? "browser_open_page" : "load_error"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
        }
    }
}

/// The same count symbol appears in the toolbar and the More panel.
struct TabCountSymbol: View {
    let count: Int
    var outlineOpacity = 1.0
    var numberOpacity = 1.0
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(lineWidth: 1.5).frame(width: count > 99 ? 22 : 18, height: 18)
                .opacity(outlineOpacity)
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .opacity(numberOpacity)
        }.frame(width: 23, height: 23)
        .accessibilityHidden(true)
    }
}

// MARK: - Tab Count Badge (for toolbar)

struct TabCountBadge: View {
    let count: Int
    var glassTint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TabCountSymbol(count: count, outlineOpacity: 0.72, numberOpacity: 0.86)
            .foregroundStyle(Color.primary)
            .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
            .contentShape(Circle())
            .browserToolbarButtonGlass(tint: glassTint)
            .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
        }
        .accessibilityLabel("\(count) \(LanguageManager.shared.localizedString("tab_tabs"))")
        .accessibilityIdentifier("browser.tabs")
        .accessibilityHint(LanguageManager.shared.localizedString("accessibility_tab_overview_hint"))
    }
}

// MARK: - View Extension for Tab Overview Scale

extension View {
    func tabOverviewScale(isActive: Bool) -> some View {
        // Preserve structural identity: branching here dismantles and reattaches
        // the live WKWebView while WebKit is presenting its text-selection menu.
        // Keep layout and safe-area geometry unchanged during presentation.
        // Extending safe areas only while active moves both browser toolbars,
        // causing visible jumps beneath the full-screen backdrop.
        self
            .scaleEffect(isActive ? 0.96 : 1)
            .opacity(isActive ? 0.45 : 1)
            .allowsHitTesting(!isActive)
            .accessibilityHidden(isActive)
    }
}

// Native context menus otherwise inherit the app accent color for template images.
@MainActor
private func tabContextLabel(_ key: String, systemImage: String) -> some View {
    Label {
        Text(LanguageManager.shared.localizedString(key))
    } icon: {
        if let image = UIImage(systemName: systemImage)?.withTintColor(.label, renderingMode: .alwaysOriginal) {
            Image(uiImage: image)
        } else {
            Image(systemName: systemImage).foregroundStyle(.primary)
        }
    }
}
