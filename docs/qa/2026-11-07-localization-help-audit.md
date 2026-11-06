# 阅读工具本地化、iPad 与帮助说明核查（计划 20、29、30）

## 初始核查

- `python3 scripts/check_localization.py --strict` 初始通过：主表 898 键 × 50 种语言。该结果不能代表阅读工具已全部翻译：原检查器只检查已经存在的 `ReadingTools.strings`，没有检查支持语言中缺少的独立表。
- `python3 scripts/audit_localization.py --output /tmp/soulo-localization-audit-20261107.md` 显示阅读工具共 436 键，只有简体中文、繁体中文、美国英语三份完整表；其余非英语语言每种仅复用 11 个通用标签，425 项回退英语。
- `SouloTests/LocalizationLayoutTests.swift` 原有用例还把德语 `wifi_hint` 回退英语作为预期，应在补全后改为验证真实本地化。

## 计划 20：补全与检查

专用工具 `scripts/generate_reading_tools_localizations.py` 只填补独立阅读工具表；不运行原全量生成器入口，不改 App Store 元数据、权限或主文案。保留既有三份完整表；通用操作复用当前语言主表，其余文案通过既有项目采用的 Google 翻译服务生成，保护品牌、文件格式和 printf 占位符。

首次请求的 `translate.googleapis.com/translate_a/single` 和 `translate.google.com/translate_a/single` 均返回 429；同一公开界面文本的 Google dictionary 客户端 `clients5.google.com/translate_a/t` 返回 200 和真实德语翻译，专用工具使用该客户端。失败时保留错误并退出，不写英文占位来冒充翻译。响应缓存在 `/tmp/soulo_reading_tools_translation_cache.json`，不进入 Git。

`check_localization.py` 已增加全部 50 种语言的阅读工具覆盖检查；`audit_localization.py` 的覆盖结论改为动态统计，避免补全后仍输出历史回退数量。机器辅助翻译仍需母语审校，完整性与占位符检查不等同于语言质量验收。

## 计划 29：iPad、键盘与窗口边界

- `project.yml` 声明 `UIApplicationSupportsMultipleScenes: true`；生成工程 `TARGETED_DEVICE_FAMILY = "1,2"`，并为 iPad 配置四方向旋转。
- `SouloApp.swift` 的 `WindowGroup(for: BrowserWindowConfiguration.self)` 为每个窗口创建独立 `SearchViewModel`、`TabManager`；标签恢复键含窗口 UUID，关闭和恢复时按窗口存储。
- `TabManagerTests` 已有 `testDefaultWindowIdentityRestoresLatestWindowAndNewWindowsRemainIndependent`、`testIndependentWindowStorageKeepsTabSessionsSeparate`，以及跨窗口桌面偏好/隐私设置同步用例。本次只读核查，不把已有测试当作本次重新执行过。
- 初始源码未发现 `keyboardShortcut`、`UIKeyCommand`、`onKeyPress`、应用内 `openWindow` 或 `requestSceneSessionActivation`。系统窗口能力存在，不代表已有可发现的应用内新窗口操作或浏览器硬件键盘快捷键。根任务负责补齐和模拟器验证。
- 首页内容在较宽窗口使用最大宽度约束。现有媒体宿主优先使用控件所在 scene；多窗口交互还需要实际场景回归，不能只以 Info.plist 开关判断完成。

## 计划 30：文档与帮助一致性

- README 的“15 种语言”“22 个平台”、旧目录树和早期阶段清单已经过时。已重写为实际功能、目录与构建/发布检查，平台数量不再维护第二份易失真的硬编码表。
- 新增 `docs/USER_GUIDE.md`，解释站点兼容、播放器模式、后台音频、下载/文件、Wi-Fi 传输、设置同步、备份、收藏 HTML、App 图标长按快捷操作和反馈入口。
- README 明确主表 50 语言与阅读工具独立表的区别，链接动态审计；不宣称所有语言都完成母语审核。
- 官网当前描述的多平台搜索、广告过滤、下载、播放、阅读、翻译与脚本扩展均有源码实现；“iCloud 设置同步”与实际范围相符，本次未改网站生成页面、部署脚本或未跟踪的网站链接审计文件，也未部署网站。
- App 内 `HelpCenterView` 初始仅含搜索、平台、收藏、壁纸、过滤及邮箱说明；播放、下载、备份等帮助的应用内入口由根任务整合。

## 本次验证

