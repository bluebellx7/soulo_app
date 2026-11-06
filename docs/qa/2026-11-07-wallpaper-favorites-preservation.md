# 壁纸收藏与清理边界

本轮新增要求：没有收藏时不能开启“仅使用喜欢的壁纸”；清除数据必须保留收藏索引与原图。界面禁用和说明由主任务处理；本文记录服务及专属回归。

## 已确认并修复

旧 `Caches/wallpaper_hd` 是收藏动作保存的原图目录，不是普通预览缓存。原分类存储清理会整体删除它，导致收藏索引仍在但离线原图丢失。现在 wallpapers 分类为只读收藏数据，`StorageUsageService.clear` 及 `clearDiskCache` 均拒绝清理。

`FavoriteWallpaperImageStore` actor 将新原图存到 `ApplicationSupport/WallpaperFavorites`。旧目录继续作为读取回退；后台迁移复制到临时文件并完成移动，确认新旧字节一致后才移除旧副本。目的地冲突、写入失败、读取失败均保留旧原图。新旧目录中迁移期间的同一收藏在分类用量中只计一次。

原图保存、迁移与取消收藏由同一个 actor 串行处理。WallpaperManager 的递增 revision 防止迟到的下载在取消收藏后重新创建原图；迟到的删除只作用于当前确实不在收藏中的标识，不删除后来重新收藏的图片。无效图片响应不作为原图保存。收藏索引仍在原有 `wallpaper_favorites` 偏好键中，清理逻辑不删除它。

没有收藏时直接设置、启动恢复、设置同步恢复“仅收藏”都会归一化为 false；删除最后一个收藏同样关闭该模式。保留本轮已完成的来源选择与 Nature 默认氛围修复。

## 全部清理链路核查

| 入口 | 实际清理范围 | 收藏处理 |
| --- | --- | --- |
| 设置/隐私“清除缓存” | BrowserCacheService：共享 URLCache、favicon、截图、WebKit 缓存；可同时清访问历史 | 不动收藏原图/索引 |
| App 图标快捷清理 | HomeView 调用相同 BrowserCacheService | 不动收藏原图/索引 |
| FireButton | WebKit 网站数据、URLCache、标签及隐私摘要 | 不动收藏原图/索引 |
| 分类存储 | 浏览器资源缓存、标签截图、站点图标可清理 | 壁纸收藏仅统计，拒绝清理 |
| RetiredStorageCleanup | 明确命名的 SouloLocalAI 目录及 soulo.localAI. 偏好 | 不动收藏原图/索引 |
| 设置备份/同步恢复 | 仅同步白名单键；包含仅收藏开关但不包含收藏原图/索引 | 空收藏不能恢复成仅收藏模式 |
| 明确取消收藏 | 相应标识的两个原图位置 | 只移除用户取消的收藏 |

新增 7 个 FavoriteWallpaperImageStore 专属测试，补充分类存储去重/拒绝清理与退休数据清理保留收藏的断言。子任务只完成源码及静态差异检查，编译与模拟器执行由主任务统一串行完成。
