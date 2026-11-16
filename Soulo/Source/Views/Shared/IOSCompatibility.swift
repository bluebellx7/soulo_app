import SwiftUI
import WebKit

private struct SegmentedValueSwipeModifier<Selection: Equatable>: ViewModifier {
    @Binding var selection: Selection
    let values: [Selection]
    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var swipeToken: UUID?
    @State private var originToken: UUID?
    @State private var originSelection: Selection?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .updating($swipeToken) { _, token, _ in
                    if token == nil { token = UUID() }
                }
                .onChanged { _ in
                    guard let swipeToken, originToken != swipeToken else { return }
                    originToken = swipeToken
                    originSelection = selection
                }
                .onEnded { drag in
                    defer { originToken = nil; originSelection = nil }
                    let horizontal = drag.translation.width
                    guard abs(horizontal) >= 24,
                          abs(horizontal) > abs(drag.translation.height) * 1.5,
                          let index = values.firstIndex(of: originSelection ?? selection) else { return }
                    let physicalStep = horizontal < 0 ? 1 : -1
                    let next = index + (layoutDirection == .rightToLeft ? -physicalStep : physicalStep)
                    guard values.indices.contains(next) else { return }
                    selection = values[next]
                }
        )
    }
}

extension View {
    /// Attach only to the segmented picker. The surrounding form keeps its
    /// scrolling, text selection and other horizontal interactions.
    func segmentedValueSwipe<Selection: Equatable>(selection: Binding<Selection>, values: [Selection]) -> some View {
        modifier(SegmentedValueSwipeModifier(selection: selection, values: values))
    }
}

extension WKWebView {
    func evaluateCompatibleJavaScript(_ source: String) async throws -> Any? {
        try await evaluateJavaScript(source)
    }

    func evaluateCompatibleJavaScript(_ source: String,
                                      completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil) {
        evaluateJavaScript(source, completionHandler: completionHandler)
    }

    /// The iOS 16 Swift overlay force-unwraps an undefined result from a
    /// content-world evaluation. Its public Objective-C API accepts nil.
    func evaluateCompatibleJavaScript(_ source: String, in frame: WKFrameInfo? = nil,
                                      contentWorld: WKContentWorld) async throws -> Any? {
        if #available(iOS 17.0, *) {
            return try await evaluateJavaScript(source, in: frame, contentWorld: contentWorld)
        }
        return try await withCheckedThrowingContinuation { continuation in
            __evaluateJavaScript(source, inFrame: frame, in: contentWorld, completionHandler: { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            })
        }
    }

    func evaluateCompatibleJavaScript(_ source: String, in frame: WKFrameInfo? = nil,
                                      in contentWorld: WKContentWorld,
                                      completionHandler: ((Result<Any, Error>) -> Void)? = nil) {
        if #available(iOS 17.0, *) {
            evaluateJavaScript(source, in: frame, in: contentWorld, completionHandler: completionHandler)
        } else {
            __evaluateJavaScript(source, inFrame: frame, in: contentWorld, completionHandler: { value, error in
                if let error { completionHandler?(.failure(error)) }
                else { completionHandler?(.success(value ?? NSNull())) }
            })
        }
    }
}

extension View {
    /// Keep optional navigation state in a Binding instead of capturing the
    /// presenting view, including all of its environment and observed objects.
    func compatibleNavigationDestination<Item, Destination: View>(
        item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        navigationDestination(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue { destination(value) }
        }
    }

    @ViewBuilder
    func compatibleListSectionSpacing(_ spacing: CGFloat) -> some View {
        if #available(iOS 17.0, *) { listSectionSpacing(spacing) }
        else { self }
    }

    @ViewBuilder
    func compatibleTopScrollAnchor() -> some View {
        if #available(iOS 17.0, *) { defaultScrollAnchor(.top) }
        else { self }
    }

