# 百度视频搜索卡片跳转与旧播放器清理

## 本轮定位：Cookie 识别复制了播放器

从零处理逐项恢复后，定位到 `WebViewScripts.privacyProtection` 的 Cookie 弹窗识别：为排除导航链接而对浮层执行 `cloneNode(true)`，连带复制了播放器。复制体的运行时静音状态没有保留，可以在不属于页面 DOM 的情况下自动播放。检查 DOM 内的视频、清理已跟踪媒体都看不到这个副本。

- 最小复现 `/tmp/soulo-consent-media-clone-reproduction.xcresult` **按预期失败**：原视频 `muted=true, paused=true, time=4.154`；离屏副本 `connected=false, muted=false, paused=false, readyState=4, time=4.985`。
- 改为 `TreeWalker` 只读现有文本，跳过链接、导航、脚本及媒体等子树，不再创建任何克隆节点；保留原先 Cookie 文案识别及拒绝/隐藏行为。
- 修复后同一最小复现无复制体；`/tmp/soulo-consent-media-clone-fixed.xcresult` 的复现、脚本导出及隐私配置检查共 **4 项通过**。
- 真实百度对照使用额外只读诊断：包装原 `cloneNode` 并仅保存 `WeakRef`，不保留播放器、不调用播放/暂停/静音。旧脚本的画面、来源入口都观测到多个离屏副本，且暂停 DOM 视频后仍有 `muted=false, paused=false, readyState=4` 的副本；原生播放状态甚至可为 paused，证明该状态也不能覆盖全部音源。修复脚本的两个入口，从搜索预览到详情及声音/暂停操作的全部采样均为 **0 个媒体复制体**，详情实际暂停，原生为 paused。结果包 `/tmp/soulo-baidu-clone-causal-comparison.xcresult`，4 个旧/新脚本入口样本全部采集完成。
- 其中旧脚本的来源入口：可见视频 `muted=true, paused=true, time=12.75`，同时离屏副本 `muted=false, paused=false, time=3.36`；修复后相同入口暂停为 `time=9.95`、没有复制体。完整弱引用采样和观察 `/tmp/soulo-browser-baseline/clone-causal-results/`。
- 完整 Soulo 在明确开启 `privacy_cookie_banner_enabled=YES` 后，真实标题、画面点击和声音/暂停控件通过；同包的隐藏播放器复现、Cookie 拒绝/遮罩、账号菜单、协议弹窗和脚本语法检查通过，共 **9 项、0 失败、0 跳过**。结果包 `/tmp/soulo-consent-ghost-final-validation.xcresult`。此前实站界面启动参数没有明确开启 Cookie 处理，现已补齐这个触发条件。
- 文本拼接保持原 `textContent` 语义，另扩展账号菜单/Cookie 回归，覆盖 `coo<b>kies</b>` 这种标签拆词，避免引入识别回归。最终拼接版本的上述 7 项行为/语法回归再次全部通过，结果包 `/tmp/soulo-consent-ghost-text-final.xcresult`。
- 最终 Debug 构建保持 1.2.5 (51)，已安装到原 Soulo 模拟器及连接的 iPhone，保留应用数据。真机安装回执 `/tmp/soulo-consent-ghost-final-device-installed.json`；本轮没有把安装成功当作真机声音验收。临时对照应用采样保存后移除，源码保留供复现。
- 本地化严格检查 881 keys × 50 locales、50 语言元数据一致性及 `git diff --check` 均通过，未修改版本或商店文案。

前几轮状态验证漏掉了离屏副本，不能将其测试通过作为此问题已解决的证据。音频输出未录制；上述复现直接检查到了非静音、已解码且时间推进的隐藏媒体对象。

## 零处理与逐项对照过程

用户再次反馈未解决后，先停止叠加播放补丁，建立零处理对照，再逐项恢复功能；由此发现上面的独立根因。

