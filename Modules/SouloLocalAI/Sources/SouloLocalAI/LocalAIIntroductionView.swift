#if canImport(UIKit)
import SwiftUI

enum LocalAIStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 196 / 255, green: 181 / 255, blue: 253 / 255, alpha: 1)
            : UIColor(red: 124 / 255, green: 58 / 255, blue: 237 / 255, alpha: 1)
    })
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
}

/// The introduction is shown once. Subsequent visits go directly to the page.
public struct LocalAIEntryView<Content: View>: View {
    @AppStorage("soulo.localAI.introductionSeen") private var introductionSeen = false
    @State private var startedThisVisit = false
    private let content: Content
    private let openLink: (@MainActor (URL) -> Void)?
    public init(openLink: (@MainActor (URL) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.openLink = openLink; self.content = content()
    }
    public var body: some View {
        Group {
            if introductionSeen || startedThisVisit { content }
            else { LocalAIIntroductionView(openLink: openLink) { introductionSeen = true; startedThisVisit = true } }
        }.tint(LocalAIStyle.accent)
    }
}

public struct LocalAIIntroductionView: View {
    @AppStorage("soulo.localAI.enabled") private var enabled = false
    @AppStorage("soulo.localAI.introductionSeen") private var introductionSeen = false
    @AppStorage("soulo.localAI.source") private var source = LocalAIModelSource.preferred.rawValue
    @ObservedObject private var store = LocalAIModelStore.shared
    @State private var settingsPresented = false
    @State private var downloadStarted = false
    @StateObject private var downloadPrompt = LocalAIDownloadPrompt()
    private let openLink: (@MainActor (URL) -> Void)?
    private let onStart: @MainActor () -> Void
    public init(openLink: (@MainActor (URL) -> Void)? = nil, onStart: @escaping @MainActor () -> Void) {
        self.openLink = openLink; self.onStart = onStart
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(LocalAIStyle.accent)
                        .frame(width: 66, height: 66)
                        .background(LocalAIStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 21))
                    Text(AIL10n.text("title")).font(.largeTitle.bold())
                    Text(AIL10n.text("intro_subtitle")).font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 25) {
                    feature("intro_chat", detail: "intro_chat_help", icon: "bubble.left.and.bubble.right")
                    feature("intro_browser", detail: "intro_browser_help", icon: "rectangle.on.rectangle")
                    feature("intro_read", detail: "intro_read_help", icon: "doc.text")
                    feature("intro_files", detail: "intro_files_help", icon: "folder")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(AIL10n.text("intro_download"), systemImage: "arrow.down.circle").font(.subheadline.weight(.semibold))
                    Text(store.selectedProfile.title).font(.subheadline)
                    Text(AIL10n.text(store.selectedProfile == .enhanced ? "model_enhanced_help" : "intro_download_help")).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Label(AIL10n.text("local_only"), systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(18)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if case let .downloading(received, total) = status {
                    ProgressView(value: Double(received), total: Double(max(1, total > 0 ? total : LocalAIModelAsset.language.bytes)))
                    Text(AIL10n.text(store.waitingForConnectivity.contains(LocalAIModelAsset.language.id)
                        ? (store.cellularDownloads.contains(LocalAIModelAsset.language.id) ? "waiting_network" : "waiting_wifi") : "download_help")).font(.caption).foregroundStyle(.secondary)
                }
                if case let .failed(message) = status { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button {
                    switch status {
                    case .installed: start()
                    case .downloading: store.pause(store.selectedProfile)
                    case .verifying: break
                    default:
                        downloadPrompt.request(store.selectedProfile, source: LocalAIModelSource(rawValue: source) ?? .preferred) {
                            enabled = true; downloadStarted = true
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if status == .verifying { ProgressView().tint(LocalAIStyle.onAccent) }
                        Text(AIL10n.text(buttonTitle)).font(.headline).foregroundStyle(LocalAIStyle.onAccent)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(status == .verifying || !store.selectedProfile.isSupportedDevice)
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .accessibilityIdentifier("localAI.introduction.start")
            }
            .frame(maxWidth: 560).padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(.bar)
        }
        .navigationTitle(AIL10n.text("about"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settingsPresented = true } label: { Image(systemName: "gearshape") }.accessibilityLabel(AIL10n.text("settings"))
            }
        }
        .onChange(of: status) { _, value in if value == .installed && downloadStarted { start() } }
        .navigationDestination(isPresented: $settingsPresented) {
            LocalAISettingsView(openLink: openLink, openChat: {
                settingsPresented = false
                start()
            })
        }
        .tint(LocalAIStyle.accent)
        .localAIDownloadPrompt(downloadPrompt)
    }
    private var status: LocalAIAssetStatus { store.status(for: store.selectedProfile) }
    private var buttonTitle: String {
        switch status {
        case .installed: "get_started"
        case .downloading: "pause"
        case .paused: "resume"
        case .verifying: "verifying"
        case .failed: "retry"
        case .missing: "download_model"
        }
    }
    private func start() { enabled = true; introductionSeen = true; onStart() }
    private func feature(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 21, weight: .regular)).foregroundStyle(LocalAIStyle.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(AIL10n.text(title)).font(.headline)
                Text(AIL10n.text(detail)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A page action stays beside the webpage, with progress, stop and undo in place.
public struct LocalAICleanupView: View {
    @StateObject private var session: LocalAIChatSession
    @ObservedObject private var store = LocalAIModelStore.shared
    @AppStorage("soulo.localAI.enabled") private var enabled = false
    @State private var settingsPresented = false
    @State private var restored = false
    private let onClose: @MainActor () -> Void
    public init(pageProvider: @escaping @MainActor () async throws -> LocalAIPage,
                applyCleanup: @escaping @MainActor ([String], String) async throws -> Int,
                undoCleanup: @escaping @MainActor () async throws -> Void,
                onClose: @escaping @MainActor () -> Void) {
        _session = StateObject(wrappedValue: LocalAIChatSession(isPrivate: true, store: .shared,
            pageProvider: pageProvider, applyCleanup: applyCleanup, undoCleanup: undoCleanup))
        self.onClose = onClose
    }
    private var ready: Bool { enabled && store.selectedModelURL != nil }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if session.isRunning { ProgressView() }
                    else { Image(systemName: session.canUndo || restored ? "checkmark.circle.fill" : "sparkles").foregroundStyle(LocalAIStyle.accent) }
                }.frame(width: 24)
                Text(title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("localAI.cleanup.status")
                if session.isRunning {
                    Button(AIL10n.text("stop")) { session.stop() }.accessibilityIdentifier("localAI.cleanup.stop")
                } else if !ready {
                    Button(AIL10n.text("settings")) { settingsPresented = true }
                } else if session.canUndo {
                    Button(AIL10n.text("undo")) { Task { await session.undo(); restored = !session.canUndo } }
                        .disabled(session.isUndoing)
                        .accessibilityIdentifier("localAI.cleanup.undo")
                } else if session.removedAds == nil {
                    Button(AIL10n.text("retry")) { restored = false; session.run(.cleanup) }
                }
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 36) }
                    .accessibilityLabel(AIL10n.text("done")).accessibilityIdentifier("localAI.cleanup.close")
            }
            if let error = session.error { Text(error).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08), lineWidth: 0.5) }
        .tint(LocalAIStyle.accent)
        .task { if ready { session.run(.cleanup) } }
        .onChange(of: ready) { _, value in if value && session.removedAds == nil && !session.isRunning { session.run(.cleanup) } }
        .onChange(of: enabled) { _, value in if !value { session.stop() } }
        .onDisappear { session.close() }
        .sheet(isPresented: $settingsPresented) {
            NavigationStack {
                LocalAISettingsView(openChat: { settingsPresented = false }, showsChatAction: false)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AIL10n.text("done")) { settingsPresented = false } } }
            }
        }
    }
    private var title: String {
        if !ready { return AIL10n.text("cleanup_setup") }
        if session.isRunning { return AIL10n.text("removing_ads") }
        if restored { return AIL10n.text("page_restored") }
        if let count = session.removedAds { return count == 0 ? AIL10n.text("cleanup_none") : String(format: AIL10n.text("cleanup_done"), count) }
        return AIL10n.text("cleanup")
    }
}
#endif