    @ViewBuilder
    func compatibleNavigationDestination<Item: Hashable, Destination: View>(
        item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            navigationDestination(isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )) {
                if let value = item.wrappedValue { destination(value) }
            }
        }
    }

    /// iOS 16 cannot reliably push an optional media destination while that
    /// destination immediately presents the fullscreen player. Present media
    /// independently of the navigation stack; keep document previews as pushes.
    @ViewBuilder
    func compatiblePreviewDestination<Item: Identifiable, Destination: View>(
        item: Binding<Item?>, isMedia: @escaping (Item) -> Bool,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            compatibleNavigationDestination(item: item, destination: destination)
        } else {
            legacyPreviewDestination(item: item, isMedia: isMedia, destination: destination)
        }
    }

    @ViewBuilder
    func compatiblePreviewDestination<Item: Identifiable & Hashable, Destination: View>(
        item: Binding<Item?>, isMedia: @escaping (Item) -> Bool,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            legacyPreviewDestination(item: item, isMedia: isMedia, destination: destination)
        }
    }

    private func legacyPreviewDestination<Item: Identifiable, Destination: View>(
        item: Binding<Item?>, isMedia: @escaping (Item) -> Bool,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        let document = Binding<Item?>(
            get: { item.wrappedValue.flatMap { isMedia($0) ? nil : $0 } },
            set: { item.wrappedValue = $0 })
        let media = Binding<Item?>(
            get: { item.wrappedValue.flatMap { isMedia($0) ? $0 : nil } },
            set: { item.wrappedValue = $0 })
        return compatibleNavigationDestination(item: document, destination: destination)
            .fullScreenCover(item: media) { value in
                NavigationStack { destination(value) }
            }
    }

    @ViewBuilder
    func compatiblePresentationCornerRadius(_ radius: CGFloat?) -> some View {
        if #available(iOS 16.4, *) { presentationCornerRadius(radius) }
        else { self }
    }

    @ViewBuilder
    func compatiblePopoverAdaptation() -> some View {
        if #available(iOS 16.4, *) { presentationCompactAdaptation(.popover) }
        else { self }
    }

    @ViewBuilder
    func compatiblePresentationBackground<Style: ShapeStyle>(_ style: Style) -> some View {
        if #available(iOS 16.4, *) { presentationBackground(style) }
        else { background(style) }
    }

    @ViewBuilder
    func compatibleSizeBasedBounce() -> some View {
        if #available(iOS 16.4, *) { scrollBounceBehavior(.basedOnSize) }
        else { self }
    }

    @ViewBuilder
    func onCompatibleChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                               _ action: @escaping (Value, Value) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(LegacyChangeObserver(value: value, initial: initial, action: action))
        }
    }

    func onCompatibleChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                               _ action: @escaping () -> Void) -> some View {
        onCompatibleChange(of: value, initial: initial) { _, _ in action() }
    }

    func onCompatibleChange<Value: Equatable>(of value: Value,
                                               perform action: @escaping (Value) -> Void) -> some View {
        onCompatibleChange(of: value) { _, newValue in action(newValue) }
    }

    @ViewBuilder
    func compatibleScrollTopMargin(_ value: CGFloat) -> some View {
        if #available(iOS 17.0, *) { contentMargins(.top, value, for: .scrollContent) }
        else { padding(.top, value) }
    }

    func compatibleSuccessFeedback<Value: Equatable>(trigger: Value) -> some View {
        onCompatibleChange(of: trigger) { HapticsManager.success() }
    }

    @ViewBuilder
    func compatibleSymbolReplacement() -> some View {
        if #available(iOS 17.0, *) { contentTransition(.symbolEffect(.replace)) }
        else { contentTransition(.opacity) }
    }

    @ViewBuilder
    func compatiblePulseSymbol() -> some View {
        if #available(iOS 17.0, *) { symbolEffect(.pulse.wholeSymbol, options: .repeating) }
        else { modifier(LegacySymbolPulse()) }
    }

    @ViewBuilder
    func compatibleFocusFeedback(trigger: Int, enabled: Bool) -> some View {
        if #available(iOS 17.0, *) {
            keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { content, scale in
                content.scaleEffect(enabled ? scale : 1)
            } keyframes: { _ in
                CubicKeyframe(0.975, duration: 0.07)
                SpringKeyframe(1, duration: 0.2, spring: .snappy)
            }
        } else {
            modifier(LegacyFocusFeedback(trigger: trigger, enabled: enabled))
        }
    }
}

extension Animation {
    static var compatibleSnappy: Animation {
        if #available(iOS 17.0, *) { return .snappy }
        return .spring(response: 0.35, dampingFraction: 0.86)
    }
}

private struct LegacyChangeObserver<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var previous: Value

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onAppear {
            previous = value
            if initial { action(value, value) }
        }.onChange(of: value) { newValue in
            let oldValue = previous
            previous = newValue
            action(oldValue, newValue)
        }
    }
}

private struct LegacySymbolPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    func body(content: Content) -> some View {
        content.opacity(pulsing && !reduceMotion ? 0.45 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .onDisappear { pulsing = false }
    }
}

private struct LegacyFocusFeedback: ViewModifier {
    let trigger: Int
    let enabled: Bool
    @State private var scale: CGFloat = 1
    func body(content: Content) -> some View {
        content.scaleEffect(enabled ? scale : 1).onChange(of: trigger) { _ in
            guard enabled else { return }
            withAnimation(.easeOut(duration: 0.07)) { scale = 0.975 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { scale = 1 }
            }
        }
    }
}

