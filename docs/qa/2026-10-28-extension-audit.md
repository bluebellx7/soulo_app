# 扩展完整检查记录（2026-10-28）

覆盖 UserScript、原生 WebExtension、商店下载、ZIP/XPI/CRX 解包、页面注入、权限、GM 接口、存储、标签页、启停与卸载。保留此前反馈 #37 的 `@require` 修复；本次不更改版本或商店元数据。

## 本轮发现与修复

| 范围 | 原有问题 | 修复与验证 |
| --- | --- | --- |
| 隐私模式 | 原生扩展的网页配置排除了隐私模式，但原生窗口模型仍枚举私密标签。 | 隐私模式隐藏标签列表和活动标签，不注册私密 WebView，不在隐私模式执行扩展动作或创建扩展标签；消息桥同时核对主框架、网页存储类型与隐私状态。 |
| UserScript 运行范围 | `@include *` 等通配规则也匹配 `webkit-extension://`、`file://`、`about:`、`data:`。 | Swift 匹配和 JavaScript 执行两端均限定 HTTP/HTTPS 页面；回归同时验证普通网页继续执行。 |
| 现代网络接口 | `GM.xmlHttpRequest` 返回普通句柄，`await` 得不到响应；`abort()` 只丢弃回调，原生请求仍运行。 | 返回带 `abort()` 的响应 Promise，原生按脚本与请求 ID 取消任务，页面导航与运行时拆卸也清理任务；保留传统回调式接口。 |
| 网络范围 | `GM_download` 仅检查首个 URL，随后走自动重定向的后台会话；部分 IPv4 简写、整数、IPv6 映射和 `.localhost` 地址绕过本地地址判断。 | 下载记录持久化权限范围，受限下载及恢复使用可逐跳审核的会话，并校验最终地址；识别本地地址别名。 |
| 存储 | 原生拒绝单项或批量写入后，页面缓存仍保留新值；简单回滚还可能覆盖后来成功的写入。 | 保留同步接口的即时读取行为，按顺序维护待确认变更，失败时移除对应变更，后续成功写入继续保留。 |
| 特殊键 | 将缓存直接嵌入 JavaScript 对象字面量时，`__proto__` 被当作原型设置，无法正常读取。 | 通过 JSON 解析并使用无原型字典保存缓存、资源名和批量结果；拒绝缺少 `value` 的存储包装。 |
| 脚本作用域与信息 | 内部 `request`、`base64Blob` 与正常脚本的同名 `const` 冲突；`GM_info.version` 使用陈旧常量。 | 内部辅助函数统一使用 `__soulo` 前缀，版本从实际应用 Bundle 读取。 |
| 临时标签数据 | 标签关闭、隐私重置或脚本卸载后，GM Tab 数据仍留在全局字典；对象地址可能被后来标签复用。 | 改用稳定 UUID，关闭、释放与卸载时清理相应数据，同时限制每脚本的临时数据总量。 |
| 后台入口 | 在扩展根目录包装 `background/worker.js`，使经典 worker 内部相对 `importScripts()` 指向错误目录。 | 包装器与原入口放在同一目录；支持旧包装器恢复原入口和重复升级，模块 worker 使用相应相对导入。 |
| 包内资源 | Manifest 的 `../` 页面路径可让兼容层改写包外 HTML；目录包的符号链接也可指向外部文件。页面带查询或片段时又可能漏注入。 | 检查资源树和规范化后的路径，拒绝越界与符号链接，按实际文件路径处理查询和片段。原路径越界已在修复前实际复现。 |
| 原生消息 | 兼容层遇到只通过回调回复的 `sendNativeMessage` 时，Promise 提前返回空结果。 | Promise 等待真实回调，兼容回调和 Promise 两种宿主，并防止重复完成。 |
| 原生宿主权限 | 已获 nativeMessaging 的扩展可直接调用宿主的通知或音频接口，宿主未核对 notifications/offscreen 权限。 | 宿主核对必需权限声明或有效的动态授权，缺少权限时返回明确错误；拒绝路径不触发通知授权或音频播放。 |
| 原生加载 | 并发启用可创建同 ID 的多个上下文；加载中卸载缺少取消；启动恢复后已有网页未统一刷新。 | 合并同 ID 的加载任务，卸载取消未完成任务，恢复时反馈加载状态，并在成功后通知已打开网页更新。 |
| 商店包大小 | 100 MiB 限制仅在完整下载后检查，超大响应已消耗网络和磁盘。 | 在下载进度中检测声明长度和实际大小，超限立即取消，并保留明确的大小错误；失败路径清理临时文件。 |

