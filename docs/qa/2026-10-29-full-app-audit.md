# 1.2.6 全应用功能与代码检查

日期：2026-10-29。范围：当前工作区（包含此前尚未提交的扩展、媒体、跳转和版本修改）。保留用户原有修改，不提交或推送。版本保持 1.2.6（51）。

## 检查方式与边界

- 主应用 199 个 Swift 文件，约 6.2 万行；同时检查 Widget、分享扩展、工程配置、权限及本地化资源。补充本轮用例后声明的单元测试为 836 项、UI 测试 71 项；这是源码数量，不是本次执行通过数量。下文全量 829 项为新增 7 项回归前的执行记录。
- 以源码入口/状态流审查、风险模式扫描、单元测试、浏览器界面回归和 Release 构建分别记录证据。源码扫描不等于逐个第三方网站、所有设备及所有权限状态都实机通过。
- 基线差异保存在 `/tmp/soulo-full-app-audit-baseline-20261029.patch`。新增回归用例位于 `SouloTests/AppFunctionalAuditTests.swift`。
- 未发送反馈、发布版本、修改账号数据或操作其他项目的进程和模拟器。

## 功能范围

| 模块 | 代码核对重点 | 对应回归 |
|---|---|---|
| 搜索、输入、平台及分组 | 组合输入、取消旧建议、网址分类、关键词编码、批量导入、分组身份、统计计数 | SearchInput、TabManager、SelectionSearchNavigation、AppFunctionalAudit |
| 网页、标签及导航 | 恢复、隐私切换、前进后退、主/子 frame、原生入口、跳转授权 | WebViewModel、WebBrowsingRegression、WebDomainNavigation、WebFrameRequest、TabOverviewLifecycle |
| 广告与隐私 | 域名边界、自动跳转、脚本世界、缓存、历史及系统搜索索引清理 | AdBlock、PrivacyProtection、PrivacyNavigation、BrowserAdNavigation、AppFunctionalAudit |
| 视频、音频及下载 | 播放状态、页面媒体移交、暂停/取消、恢复、文件命名、清理、离线包 | DownloadPlayback、BackgroundDownloadRecovery、WebMediaPlaybackBridge、WebEpisodeDownload |
| 用户脚本与 Web 扩展 | 安装、依赖、授权、跨源请求、存储、归档目录边界 | UserScriptRequirements、ExtensionAudit、ExtensionArchive、ExtensionLifecycle |
| 文件、阅读、图片及 Wi-Fi 传输 | 路径与符号链接、重复文件、大小限制、解压、阅读取消、传输配对及 Host 检查 | ReadingTools、ReaderExperience、LibraryExperience、FileRename、FileBrowserRefinement |
| 书签与历史 | 导入去重、文件夹关系、删除范围、保存与 Spotlight 一致性 | BookmarkImportExport、ReadingTools、AppFunctionalAudit |
| 云同步与备份 | 允许字段、数据类型、跨设备 ID、删除记录、合并优先级、回滚前备份、KVS 容量 | CloudSyncSafety |
| 系统入口、分享及权限 | URL scheme、App Group 原子交接、分享取消、控制中心、快捷指令、相机/麦克风/传感器提示 | SharedWebLink、SouloURLRoute、ShareContentLoader、SpeechRecognition、SettingsAndCertificate |
| 外观、设置及发布资源 | 默认偏好、壁纸任务、主题、工具栏、语言资源、版本一致性 | BrowserUIPreferences、SettingsAndCertificate、LocalizationLayout、资源检查脚本 |

## 已确认并修正

