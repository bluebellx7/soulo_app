# Project agent instructions

保留用户现有修改；开始工作前先运行 `git status --short`，只修改和提交当前任务明确涉及的文件。`project.yml` 是 Xcode 工程配置的源文件，修改工程设置后应按项目既有方式重新生成 Xcode 工程。

## 新版本与 App Store 元数据

- `fastlane/metadata/<App Store Connect 中文语言名>/` 是商店文案源文件；`fastlane/app_store_metadata.json` 是 Chrome 扩展使用的生成文件，不要直接手改 JSON。
- 每次准备新版本、修改 `MARKETING_VERSION`，或更新 App Store 发布内容时，必须同步维护全部 50 个语言目录中的 `name.txt`、`subtitle.txt`、`promotional_text.txt`、`description.txt`、`release_notes.txt` 和 `keywords.txt`。
- 文案更新后运行 `python3 scripts/export_metadata_json.py`，再运行 `python3 scripts/export_metadata_json.py --check`。JSON 中的 `app.version` 必须与工程 `MARKETING_VERSION` 一致。
- 同时运行项目原有本地化检查：`python3 scripts/check_localization.py --strict`。不得通过删除语言、复制无关语言或手改生成 JSON 绕过检查。
- App Store 字段上限分别为名称 30、副标题 30、推广文本 170、描述 4000、新增内容 4000、关键词 100。导出器报告的零宽字符等警告必须记录为待人工处理；扩展会跳过该语言，不得让它阻断其余语言。
- 提交或推送版本更新时，应同时包含修改过的 `fastlane/metadata` 源文件和重新生成的 `fastlane/app_store_metadata.json`。
