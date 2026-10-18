# Soulo 本地 AI

独立 Swift Package，iOS 17+。模型在用户选择后下载；推理由应用进程内的 llama.cpp / Metal 执行，不依赖电脑上的服务，也不启动本地 HTTP 服务。

## 使用

- “更多 → 本地 AI”先进入独立介绍页；点击下载约 672 MB 的文字模型，校验完成后进入完整的对话页面。设置中可管理来源、导入、下载和删除。
- 设置中可以选择轻量 1B 或 Agent 35B-A3B。35B 对话模型由主文件、40 个专家分片和一个清单组成，共约 15.5 GB；视觉组件另下约 1.12 GB。推荐 12 GB 以上内存，8 GB 设备可以尝试，但速度与稳定性需要按设备实测，不能套用官方高端设备的速度。
- 搜索框和地址输入框保留原有布局。下载并启用模型后，可从侧边形象或菜单进入 AI；语音识别后的文字也能交给 AI。形象直径 48 点，吸附左右边缘时露出一半，保留 44 × 64 点的触摸区域。
- 设置 → 自定义工具栏，可放置“本地 AI”和“去广告”。去广告直接在当前网页执行，以小条显示进度、停止、结果和恢复。
- 设置 → 本地 AI → 助手形象，可选择四种原生绘制的形象，开启悬浮入口，轻微呼吸和浮动动画，拖动后吸附左右侧边并记住位置；减弱动态效果或进入后台时停止循环动画。对话、键盘输入和标签管理时隐藏。
- 网页对话关联当前标签的内容，支持问答、分段总结、阅读提纲和原有阅读器。回答以原生 Markdown 呈现，深色界面使用浅紫色操作按钮与高对比正文。
- 对话可以打开网址、搜索、查看/切换/新建/关闭/恢复标签、刷新/前进/后退、滚动、查找文字和打开网页链接；也可调整外观、阅读配色/字号、工具栏、网页样式、隐私等注册设置，提取当前已加载的网页图片并打开原生图片列表，或打开浏览器已有工具。
- “整理下载文件”先列出按类型分类的移动方案，确认后执行，支持撤销；保留下载记录、书籍标题、阅读进度和媒体引用。仅操作应用内已完成的文件，不覆盖已有文件、不跟随符号链接，也不删除文件。
- “去广告”让模型从有明确广告标记且通过保护规则的候选中选择，然后直接隐藏，可恢复。正文、目录、导航、表单、媒体和嵌入内容受保护。它不能保证移除所有网站广告。
- 回答里的网页链接交回 Soulo 处理；不通过回答直接打开 App Scheme、本地文件或脚本链接。模型通过受约束的 JSON 选择已注册的原生操作，不能生成代码执行。
- 视觉组件按需另下约 1.11 GB；用于理解可见区域截图。剩余内存额度低于 1.8 GB 时继续提供文字功能。
- 无痕模式不加载或保存对话历史；关闭页面、切后台、内存警告会停止推理并释放模型，空闲 30 秒释放。历史最多读取最近 100 个对话，每个保留最近 80 条消息。

## 原生操作接口

`LocalAITools` 是独立包的宿主协议：注册工具名称、参数范围、是否确认，以及预览、执行、撤销和页面切换回调。浏览器类型留在宿主 `BrowserLocalAITools` 中；模型包不依赖 WebView、TabManager、文件库或设置服务。

当前宿主注册网页、标签和文件操作、45 项设置，以及浏览器已有工具入口。所有标签可列出并按编号操作，提示上下文只包含前 30 个标签以控制开销。用户意图由本地模型判断，不使用用户关键词分流或直接执行操作。1B 分别选择函数和生成命名参数；35B 在一次结构化输出中选择下一步函数及参数，或选择直接回答。GBNF 约束函数、参数 JSON 及枚举值；原生层检查格式、范围、网址、标签和页面状态，不合格参数允许模型修正一次。原文计数的目标须来自用户文字，域名筛选必须是有效域名或已配置的网站名。结构化规划使用确定性解码。