- 三个 Python 文件编译检查通过：专用阅读翻译工具、严格检查器、审计生成器。
- 全量生成完成：50 种语言 × 436 个阅读工具键；原主表仍为 898 × 50，严格检查通过。原有三份完整表保持原文，其余按目标语言翻译，英语地区使用英语；没有把不相关语言或英文复制到非英语语言来消除缺项。
- 50 份阅读表均通过 `plutil -lint`；全表 printf 占位符与来源一致，未发现保护标记残留。德语、法语、西班牙语、日语、韩语及葡萄牙语的短标签另外抽查，格式/明暗/外观等歧义项补充语境或复用已有 UI 同义翻译。
- `LocalizationLayoutTests.testReadingToolTablesAreIncludedForEverySupportedLanguage` 新增真实打包资源的 50 语言读取检查；`testToolLabelsUseSelectedAndRegionalLanguagesWithoutChangingPreferences` 改为验证德语提示不再是英语。原生测试由根任务在重新生成工程后串行运行，本子任务未运行 Xcode 构建或模拟器。
- 本机过程日志：`/tmp/soulo-reading-tools-all-20261107.log`、`/tmp/soulo-reading-tools-labels-20261107.log`、`/tmp/soulo-reading-tools-labels-final-20261107.log`。临时缓存和日志不进入 Git。

## 新增界面集成快速审查

- 23 个当时已改动或新增的 Views 文件通过 `swiftc -frontend -parse`。这只验证语法，不替代根任务的 iOS 类型检查、链接与界面验证。
- 独立 Foundation 类型检查证实 `URL` 不符合 `Identifiable`，因此试搜索页最初的 `.sheet(item: $previewURL)` 不能直接使用。已向根任务报告，建议 Bool sheet 或局部 Identifiable 包装；不添加 Foundation 类型的全局追认符合。
- 重复收藏过滤最初在每次 filter 迭代中重新计算全量重复集合，可能达到 O(n²)；已建议循环外计算一次。
- 离线阅读最初把全文集合放入一份主线程 JSON，每次阅读位置变化会编码全部正文；已建议限制总量、拆分正文与索引或后台串行持久化。
- 音频控制行新增睡眠定时的默认 Label 会和已有 44 点动作抢空间；已建议行内只显示图标，更多菜单保留文字标签。根任务负责修正和模拟器截图验收。

`generate_reading_tools_localizations.py --table FeatureImprovements` 已准备为新功能的独立增量模式；不会改阅读表、主表、权限或商店元数据。新表的源文件与最终检查由根任务完成后继续同步。

## 新功能表最终集成

- 新增 `FeatureImprovements.strings`，按当前 `FeatureText.text` 调用建立简繁中文和美国英语源，补齐全部 50 语言，共 **83 键 × 50**。包含筛选排序字典、启用状态、分组置顶条件分支、长帮助说明、`%lld` 删除确认、收藏壁纸分类与清除站点数据的登录/同域影响提示。
- `feature_localization_keys.py` 读取完整调用表达式，涵盖静态字符串、条件分支与字典；严格检查比对全部实际键。根任务后加的站点清除提示曾被检查准确报为缺键，补译后通过。
- 短词直译中的“播放”被误作游戏、“固定分组”被误作针脚组等问题已加入语境处理；德语、法语、西班牙语、日语、韩语和两种葡萄牙语的部分短标签另做自然表达校正。保留简繁中文源；未将英文复制到其他语言来消除错误。
- 翻译服务在密集保护标记的键盘说明中破坏或遗漏 `Command-F`，逐语对照后采用完整句翻译、人工保留标准快捷键名称并校对；芬兰语句单独校正。严格检查现在验证全部 `Command-*` 与 Soulo、Apple、iPad、HTML 的保留，并拒绝任何保护标记残留。
- 最终验证通过：主表 **898 × 50**、阅读工具 **436 × 50**、新功能 **83 × 50**；50 份新功能表的 `plutil` 语法、实际源码键集合、printf 占位符与标记检查全部通过。四个相关 Python 文件编译、`LocalizationLayoutTests.swift` 语法检查通过。
- 原生新增 `LocalizationLayoutTests.testFeatureTablesAreIncludedForEverySupportedLanguageAndPreserveCountFormats`，验证实际 Bundle 中每语表和 `%lld` 格式；需根任务重新 `xcodegen generate` 后运行。本子任务没有运行 Xcode 构建、模拟器或提交。
- README、USER_GUIDE 和 LOCALIZATION_AUDIT 已同步；App 内 HelpCenter 的播放/文件/备份和键盘说明由根任务接入，审计生成器动态报告新功能表覆盖。机器辅助译文仍需母语审校，不把上述完整性检查宣称为全部语言质量验收。
- 过程日志在 `/tmp/soulo-feature-improvements-20261107.log`、`/tmp/soulo-feature-improvements-context-20261107.log`、`/tmp/soulo-feature-keyboard-repair-20261107.log` 和 `/tmp/soulo-feature-improvements-site-clear-20261107.log`；缓存与临时工具不进入 Git。

