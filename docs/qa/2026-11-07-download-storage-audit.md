# 下载、文件与分类存储：后端审计

范围：计划第 7、8、13、14、15、21 项；保留既有传输引擎、文件操作与播放入口。此记录由负责 Services/Models 的并行任务编写，界面整合、编译及模拟器验证由主任务串行执行。

## 已修复的具体缺陷

- **嵌套下载在 App 数据容器迁移后丢记录**：旧恢复代码只重建 `Downloads/<文件名>`，已移动到子文件夹的记录会被当成文件已删除。现在保留 `Documents/Downloads/` 后的相对路径，仅重定位到当前下载根目录内的真实文件，拒绝指向根目录外的符号链接。
- **移动父文件夹后下载引用不更新**：原实现只比较完全相同的 URL。现在通过 `LibraryFileActions.relocated` 同时更新目录内的后代下载记录；磁力下载只随真实目录重命名改变标题，移动父目录时保留元数据标题。
- **损坏的下载历史被启动清理覆盖**：解码失败时保留原数据并设置 `hasUnreadableHistory`，不再立即写回空历史；列表进入时的自动缺失文件清理同样跳过该状态。后续主动修改仍会保存当前记录；本次没有新增复杂的归档恢复界面。
- **文件移动来源的归属检查缺失**：目的地已要求处于文件库根目录，但来源未做同样限制。现在两侧都必须位于 owned root；外部文件继续走已有复制导入入口。
- **离线阅读接受缺少主机名的 URL**：`ReadingListStore.save` 除 http/https 协议外增加非空 host 校验，避免 `http:broken` 被存为网页。

## 可接入的纯查询 API

`LibraryQueryService.swift` 中的查询不访问磁盘，复用界面异步准备的实际文件信息。

- `DownloadListQuery.apply(_:search:status:kind:sort:sizes:kinds:)`：名称与解码后的来源 URL 支持多个关键词；状态与类型可组合；按开始日期、自然文件名、实际/预期大小排序。`kinds` 可传入内容嗅探后的类型，避免无扩展名图片被归到其它类型。
- `LibraryFileQuery.apply(_:search:kind:sort:directoriesFirst:url:presentation:modifiedAt:)`：泛型保留原界面记录、缩略图和选择身份；默认目录在前，支持相同的类型/日期/名称/大小查询。
- `DownloadStatusFilter`：all、active（含暂停）、paused、completed、failed、canceled。
- `LibraryFileFilter`：all、folders、images、videos、audio、documents、archives、other。
- `LibraryListSort`：newest、oldest、nameAscending、nameDescending、sizeLargest、sizeSmallest。

原有文件重命名/移动已经提供重名拒绝、整组选中项预校验和移动失败回退，不额外引入覆盖文件的行为。原有下载完成 publisher、播放/打开、分享、在文件中查看及各传输类型的重试/暂停/恢复入口保留。

## 分类存储 API 与清理边界

`StorageUsageService.scan()` 异步返回 `[StorageUsageRecord]`，每条记录有 `category`、`bytes`、`isEstimated`、`canClear`。分类如下：

| 分类 | 统计范围 | 提供清理 |
| --- | --- | --- |
| webData | WebKit 缓存与共享 URLCache，估算值 | 是；不含 cookies、LocalStorage、历史 |
| tabSnapshots | 当前及旧路径中的标签截图 | 是；传入 TabManager 时先失效内存引用 |
| favicons | favicon URLCache 的磁盘/内存用量，估算值 | 是；使用已有 service 清理与失效逻辑 |
| wallpapers | `ApplicationSupport/WallpaperFavorites` 收藏原图及旧 `Caches/wallpaper_hd` | 否；收藏原图和索引属于用户数据 |
| downloads | Downloads 文件及 `.soulohls` 引用的真实离线包 | 否；仅显示用量 |
| readingData | BookLibrary.json、BookCovers、ReadingList.json | 否 |
| backups | ApplicationSupport/Soulo/SettingsBackups | 否；在备份界面逐项操作 |
| filterRules | AdBlock 订阅源/合并规则及 SouloAdBlockStartup | 否 |