struct CompatibleUnavailableView<LabelContent: View, Description: View, Actions: View>: View {
    let label: LabelContent
    let description: Description
    let actions: Actions
    private var searchText: String?

    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description,
         @ViewBuilder actions: () -> Actions) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 17.0, *) {
            if let searchText {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView { label } description: { description } actions: { actions }
            }
        } else {
            VStack(spacing: 14) {
                label.labelStyle(LegacyEmptyLabelStyle())
                description.font(.subheadline).foregroundStyle(.secondary)
                actions
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension CompatibleUnavailableView where Actions == EmptyView {
    init(@ViewBuilder label: () -> LabelContent, @ViewBuilder description: () -> Description) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension CompatibleUnavailableView where Description == EmptyView, Actions == EmptyView {
    init(@ViewBuilder label: () -> LabelContent) {
        self.init(label: label, description: { EmptyView() }, actions: { EmptyView() })
    }
}

extension CompatibleUnavailableView where LabelContent == Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(label: { Label(title, systemImage: systemImage) }, description: { description }, actions: { EmptyView() })
    }

    static func search(text: String) -> Self {
        var view = Self(LanguageManager.shared.localizedString("no_results"), systemImage: "magnifyingglass", description: Text(text))
        view.searchText = text
        return view
    }
}

private struct LegacyEmptyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon.font(.system(size: 42)).foregroundStyle(.secondary)
            configuration.title.font(.headline)
        }
    }
}

extension View {
    /// Before 16.4 SwiftUI adapts every compact popover to a full-height sheet.
    /// Use UIKit's non-adapting popover so the same menu stays content-sized.
    func compatiblePopover<Panel: View>(isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds), arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Panel) -> AnyView {
        // Keep both OS branches and the potentially large panel type out of
        // the caller's metadata. On device, resolving a deeply nested toolbar
        // type can exhaust the main stack before the popover is even opened.
        if #available(iOS 16.4, *) {
            return AnyView(popover(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) {
                AnyView(content())
            })
        } else {
            // Keep the anchor mounted, but build the legacy panel only when
            // shown. Its stable AnyView type preserves updates and dismissal.
            return AnyView(background(LegacyContentPopover(isPresented: isPresented, arrowEdge: arrowEdge,
                panel: isPresented.wrappedValue ? AnyView(content()) : AnyView(EmptyView()))))
        }
    }
}

private struct LegacyContentPopover<Panel: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let panel: Panel
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Anchor: UIView {
        var ready: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { ready?(self) } }
    }
    func makeUIView(context: Context) -> UIView {
        let view = Anchor()
        view.ready = { [weak coordinator = context.coordinator] in coordinator?.update(anchor: $0) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.panel = AnyView(panel.environment(\.self, context.environment))
        coordinator.edge = arrowEdge
        DispatchQueue.main.async { [weak view, weak coordinator] in
            if let view { coordinator?.update(anchor: view) }
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.close() }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var isPresented: Binding<Bool>?
        var panel = AnyView(EmptyView())
        var edge: Edge = .top
        var host: UIHostingController<AnyView>?
        func update(anchor: UIView) {
            guard isPresented?.wrappedValue == true else { close(); return }
            guard let window = anchor.window else { return }
            let controller: UIHostingController<AnyView>
            if let host { controller = host; host.rootView = panel }
            else {
                controller = UIHostingController(rootView: panel)
                controller.modalPresentationStyle = .popover
                controller.view.backgroundColor = .systemBackground
                controller.view.accessibilityIdentifier = "soulo.legacy-popover"
                controller.sizingOptions = .preferredContentSize
                guard let popover = controller.popoverPresentationController else { return }
                popover.sourceView = anchor; popover.sourceRect = anchor.bounds
                switch edge {
                case .top: popover.permittedArrowDirections = .up
                case .bottom: popover.permittedArrowDirections = .down
                case .leading: popover.permittedArrowDirections = .left
                case .trailing: popover.permittedArrowDirections = .right
                }
                popover.delegate = self
                var presenter = window.rootViewController
                while let next = presenter?.presentedViewController, !next.isBeingDismissed { presenter = next }
                guard let presenter, !presenter.isBeingDismissed else { return }
                host = controller
                controller.preferredContentSize = fittingSize(controller, window: window)
                presenter.present(controller, animated: true)
            }
            let size = fittingSize(controller, window: window)
            if controller.preferredContentSize != size { controller.preferredContentSize = size }
        }
        private func fittingSize(_ controller: UIHostingController<AnyView>, window: UIWindow) -> CGSize {
            let maximum = CGSize(width: min(400, max(240, window.bounds.width - 32)),
                                 height: max(160, window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom - 60))
            let size = controller.sizeThatFits(in: maximum)
            return CGSize(width: min(maximum.width, max(120, size.width)), height: min(maximum.height, max(44, size.height)))
        }
        func close() { let previous = host; host = nil; previous?.dismiss(animated: true) }
        func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
        func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            host = nil; isPresented?.wrappedValue = false
        }
        func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
            host = nil; isPresented?.wrappedValue = false
        }
    }
}