1. **关键词改变网址结构。** 抖音等把关键词放在路径中的平台，`AC/DC` 会生成额外路径段，`猫?狗` 会变成 query。直接编译修改前的 `SearchPlatform.swift` 已复现，日志 `/tmp/soulo-audit-search-url-before.log`。搜索和四个自动建议提供方统一使用适用于路径段/参数值的编码。进一步发现 Pexels/Pixabay 前台搜索与后台取图共四处有同类问题，也统一采用该编码。
2. **搜索建议拆坏内容。** 百度建议按逗号与首个 `]` 拆分，无法保留字符串中的逗号、括号及转义。改为移除 JSONP 包装后用 JSON5 解码对象，并拒绝非成功 HTTP 响应。已实际获取公开 `swift` 建议响应确认 GB18030 与未加引号字段格式；原始样本 `/tmp/soulo-audit-baidu-suggestions.dat`。
3. **批量导入接受无效平台。** 导入路径未使用单条添加的 HTTP(S)/占位符校验。现在过滤无名、无主机、非网页、无占位符与重复项；没有有效新项目时不创建空分组。首页推导保留端口。
4. **同名分组导入选错目标。** 界面把分组名称传给服务，名称重复时会选到第一组。现传递所选 UUID；目标已删除时不导入到其他位置。结果为 10、20 等数量时也不再因字符串中含 `0` 显示警告色。
5. **清理记录遗漏系统索引和首页缓存。** 历史列表/隐私设置通过基础服务删除记录时，没有清理已建立的 Spotlight 历史索引。删除成功后同步请求移除对应条目或域；清空书签也移除历史版本索引域。隐私设置清空历史后立即清空首页已缓存的关键词。
6. **恢复极端计数后搜索可能溢出。** 平台使用次数为 `Int.max` 时，搜索与存储各自的 `+= 1` 会崩溃。统一为饱和计数，负值先归零。普通计数行为保持一致。
7. **网址清理改变业务参数，历史还保留凭据。** 跟踪参数和历史规范化使用解码后的 query 重建 URL，使 `C%2B%2B` 变成原始 `C++`，部分服务器会把它理解成空格。改为仅解码参数名作筛选、保留原始编码值。历史同时移除用户名/密码；历史列表不再把路径及 query 的大小写差异合并。实时导航仍保留站点登录凭据与片段。已验证旧历史规范化及再次访问不会创建重复条目。
8. **云同步初始化使用错误的隐私默认值。** 四项隐私功能实际默认关闭，但同步引擎把开启当作出厂值，导致首次合并时将用户主动开启的值漏记、把未修改的关闭值记成编辑。改为引用实际 `PrivacyFeatureDefaults`，补充出厂值、主动开启与合并验证。
9. **搜索建议高亮导致输入崩溃。** 重启后系统拼音界面测试实际触发 `EXC_BREAKPOINT`；崩溃栈位于 `SearchAutocompleteView.buildHighlightedText`。该方法取小写副本的索引切片原文，Unicode 长度变化及字符串存储编码差异会使索引失效。现直接在原文上执行不区分大小写的查找，切片和范围来自同一字符串。补充中文、大小写、İ、组合字符、Emoji 及 NSString 桥接用例，并扫描了同类索引写法。原始崩溃报告 `Soulo-2026-10-29-203125.ips` 已保存在持久证据目录。

## 验证进度

### 重启后续验（2026-10-29）