## 键盘与窗口最终源码核查

初始隐藏按钮方案没有足够证据支持“快捷键一定保留”：Apple 的 [hidden() 说明](https://developer.apple.com/documentation/swiftui/view/hidden%28%29) 指出隐藏视图保留在层级中，但不能接收或响应交互；[keyboardShortcut 说明](https://developer.apple.com/documentation/swiftui/view/keyboardshortcut%28_%3Amodifiers%3A%29) 描述前台窗口/scene 的命令查找，并未承诺隐藏或零尺寸按钮的行为。因此没有把初始实现判定为已实测可用，也没有只凭文档断言它必定失败。

实现已改用官方 scene 命令：`SouloApp` 的 WindowGroup 挂接 `BrowserKeyboardCommands: Commands`，Home 通过 `focusedSceneValue` 发布该窗口的 `BrowserKeyboardActions`。Apple 的 [commands(content:) 说明](https://developer.apple.com/documentation/swiftui/scene/commands%28content%3A%29) 明确支持 iPadOS 快捷键提示；[focusedSceneValue 说明](https://developer.apple.com/documentation/swiftui/view/focusedscenevalue%28_%3A_%3A%29-57boz) 提供当前 scene 的动作，并以移动焦点到文本框作为示例。已对照本机 iOS SDK 接口确认 Commands 从 iOS 14 可用，可选 focusedSceneValue 从 iOS 16 可用，覆盖项目最低 iOS 17。

- 动作闭包绑定每个窗口自己的 TabManager。首页聚焦通知带 TabManager 身份，网页地址聚焦通知带 WebViewModel 身份，接收者校验目标；没有全局“最后一个窗口”动作存储。
- iPad 首页菜单和 Command-N 调用 `openWindow(value: BrowserWindowConfiguration())`。该值含新 UUID，与已有值类型 WindowGroup 匹配；[Apple openWindow(value:) 说明](https://developer.apple.com/documentation/swiftui/openwindowaction/callasfunction%28value%3A%29) 确认此 API 打开对应类型的窗口组。
- Home 统一门控自身弹窗、导航目的地和标签概览。额外的 `BrowserKeyboardContext` 通过不拦触摸的 UIKit reader 观察自己的 weak window，执行命令时要求该窗口为 key、scene 活跃，且 root controller 没有 presented controller。此门控用于阻止浏览器工具展示时的幕后标签动作；各具体弹窗仍须由根任务通过原生窗口测试和模拟器验证。检查的是 presented controller 而非 children，正常 NavigationStack 子控制器本身不会触发该条件。
- `BrowserKeyboardContextTests/testCommandsRequireTheirKeyWindowAndNoPresentedTool` 已新增：真实 window/overFullScreen presenter 的允许与阻断、dismiss 恢复、另一个 key window 的阻断、旧 reader 在替换后移除的身份保护。每阶段有 6 秒上界，defer 恢复原 key window。子任务只通过语法检查，没有执行此原生用例。
- 官方 API、源码动作路由、窗口门控和测试编写不能代替实际按键输入验证。根任务负责最后原生构建和 iPad 模拟器；真实外接键盘与不同键盘布局未由本子任务验收，不宣称已经完成硬件实键覆盖。

文档同时限定设置搜索是页面名称直达和分区匹配；文件搜索限当前目录名称；下载筛选可组合状态与类型；标签分组是自动站点组的重命名/置顶，而非任意手动分组；收藏壁纸作为保存内容保护。阅读列表说明现在对应 actor 串行持久化和 500 篇、单篇 2 MB、正文合计 20 MB 的限制。

阅读列表限额另加专属错误提示，避免沿用“书籍 128 MB/压缩包”错误文案。新增功能表最终为 **84 键 × 50**，三份中英源和所有语言已补齐，严格检查通过；这不会改变历史第 83 键批次的验证记录。
