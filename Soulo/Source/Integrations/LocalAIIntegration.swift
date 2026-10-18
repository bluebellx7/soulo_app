import SwiftUI
import WebKit
import Combine
#if SOULO_LOCAL_AI && canImport(SouloLocalAI)
import SouloLocalAI
#endif

/// The browser's only import of the optional feature package.
/// Disable its include in project.yml before removing Modules/SouloLocalAI;
/// regenerating the project then leaves these hooks inert.
@MainActor enum LocalAIIntegration {
    static var ready: Bool {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        UserDefaults.standard.bool(forKey: "soulo.localAI.enabled") && LocalAIModelStore.shared.selectedModelURL != nil
        #else
        false
        #endif
    }
    static func floatingButton(action: @escaping @MainActor () -> Void) -> AnyView {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        AnyView(LocalAIFloatingButton(action: action))
        #else
        AnyView(EmptyView())
        #endif
    }
    static var voiceTitle: String {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        AIL10n.text("ask_ai")
        #else
        ""
        #endif
    }
    static var available: Bool {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        true
        #else
        false
        #endif
    }
    static var title: String {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        AIL10n.text("title")
        #else
        ""
        #endif
    }
    static var cleanupTitle: String {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        AIL10n.text("cleanup")
        #else
        ""
        #endif
    }
    static func settingsView(openLink: @escaping @MainActor (URL) -> Void, openChat: (@MainActor () -> Void)? = nil) -> AnyView {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        AnyView(LocalAISettingsView(isPrivate: UserDefaults.standard.bool(forKey: "is_incognito"), privacyCheck: { UserDefaults.standard.bool(forKey: "is_incognito") }, openLink: openLink, openChat: openChat))
        #else
        AnyView(EmptyView())
        #endif
    }
    static func handleBackgroundSession(_ identifier: String, completion: @escaping () -> Void) -> Bool {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        guard identifier == LocalAIModelStore.sessionIdentifier else { return false }
        LocalAIModelStore.shared.backgroundCompletion = completion
        LocalAIModelStore.shared.reconnectBackgroundDownloads()
        return true
        #else
        return false
        #endif
    }
    static func chatView(search: SearchViewModel? = nil, tabs: TabManager? = nil, initialQuestion: String = "", onReveal: @escaping () -> Void = {}, features: [String: () -> Void] = [:], openLink: @escaping @MainActor (URL) -> Void) -> AnyView {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        let tools = search.flatMap { search in tabs.map { BrowserLocalAITools(search: search, tabs: $0, reveal: onReveal, features: features).tools } }
        let source = tabs.map { tabs in BrowserLocalAIPageSource(model: tabs.activeWebViewModel, modelProvider: { tabs.activeWebViewModel }) }
        return AnyView(LocalAIEntryView(openLink: openLink) {
            LocalAIAssistantView(isPrivate: UserDefaults.standard.bool(forKey: "is_incognito"), privacyCheck: { UserDefaults.standard.bool(forKey: "is_incognito") }, openLink: openLink,
                pageProvider: source.map { source in { try await source.read() } }, screenshot: source.map { source in { try await source.screenshot() } },
                applyCleanup: source.map { source in { try await source.apply(ids: $0, revision: $1) } },
                undoCleanup: source.map { source in { try await source.undo() } }, tools: tools, initialQuestion: initialQuestion)
        })
        #else
        return AnyView(EmptyView())
        #endif
    }
    static func assistantView(model: WebViewModel, search: SearchViewModel? = nil, tabs: TabManager? = nil, initialQuestion: String = "", onReveal: @escaping () -> Void = {}, features: [String: () -> Void] = [:], openLink: @escaping @MainActor (URL) -> Void, readOriginal: @escaping () -> Void) async -> AnyView {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        let allFeatures = features.merging(["阅读原文 / Read original": readOriginal]) { first, _ in first }
        guard ["http", "https"].contains(model.webView?.url?.scheme ?? "") else { return chatView(search: search, tabs: tabs, initialQuestion: initialQuestion, onReveal: onReveal, features: allFeatures, openLink: openLink) }
        let tools = search.flatMap { search in tabs.map { BrowserLocalAITools(search: search, tabs: $0, reveal: onReveal, features: allFeatures).tools } }
        let provider: (() -> WebViewModel?)? = tabs.map { tabs in { tabs.activeWebViewModel } }
        let source = BrowserLocalAIPageSource(model: model, modelProvider: provider)
        // A pushed page detaches the browser from its window. Capture the visible
        // viewport before navigating, then retain only this bounded JPEG.
        _ = try? await source.screenshot()
        return AnyView(LocalAIEntryView(openLink: openLink) { LocalAIAssistantView(
            isPrivate: UserDefaults.standard.bool(forKey: "is_incognito") || model.webView?.configuration.websiteDataStore.isPersistent == false,
            privacyCheck: { [weak model] in UserDefaults.standard.bool(forKey: "is_incognito") || model?.webView?.configuration.websiteDataStore.isPersistent == false },
            openLink: openLink,
            pageProvider: { try await source.read() }, screenshot: { try await source.screenshot() },
            applyCleanup: { try await source.apply(ids: $0, revision: $1) },
            undoCleanup: { try await source.undo() }, readOriginal: readOriginal, tools: tools, initialQuestion: initialQuestion) })
        #else
        return AnyView(EmptyView())
        #endif
    }
    static func cleanupView(model: WebViewModel, onClose: @escaping @MainActor () -> Void) -> AnyView {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        let source = BrowserLocalAIPageSource(model: model)
        return AnyView(LocalAICleanupView(pageProvider: { try await source.read() },
            applyCleanup: { try await source.apply(ids: $0, revision: $1) },
            undoCleanup: { try await source.undo() }, onClose: onClose))
        #else
        return AnyView(EmptyView())
        #endif
    }
}

@MainActor final class LocalAIAvailability: ObservableObject {
    static let shared = LocalAIAvailability()
    @Published private(set) var isReady = false
    private var subscriptions = Set<AnyCancellable>()
    private init() {
        #if SOULO_LOCAL_AI && canImport(SouloLocalAI)
        LocalAIModelStore.shared.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in Task { @MainActor in self?.refresh() } }.store(in: &subscriptions)
        #endif
        refresh()
    }
    private func refresh() { let value = LocalAIIntegration.ready; if value != isReady { isReady = value } }
}

extension Notification.Name {
    static let askSouloLocalAI = Notification.Name("soulo.askLocalAI")
    static let performLocalAIFeature = Notification.Name("soulo.performLocalAIFeature")
}

