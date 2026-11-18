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
                    }
                    .buttonStyle(CompactActionButtonStyle(prominent: true))
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
                    ("GM_xmlhttpRequest / GM.xmlHttpRequest", "userscript_docs_limits_network"),
                    ("Private Browsing", "userscript_docs_limits_private"),
                    ("@require", "userscript_docs_limits_require")
                ]
            )

            Section("Soulo \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.17") · API") {
                ScrollView(.horizontal) {
                    Text(Self.runtimeReference)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            }

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
        HapticsManager.success()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            promptCopied = false
        }
    }

    private var aiPrompt: String {
        if LanguageManager.shared.currentLanguage.hasPrefix("zh") {
            return Self.chineseAIPrompt + "\n\n" + Self.runtimeReference
        }
        return Self.englishAIPrompt + "\n\n" + Self.runtimeReference
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
    6. GM_xmlhttpRequest details 支持 url、method、headers、data、timeout、responseType、anonymous、cookie、context，以及 onloadstart、onreadystatechange、onprogress、upload 事件、ontimeout、onabort、onload、onerror、onloadend。data 支持文本、Blob、ArrayBuffer、TypedArray、URLSearchParams 和 FormData；responseType 可为 json、blob、arraybuffer 或文本。GM.xmlHttpRequest 返回可 await 的 Promise，两种写法均可通过 abort() 取消。单次响应上限 20 MiB、上传上限 8 MiB、每页最多 8 个并发请求，超时范围 1–60 秒。进度事件报告 loaded/total 字节数，完整响应在 onload 中读取；不提供流式 responseText。不会自动发送 Cookie，也不能通过 headers 注入 Cookie/Host/Origin；显式 cookie 参数还需 GM_cookie 权限，anonymous=true 时不发送，跨源重定向时移除。
    7. 存储单个值上限 256 KiB、脚本总存储上限 1 MiB，只保存可 JSON 序列化的数据。值变化监听支持跨标签页，其他标签页的变化会以 remote=true 通知；注意移除不再使用的监听器。
    8. @resource 需要声明名称、URL 及匹配的 @connect；资源 API 是异步 Promise。HTTPS @require 在安装或保存时下载并缓存，按声明顺序在正文前执行，不需要 @connect；旧 HTTP 地址会升级为 HTTPS。最多 32 个依赖，单文件 5 MB、合计 20 MB；支持 URL 片段中的 MD5、SHA-1/256/384/512 完整性校验，不支持 tampermonkey:// 内置依赖。
    9. 可以使用标准 DOM、事件、MutationObserver、fetch 等网页 API；fetch 仍受网页同源和 CORS 限制。脚本在隐私浏览中不运行。
    10. 兼顾 iPhone/iPad、明暗模式、安全区、动态网页和无障碍；所有新增 DOM id/class 使用独特前缀，避免污染网页；避免高频无节制的 MutationObserver、轮询和全局样式。
    11. 代码应可重复执行而不产生重复控件，包含必要的空值检查、错误处理和清理逻辑；页面跳转、重复运行和 DOM 移除时取消请求、移除监听器并释放 Object URL。独立脚本按主框架注入；不要假定能够直接访问跨域 iframe。
    12. 下载公网直链优先使用 GM_download / GM.download 并遵守 @connect、取消和错误回调；不要把大视频全部经 GM 请求读入内存后拼成 Blob。不要伪造文件大小，也不要把分片数、时长或进度单位当作字节。
    13. 如必须处理 Range，验证 206、Content-Range 和准确字节长度；遇到服务器忽略 Range 返回 200 时退回普通下载，不重复拼接整文件。请求池应有上限和退避，不能假定每片都重新握手。
    14. HLS 既可能是 TS，也可能是 fMP4。AES-128 未提供 IV 时应按媒体序号生成 128 位大端 IV，不能使用密钥充当 IV。TS 拼接不等于 MP4 封装；不要默认删除疑似广告分片或处理 DRM。
    15. 本需求生成的是独立 UserScript，不是 CRX/WebExtension。不要在 .user.js 中调用 chrome.userScripts、chrome.runtime 或 chrome.downloads；下方 extensionHost 参考仅适用于已安装的浏览器扩展。不要把部分接口支持表述为完整 Chrome/Tampermonkey 兼容。
    16. 提供 HTTPS @updateURL/@downloadURL 和 @version 可用于更新检查；打开已安装列表时每次最多检查 4 个脚本，每个脚本每 24 小时最多一次。隐私浏览、低电量或高温时暂停；更新代码仍需用户检查确认后安装。GM_webRequest、GM_audio 和 sandbox/run-in 隔离暂不支持。

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
    6. XHR details support url, method, headers, data, timeout, responseType, anonymous, cookie, context, onloadstart, onreadystatechange, onprogress, upload events, ontimeout, onabort, onload, onerror, and onloadend. data accepts text, Blob, ArrayBuffer, TypedArray, URLSearchParams, and FormData. responseType may be json, blob, arraybuffer, or text. Limits: 20 MiB per response, 8 MiB per upload, 8 concurrent requests per page, and 1–60 seconds per request. Progress reports loaded/total bytes; read the complete response in onload, not streaming responseText. Cookies are not sent automatically; Cookie/Host/Origin cannot be injected through headers. An explicit cookie option also requires GM_cookie permission; anonymous=true suppresses it, and cross-origin redirects remove it. GM.xmlHttpRequest returns an awaitable Promise; both forms support abort().
    7. Persist only JSON-serializable values. Limits: 256 KiB per value and 1 MiB per script. Value listeners support cross-tab changes, reporting remote=true for another tab. Remove listeners when no longer needed.
    8. @resource requires a name, URL, and matching @connect; resource APIs return Promises. HTTPS @require files are downloaded and cached at installation or save, then executed in declaration order before the main script without needing @connect; legacy HTTP URLs are upgraded to HTTPS. Limits: 32 dependencies, 5 MB each, 20 MB total. MD5 and SHA-1/256/384/512 integrity hashes in URL fragments are supported; tampermonkey:// built-in dependencies are not.
    9. Standard DOM, events, MutationObserver, fetch, and other web APIs are available; fetch remains subject to page origin and CORS. Scripts do not run in Private Browsing.
    10. Support iPhone/iPad, light/dark appearance, safe areas, dynamic pages, and accessibility. Namespace every inserted id/class and avoid expensive polling, unbounded observers, and global CSS leakage.
    11. Make execution idempotent. Cancel outstanding requests, remove listeners, and revoke Object URLs on cleanup/navigation. Standalone scripts are injected in the main frame; do not assume cross-origin iframe access.
    12. Prefer GM_download / GM.download for public direct URLs, respecting @connect, cancellation, and error callbacks. Do not accumulate an entire large video in memory through GM XHR and Blob arrays. Never present segment counts, duration, or scaled progress units as bytes or invent a file size.
    13. For Range requests, validate 206, Content-Range, and exact byte counts. Fall back to an ordinary download if the server ignores Range and returns 200; never concatenate duplicated whole files. Bound concurrency and back off on failures. Connections may be reused between requests.
    14. HLS may contain TS or fMP4. If AES-128 has no IV attribute, derive the 128-bit big-endian IV from the media sequence number, never from the key. Concatenated TS is not MP4 muxing. Do not remove presumed ad segments by default or implement DRM decryption.
    15. This output is a standalone UserScript, not a CRX/WebExtension. Do not call chrome.userScripts, chrome.runtime, or chrome.downloads from .user.js. The extensionHost reference below applies only to installed browser extensions. Partial API support does not mean complete Chrome/Tampermonkey compatibility.
    16. Supply HTTPS @updateURL/@downloadURL and @version for update checks. Opening Installed checks up to 4 scripts per visit, once per script per 24 hours. Checks pause in Private Browsing, Low Power Mode, or high heat. Updated code still requires user review and installation. GM_webRequest, GM_audio, and sandbox/run-in isolation are unsupported.

    Generate the script now from the Requirement section.
    """

    /// Machine-readable reference shared by the visible document and copied
    /// prompt, so their capability boundaries cannot drift independently.
    private static var runtimeReference: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.17"
        return """
        {
          "Soulo": "\(version)",
          "standaloneUserScript": {
            "format": ".user.js", "frames": "main", "privateBrowsing": false,
            "GM_xmlhttpRequest": {"maxResponseBytes": 20971520, "maxUploadBytes": 8388608, "maxConcurrentPerPage": 8, "timeoutSeconds": [1, 60], "events": ["progress", "upload", "timeout", "abort"], "progress": "loaded/total bytes; complete response in onload", "automaticCookies": false, "explicitCookieGrant": "GM_cookie", "anonymousSuppressesCookie": true, "crossOriginRedirectStripsCookie": true},
            "GM_download": {"transport": "native", "publicHTTPURL": true, "requiresConnectPermission": true, "gmXHRSizeCapApplies": false},
            "storage": {"perValueBytes": 262144, "perScriptBytes": 1048576, "crossTabValueListeners": true, "remoteChanges": true},
            "updateChecks": {"trigger": "Installed list", "perVisit": 4, "minimumIntervalHours": 24, "metadataOnly": true, "automaticInstall": false},
            "unsupported": ["GM_webRequest", "GM_audio", "sandbox/run-in isolation"]
          },
          "extensionHost": {
            "minimumIOS": "18.4", "publisherPermissionsRequired": true,
            "userScripts.execute": {"worlds": ["USER_SCRIPT", "MAIN"], "targets": ["tabId", "frameIds", "documentIds", "allFrames"], "asyncResults": true},
            "userScripts.configureWorld": {"messaging": "opt-in", "networkCSP": ["default-src", "connect-src"], "fullChromeCSP": false},
            "runtime": ["onUserScriptMessage", "onUserScriptConnect", "bidirectional ports"],
            "downloads": ["HTTP(S)", "owned Blob", "data URL"],
            "registeredScripts": "wrapped programs; use explicit shared global state when required",
            "allChromeAPIs": false, "allExtensionsCompatible": false
          }
        }
        """
    }

}
