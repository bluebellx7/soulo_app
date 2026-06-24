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
                            onTap: {
                                HapticsManager.selection()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    tabManager.switchToTab(at: index)
                                }
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
    let onTap: () -> Void
    let onClose: () -> Void

    private var displayTitle: String {
        let title = webViewModel.pageTitle
        if !title.isEmpty { return title }
        if let host = webViewModel.currentURL?.host { return host }
        if let kw = keyword, !kw.isEmpty { return kw }
        return LanguageManager.shared.localizedString("tab_new_tab")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Favicon / loading indicator
                if webViewModel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(isActive ? .white : .secondary)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isActive ? .white : .secondary)
                }

                // Title — reactively updates from webViewModel
                Text(displayTitle)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : .primary.opacity(0.6))
                    .lineLimit(1)
                    .frame(maxWidth: 120)

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isActive ? .white.opacity(0.6) : .secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle().fill(isActive ? .white.opacity(0.15) : Color(UIColor.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isActive
                          ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "7C3AED")],
                                                          startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color(UIColor.tertiarySystemFill))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? Color(hex: "6366F1").opacity(0.3) : Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
                                withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                                    isExpanding = true
                                    expandingIndex = index
                                }
                                // Trigger actual select after animation completes
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
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
            iconButton("plus") {
                HapticsManager.light()
                onNewTab()
                dismiss()
            }

            if let closed = tabManager.recentlyClosed.first {
                iconButton("arrow.uturn.backward") {
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

            iconButton("xmark") {
                dismiss()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
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
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.34), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func dismiss() {
        HapticsManager.light()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            onDismiss()
        }
    }

    private func carouselHeight(in geo: GeometryProxy) -> CGFloat {
        min(max(geo.size.height * 0.72, 430), max(geo.size.height - 170, 320))
    }
}

// MARK: - Tab Switcher Carousel

private struct TabSwitcherCarousel: View {
    @ObservedObject var tabManager: TabManager
    @Binding var isExpanding: Bool
    @Binding var expandingIndex: Int?
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void