- 已恢复此前任务记录，保留全部既有修改，版本仍为 1.2.6（51）。专用模拟器 `2D4AD1ED-8F8F-4AD3-B358-C0B425EE3633` 已成功启动，`simctl bootstatus` 确认启动完成；无需重启共享辅助进程。
- 重启前 `/tmp` 中的日志、结果包和独立验证脚本已不在，以下原记录保留为历史进度，不作为本轮重新执行的证据。
- 本轮持久证据目录：`/Users/shunfei.z/Library/Logs/Soulo/20261029-resume/`。已保存工作区差异、状态及 288 个源码/配置文件的 SHA-256 基线；`units.log` 和 `units.xcresult` 用于当前源码的全量单测。
- 本轮重新执行通过：本地化严格检查（881 key × 50 语言）、50 语言商店 JSON 一致性、5 项 Python 资源测试，以及 `git diff --check`。
- 首轮 `units.log` 使用了 `CODE_SIGNING_ALLOWED=NO`。新增 16 项回归全部通过，但 3 项分轨后台下载用例失败；随后主动停止（退出 143），不计为完整单测通过。系统 `nsurlsessiond` 日志明确记录 `Process with pid 13600 does not have a bundle ID, rejecting connection`；`codesign` 显示产物仅有 linker signature、`Info.plist=not bound`。已改用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 的模拟器签名构建重跑，结果另存 `units-signed.log` / `units-signed.xcresult`；不为首轮配置错误修改生产下载代码。
- 有效签名的全量结果 `units-signed.xcresult` 共 829 项：817 通过、9 跳过、3 失败，不能记为全量通过。失败分别为缩略图测试夹具竞争、实际视频时钟倍速断言，以及长时间未返回的缓存清理（采样后人为终止专用测试进程，结果为 signal kill）。保留原始失败包及 `units-signed-summary.json`。
- 倍速、缓存清理在新测试进程中的 `focused-before.xcresult`、`focused-fixed.xcresult`、`focused-rebooted.xcresult` 均通过。缓存等待期间，专用模拟器的 WebKit 网络进程采样停在 `NetworkStorageManager` 的空目录删除内核调用；网络进程重启没有恢复该回调，随后结束卡住的测试宿主，由 XCTest 恢复执行其余 157 项。日志及采样均保存在持久证据目录，不能把这次人为恢复算作缓存清理自然完成。
- 修正 `TabOverviewLifecycleTests` 的夹具：先切换模式，再通过生产串行队列保存预览；预览专用页面改用确定性的 `WKURLSchemeHandler`，避免与其它测试的网络会话清理互相影响。加载完成有明确断言，首次绘制仍要求在资源未加载完时保存截图。中间包的失败全部保留。
- **最终专项 `extension-verified.xcresult`：203 项，199 通过、4 跳过、0 失败。** 覆盖本轮全部 6 项新增插件用例、16 项功能审计用例、脚本依赖、安装包、原生加载、下载管理、后台恢复、网页脚本，以及完整标签生命周期测试。最终跳过项沿用原有显式开启规则；不把专项结果改写为全量 829 项通过。
- `release-final.xcresult`（插件修复）及 **`release-verified.xcresult`（同时包含搜索崩溃修复）均构建成功**，退出 0。后者对应当前生产源码。
- 关键界面首轮 `ui-critical.xcresult` 共 11 项：9 通过、2 失败。通过项为跨站确认、已声明/未声明目标、中间文档、POST 新标签、登录弹窗、可信域名设置、返回加载中的页面，以及 2 项网页保护。失败分别为上述已修复的真实搜索输入崩溃，以及下载夹具过早发送完毕。
- 旧下载截图 `ui-critical-all-attachments/107DD68A-87AF-41DD-B1AB-F260697A6E45.png` 已实际查看，显示原生播放器与 `Download complete`。56 KB 文件按原节奏在约 50 秒内发完，但界面操作到播放器时已约 90 秒，导致后续要求下载继续增长的断言无效。现仅为该界面用例配置较慢分块（128 字节/秒，Range 播放读取保持快速）；默认夹具行为不变，播放推进、传输继续及最终完成断言全部保留。
- `input-download-fixed.xcresult` 中 **7 项输入单测和视频下载界面通过**。拼音用例完成全部功能断言，但在恢复英文键盘的 teardown 动作中反复等待实站页面动画，超过 4 分钟执行上限；该包仍按失败保留。专用模拟器上移除此项多余键盘切换、保留 App 终止清理后，**`pinyin-verified.xcresult` 的系统拼音完整用例通过，0 失败**，包括真实候选词提交、清空、搜索和地址编辑器中的完整“中文”查询。最终关键界面 11 项均有通过证据，分布于上述结果包，不能把首轮失败包改写成成功。
- 最终源码指纹 `final-source-sha256.json`。本轮生产修改涉及脚本/扩展服务、原生兼容层、WebView 桥接、资源下载及搜索高亮；另外维护相关回归用例和夹具。保留重启前的全部修改，不提交或推送。

### 重启前记录

