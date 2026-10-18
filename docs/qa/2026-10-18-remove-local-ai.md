# 移除本地 AI 并归档

- 基准：`d082b2144f6447637392333e900c377f5755518b`，Soulo 1.2.2，最后一个没有本地 AI 模块的主线提交。
- 本地归档 tag：`archive/local-ai-2026-10-18`，指向 `f9893cf5058f32d38c171d334593091bd991caa0`。先将当前 105 个变更文件完整快照到独立提交，再逐个核对 Git 对象与工作文件一致。没有将实验提交加入主线历史；模型权重、生成的框架及构建缓存不入 Git。
- 移除 `Modules/SouloLocalAI`、宿主适配、AI 专用测试和旧实验 QA 文件；原文件保存在归档 tag 中。首页、语音、菜单、工具栏、设置、后台下载和工程配置恢复基准实现，使用原浏览器签名权限并通过 XcodeGen 重新生成工程。
- 保留独立的视频长按倍速提示及其回归测试。已移除的工具栏操作按原按钮位置恢复默认项，保留仍有效的自定义按钮；地址栏未知操作恢复原默认项。
- 源码和生成工程均无本地 AI 包、编译开关或宿主接入引用。签名调试包全部 9 个 Mach-O 文件均无 `lai` / `llama` / `ggml` / `mtmd` 导出符号，无模型文件或 AI 资源包；不再申请 increased-memory-limit，保留原浏览器权限。
- 清理专用模拟器内 672,105,197 字节的 AI 数据和 Mac 上本轮派生的 19,889,470,407 字节 Q4 测试模型。Mac 原有 MiniCPM 模型保留。

## 验证

- 原生回归：10 项通过，覆盖工具栏配置兼容、输入交互、长按倍速恢复及导航后的提示清理。结果：`/tmp/soulo-remove-ai-tests.xcresult`。
- 界面回归：3 项通过，结果为 `/tmp/soulo-remove-ai-ui.xcresult`，检查慢加载时工具栏与多标签、系统设置入口、网页与跨域内嵌视频长按倍速。
- 真实网页：Swift 官方文档渲染、更多菜单及标签按钮可操作，用例通过；结果 `/tmp/soulo-remove-ai-real-web.xcresult`，[界面截图](2026-10-18-remove-local-ai/swift-page.png)。合计 14 项原生和界面回归通过。
- 签名 Debug 真机包：构建通过。路径：`/tmp/soulo-remove-ai-device/Build/Products/Debug-iphoneos/Soulo.app`。
- Release 构建通过，日志：`/tmp/soulo-remove-ai-release.log`。
- 严格本地化检查 877 键 × 50 语言通过；50 语言商店元数据检查通过；版本及商店文案未改变。

## 连接的 iPhone

安装工具报告 `kAMDMobileImageMounterDeviceLocked`，已请求解锁。当前不能将代码恢复或模拟器验证说成真机已经覆盖安装。恢复包会覆盖安装到原应用，保留浏览数据；独立的 `Soulo AI Check` 测试应用及其数据待设备可访问后清理。

需要恢复实验代码时，可从归档 tag 新建工作树：

```sh
git worktree add --detach ../Soulo-AI-archive archive/local-ai-2026-10-18
```
