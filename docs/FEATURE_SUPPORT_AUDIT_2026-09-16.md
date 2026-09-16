# Soulo 功能支持核对（2026-09-16）

依据当前工作区代码与定向测试。版本 1.1.6（24）。这里的“支持”指已有实现与入口，不代表所有网站、编码、DRM 内容或第三方服务均兼容；需要真机/外设的项目单独注明。没有将清单里缺少的功能自动列入本次开发范围。

## 音视频

| 功能 | 当前情况 | 说明 |
| --- | --- | --- |
| App 内悬浮/小窗 | 支持 | 共享播放会话，离开播放器后显示可拖动、贴边的小播放器。 |
| 切到其他 App 后悬浮视频 | 真机基础流程通过 | iPhone 17 实测手动进入 PiP，在主屏幕及系统设置上方持续显示动态视频，退出 PiP 后恢复原生播放画面。自动进入、锁屏和更多媒体兼容性仍待测。 |
| 0.5–16 倍速 | 有条件支持 | 预设及 0.1 调节；高于 2 倍要求媒体支持快速播放。网页跨域播放器可能限制修改。 |
| 后台播放 | 真机播放状态基础验证通过 | M4A 切后台 30 秒后进度从 5 秒推进到 38 秒；主动暂停后切后台仍停在 39.227 秒。实际听音、锁屏、远程控制和网页媒体仍待验收。 |
| AirPlay | 真机输出切换通过，接收端播放待确认 | 实测发现并选中 MacBook Pro，再切回 iPhone 扬声器；未取得接收端实际音视频证据，不视为完整投屏验收。 |
| DLNA | 不支持 | 未发现 SSDP/UPnP/DLNA 投屏实现。 |
| 单曲循环 | 支持 | 当前播放项结束后重新播放。 |
| 画中画 | 已实现并补强入口 | App 内小窗与系统跨 App 画中画是两个不同层级。 |
| 视频截图 | 支持 | 播放器菜单提取当前视频帧，经系统分享面板保存或分享；受保护内容及无法提帧的流媒体会返回错误。 |
| 视频镜像 | 支持本地显示 | 播放器菜单切换，App 内普通/全屏/小窗与截图使用镜像；不改写视频文件，不承诺外部 AirPlay / 系统 PiP 的镜像效果。 |
| 长按倍速控制 | 支持原生播放器 | 正在播放的视频长按临时 2×，释放/取消/退出/切后台恢复；原速度 ≥2× 不降速，不更改保存的倍速。网页自己的播放器不注入此手势。 |

主要实现：`MediaSession.swift`、`MediaPlayerView.swift`、`MediaPictureInPicture.swift`、`WebMediaPlaybackBridge.swift`。

## 文件管理

| 功能 | 当前情况 | 说明 |
| --- | --- | --- |
| 手动下载 | 支持链接触发 | 网页、资源嗅探、URL Scheme 可发起；没有独立粘贴下载地址的新建任务表单。 |
| ZIP / RAR / 7z 解压 | 支持，含密码 | RAR 多分卷不支持；不能承诺各工具所有专有变体。 |
| ZIP / 7z 压缩 | 支持，含密码 | ZIP AES；7z 内容及文件头加密。 |
| RAR 压缩 | 不支持 | 解压支持不等于可以创建。 |
| 文件新建/编辑 | 不支持通用编辑 | 重命名已支持；文本预览只读。 |
| 纯文本打开 | 支持 | 文件列表/网格长按菜单“文本打开”；只读，16 MB 限制，二进制内容明确报错。 |
| 编码选择 | 支持 TXT 与文本预览 | 自动、UTF-8、UTF-16/LE/BE、UTF-32、GB18030、Big5、Shift-JIS、Windows-1252、ISO-8859-1；自动优先 BOM，指定失败不回退。 |
| 相册导入到文件 | 已实现 | 导入图标菜单打开系统照片选择器，可选照片/视频；复制导入，避免覆盖同名文件，不请求整库访问。 |
| 文件移动/复制 | 不支持 App 内通用操作 | 导入会复制文件；没有文件管理移动/复制目标目录操作。可使用系统“文件”管理共享目录。 |
| Wi-Fi 传输 | 支持 | 本地网络、配对码与前台传输服务。 |
| 文件重命名、列表/封面网格 | 支持 | 已有入口与预览。 |
| 系统 Files / Finder / iTunes 共享 | 已配置支持 | UIFileSharingEnabled、LSSupportsOpeningDocumentsInPlace；最低 iOS 17，不支持在 iOS 11 上安装。 |

