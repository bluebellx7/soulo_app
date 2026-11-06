# 单站隐私、音频、扩展与备份核查

核查范围：计划第 12、24、26、27、28 项。核查基于 2026-11-07 这一批次的工作区；行号随主任务继续修改可能变化。本文区分已有实现、新补的独立服务，以及需要主任务统一验证的接入。未运行 `xcodebuild`、模拟器或真机，本子任务仅完成语法解析和差异空白检查。

## 12. 临时允许单站广告

- 原有过滤设置只有持久白名单。新增 `AdBlockSettingsService.temporarilyDisableFiltering(for:)`（`Soulo/Source/Services/AdBlockSettingsService.swift:191`），以及 `isTemporarilyAllowlisted`、`clearTemporaryException`、`clearTemporaryExceptions`。
- `allowlistedHosts` 是永久与临时例外的有效并集，原有脚本生成和原生过滤读接口继续适用；`permanentAllowlistedHosts`（同文件 132 行）用于永久例外管理页面。静态 `isHostAllowlisted(_:userDefaults:)`（257 行）读取同一临时注册表，避免原生和脚本路径设置不一致。
- 生命周期是应用会话：退出后台不清除，服务销毁或显式清除时结束；只写永久部分到偏好、iCloud 设置和设置备份。宿主名按现有规范化与子域匹配规则处理。重新开启某站过滤会清除作用于它的临时上级域名例外；选择永久允许会将临时选择升级为永久选择。
- 根任务已接入站点隐私面板（`SitePrivacyPanelView.swift:481`）。派生的规则缓存可能曾包含当前会话生成的脚本，但下一次启动以新的有效白名单和签名重新选择规则，临时例外本身不由缓存恢复。

新增 `AdBlockSettingsServiceTests` 的三项用例覆盖：临时/静态/子域读接口一致、偏好和设置快照没有临时项、普通永久项升级与保留、不同 defaults 隔离、销毁服务后结束会话。主任务还应运行实际网页的临时允许—刷新—恢复过滤，并确认其他站点仍过滤。

## 24. 清除当前站点数据

核查发现原实现固定使用 `WKWebsiteDataStore.default()`。从隐私标签页操作时，会清理普通数据而留下当前隐私数据，属于真实的存储隔离缺口。

根任务已将面板的清理目标改为传入的 `websiteDataStore`（`Soulo/Source/Views/WebView/SitePrivacyPanelView.swift:398`、582 行）。最小安全边界是始终从当前 WKWebView 的 `configuration.websiteDataStore` 取目标，不在缺少当前容器时回落清理默认持久容器。

WebKit 的 `WKWebsiteDataRecord` 通常按站点聚合，父域记录可能同时承载其子域登录。说明应明确该操作会退出所选站点登录，而不承诺仅删除某条 URL 的数据。域名匹配必须保留点分隔边界，不能将 `evil-example.com` 视为 `example.com` 的子域。

建议原生回归：两个独立 `nonPersistent()` 数据容器访问相同域名并分别写 cookie/localStorage，清除所选容器后另一容器和普通持久容器保持；再覆盖子域/父域 cookie、相似后缀域名、无当前容器和空记录分支。此处只读核查与报告，生产修复由根任务负责。

## 26. 本地音频队列与睡眠定时

已有的同目录音频队列由 `MediaSession.setLocalAudioPlaylist` 与 `advanceLocalAudio`（`Soulo/Source/Services/ReadingTools/MediaSession.swift:600`、606 行）维护，系统和 Soulo 两种模式在结束时都能推进。目录枚举通过 `FileVideoEpisodes`（`Soulo/Source/Views/ReadingTools/MatroskaPlayerView.swift`）过滤未完成下载、隐藏文件与符号链接，并自然排序；文件类型包含扩展名及 UTType 音频判断。

已有测试 `TorrentStreamingTests.testFileMusicKeepsPlayingAfterNavigationAndAutomaticallyAdvancesInBothModes`（352 行）验证 `2.wav` 到 `10.wav` 及离开原页面后继续播放；`IncrementalFeatureTests.testLocalAudioContinuesInBackgroundInBothPlayerModes`（254 行）覆盖后台音频。完整任意队列重排不是本项必要依赖；远程控制上一首/下一首在列表端点的启用状态可在后续细化。

本批新增独立 `PlaybackSleepTimerService`（`Soulo/Source/Services/ReadingTools/PlaybackSleepTimerService.swift:7`）：

- `init(pause:now:)` 注入暂停动作与测试时钟，不直接依赖播放器或视图。
- `start(after:)` 支持有效的 0–24 小时间隔，`stopAfterCurrentItem()` 在当前项目结束后暂停；`cancel()` 清除模式与挂起任务。
- `refresh()` 在恢复前台时按真实截止时间检查，`playbackEnded()` 返回 `true` 表示结束事件已被定时器消费，调用方必须停止循环或自动下一首。
- 替换/取消使用代次标识，避免旧任务稍后暂停新会话。暂停回调最多触发一次，普通倒计时可跨自动下一首持续生效。