    @State private var activeTabId: UUID? = nil

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(max(geo.size.width * 0.68, 250), 360)
            let horizontalMargin = max((geo.size.width - cardWidth) / 2, 22)
            // Adjust spacing to create a tighter iOS-style card stack
            let cardSpacing = -cardWidth * 0.22
            let viewportMinY = geo.frame(in: .global).minY
            let viewportMidX = geo.frame(in: .global).midX
            let safeAreaTop = geo.safeAreaInsets.top

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .center, spacing: cardSpacing) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabSwitcherCardItem(
                            index: index,
                            tab: tab,
                            isActive: index == tabManager.activeTabIndex,
                            isExpanding: isExpanding,
                            isAnyExpanding: isExpanding,
                            expandingIndex: expandingIndex,
                            cardWidth: cardWidth,
                            viewportWidth: geo.size.width,
                            viewportMidX: viewportMidX,
                            viewportMinY: viewportMinY,
                            safeAreaTop: safeAreaTop,
                            onSelect: onSelect,
                            onClose: onClose,
                            tabManager: tabManager
                        )
                        .id(tab.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, horizontalMargin)
                .padding(.vertical, 18)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
            .scrollPosition(id: $activeTabId)
            .onAppear {
                activeTabId = tabManager.activeTab?.id
            }
            .onChange(of: tabManager.activeTabIndex) { _, newIndex in
                if tabManager.tabs.indices.contains(newIndex) {
                    let newId = tabManager.tabs[newIndex].id
                    if activeTabId != newId {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            activeTabId = newId
                        }
                    }
                }
            }
            .onChange(of: tabManager.tabs.map(\.id)) { _, ids in
                if let activeTabId, !ids.contains(activeTabId) {
                    self.activeTabId = tabManager.activeTab?.id
                } else if activeTabId == nil {
                    activeTabId = tabManager.activeTab?.id
                }
            }
            .onChange(of: activeTabId) { _, newValue in
                if let newValue,
                   let index = tabManager.tabs.firstIndex(where: { $0.id == newValue }),
                   index != tabManager.activeTabIndex {
                    HapticsManager.selection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        tabManager.focusTabInSwitcher(at: index)
                    }
                }
            }
        }
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
    let viewportWidth: CGFloat
    let viewportMidX: CGFloat
    let viewportMinY: CGFloat
    let safeAreaTop: CGFloat
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    @ObservedObject var tabManager: TabManager

    var body: some View {
        let isThisExpanding = isExpanding && index == expandingIndex
        let zIndexVal: Double = isThisExpanding ? 200.0 : (isActive ? 100.0 : Double(50 - abs(index - tabManager.activeTabIndex)))
        let scaleValMultiplier: CGFloat = isThisExpanding ? (viewportWidth / cardWidth) * 1.02 : 1.0
        let verticalOffsetVal: CGFloat = isThisExpanding ? -viewportMinY + safeAreaTop - 10.0 : 0.0

        GeometryReader { cardGeo in
            let midX = cardGeo.frame(in: .global).midX
            let distance = midX - viewportMidX
            let stepDistance = cardWidth * 0.78
            let normalizedDistance = stepDistance > 0 ? (distance / stepDistance) : 0.0
            let clampedDistance = min(abs(normalizedDistance), 1.4)
            let centeredness = max(0.0, 1.0 - clampedDistance / 1.4)

            let scaleVal: CGFloat = {
                if isThisExpanding { return 1.0 }
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
                        onTap: { onSelect(index) },
                        onClose: { onClose(index) }
                    )
                }
                .scaleEffect(scaleVal)
                .offset(x: offsetValX, y: offsetValY)
                .opacity(opacityVal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: cardWidth)
        .zIndex(zIndexVal)
        .scaleEffect(scaleValMultiplier)
        .offset(y: verticalOffsetVal)
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
        VStack(alignment: .leading, spacing: isExpanding ? 0 : 10) {
            cardHeader
                .padding(.horizontal, 4)

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
    }

    private var cardHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(width: 32, height: 32)

                if webViewModel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.primary)
                } else {
                    Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                }
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
        .frame(height: isExpanding ? 0 : nil)
        .clipped()
        .opacity(isExpanding ? 0.0 : 1.0)
    }

    private var previewCard: some View {
        ZStack(alignment: .top) {
            preview
                .aspectRatio(0.56, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: isExpanding ? 0 : 34, style: .continuous))

            if webViewModel.isLoading {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [Color(hex: "6366F1"), Color(hex: "7C3AED"), Color(hex: "A855F7")],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * max(webViewModel.estimatedProgress, 0.05), height: 2)
                }
                .frame(height: 2)
                .clipShape(Capsule())
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: isExpanding ? 0 : 34, style: .continuous)
                .stroke(isExpanding ? Color.clear : (isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.22)), lineWidth: isExpanding ? 0 : (isActive ? 1.4 : 0.8))
        )
        .shadow(color: .black.opacity(isExpanding ? 0.0 : (isActive ? 0.34 : 0.24)), radius: isExpanding ? 0 : (isActive ? 30 : 18), y: isExpanding ? 0 : (isActive ? 18 : 10))
    }

    @ViewBuilder
    private var preview: some View {
        if let snapshot = webViewModel.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color(UIColor.tertiarySystemFill).opacity(0.5))
                .overlay {
                    if webViewModel.isLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.regular)
                            Text(LanguageManager.shared.localizedString("loading"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } else if webViewModel.currentURL == nil {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.quaternary)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.quaternary)
                    }
                }
        }
    }
}

// MARK: - Tab Count Badge (for toolbar)

struct TabCountBadge: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 22, height: 22)

                Text("\(min(count, 99))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(.black.opacity(0.35))
                    .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
            )
        }
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