主要实现：`ArchiveService.swift`、`LibraryToolsView.swift`、`FilePresentation.swift`、`DownloadManagerView.swift`、`WiFiTransferView.swift`、`project.yml`。

## 电子书

| 格式/功能 | 当前情况 |
| --- | --- |
| TXT、PDF、EPUB | 支持；受保护、损坏或超大文件有边界限制。 |
| MOBI、AZW、AZW3、PRC | 识别无 DRM MOBI/KF8 或 PalmDoc 实际内容；后缀被接受不代表所有 Kindle 文件都能解码。 |
| AZW4、PDB | 部分支持：按实际容器签名判定，不能把整个格式家族视为完整支持。 |
| Kindle | 不是单一格式；以上格式有限兼容，DRM 与 KFX 不支持。 |
| 简繁体转换 | TXT / EPUB 等流式正文支持显示转换；阅读外观中选择原文/简体/繁体，不更改源文件，跳过代码和样式，PDF 不适用。 |

主要实现：`BookLibrary.swift`（实际内容探测、DRM 检查）、`BookReaderView.swift`、内置阅读引擎。电子书导入有 128 MB 边界。

## 网页、扩展和系统集成

| 功能 | 当前情况 | 说明 |
| --- | --- | --- |
| 自定义 JavaScript | 支持 | 脚本导入/编辑/开关/运行、匹配规则及多种 GM API；不声称完全兼容所有油猴脚本。 |
| 每站广告拦截 | 支持 | 站点例外、过滤开关与手动标记规则。 |
| 每站视频悬浮偏好 | 不支持独立持久设置 | 可以开启播放器，不等于按站记忆自动悬浮。 |
| 每站无图模式 | 不支持独立设置 | 未发现完整的按域名图片阻断配置。 |
| 每站剪贴板访问开关 | 不支持独立面板 | 系统授权和脚本权限校验仍生效。 |
| 每站 JS | 部分支持 | 用户脚本有 @match/@exclude；没有按网站禁用网页全部 JavaScript 的总开关。 |
| iPad 分屏 | 配置与布局支持，待专门验收 | 支持 iPad、多方向和多场景；没有禁用系统分屏。不能宣称已对所有分屏尺寸完成验收。 |
| iPad 跨 App 拖拽文件 | 已实现，跨 App 手势待 iPad 验收 | 文件列表/网格提供文件拖出，页面接收拖入后复制；导入临时文件在提供方回调内暂存，拒绝目录/符号链接，同名不覆盖。 |
| BigBang 分词选择 | 不支持 | 普通文本选取和 OCR 不等价。 |
| Handoff | 已实现，待跨设备验收 | 当前活动网页发布 NSUserActivity，并接收 Soulo 接力；隐私模式、本地文件/IP、本地域名与带账户信息的 URL 不发布。不启用 Spotlight/公开索引。 |
| 1Password / LastPass | 系统 AutoFill 路径可用，第三方真机待测 | 使用 WKWebView 原生表单与键盘；不自行读取密码库。用户在 iOS 自动填充设置启用提供方。 |
| Avast Passwords | 旧产品已停止支持 | 应改为评估当前 Avast Password Manager 的 iOS AutoFill；不能继续承诺旧产品兼容。 |
| 查看源码 | 无内置工具入口 | 可自定义脚本查看 DOM，但不等于网络原始响应源码查看器。 |
| Eruda / vConsole | 无内置工具 | 可通过用户脚本自行接入，受网站 CSP、网络等限制。 |
| Cookie 管理 | 部分支持 | 脚本 GM_cookie / GM.cookie 提供授权后的读写删除；没有可视化 Cookie 管理器。 |

密码管理器主要走系统集成，而不是分别安装 1Password/LastPass 的私有 SDK。网页应提供标准 username/current-password/new-password/one-time-code 标记。Soulo 应保留 WebKit 原生输入与 AutoFill 菜单，避免为读取密码做 JS 注入。

