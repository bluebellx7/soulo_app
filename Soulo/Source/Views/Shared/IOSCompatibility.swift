import SwiftUI
import WebKit

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

    @ViewBuilder
    func compatibleSuccessFeedback<Value: Equatable>(trigger: Value) -> some View {
        if #available(iOS 17.0, *) { sensoryFeedback(.success, trigger: trigger) }
        else {
            onCompatibleChange(of: trigger) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
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
