# 网页图片、选区、视频与多标签回归

最新下载提示与性能优化记录见 [performance-followup.md](performance-followup.md)。最近页面保留上限现为按设备内存选择 5～8 个，以下 3 个为此前测试记录。

测试设备：独立 iPhone 17 Pro / iOS 26.2 模拟器 `AF2D4A20-E053-4893-BE57-09F976E3E2D8`。

- 主工程 216 项相关测试全部通过：`/tmp/soulo-browser-full-regression.xcresult`。
- 收起工具栏改动后，17 项视频、标签测试全部通过：`/tmp/soulo-collapsed-controls-unit.xcresult`。
- 本地化严格检查（50 语言）及 `git diff --check` 通过。
- 真实视频测试核对后台暂停、切回续播、释放 WebView 后恢复进度及 1.5 倍速，并确认用户手动暂停的视频恢复后不会自动播放。
- 20 标签场景验证保留最近 3 个标签；内存告警释放后台页，保留标签记录。正在下载的标签受保护，可能暂时超过保留上限。没有承诺真实设备上的固定内存占用。

原生 UI 测试源见 `BrowserInteractionUITests.swift.txt`。测试 HTML 由 Python HTTP server 在 8917 端口提供，127.0.0.1 与 localhost 用作不同源。复制项目现有 `Soulo/Assets.xcassets/IllustrationBooks.imageset/illustration.png` 为 `qa-image.png`，复制 `SouloTests/ReadingFixtures/playback-h264-aac.mp4` 为 `video.mp4`。用 `ffmpeg -stream_loop 9 -i video.mp4 -c copy video-long.mp4` 生成标签切换测试的长视频；原片仅 8 秒，不能跳到第 8 秒后检测续播。

已验证普通与跨域 Blob 图片原生长按菜单、可缩放预览；视频下载落盘，57,685 字节（最终以实测日志为准），SHA-256 与源文件一致。真实 pbpbw 播放器横屏进入和退出已验证。

实现边界：媒体检查点只保存在标签内存中，不跨应用重启持久化；点播恢复依赖站点继续提供同一可定位媒体。图片或画布里的文字仍需图像文字识别，文本选区保留输入框、原生播放器的正常交互。


原生回归结果：
- `/tmp/soulo-interaction-native-final.xcresult` 中跨域 HTTP/Blob 图片预览与下载已通过；其中复制用例定位菜单项类型错误、标签用例误跳到 8 秒视频末尾，测试已修正后重跑。
- `/tmp/soulo-collapsed-controls-native.xcresult` 中原生图片缩放→长按文字→复制→粘贴、真实 pbpbw 横屏、默认折叠/展开/外部点击收起通过。
- `/tmp/soulo-collapsed-controls-followup.xcresult` 中下载、倍速/横屏及真实新建/切回标签的续播全部通过。新标签由 App 的标签按钮显式创建，避免网页 target=_blank 根据用户偏好在当前页打开。
- 最新外观为 36 pt 按钮、18 pt 图标；三个动作的图标居中，倍速值在选择面板显示；默认入口为自绘播放+调节组合图标。

最新尺寸与组合图标的原生验证：`/tmp/soulo-video-tools-compact-final.xcresult`，2 项通过；核对默认折叠、展开后三个按钮同一中心线、按钮宽度不超过 38 pt、点击外部收起、倍速与横屏进出。最新截图已替换为该版本。


工具栏动效：固定右侧锚点，宽度在 36 / 144 pt 之间用 220 ms 曲线过渡，图标 140 ms 淡入淡出并轻移 6 px。收起时立即取消隐藏动作的命中与键盘焦点，避免动画期间误触；跟随 prefers-reduced-motion 并支持实时变更。测试页以 requestAnimationFrame 采样原生点击后的实际宽度，验证展开与收起均出现中间帧。

新增大图操作与手机旋转图标：
- 新建并启动 `Soulo-Media-Review`，iPhone 17 Pro / iOS 26.2，设备 ID `C5898DD2-6450-4157-A8E5-99F325FE63DA`；关闭旧的专用 QA 模拟器。
- 大图底部加入保存到照片、系统分享；预览下载的原图会保留到预览及保存/分享结束，兼容跨域 Blob 图片；原图文件命名为 Image + 实际扩展名。照片导入继续使用原有格式识别与兼容转换逻辑。
- 新模拟器实际保存 PNG 2,009,375 字节；DCIM 文件 SHA-256 与测试原图一致：`cb6230e4903a74308b9c5c7cf32f1e9b4b739cefbb5bb6c942cd0a517e979e45`。
- `/tmp/soulo-media-actions-native-final.xcresult` 中保存、分享和倍速选择/横屏进出通过；工具栏外部文字点击收起未通过，随后补充 touchstart 收起路径并修正按钮点击背景残留。
- `/tmp/soulo-image-actions-ready.xcresult` 中 4 项图片导入测试全部通过。新模拟器真实视频时钟单元测试仍出现不稳定：playbackRate 为 2，但一次时钟近 1 倍、另一次停止；保留失败记录，不将属性值改变当作播放速度已验证。

触摸定位结论：测试使用 StaticText.tap() 时，事件记录没有收到页面文字处的 pointerdown / touchstart / click。改为文字中心的屏幕坐标点击后，`/tmp/soulo-media-touch-point.xcresult` 通过，包含两方向动画中间帧、按钮对齐及外部点击收起。不要为测试假象增加拦截页面触摸的逻辑。

`/tmp/soulo-media-event-trace.xcresult` 中实际 App 界面设置 2× 后，通过两秒间隔的视频进度增长验证（增长超过 3 秒），确认播放时钟实际提速；前述独立单元测试的不稳定仍保留记录。

最终原生回归：`/tmp/soulo-media-delivery.xcresult`，4 项全部通过：
- 跨域 Blob 大图保存、成功提示及系统分享面板；
- 真实 pbpbw 播放器手机旋转图标、横屏进入/退出；
- 实际 App 选择 2× 后的视频进度增长；
- 干净测试页默认折叠、36 pt 同行图标、展开/收起中间帧、关闭后动作不可见、屏幕坐标点击外部收起。

最新截图更新至该结果。独立单元测试中的短片时钟不稳定未隐藏，不能把此次原生界面回归通过表述成全部单元测试通过。50 语言本地化严格检查与 git diff --check 通过。


1.1.8 的逐项审查、补充修复及最新回归结果见 [review-1.1.8.md](review-1.1.8.md)。全量 441 项中 440 项通过，唯一失败为既有本地 WAV 0.5× 时钟的间歇性测试；隔离复测通过，仍保留失败记录。7 个关键原生 UI 场景均有通过记录。
