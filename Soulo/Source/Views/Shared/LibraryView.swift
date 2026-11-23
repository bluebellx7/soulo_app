import SwiftUI
import UIKit

enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks
    case history
    case downloads
    case files

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .bookmarks: "bookmarks"
        case .history: "search_history"
        case .files: "files"
        case .downloads: "downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .bookmarks: HomeToolbarAction.bookmarks.listSymbol
        case .history: "clock.arrow.circlepath"
        case .files: HomeToolbarAction.files.listSymbol
        case .downloads: HomeToolbarAction.downloads.listSymbol
        }
    }
}

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject var searchVM: SearchViewModel
    @State private var selectedSection: LibrarySection
    @State private var pageProgress: CGFloat
    @State private var showReadingList = false

    init(
        initialSection: LibrarySection = .bookmarks,
        searchVM: SearchViewModel
    ) {
        self.searchVM = searchVM
        _selectedSection = State(initialValue: initialSection)
        _pageProgress = State(initialValue: CGFloat(LibrarySection.allCases.firstIndex(of: initialSection) ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            LibrarySectionSwitcher(selectedSection: $selectedSection, progress: pageProgress)

            libraryPager
        }
        .navigationTitle(LanguageManager.shared.localizedString("library"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .mediaPlayerNavigation()
        .navigationDestination(isPresented: $showReadingList) { ReadingListView() }
        .onReceive(NotificationCenter.default.publisher(for: .openSouloFiles)) { _ in
            selectedSection = .files
        }
    }

    @ViewBuilder private var libraryPager: some View {
        if #available(iOS 17.0, *) {
            LibraryPager(selectedSection: $selectedSection, progress: $pageProgress) { section in
                page(section)
            }
        } else {
            // Capturing LibraryView also captures its dismiss environment. Old
            // SwiftUI can recursively invalidate navigation on player return.
            let onOpen: (String) -> Void = { [dismiss, tabManager, searchVM, modelContext] value in
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    searchVM.openLibrarySelection(value, tabManager: tabManager, context: modelContext)
                }
            }
            LibraryPager(selectedSection: $selectedSection, progress: $pageProgress) {
                [searchVM, onOpen] section in
                LegacyLibraryPage(section: section, searchVM: searchVM, onOpen: onOpen)
            }
        }
    }

    @ViewBuilder
    private func page(_ section: LibrarySection) -> some View {
        switch section {
        case .bookmarks: BookmarksContentView(searchVM: searchVM, onOpen: openSelection, embeddedInLibrary: true, onReadingListOpen: { showReadingList = true })
        case .history: SearchHistoryContentView(searchVM: searchVM, onOpen: openSelection, embeddedInLibrary: true)
        case .downloads: DownloadManagerContentView(embeddedInLibrary: true)
        case .files: LibraryFilesView(embeddedInLibrary: true)
        }
    }

    private func openSelection(_ value: String) {
        let tabs = tabManager
        let model = searchVM
        let context = modelContext
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            model.openLibrarySelection(value, tabManager: tabs, context: context)
        }
    }

}

private struct LegacyLibraryPage: View {
    let section: LibrarySection
    let searchVM: SearchViewModel
    let onOpen: (String) -> Void

    @ViewBuilder var body: some View {
        switch section {
        case .bookmarks: BookmarksContentView(searchVM: searchVM, onOpen: onOpen)
        case .history: SearchHistoryContentView(searchVM: searchVM, onOpen: onOpen)
        case .downloads: DownloadManagerContentView(embeddedInLibrary: true)
        case .files: LibraryFilesView(embeddedInLibrary: true)
        }
    }
}

struct LibraryPager<Content: View>: View {
    @Binding var selectedSection: LibrarySection
    @Binding var progress: CGFloat
    @Environment(\.layoutDirection) private var layoutDirection
    @StateObject private var gestures = LibraryPagingGestures()
    @State private var loadedSections: Set<LibrarySection> = []
    @ViewBuilder let content: (LibrarySection) -> Content

