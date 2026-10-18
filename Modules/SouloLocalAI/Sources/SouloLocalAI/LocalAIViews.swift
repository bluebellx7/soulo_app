#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

public struct LocalAISettingsView: View {
    @AppStorage("soulo.localAI.enabled") private var enabled = false
    @AppStorage("soulo.localAI.source") private var source = LocalAIModelSource.preferred.rawValue
    @ObservedObject private var store = LocalAIModelStore.shared
    @ObservedObject private var runtime = LocalAIRuntime.shared
    @State private var importPresented = false
    @State private var importing = false
    @State private var assetToDelete: LocalAIModelAsset?
    @State private var profileToDelete: LocalAIModelProfile?
    @State private var error: String?
    @StateObject private var downloadPrompt = LocalAIDownloadPrompt()
    private let isPrivate: Bool
    private let privacyCheck: @MainActor () -> Bool
    private let openLink: (@MainActor (URL) -> Void)?
    private let openChat: (@MainActor () -> Void)?
    private let showsChatAction: Bool
    public init(isPrivate: Bool = false, privacyCheck: @escaping @MainActor () -> Bool = { false }, openLink: (@MainActor (URL) -> Void)? = nil, openChat: (@MainActor () -> Void)? = nil, showsChatAction: Bool = true) {
        self.isPrivate = isPrivate; self.privacyCheck = privacyCheck; self.openLink = openLink; self.openChat = openChat
        self.showsChatAction = showsChatAction
    }

