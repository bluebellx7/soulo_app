# 搜罗 Soulo

Soulo 是一款 iOS 多平台搜索浏览器。输入一次关键词，即可在搜索引擎、视频、社区和第三方 AI 平台之间切换；平台各自提供结果，Soulo 不生成或合并答案。

[官网与导航](https://soulo.dkluge.com/) · [App Store](https://apps.apple.com/app/id6761165330) · [使用说明](docs/USER_GUIDE.md) · [反馈群组](https://t.me/soulobrowser)

## 当前功能

- 搜索、语音输入、网址访问、历史和收藏；按地区或自定义分组组织平台，导入、导出和管理搜索模板。
- 多标签浏览、网站自动分组的重命名与置顶、标签缩略图、恢复关闭标签、桌面模式和无痕浏览；iPad 多窗口分别保存标签会话。
- 广告过滤订阅、手动标记广告、站点开关、跟踪保护与网站权限管理。
- HTTP、流媒体、BT 和 ED2K 下载；本地文件管理、压缩包处理、Wi-Fi 传输和分享。
- 网页、下载和本地媒体共用播放会话，可切换 Soulo 和系统播放器；支持倍速、选集、画中画与投屏，具体能力取决于媒体格式和设备。
- 电子书与网页阅读、网页翻译、长截图、PDF 导出、图片文字识别、用户脚本和 WebExtension 扩展。
- 壁纸、工具栏、首页和快捷操作设置；可选 iCloud **设置**同步与本地设置备份。

主界面、阅读工具与新增功能表均覆盖 50 种语言。独立文案表的覆盖与校对边界见[本地化检查](docs/LOCALIZATION_AUDIT.md)；键完整性检查不能代替语言校对。

历史、收藏、登录数据和下载默认保存在设备上。iCloud 设置同步不包含历史、收藏、缓存、登录数据或下载文件；收藏可通过 HTML 文件单独导入导出。详见[数据范围说明](docs/USER_GUIDE.md#数据同步备份与清除)。

## 开发

- SwiftUI、WKWebView、SwiftData；最低 iOS 17.0。
- `project.yml` 是工程配置源文件。使用 XcodeGen 重新生成 `Soulo.xcodeproj`，不要只改生成的工程设置。
- 第三方播放和下载依赖位于 `ThirdParty/`；使用和构建说明见各目录 README，许可证见 App 内与资源声明。

```sh
xcodegen generate
python3 scripts/check_localization.py --strict
python3 scripts/export_metadata_json.py --check
```

在 Xcode 中选择 `Soulo` scheme 和所需模拟器运行。原生测试位于 `SouloTests/`，界面测试位于 `SouloUITests/`；同一模拟器上的构建和测试应串行执行。历史验证记录保存在 `docs/qa/`。

## 项目目录

| 目录 | 内容 |
| --- | --- |
| `Soulo/Source/App` | App、窗口与场景生命周期 |
| `Soulo/Source/Models` | 搜索、收藏、标签和设置模型 |
| `Soulo/Source/Services` | 浏览、下载、同步、隐私、媒体和阅读服务 |
| `Soulo/Source/ViewModels` | 首页、搜索、网页和设置状态 |
| `Soulo/Source/Views` | 首页、浏览、资料库、阅读播放与设置界面 |
| `Soulo/*.lproj` | App 界面与权限本地化 |
| `SouloShareExtension`、`SouloWidget` | 分享扩展和小组件 |
| `fastlane/metadata` | 50 种语言的 App Store 文案源文件 |
| `website` | 官网静态页面与导航目录，见[网站维护说明](website/README.md) |
| `scripts` | 工程依赖准备、本地化、元数据和网站生成与检查 |

## 发布与维护

商店文案以 `fastlane/metadata/<语言名>/` 为准。版本或商店内容变更后，同步全部语言，再生成 Chrome 扩展使用的 JSON：

```sh
python3 scripts/export_metadata_json.py
python3 scripts/export_metadata_json.py --check
python3 scripts/check_localization.py --strict
```

不要直接修改生成的 `fastlane/app_store_metadata.json`。商店字段限制和版本流程见 [fastlane/README.md](fastlane/README.md) 与 [AGENTS.md](AGENTS.md)。官网发布使用 `bash website/upload.sh`，Git push 与网站部署是两个独立步骤。