新增 `scripts/diagnostics/RawBrowserBaseline.swift` 及构建器 `build_raw_browser_baseline.py`，构建独立 UIKit + WKWebView 应用，不链接 Soulo。`system` 使用系统默认配置；`-sampling NO` 连只读 JavaScript 采样也关闭，没有用户脚本、内容过滤、URL 改写、媒体挂起/释放或播放接管。`ua` 是保留内联/自动播放及相同 UA、但仍零注入的另一个对照。新窗口保留 WebKit 提供的配置。

复现入口仍为同一搜索词和“B站精选”的同一视频，分别点标题、画面、来源小字。自动实验的采样只读取状态；逐项增加的处理来自生产源码导出，使用原来的内容世界和注入时机。对照应用不会伪造用户手势或调用测试专用 play/unmute。

| 对照层 | 本轮观察 | 结果的限制 |
| --- | --- | --- |
| 系统默认 → 仅内联 → 自动播放 → Soulo UA | 12 个入口样本。仅内联且保留系统音频手势限制时详情暂停；加自动播放后播放；相同 UA 后百度使用自定义控件并默认静音。零注入也出现绿画面。 | 系统默认配置有 DOM 暂停但原生 playing 的样本；不能仅据 DOM 判定音源。 |
| 同 UA → 全屏开关 → 弹窗开关 → 导航重载 → 挂起配对 | 10 个画面/来源样本，其中导航重载的来源样本未返回目标卡片，不能计为有效对照。其余多数详情暂停后原生为 paused。 | 一个全屏开关样本未实际暂停，控件时序需复测。 |
| 单独加入选词、资源嗅探、视频工具、媒体会话、广告、隐私、导航脚本 | 每次只加一项，7 个画面样本全部采集完成；6 个最终 DOM 和原生均暂停。隐私样本中“声音”触摸步骤已出现 pause，后续触摸反而恢复播放。 | 这是观察采集用例，绿色不代表问题修复。隐私样本不能凭坐标触摸次数归因，须验证实际状态后重试。 |

第一组结果 `/tmp/soulo-raw-browser-baseline-matrix.xcresult`，原生逐层 `/tmp/soulo-native-layer-baseline-matrix.xcresult`，单脚本 `/tmp/soulo-script-layer-baseline.xcresult`。采样和完整观察保存 `/tmp/soulo-browser-baseline/{results,native-results,script-results}`；截图、可访问性和观察附件保留在对应结果包。

原始应用的可复现构建方式（安装不启动，不影响 Soulo 数据）：

```sh
python3 scripts/diagnostics/build_raw_browser_baseline.py --profile system --device SIMULATOR_UUID
xcrun simctl launch SIMULATOR_UUID com.soulo.qa.RawBrowser.system -profile system -sampling NO
```

`testExportBrowserScriptsForIsolation` 仅在 `SOULO_EXPORT_ISOLATION_SCRIPTS=1` 时导出当前生产脚本。`testUnprocessedBaiduPlaybackBaseline` 仅在 `TEST_RUNNER_SOULO_RAW_BASELINE_QA=1` 时运行；用 `TEST_RUNNER_SOULO_BASELINE_PROFILES` / `ENTRIES` 指定层级和入口。单脚本应用通过构建器的 `--scripts-json` 接受导出文件。非必要原生桥处理为空；该实验不能替代整个 Soulo 的组合验收。

本轮尚未采集实际音频输出，因此不声称已证明“无后台声音”。自动化使用独立 QA 模拟器，原 Soulo 模拟器在实验期间终止 Soulo，避免两个测试应用混音；未操作其他项目的模拟器。

## 用户追加反馈后的复核