- 初次全量单测进程在构建开始前退出 137：`/tmp/soulo-full-app-audit-units-20261029.log`，没有用例结果，不计为通过。
- 原聚焦测试构建因后续发现并修复第 7、8 项而主动停止（退出 143）；未开始执行用例，不计为通过。当前测试包构建日志 `/tmp/soulo-full-app-audit-current-build-20261029.log`，结果包 `/tmp/soulo-full-app-audit-current-build-20261029.xcresult`。补充壁纸修复后，已安排其结束即自动执行最终增量 `build-for-testing`：日志 `/tmp/soulo-full-app-audit-final-build-20261029.log`、结果包 `/tmp/soulo-full-app-audit-final-build-20261029.xcresult`、退出码 `/tmp/soulo-full-app-audit-final-build-status.json`。这些命令只构建测试包，构建通过也不等于测试通过。
- 新增 `AppFunctionalAuditTests` 共 16 项，覆盖上述问题；尚待 iOS 测试运行环境恢复后执行。
- 独立编译实际生产搜索源码（模型、URL 工具、建议服务）的 Foundation 验证通过：特殊字符不改变路径/参数结构、JSON5 字符串解析、实际捕获的百度 GB18030 响应与饱和计数。脚本和日志 `/tmp/soulo-full-audit-pure-search.swift`、`/tmp/soulo-full-audit-pure-search.log`。这不替代 iOS 全应用测试。
- 提取生产壁纸四个调用的关键词编码与 URL 构造表达式，使用含 `C++`、`&`、`#`、中文及伪造额外参数的主题验证：四项由失败变为通过，参数数量与完整主题保持正确，未发出 API 请求。生成器 `/tmp/soulo-full-audit-wallpaper-check.py`；修复前后日志 `/tmp/soulo-full-audit-wallpaper-before.log`、`/tmp/soulo-full-audit-wallpaper-after.log`。
- 独立编译实际生产模型、历史/书签服务与 Spotlight 服务的 SwiftData 验证通过：单条删除、域清空、文件夹清空和保留无关数据；使用内存模型与索引替身，不写用户模型或系统索引。脚本和日志 `/tmp/soulo-full-audit-storage.swift`、`/tmp/soulo-full-audit-storage.log`。
- 平台导入独立验证通过：无效项过滤、空组保护、去重、首页端口、所选同名分组身份、目标已删除和计数边界。脚本 `/tmp/soulo-full-audit-platforms.swift` 使用生产源码，仅将 `UserDefaults.standard` 替换为隔离 suite，并替换显示名称翻译依赖；日志 `/tmp/soulo-full-audit-platforms.log`。
- 网址/云默认值独立验证由失败变为通过：直接提取生产规范化方法、隐私导航源码及同步默认值，验证历史去凭据且保留编码、实时去跟踪保留业务参数、同步默认值一致。复现前日志 `/tmp/soulo-full-audit-url-cloud-before.log`（3 项失败）、修复后 `/tmp/soulo-full-audit-url-cloud-after.log`（3 项通过）；生成器 `/tmp/soulo-full-audit-url-cloud-check.py`。这不代替完整云同步回归。
- 进一步独立编译完整生产 `CloudSettingsSyncEngine` 和 `CloudSettingsBackupStore`，验证出厂关闭值不产生编辑、主动开启生成四条记录、journal 编解码校验、合并保留开启、随后主动关闭、备份恢复与保留初始副本，全部通过。使用生产平台/分组模型及默认数据、生产订阅模型及默认数据、生产同步字段表，替换显示语言等运行依赖并使用临时备份目录；不连接真实 iCloud。生成器 `/tmp/soulo-full-audit-cloud-engine-check.py`、日志 `/tmp/soulo-full-audit-cloud-engine.log`。
- Python 资源检查回归 5 项通过，日志 `/tmp/soulo-full-app-audit-python-20261029.log`。
- 为全量回归新建隔离模拟器 `Soulo Full Audit 20261029`（`2D4AD1ED-8F8F-4AD3-B358-C0B425EE3633`），不清理用户设备的数据。
- 本地化严格检查：881 个 key × 50 种语言通过。
- 商店 JSON：50 个语言目录与生成 JSON 一致。
- `git diff --check` 通过。

## 重启前 iOS 运行环境诊断（历史记录）