## 验证记录

- 修复后的首轮专项：28 项通过，包含真实 iOS WKWebView 中的 `@require`、存储与扩展生命周期验证。
- 当前制品已通过 `xcodebuild build-for-testing`，工程按项目方式由 `xcodegen generate` 生成。
- 最终回归选择记录：`/tmp/soulo-extension-verified-selection.txt`；结果包：`/tmp/soulo-extension-verified-tests.xcresult`。
- 最终同一轮回归共 **162 项、0 失败**：WebView 预热与隐私 11 项、下载管理 35 项、安装包格式 3 项、本轮专项 19 项、扩展生命周期 2 项、文件相关 2 项、标签生命周期 23 项、`@require` 14 项、导航与安装识别 25 项、脚本菜单 1 项、原有脚本/原生扩展 27 项。包含真实 iOS WKWebView 与 WebExtension 加载。
- 包格式测试覆盖 ZIP、XPI、CRX2、CRX3，及 CRC 损坏、加密、截断、路径越界和超大解包声明。
- `python3 scripts/check_localization.py --strict`、`python3 scripts/export_metadata_json.py --check`、`git diff --check` 已通过。
- 扩大检查时，原有后台视频双轨下载测试 `BackgroundDownloadRecoveryTests/testBackgroundTracksDownloadPauseResumeAndMerge` 遇到 `nsurlsessiond` 连接错误。以 HEAD `725dfaa` 的干净工作树、同一 SDK、同一模拟器及相同构建参数单独对照，得到相同失败；该测试的媒体合并代码不在本次修改范围内。基线结果包：`/tmp/soulo-extension-head-test.xcresult`，日志：`/tmp/soulo-extension-head-test.log`。
- 上述背景视频测试仍为独立未解决测试项，不计入 162 项通过结果；不能用本次扩展检查声称全部后台视频下载场景已通过。
- 通配范围收紧后，原来在空白 WKWebView 运行的测试夹具需加载真实 HTTP/HTTPS 文档。夹具等待唯一 DOM 标记、页面协议和文档完成状态，保留生产代码对内部/本地页面的拒绝规则；不以放宽运行范围换取通过。

## 仍需遵守的兼容边界

- 不保证所有 Tampermonkey、Chrome 或 Firefox 扩展兼容。UserScript 仅在普通 HTTP/HTTPS 主框架运行，支持 document-start/end；不提供完整沙箱或 run-in 行为。
- `@updateURL`、`@downloadURL` 用于识别重新安装，尚无自动更新服务。`@require` 不支持 `tampermonkey://` 内置库。
- GM 值变化监听仍限当前页面；同步存储读取基于当前页面快照，跨标签同步需重新加载。资源接口为异步调用；GM_webRequest、GM_audio 等原有未支持能力保持明确边界。
- 原生 WebExtension 依赖 iOS 18.4 以上及 WebKit 支持的 Manifest/API。通知事件、桌面命令、offscreen 的完整 DOM 环境、多窗口等不能视为桌面浏览器的完整等价实现。

## 参考

- [Tampermonkey：网络 API 的 Promise 和 abort 约定](https://www.tampermonkey.net/documentation.php?q=GM_xmlhttpRequest)
- [Worker importScripts 相对 worker 入口 URL 解析](https://developer.mozilla.org/en-US/docs/Web/API/WorkerGlobalScope/importScripts)
