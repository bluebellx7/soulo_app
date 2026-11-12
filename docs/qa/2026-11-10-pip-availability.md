# 小播放器画中画按钮误置灰

2026-11-10，Soulo 1.2.11 (51)。用户截图标出的是小播放器中的系统画中画按钮。

## 原因

`FileMediaPlaybackView` 可以在系统解码兼容性检测完成前启动 Soulo 播放器。此时 `nativeAvailable` 还是 `nil`，生成的 `systemAvailable` 为 `false`。`MatroskaPlayback.open` 将这个初始值写进 `MediaSession.souloSystemAvailable`，后续页面检测通过时没有同步更新共享会话。小播放器依据这个旧值禁用画中画按钮；返回列表过快、原页面任务被取消时，也可能一直保留错误的初始状态。

新增的确定性回归在修改前复现：同一个 Soulo 播放对象的兼容性从 false 改为 true，小播放器共享状态仍不更新。

## 修改

- 系统兼容性与检测中状态由共享会话发布，页面确认结果后同步给当前播放对象，无需重启解码器。
- 区分“检测中”和“已确认不可用”。本地文件的未完成检测由共享会话持有，离开播放页后仍可完成；仅使用本地文件检查，不增加公网请求。
- 停止、切换播放对象、切回系统播放器及收到明确结果时取消旧检测，旧播放对象的结果不能修改当前状态。
- 小播放器检测期间显示加载状态，确认兼容后恢复按钮。保留项目现有系统解码检查；需要 Soulo 解码的格式不会被直接放行。

## 验证

- `/tmp/soulo-pip-availability-20261110/baseline.xcresult`：新增状态同步回归失败，符合修改前复现预期。
- `fixed.xcresult`：4 项通过、0 失败、1 项跳过。包括状态后续更新且不重启播放器、离开文件页后继续完成检查、H.264 MP4 兼容 / 项目判定需扩展解码的 HEVC `hev1` MP4 保持不可用、小播放器不能抢占主画面，以及既有双播放器点击/拖动/续播界面回归。
- 此 iPhone 17 / iOS 26.2 模拟器的 `AVPictureInPictureController.isPictureInPictureSupported()` 返回 false；实际画中画测试据此跳过。界面用例的画中画按钮检查也受这个系统条件限制，不能把其通过表述为已在模拟器启动画中画。
- `python3 scripts/check_localization.py --strict` 和 `git diff --check` 通过。界面使用已有 50 语言的加载文案，没有新增商店文案或版本变更。

连接 iPhone 的设备检查两次返回 `passcodeRequired: true`。已请求解锁，Debug 真机测试包构建成功（`TEST BUILD SUCCEEDED`，命令行使用项目现有 `DEVELOPMENT_TEAM=7S2LBJA9VA`，未修改工程签名设置）。截至构建结束仍为锁屏状态，未安装运行该测试包，实际画中画启动尚未验证。本轮临时产物在 `/tmp/soulo-pip-availability-20261110/`，日志为 `/tmp/soulo-pip-availability-*-20261110.log`。