参考：[Apple HTML AutoFill](https://developer.apple.com/documentation/security/enabling-password-autofill-on-an-html-input-element)、[1Password iOS AutoFill](https://support.1password.com/ios-autofill/)、[LastPass AutoFill](https://www.lastpass.com/features/autofill)、[Avast 旧版 Passwords 状态](https://support.avast.com/en-us/article/use-mobile-passwords)、[Avast Password Manager](https://apps.apple.com/us/app/avast-password-manager/id6738665730)。

## 本次修改与验收记录

- 连接安全展开区概括为一行，保留证书入口及完整 URL 复制。
- 下拉刷新改为灰色细环，保留系统手势和请求生命周期；无常驻计时器。
- 资源嗅探图片增加多选/全选/批量保存、取消、逐张失败统计。
- 相册导入按图片字节确定格式和文件后缀；遇到 PhotoKit invalidResource 才转换静态 PNG 或动画 GIF 再试。原格式可接受时保留原图。
- 支持邮箱移到反馈提交按钮下方，保留邮件链接与复制。
- 灵动岛紧凑态改为短标识，长网址仅留在展开态。
- 原生播放器新增直接画中画入口，统一文件、下载、资源预览的播放器能力。

图片报错 3302 是 PhotoKit 的资源校验失败，不能仅凭错误码断定某一张图的具体原因；不支持的编码、内容与后缀不匹配或无效响应均需排查。参考 [Apple invalidResource](https://developer.apple.com/documentation/photos/phphotoserror-swift.struct/code/invalidresource)。

### 已完成的定向验证

- `PhotoImportPreparationTests` 4 项、`WebImageBatchSaverTests` 3 项全部通过：错误后缀纠正且保留原始字节、拒绝 HTML、静态图尺寸与透明通道、动画帧与时序、去重串行、失败继续、拒绝权限与取消。
- iPhone 17 Pro / iOS 26.2 独立模拟器：普通 WebP、动画 WebP、PNG 内容配 JPG 后缀的 3 张资源批量保存，实际相册导入 3 成功 / 0 失败。
- 同一浏览器页面下拉刷新后计数从 1 到 2，加载指示消失；继续通过 Scheme 打开另一页面成功，避免复用 NavigationStack 时只改搜索状态却没有加载的问题。
- 原生密码输入框可弹出“自动填充”和 Passwords 入口；没有第三方密码账户，因此不把此结果表述为 1Password / LastPass / Avast 真机登录成功。
- 反馈页支持邮箱的纵向位置位于提交按钮之后。
- 全部 50 种语言的严格本地化检查与 App Store 元数据一致性检查通过。本次没有修改版本或商店文案。

- 系统画中画：在独立模拟器运行进程中用 LLDB 调用公开 API，`AVPictureInPictureController.isPictureInPictureSupported()` 实际返回 `NO`。因此不把模拟器上的入口检查当作跨 App 悬浮播放成功；不支持的设备隐藏入口。真机仍需验收手动开启、自动切后台、关闭/恢复及全屏切换。

- 最后回归共 10 项通过，另含播放速度范围/共享会话替换、实际视频播放与拖动恢复、App 内悬浮播放器导航保持。没有进行全应用的无遗漏验收，也没有把 AirPlay、第三方密码管理器或真机 PiP 写成已验证。
- 界面证据：`docs/qa/2026-09-16-media-images/`。测试日志：`/tmp/soulo-final-regression.log`；已通过的相册/刷新/AutoFill 界面用例在 `/tmp/soulo-current-ui3.xcresult`（其中 PiP 用例受模拟器能力限制未通过，另行检查系统支持状态）。

- 全屏进入/退出的界面检查通过，退出后播放继续；跨 App PiP 用例按系统能力跳过（不是通过）。记录：`/tmp/soulo-video-final-ui.xcresult`。


## 本轮补齐（2026-09-16）

详细任务与验收见 `FEATURE_IMPLEMENTATION_PLAN_2026-09-16.md`。
- 音频中断只在系统允许且用户未暂停/换片时恢复，耳机拔出仍暂停。
- 新增编码、导入、Handoff 隐私规则和临时倍速定向测试。
- TXT 实际 WebKit 阅读器验证简体→繁体→原文；EPUB 验证正文转换、代码不变及书内脚本仍被隔离。
- 阅读/压缩/媒体原有 25 项回归通过。
- 密码管理器沿用原生 AutoFill，不获取密码库，不改写网站登录表单；第三方账户需真机验收。

- 进一步修复主播放器与小窗在页面切换时争用视频图层的黑屏，并以模拟器实际像素检查首次显示/镜像/全屏返回。
- 本轮 34 项定向/回归测试分批通过；文件/相册/编码/播放器界面链路通过。证据见 `qa/2026-09-16-incremental-features/`。
