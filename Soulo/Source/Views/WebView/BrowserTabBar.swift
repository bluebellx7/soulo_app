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

// MARK: - Tab Overview (Grid View)

struct TabOverviewView: View {
    @ObservedObject var tabManager: TabManager
    let onNewTab: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()

                if tabManager.tabs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                                    TabOverviewCard(
                                        webViewModel: tab.webViewModel,
                                        keyword: tab.keyword,
                                        isActive: index == tabManager.activeTabIndex,
                                        onTap: {
                                            HapticsManager.selection()
                                            tabManager.switchToTab(at: index)
                                            dismiss()
                                        },
                                        onClose: {
                                            HapticsManager.light()
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                tabManager.closeTab(at: index)
                                            }
                                        }
                                    )
                                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                                }
                            }

                            // Recently closed section
                            if !tabManager.recentlyClosed.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label(
                                            LanguageManager.shared.localizedString("tab_recently_closed"),
                                            systemImage: "clock.arrow.circlepath"
                                        )
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        Spacer()
                                    }

                                    ForEach(tabManager.recentlyClosed.prefix(5)) { closed in
                                        Button {
                                            HapticsManager.selection()
                                            tabManager.restoreClosedTab(closed)
                                            dismiss()
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "globe")
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 24)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(closed.title)
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(1)
                                                    if let host = closed.url?.host {
                                                        Text(host)
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(.tertiary)
                                                            .lineLimit(1)
                                                    }
                                                }

                                                Spacer()

                                                Image(systemName: "arrow.uturn.backward.circle")
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(Color(hex: "6366F1"))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 80)
                    }
                }
            }
            .navigationTitle("\(tabManager.tabCount) \(LanguageManager.shared.localizedString("tab_tabs"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            HapticsManager.light()
                            onNewTab()
                        } label: {
                            Label(LanguageManager.shared.localizedString("tab_new_tab"), systemImage: "plus")
                        }

                        if tabManager.tabs.count > 1 {
                            Divider()
                            Button {
                                tabManager.closeOtherTabs()
                            } label: {
                                Label(LanguageManager.shared.localizedString("tab_close_others"), systemImage: "xmark.circle")
                            }
                            Button(role: .destructive) {
                                tabManager.closeAllTabs()
                            } label: {
                                Label(LanguageManager.shared.localizedString("tab_close_all"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color(hex: "6366F1"))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(LanguageManager.shared.localizedString("tab_no_tabs"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tab Overview Card (observes WebViewModel directly, fixed height)

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
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Header: title + close
                HStack(spacing: 6) {
                    if webViewModel.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isActive ? Color(hex: "6366F1") : .secondary)
                    }

                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color(UIColor.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // Snapshot preview
                if let snapshot = webViewModel.snapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                } else {
                    // Placeholder
                    Rectangle()
                        .fill(Color(UIColor.tertiarySystemFill).opacity(0.5))
                        .frame(height: 120)
                        .overlay {
                            if webViewModel.isLoading {
                                VStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(LanguageManager.shared.localizedString("loading"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            } else if webViewModel.currentURL == nil {
                                Image(systemName: "plus")
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(.quaternary)
                            } else {
                                Image(systemName: "globe")
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                }

                // URL line
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                // Loading progress
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
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isActive ? Color(hex: "6366F1").opacity(0.5) : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: isActive ? Color(hex: "6366F1").opacity(0.15) : .black.opacity(0.05), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onClose()
            } label: {
                Label(LanguageManager.shared.localizedString("tab_close"), systemImage: "xmark")
            }

            if let url = webViewModel.currentURL {
                Button {
                    UIPasteboard.general.url = url
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

// MARK: - Home Tab Overview Sheet (shown from home page)

struct HomeTabOverviewSheet: View {
    @ObservedObject var tabManager: TabManager
    var onSelectTab: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabOverviewCard(
                            webViewModel: tab.webViewModel,
                            keyword: tab.keyword,
                            isActive: index == tabManager.activeTabIndex,
                            onTap: {
                                HapticsManager.selection()
                                tabManager.switchToTab(at: index)
                                onSelectTab()
                            },
                            onClose: {
                                HapticsManager.light()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    tabManager.closeTab(at: index)
                                }
                            }
                        )
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("\(tabManager.tabCount) \(LanguageManager.shared.localizedString("tab_tabs"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
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