#if SOULO_LOCAL_AI && canImport(SouloLocalAI)
@MainActor final class BrowserLocalAIPageSource {
    private weak var model: WebViewModel?
    private weak var sourceWebView: WKWebView?
    private var sourceURL: URL?
    private weak var previewWebView: WKWebView?
    private var previewURL: URL?
    private var previewData: Data?
    private var previewOffset: CGPoint?
    private weak var undoWebView: WKWebView?
    private var undoURL: URL?
    private let modelProvider: (() -> WebViewModel?)?
    init(model: WebViewModel?, modelProvider: (() -> WebViewModel?)? = nil) { self.model = model; self.modelProvider = modelProvider }
    private func refreshModel() { if let modelProvider { model = modelProvider() } }
    private func requireCurrent(_ web: WKWebView, url: URL?) throws {
        refreshModel()
        guard model?.webView === web, web.url == url else { throw LocalAIError.pageChanged }
    }

    func read() async throws -> LocalAIPage {
        refreshModel()
        guard let web = model?.webView, let url = web.url, ["http", "https"].contains(url.scheme ?? "") else { throw LocalAIError.pageChanged }
        let article = try? await ArticleReader.extract(web)
        try requireCurrent(web, url: url)
        let result = try await web.callAsyncJavaScript(Self.inspectScript, arguments: ["revisionToken": UUID().uuidString], in: nil, contentWorld: .defaultClient)
        try requireCurrent(web, url: url)
        guard let values = result as? [String: Any],
              let revision = values["revision"] as? String else { throw LocalAIError.pageChanged }
        sourceWebView = web; sourceURL = url
        if values["canUndo"] as? Bool == true { undoWebView = web; undoURL = url }
        let raw = article?.text ?? values["text"] as? String ?? ""
        let candidates = (values["elements"] as? [[String: String]] ?? []).compactMap { value -> LocalAIPageElement? in
            guard let id = value["id"], let text = value["text"], let hint = value["hint"] else { return nil }
            return LocalAIPageElement(id: id, text: text, hint: hint)
        }
        return LocalAIPage(title: article?.title ?? web.title ?? url.host ?? "", url: url,
                           text: String(raw.prefix(32_000)), selection: values["selection"] as? String ?? "",
                           revision: revision, elements: candidates, canUndo: values["canUndo"] as? Bool == true,
                           isLimited: raw.count > 32_000 || values["limited"] as? Bool == true)
    }
    func apply(ids: [String], revision: String) async throws -> Int {
        refreshModel()
        guard let web = sourceWebView, model?.webView === web, web.url == sourceURL else { throw LocalAIError.pageChanged }
        let count = try await web.callAsyncJavaScript(Self.applyScript, arguments: ["ids": ids, "revision": revision], in: nil, contentWorld: .defaultClient)
        guard let count = count as? Int, count >= 0 else { throw LocalAIError.pageChanged }
        if count > 0 { undoWebView = web; undoURL = sourceURL }
        return count
    }
    func undo() async throws {
        refreshModel()
        guard let web = undoWebView else { throw LocalAIError.pageChanged }
        try requireCurrent(web, url: undoURL)
        _ = try await web.callAsyncJavaScript(Self.undoScript, arguments: [:], in: nil, contentWorld: .defaultClient)
        undoWebView = nil; undoURL = nil
    }
    func screenshot() async throws -> Data {
        refreshModel()
        guard let web = model?.webView, web.bounds.width > 1, web.bounds.height > 1 else { throw LocalAIError.pageChanged }
        if web.window == nil {
            guard web === previewWebView, web.url == previewURL, web.scrollView.contentOffset == previewOffset, let previewData else { throw LocalAIError.pageChanged }
            return previewData
        }
        let originalURL = web.url
        let config = WKSnapshotConfiguration(); config.rect = web.bounds; config.snapshotWidth = 768
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? LocalAIError.pageChanged) }
            }
        }
        try requireCurrent(web, url: originalURL)
        guard let data = image.jpegData(compressionQuality: 0.8) else { throw LocalAIError.pageChanged }
        previewWebView = web; previewURL = originalURL; previewData = data; previewOffset = web.scrollView.contentOffset
        return data
    }
    // Installed only after explicitly opening the assistant. Candidate handles
    // live in WebKit's isolated world; the website cannot supply executable edits.
    static let inspectScript = #"""
    const previous = window.__souloLocalAI;
    const state = {revision: revisionToken, url: location.href, candidates: new Map(),
                   hidden: previous?.url === location.href ? previous.hidden : []};
    const protectedNode = el => !el || !el.isConnected ||
        /^(HTML|BODY|MAIN|ARTICLE|NAV|HEADER|FOOTER|FORM|VIDEO|AUDIO|IFRAME)$/.test(el.tagName) ||
        !!el.closest('nav,header,footer,[role="navigation"],[role="banner"],[class~="toc"],[id="toc"],[class*="table-of-contents" i]') ||
        el.contains(document.activeElement) ||
        !!el.querySelector('main,article,h1,form,input,textarea,button,video,audio,iframe,[contenteditable="true"]') ||
        (el.innerText || '').length > 800;
    state.protectedNode = protectedNode;
    const elements = [];
    const selector = '[data-ad],[data-ad-slot],[id*="advert" i],[class*="advert" i],[class~="ad"],[class~="ads"],[id^="ad_"],[id^="ad-"],[class*="sponsor" i],[class*="banner" i]';
    for (const el of document.querySelectorAll(selector)) {
        if (elements.length >= 24) break;
        const rect = el.getBoundingClientRect();
        if (protectedNode(el) || rect.width < 2 || rect.height < 2 || getComputedStyle(el).visibility === 'hidden') continue;
        const id = 'e' + elements.length;
        const text = (el.innerText || el.textContent || '').trim().slice(0,96);
        const hint = (el.tagName + ' ' + el.id + ' ' + el.className).slice(0,96);
        state.candidates.set(id, {el, text: (el.innerText || el.textContent || '').trim().slice(0,96)});
        elements.push({id,text,hint});
    }
    window.__souloLocalAI = state;
    const text = document.body?.innerText || '';
    return {revision:state.revision, elements, text:text.slice(0,32001), limited:text.length>32000,
            selection:(getSelection()?.toString() || '').slice(0,1000), canUndo:state.hidden.length>0};
    """#
    static let applyScript = #"""
    const state = window.__souloLocalAI;
    if (!state || state.url !== location.href || state.revision !== revision || ids.length > 20) return -1;
    let count = 0;
    for (const id of ids) {
        const candidate = state.candidates.get(id);
        if (!candidate || state.protectedNode(candidate.el)) continue;
        const el = candidate.el;
        if ((el.innerText || el.textContent || '').trim().slice(0,96) !== candidate.text) continue;
        if (state.hidden.some(record => record.el === el)) continue;
        state.hidden.push({el,value:el.style.getPropertyValue('display'),priority:el.style.getPropertyPriority('display')});
        el.style.setProperty('display','none','important'); count++;
    }
    return count;
    """#
    static let undoScript = #"""
    const state = window.__souloLocalAI;
    if (state) {
        for (const record of state.hidden) {
            if (record.value) record.el.style.setProperty('display',record.value,record.priority);
            else record.el.style.removeProperty('display');
        }
        state.hidden = [];
    }
    return true;
    """#
}
#endif

#if SOULO_LOCAL_AI && canImport(SouloLocalAI)
@MainActor final class BrowserLocalAITools {
    struct Setting {
        let key: String, title: String, values: String
        var confirm = false
    }
    private let search: SearchViewModel
    private let tabs: TabManager
    private let reveal: () -> Void
    private let features: [String: () -> Void]
    private var destinations: [URL] = []
    private var pendingFeature: (() -> Void)?
    private var filePlan: [LocalAIFileMove]?
    private var undoAction: (() async throws -> String)?
    private var pageLinks: [LocalAIPageLink] = []
    private var linksURL: URL?
    private var linkFilter = ""
    private var extractedLinks: LocalAILinkResult?
    private var reviewedLinks: [String: URL] = [:]
    private var reviewedTabs: [String: UUID] = [:]
    private var reviewedPages: [String: (tab: UUID, url: URL?)] = [:]
    private func text(_ cn: String, _ en: String) -> String { AIL10n.interfaceText(cn, en) }
    private func featureTitle(_ key: String) -> String {
        let parts = key.components(separatedBy: " / ")
        return parts.count == 2 ? text(parts[0], parts[1]) : key
    }
    init(search: SearchViewModel, tabs: TabManager, reveal: @escaping () -> Void, features: [String: () -> Void]) {
        self.search = search; self.tabs = tabs; self.reveal = reveal; self.features = features
    }
    private var settings: [Setting] {
        var result: [Setting] = [Setting(key: "appearance", title: text("应用外观", "App appearance"), values: "system|light|dark"),
         Setting(key: "page_zoom", title: text("网页字号缩放", "Page zoom"), values: "50...200 percent"),
         Setting(key: "home_title", title: text("首页标题", "Home title"), values: "text up to 80 characters"),
         Setting(key: "home_subtitle", title: text("首页副标题", "Home subtitle"), values: "text up to 120 characters"),
         Setting(key: "reader.font", title: text("阅读字体", "Reader font"), values: "serif|sans|mono"),
         Setting(key: "reader.theme", title: text("阅读配色", "Reader colors"), values: "paper|light|dark"),
         Setting(key: "reader.fontSize", title: text("阅读字号", "Reader font size"), values: "number:14...36"),
         Setting(key: "reader.lineHeight", title: text("阅读行距", "Reader line height"), values: "number:1.2...2.4"),
         Setting(key: "soulo.localAI.avatar", title: text("助手形象：星团小橘猫芽芽小方", "Assistant character: orbit cat sprout robot"), values: "orbit|cat|sprout|robot"),
         Setting(key: "soulo.localAI.source", title: text("模型下载来源", "Model download source"), values: LocalAIModelSource.allCases.map(\.rawValue).joined(separator: "|")),
         Setting(key: "app_language", title: text("应用语言", "App language"), values: AppConstants.supportedLanguages.map(\.code).joined(separator: "|"))]
        result += (1...4).map { Setting(key: "toolbar_slot_\($0)", title: text("工具栏第 \($0) 个按钮", "Toolbar button \($0)"), values: BrowserToolbarAction.allCases.map(\.rawValue).joined(separator: "|")) }
        result += [Setting(key: "toolbar_address", title: text("地址栏按钮", "Address bar button"), values: BrowserToolbarAction.allCases.filter { !BrowserToolbarConfigurationService.unsupportedAddressActions.contains($0) }.map(\.rawValue).joined(separator: "|"))]
        result += LocalAIPromptKind.allCases.map { Setting(key: "soulo.localAI.prompt." + $0.rawValue, title: text("自定义提示词：", "Custom prompt: ") + AIL10n.text($0.rawValue), values: "text up to 2000 characters", confirm: true) }
        let flags: [(String, String, String, Bool)] = [
            ("show_top_search_bar", "顶部搜索框", "Top search bar", false),
            ("show_top_tab_bar", "顶部标签栏", "Top tab bar", false),
            ("keep_fullscreen_browsing", "保持全屏浏览", "Keep fullscreen browsing", false),
            ("keep_page_above_toolbar", "网页避开工具栏", "Keep page above toolbar", false),
            ("browser_toolbar_hidden", "隐藏浏览工具栏", "Hide browser toolbar", false),
            ("show_bookmarks_on_home", "首页显示收藏", "Home bookmarks", false),
            ("show_group_picker_on_home", "首页显示分组", "Home groups", false),
            ("show_recent_searches_on_home", "首页最近搜索", "Recent searches on home", false),
            ("web_follows_app_color_scheme", "网页跟随应用外观", "Page follows app appearance", false),
            ("web_force_dark_pages", "网页深色模式", "Dark webpages", false),
            ("web_warm_color_shift", "网页护眼暖色", "Warm page colors", false),
            ("web_reduce_page_motion", "减少网页动画", "Reduce page motion", false),
            ("web_underline_links", "网页链接下划线", "Underline page links", false),
            ("ad_block_enabled", "广告过滤", "Ad blocking", true),
            ("soulo_external_navigation_prompt_enabled", "跳转外部应用提示", "External app confirmation", true),
            ("ad_block_confirm_cross_domain", "跨域跳转提示", "Cross-domain confirmation", true),
            ("privacy_https_upgrade_enabled", "HTTPS 升级", "HTTPS upgrade", true),
            ("privacy_strip_tracking_parameters", "移除跟踪参数", "Remove tracking parameters", true),
            ("privacy_gpc_enabled", "全局隐私控制", "Global privacy control", true),
            ("privacy_cookie_banner_enabled", "处理 Cookie 提示", "Cookie banner handling", true),
            ("is_incognito", "无痕浏览", "Private browsing", true),
            ("soulo.localAI.floating", "悬浮 AI 形象", "Floating AI companion", false),
            ("reader.continuous", "连续阅读", "Continuous reading", false),
            ("soulo.localAI.enabled", "启用本地 AI", "Enable Local AI", false),
            ("icloud_sync_enabled", "iCloud 同步", "iCloud sync", true)
        ]
        result += flags.map { Setting(key: $0.0, title: text($0.1, $0.2), values: "true|false", confirm: $0.3) }
        return result
    }
    var tools: LocalAITools {
        var catalog = [
            LocalAITool("open_url", title: "访问用户提供的完整网址 / Visit an explicit URL supplied by the user", argument: "explicit http/https URL"),
            LocalAITool("search_web", title: "导航到搜索引擎的结果页 / Navigate the current tab to search engine results", argument: "search query"),
            LocalAITool("tabs_list", title: text("查看所有标签页", "List all tabs")),
            LocalAITool("tab_switch", title: text("切换标签页", "Switch tab"), argument: "1-based tab number"),
            LocalAITool("tab_new", title: text("新建标签页", "New tab"), argument: "optional http/https URL"),
            LocalAITool("tab_close", title: text("关闭标签页", "Close tab"), argument: "1-based number or current", confirmation: true),
            LocalAITool("tab_restore", title: text("恢复关闭的标签页", "Restore closed tab")),
            LocalAITool("page_reload", title: text("刷新当前网页", "Reload current page")),
            LocalAITool("page_back", title: text("网页后退", "Go back")),
            LocalAITool("page_forward", title: text("网页前进", "Go forward")),
            LocalAITool("page_links", title: "Extract links from current webpage, optionally filter by website domain; 提取网页链接，可按网站筛选", argument: "domain or configured website name only, empty string for all links"),
            LocalAITool("page_count_text", title: "Count exact occurrences of text in the entire rendered page, not a summary; 精确统计网页文字出现次数", argument: "exact literal text to count, up to 200 characters"),
            LocalAITool("page_open_link", title: text("打开网页第几个链接", "Open numbered page link"), argument: "1-based link number"),
            LocalAITool("page_scroll", title: text("滚动网页到顶部底部上下翻页", "Scroll page top bottom up down"), argument: "top|bottom|up|down"),
            LocalAITool("page_find", title: text("在网页内查找文字", "Find text on page"), argument: "text to find, up to 200 characters"),
            LocalAITool("files_list", title: text("查看下载文件", "List downloaded files")),
            LocalAITool("files_organize", title: text("整理下载文件按类型分组", "Organize downloaded files by type"), confirmation: true)
        ]
        catalog.append(LocalAITool("open_website", title: "按名称打开已配置的网站 / Open configured website by name", argument: "website name as shown in browser state"))
        if LocalAIModelStore.shared.selectedProfile.isMultiStepAgent {
            catalog.append(LocalAITool("page_read", title: "Read current page title, URL and loaded text as an observation for further reasoning", category: .page))
            catalog.append(LocalAITool("page_show", title: "Present the current webpage and finish. Use after required navigation or visual operations; keep requested explanations and analysis in the conversation instead.", category: .page))
        }
        let parameters = ["page_count_text": "text", "page_links": "filter", "open_url": "url", "open_website": "website"]
        catalog = catalog.map { LocalAITool($0.id, title: $0.title, argument: $0.argument, confirmation: $0.confirmation, category: category(for: $0.id), parameter: parameters[$0.id], verbatim: ["page_count_text", "page_find"].contains($0.id)) }
        if features["网页图片 / Page images"] != nil { catalog.append(LocalAITool("page_images", title: text("提取网页中所有图片", "Extract list show all page images"), category: .page)) }
        catalog += settings.map { LocalAITool("set:" + $0.key, title: $0.title, argument: $0.values, confirmation: $0.confirm, category: category(for: "set:" + $0.key)) }
        catalog += features.keys.sorted().map { LocalAITool("feature:" + $0, title: $0, category: .features) }
        return LocalAITools(catalog: catalog, context: { [self] in
            let list = tabs.tabs.prefix(30).enumerated().map { "\($0.offset + 1): \($0.element.displayTitle.prefix(80)) \($0.element.webViewModel.currentURL?.host ?? "")" }
            let websites = PlatformDataStore.shared.allPlatforms().prefix(18).map { LanguageManager.shared.localizedString($0.name) + ": " + $0.homeURL }.joined(separator: "\n")
            let links = pageLinks.prefix(10).enumerated().map { "\($0.offset + 1). \($0.element.title.prefix(60)) \($0.element.url.absoluteString.prefix(200))" }.joined(separator: "\n")
            let position = tabs.activeWebViewModel?.webView.map { "Scroll: \(Int($0.scrollView.contentOffset.y))/\(Int($0.scrollView.contentSize.height))" } ?? ""
            return "Current URL: \(tabs.activeWebViewModel?.currentURL?.absoluteString.prefix(250) ?? "")\n" + position + "\nExtracted links:\n" + links + "\nWebsites:\n" + websites + "\nTabs:\n" + list.joined(separator: "\n")
        }, preview: { [self] in try await preview($0) }, perform: { [self] in try await perform($0) }, undo: { [self] in
            guard let undoAction else { throw LocalAIError.pageChanged }
            let receipt = try await undoAction(); self.undoAction = nil; return receipt
        }, finish: { [self] in finish($0, agent: false) }, canUndo: { [self] in undoAction != nil }, resolveWebsite: { name in
            let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = ["百度": "platform_baidu", "百度搜索": "platform_baidu", "谷歌": "platform_google", "必应": "platform_bing", "必應": "platform_bing", "b站": "platform_bilibili", "油管": "platform_youtube", "推特": "platform_twitter"]
            let chinese = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
            for platform in PlatformDataStore.shared.allPlatforms() {
                let localized = LanguageManager.shared.localizedString(platform.name).lowercased()
                let english = platform.name.replacingOccurrences(of: "platform_", with: "").replacingOccurrences(of: "_", with: " ").lowercased()
                let chineseName = chinese?.localizedString(forKey: platform.name, value: nil, table: nil).lowercased()
                if normalized == localized || normalized == english || normalized == platform.name.lowercased() || normalized == chineseName || aliases[normalized] == platform.name {
                    return SearchPlatformURLInput.webURL(from: platform.homeURL)
                }
            }
            return nil
        }, linkResult: { [self] in extractedLinks }, checkpoint: { [self] in try await checkpoint($0) }, currentPageURL: { [self] in
            guard let url = tabs.activeWebViewModel?.webView?.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
            return url
        }, finishAgent: { [self] in finish($0, agent: true) })
    }
    private func finish(_ calls: [LocalAIToolCall], agent: Bool) {
        if let destination = destinations.last {
            for url in destinations.dropLast() { tabs.createTab(url: url, switchTo: false) }
            destinations = []
            NotificationCenter.default.post(name: .openSouloWebURL, object: destination, userInfo: ["owner": search])
        } else if let feature = pendingFeature {
            pendingFeature = nil; reveal()
            // Capture/export tools need the browser window after the pop transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { feature() }
        } else if calls.contains(where: { $0.tool == "page_show" }) || (!agent && calls.contains(where: {
            ["tab_switch", "tab_new", "tab_close", "tab_restore", "page_reload", "page_back", "page_forward", "page_scroll", "page_find"].contains($0.tool)
        })) { reveal() }
    }
    private func checkpoint(_ call: LocalAIToolCall) async throws -> Bool {
        if pendingFeature != nil || call.tool == "page_show" { return false }
        let pageChanges = ["open_url", "open_website", "search_web", "page_open_link", "tab_switch", "tab_new", "page_reload", "page_back", "page_forward"]
        guard pageChanges.contains(call.tool) else { return true }
        if let destination = destinations.last {
            guard let model = tabs.activeWebViewModel else { throw LocalAIError.pageChanged }
            destinations = []
            model.loadURL(destination)
            search.isSearching = true
        }
        guard let tab = tabs.activeTab else { throw LocalAIError.pageChanged }
        let expectedID = tab.id, model = tab.webViewModel
        if model.currentURL == nil { return true }
        var readySince: Date?
        var lastSignature = ""
        var stableSamples = 0
        for _ in 0..<300 {
            try Task.checkCancellation()
            guard tabs.activeTab?.id == expectedID, tabs.activeWebViewModel === model else { throw LocalAIError.pageChanged }
            if let failure = model.errorMessage { throw NSError(domain: "Soulo.LocalAI.Navigation", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
            if let web = model.webView, let url = web.url, !web.isLoading,
               let state = try? await web.callAsyncJavaScript("""
                   const root = document.querySelector('main,article,[role="main"]') || document.body;
                   return {url:location.href, ready:document.readyState,
                       text:(root?.innerText || '').trim().length,
                       media:root?.querySelectorAll('img,video,canvas,iframe').length || 0,
                       controls:root?.querySelectorAll('input,textarea,select').length || 0};
                   """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any],
               !web.isLoading, web.url == url, URL(string: state["url"] as? String ?? "") == url,
               ["interactive", "complete"].contains(state["ready"] as? String ?? "") {
                if readySince == nil { readySince = Date() }
                let text = state["text"] as? Int ?? 0, media = state["media"] as? Int ?? 0, controls = state["controls"] as? Int ?? 0
                let signature = url.absoluteString + ":\(text):\(media):\(controls)"
                stableSamples = signature == lastSignature ? stableSamples + 1 : 0
                lastSignature = signature
                // Some SPAs finish their document before fetching the article.
                // Wait for readable content to settle; a genuinely short page
                // remains usable after this bounded grace period.
                let hasContent = text >= 80 || media > 0 || controls > 0
                if stableSamples >= 2, hasContent || Date().timeIntervalSince(readySince!) >= 6 { return true }
            } else { readySince = nil; stableSamples = 0 }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }
    private func category(for id: String) -> LocalAIToolCategory {
        if ["open_url", "open_website", "search_web"].contains(id) { return .navigation }
        if id.hasPrefix("tab") { return .tabs }
        if id.hasPrefix("page_") || id == "set:page_zoom" { return .page }
        if id.hasPrefix("files_") { return .files }
        if id.hasPrefix("set:toolbar_") { return .toolbar }
        if id.hasPrefix("set:soulo.localAI.") { return .assistant }
        if id.hasPrefix("set:privacy_") || ["set:is_incognito", "set:ad_block_enabled", "set:soulo_external_navigation_prompt_enabled", "set:ad_block_confirm_cross_domain", "set:icloud_sync_enabled"].contains(id) { return .privacy }
        if id.hasPrefix("set:reader.") { return .reader }
        if id.hasPrefix("set:web_") { return .webAppearance }
        if ["set:appearance", "set:app_language"].contains(id) || id.hasPrefix("set:home_") { return .appearance }
        return .browsing
    }
    private func validURL(_ value: String?) throws -> URL {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw LocalAIError.pageChanged }
        return url
    }
    private func tabIndex(_ value: String?) throws -> Int {
        let index = value == nil || value == "current" ? tabs.activeTabIndex : (Int(value ?? "") ?? 0) - 1
        guard tabs.tabs.indices.contains(index) else { throw LocalAIError.pageChanged }; return index
    }
    private func setting(_ call: LocalAIToolCall) throws -> Setting {
        guard let item = settings.first(where: { "set:" + $0.key == call.tool }), let value = call.value else { throw LocalAIError.inferenceFailed }
        if item.values.contains("|") { guard item.values.split(separator: "|").contains(Substring(value)) else { throw LocalAIError.invalidToolCall } }
        else if item.values.hasPrefix("number:") {
            let bounds = item.values.dropFirst(7).components(separatedBy: "...")
            guard bounds.count == 2, let low = Double(bounds[0]), let high = Double(bounds[1]), let number = Double(value), number.isFinite, (low...high).contains(number) else { throw LocalAIError.invalidToolCall }
        }
        else if item.key == "page_zoom" { guard let scale = Double(value), scale.isFinite, (50...200).contains(scale) else { throw LocalAIError.inferenceFailed } }
        else { guard value.count <= (item.key.hasPrefix("soulo.localAI.prompt.") ? 2000 : item.key == "home_title" ? 80 : 120), !value.contains("\0") else { throw LocalAIError.invalidToolCall } }
        return item
    }
    private func preview(_ call: LocalAIToolCall) async throws -> String {
        if needsPage(call) {
            guard let tab = tabs.activeTab else { throw LocalAIError.pageChanged }
            reviewedPages[call.tool + (call.value ?? "")] = (tab.id, tab.webViewModel.webView?.url ?? tab.webViewModel.currentURL)
        }
        if call.tool.hasPrefix("set:") { let item = try setting(call); return item.title + " → " + displayValue(call.value ?? "", for: item) }
        switch call.tool {
        case "open_url": return try validURL(call.value).absoluteString
        case "open_website":
            guard let name = call.value, let url = tools.resolveWebsite(name) else { throw LocalAIError.operationNotApplied }
            return text("打开网站：", "Open website: ") + name + "\n" + url.absoluteString
        case "search_web": guard let value = call.value, !value.isEmpty, value.count <= 500 else { throw LocalAIError.inferenceFailed }; return value
        case "tab_switch", "tab_close":
            let i = try tabIndex(call.value); reviewedTabs[call.tool + (call.value ?? "")] = tabs.tabs[i].id
            return "\(i + 1). \(tabs.tabs[i].displayTitle)"
        case "tab_new": if let value = call.value, !value.isEmpty { _ = try validURL(value) }; return text("新建标签页", "New tab")
        case "page_links":
            guard (call.value?.count ?? 0) <= 160 else { throw LocalAIError.invalidToolCall }
            _ = try linkDomains(call.value ?? "")
            return text("读取并筛选当前网页链接", "Read and filter current page links")
        case "page_count_text":
            guard let value = call.value, !value.isEmpty, value.count <= 200 else { throw LocalAIError.invalidToolCall }
            return text("统计网页文字：", "Count page text: ") + value
        case "page_images":
            guard tabs.activeWebViewModel?.webView?.url != nil else { throw LocalAIError.pageChanged }
            return text("提取当前网页的图片资源", "Extract images from the current page")
        case "page_open_link":
            if linksURL != tabs.activeWebViewModel?.webView?.url || pageLinks.isEmpty { try await inspectLinks(filter: linkFilter) }
            guard let number = Int(call.value ?? ""), pageLinks.indices.contains(number - 1) else { throw LocalAIError.pageChanged }
            reviewedLinks[call.tool + (call.value ?? "")] = pageLinks[number - 1].url
            return pageLinks[number - 1].title + "\n" + pageLinks[number - 1].url.absoluteString
        case "page_scroll": guard ["top", "bottom", "up", "down"].contains(call.value ?? "") else { throw LocalAIError.inferenceFailed }; return call.value ?? ""
        case "page_find": guard let value = call.value, !value.isEmpty, value.count <= 200 else { throw LocalAIError.inferenceFailed }; return value
        case "files_organize":
            let directory = BookLibrary.directory
            let scanned = try await Task.detached { try LocalAIFileOrganizer.plan(in: directory) }.value
            let busyFiles = Set(DownloadManagerService.shared.downloads.filter { [.inProgress, .paused].contains($0.status) }.map { $0.localURL.resolvingSymlinksInPath().standardizedFileURL })
            let plan = scanned.filter { !busyFiles.contains($0.source.resolvingSymlinksInPath().standardizedFileURL) }
            filePlan = plan
            return text("按文件类型整理 \(plan.count) 个文件：", "Group \(plan.count) files by type:") + "\n" + plan.map { $0.source.lastPathComponent + " → " + $0.destination.deletingLastPathComponent().lastPathComponent }.joined(separator: "\n")
        default:
            guard tools.catalog.contains(where: { $0.id == call.tool }) else { throw LocalAIError.inferenceFailed }
            if call.tool.hasPrefix("feature:") { return featureTitle(String(call.tool.dropFirst("feature:".count))) }
            return tools.catalog.first(where: { $0.id == call.tool })?.title ?? call.tool
        }
    }
    private func perform(_ call: LocalAIToolCall) async throws -> String {
        if needsPage(call) {
            guard let target = reviewedPages[call.tool + (call.value ?? "")], let tab = tabs.activeTab,
                  tab.id == target.tab, (tab.webViewModel.webView?.url ?? tab.webViewModel.currentURL) == target.url else { throw LocalAIError.pageChanged }
        }
        if call.tool.hasPrefix("set:") {
            let item = try setting(call), old = UserDefaults.standard.object(forKey: item.key)
            let changedPage = tabs.activeWebViewModel, zoom = changedPage?.pageZoom, pageURL = changedPage?.currentURL
            let previousActions = BrowserToolbarConfigurationService.shared.actions, previousAddress = BrowserToolbarConfigurationService.shared.addressAction
            try write(item, value: call.value)
            undoAction = { [self] in
                if item.key == "page_zoom", let zoom {
                    guard let changedPage, changedPage.currentURL == pageURL else { throw LocalAIError.pageChanged }
                    changedPage.setPageZoom(zoom)
                }
                else if item.key.hasPrefix("toolbar_") { BrowserToolbarConfigurationService.shared.save(actions: previousActions, addressAction: previousAddress) }
                else if let old { UserDefaults.standard.set(old, forKey: item.key); try apply(item) }
                else { UserDefaults.standard.removeObject(forKey: item.key); try apply(item) }
                return text("已恢复：", "Restored: ") + item.title
            }
            return text("已设置：", "Changed: ") + item.title + " → " + displayValue(call.value ?? "", for: item)
        }
        switch call.tool {
        case "page_show":
            guard tabs.activeWebViewModel != nil else { throw LocalAIError.pageChanged }
            return text("已展示当前页面", "Current page shown")
        case "page_read":
            guard let model = tabs.activeWebViewModel else { throw LocalAIError.pageChanged }
            let page = try await BrowserLocalAIPageSource(model: model).read()
            return page.title + "\n" + page.url.absoluteString + "\n" + String(page.text.prefix(6000))
        case "open_website":
            guard let name = call.value, let destination = tools.resolveWebsite(name) else { throw LocalAIError.operationNotApplied }
            destinations.append(try validURL(destination.absoluteString)); return text("打开网站：", "Open website: ") + name
        case "open_url": let destination = try validURL(call.value); destinations.append(destination); return text("打开网页：", "Open page: ") + destination.absoluteString
        case "search_web":
            guard let query = call.value, !query.isEmpty, query.count <= 500,
                  let url = search.selectedPlatform?.searchURL(for: query) else { throw LocalAIError.pageChanged }
            destinations.append(try validURL(url.absoluteString)); return text("搜索：", "Search: ") + query
        case "tabs_list": return tabs.tabs.enumerated().map { "\($0.offset + 1). \($0.element.displayTitle)\n\($0.element.webViewModel.currentURL?.absoluteString ?? "")" }.joined(separator: "\n\n")
        case "tab_switch": let index = try reviewedTabIndex(call); tabs.switchToTab(at: index); search.isSearching = true; return text("已切换标签页", "Tab switched")
        case "tab_new": let url = try call.value.flatMap { $0.isEmpty ? nil : try validURL($0) }; tabs.createTab(url: url); search.isSearching = true; return text("已新建标签页", "Tab created")
        case "tab_close":
            let index = try reviewedTabIndex(call), closedID = tabs.tabs[index].id
            tabs.closeTab(at: index)
            undoAction = { [self] in
                guard let closed = tabs.recentlyClosed.first(where: { $0.id == closedID }) else { throw LocalAIError.pageChanged }
                tabs.restoreClosedTab(closed); return text("已恢复标签页", "Tab restored")
            }
            return text("已关闭标签页", "Tab closed")
        case "tab_restore":
            guard !tabs.recentlyClosed.isEmpty else { return text("没有最近关闭的标签页", "There are no recently closed tabs") }
            tabs.restoreLastClosedTab(); return text("已恢复最近关闭的标签页", "Restored the recently closed tab")
        case "page_reload": guard let page = tabs.activeWebViewModel, page.currentURL != nil else { throw LocalAIError.pageChanged }; page.reload(); return text("正在刷新网页", "Reloading page")
        case "page_back": guard let page = tabs.activeWebViewModel, page.canGoBack else { throw LocalAIError.pageChanged }; page.goBack(); return text("已返回上一页", "Went back")
        case "page_forward": guard let page = tabs.activeWebViewModel, page.canGoForward else { throw LocalAIError.pageChanged }; page.goForward(); return text("已前往下一页", "Went forward")
        case "page_links":
            try await inspectLinks(filter: call.value ?? "")
            return pageLinks.isEmpty ? text("当前已加载页面未找到符合条件的链接。", "No matching links were found in the loaded page.") : text("找到 \(pageLinks.count) 个链接", "Found \(pageLinks.count) links")
        case "page_count_text": return try await countText(call.value ?? "")
        case "page_open_link":
            guard linksURL == tabs.activeWebViewModel?.webView?.url, let selectedURL = reviewedLinks[call.tool + (call.value ?? "")] else { throw LocalAIError.pageChanged }
            try await inspectLinks(filter: linkFilter)
            guard let selected = pageLinks.first(where: { $0.url == selectedURL }) else { throw LocalAIError.pageChanged }
            destinations.append(selected.url); return text("打开：", "Open: ") + selected.title
        case "page_scroll":
            guard let web = tabs.activeWebViewModel?.webView else { throw LocalAIError.pageChanged }
            let scroll = web.scrollView, previous = scroll.contentOffset, originalURL = web.url
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let target: CGFloat
            switch call.value { case "top": target = 0; case "bottom": target = maximum; case "up": target = max(0, previous.y - scroll.bounds.height * 0.85); case "down": target = min(maximum, previous.y + scroll.bounds.height * 0.85); default: throw LocalAIError.inferenceFailed }
            scroll.setContentOffset(CGPoint(x: previous.x, y: target), animated: false)
            undoAction = { [weak web, self] in guard let web, web.url == originalURL else { throw LocalAIError.pageChanged }; web.scrollView.setContentOffset(previous, animated: false); return text("已恢复浏览位置", "Reading position restored") }
            return text("已滚动网页", "Page scrolled")
        case "page_find":
            guard let web = tabs.activeWebViewModel?.webView, let query = call.value, !query.isEmpty, query.count <= 200 else { throw LocalAIError.pageChanged }
            let found = await withCheckedContinuation { continuation in web.find(query, configuration: WKFindConfiguration()) { continuation.resume(returning: $0.matchFound) } }
            return text(found ? "已在网页中找到：" : "网页中未找到：", found ? "Found on page: " : "Not found on page: ") + query
        case "page_images":
            guard let feature = features["网页图片 / Page images"], tabs.activeWebViewModel?.webView?.url != nil else { throw LocalAIError.pageChanged }
            queueFeature(feature, for: call)
            return text("正在提取网页图片", "Extracting page images")
        case "files_list":
            let directory = BookLibrary.directory
            let names = try await Task.detached { try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }.sorted().prefix(100).joined(separator: "\n") }.value
            return names.isEmpty ? text("还没有下载文件", "There are no downloaded files yet") : names
        case "files_organize":
            guard let plan = filePlan else { throw LocalAIError.pageChanged }
            try await moveFiles(plan, reverse: false)
            filePlan = nil
            undoAction = { [self] in try await moveFiles(plan, reverse: true); return text("文件已恢复原位", "Files restored to their original locations") }
            return text("已整理 \(plan.count) 个文件，可撤销。", "Organized \(plan.count) files. You can undo this.")
        default:
            let key = String(call.tool.dropFirst("feature:".count))
            guard call.tool.hasPrefix("feature:"), let feature = features[key] else { throw LocalAIError.inferenceFailed }
            queueFeature(feature, for: call); return text("打开：", "Open: ") + featureTitle(key)
        }
    }
    private func needsPage(_ call: LocalAIToolCall) -> Bool {
        if call.tool.hasPrefix("page_") || call.tool == "set:page_zoom" { return true }
        guard call.tool.hasPrefix("feature:") else { return false }
        return !["设置 / Settings", "文件 / Files", "下载 / Downloads", "收藏 / Bookmarks", "历史 / History", "扩展 / Extensions"].contains(String(call.tool.dropFirst("feature:".count)))
    }
    private func queueFeature(_ feature: @escaping () -> Void, for call: LocalAIToolCall) {
        let target = reviewedPages[call.tool + (call.value ?? "")]
        let tabs = self.tabs
        pendingFeature = { [weak tabs] in
            guard let tabs else { return }
            if let target {
                guard let active = tabs.activeTab, active.id == target.tab,
                      (active.webViewModel.webView?.url ?? active.webViewModel.currentURL) == target.url else { return }
            }
            feature()
        }
    }
    private func displayValue(_ value: String, for item: Setting) -> String {
        if item.values == "true|false" { return value == "true" ? text("开启", "On") : text("关闭", "Off") }
        if item.key == "appearance" || item.key == "reader.theme" {
            return ["system": text("跟随系统", "System"), "light": text("浅色", "Light"), "dark": text("深色", "Dark"), "paper": text("纸张", "Paper")][value] ?? value
        }
        if item.key == "reader.font" { return ["serif": text("衬线", "Serif"), "sans": text("无衬线", "Sans serif"), "mono": text("等宽", "Monospaced")][value] ?? value }
        if item.key == "page_zoom" { return value + "%" }
        if item.key == "soulo.localAI.avatar" { return AIL10n.text("avatar_" + value) }
        if item.key.hasPrefix("toolbar_"), let action = BrowserToolbarAction(rawValue: value) { return action.localizedTitle }
        if item.key == "app_language" { return AppConstants.supportedLanguages.first(where: { $0.code == value })?.name ?? value }
        return value
    }
    private func write(_ item: Setting, value: String?) throws {
        guard let value else { throw LocalAIError.inferenceFailed }
        if item.key.hasPrefix("toolbar_") {
            guard let action = BrowserToolbarAction(rawValue: value) else { throw LocalAIError.invalidToolCall }
            let service = BrowserToolbarConfigurationService.shared
            if item.key == "toolbar_address" { service.save(actions: service.actions, addressAction: action) }
            else {
                guard let number = Int(item.key.replacingOccurrences(of: "toolbar_slot_", with: "")), (1...4).contains(number) else { throw LocalAIError.invalidToolCall }
                var actions = service.actions; actions[number - 1] = action; service.save(actions: actions, addressAction: service.addressAction)
            }
            return
        }
        if item.key == "page_zoom" { guard let page = tabs.activeWebViewModel, let number = Double(value) else { throw LocalAIError.pageChanged }; page.setPageZoom(CGFloat(number / 100)); return }
        if item.key == "is_incognito" {
            _ = search.setPrivateBrowsing(value == "true", tabManager: tabs)
            guard search.isIncognito == (value == "true") else { throw LocalAIError.operationNotApplied }; return
        }
        if item.key.hasPrefix("soulo.localAI.prompt."), let kind = LocalAIPromptKind(rawValue: String(item.key.dropFirst("soulo.localAI.prompt.".count))) { LocalAIPrompts.save(value, kind: kind); return }
        if item.values == "true|false" { UserDefaults.standard.set(value == "true", forKey: item.key) }
        else if item.values.hasPrefix("number:"), let number = Double(value) { UserDefaults.standard.set(number, forKey: item.key) }
        else { UserDefaults.standard.set(value, forKey: item.key) }
        try apply(item)
        if item.values == "true|false", UserDefaults.standard.bool(forKey: item.key) != (value == "true") { throw LocalAIError.operationNotApplied }
    }
    private func reviewedTabIndex(_ call: LocalAIToolCall) throws -> Int {
        guard let id = reviewedTabs[call.tool + (call.value ?? "")], let index = tabs.tabs.firstIndex(where: { $0.id == id }) else { throw LocalAIError.pageChanged }
        return index
    }
    private func apply(_ item: Setting) throws {
        if item.key == "is_incognito" { _ = search.setPrivateBrowsing(UserDefaults.standard.bool(forKey: item.key), tabManager: tabs) }
        if item.key == "icloud_sync_enabled" { CloudSyncService.shared.setEnabled(UserDefaults.standard.bool(forKey: item.key)) }
        if item.key == "soulo.localAI.enabled", !UserDefaults.standard.bool(forKey: item.key) { LocalAIRuntime.shared.release() }
        if item.key == "app_language" { LanguageManager.shared.selectedLanguage = UserDefaults.standard.string(forKey: item.key) ?? AppConstants.preferredLanguageCode() }
        if item.key == "appearance" { ThemeManager.shared.setAppearance(UserDefaults.standard.string(forKey: item.key) ?? "system") }
        if item.key.hasPrefix("web_") {
            WebAppearanceService.shared.refreshFromDefaults()
            for tab in tabs.tabs { if let web = tab.webViewModel.webView { WebAppearanceService.shared.apply(to: web) } }
        }
        if item.key == "ad_block_enabled", let page = tabs.activeWebViewModel { WebViewRepresentable.reloadWithCurrentAdRules(page) }
    }
    private func linkDomains(_ filter: String) throws -> [String] {
        guard filter.count <= 160 else { throw LocalAIError.invalidToolCall }
        let parts = filter.split(whereSeparator: { "|,，".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        let domains = parts.compactMap { value -> String? in
            if let site = tools.resolveWebsite(value)?.host { return site.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored) }
            guard let parsed = URL(string: value.contains("://") ? value : "https://" + value), let host = parsed.host,
                  host.contains("."), parsed.user == nil, parsed.password == nil else { return nil }
            return host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
        }
        guard domains.count == parts.count else { throw LocalAIError.invalidToolCall }
        return domains
    }
    private func inspectLinks(filter: String) async throws {
        guard let web = tabs.activeWebViewModel?.webView, let url = web.url else { throw LocalAIError.pageChanged }
        let domainFilter = try linkDomains(filter)
        let values = try await web.callAsyncJavaScript("""
        const links=[], seen=new Set(), anchors=Array.from(document.querySelectorAll('a[href]'));
        let limited=anchors.length>4000;
        const valid=value=>{try{const u=new URL(value,location.href);return /^https?:$/.test(u.protocol)&&!u.username&&!u.password&&u.href.length<=2048?u:null}catch(_){return null}};
        const matches=u=>domains.some(d=>u.hostname===d||u.hostname.endsWith('.'+d));
        for (const a of anchors.slice(0,4000)) {
            const r=a.getBoundingClientRect();
            if(r.width<=1||r.height<=0||getComputedStyle(a).visibility==='hidden'||a.closest('[data-soulo-video-rotate],#soulo-episode-dock'))continue;
            const title=(a.innerText||a.getAttribute('aria-label')||a.href).trim().slice(0,180);
            const candidates=[valid(a.href)].filter(Boolean);
            // Read associated DOM metadata; never fetch a tracking URL just to
            // discover its destination, and never execute website handlers.
            for(let node=a,depth=0;node&&node!==document.body&&depth<5;node=node.parentElement,depth++){
                for(const key of ['mu','data-url','data-landurl','data-href','data-original-url']){
                    const raw=node.getAttribute(key);if(raw){const u=valid(raw);if(u)candidates.push(u)}
                }
                const raw=node.getAttribute('data-log');
                if(raw&&raw.length<=4096){try{const data=JSON.parse(raw);for(const key of ['mu','url','target']){if(typeof data[key]==='string'){const u=valid(data[key]);if(u)candidates.push(u)}}}catch(_){}}
                if(node.matches('article,.result,.c-container,.b_algo'))break;
            }
            for(const u of candidates.slice()){
                for(const key of ['url','target','redirect_url','dest']){
                    const raw=u.searchParams.get(key);if(raw&&(raw.startsWith('https://')||raw.startsWith('http://'))){const next=valid(raw);if(next)candidates.push(next)}
                }
            }
            let selected;
            if(domains.length)selected=candidates.find(matches);
            else selected=candidates[0];
            if(!selected||seen.has(selected.href))continue;
            if(links.length>=100){limited=true;break}
            seen.add(selected.href);links.push({title:title||selected.hostname,url:selected.href});
        }
        return {links,limited};
        """, arguments: ["domains": domainFilter], in: nil, contentWorld: .defaultClient)
        guard web === tabs.activeWebViewModel?.webView, web.url == url, let result = values as? [String: Any], let list = result["links"] as? [[String: String]] else { throw LocalAIError.pageChanged }
        pageLinks = list.compactMap { item in guard let href = item["url"], let parsed = try? validURL(href) else { return nil }; return LocalAIPageLink(title: item["title"] ?? href, url: parsed) }
        linksURL = url
        linkFilter = filter
        extractedLinks = LocalAILinkResult(links: pageLinks, sourceURL: url, filter: filter, limited: result["limited"] as? Bool ?? false)
    }
    private func countText(_ value: String) async throws -> String {
        guard !value.isEmpty, value.count <= 200, let web = tabs.activeWebViewModel?.webView, let url = web.url else { throw LocalAIError.pageChanged }
        let result = try await web.callAsyncJavaScript("""
        const full=document.body?.innerText||'', text=full.slice(0,2000000);
        let count=0,offset=0;
        while((offset=text.indexOf(needle,offset))!==-1){count++;offset+=needle.length}
        return {count,limited:full.length>text.length};
        """, arguments: ["needle": value], in: nil, contentWorld: .defaultClient)
        guard web === tabs.activeWebViewModel?.webView, web.url == url, let data = result as? [String: Any], let count = data["count"] as? Int else { throw LocalAIError.pageChanged }
        let prefix = data["limited"] as? Bool == true ? text("已检查的网页文字中", "In the inspected page text") : text("当前已加载的网页文字中", "In the currently loaded page text")
        return prefix + text("，“", ", “") + value + text("”出现 **\(count)** 次。", "” occurs **\(count)** times.") + "\n\n" + text("按主页面已加载的可见文字统计，不含输入框、图片和嵌入网页中的文字。", "Counted from rendered text in the loaded main document, excluding input values, image text and embedded pages.")
    }
    private func moveFiles(_ plan: [LocalAIFileMove], reverse: Bool) async throws {
        let activeFiles = Set(DownloadManagerService.shared.downloads.filter { [.inProgress, .paused].contains($0.status) }.map { $0.localURL.resolvingSymlinksInPath().standardizedFileURL })
        guard !plan.contains(where: { activeFiles.contains((reverse ? $0.destination : $0.source).resolvingSymlinksInPath().standardizedFileURL) }) else { throw LocalAIError.operationNotApplied }
        let references = plan.map { move in (move, Set(BookLibrary.shared.books.filter { $0.url.resolvingSymlinksInPath().standardizedFileURL == (reverse ? move.destination : move.source).resolvingSymlinksInPath().standardizedFileURL }.map(\.id))) }
        let directory = BookLibrary.directory
        try await Task.detached { try LocalAIFileOrganizer.commit(plan, in: directory, reverse: reverse) }.value
        do { try BookLibrary.shared.updateFileReferences(references.map { (bookIDs: $0.1, url: reverse ? $0.0.source : $0.0.destination) }) }
        catch {
            try? await Task.detached { try LocalAIFileOrganizer.commit(plan, in: directory, reverse: !reverse) }.value
            throw error
        }
        let changes = plan.map { (from: reverse ? $0.destination : $0.source, to: reverse ? $0.source : $0.destination) }
        DownloadManagerService.shared.updateFileReferences(changes)
        for change in changes { MediaSession.shared.updateFileReference(from: change.from, to: change.to) }
    }
}
#endif