- 同款结果：百度搜索 `20201年喜剧电影解说`，视频《侦探：开端》，来源“B站精选 10月16日”。
- 标题的入口位于 `article` 的 `rl-link-href`、`rl-link-data-url`，根卡片 `data-log.mu` 是不同的 B 站来源地址。标题文字到根卡片需要经过 12 个祖先，即点击路径的第 13 个元素，超出最初 12 个元素的识别范围。
- 仅补链接字段和检查标题不够：实站画面点击有时只启动搜索页内预览，没有发起导航。百度 AI 提示浮层还会遮住标题左侧；界面测试必须点中实际露出的标题部分。
- 换页前只调用一次 pause 不够：在目标响应被延迟时，旧页面的 pause 监听器可以再次调用 play，已实际复现预览恢复播放。结果包 `/tmp/soulo-video-restart-reproduction.xcresult`。
- 释放/重建 WebView 只 stopLoading 也不够：保留旧 WebView 强引用时，旧播放器在 0.6 秒内仍由 0.283 秒推进至 0.907 秒；重建路径同样复现。结果包 `/tmp/soulo-video-followup-reproduction.xcresult`。
- WebKit 的媒体挂起使用计数，重复挂起必须成对解除。把跳转和后台标签分别挂起、再只解除一次，会让新页面持续无法播放。
- 用户再次反馈后在 iPhone 17 实站复现：搜索页视频已播放 10 秒且有声，进入详情后网站新建的视频默认静音。旧文档没有新的 play 事件，原生播放器未播放，详情上也没有旧页预览覆盖；不能把这种状态归因为旧页面截图。
- 只传递静音、进度后仍未通过真机验收：详情保留 11.453 秒且 `muted=false`，随后在初始化期间发出 pause，时间不再前进。失败结果 `/tmp/soulo-video-final-handoff-device.xcresult`。因此新增一次受限的启动重试，并用“首次 canplay 后暂停”的本地夹具覆盖。
- 用户再次反馈后，真实受信任点击诊断 `/tmp/soulo-video-real-tap-diagnostic.xcresult` 确认：默认预览的 `muted=true` 被原样放进 `videoPlayback`；详情 0.5 秒采样仍静音。该轮点击没有进入额外 WebView，pointerdown 到 click 期间预览也未暂停。源状态传递正确不等于符合“点击进入有声播放”的行为。
- 同一结果中界面用例虽然通过，截图却仍为缓冲状态：它把时间轴从 0 恢复到 12 秒的跳变当成了持续播放。现改为等待 8 秒，再连续检查时间推进；实站用例取消预先解静音，使用生产状态生成器，另以受信任的界面点击覆盖原生消息和加载路径。
- 用户补充“静音图标仍有声音”后，确认另一个状态错误：百度 `@baidu/splayer-control` 的 `toggleVoiceControl` 使用独立 `vnode.muted`，不会从 HTMLMediaElement.muted 自动回读。直接改元素会使图标与下一次点击的含义失配。修复通过其现有 `.voiceControlContainer` 的动作同步网站状态和媒体状态，不直接改图标。
- 该控件行为来自百度自身模块：[splayer-control_3021631.js](https://ms.bdstatic.com/se/static/sf/app/amd_modules/@baidu/splayer-control_3021631.js)。本地保存 `/tmp/soulo-baidu-splayer-control.js`，没有把第三方完整源码加入仓库。

## 当前实现

- 通用导航识别检查前 24 个点击路径元素，并识别两个 `rl-link-*` 字段。
- 百度 `/s` 搜索页的富视频卡片标题和画面由受信任的短点按打开卡片已声明的 `https://m.baidu.com/video/page?nid=...`。原生再次校验来源域名、搜索路径、详情地址和数字视频 ID；不取来源小字地址作为画面入口。仅作用于主文档。
- 只接管这类卡片的画面入口。控制栏、进度条、静音/播放按钮、Soulo 控件、带原生 controls 的视频、拖动、长按和已有文本选择继续保留原行为；标记广告时不发起画面跳转。
- 换页期间持续挂起旧文档媒体，阻止页面脚本重新播放。主文档提交、最终失败、手动停止或转为下载时解除跳转限制；后台标签仍保持挂起。
- 活跃标签与跳转限制共享一个有状态的挂起/恢复配对，重复重定向和标签切换不累加 WebKit 计数。
- WebView 被释放或替换时挂起被淘汰的运行时并关闭其媒体呈现，避免 SwiftUI、画中画或下载仍持有它时继续播放。新 WebView 独立恢复自身状态。
- 页内片段和 iframe 导航不挂起主页面；真正移出 DOM 的已跟踪媒体暂停，同一轮 DOM 中的正常重排保持播放。
- 点击百度视频标题/画面时，先等待旧文档完成媒体源释放，再发起详情加载，不依赖进程切换时的 pagehide 时序。释放会暂停旧媒体、清除 src / source / srcObject 并调用 load；已退场文档的 play 事件仍立即暂停。缓存后退以及取消/失败/转下载时恢复原媒体源与播放状态。
- 点击卡片表示进入完整播放器观看，详情启动为非静音。自动预览的静音、暂停或尚未完成元数据加载不会阻止详情启动；已知的同视频进度继续接续。状态只交给相同详情路径、相同视频 ID 的主文档。
- 新页初始化再次暂停时，5 秒内最多重试一次；用户触碰或按键立即取消待接续/重试状态，详情的常规控件保留网站行为。
- 百度自定义声音控件准备好后才交接；通过该控件切换静音，使声音图标与实际 muted 一致。metadata 之前/之后创建控件都能触发待接续处理，其他网站保持原媒体行为。
- 停止加载会标记该次导航已取消，迟到的主文档策略回调不再重新挂起旧页；新原生请求、受信任交互、后退/前进或重新加载会开启新的导航，避免取消后永久停播。

## 静音与暂停的实际控件验证

- 最终 **75 个不同模拟器用例通过、无跳过**。`/tmp/soulo-video-controls-final-regression.xcresult` 中 73 项媒体/导航/标签回归和真实标题入口通过；画面入口的暂停步骤遇到控件自动隐藏，首次点击只是显示控件，因此该整包为失败。补齐“首次显示控件、再次暂停”的界面步骤后，`/tmp/soulo-video-hardware-controls-final.xcresult` 的画面入口和真实声音/暂停点击通过。只调整了界面测试步骤，生产代码与前述 73 项及标题通过时相同。
- 最终真实触摸采样 `/tmp/soulo-video-hardware-controls-final.trace`：静音时 `iconMuted=1, muted=1, paused=0`；取消静音为 `iconMuted=0, muted=0, paused=0`；暂停后为 `paused=1`，时间在 3 次采样中保持 `29.0566231553`。加载详情前，旧文档释放回执为 `readyState=0`。
- 本轮签名开发构建于 18:03 安装到连接的 iPhone，回执 `/tmp/soulo-video-controls-final-installed.json`，版本仍为 1.2.5 (51)。本轮真机测试因设备锁屏未运行，不引用前轮真机通过作为当前控件修复的真机验证。
- 最终模拟器构建也已同步到原 Soulo Extension Audit 20261028（466D547B-562B-4CED-A1F4-329EE4E9539F），保留其应用数据。最终本地化、元数据一致性与 diff 空白检查均通过，未修改版本或商店文案。

- `/tmp/soulo-video-mute-control-verified.xcresult` 的实站用例通过：默认静音搜索预览 → 有声详情；随后点击百度自己的声音控件 **4 次**，每次均要求图标、video.muted 和所有文档媒体的可发声状态一致；再点击网站暂停控件，时间在 0.5 秒内不再前进，原生 `requestMediaPlaybackState` 返回 paused（2）。未录制麦克风音频，结论限定为媒体/控件/原生状态一致。
- 该结果包整体仍失败：另一项取消用例捕获到原生 suspended（3），媒体源已经恢复但仍被挂起。它暴露了停止后的迟到策略回调；已改为显式取消状态，必须在最终回归中再次验证，不能把上述单项通过写成整包通过。
- 旧文档会尝试发 play 事件，但释放后事件中的实际状态为 `paused=true`、`readyState=0`、没有配置源。这是被抑制的重播尝试。断言检查实际可播放媒体而非仅检查事件名称，以免把已阻止的尝试误报为继续出声。
- 自动化改用独立模拟器 `1E6318D8-B5BE-4513-B033-56104F368D72`（Soulo Media Controls QA 20261028）；不操作用户当前窗口中的其他模拟器。

## 前轮恢复函数验证（未覆盖默认预览点击）

- 真机 iPhone 17 / iOS 26.6.1：`/tmp/soulo-video-startup-retry-device.xcresult`，**12 项通过、0 跳过、0 失败**。测试于 16:39 完成；安装的是包含一次启动重试的签名开发构建。
- 其中真实百度普通模式：源视频 `currentTime=10.214`、`paused=false`、`muted=false`；进入新文档后为 `11.592 → 13.610` 秒、`paused=false`、`muted=false`、`volume=1`、`readyState=4`。新页没有额外执行测试专用 play / unmute。旧文档只收到 pause，没有新的 play；原生播放器未播放，旧页预览覆盖不存在。
- 同一真机的本地夹具同时覆盖有声/静音两种源状态，详情默认暂停并在首次 canplay 后再暂停一次，仍能接续播放。退场媒体的已配置源为空、`paused=true`、`readyState=0`；后退重新加载原媒体源。
- 模拟器 `/tmp/soulo-video-startup-retry-regression.xcresult`：媒体、导航策略、标签与视频接续共 **71 项通过、1 项实站选用用例跳过、0 失败**（报告总数 72）。该实站用例已在上述真机结果中实际执行通过。
- 测试事件附件导出至 `/tmp/soulo-video-startup-retry-device-attachments/`。这里验证的是播放器非静音、播放时间推进和旧文档事件，没有进行麦克风声音录制；未宣称真机 XCUITest 界面运行器通过。
- `check_localization.py --strict`、`export_metadata_json.py --check` 和 `git diff --check` 通过。版本保持 1.2.5 (51)，未更新商店元数据。

## 前轮验证与局限

- 模拟器：`/tmp/soulo-video-final-simulator.xcresult`，108 项媒体、导航、标签、预热相关测试及 2 项本地界面测试，合计 **110 项、0 失败**。
- 真机：连接的 iPhone 17 / iOS 26.6.1，`SearchVideoNavigationTests` **10 项、0 失败**；含旧运行时保留引用、旧页脚本重新 play、跨域 iframe、新页自动播放、后台标签与取消的挂起配对、画面/控制栏识别及 URL 范围限制。
- 真机结果包 `/tmp/soulo-video-final-device.xcresult` 整体为失败：上述 10 项通过后，界面运行器在进入用例前以 74 退出，报告 IDE disconnection。随后解锁、确认有线连接后仍复现 DTX 测试通道被拒绝，不能只归因于锁屏。改用实际 iPhone 镜像及不依赖界面运行器的实站 XCTest 检查。
- 最终卡片复核 `/tmp/soulo-video-final-card-entry.xcresult`：10 项专项和 2 项实站界面测试，**12 项、0 失败**。两个实站用例分别点击标题和画面，均检查到达详情页，以及视频时间轴实际推进；不是仅检查地址栏变化。截图已导出至 `/tmp/soulo-video-final-card-attachments/`。
- 与 110 项回归结果合并，有 112 个不同的模拟器用例通过，重复的 10 项专项不重复计数。
- 前轮签名开发构建于 15:12 安装；本轮修复接续状态后于 16:28 再次安装，回执 `/tmp/soulo-video-sound-handoff-installed.json`。版本仍为 1.2.5 (51)，后续实站 XCTest 会安装该轮编译的同一应用。
- 界面夹具覆盖 18 层嵌套标题、来源地址与落地地址不一致、网站原处理器、重定向、表单、新窗口及广告拦截。
- 实站播放已检查时间轴推进；仍不能把时间轴通过等同于画面解码正确。模拟器截图依然偏绿。
- 对偏绿画面另建独立 UIKit + WKWebView 应用进行对照，不链接 Soulo、不注入用户脚本、不执行任何暂停/挂起调用，使用同一 User-Agent 和该卡片声明的完整详情 URL。对照也出现绿画面；22 秒采样时 `paused=false`、`currentTime=19.051`、`readyState=4`、视频尺寸 853×480。源码、采样和截图位于 `/tmp/soulo-bare-video/`。这证明该现象无需 Soulo 脚本或媒体控制即可复现；未据此武断定位到具体解码器。临时对照应用验证后已卸载。
- 真机镜像可正常显示该视频画面；旧实现能直接看到详情静音图标。镜像后续坐标点击报 `noWindowsAvailable`，因此继续采用真机实站 XCTest；未把镜像截图当作声音采集或完整手动验收。
- `python3 scripts/check_localization.py --strict`、`python3 scripts/export_metadata_json.py --check`、`git diff --check` 通过。未更改版本或商店文案。

## 复测

实站用例通过 `SOULO_LIVE_SEARCH_VIDEO_QA=1` 显式启用；使用 xcodebuild 时同时设置 `TEST_RUNNER_SOULO_LIVE_SEARCH_VIDEO_QA=1`。实时搜索若不再返回同款卡片，会记录跳过，不能计为通过。

`testLiveBaiduDocumentMediaHandoffAndSound` 使用默认静音的真实搜索预览，等待 10 秒后调用与点击脚本共用的生产 playbackIntent 生成器，再走加载/旧源释放入口；不预先取消预览静音，不在新页补做测试专用 play / unmute。App-hosted XCTest 不能生成硬件信任触摸；曾改写 isTrusted 的尝试没有进入消息链，现已撤回。受信任点击及原生消息路径由独立标题/画面界面用例验证。`TEST_RUNNER_SOULO_MEDIA_NORMAL_QA=1` 使用普通模式及正常扩展环境。

开启 `SOULO_BROWSER_TRACE=1` 后，Debug 构建将导航事件与媒体采样写入应用 tmp/soulo-browser-trace.log，最多 256 KiB；Release 不启用该记录。日志只记录 host/path 及播放器状态，不记录网址查询参数。

## 搜索结果中的 JSON 标题

用户标记的 `{"code":0,"stg_ver` 与“贵妃醉影”微博摘要，在不链接 Soulo、不安装用户脚本/广告过滤的独立 AppKit + WKWebView 中也会出现。2026-10-28 再次运行 `/tmp/soulo-baidu-video-diagnostic.swift`，结果保存 `/tmp/soulo-baidu-clean-result-check.json`，body 包含相同文本。因此来源是百度页面的搜索结果，不是 Soulo 后处理生成。单独 HTTP 请求可能返回不同批次/布局的结果，未据此声称所有响应批次均含该标题，也未擅自隐藏结果。百度收录或源站哪一环节出错尚未确定。

## 本轮排查检查

1. 失败信号：保留用户关于旧页播放、详情静音和静音图标有声的原始反馈，逐项验证。
2. 搜索：查实际页面、控件模块与导航/媒体源码，不用错误截图推断音源。
3. 原始材料：检查点击脚本、原生策略、页面提交和源释放的完整调用路径。
4. 前置条件：记录安装回执、实际测试设备、默认静音状态；锁屏的真机测试不算通过。
5. 反向验证：检查当前播放器的控件失配，而非只假设旧页在响。
6. 最小复现：用本地延迟响应、初始化再暂停、保留旧运行时及裸 WKWebView 对照。
7. 改变方法：从直接调用恢复函数改为真实标题/画面点击，并增加网站静音/暂停控件及原生播放状态检查。

原生媒体契约参考：[Apple：setAllMediaPlaybackSuspended](https://developer.apple.com/documentation/webkit/wkwebview/setallmediaplaybacksuspended(_:completionhandler:))、[WebKit WebPageProxy 的挂起/恢复实现](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp)。
