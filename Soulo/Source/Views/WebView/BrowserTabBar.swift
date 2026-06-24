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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                    .background(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.18))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismiss()
                    }

                VStack(spacing: 0) {
                    Spacer(minLength: max(geo.safeAreaInsets.top, 12) + 36)

                    if tabManager.tabs.isEmpty {
                        emptyState
                    } else {
                        TabSwitcherCarousel(
                            tabManager: tabManager,
                            onSelect: { index in
                                onSelectTab(index)
                                dismiss()
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
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(max(geo.size.width * 0.68, 250), 360)
            let horizontalMargin = max((geo.size.width - cardWidth) / 2, 22)
            let cardSpacing = -cardWidth * 0.18

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: cardSpacing) {
                        ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabOverviewCard(
                                webViewModel: tab.webViewModel,
                                keyword: tab.keyword,
                                isActive: index == tabManager.activeTabIndex,
                                onTap: { onSelect(index) },
                                onClose: { onClose(index) }
                            )
                            .frame(width: cardWidth)
                            .scaleEffect(index == tabManager.activeTabIndex ? 1.0 : 0.90)
                            .offset(y: index == tabManager.activeTabIndex ? 0 : 18)
                            .opacity(index == tabManager.activeTabIndex ? 1.0 : 0.82)
                            .zIndex(index == tabManager.activeTabIndex ? 10 : Double(tabManager.tabs.count - abs(index - tabManager.activeTabIndex)))
                            .id(tab.id)
                            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: tabManager.activeTabIndex)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, horizontalMargin)
                    .padding(.vertical, 18)
                }
                .scrollTargetBehavior(.viewAligned)
                .onAppear { scrollToActive(proxy) }
                .onChange(of: tabManager.activeTabIndex) { _, _ in
                    scrollToActive(proxy)
                }
            }
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        guard let id = tabManager.activeTab?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

// MARK: - Tab Overview Card (observes WebViewModel directly)

private struct TabOverviewCard: View {
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

    private var subtitle: String {
        if let host = webViewModel.currentURL?.host { return host }
        if let kw = keyword, !kw.isEmpty { return kw }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
                .padding(.horizontal, 4)

            previewCard
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
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
    }

    private var previewCard: some View {
        ZStack(alignment: .top) {
            preview
                .aspectRatio(0.56, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground))
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))

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
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.22), lineWidth: isActive ? 1.4 : 0.8)
        )
        .shadow(color: .black.opacity(isActive ? 0.34 : 0.24), radius: isActive ? 30 : 18, y: isActive ? 18 : 10)
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