    @ViewBuilder var body: some View {
        if #available(iOS 17.0, *) {
            modernPager
        } else {
            // iOS 16's NavigationStack repeatedly invalidates destinations in
            // sibling pages hosted in one horizontal ScrollView. PageTabView
            // gives each page its own hosting boundary while retaining state.
            TabView(selection: $selectedSection) {
                ForEach(LibrarySection.allCases) { section in
                    content(section)
                        .environment(\.libraryPageIsActive, selectedSection == section)
                        .accessibilityHidden(selectedSection != section)
                        .tag(section)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(LibraryPagingGesturePriority(gestures: gestures, direction: layoutDirection,
                progress: $progress, usesPageController: true))
            .environment(\.libraryPagingGestures, gestures)
            .accessibilityIdentifier("library.pages")
            .onAppear { progress = CGFloat(LibrarySection.allCases.firstIndex(of: selectedSection) ?? 0) }
            .onCompatibleChange(of: selectedSection) { _, section in
                progress = CGFloat(LibrarySection.allCases.firstIndex(of: section) ?? 0)
            }
        }
    }

    @available(iOS 17.0, *)
    private var modernPager: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(LibrarySection.allCases, id: \.self) { section in
                            Group {
                                if section == selectedSection || loadedSections.contains(section) { content(section) }
                                else { Color.clear }
                            }
                                .environment(\.libraryPageIsActive, selectedSection == section)
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .accessibilityHidden(selectedSection != section)
                                .id(section)
                        }
                    }
                    .scrollTargetLayout()
                    .background(LibraryPagingGesturePriority(gestures: gestures,
                        direction: layoutDirection, progress: $progress))
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding(
                    get: { Optional(selectedSection) },
                    set: { if let section = $0 { selectedSection = section } }
                ), anchor: .center)
                .environment(\.libraryPagingGestures, gestures)
                .accessibilityIdentifier("library.pages")
                .onAppear { loadedSections.insert(selectedSection); proxy.scrollTo(selectedSection, anchor: .center) }
                .onCompatibleChange(of: selectedSection) { _, section in loadedSections.insert(section) }
                .onCompatibleChange(of: progress) { _, value in
                    // Materialize only pages reached by a swipe, then retain
                    // their state. Navigation destinations stay in a regular
                    // container rather than an unsupported lazy ancestor.
                    guard value.isFinite else { return }
                    for index in [Int(floor(value)), Int(ceil(value))] where LibrarySection.allCases.indices.contains(index) {
                        loadedSections.insert(LibrarySection.allCases[index])
                    }
                }
                .onCompatibleChange(of: viewport.size.width) { _, width in
                    guard width > 0 else { return }
                    proxy.scrollTo(selectedSection, anchor: .center)
                }
            }
        }
    }
}

struct LibrarySectionSwitcher: View {
    @Binding var selectedSection: LibrarySection
    var progress: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 11

