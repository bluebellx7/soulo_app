# iPhone Duo 适配准备（2026-10-06）

状态：已完成当前 SDK 可编译、可测试的基础适配；**尚未完成 Duo 专项验收或生成商店截屏**。

## 官方要求与本机环境

- Apple 的 [适配入口](https://developer.apple.com/iphone-duo/) 和 [技术指南](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)要求根据视图、窗口尺寸调整布局，处理内外屏切换和不对称安全区。使用 Xcode 27.1 / iOS 27.1 SDK 构建才能启用完整的新屏幕体验。
- [2026-10-05 公告](https://developer.apple.com/news/?id=kkphp5qo)说明自 2027 年 4 月起提交 App 需要提供 Duo 截屏。
- 本机为 macOS 26.3.1、Xcode 26.2，只有 iOS 26.2 SDK/runtime；`simctl list devicetypes` 中没有 Duo。没有用自定义窗口截图冒充 Duo 截屏。
- 工程已支持 iPhone / iPad、多窗口、横屏和竖屏，没有 `UIRequiresFullScreen` 限制。本次保持版本 1.2.0（27），未调整 deployment target，也未修改商店文案。

## 已处理

- 首页搜索区使用同一视图层级；窗口缩小、尺寸类别切换时不重建输入框。可用高度足够时居中，不足时滚动；宽窗口限制搜索内容宽度。
- 壁纸保存使用编辑画布尺寸和当前显示比例，按与预览一致的 aspect-fill、缩放、位移绘制。修复宽窗口下按主屏幕高度计算导致的裁剪偏差和黑边。
- 阅读亮度从阅读器所在窗口读取显示屏，内外屏改变时更新目标。反馈诊断包含反馈页面所属显示屏和窗口尺寸，不从任意前台 scene 取值。
- 网页长截图采用 WKWebView 的显示比例。网页全屏保留两侧安全区，工具栏及视频底部避让采用页面自己的窗口。
- 增加 `scripts/check_iphone_duo_screenshots.py`，检查尺寸、文件格式、alpha 通道、每组图片数量。没有截图时明确失败。

## 验证

- iPhone 17 Pro / iOS 26.2 专用 QA 模拟器上的最终合跑：`AdaptiveWindowTests` + `WebViewModelTests` **79 项通过、0 失败、0 跳过**。包含输入框焦点/文字/选区保持、不对称左右安全区、当前窗口诊断、壁纸导出像素检查及网页截图回归。
- 偏好和反馈检查：15 项通过；阅读、网页、工具栏和视频全屏检查：113 项通过（109 单元测试 + 4 UI 测试）。这些与最终合跑有重叠，不相加作为独立用例数量。
- 最后调整页面窗口安全区来源后，慢页面工具栏 UI 用例再次通过。已查看普通 iPhone 首页及阅读器的测试截图，未见此次改动引入的裁切；这些不是 Duo 截图。
- unsigned device Release 编译通过（`/tmp/soulo-duo-release-20261006.log`）；`git diff --check` 通过。
- 截屏检查器的 5 项测试通过；真实 Duo 截屏检查当前按预期以 exit 1 退出，因为没有 Duo 截图，不代表素材已就绪。
- 生成元数据检查通过：50 个语言；严格本地化检查通过：865 keys × 50 locales。

原始 xcresult 摘要及失败记录见 [validation.json](2026-10-06-iphone-duo/validation.json)。

最终合跑命令（使用本机现有 QA 模拟器）：

```bash
xcodebuild test -project Soulo.xcodeproj -scheme Soulo \
  -destination 'platform=iOS Simulator,id=FE8ED7B2-0818-46A7-AC9C-051B058C7148' \
  -parallel-testing-enabled NO \
  -only-testing:SouloTests/AdaptiveWindowTests \
  -only-testing:SouloTests/WebViewModelTests
```

测试夹具曾在合跑时触发一次可重复的 SwiftData 崩溃：布局测试结束后，历史测试的 `context.save()` 通知触发 `_SwiftData_SwiftUI` 观察器；SwiftData 栈在加载已释放容器的弱引用后触发断言。仅卸载界面不能解决，历史测试独立运行通过。将新布局测试的内存容器改为与正式 App 的 WindowGroup 一致的长生命周期后，完整 79 项合跑通过。保留了失败摘要，没有跳过历史用例，也没有修改历史服务或历史测试来绕过问题。

## Xcode 27.1 / Device Hub 中的待验收项

以下不能由 iOS 26.2 上的窗口尺寸测试替代：

1. 用 iOS 27.1 SDK 重编译，检查内外屏闭合、展开、部分折叠、帐篷姿态及横竖切换；关注 WKWebView、PDF/EPUB 阅读器和扫描器是否连续保持页面、输入、阅读及播放位置。
2. 检查系统竖向导航和工具栏、居中/侧边 sheet、弹出菜单在外屏和 Split View 左右两侧的显示与点击。
3. 使用 `ReservedRegion` / `ArrangementView` 等新 SDK 能力，按实际表现调整自定义首页和浏览器控件的折叠区避让。本次没有在旧 SDK 下加入无法编译验证的新 API。
4. 验证视频全屏进出、旋转及内外屏切换，退出后应跟随当前窗口；不能只以传统手机的“恢复竖屏”判定 Duo 内屏。
5. 验证正在下载或播放时折叠、切后台再返回；确认状态连续、按钮可点击、下载进度继续。
6. 获取真实 Duo 截屏，运行下面的检查，再在 App Store Connect 的资源库与产品页预览中检查并上传。当前 Fastlane 的 `metadata` / `release` 使用 `skip_screenshots: true`，不会上传这些图片。

## 商店截屏

Apple [截屏规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)（2026-10-06 核实）：

| 显示屏 | 竖向像素 | 横向像素 |
| --- | --- | --- |
| 外屏 | 1398 × 2034 | 2034 × 1398 |
| 内屏 | 2007 × 2853 | 2853 × 2007 |

PNG 或 JPEG，不能含 alpha 通道；每种设备尺寸最多 10 张。建议准备内外屏各一组，作为项目验收标准；检查器默认不将“两个屏都必须上传”误作 Apple 的要求。不能将旧设备截图拉伸到这些尺寸。

存放方式（该目录已在 `.gitignore` 中忽略）：

```text
fastlane/screenshots/iphone-duo/en-US/01-home-outer.png
fastlane/screenshots/iphone-duo/en-US/02-browser-inner.png
fastlane/screenshots/iphone-duo/zh-Hans/01-home-outer.png
```

```bash
python3 scripts/check_iphone_duo_screenshots.py --require-both
python3 -m unittest discover -s scripts/tests -p test_iphone_duo_screenshots.py
```

检查器只检查已提供语言的文件格式和尺寸，不能验证页面内容、设备来源或 App Store 上传完成状态；也不会生成、缩放或上传图片。
