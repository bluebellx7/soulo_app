# 1.2.1 版本与中英文 App Store 素材

输出目录：`/Users/shunfei.z/Desktop/Soulo-AppStore-1.2.1-2026-10-06`。

App、Widget、Share Extension 的 `MARKETING_VERSION` 统一为 1.2.1，构建号为 28。修改 `project.yml` 后已通过 XcodeGen 重新生成工程。检查了 50 个语言目录的名称、副标题、推广文本、描述、更新说明、关键词；所有更新说明同步为 1.2.1，其余仍适用的文案保留。JSON 由 `scripts/export_metadata_json.py` 生成，没有直接编辑。

## 验证

- `python3 scripts/export_metadata_json.py --check`：50 语言通过，JSON 版本为 1.2.1，无零宽字符警告。
- `python3 scripts/check_localization.py --strict`：865 keys × 50 locales 通过。
- unsigned device Release：`/tmp/soulo-store-release-121.log`，`BUILD SUCCEEDED`。编译产物的 App、Widget、Share Extension 均为 1.2.1 (28)。
- UI 采集：专用 iPhone 17 Pro 和 iPad Pro 13 英寸 (M5)，iOS 26.2；中英文正式采集用例通过。iPad 英文采集使用英文系统语言，避免日期混用。
- 英文 iPad 平台页最终重采集：`/tmp/soulo-store-pad-en-platform-native.xcresult`，1 项通过，0 失败，20.899 秒。已逐组查看中英文总览，确认最终平台页、正文和推广排版没有出现遮挡提示或空白采集。
- Duo 预览采集：`AppStoreLayoutPreviewTests/testCaptureDuoLayoutPreviews` 通过，真实 App 视图按指定点尺寸渲染，共六张。它不是 Duo 设备验收。
- 图片检查：28 张指定像素 PNG，无 alpha 或透明度。输出文件的 SHA-256、尺寸和状态记录在素材目录的 `源文件/尺寸与格式检查.json`。
- `git diff --check` 通过。未提交、推送或上传商店；保留此前用户修改。

## 数量与来源

每种语言：标题 1 张 (3840 × 1646)、搜索结果素材 1 张 (1920 × 1280)、iPhone 5 张 (1206 × 2622)、iPad 4 张 (2064 × 2752)、Duo 布局预览 3 张 (1398 × 2034、2007 × 2853、2853 × 2007)。共 22 张正式素材、6 张待替换的 Duo 预览。

原始 UI 截屏保留在输出目录中。`scripts/render_app_store_assets.mjs` 使用 HTML/CSS 排版并嵌入真实 UI 图片，未用 AI 重绘界面。标题与搜索素材使用首页、文件和阅读器，避免将第三方平台图标作为推广主体。平台管理页截屏保留 App 实际显示的界面。文件和阅读示例为本次编写的原创内容，没有使用用户私人数据。

英文 iPad 平台页的初始滚动过多，未保留该画面作为最终素材。重采集时曾选到 sheet 下方首页的 ScrollView；改为 sheet 内滚动后，惯性滚动又导致目标分组离开画面，并遇到 XCTest 等待 App idle。最终采集原生初始分组顺序，避免为推广取景继续调整任意滚动位置。失败记录保留在 `/tmp/soulo-store-pad-en-platform-framed.xcresult` 和 `/tmp/soulo-store-pad-en-platform-container.xcresult`，最终 native 采集单独验收。

## 重做流程

1. 新建名称以 `Soulo Store ` 开头的专用模拟器，安装当前 App；`scripts/app_store_assets.py DEVICE zh-Hans` 或 `en-US` 写入示例文件，只清理该脚本上次生成的示例。
2. 通过 XcodeGen 生成工程并 build-for-testing。在 xctestrun 的 runner 环境中设置 `SOULO_CAPTURE_STORE_ASSETS=1`，运行 `SouloUITests/AppStoreScreenshotUITests/testCaptureChinese` / `testCaptureEnglish`。默认普通测试运行会跳过这些采集用例。
3. 使用 `xcresulttool export attachments` 导出，仅选取以 `store-` 命名的 PNG，按语言和设备放入输出目录的 `源文件/原始截屏`。不复制失败日志或测试录像。
4. 在 Node 环境安装 Playwright；本机渲染使用已安装的 Google Chrome：

   ```bash
   SOULO_PLAYWRIGHT_MODULE=/path/to/node_modules/playwright \
   node scripts/render_app_store_assets.mjs /path/to/output /path/to/Soulo
   ```

5. 查看输出目录的总览与单张图片。Duo 的六张预览保留明确水印和独立目录，不能按正式截屏上传。

## 未完成的 Duo 条件

本机仍为 Xcode 26.2，没有 iOS 27.1 / Duo runtime。需要在真实 Duo 或官方模拟器中采集替换图，并验证实际系统导航、安全区、折叠切换和内外屏布局；当前尺寸检查与自定义窗口渲染不能代替它们。参见 [Duo 适配记录](2026-10-06-iphone-duo.md)。本次没有上传素材到 App Store Connect，也没有制作 App 预览视频。

参考：[Apple Creative assets specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)、[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)、[Asset best practices](https://developer.apple.com/app-store/asset-best-practices/)。
