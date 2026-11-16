import SwiftUI
import UniformTypeIdentifiers

struct BatchImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var groupName = ""
    @State private var preparedDefaultName = false
    @State private var importResult: String? = nil
    @State private var importSucceeded = false
    @State private var isImporting = false
    @State private var showFilmExample = false
    @State private var showJSONExample = false
    @State private var replacesAll = false
    @State private var pendingReplacement: PlatformImportDocument?
    @State private var replacementCounts = (platforms: 0, groups: 0)
    @State private var importTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum GroupSelection {
        case region(PlatformRegion)
        case customGroup(UUID)
        case newGroup
    }

    private enum Field {
        case json
        case groupName
    }

    @State private var selection: GroupSelection = .newGroup
    private let filmImportURL = URL(string: "https://soulo.dkluge.com/sources.html")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    importShortcuts
                    formatExample
                    jsonEditor
                    importMode
                    if !replacesAll { destinationGroup }
                    if let result = importResult {
                        Label(result, systemImage: importSucceeded ? "checkmark.circle.fill" : "info.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(importSucceeded ? .green : .orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("batch-import.result")
                    }
                }
                .padding(16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .disabled(isImporting)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.themeGroupedBg)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    focusedField = nil
                    doImport()
                } label: {
                    HStack(spacing: 8) {
                        if isImporting { ProgressView().tint(.white) }
                        else { Image(systemName: "square.and.arrow.down") }
                        Text(LanguageManager.shared.localizedString("batch_import_action"))
                    }
                    .font(.body.weight(.semibold))
                }
                .buttonStyle(CompactActionButtonStyle(prominent: true))
                .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                .accessibilityIdentifier("batch-import.execute")
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .onAppear {
                if !preparedDefaultName { groupName = defaultGroupName(); preparedDefaultName = true }
            }
            .dismissKeyboardOnBackgroundTap()
            .onDisappear { importTask?.cancel() }
            .alert(FeatureText.text("Replace all platforms?"), isPresented: Binding(
                get: { pendingReplacement != nil }, set: { if !$0 { pendingReplacement = nil } }
            )) {
                Button(FeatureText.text("Replace all"), role: .destructive) {
                    guard let document = pendingReplacement else { return }
                    pendingReplacement = nil
                    finishImport(document, replacing: true)
                }
                .accessibilityIdentifier("batch-import.replace-confirm")
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { pendingReplacement = nil }
            } message: {
                Text(LanguageManager.shared.localizedString("settings_platforms") + ": \(PlatformDataStore.shared.platforms.count) → \(replacementCounts.platforms)\n"
                    + LanguageManager.shared.localizedString("custom_groups") + ": \(PlatformDataStore.shared.customGroups.count) → \(replacementCounts.groups)\n"
                    + FeatureText.text("A settings backup is saved before replacement."))
            }
            .navigationTitle(LanguageManager.shared.localizedString("batch_import"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) {
                        focusedField = nil
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(LanguageManager.shared.localizedString("done")) {
                        focusedField = nil
                    }
                }
            }
            .sheet(isPresented: $showFilmExample) {
                if let filmImportURL {
                    BatchImportExampleWebView(url: filmImportURL)
                }
            }
        }
    }

    private var importShortcuts: some View {
        HStack(spacing: 12) {
            Button {
                focusedField = nil
                showFilmExample = true
            } label: {
                shortcutLabel(LanguageManager.shared.localizedString("example"), icon: "list.bullet.rectangle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("batch-import.examples")

            NavigationLink {
                PlatformImportPromptView()
            } label: {
                shortcutLabel("AI Prompt", icon: "sparkles")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("batch-import.ai-prompt")
        }
    }

    private func shortcutLabel(_ title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.themePrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private var formatExample: some View {
        DisclosureGroup(isExpanded: $showJSONExample) {
            ScrollView(.horizontal) {
                Text(PlatformImportPrompt.exampleJSON)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 10)
        } label: {
            Label {
                Text("JSON " + LanguageManager.shared.localizedString("example"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "curlybraces").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("batch-import.format")
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("JSON").font(.subheadline.weight(.semibold))
                Spacer()
                PasteButton(payloadType: String.self) { values in
                    focusedField = nil
                    if let text = values.first, !text.isEmpty { jsonText = text }
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("batch-import.paste")
            }
            ZStack(alignment: .topLeading) {
                if jsonText.isEmpty {
                    Text(LanguageManager.shared.localizedString("batch_import_format"))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $jsonText)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .json)
                    .frame(height: 190)
                    .padding(8)
                    .accessibilityIdentifier("batch-import.json")
            }
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var importMode: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FeatureText.text("Import mode")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Picker(FeatureText.text("Import mode"), selection: $replacesAll) {
                Text(FeatureText.text("Append")).tag(false)
                Text(FeatureText.text("Replace all")).tag(true)
            }
            .pickerStyle(.segmented)
            .segmentedValueSwipe(selection: $replacesAll, values: [false, true])
            .accessibilityIdentifier("batch-import.mode")
        }
        .padding(16)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var destinationGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LanguageManager.shared.localizedString("batch_import_group"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(PlatformRegion.allCases, id: \.self) { region in
                    Button {
                        focusedField = nil
                        selection = .region(region)
                    } label: {
                        HStack {
                            Text(PlatformDataStore.shared.regionDisplayName(for: region))
                            if case .region(let value) = selection, value == region { Image(systemName: "checkmark") }
                        }
                    }
                }
                ForEach(PlatformDataStore.shared.customGroups) { group in
                    Button {
                        focusedField = nil
                        selection = .customGroup(group.id)
                    } label: {
                        HStack {
                            Text(group.name)
                            if case .customGroup(let id) = selection, id == group.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                Divider()
                Button {
                    focusedField = .groupName
                    selection = .newGroup
                    if groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { groupName = defaultGroupName() }
                } label: {
                    Label(LanguageManager.shared.localizedString("add_group"), systemImage: "folder.badge.plus")
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(Color.themePrimary)
                    Text(currentGroupLabel).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            if case .newGroup = selection {
                TextField(LanguageManager.shared.localizedString("batch_import_group_placeholder"), text: $groupName)
                    .font(.body)
                    .focused($focusedField, equals: .groupName)
                    .accessibilityIdentifier("batch-import.groupName")
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(FeatureText.text("Group names in JSON take priority. Matching groups merge without removing existing platforms."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 18))
    }

    private var currentGroupLabel: String {
        switch selection {
        case .region(let r):
            return PlatformDataStore.shared.regionDisplayName(for: r)
        case .customGroup(let gid):
            return PlatformDataStore.shared.customGroups.first(where: { $0.id == gid })?.name ?? ""
        case .newGroup:
            return LanguageManager.shared.localizedString("add_group")
        }
    }

    private func defaultGroupName() -> String {
        let base = ToolText.text("batch_import_new_group")
        let names = Set(PlatformDataStore.shared.customGroups.map(\.name))
        var name = base, suffix = 2
        while names.contains(name) { name = "\(base) \(suffix)"; suffix += 1 }
        return name
    }

    private func doImport() {
        isImporting = true; importResult = nil; importSucceeded = false
        let source = jsonText, replacing = replacesAll
        importTask = Task { @MainActor in
            defer { isImporting = false }
            do {
                let document = try await Task.detached(priority: .userInitiated) { try PlatformImportDocument.parse(source) }.value
                try Task.checkCancellation()
                if replacing {
                    let plan = try PlatformDataStore.shared.replacementPlan(document)
                    replacementCounts = (plan.platforms.count, plan.groups.count)
                    pendingReplacement = document
                } else { finishImport(document, replacing: false) }
            } catch is CancellationError { }
            catch { importResult = error.localizedDescription }
        }
    }

    private func finishImport(_ document: PlatformImportDocument, replacing: Bool) {
        do {
            let store = PlatformDataStore.shared
            let result: PlatformImportResult
            if replacing { result = try store.replacePlatforms(document) }
            else {
                switch selection {
                case .region(let region): result = store.applyImport(document, groupName: nil, region: region)
                case .customGroup(let id): result = store.applyImport(document, groupName: nil, intoGroupID: id)
                case .newGroup:
                    let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    result = store.applyImport(document, groupName: name.isEmpty ? defaultGroupName() : name)
                }
            }
            importSucceeded = result.hasChanges
            if result.changedGroups > 0 {
                importResult = String(format: FeatureText.text("Imported %1$d platforms into %2$d groups."), result.matchedPlatforms, result.changedGroups)
            } else if result.hasChanges {
                importResult = String(format: LanguageManager.shared.localizedString("batch_import_result"), result.matchedPlatforms)
            } else { importResult = FeatureText.text("No new platforms or group entries.") }
            if result.hasChanges {
                importTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1)); dismiss() } catch { }
                }
            }
        } catch { importResult = error.localizedDescription; importSucceeded = false }
    }

}

private struct BatchImportExampleWebView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var webViewModel = WebViewModel()
    @StateObject private var bookmarkViewModel = BookmarkViewModel()
    @State private var isFullscreen = false

    var body: some View {
        NavigationStack {
            WebViewContainer(
                webViewModel: webViewModel,
                bookmarkViewModel: bookmarkViewModel,
                isFullscreen: $isFullscreen
            )
            .navigationTitle(LanguageManager.shared.localizedString("example"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if webViewModel.currentURL == nil {
                    webViewModel.loadURL(url)
                }
            }
        }
    }
}


enum PlatformImportPrompt {
    static let exampleJSON = """
    {"groups":[
      {"name":"Search","platforms":[
        {"name":"Google","url":"https://www.google.com/search?q=%@"}]},
      {"name":"Reference","platforms":[
        {"name":"Wikipedia","url":"https://en.wikipedia.org/w/index.php?search=%@"}]}
    ]}
    """

    static func text(language: String) -> String {
        let rules = exampleJSON
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") {
            return """
            請按我的需求，產生可貼到 Soulo「平台批次匯入」的 JSON。只輸出合法 JSON，不要 Markdown、註解或說明。
            我的需求：【在這裡填寫想要的分組及平台】
            格式：\(rules)
            規則：可包含多個 groups；每組 name 為使用者需要的組名，platforms 為平台陣列。每個平台必須包含簡短 name 和真實 HTTP(S) 搜尋網址 url，搜尋關鍵字位置必須使用一個 %@ 佔位符。homeURL 可選，是平台首頁網址。
            請核實網址及搜尋參數，不要編造無法確認的介面；無法確認的網站請不要加入。不得加入 JavaScript、Cookie、帳戶憑證或 App 喚起網址。最多100組、合計2000個平台。
            使用者會複製你的結果，在 Soulo 批次匯入頁中貼上並匯入；JSON 內的組名優先；預設追加合併，也可在預覽及確認後覆蓋全部平台和分組。若我提供現有 JSON，請僅優化分組及順序，保留所有網址、%@ 佔位符、id、region、homeURL、isVisible、interactionType；不要因無法重新驗證而丟棄現有連結。interactionType 為 aiChat 的現有 AI 平台使用首頁網址，不要求 %@。region 表示內置地區分類；新建主題分組可省略 region。
            """
        }
        if language.hasPrefix("zh") {
            return """
            请按我的需求，生成可粘贴到 Soulo「平台批量导入」的 JSON。只输出合法 JSON，不要 Markdown、注释或说明。
            我的需求：【在这里填写想要的分组及平台】
            格式：\(rules)
            规则：可包含多个 groups；每组 name 为用户需要的组名，platforms 为平台数组。每个平台必须包含简短 name 和真实 HTTP(S) 搜索地址 url，搜索关键词位置必须使用一个 %@ 占位符。homeURL 可选，是平台首页地址。
            请核实网址及搜索参数，不要编造无法确认的接口；无法确认的站点请不要加入。不得加入 JavaScript、Cookie、账户凭据或 App 唤起地址。最多100组、合计2000个平台。
            用户会复制你的结果，在 Soulo 批量导入页中粘贴并导入；JSON 内的组名优先；默认追加合并，也可在预览及确认后覆盖全部平台和分组。如果我提供现有 JSON，请只优化分组和顺序，保留所有网址、%@ 占位符、id、region、homeURL、isVisible、interactionType；不要因为无法重新验证而丢弃已有链接。interactionType 为 aiChat 的现有 AI 平台使用首页网址，不要求 %@。region 表示内置地区分类；新建主题分组可省略 region。
            """
        }
        return """
        Generate valid JSON for Soulo platform batch import. Output JSON only, without Markdown or comments.
        My request: [Describe the groups and platforms here]
        Schema: \(rules)
        Include one or more groups, each with a name and platforms array. Each platform needs a short name and a verified HTTP(S) search URL with exactly one %@ keyword placeholder. homeURL is an optional home page URL.
        Verify real search parameters; omit sites you cannot verify. Include no JavaScript, credentials, cookies, or app-launch URLs. Limit: 100 groups and 2000 platforms in total.
        The user will copy your result and paste it into Soulo Batch Import. JSON group names take priority. Append is the default; Replace all requires review and confirmation. If I supply existing JSON, optimize its groups and order while retaining every link, %@ placeholder, id, region, homeURL, isVisible and interactionType. Do not discard existing links merely because you cannot re-verify them. Existing AI platforms with interactionType aiChat use their home URL without requiring %@. region identifies a built-in regional category; omit it for new topic groups.
        """
    }
}

private struct PlatformImportPromptView: View {
    @State private var copied = false
    @State private var copiedLinks = false
    @State private var exportData = Data()
    @State private var showsExporter = false
    @State private var exportError: String?
    private var prompt: String { PlatformImportPrompt.text(language: LanguageManager.shared.currentLanguage) }

    var body: some View {
        List {
            Section(FeatureText.text("Current platforms")) {
                Button {
                    do {
                        let data = try PlatformDataStore.shared.exportPlatformLinks()
                        UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
                        copiedLinks = true; HapticsManager.success()
                    } catch { exportError = error.localizedDescription }
                } label: {
                    Label(LanguageManager.shared.localizedString(copiedLinks ? "copied" : "resource_copy_all_links"), systemImage: copiedLinks ? "checkmark" : "link")
                }
                .accessibilityIdentifier("batch-import.copy-platforms")
                Button {
                    do { exportData = try PlatformDataStore.shared.exportPlatformLinks(); showsExporter = true }
                    catch { exportError = error.localizedDescription }
                } label: { Label(ToolText.text("favorites_export") + " JSON", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("batch-import.export-platforms")
            }
            Section {
                Text(FeatureText.text("Copy this prompt, add your requirements, send it to an AI, then paste its JSON here to import."))
                Button {
                    UIPasteboard.general.string = prompt; copied = true; HapticsManager.success()
                } label: {
                    Label(LanguageManager.shared.localizedString(copied ? "copied" : "userscript_docs_copy_prompt"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("batch-import.copy-prompt")
            }
            Section("AI Prompt") {
                Text(prompt).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("batch-import.prompt-text")
            }
            Section {
                Label(LanguageManager.shared.localizedString("paste_from_clipboard"), systemImage: "doc.on.clipboard")
            }
        }
        .navigationTitle("AI Prompt").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showsExporter, document: PlatformLinksDocument(data: exportData), contentType: .json, defaultFilename: "Soulo-Platforms") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(ToolText.text("error"), isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(ToolText.text("done")) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

private struct PlatformLinksDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