    var body: some View {
        ViewThatFits(in: .horizontal) {
            sectionButtons
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    sectionButtons.fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityIdentifier("library.tabs")
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { proxy.scrollTo(selectedSection, anchor: .center) }
                .onCompatibleChange(of: selectedSection) { _, section in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(section, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, LibraryPageLayout.horizontalMargin)
        .padding(.bottom, 4)
        .background(Color(uiColor: .systemBackground))
    }

    private var sectionButtons: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(LibrarySection.allCases) { section in
                let selected = selectedSection == section
                let titleKey = section == .history ? "library_history_tab" : section == .files ? "library_files_tab" : section.titleKey
                let title = LanguageManager.shared.localizedString(titleKey)
                Button {
                    guard !selected else { return }
                    HapticsManager.selection()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { selectedSection = section }
                } label: {
                    let index = CGFloat(LibrarySection.allCases.firstIndex(of: section) ?? 0)
                    let emphasis = max(0, 1 - abs(displayProgress - index))
                    caption(section, title: title)
                        .foregroundStyle(.secondary)
                        .overlay {
                            caption(section, title: title)
                                .foregroundStyle(Color.themePrimary)
                                .opacity(Double(emphasis))
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(minWidth: 48, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .anchorPreference(key: LibraryTabFramesKey.self, value: .bounds) { [section: $0] }
                .accessibilityLabel(title)
                .accessibilityIdentifier("library.section.\(section.rawValue)")
                .id(section)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if section != .files { Spacer(minLength: 6) }
            }
        }
        .frame(maxWidth: .infinity)
        .backgroundPreferenceValue(LibraryTabFramesKey.self) { anchors in
            GeometryReader { geometry in
                let frames = LibrarySection.allCases.compactMap { anchors[$0].map { geometry[$0] } }
                if frames.count == LibrarySection.allCases.count,
                   let frame = LibraryPageGeometry.indicator(progress: displayProgress, frames: frames) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.themePrimary.opacity(0.1))
                        .frame(width: frame.width, height: max(0, frame.height - 8))
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var displayProgress: CGFloat {
        progress ?? CGFloat(LibrarySection.allCases.firstIndex(of: selectedSection) ?? 0)
    }

    private func caption(_ section: LibrarySection, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: section.systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(height: 20)
            Text(title)
                .font(.system(size: captionSize, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: true)
        }
    }
}

enum LibraryPageLayout {
    static let horizontalMargin: CGFloat = 16
    static let searchRowInsets = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
}

extension View {
    @ViewBuilder func libraryListLayout(embedded: Bool) -> some View {
        let list = listStyle(.insetGrouped)
            .compatibleListSectionSpacing(20)
            .compatibleScrollTopMargin(24)
        if #available(iOS 17.0, *), embedded {
            list.contentMargins(.horizontal, LibraryPageLayout.horizontalMargin, for: .scrollContent)
        } else {
            list
        }
    }
}

// Offscreen pages retain their local state but must not contribute navigation
// items or perform the work that previously happened only on page appearance.
private struct LibraryPageActivityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var libraryPageIsActive: Bool {
        get { self[LibraryPageActivityKey.self] }
        set { self[LibraryPageActivityKey.self] = newValue }
    }
}

private struct LibraryTabFramesKey: PreferenceKey {
    static let defaultValue: [LibrarySection: Anchor<CGRect>] = [:]
    static func reduce(value: inout [LibrarySection: Anchor<CGRect>], nextValue: () -> [LibrarySection: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum LibraryPageGeometry {
    static func progress(frame: CGRect, width: CGFloat, direction: LayoutDirection) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        let offset = direction == .rightToLeft ? frame.maxX - width : -frame.minX
        guard offset.isFinite else { return 0 }
        return min(max(offset / width, 0), CGFloat(LibrarySection.allCases.count - 1))
    }

    static func indicator(progress: CGFloat, frames: [CGRect]) -> CGRect? {
        guard !frames.isEmpty, progress.isFinite else { return nil }
        let position = min(max(progress, 0), CGFloat(frames.count - 1))
        let index = Int(position), fraction = position - CGFloat(index)
        let start = frames[index], end = frames[min(index + 1, frames.count - 1)]
        return CGRect(x: start.minX + (end.minX - start.minX) * fraction,
                      y: start.minY + (end.minY - start.minY) * fraction,
                      width: start.width + (end.width - start.width) * fraction,
                      height: start.height + (end.height - start.height) * fraction)
    }
}

private struct LibraryPagingGesturesKey: EnvironmentKey {
    static let defaultValue: LibraryPagingGestures? = nil
}

private extension EnvironmentValues {
    var libraryPagingGestures: LibraryPagingGestures? {
        get { self[LibraryPagingGesturesKey.self] }
        set { self[LibraryPagingGesturesKey.self] = newValue }
    }
}

/// Only a row's trailing swipe takes priority over paging. Other horizontal
/// drags belong to the pager; the navigation controller keeps its edge swipe.
@MainActor
private final class LibraryPagingGestures: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    private final class Region {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }
    private weak var scroll: UIScrollView?
    private weak var back: UIGestureRecognizer?
    private var rows: [ObjectIdentifier: Region] = [:]
    private let protectedPans = NSHashTable<UIGestureRecognizer>.weakObjects()
    private let backProtectedPans = NSHashTable<UIGestureRecognizer>.weakObjects()
    private var observations: [NSKeyValueObservation] = []
    private var progressQueued = false
    private var lastProgress: CGFloat?
    var onProgress: ((CGFloat) -> Void)?
    var direction: LayoutDirection = .leftToRight
    var isDragging: Bool { scroll?.isDragging == true || scroll?.isTracking == true }
    private lazy var rowSwipe: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRowSwipe))
        gesture.maximumNumberOfTouches = 1
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()
    // A closed trailing-action row can still consume a leading drag even though
    // it has no action on that side. Let native paging recognize that direction.
    private lazy var leadingSwipe: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRowSwipe))
        gesture.maximumNumberOfTouches = 1
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    func connect(_ scroll: UIScrollView, back: UIGestureRecognizer?) {
        if #unavailable(iOS 17.0) { scroll.isPagingEnabled = true }
        if self.scroll !== scroll {
            self.scroll?.removeGestureRecognizer(rowSwipe)
            self.scroll?.removeGestureRecognizer(leadingSwipe)
            observations.forEach { $0.invalidate() }
            self.scroll = scroll
            lastProgress = nil
            observations = [
                scroll.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.scheduleProgress() }
                },
                scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.scheduleProgress() }
                },
                scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.scheduleProgress() }
                }
            ]
            scroll.addGestureRecognizer(rowSwipe)
            scroll.addGestureRecognizer(leadingSwipe)
            scroll.panGestureRecognizer.require(toFail: rowSwipe)
            protectedPans.removeAllObjects()
        }
        if let back, self.back !== back {
            scroll.panGestureRecognizer.require(toFail: back)
            rowSwipe.require(toFail: back)
            leadingSwipe.require(toFail: back)
            self.back = back
            backProtectedPans.removeAllObjects()
        }
        for region in rows.values { if let view = region.view { protectRowPans(in: view) } }
        scheduleProgress()
    }

    private func scheduleProgress() {
        guard !progressQueued else { return }
        progressQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progressQueued = false
            guard let scroll = self.scroll, scroll.bounds.width > 0 else { return }
            let frame = CGRect(x: -scroll.contentOffset.x, y: 0, width: scroll.contentSize.width, height: 0)
            let value = LibraryPageGeometry.progress(frame: frame, width: scroll.bounds.width, direction: self.direction)
            guard self.lastProgress.map({ abs($0 - value) > 0.0001 }) ?? true else { return }
            self.lastProgress = value
            self.onProgress?(value)
        }
    }

    func disconnect() {
        observations.forEach { $0.invalidate() }; observations.removeAll()
        scroll?.removeGestureRecognizer(rowSwipe)
        scroll?.removeGestureRecognizer(leadingSwipe)
        protectedPans.removeAllObjects(); backProtectedPans.removeAllObjects()
        scroll = nil; back = nil; lastProgress = nil
    }

    func register(_ view: UIView) {
        rows[ObjectIdentifier(view)] = Region(view)
        protectRowPans(in: view)
    }
    func unregister(_ view: UIView) { rows.removeValue(forKey: ObjectIdentifier(view)) }

    private func protectRowPans(in view: UIView) {
        guard let scroll else { return }
        var ancestor = view.superview
        while let current = ancestor, current !== scroll {
            for pan in current.gestureRecognizers ?? [] where pan is UIPanGestureRecognizer {
                if !protectedPans.contains(pan) {
                    pan.require(toFail: leadingSwipe)
                    protectedPans.add(pan)
                }
                if let back, !backProtectedPans.contains(pan) {
                    pan.require(toFail: back)
                    backProtectedPans.add(pan)
                }
            }
            ancestor = current.superview
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let scroll else { return false }
        rows = rows.filter { $0.value.view != nil }
        let point = touch.location(in: scroll)
        let distanceFromLeadingEdge = direction == .rightToLeft ? scroll.bounds.maxX - point.x : point.x - scroll.bounds.minX
        if back?.isEnabled == true, distanceFromLeadingEdge < 28 { return false }
        return rows.values.contains { region in
            guard let view = region.view, view.window === scroll.window else { return false }
            return view.convert(view.bounds, to: scroll).contains(point)
        }
    }

    private func hasExpandedSwipeActions() -> Bool {
        guard let scroll else { return false }
        for region in rows.values {
            guard let view = region.view, view.window === scroll.window,
                  view.convert(view.bounds, to: scroll).intersects(scroll.bounds) else { continue }
            var ancestor = view.superview
            while let current = ancestor, current !== scroll {
                if let cell = current as? UICollectionViewCell, cell.configurationState.isSwiped { return true }
                if let cell = current as? UITableViewCell, cell.showingDeleteConfirmation { return true }
                ancestor = current.superview
            }
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: scroll)
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        let trailing = direction == .rightToLeft ? velocity.x > 0 : velocity.x < 0
        // UIKit owns closing an open action row. Reserve this first leading
        // swipe for it, then let a subsequent swipe page the library normally.
        let restoringRow = !trailing && hasExpandedSwipeActions()
        return gestureRecognizer === rowSwipe ? (trailing || restoringRow) : (!trailing && !restoringRow)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === leadingSwipe { return other === scroll?.panGestureRecognizer }
        return other !== scroll?.panGestureRecognizer && other !== back && other !== leadingSwipe
    }

    @objc private func handleRowSwipe(_ gesture: UIPanGestureRecognizer) {
        // The row's existing SwiftUI swipe actions perform the operation.
    }
}

