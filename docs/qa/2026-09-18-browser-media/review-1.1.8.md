# 1.1.8 修改审查与回归（2026-09-18）

逐项阅读本轮 32 个已修改源码、字符串和测试文件的差异及相关调用，保留原有修改。覆盖广告规则解析/编译/编辑、手工标记及点击屏蔽、自动跳转与刷新、长按图片/选区、大图保存/分享、视频工具/横屏、多标签生命周期、首页横屏布局。检查既有 QA 说明和复现脚本。

## 审查补充修复

- 视频检查点改为新 WebView 创建后的一次性恢复：不再将旧进度嵌入每次导航都会执行的脚本。显式重新加载后不会重复恢复旧进度；异步采集增加运行代次校验，避免已释放页面的结果覆盖新状态。
- 页面导航清理旧帧；移除视频节点时释放跟踪集合，重新挂载不重复绑定事件；移除 Shadow DOM 时解除对应观察，减少长页面和多标签的无效引用。
- 文字选择样式排除可编辑区域、输入框、按钮、滑块及其子元素，避免改变编辑器和控件行为。
- 原生图片菜单的保存动作与 HTTP 图片能力一致；跨域图片操作使用来源帧的 Referer，Blob 图片通过大图预览保存和分享。
- 原生播放器横屏入口统一为手机旋转图标。
- 修正拼片广告回归夹具的初始视口同步：等待固定定位元素与当前 innerHeight 一致后命中选择，避免离屏 WebView 挂载期间测试坐标失效。

## 版本与商店文案

`project.yml` 中主 App、Widget、分享扩展均为 1.1.8，build 25。运行 `xcodegen generate` 重新生成工程，并验证编译产物三者版本一致。

维护全部 50 个语言目录的新增内容、推广文本、描述；逐一校验名称、副标题、关键词，保留有效现有内容。共 300 个源字段通过长度和内容检查。由源文件重新导出 `fastlane/app_store_metadata.json`，app.version 为 1.1.8。

通过 `python3 scripts/export_metadata_json.py --check`、`python3 scripts/check_localization.py --strict`（862 keys × 50 locales）、`git diff --check`。导出没有报告零宽字符等待处理警告。

## 测试记录

专用模拟器 Soulo-Media-Review，iPhone 17 Pro / iOS 26.2，设备 ID `C5898DD2-6450-4157-A8E5-99F325FE63DA`。

初轮完整测试 `/tmp/soulo-full-change-review.xcresult`：440 项中 439 项通过；拼片广告视口同步测试失败 4 个断言（1 个用例），随后修正测试夹具。

边界复测 `/tmp/soulo-review-boundaries-2.xcresult`：拼片广告和全部 9 项网页媒体测试通过。新增文字选择测试最初使用 WebKit 未生效的无前缀 user-select 夹具，补充 -webkit-user-select 后在 `/tmp/soulo-selection-review.xcresult` 通过。

1.1.8 全量 `/tmp/soulo-118-full-review.xcresult`：441 项中 440 项通过，唯一失败用例 `ReadingToolsTests.testNativePlaybackActuallyAdvancesAtSupportedRates` 在 0.5× WAV 时钟上出现超时/零增长，产生 2 个失败断言。所有广告、网页交互、图片导入、多标签、网页视频倍速/检查点测试通过；前述拼片视口用例也通过。

隔离复测 `/tmp/soulo-118-native-clock-isolated.xcresult`：上述 WAV 0.5～16× 时钟测试及本地 MP4 0.5× 启动/拖动/续播测试，2 项全部通过。MediaSession.swift 和 ReadingToolsTests.swift 相对 HEAD 均未改动。该间歇失败保留为未消除的测试稳定性问题，不把隔离通过写成全量通过。日志还包含既有模拟器音频和 WebKit 进程警告；未凭警告直接断定根因。

原生界面 `/tmp/soulo-118-native-review.xcresult`：7 项中 6 项通过。已通过真实 pianbs / yinsuw 底部各 3 次点击及反复标记、图片保存/分享、真实 pbpbw 横屏进出、原生播放器横屏及恢复、切换标签续播、36 pt 工具栏对齐和展开/收起动画。

图片放大/复制粘贴用例最初在粘贴菜单定位失败：输入框默认小字号触发 WebKit 聚焦缩放，测试在页面坐标变化期间长按。将测试夹具输入框字号设为 20 px，等待聚焦并在文字起点附近长按；应用代码未为此改动。`/tmp/soulo-118-copy-review.xcresult` 完整操作复测通过，包含图片缩放、受限制网页文字选区、复制及实际粘贴结果检查。7 个关键界面场景至此均有通过记录，不将首轮失败隐去。

本次截图位于 [review-1.1.8](review-1.1.8/)，已检查隐藏广告、图片操作栏、视频图标排列与原生横屏图标。完整测试脚本随 QA 文档保留。

## 验证边界

模拟器与这些站点的当前页面不能覆盖所有设备、媒体编码或网站后续变化。没有承诺固定内存占用或零回归。媒体检查点仅在标签会话内保存，不跨 App 重启；保留上限为最近 3 个 WebView，正在下载的页面受到保护，可能暂时超过上限。

后续下载提示与性能优化见 [performance-followup.md](performance-followup.md)，其中将最近 WebView 保留上限由 3 调整为按设备内存选择 5～8 个。
