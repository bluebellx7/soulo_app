# Project agent instructions

保留用户现有修改；开始工作前先运行 `git status --short`，只修改和提交当前任务明确涉及的文件。`project.yml` 是 Xcode 工程配置的源文件，修改工程设置后应按项目既有方式重新生成 Xcode 工程。

## 新版本与 App Store 元数据

- `fastlane/metadata/<App Store Connect 中文语言名>/` 是商店文案源文件；`fastlane/app_store_metadata.json` 是 Chrome 扩展使用的生成文件，不要直接手改 JSON。
- 每次准备新版本、修改 `MARKETING_VERSION`，或更新 App Store 发布内容时，必须同步维护全部 50 个语言目录中的 `name.txt`、`subtitle.txt`、`promotional_text.txt`、`description.txt`、`release_notes.txt` 和 `keywords.txt`。
- 文案更新后运行 `python3 scripts/export_metadata_json.py`，再运行 `python3 scripts/export_metadata_json.py --check`。JSON 中的 `app.version` 必须与工程 `MARKETING_VERSION` 一致。
- 同时运行项目原有本地化检查：`python3 scripts/check_localization.py --strict`。不得通过删除语言、复制无关语言或手改生成 JSON 绕过检查。
- App Store 字段上限分别为名称 30、副标题 30、推广文本 170、描述 4000、新增内容 4000、关键词 100。导出器报告的零宽字符等警告必须记录为待人工处理；扩展会跳过该语言，不得让它阻断其余语言。
- 提交或推送版本更新时，应同时包含修改过的 `fastlane/metadata` 源文件和重新生成的 `fastlane/app_store_metadata.json`。

## 界面文案

菜单和按钮优先使用简短、明确的名称；上下文已经说明对象时省略重复词，避免普通字号下因冗长文案而换行。不要靠缩小字号掩盖文案过长的问题。

## App Store 截图与推广素材

- 用户于 2026-10-07 指定 `/Users/shunfei.z/Desktop/Screenshot/Soulo` 中自己制作的图片为后续风格基准。制作、更新或补充 Soulo 商店素材前，必须查看对应原图和 [截图风格规范](docs/design/app-store-screenshot-style.md)，按这套配色、设备边框、构图、字号和文案层级制作。
- 设备截图沿用灰蓝背景、紫色色块、大幅设备画面和无衬线文字；标题及搜索结果素材沿用白底、黑色粗体标题、浅金色点缀和三台手机叠放的构图。中英文使用同一套视觉样式，分别调整文字断行。
- `scripts/render_app_store_assets.mjs` 当前包含的是此前的历史布局，不能直接作为新素材的默认样式；复用时先按用户参考更新模板。参考原图保留不改，尺寸和设备来源另行验证。
