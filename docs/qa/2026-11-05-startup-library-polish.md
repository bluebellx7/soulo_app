# 启动、标签撤回与资料库界面

2026-11-05，基于 main 的 1.2.8（51）。未调整版本号或商店文案。

## 改动

- 缓存远程壁纸及本地照片改为后台解码；切换来源、替换图片和清理缓存时取消旧恢复，避免过期图片覆盖新选择。语音音频引擎改为使用时初始化。
- 标签管理的撤回按钮位于最前，图标为橙色；恢复标签后保留管理页面。背景和点击区域沿用其他按钮。
- 下载和文件继续共用 `FileThumbnailView`，补充视频封面提取及系统预览/类型图标回退。文件类型增加常见办公文档、表格、演示、代码、字体、压缩包和媒体扩展名。格式识别不代表所有格式都能由系统解码；失败保留类型图标。
- 下载、收藏、历史的空状态分别使用新插画；生成方式、资源和完整提示词见 `docs/design/empty-state-illustrations.md`。
- 无说明的设置行垂直居中；浏览器工具栏预览地址为 `soulo.dkluge.com`；版本页的图标、名称和版本号直接显示在页面背景上。

## 验证

- iPhone 17 / iOS 26.2 的专用 Soulo QA 模拟器，设备 ID `4EDA06FB-B649-4C6B-9F77-69D7D4A6D292`。
- `build-for-testing` 成功。`BrowsingRefinementTests` 17 项、启动/资源相关 3 项、`SpeechRecognitionServiceTests` 9 项，共 29 项单测通过。最终缓存清理改动后另行重跑壁纸恢复测试通过。
- 新的撤回 UI 用例分别验证分组和卡片视图：关闭真实页面、撤回按钮最前且垂直对齐、点击恢复、管理页面继续显示、关闭管理页后原网页可见。通过。测试使用每次独立的页面标题，防止命中历史记录或另一张同名卡片。
- 原有视频设置/反馈/版本入口 UI 用例通过；移除版本页白底后再次运行通过并检查截图。
- `python3 scripts/check_localization.py --strict`：894 个键、50 个语言全部通过。
- `python3 scripts/export_metadata_json.py --check`：50 个语言与生成文件一致。

## 启动问题的证据和边界

修改前的冷启动调用栈中存在主线程 `WallpaperManager.loadPersistedRemoteWallpaper` / `WallpaperImageDecoder.decode`。修改后两次冷启动日志中，壁纸解码均记录为 `main=false`，耗时约 40–46 ms。诊断仅在 DEBUG 且显式设置 `SOULO_BROWSER_TRACE=1` 时启用，Release 不轮询、不写日志。

目前未在模拟器重现手机上“首页已经显示但整页触摸无响应”的偶发现象。上述改动移除了确认存在的同步工作，不能据此认定已定位全部原因或证明真机问题完全消失。

详细运行产物保存在本机 `/tmp/soulo-startup-20261105/`，包括原始调用栈、前后启动日志、`Verified.xcresult`（29 项单测）、`FinalUI.xcresult`（两项 UI 回归）、`VersionUI.xcresult`（最终版本页截图）及构建日志。