精确计数、链接筛选及文件移动由原生工具执行，结果直接取自实际数据。计数覆盖主页面已加载的可见文字，排除输入框、图片及嵌入网页的文字。链接提取读取最多 4,000 个锚点，最多返回 100 个去重结果，支持域名筛选及网页自身记录的跳转目标；结果以原生卡片展示，支持打开、逐条复制及全部复制，达到上限会提示。原生结果作为独立观察记录传给后续对话，不把页面摘录中的数量当作整页统计。

1B 每轮处理一个函数；35B 每轮最多执行 6 步，执行后把实际结果交回模型决定下一步，重复且状态未改变的调用会停止。导航在原标签执行，等待当前文档及内容稳定后才能继续读取，适配文档加载结束后才填充正文的 SPA。是否展示网页也由模型选择 `page_show` 工具决定；请求分析时，结果保留在对话页。打开既有工具界面、需要用户确认的操作和达到步骤上限都会结束本轮自动执行。操作审核绑定具体标签及网页，确认期间切换页面会拒绝旧方案。关闭网页关联后不自动提取全文；明确调用网页读取或总结功能仍可使用页面。模型可能误选函数或参数，有限的验收场景不能证明任意 Agent 任务都可靠。

关闭标签、整理文件、自定义提示词以及隐私/同步设置会展示具体改动再执行。普通显示设置直接生效并提供“撤销上次更改”。文件方案展示全部待移动文件（最多 200 个），执行前再次检查文件大小、修改时间、下载状态和目标冲突。网页脚本是固定的隔离世界脚本，只在需要读取链接、正文或清理元素时调用。

默认仍为 MiniCPM-V 4.7 **1B Q4_K_M**；**35B-A3B LES** 是独立的可下载选项，不连接电脑的推理服务。1B 的复杂对话与规划能力有限；更大模型也不能保证推理和广告判断准确。长页面最多提取 32,000 字符，超出时说明截断；摘要按段处理，问答使用相关片段。

## 构建

从仓库根目录运行：