根任务已在 `MediaSession.swift:138` 绑定弱引用暂停动作，并在两个播放结束路径（161、619 行）先消费定时器、前台通知（183 行）刷新。新增 `PlaybackSleepTimerServiceTests` 四项覆盖过期刷新只暂停一次、当前项目结束消费、替换/取消不误触发、真实短时定时回调。仍需统一运行两模式的实际结束/循环/下一首和后台返回回归，避免仅凭服务测试认定完整解码路径通过。

## 27. 扩展运行诊断

现有实现已经记录真实错误：

- 用户脚本 `BrowserExtensionService.userScriptRuntimeErrors`（`Soulo/Source/Services/BrowserExtensionService.swift:320`）和 `reportUserScriptError`（667 行）只接收仍启用的脚本，消息截断至 2000 字。保存/升级/删除会清除陈旧错误。
- 生产注入包装捕获同步异常，并通过错误/未处理 Promise 事件及带 token 的生产桥报告；错误桥需通过脚本身份、权限和来源校验。`ExtensionCenterView` 显示最近错误。
- `webExtensionDiagnostics`（1211 行）结合加载错误、已知不支持权限和原生 context 错误；原生诊断实现位于同文件 2761 行，`WebExtensionManagementView` 使用 `ExtensionDiagnosticsSection` 呈现。

真实缺口主要是“没有错误”缺少可解释的正向状态，用户难区分未启用、加载中、当前页面不匹配、不允许隐私会话与正常运行。推荐最小补齐是复用现有启用/加载/私密可用状态显示简短状态行，不在这一批另做完整日志系统，也不记录页面内容、完整访问 URL 或桥接 token。若增加最近成功时间，保持内存有界并能清除。

已有 `ExtensionLifecycleTests.testFailedEnableRestoresOffStateAndExplainsFailure` 和 `ExtensionManagementTests.testRealTabsShareStorageAndReportScriptErrorsThroughProductionBridge`（293 行）分别覆盖加载失败回滚、真实脚本错误桥及重存后清错。新增状态说明后，应覆盖禁用/加载中/错误/正常、隐私不允许和不匹配场景，确保空错误列表不会被当作“正在运行”。本子任务没有修改扩展生产代码。

## 28. 备份便携导入导出、版本与同步范围

已有本机备份 v1 在 `CloudSettingsBackupStore` 保留首次迁移副本及最近 20 个普通副本，支持单个删除；`CloudSyncService.restoreBackup`（`Soulo/Source/Services/CloudSyncService.swift:346`）在恢复前先保存当前副本并关闭 iCloud 设置同步。备份失败不能先覆盖当前设置。

本批新增便携设置文件：`CloudSettingsBackupStore.exportData(for:)`（73 行）与 `importData(_:preserving:date:)`（91 行）。格式固定应用标识、格式版本 1、`settings` 范围、导出时设置白名单、导出应用版本和 plist 负载。大小上限为 16 MiB；拒绝未知范围/版本、重复或越界字段、损坏负载、非有限数字和无效长按倍速。所有校验完成前不写任何新备份。

导出只包含 `CloudSyncService.syncedKeys`。导入只创建本机备份供用户选择恢复，不直接写偏好、开启同步或上传。旧版本的导出范围之外，保留当前版本新增设置；旧范围内明确缺省的键则恢复默认，防止旧备份静默清空未来的新设置。根任务已在 `CloudSyncService.swift:328` 接入包装及备份列表的文件导入/导出。

范围说明应明确：iCloud 设置同步/设置备份不包含收藏、标签页、浏览历史、登录态、缓存和下载文件。可见性等“收藏显示设置”属于设置，实际收藏记录不是。收藏已有独立 HTML 导入/导出（`Soulo/Source/Views/Bookmarks/BookmarksView.swift:162`、168 行，事务导入在 `BookmarkLibraryService`），不要将它表述成收藏 iCloud 同步。现有 entitlements 只有 App Group 与 iCloud KV，未配置 CloudKit 收藏容器；真正的收藏跨设备同步需要独立迁移、冲突与真机验证，不能靠扩大设置白名单实现。

新增 `PortableSettingsBackupTests` 三项覆盖设置白名单和不自动恢复、旧范围保留新增设置、未知版本/范围/非法倍速/NaN/超限文件不破坏原备份。已有 `CloudSyncSafetyTests` 覆盖恢复前备份、关闭同步、不上传、首次副本轮换保留、删除单个副本和恢复失败保护。建议统一补充 UI 文件导入错误提示、导入成功但当前设置未变、显式恢复后字段生效，再运行既有同步回归。

## 本子任务交付与验证边界

独立服务修改：`AdBlockSettingsService.swift`、`CloudSettingsBackupStore.swift`、新增 `PlaybackSleepTimerService.swift`；专属测试：`AdBlockSettingsServiceTests.swift`、新增 `PlaybackSleepTimerServiceTests.swift` 与 `PortableSettingsBackupTests.swift`。

以上文件已通过 `swiftc -frontend -parse -swift-version 5` 和 `git diff --check`。这不代表类型检查、原生运行或界面用例已通过。所有构建、模拟器与统一回归由根任务串行执行；本子任务未修改 MediaSession、Views、本地化或工程配置。
