# 视频切到其他 App 后暂停

## 行为

- 系统与 Soulo 模式共用 MediaSession 的后台暂停处理，覆盖网页、下载和文件来源。
- App 真正进入后台时暂停普通视频，保留播放位置。返回前台后保持暂停，并沿用上一项修复的全屏方向恢复。
- 加载完成、挂载视频表面、延迟播放和中断结束等回调受后台播放意图约束，避免退后台后又启动视频。
- 本地音乐继续后台播放。手动请求、启动中或已启动的系统画中画，以及已连接的 AirPlay 继续播放；画中画关闭或启动失败后，后台普通视频暂停。
- 关闭自动进入画中画，保留播放器里的手动悬浮窗操作。

使用 [UIApplication.didEnterBackgroundNotification](https://developer.apple.com/documentation/uikit/uiapplication/didenterbackgroundnotification) 区分后台与短暂失去焦点。自动画中画行为依据 [Apple AVKit WWDC21 说明](https://developer.apple.com/videos/play/wwdc2021/10290/) 中的 `canStartPictureInPictureAutomaticallyFromInline` 开关。

## 验证

环境：iPhone 17 模拟器，iOS 26.2，`4EDA06FB-B649-4C6B-9F77-69D7D4A6D292`。

- 构建通过。
- 6 项单元回归通过：系统视频暂停与进度保留、后台加载完成、Soulo 表面晚挂载及播放中暂停、两种模式的后台音乐、主视频表面保护、长按倍速与音频中断及截图。
- 系统画中画控制器在当前模拟器不受支持，画中画实际运行用例依据能力检查跳过，需要支持画中画的真机验证。AirPlay 没有实机接收端验证。
- 实际网页全屏 UI 回归通过：两种模式都在播放中切到系统设置 App，竖持设备后返回；返回仍横屏、播放按钮显示为继续播放，时间及旋转按钮保持可用。
- 返回后的两个模式截图已查看；`git diff --check` 通过。

倍速单元测试在共享播放器整组运行时出现波动、单独运行通过，初步判断受到共享会话状态干扰。改为独立 MediaSession 实例后，同组前置媒体测试之后的全部断言通过。

产物：`/tmp/soulo-player-background-20261105/`。

- `PolicyIsolated.xcresult`、`policy-isolated.log`：最终单元回归，6 通过、1 个画中画能力用例跳过、0 失败。
- `Background.xcresult`、`background.log`：产品代码对应的 UI 回归通过；较早的同包单元结果包含上述已处理的测试失败，不能将整个包视为通过。
- `screenshots/`：两种模式切回后的截图。

未安装到用户真机。版本号与商店元数据未改动。