    public var body: some View {
        Form {
            Section {
                Toggle(AIL10n.text("enable"), isOn: $enabled).accessibilityIdentifier("localAI.enable")
                Label(AIL10n.text("privacy"), systemImage: "lock.shield")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } footer: { Text(AIL10n.text("enabled_help")) }
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cpu").font(.title2).foregroundStyle(.tint)
                        .frame(width: 42, height: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MiniCPM-V 4.7").font(.headline)
                        Text(store.selectedProfile == .light ? "1B · Q4_K_M" : "35B-A3B · LES").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.vertical, 6)
                Picker(AIL10n.text("model_mode"), selection: Binding(get: { store.selectedProfile }, set: { store.select($0) })) {
                    ForEach(LocalAIModelProfile.allCases) { profile in
                        Text(AIL10n.text(profile == .light ? "model_light" : "model_enhanced")).tag(profile)
                    }
                }.disabled(runtime.isBusy).accessibilityIdentifier("localAI.model-profile")
                Picker(AIL10n.text("source"), selection: $source) {
                    ForEach(LocalAIModelSource.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                if store.selectedProfile == .enhanced { enhancedModelRow }
                else { assetRow(.language) }
                if let vision = store.selectedProfile.visionAsset { assetRow(vision) }
                Button { importPresented = true } label: {
                    Label(AIL10n.text(importing ? "verifying" : "import"), systemImage: "square.and.arrow.down")
                }.disabled(importing).accessibilityIdentifier("localAI.import")
            } header: { Text(AIL10n.text("model")) }
            footer: {
                Text(AIL10n.text("download_help") + "\n" + AIL10n.text("source_help") + "\n" + AIL10n.text("import_help"))
            }
            Section {
                if showsChatAction { Group {
                    if let openChat {
                        Button(action: openChat) { Label(AIL10n.text("assistant"), systemImage: "bubble.left.and.bubble.right") }
                    } else {
                        NavigationLink { LocalAIAssistantView(isPrivate: isPrivate, privacyCheck: privacyCheck, openLink: openLink) } label: {
                            Label(AIL10n.text("assistant"), systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }.disabled(!enabled).accessibilityIdentifier("localAI.open-chat") }
                NavigationLink { LocalAIPromptSettingsView() } label: {
                    Label(AIL10n.text("prompts"), systemImage: "text.bubble")
                }.accessibilityIdentifier("localAI.prompts")
                NavigationLink { LocalAIAvatarSettingsView() } label: { Label(AIL10n.text("assistant_style"), systemImage: "face.smiling") }
                    .accessibilityIdentifier("localAI.avatar-settings")
                Button { runtime.release() } label: {
                    Label(AIL10n.text("release"), systemImage: "memorychip")
                }
            }
            Section {
                NavigationLink {
                    LocalAIIntroductionView(openLink: openLink) { openChat?() }
                } label: { Label(AIL10n.text("about"), systemImage: "info.circle") }
                .accessibilityIdentifier("localAI.about")
                NavigationLink(AIL10n.text("licenses")) { LocalAILicensesView() }
                Link("MiniCPM-V · Apache 2.0", destination: URL(string: "https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf")!)
                Link("llama.cpp · MIT", destination: URL(string: "https://github.com/ggml-org/llama.cpp")!)
            }
        }
        .navigationTitle(AIL10n.text("title"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(LocalAIStyle.accent)
        .localAIDownloadPrompt(downloadPrompt)
        .onChange(of: enabled) { _, value in if !value { runtime.release() } }
        .onChange(of: store.error) { _, value in if let value { error = value } }
        .task { store.reconnectBackgroundDownloads() }
        .fileImporter(isPresented: $importPresented, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            switch result {
            case .success(let url):
                importing = true
                Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() }; importing = false }
                    do { try await store.importFile(url) } catch { self.error = error.localizedDescription }
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .confirmationDialog(AIL10n.text("delete_model"), isPresented: Binding(get: { assetToDelete != nil }, set: { if !$0 { assetToDelete = nil } }), titleVisibility: .visible) {
            if let assetToDelete { Button(AIL10n.text("delete"), role: .destructive) { Task { await store.delete(assetToDelete) } } }
            Button(AIL10n.text("cancel"), role: .cancel) {}
        } message: { Text(AIL10n.text("delete_help")) }
        .confirmationDialog(AIL10n.text("delete_model"), isPresented: Binding(get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }), titleVisibility: .visible) {
            if let profileToDelete { Button(AIL10n.text("delete"), role: .destructive) { Task { await store.delete(profileToDelete) } } }
            Button(AIL10n.text("cancel"), role: .cancel) {}
        } message: { Text(AIL10n.text("delete_help")) }
        .alert(AIL10n.text("title"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(AIL10n.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var enhancedModelRow: some View {
        let profile = LocalAIModelProfile.enhanced
        let state = store.status(for: profile)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AIL10n.text("model_enhanced"), systemImage: "sparkles").font(.body.weight(.medium))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: profile.downloadBytes, countStyle: .file)).foregroundStyle(.secondary)
            }
            Text(AIL10n.text("model_enhanced_help")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !profile.isSupportedDevice { Text(AIL10n.text("model_device_low")).font(.footnote).foregroundStyle(.orange) }
            switch state {
            case .installed:
                HStack {
                    Label(AIL10n.text("installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button(role: .destructive) { profileToDelete = profile } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel(AIL10n.text("delete"))
                }
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(1, total)))
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    if let waiting = profile.languageAssets.first(where: { store.waitingForConnectivity.contains($0.id) }) {
                        Text(AIL10n.text(store.cellularDownloads.contains(waiting.id) ? "waiting_network" : "waiting_wifi")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(AIL10n.text("pause")) { store.pause(profile) }.frame(minHeight: 44)
                }
            case .verifying:
                HStack { ProgressView(); Text(AIL10n.text("verifying")) }.frame(minHeight: 44)
            case .missing, .paused, .failed:
                if case let .failed(message) = state { Text(message).font(.footnote).foregroundStyle(.red) }
                HStack {
                    Button(AIL10n.text(state == .paused ? "resume" : "download")) {
                        downloadPrompt.request(profile, source: LocalAIModelSource(rawValue: source) ?? .preferred)
                    }.buttonStyle(.bordered).frame(minHeight: 44).disabled(!profile.isSupportedDevice).accessibilityIdentifier("localAI.download.enhanced")
                    Spacer()
                    if profile.languageAssets.contains(where: { store.hasLocalData(for: $0) }) {
                        Button(role: .destructive) { profileToDelete = profile } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel(AIL10n.text("delete"))
                    }
                }
            }
        }.padding(.vertical, 4)
    }

    private func assetRow(_ asset: LocalAIModelAsset) -> some View {
        let state = store.statuses[asset.id] ?? .missing
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(AIL10n.text(asset.id == LocalAIModelAsset.language.id ? "language_model" : "vision_model")).font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if asset.id != LocalAIModelAsset.language.id {
                Text(AIL10n.text("vision_description")).font(.footnote).foregroundStyle(.secondary)
            }
            switch state {
            case .installed:
                HStack {
                    Label(AIL10n.text("installed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button(role: .destructive) { assetToDelete = asset } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(AIL10n.text("delete"))
                }.font(.subheadline)
            case let .downloading(received, total):
                ProgressView(value: Double(received), total: Double(max(1, total > 0 ? total : asset.bytes)))
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    if store.waitingForConnectivity.contains(asset.id) {
                        Text(AIL10n.text(store.cellularDownloads.contains(asset.id) ? "waiting_network" : "waiting_wifi")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(AIL10n.text("pause")) { store.pause(asset) }.font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
            case .verifying:
                HStack { ProgressView(); Text(AIL10n.text("verifying")).font(.subheadline).foregroundStyle(.secondary) }.frame(minHeight: 44)
            case .missing, .paused, .failed:
                if case .failed(let message) = state {
                    Text(message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(AIL10n.text(state == .paused ? "resume" : "download")) { downloadPrompt.request(asset, source: LocalAIModelSource(rawValue: source) ?? .preferred) }
                        .buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("localAI.download.\(asset.id)")
                    Spacer()
                    if store.hasLocalData(for: asset) {
                        Button(role: .destructive) { assetToDelete = asset } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .accessibilityLabel(AIL10n.text("delete"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LocalAITranscriptTailKey: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

private struct LocalAITranscriptScrollTracking: ViewModifier {
    @Binding var followsLatest: Bool
    @Binding var userIsScrolling: Bool
    @Binding var tailIsVisible: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 60
                } action: { _, visible in tailIsVisible = visible }
                .onScrollPhaseChange { _, phase in
                    userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    if userIsScrolling { followsLatest = false }
                }
        } else {
            content
                .onPreferenceChange(LocalAITranscriptTailKey.self) { tailIsVisible = $0 }
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { _ in userIsScrolling = true; followsLatest = false }
                    .onEnded { _ in userIsScrolling = false })
        }
    }
}

private struct LocalAILicensesView: View {
    private let files = ["llama-MIT", "Apache-2.0", "stb-image-license", "NativeThirdPartyNotices"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("llama.cpp b11706 · ggml authors\nMiniCPM-V 4.7 1B · OpenBMB\nstb_image · Sean Barrett and contributors").font(.headline)
                ForEach(files, id: \.self) { name in
                    if let url = Bundle.module.url(forResource: name, withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                        Text(text).font(.footnote).textSelection(.enabled)
                    }
                }
            }.padding(20)
        }.navigationTitle(AIL10n.text("licenses")).navigationBarTitleDisplayMode(.inline)
    }
}

public struct LocalAIPromptSettingsView: View {
    public init() {}
    public var body: some View {
        List {
            ForEach(LocalAIPromptKind.allCases, id: \.self) { kind in
                NavigationLink(kind.title) { PromptEditor(kind: kind) }
            }
            Section { Text(AIL10n.text("prompt_help")).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(AIL10n.text("prompts")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct PromptEditor: View {
    let kind: LocalAIPromptKind
    @State private var value = ""
    var body: some View {
        Form {
            Section {
                TextEditor(text: $value).frame(minHeight: 280).font(.body)
                    .accessibilityIdentifier("localAI.prompt-editor")
                    .onChange(of: value) { _, newValue in
                        if newValue.count > 4000 { value = String(newValue.prefix(4000)) }
                        LocalAIPrompts.save(value, kind: kind)
                    }
            } footer: { Text(AIL10n.text("prompt_help")) }
            Button(AIL10n.text("reset")) { value = kind.defaultTemplate; LocalAIPrompts.save(value, kind: kind) }
        }
        .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .onAppear { value = LocalAIPrompts.template(kind) }
    }
}

public struct LocalAIAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("soulo.localAI.enabled") private var enabled = false
    @ObservedObject private var store = LocalAIModelStore.shared
    @StateObject private var session: LocalAIChatSession
    @State private var settingsPresented = false
    @State private var historyPresented = false
    @State private var introductionPresented = false
    @State private var capturing = false
    @FocusState private var inputFocused: Bool
    private let screenshot: (@MainActor () async throws -> Data)?
    private let readOriginal: (@MainActor () -> Void)?
    private let privacyCheck: @MainActor () -> Bool
    private let openLink: (@MainActor (URL) -> Void)?
    private let initialQuestion: String
    @State private var initialSubmitted = false
    @State private var copiedMessageID: UUID?
    @State private var followsLatest = true
    @State private var userIsScrolling = false
    @State private var tailIsVisible = true

    public init(isPrivate: Bool = false, privacyCheck: @escaping @MainActor () -> Bool = { false }, openLink: (@MainActor (URL) -> Void)? = nil, pageProvider: (@MainActor () async throws -> LocalAIPage)? = nil,
                screenshot: (@MainActor () async throws -> Data)? = nil,
                applyCleanup: (@MainActor ([String], String) async throws -> Int)? = nil,
                undoCleanup: (@MainActor () async throws -> Void)? = nil,
                readOriginal: (@MainActor () -> Void)? = nil, tools: LocalAITools? = nil, initialQuestion: String = "") {
        _session = StateObject(wrappedValue: LocalAIChatSession(isPrivate: isPrivate, store: .shared, privacyCheck: privacyCheck,
            pageProvider: pageProvider, applyCleanup: applyCleanup, undoCleanup: undoCleanup, tools: tools, imageProvider: screenshot))
        self.screenshot = screenshot; self.readOriginal = readOriginal
        self.privacyCheck = privacyCheck
        self.openLink = openLink
        self.initialQuestion = initialQuestion
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.hasPageProvider { pageHeader }
            transcript
            if let error = session.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if session.canRetry {
                        Button(AIL10n.text("retry")) { session.retry() }.frame(minWidth: 44, minHeight: 44)
                            .disabled(session.isRunning || session.isUndoing).accessibilityIdentifier("localAI.retry")
                    }
                    Button { session.error = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(AIL10n.text("dismiss_error"))
                }.foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(AIL10n.text("title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { session.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(AIL10n.text("new_chat")).disabled(session.isRunning || session.isUndoing)
                if !session.isPrivate {
                    Button { session.synchronizePrivacy(); if !session.isPrivate { historyPresented = true } } label: { Image(systemName: "clock") }
                        .accessibilityLabel(AIL10n.text("history")).disabled(session.isRunning || session.isUndoing)
                }
                Menu {
                    Button(AIL10n.text("settings"), systemImage: "gearshape") { settingsPresented = true }
                    Button(AIL10n.text("about"), systemImage: "info.circle") { introductionPresented = true }
                    if session.hasPageProvider {
                        Button(AIL10n.text("summary"), systemImage: "text.alignleft") { inputFocused = false; session.run(.summary) }
                            .disabled(!ready || session.isRunning || session.isUndoing)
                        if let readOriginal { Button(AIL10n.text("read_original"), systemImage: "book") { inputFocused = false; readOriginal() } }
                        Button(AIL10n.text("cleanup"), systemImage: "sparkles.rectangle.stack") { inputFocused = false; session.run(.cleanup) }
                            .disabled(!ready || session.isRunning || session.isUndoing)
                        Button(AIL10n.text("reading"), systemImage: "text.book.closed") { inputFocused = false; session.run(.reading) }
                            .disabled(!ready || session.isRunning || session.isUndoing)
                    }
                    if let screenshot {
                        Button(AIL10n.text("screenshot"), systemImage: "viewfinder") {
                            guard !capturing, !session.isRunning else { return }
                            inputFocused = false; capturing = true
                            Task {
                                defer { capturing = false }
                                do { session.run(.chat, question: AIL10n.text("screenshot_question"), image: try await screenshot()) }
                                catch { session.error = error.localizedDescription }
                            }
                        }.disabled(session.isRunning || session.isUndoing || capturing || !ready || store.selectedVisionURL == nil)
                    }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel(AIL10n.text("settings"))
            }
        }
        .sheet(isPresented: $settingsPresented) {
            NavigationStack {
                LocalAISettingsView(isPrivate: session.isPrivate, privacyCheck: privacyCheck, openLink: openLink, openChat: { settingsPresented = false })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AIL10n.text("done")) { settingsPresented = false } } }
            }.tint(LocalAIStyle.accent)
        }
        .sheet(isPresented: $historyPresented) { historyView }
        .navigationDestination(isPresented: $introductionPresented) {
            LocalAIIntroductionView(openLink: openLink) { introductionPresented = false }
        }
        .task {
            await session.preparePage()
            if !initialSubmitted && !initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                initialSubmitted = true
                session.input = initialQuestion
                if ready { session.run(.chat) }
            }
        }
        .onDisappear { inputFocused = false; session.close() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { session.stop(); session.persist() } }
        .onChange(of: enabled) { _, value in if !value { session.stop() } }
        .task(id: copiedMessageID) {
            guard copiedMessageID != nil else { return }
            do { try await Task.sleep(for: .seconds(1.6)); copiedMessageID = nil } catch {}
        }
        .tint(LocalAIStyle.accent)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: 18)).foregroundStyle(LocalAIStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(LocalAIStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.page?.title ?? AIL10n.text("page")).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let host = session.page?.url.host { Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Toggle(AIL10n.text("attach_page"), isOn: $session.attachPage).labelsHidden().fixedSize()
                    .disabled(session.isRunning || session.isUndoing).accessibilityIdentifier("localAI.attach-page")
            }
            if !inputFocused && !dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact { HStack(spacing: 10) {
                actionChip("summary", icon: "text.alignleft") { session.run(.summary) }
                if let readOriginal { actionChip("read", icon: "book", needsModel: false) { readOriginal() } }
                actionChip("cleanup", icon: "sparkles.rectangle.stack") { session.run(.cleanup) }
            } }
            if session.canUndo {
                HStack {
                    Label(AIL10n.text("page_cleaned"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    Spacer()
                    Button(AIL10n.text("undo")) { Task { await session.undo() } }.accessibilityIdentifier("localAI.undo")
                        .disabled(session.isRunning || session.isUndoing)
                }.font(.footnote).padding(.top, 2)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
    private func actionChip(_ title: String, icon: String, needsModel: Bool = true, action: @escaping () -> Void) -> some View {
        Button { inputFocused = false; action() } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                Text(AIL10n.text(title)).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).foregroundStyle(LocalAIStyle.accent)
        .disabled((needsModel && !ready) || session.isRunning || session.isUndoing)
        .opacity((needsModel && !ready) || session.isRunning || session.isUndoing ? 0.4 : 1)
        .accessibilityIdentifier("localAI.action.\(title)")
    }
    private var ready: Bool { enabled && store.selectedModelURL != nil }

    private var transcript: some View {
        GeometryReader { viewport in
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if session.messages.isEmpty { welcome }
                    ForEach(session.messages) { message in messageView(message) }
                    if !session.pendingCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(session.pendingDescriptions.enumerated()), id: \.offset) { _, description in Text(description).font(.subheadline) }
                            HStack {
                                Button(AIL10n.text("confirm_execute")) { session.confirmTools() }.buttonStyle(.borderedProminent).foregroundStyle(LocalAIStyle.onAccent)
                                Button(AIL10n.text("cancel")) { session.cancelPendingTools() }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityIdentifier("localAI.action-review")
                    }
                    if session.hasToolUndo {
                        Button(AIL10n.text("undo_action"), systemImage: "arrow.uturn.backward") { Task { await session.undoTools() } }
                            .font(.subheadline).disabled(session.isRunning || session.isUndoing).accessibilityIdentifier("localAI.undo-action")
                    }
                    if session.isRunning {
                        HStack(spacing: 8) { ProgressView(); Text(session.phase).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(20)
                    .background(GeometryReader { content in
                        let bottom = content.frame(in: .named("localAI.transcript")).maxY
                        Color.clear.preference(key: LocalAITranscriptTailKey.self, value: bottom <= viewport.size.height + 60 && bottom >= 0)
                    })
            }
            .accessibilityIdentifier("localAI.transcript")
            .coordinateSpace(name: "localAI.transcript")
            .scrollDismissesKeyboard(.interactively)
            .modifier(LocalAITranscriptScrollTracking(followsLatest: $followsLatest, userIsScrolling: $userIsScrolling, tailIsVisible: $tailIsVisible))
            .onChange(of: session.messages.last?.content) { _, _ in if followsLatest && !userIsScrolling { reader.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: session.messages.last(where: { $0.role == "user" })?.id) { _, _ in
                followsLatest = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { reader.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.hasToolUndo) { _, _ in if followsLatest { reader.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: session.isRunning) { _, _ in if followsLatest { reader.scrollTo("bottom", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest && !tailIsVisible && !session.messages.isEmpty {
                    Button {
                        followsLatest = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.scrollTo("bottom", anchor: .bottom) }
                    } label: { Label(AIL10n.text("latest"), systemImage: "arrow.down").font(.subheadline.weight(.medium)).padding(.horizontal, 16).frame(minHeight: 44).background(.regularMaterial, in: Capsule()) }
                        .padding(16).accessibilityIdentifier("localAI.latest")
                }
            }
        }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: session.hasPageProvider ? "doc.text.magnifyingglass" : "bubble.left.and.bubble.right")
                .font(.system(size: 27, weight: .regular)).foregroundStyle(LocalAIStyle.accent)
                .frame(width: 56, height: 56)
                .background(LocalAIStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .padding(.bottom, 6)
            Text(AIL10n.text(session.hasPageProvider ? "welcome_page" : "welcome")).font(.title2.weight(.semibold))
            Text(AIL10n.text(session.hasPageProvider ? "welcome_page_help" : "welcome_help")).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !ready {
                Button { settingsPresented = true } label: { Label(AIL10n.text("settings"), systemImage: "arrow.down.circle").foregroundStyle(LocalAIStyle.onAccent) }
                    .buttonStyle(.borderedProminent).padding(.top, 6).accessibilityIdentifier("localAI.setup")
            }
            Label(AIL10n.text(session.isPrivate ? "private" : "local_only"), systemImage: "lock")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 32)
    }
    private func messageView(_ message: LocalAIMessage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if message.role == "user" {
                Text(message.content).textSelection(.enabled).padding(14)
                    .background(LocalAIStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if !message.content.isEmpty {
                Group {
                    LocalAIMessageContentView(text: message.content).equatable()
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("localAI.answer")
                    if let result = message.linkResult { LocalAILinkResultsView(result: result) }
                }
                    .environment(\.openURL, OpenURLAction { url in
                        guard LocalAILinkPolicy.permits(url), let openLink else { session.error = AIL10n.text("unsupported_link"); return .discarded }
                        dismiss(); openLink(url); return .handled
                    })
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = message.linkResult.map { $0.links.map { $0.url.absoluteString }.joined(separator: "\n") } ?? message.content; copiedMessageID = message.id
                        UISelectionFeedbackGenerator().selectionChanged()
                        UIAccessibility.post(notification: .announcement, argument: AIL10n.text("copied"))
                    } label: { Image(systemName: copiedMessageID == message.id ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44) }
                        .accessibilityLabel(AIL10n.text(copiedMessageID == message.id ? "copied" : "copy"))
                    if let source = message.sourceURL { Text(source.host ?? "").lineLimit(1) }
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if session.limitedContext { Text(AIL10n.text("limited")).font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .bottom, spacing: 12) {
                TextField(AIL10n.text("ask"), text: $session.input, axis: .vertical)
                    .lineLimit(1...6).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .focused($inputFocused).accessibilityIdentifier("localAI.input")
                    .onChange(of: session.input) { _, value in session.synchronizePrivacy(); if value.count > 3000 { session.input = String(value.prefix(3000)) } }
                Button {
                    if session.isRunning { session.stop() }
                    else { inputFocused = false; session.run(.chat) }
                } label: {
                    Image(systemName: session.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(LocalAIStyle.onAccent)
                        .frame(width: 44, height: 44).background(LocalAIStyle.accent, in: Circle())
                }
                .disabled(session.isUndoing || (!session.isRunning && (!ready || session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
                .accessibilityLabel(AIL10n.text(session.isRunning ? "stop" : "send"))
                .accessibilityIdentifier(session.isRunning ? "localAI.stop" : "localAI.send")
            }
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10).background(.bar)
    }
    private var historyView: some View {
        NavigationStack {
            List {
                if session.history.isEmpty { Text(AIL10n.text("no_history")).foregroundStyle(.secondary) }
                ForEach(session.history) { conversation in
                    Button {
                        session.open(conversation); historyPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(conversation.title).foregroundStyle(.primary).lineLimit(2)
                            Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    .swipeActions { Button(AIL10n.text("delete"), role: .destructive) { session.remove(conversation) } }
                }
            }
            .navigationTitle(AIL10n.text("history")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(AIL10n.text("done")) { historyPresented = false } } }
        }
    }
}
#endif
