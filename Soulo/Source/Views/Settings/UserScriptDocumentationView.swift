import SwiftUI

struct UserScriptDocumentationView: View {
    @State private var promptCopied = false

    private let template = """
    // ==UserScript==
    // @name My Soulo Script
    // @description Describe what the script does.
    // @namespace com.example.soulo.my-script
    // @version 1.0.0
    // @match https://example.com/*
    // @grant GM_addStyle
    // @run-at document-end
    // ==/UserScript==

    (() => {
      'use strict';
      // Your code here.
    })();
    """

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 13) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 44, height: 44)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(localized("userscript_docs_ai_title"))
                                .font(.headline)
                            Text(localized("userscript_docs_ai_desc"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button(action: copyAIPrompt) {
                        Label(
                            localized(promptCopied ? "copied" : "userscript_docs_copy_prompt"),
                            systemImage: promptCopied ? "checkmark.circle.fill" : "doc.on.doc.fill"
                        )
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.vertical, 7)
            }

            Section(localized("userscript_docs_status_title")) {
                compatibilityRow(
                    titleKey: "userscript_docs_supported_title",
                    descriptionKey: "userscript_docs_supported_desc",
                    icon: "checkmark.circle.fill",
                    tint: .green
                )
                compatibilityRow(
                    titleKey: "userscript_docs_partial_title",
                    descriptionKey: "userscript_docs_partial_desc",
                    icon: "circle.lefthalf.filled",
                    tint: .orange
                )
                compatibilityRow(
                    titleKey: "userscript_docs_unsupported_title",
                    descriptionKey: "userscript_docs_unsupported_desc",
                    icon: "xmark.circle.fill",
                    tint: .secondary
                )
            }

            documentationSection(
                titleKey: "userscript_docs_metadata_title",
                rows: [
                    ("@name / @description", "userscript_docs_metadata_identity"),
                    ("@namespace / @version", "userscript_docs_metadata_version"),
                    ("@match / @include", "userscript_docs_metadata_match"),
                    ("@exclude / @exclude-match", "userscript_docs_metadata_exclude"),
                    ("@run-at document-start | document-end", "userscript_docs_metadata_run_at"),
                    ("@grant", "userscript_docs_metadata_grant"),
                    ("@connect", "userscript_docs_metadata_connect"),
                    ("@homepage / @updateURL / @downloadURL", "userscript_docs_metadata_urls"),
                    ("@resource name URL", "userscript_docs_metadata_resource"),
                    ("@require", "userscript_docs_metadata_require")
                ]
            )

            documentationSection(
                titleKey: "userscript_docs_api_title",
                rows: [
                    ("GM_info · GM.info", "userscript_docs_api_info"),
                    ("unsafeWindow", "userscript_docs_api_unsafe_window"),
                    ("GM_addStyle(css) · await GM.addStyle(css)", "userscript_docs_api_style"),
                    ("GM_log(...values) · GM.log(...values)", "userscript_docs_api_log"),
                    ("GM_getValue(key, fallback) · await GM.getValue(…)", "userscript_docs_api_get"),
                    ("GM_setValue(key, value) · await GM.setValue(…)", "userscript_docs_api_set"),
                    ("GM_deleteValue(key) · await GM.deleteValue(…)", "userscript_docs_api_delete"),
                    ("GM_listValues() · await GM.listValues()", "userscript_docs_api_list"),
                    ("GM_getValues / setValues / deleteValues", "userscript_docs_api_bulk"),
                    ("GM_addValueChangeListener / remove…", "userscript_docs_api_listener"),
                    ("GM_addElement(…) · await GM.addElement(…)", "userscript_docs_api_element"),
                    ("GM_setClipboard(value) · await GM.setClipboard(…)", "userscript_docs_api_clipboard")
                ]
            )

            documentationSection(
                titleKey: "userscript_docs_extended_title",
                rows: [
                    ("GM_registerMenuCommand / unregister…", "userscript_docs_api_menu"),
                    ("GM_notification · GM.notification", "userscript_docs_api_notification"),
                    ("GM_openInTab / closeTab / focusTab", "userscript_docs_api_tabs"),
                    ("GM_download · GM.download", "userscript_docs_api_download"),
                    ("GM_getTab / saveTab / getTabs", "userscript_docs_api_tabdata"),
                    ("GM_cookie · GM.cookie", "userscript_docs_api_cookie"),
                    ("GM.getResourceText / getResourceUrl", "userscript_docs_api_resource"),
                    ("window.onurlchange / urlchange", "userscript_docs_api_urlchange")
                ]
            )

            documentationSection(
                titleKey: "userscript_docs_network_title",
                rows: [
                    ("GM_xmlhttpRequest(details)", "userscript_docs_network_legacy"),
                    ("GM.xmlHttpRequest(details)", "userscript_docs_network_modern"),
                    ("details", "userscript_docs_network_details"),
                    ("responseType", "userscript_docs_network_response"),
                    ("@connect self | example.com | *.example.com | *", "userscript_docs_network_connect")
                ]
            )

            documentationSection(
                titleKey: "userscript_docs_limits_title",
                rows: [
                    ("Web APIs", "userscript_docs_limits_web"),
                    ("Storage", "userscript_docs_limits_storage"),
                    ("Network", "userscript_docs_limits_network"),
                    ("Private Browsing", "userscript_docs_limits_private"),
                    ("@require", "userscript_docs_limits_require")
                ]
            )

            Section {
                ScrollView(.horizontal) {
                    Text(template)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            } header: {
                Text(localized("userscript_docs_template_title"))
            } footer: {
                Text(localized("userscript_docs_template_footer"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(localized("userscripts_documentation"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func documentationSection(
        titleKey: String,
        rows: [(signature: String, descriptionKey: String)]
    ) -> some View {
        Section(localized(titleKey)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.signature)
                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(localized(row.descriptionKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func compatibilityRow(
        titleKey: String,
        descriptionKey: String,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized(titleKey))
                    .font(.subheadline.weight(.semibold))
                Text(localized(descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func localized(_ key: String) -> String {
        LanguageManager.shared.localizedString(key)
    }

    private func copyAIPrompt() {
        UIPasteboard.general.string = aiPrompt
        promptCopied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            promptCopied = false
        }
    }

    private var aiPrompt: String {
        if LanguageManager.shared.currentLanguage.hasPrefix("zh") {
            return Self.chineseAIPrompt
        }
        return Self.englishAIPrompt
    }

    private static let chineseAIPrompt = """
    你是一名为 iOS 浏览器 Soulo 编写 UserScript 的资深 JavaScript 工程师。请根据我随后提供的需求，生成一个可直接安装到 Soulo 的完整 `.user.js` 脚本。

    用户需求：
    【请在这里填写具体需求】

    必须遵守以下兼容规则：
    1. 只输出一个完整的 JavaScript 代码块，不要输出解释、Markdown 标题或省略号。
    2. 必须包含 `// ==UserScript==` 元数据块，并填写 @name、@description、唯一 @namespace、@version、至少一个 @match，以及正确的 @run-at。
    3. @match 支持 `http`、`https`、`*://*/*`、`https://*.example.com/*` 和 `<all_urls>`；如需排除页面，使用 @exclude 或 @exclude-match。
    4. 只声明实际使用的权限。无特权 API 时写 `@grant none`。支持传统及 GM.* 现代写法：GM_info、unsafeWindow、GM_addStyle、GM_addElement、GM_log、单项/批量存储、值变化监听、GM_setClipboard、GM_xmlhttpRequest、菜单命令、通知、打开/关闭/聚焦标签页、下载、Tab 数据、GM_cookie、GM.getResourceText/GM.getResourceUrl 和 window.onurlchange。
    5. 跨域请求必须同时声明 GM_xmlhttpRequest 或 GM.xmlHttpRequest，以及对应 @connect。@connect 支持 self、域名、*.域名或 *。没有 @connect 时仅允许请求当前网页主机。
    6. GM_xmlhttpRequest details 支持 url、method、headers、data、timeout、responseType，以及 onloadstart、onreadystatechange、onload、onerror、onloadend；responseType 可为 json、blob、arraybuffer 或文本。网络响应上限 20 MB，超时范围 1–60 秒，不发送 Cookie。
    7. 存储单个值上限 256 KB、脚本总存储上限 1 MB，只保存可 JSON 序列化的数据。
    8. @resource 需要声明名称、URL 及匹配的 @connect；资源 API 是异步 Promise。@require 只会在安装时显示，不会自动下载或执行，因此脚本必须自包含，不依赖 CDN 或外部库。
    9. 可以使用标准 DOM、事件、MutationObserver、fetch 等网页 API；fetch 仍受网页同源和 CORS 限制。脚本在隐私浏览中不运行。
    10. 兼顾 iPhone/iPad、明暗模式、安全区、动态网页和无障碍；所有新增 DOM id/class 使用独特前缀，避免污染网页；避免高频无节制的 MutationObserver、轮询和全局样式。
    11. 代码应可重复执行而不产生重复控件，包含必要的空值检查、错误处理和清理逻辑。

    请现在根据“用户需求”生成脚本。
    """

    private static let englishAIPrompt = """
    You are a senior JavaScript engineer writing a UserScript for the Soulo iOS browser. Generate one complete, directly installable `.user.js` script for the requirement I provide below.

    Requirement:
    [Describe the desired behavior here]

    Compatibility requirements:
    1. Return exactly one complete JavaScript code block. Do not add explanations, headings, or omitted sections.
    2. Include a `// ==UserScript==` metadata block with @name, @description, a unique @namespace, @version, at least one @match, and the correct @run-at.
    3. Match rules support http, https, `*://*/*`, `https://*.example.com/*`, and `<all_urls>`. Use @exclude or @exclude-match when needed.
    4. Declare only permissions actually used. Use `@grant none` when no privileged API is needed. Soulo supports legacy and GM.* forms for script info, unsafeWindow, styles/elements, logging, single/bulk storage, value listeners, clipboard, privileged requests, menu commands, notifications, tab opening/closing/focusing, downloads, tab data, cookies, resources, and URL-change events.
    5. Cross-origin requests require the XHR grant and matching @connect entries. @connect accepts self, a domain, *.domain, or *. Without @connect, privileged requests are limited to the current page host.
    6. XHR details support url, method, headers, data, timeout, responseType, onloadstart, onreadystatechange, onload, onerror, and onloadend. responseType may be json, blob, arraybuffer, or text. Responses are limited to 20 MB, timeout is 1–60 seconds, and cookies are not sent.
    7. Persist only JSON-serializable values. The limit is 256 KB per value and 1 MB per script.
    8. @resource requires a name, URL, and matching @connect; resource APIs return Promises. @require is displayed during installation but is not downloaded or executed. The script must be self-contained with no CDN dependency.
    9. Standard DOM, events, MutationObserver, fetch, and other web APIs are available; fetch remains subject to page origin and CORS. Scripts do not run in Private Browsing.
    10. Support iPhone/iPad, light/dark appearance, safe areas, dynamic pages, and accessibility. Namespace every inserted id/class and avoid expensive polling, unbounded observers, and global CSS leakage.
    11. Make execution idempotent and include appropriate null checks, error handling, and cleanup.

    Generate the script now from the Requirement section.
    """
}