struct LibrarySwipeActionsRegion: View {
    @Environment(\.libraryPagingGestures) private var gestures
    var body: some View {
        if let gestures { Marker(gestures: gestures).allowsHitTesting(false) }
    }

    private struct Marker: UIViewRepresentable {
        let gestures: LibraryPagingGestures
        func makeUIView(context: Context) -> Host { Host(gestures: gestures) }
        func updateUIView(_ view: Host, context: Context) {}

        final class Host: UIView {
            let gestures: LibraryPagingGestures
            init(gestures: LibraryPagingGestures) {
                self.gestures = gestures
                super.init(frame: .zero)
                isUserInteractionEnabled = false
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
            override func didMoveToWindow() {
                super.didMoveToWindow()
                if window != nil { gestures.register(self) } else { gestures.unregister(self) }
            }
        }
    }
}

private struct LibraryPagingGesturePriority: UIViewRepresentable {
    let gestures: LibraryPagingGestures
    let direction: LayoutDirection
    @Binding var progress: CGFloat
    var legacySelection: Binding<LibrarySection>? = nil
    var usesPageController = false
    func makeUIView(context: Context) -> Host { Host(gestures: gestures) }
    func updateUIView(_ view: Host, context: Context) {
        gestures.direction = direction
        view.usesPageController = usesPageController
        let binding = $progress
        gestures.onProgress = usesPageController ? nil : { value in
            // Native contentOffset also changes between SwiftUI layout passes.
            // Use it directly, without a second animation lagging the finger.
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { binding.wrappedValue = value }
            let index = Int(value.rounded())
            if let legacySelection, !gestures.isDragging,
               abs(value - value.rounded()) < 0.001,
               LibrarySection.allCases.indices.contains(index),
               legacySelection.wrappedValue != LibrarySection.allCases[index] {
                legacySelection.wrappedValue = LibrarySection.allCases[index]
            }
        }
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: Host, coordinator: ()) {
        view.gestures.disconnect(); view.gestures.onProgress = nil
    }