`clear(_:tabManager:)` 仅接受前三种可重建缓存。`measureDiskUsage(locations:)` 与 `clearDiskCache(_:locations:)` 可用隔离目录验证。统计不跟随符号链接；离线包按规范路径去重；只读取不超过 1 MB 的 HLS 引用。命名缓存根目录的符号链接会拒绝清理。壁纸收藏迁移期间的同一原图按文件身份去重统计。

这些分类显示数据占用，**不是 App 安装体积**，WebKit 不公开准确的单站字节用量，不能把估算值当精确磁盘总量。

## 新增回归覆盖与待统一执行

- `DownloadManagerServiceTests` 新增 3 项：嵌套容器迁移、父目录移动/磁力标题保留、损坏历史启动保护。
- `LibraryQueryServiceTests` 新增 3 项：组合查询/自然排序/类型覆写、真实文件元数据查询、拒绝移动外部来源。
- `StorageUsageServiceTests` 共 5 项：分类及 ReadingList 计入、只清理命名缓存而保留数据、不跟随符号链接、HLS 离线包去重、壁纸收藏迁移去重。
- `FavoriteWallpaperImageStoreTests` 新增 7 项：安全迁移与失败回退、清理拒绝删除收藏原图/索引、仅明确取消收藏才移除、迟到下载/取消收藏的顺序保护、空收藏不能启用或恢复仅收藏模式、不安全标识及 HTML 占位数据不能写入。`RetiredStorageCleanupTests` 同时验证保留收藏目录。
- `ReadingListStoreTests` 共 8 项：持久恢复/阅读位置、同 URL 更新与身份保留、只删除目标记录、非法输入保留原数据、写入失败保留内存及磁盘旧数据、并发加载/保存不丢条目、总正文容量限制、损坏归档不被首次保存覆盖。
- `RecentLocalPlaybackStoreTests` 新增 6 项：最近本地媒体相对路径在容器迁移后恢复、拒绝外部/越界 URL、损坏/恶意偏好不被采用、符号链接不能逃出文件库、隐私及重复 tick 不写入、删除仅清除对应文件或父目录条目。

本子任务没有执行 xcodebuild 或 simctl，测试尚待主任务统一运行。已检查负责文件的 diff 空白错误；不以静态检查代替测试通过。

## 阅读列表持久化与最近本地媒体的追加修正

`ReadingListStore` 的初始化不读取归档。`load/save/remove/updatePosition` 均为 `async throws`，界面先 `await load()`；独立 `ReadingListPersistence` actor 持有权威条目并串行完成解码、校验、原子写入。主 actor 仅按递增 revision 发布已成功读取/写入的快照，旧返回结果不能覆盖新状态。正文上限每篇 2 MiB、合计 20 MiB、最多 500 条；无效或损坏的已有归档会报错并保留原文件。此处不使用信号量或同步派发等待磁盘任务。

`RecentLocalPlaybackStore` 仅保存最近一个 Downloads 内媒体的相对路径及标题，不存正文或绝对容器地址。调用 `record(url:title:persistPosition:)` 时隐私会话传 false，或者由调用方先检查 `persistsPosition`。读取会重新确认路径位于当前根目录；文件存在检查由继续播放入口负责。相同路径及标题不重复写入；删除文件后用 `clearIfContained(in:)` 清除目标文件或父目录所对应的条目。

## 工具栏附带只读核查（第 10 项）

四个槽位的补齐、未知配置回退、旧 books→files 迁移、地址栏禁止 tabs/more 已有实现及回归。隐藏工具栏后的悬浮更多菜单保留恢复工具栏、编辑地址及锁→站点信息入口。核查时仅有默认布局、自定义、恢复默认，尚未提供多套预设；如第 10 项验收要求预设，需要由界面任务补充。本子任务不修改工具栏源码。
