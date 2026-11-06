# 全屏播放器前台方向恢复与当前时间

## 改动

- 全屏横屏会话只支持左右两个横屏方向，避免 iOS 返回前台时按竖持设备重建成竖屏。播放器同时监听所属场景的激活通知，在没有设备旋转事件时重新应用方向。
- 系统与 Soulo 模式共用全屏方向按钮，竖屏时可切横屏，横屏时可切竖屏。切换方向保留当前全屏控制器和播放会话；切换解码模式也保留所选方向。
- 手动选择竖屏后移除横屏恢复监听；关闭全屏后清理监听，保留原有页面方向恢复逻辑。
- 横屏控制栏右上角、播放器模式按钮之前显示当前时间，使用系统时间格式，每分钟更新，与控制栏一起显示或隐藏。

场景通知使用 [Apple UIScene.didActivateNotification](https://developer.apple.com/documentation/uikit/uiscene/didactivatenotification)，时间更新使用 [TimelineSchedule.everyMinute](https://developer.apple.com/documentation/swiftui/timelineschedule/everyminute)。

## 验证

环境：iPhone 17 模拟器，iOS 26.2，设备 `4EDA06FB-B649-4C6B-9F77-69D7D4A6D292`。

- Xcode 测试构建通过。
- `IncrementalFeatureTests` 的 5 项方向与模式切换测试通过：前台恢复、手动竖屏、左右横屏、退出清理、同一控制器内切换模式及方向、原浏览页面方向恢复。
- `DownloadPlaybackUITests.testWebFullscreenSwitchesModesAndClosesDirectly` 通过。使用本地网页中的实际视频依次验证系统和 Soulo 模式：横竖屏切换、切到系统设置 App 后竖持设备返回、时间与关闭按钮水平对齐且不与模式按钮重叠、隐藏控制栏同时隐藏时间、点击一次关闭返回网页。
- 两张实际 UI 截图已人工查看，时间和按钮对齐，右下角方向按钮可见。
- `git diff --check` 通过。

首次专项运行中的单元测试向 UIKit 全局通知中心发送了以 `NSObject` 充当场景的无效激活通知，导致测试进程退出。步骤日志已定位到该发送调用；移除此无效模拟后，使用实际 `UIWindowScene` 的前台恢复与清理验证全部通过。产品实现未因此调整。

产物保存在 `/tmp/soulo-player-foreground-20261105/`：

- `build.log`：测试构建通过。
- `Orientation.xcresult`、`orientation.log`：修正测试模拟后的 5 项专项测试全部通过。
- `Regression.xcresult`、`regression.log`：界面测试通过；此较早的结果包同时包含上述已修正的单元测试模拟失败，不能视为整个结果包通过。
- `screenshots/`：两个模式的横屏控制栏截图。

此次没有安装到用户真机；模拟器结果不能替代真机切后台后的体验验收。版本号、工程设置和商店元数据未改动。