    final class Host: UIView {
        let gestures: LibraryPagingGestures
        var usesPageController = false
        init(gestures: LibraryPagingGestures) {
            self.gestures = gestures
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { gestures.disconnect() } else { setNeedsLayout() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            var ancestor = superview
            var target: UIScrollView?
            if usesPageController {
                // PageTabView's paging scroll is a descendant of the marker's
                // host, unlike the iOS 17 horizontal ScrollView. Its offsets are
                // relative to the current page, so do not use them as selection.
                while let view = ancestor {
                    if let scroll = pagingScroll(in: view) { target = scroll; break }
                    ancestor = view.superview
                }
            } else {
                while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
                target = ancestor as? UIScrollView
            }
            guard let scroll = target else { return }
            var responder: UIResponder? = self
            var back: UIGestureRecognizer?
            while let current = responder {
                if let controller = current as? UIViewController,
                   let candidate = controller.navigationController?.interactivePopGestureRecognizer {
                    back = candidate; break
                }
                responder = current.next
            }
            gestures.connect(scroll, back: back)
        }

        private func pagingScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.isPagingEnabled,
               scroll.bounds.width > 0, scroll.contentSize.width > scroll.bounds.width + 1 {
                let own = convert(bounds, to: window), candidate = scroll.convert(scroll.bounds, to: window)
                if own.width > 0, own.height > 0,
                   own.intersection(candidate).width >= own.width * 0.8,
                   own.intersection(candidate).height >= own.height * 0.7 { return scroll }
            }
            for child in view.subviews {
                if let scroll = pagingScroll(in: child) { return scroll }
            }
            return nil
        }
    }
}
