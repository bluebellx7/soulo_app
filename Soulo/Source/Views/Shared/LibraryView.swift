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
        case .bookmarks: "bookmark.fill"
        case .history: "clock.arrow.circlepath"
        case .files: "folder.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }
}

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var searchVM: SearchViewModel
    @State private var selectedSection: LibrarySection
    @State private var pageProgress: CGFloat
    private let onOpen: ((String) -> Void)?

    init(
        initialSection: LibrarySection = .bookmarks,
        searchVM: SearchViewModel,
        onOpen: ((String) -> Void)? = nil
    ) {
        self.searchVM = searchVM
        self.onOpen = onOpen
        _selectedSection = State(initialValue: initialSection)
        _pageProgress = State(initialValue: CGFloat(LibrarySection.allCases.firstIndex(of: initialSection) ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            LibrarySectionSwitcher(selectedSection: $selectedSection, progress: pageProgress)

            LibraryPager(selectedSection: $selectedSection, progress: $pageProgress) { section in
                page(section)
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("library"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .mediaPlayerNavigation()
        .onReceive(NotificationCenter.default.publisher(for: .openSouloFiles)) { _ in
            selectedSection = .files
        }
    }

    @ViewBuilder
    private func page(_ section: LibrarySection) -> some View {
        switch section {
        case .bookmarks: BookmarksContentView(searchVM: searchVM, onOpen: openSelection)
        case .history: SearchHistoryContentView(searchVM: searchVM, onOpen: openSelection)
        case .downloads: DownloadManagerContentView(embeddedInLibrary: true)
        case .files: LibraryFilesView(embeddedInLibrary: true)
        }
    }

    private func openSelection(_ value: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if let onOpen {
                onOpen(value)
            } else {
                searchVM.searchText = value
                searchVM.performSearch(context: modelContext)
            }
        }
    }

}

struct LibraryPager<Content: View>: View {
    @Binding var selectedSection: LibrarySection
    @Binding var progress: CGFloat
    @Environment(\.layoutDirection) private var layoutDirection
    @StateObject private var gestures = LibraryPagingGestures()
    @ViewBuilder let content: (LibrarySection) -> Content

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(LibrarySection.allCases, id: \.self) { section in
                            content(section)
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
                .onAppear { proxy.scrollTo(selectedSection, anchor: .center) }
                .onChange(of: viewport.size.width) { _, width in
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
                .onChange(of: selectedSection) { _, section in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(section, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(Color(uiColor: .systemBackground))
    }

    private var sectionButtons: some View {
        HStack(alignment: .top, spacing: 4) {
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(minWidth: 48, minHeight: 50)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .anchorPreference(key: LibraryTabFramesKey.self, value: .bounds) { [section: $0] }
                .accessibilityLabel(section == .history ? LanguageManager.shared.localizedString("search_history") : title)
                .accessibilityIdentifier("library.section.\(section.rawValue)")
                .id(section)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if section != .files { Spacer(minLength: 0) }
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
                        .frame(width: frame.width, height: frame.height)
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
        VStack(spacing: 4) {
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
    private var observations: [NSKeyValueObservation] = []
    private var progressQueued = false
    private var lastProgress: CGFloat?
    var onProgress: ((CGFloat) -> Void)?
    var direction: LayoutDirection = .leftToRight
    private lazy var rowSwipe: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRowSwipe))
        gesture.maximumNumberOfTouches = 1
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    func connect(_ scroll: UIScrollView, back: UIGestureRecognizer?) {
        if self.scroll !== scroll {
            self.scroll?.removeGestureRecognizer(rowSwipe)
            observations.forEach { $0.invalidate() }
            self.scroll = scroll
            lastProgress = nil
            observations = [
                scroll.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in self?.scheduleProgress() },
                scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.scheduleProgress() },
                scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.scheduleProgress() }
            ]
            scroll.addGestureRecognizer(rowSwipe)
            scroll.panGestureRecognizer.require(toFail: rowSwipe)
        }
        if let back, self.back !== back {
            scroll.panGestureRecognizer.require(toFail: back)
            self.back = back
        }
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
        scroll = nil; back = nil; lastProgress = nil
    }

    func register(_ view: UIView) { rows[ObjectIdentifier(view)] = Region(view) }
    func unregister(_ view: UIView) { rows.removeValue(forKey: ObjectIdentifier(view)) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let scroll else { return false }
        rows = rows.filter { $0.value.view != nil }
        let point = touch.location(in: scroll)
        return rows.values.contains { region in
            guard let view = region.view, view.window === scroll.window else { return false }
            return view.convert(view.bounds, to: scroll).contains(point)
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = rowSwipe.velocity(in: scroll)
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        return direction == .rightToLeft ? velocity.x > 0 : velocity.x < 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other !== scroll?.panGestureRecognizer && other !== back
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
    func makeUIView(context: Context) -> Host { Host(gestures: gestures) }
    func updateUIView(_ view: Host, context: Context) {
        gestures.direction = direction
        let binding = $progress
        gestures.onProgress = { value in
            // Native contentOffset also changes between SwiftUI layout passes.
            // Use it directly, without a second animation lagging the finger.
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { binding.wrappedValue = value }
        }
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: Host, coordinator: ()) {
        view.gestures.disconnect(); view.gestures.onProgress = nil
    }

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
            if window == nil { gestures.disconnect() } else { setNeedsLayout() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
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
    }
}