- 新隔离设备两次启动失败，原有 Soulo 测试设备的对照启动也失败，均为 `NSPOSIXErrorDomain Code=60`、`launchd_sim` 无法绑定会话。均发生在安装/运行当前 App 之前，不能记为 App 用例失败或通过。日志：`/tmp/soulo-full-app-audit-boot-20261029.log`、`/tmp/soulo-full-app-audit-existing-simulator-boot.log`。
- 已核对 CoreSimulator 版本 `1051.17.7` 与 Xcode 的包装工具预期一致；两个系统临时目录权限均为 `1777`；进程数 1,246 低于每用户上限 5,333，文件句柄 16,466 低于上限 245,760。不是基于报错直接重装工程或清理用户设备。
- [Apple 开发工具工程师对同类启动故障的说明](https://developer.apple.com/forums/thread/807025)涉及运行时加载、权限和安全扫描等不同原因。当前定向安全日志查询没有匹配，不能据此确认或排除某一具体原因。
- 从 Simulator 的设备菜单启动新设备后，只有 External Display 窗口，没有进入 iPhone 主界面；未把创建窗口当作成功启动。
- 当前还有两台其它项目的 StockClaw 模拟器运行。重启公共启动辅助进程可能中断其连接，因此已请求用户确认，未取得回答前不重启该公共进程。
- 原 Release 构建因补充壁纸编码修复而中断（退出 75），不计为构建通过。最终代码的 Release 构建日志 `/tmp/soulo-full-app-audit-final-release-20261029.log`，尚无完成结果。最终源码指纹 `/tmp/soulo-full-audit-source-sha256.json`，共 284 个源文件及工程配置；记录后源码未再改动。
- 19:12 读取的主机负载为 `598.44 / 506.87 / 466.79`，swap 已使用约 13.6 GiB。编译进程仍在累计 CPU 时间，但用时明显增加；仅作为耗时环境记录，不据此推断模拟器故障根因。

## 插件系统续检与完善（2026-10-29）

用户补充要求继续检查生产代码缺陷，并判断插件系统是否完善。本轮同时检查 UserScript 与 iOS 原生 WebExtension；结论是基础流程已经具备，但还不能视为完整 Tampermonkey / Chrome / Firefox 扩展环境。

### 本轮新增修复

1. **下载取消没有停止原生下载。** `GM_download.abort()` 原先只设置 JavaScript 标志，`GM.download()` 的 Promise 还缺少取消方法。现以脚本 ID + 请求 ID 跟踪原生下载，取消会更新下载状态、终止传输；即时取消也覆盖原生任务创建前的窗口。请求键保留到动作结束，避免取消后复用相同键串到另一下载。成功、失败与取消只完成一次。
2. **相对资源地址请求了当前网页。** `@resource assets/style.css` 原先按访问页面解析。现在按安装脚本的来源解析；没有来源时拒绝相对地址。继续核对原有 `@connect` 和本地地址限制，不扩大网络授权。
3. **错误页面被当作资源正文。** 原资源调用会把 HTTP 404 等页面作为 CSS/资源内容交给脚本。资源接口现在拒绝非成功响应；普通 XHR 仍可读取 HTTP 错误状态与正文。
4. **原生回调失败被当作成功。** 兼容层没有在回调期间读取 `runtime.lastError`。以实际生产兼容脚本在 JavaScriptCore 复现：修复前得到 `{rejected:false,value:"soulo"}`，修复后得到 `{rejected:true,value:"Permission denied"}`。对应持久日志为 `native-callback-before.log` / `native-callback-after.log`。
5. **系统拒绝通知后仍返回创建成功。** 宿主现返回明确错误，结合第 4 项正确传播给扩展；不会把未获得授权的通知描述为已创建。
6. **查询通知遗漏已显示项。** `notifications.getAll()` 原先只读取待发送队列，现合并待发送及已显示项，并按扩展前缀隔离、按 ID 去重，避免重复 ID 触发字典构建崩溃。

新增用例位于 `ExtensionAuditTests`，覆盖现代下载 Promise、原生取消消息、即时取消与请求隔离、取消后不创建传输、相对资源来源/权限、HTTP 错误资源拒绝，以及原生回调错误传播。通知系统授权拒绝及已显示通知查询完成了代码修正和构建检查；本轮没有为实测发送系统通知或弹出通知授权提示，不把桥接替身用例写成系统通知实机验收。

### 上一轮记录的完善项

以下为续改前状态；本轮实现和验证见后文「插件管理续改」。

| 优先级 | 项目 | 当前实际边界 |
| --- | --- | --- |
| 高 | 安装权限明细与逐站管理 | 原生扩展加载时授予 manifest 请求权限；尚缺完整的权限预览、逐站撤销与管理界面。动态新增授权已有提示。 |
| 高 | 原生扩展升级与身份保持 | 原生包安装采用新 UUID，尚无保留身份、存储和回滚副本的升级流程。UserScript 已有重装识别与存储保留，但没有自动检查更新。 |
| 高 | 兼容能力诊断 | 仍有按字符串替换部分第三方 JS 调用的历史兼容措施；可能影响字面量，需用能力注入或语法级方案替代，并增加真实扩展样本验收。当前不能把“安装成功”视为全部功能可用。 |
| 中 | UserScript 存储跨标签一致性 | 同步读取来自当前页面快照，变化监听限当前页面；需增加跨标签广播、写入确认及远端变化通知。 |
| 中 | 生命周期与错误可见性 | 有安装/依赖/启用错误，但缺少集中运行日志、每脚本执行错误、兼容 API 清单与版本化诊断。 |
| 中 | 资源缓存和完整标准语义 | `@require` 已离线缓存；`@resource` 仍按声明和 `@connect` 在线读取，接口是 Promise，尚非 Tampermonkey 的完整同步资源语义。 |
| 平台边界 | 运行环境 | UserScript 限 HTTP(S) 主框架；不提供完整脚本沙箱、iframe 注入或全部 run-at 行为。原生扩展需 iOS 18.4+，offscreen DOM、桌面命令、多窗口和完整通知事件不能当作已实现。 |

优先完善权限、升级/回滚和兼容诊断，再扩大 API 数量。新增 API 应有明确能力判断与错误结果，避免只提供同名空实现。

参考约定：[Tampermonkey 下载接口及取消句柄](https://www.tampermonkey.net/documentation.php?locale=en#api:GM_download)、[Chrome runtime.lastError 的回调作用域](https://developer.chrome.com/docs/extensions/reference/api/runtime#property-lastError)、[WebExtensions 当前活动通知查询](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/notifications/getAll)。

## 插件管理续改（2026-10-29）

本轮响应「继续完善」，保留现有工作区和版本号，完成以下代码改造：

- **权限选择与逐站管理：** 文件、商店链接、网页下载包三个原生扩展入口统一进入安装预览；按权限和网站选择后安装。已安装项增加管理入口，可撤销权限、设置网站规则和禁止域名（含子域）。授权、拒绝、到期时间与动态授权变化保存到本地；重新启用及启动恢复沿用选择。阻止名单也约束后续动态授权。没有可展示的权限提示界面时拒绝本次请求，但不将其冒充用户永久拒绝。
- **身份与版本恢复：** 按商店、Gecko ID、公钥或来源识别更新；管理页支持明确指定目标的文件更新。同一扩展保持 UUID、安装时间、启用状态和稳定资源 origin，保留上一版资源。新版本加载或持久化失败时恢复旧版；恢复上一版同样经过权限预览。过期的版本预览、权限已变更的预览和并行替换不能覆盖较新的状态。修复版本目录在下次启动被再次迁移的问题。没有可识别身份的本地包通过管理页更新，避免按同名合并不同扩展。
- **跨标签存储：** GM 单值和批量写入、删除均在原子保存成功后广播完整快照，使用脚本 ID、修订号、来源标签和操作 ID 合并。保留未确认的本地写入，忽略过期快照，远端回调标记 `remote=true`。更新保留页面的后续注入快照并维持原有注入顺序；页面执行时另取一次最新快照。写盘失败恢复内存值且不广播成功。
- **兼容性和错误：** 删除按字符串改写第三方 JS 的历史实现，通过独立兼容脚本保护不支持的桌面命令注册；管理页和安装页展示已知能力限制和 WebKit 错误。UserScript 的同步执行错误及可归属脚本的异步错误回传到脚本列表；保存修正后清除旧错误。原生兼容 API 同时检查声明和当前许可，不能仅凭 manifest 继续使用已撤销的能力。
- **写盘失败保护：** 续查发现脚本保存、脚本/原生扩展开关及删除会吞掉持久化错误。现先原子保存，失败恢复原状态并显示错误，成功后才取消依赖任务、清除脚本错误或删除原生资源，避免失败时界面仍显示成功或丢失内存状态。
- 新增 9 个界面键，完成全部 50 种语言和别名目录翻译。工程按 `project.yml` 重新生成。未修改版本或本轮 App Store 文案。

验证记录保存在 `/Users/shunfei.z/Library/Logs/Soulo/20261029-extension-enhance/`。`ExtensionManagementTests` 覆盖预览取消、权限过期预览、身份和存储保留、版本恢复、写盘故障恢复、动态权限和网站禁止、跨标签真实 WebView、运行错误以及中英文管理页截图。

- 独立提取实际生产模型、存储运行时和兼容脚本，在 macOS Swift / JavaScriptCore 执行检查，最终 **16 项通过**（`portable-checks-final.log`），含乱序确认、远端回调和第三方能力注入；它不代替 iOS 原生集成验证。
- 首次 iOS 运行 `management-initial` 卡在 CoreSimulator 启动应用阶段，无用例开始；保留采样 `test-launch-sample.txt` 和原始日志，终止该次运行并仅恢复专用模拟器，未把它计作通过。
- `extension-complete.xcresult`：**144 项，140 通过、4 跳过、0 失败**。13 项新管理回归全部通过；真实跨标签用例验证写入、删除、重新加载及脚本报错。`regression-final.xcresult` 中另有 16 项全应用审查、63 项浏览回归（2 跳过）通过；该包仍按整包失败保留，因为其中发现诊断正文遗漏和历史替换断言尚待调整，不能改称整包通过。
- 初轮 `management-verified.xcresult` 为 11 项、8 通过、3 失败：修正夹具缺少准备目录、轮询误用 `XCTUnwrap` 和普通 WKWebView 缺少原生导航标记的问题。后续 `management-final.xcresult` 的 12/13 项通过；剩余失败进一步定位为 Safari / JavaScriptCore 的 `Error.stack` 不含错误正文。现总是保留 `error.message` 并附加调用栈；`error-stack-before.log` 留存修复前重现。旧测试改为验证第三方源码保留以及兼容注入后的实际执行。
- 中英文安装、管理页截图已从结果包导出并逐张查看，位于 `screenshots/`。Debug 测试构建通过；Release 曾在本轮代码状态成功（`release-final.log`），随后错误正文修复及性能优化的最终生产源码也已重新构建成功，见性能证据目录的 `release-current.log`。另保留一次 Xcode 构建数据库锁冲突和主动中止的旧构建记录，均不计测试通过。
- 用户追加的速度、内存、耗能与空间检查已完成本轮改造和验证，见 [资源效率报告](2026-10-29-resource-efficiency.md)。相关 355 个不同用例有 349 项通过证据、6 项跳过，通过证据包含两项夹具修正后的 16 项重测；没有把原失败包改写为通过。版本号保持不变。

仍保留的明确边界：不自动轮询或后台升级第三方包；不提供完整 offscreen DOM、桌面快捷键和通知点击/关闭事件；资源接口仍是现有 Promise 语义，UserScript 仍限 HTTP(S) 主框架。保存上一版代码不等同于撤销第三方自身的数据迁移，当前也没有集中导出完整运行日志或全部商店真实扩展的验收矩阵。

## 设计待确认

跨站确认开关 `ad_block_confirm_cross_domain` 和可信域名 `ad_block_cross_domain_allowlist` 尚未列入云同步/备份字段。已询问是否应与其它隐私设置一起同步；未确认前保持当前仅本机的范围。若增加同步，还需同步刷新 `BrowserDomainAllowlist` 的已发布界面状态，并补充备份/合并回归。

## 仍需独立设备条件的验证

真实 iCloud 多设备同步、相机/麦克风/语音的系统授权组合、后台长时下载、AirPlay/画中画、第三方 App 的分享宿主和各网站实时登录状态，不能用纯模拟器单测代替。
