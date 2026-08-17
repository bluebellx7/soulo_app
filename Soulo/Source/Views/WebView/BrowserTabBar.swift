import SwiftUI

// MARK: - Browser Tab Bar (Scrollable Strip)

struct BrowserTabBar: View {
    @ObservedObject var tabManager: TabManager
    let onNewTab: () -> Void

    @Namespace private var tabNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
                .frame(maxWidth: 120)

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
        .padding(.vertical, 7)
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
            Button {
                onClose()
            } label: {
                Label(LanguageManager.shared.localizedString("tab_close"), systemImage: "xmark")
            }
        }
    }
}

// MARK: - Tab Switcher Overlay

struct TabSwitcherOverlay: View {
    @ObservedObject var tabManager: TabManager
    let onSelectTab: (Int) -> Void
    let onNewTab: () -> Void
    let onDismiss: () -> Void

    @State private var isExpanding: Bool = false
    @State private var expandingIndex: Int? = nil

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
                    Spacer(minLength: max(geo.safeAreaInsets.top, 12) + 36)

                    if tabManager.tabs.isEmpty {
                        emptyState
                    } else {
                        TabSwitcherCarousel(
                            tabManager: tabManager,
                            isExpanding: $isExpanding,
                            expandingIndex: $expandingIndex,
                            onSelect: { index in
                                HapticsManager.selection()
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    onSelectTab(index)
                                    onDismiss()
                                }
                            },
                            onClose: { index in
                                HapticsManager.light()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                    tabManager.closeTab(at: index)
                                }
                            }
                        )
                        .frame(height: carouselHeight(in: geo))
                        .offset(y: -16)
                    }

                    Spacer(minLength: 18)

                    bottomDock
                        .opacity(isExpanding ? 0 : 1)
                        .scaleEffect(isExpanding ? 0.9 : 1.0)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 10)
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .zIndex(500)
    }

    private var bottomDock: some View {
        HStack(spacing: 14) {
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

            Menu {
                if tabManager.tabs.count > 1 {
                    Button {
                        tabManager.closeOtherTabs()
                    } label: {
                        Label(LanguageManager.shared.localizedString("tab_close_others"), systemImage: "xmark.circle")
                    }
                }

                Button(role: .destructive) {
                    tabManager.closeAllTabs()
                } label: {
                    Label(LanguageManager.shared.localizedString("tab_close_all"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.34), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
            }
            .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))

            iconButton("xmark", label: "done") {
                dismiss()
            }
        }
        .padding(.horizontal, 14)
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
    }

    private func dismiss() {
        HapticsManager.light()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            onDismiss()
        }
    }

    private func carouselHeight(in geo: GeometryProxy) -> CGFloat {
        min(max(geo.size.height * 0.78, 500), max(geo.size.height - 130, 360))
    }
}

// MARK: - Tab Switcher Carousel

private struct TabSwitcherCarousel: View {
    @ObservedObject var tabManager: TabManager
    @Binding var isExpanding: Bool
    @Binding var expandingIndex: Int?
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isHorizontalDragging = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(max(geo.size.width * 0.74, 260), 390)
            let cardSpacing = -cardWidth * 0.24
            let stepDistance = cardWidth + cardSpacing

            ZStack {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabSwitcherCardItem(
                        index: index,
                        tab: tab,
                        isActive: index == tabManager.activeTabIndex,
                        isExpanding: isExpanding,
                        isAnyExpanding: isExpanding,
                        expandingIndex: expandingIndex,
                        cardWidth: cardWidth,
                        stepDistance: stepDistance,
                        dragOffset: dragOffset,
                        viewportWidth: geo.size.width,
                        onSelect: onSelect,
                        onClose: onClose,
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
                              tabManager.tabs.count > 1 else { return }
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

                        if targetIndex != tabManager.activeTabIndex {
                            HapticsManager.selection()
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                                tabManager.focusTabInSwitcher(at: targetIndex)
                                dragOffset = 0
                            }
                        } else {
                            resetDrag()
                        }
                        isHorizontalDragging = false
                    }
            )
            .onChange(of: tabManager.activeTabIndex) { _, _ in
                resetDrag()
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
        let activeIndex = tabManager.activeTabIndex
        let rightLimit = CGFloat(activeIndex) * stepDistance
        let leftLimit = CGFloat(max(tabManager.tabs.count - 1 - activeIndex, 0)) * stepDistance

        if proposed > rightLimit {
            return rightLimit + (proposed - rightLimit) * 0.24
        }
        if proposed < -leftLimit {
            return -leftLimit + (proposed + leftLimit) * 0.24
        }
        return proposed
    }

    private func targetIndex(for projectedOffset: CGFloat, stepDistance: CGFloat) -> Int {
        guard stepDistance > 0 else { return tabManager.activeTabIndex }
        let rawDelta = -projectedOffset / stepDistance
        var delta = Int(rawDelta.rounded())

        if delta == 0, abs(projectedOffset) > stepDistance * 0.22 {
            delta = projectedOffset < 0 ? 1 : -1
        }

        let proposedIndex = tabManager.activeTabIndex + delta
        return min(max(proposedIndex, 0), max(tabManager.tabs.count - 1, 0))
    }
}

// MARK: - Tab Switcher Card Item (Extracted to prevent compiler timeout)

private struct TabSwitcherCardItem: View {
    let index: Int
    let tab: BrowserTab
    let isActive: Bool
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
        let baseOffsetX = CGFloat(index - tabManager.activeTabIndex) * stepDistance + dragOffset
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
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
                .padding(.horizontal, 4)
                .frame(height: 44)

            previewCard
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isExpanding {
                onTap()
            }
        }
        .contextMenu {
            if !isExpanding {
                Button {
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
                        Label(LanguageManager.shared.localizedString("copy_link"), systemImage: "doc.on.doc")
                    }

                    Button {
                        NotificationCenter.default.post(
                            name: .openInNewTab,
                            object: nil,
                            userInfo: ["url": url]
                        )
                    } label: {
                        Label(LanguageManager.shared.localizedString("tab_duplicate"), systemImage: "plus.square.on.square")
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

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.36), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var previewCard: some View {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
            .fill(Color(UIColor.secondarySystemBackground))
            // The card owns the aspect ratio. Snapshot dimensions must never
            // participate in layout because WKWebView can briefly report a
            // transitional viewport while the switcher is opening.
            .aspectRatio(0.56, contentMode: .fit)
            .overlay {
            preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .shadow(
                color: .black.opacity(isActive ? 0.34 : 0.24),
                radius: isActive ? 30 : 18,
                y: isActive ? 18 : 10
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
                            Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.quaternary)
                            if let host = webViewModel.currentURL?.host {
                                Text(host)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 24)
                            }
                        }
                    }
                }
        }
    }
}

// MARK: - Tab Count Badge (for toolbar)

struct TabCountBadge: View {
    let count: Int
    var glassTint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.72), lineWidth: 1.5)
                    .frame(width: 18, height: 18)

                Text("\(min(count, 99))")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.86))
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .browserToolbarButtonGlass(tint: glassTint)
        }
        .accessibilityLabel("\(count) \(LanguageManager.shared.localizedString("tab_tabs"))")
        .accessibilityHint(LanguageManager.shared.localizedString("accessibility_tab_overview_hint"))
    }
}

// MARK: - View Extension for Tab Overview Scale

extension View {
    @ViewBuilder
    func tabOverviewScale(isActive: Bool) -> some View {
        if isActive {
            self
                .scaleEffect(0.90)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .ignoresSafeArea()
        } else {
            self
        }
    }
}