```sh
python3 Modules/SouloLocalAI/Scripts/prepare_runtime.py
xcodegen generate
xcodebuild build -project Soulo.xcodeproj -scheme Soulo -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

`prepare_runtime.py` 从官方 Demo 使用的 `tc-mb/llama.cpp-omni` 固定提交构建 macOS、iOS 真机及当前 Mac 架构的模拟器切片，只链接 llama、ggml 和 mtmd，不包括 Demo、服务器或 TTS。需要 Xcode、CMake 和 Git；可用 `--skip-simulator` 跳过模拟器。脚本不下载模型。iOS 专家文件使用有界缓存并绕过重复的系统文件缓存；8 GB 与更大内存设备采用不同的预填批量。此版本未启用 DSpark，不能直接宣称达到官方整套方案的速度。

运行时、编译缓存和模型不提交 Git。首次构建前必须准备运行时，不能直接跳过此步骤。

## 移除或禁用

1. 将根 `project.yml` 中 `Modules/SouloLocalAI/project.yml` 的 `enable` 改为 `false`。
2. 运行 `xcodegen generate`。此时 AI 依赖、编译条件和所有入口消失，浏览器继续构建；签名权限也恢复使用原有 `SouloBrowser.entitlements`。
3. 可删除整个 `Modules/SouloLocalAI` 目录。保留的宿主 `LocalAIIntegration.swift` 会编译为无功能接口；无需修改浏览器模型或 WebView 生命周期。

已实际执行禁用后的独立 Release 构建。宿主通过设置、搜索/语音、工具栏、独立对话导航、悬浮入口、原生工具适配和后台下载分发接入；宿主唯一的模块 import 在 `Soulo/Source/Integrations/LocalAIIntegration.swift`。模块 UI 和运行时完全不依赖 Soulo 类型。

移除代码不会清除已安装应用里的数据。用户可先在设置中删除模型。数据仅写入应用容器 `Library/Application Support/SouloLocalAI/`，不参与浏览器同步和系统备份；提示词及开关使用 `soulo.localAI.*` 偏好键。对话保存在 Conversations，模型、续传信息和校验标记在 Models。无痕模式不写对话文件。

## 模型和运行时固定版本

| 内容 | 大小（字节） | SHA-256 |
| --- | ---: | --- |
| MiniCPM-V-4_7-1B-Q4_K_M.gguf | 672003680 | 588c6c94c82f756b86dba35c42ed9ba9ec187d65824eb52f039c347df563e63d |
| mmproj-model-f16.gguf | 1110117984 | fb9cc047a3cdad5317fd8433a4aeda2d22f00f02ca4bd93b34ad84165b25a900 |

官方模型仓库：[OpenBMB / MiniCPM-V-4.7-1B-gguf](https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf)，固定 revision `9684c734cfb2e6aaccb0bb52ba58afa9aae92d90`。中文用户默认 ModelScope 镜像，其他语言默认 Hugging Face；两个来源使用完全相同的大小和 SHA 校验，切换来源会重新开始未完成下载。默认使用 Wi-Fi，移动网络和个人热点下载前展示大小并确认。许可只作用于本次模型下载及续传，完成或删除后清除；取消不发起下载。“等待 Wi-Fi”不会允许蜂窝或热点流量。更改已有续传任务的网络方式会在提示中说明需要重新开始。支持暂停和后台继续；系统强制退出后已完成的文件会重新校验，而不是重复下载。

35B 使用[官方 Demo 指向的端侧拆分仓库](https://huggingface.co/tc-mb/MiniCPM-V-Apps-gguf)，固定 revision `8716e5209f308fd53f197ccd7d50c6fdcc2dc37d`。全部 43 个文件的大小、SHA-256、路径及来源保存在 `Resources/Models35B.json`，视觉文件不属于文字下载包。任一必需分片未通过校验时都不能运行。相同大小的专家分片依靠文件身份恢复中断传输，不能仅按大小关联。

运行时固定为 `tc-mb/llama.cpp-omni` 的 `96bbf61710d44421ea54e63f5194f9b17c20d877`，和本次参考的官方 Demo 子模块一致。MIT、Apache 2.0 和 stb 许可随模块打包。启用模块时使用专用 entitlement 文件，在保留浏览器权限的基础上申请 iOS increased-memory-limit；仍检查实际剩余内存，不依赖系统一定提供额外额度。

## 验证工具

```sh
swift test --package-path Modules/SouloLocalAI
swift run --package-path Modules/SouloLocalAI local-ai-check --model /path/to/model.gguf --prompt '请简短介绍你自己' --tokens 128
swift run --package-path Modules/SouloLocalAI local-ai-check --model /path/to/model.gguf --projector /path/to/mmproj.gguf --image /path/to/image.jpg --prompt '图片是什么？'
```

- `SouloTests/LocalAIFileOrganizerTests.swift`：方案变化/冲突/符号链接拒绝、移动和撤销、书籍及下载引用保留。
- `SouloTests/LocalAIIntegrationTests.swift`：真实 WKWebView 上的提取、导航过期保护、元素隐藏与恢复、截图。
- `SouloUITests/LocalAIUITests.swift`：真实 Swift.org 文档网页、实际模型回答/操作、停止、独立页面、介绍、自定义工具栏去广告及恢复、形象和无痕界面。需要先将已校验的模型放入专用测试模拟器的应用容器。
- `LocalAIAgentModelTests` 是可选的真实模型规划验收。设置 `SOULO_AI_ACCEPTANCE_MODEL` 和宿主导出的 `SOULO_AI_ACCEPTANCE_CATALOG`；35B 还需 `SOULO_AI_ACCEPTANCE_PROFILE=enhanced`。它覆盖计数、链接、图片、访问网址及网站、设置、否定指令及追问，并包含实际页面分析功能。宿主的增强目录由 `testEnhancedAgentExportsItsActualCatalog` 导出，避免手写样本与产品接口分离。
- `LocalAIValidation` scheme：独立真机验证程序，读取其 Documents 中的两个模型文件，测试中文回答、真实 Swift 文档网页、取消、图片识别和释放内存。环境变量 `SOULO_LOCAL_AI_QA_AUTORUN=1` 会自动运行、输出 JSON 并以测试结果退出。可设置 `SOULO_LOCAL_AI_QA_TEXT_ONLY=1` 跳过视觉组件，输出会标明文字验证模式；还检查约束格式的浏览器操作计划。该程序不随 Soulo 安装。

界面提供简体、繁体和英文，其他应用语言回退英文。没有改动应用版本或商店文案。1B 记录见 `docs/qa/2026-10-17-local-ai.md`；35B 与 LFM 可行性记录见 `docs/qa/2026-10-17-local-ai-35b.md`。
