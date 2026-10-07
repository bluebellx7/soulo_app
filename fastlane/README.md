# Soulo Fastlane

当前工程版本为 **1.2.1（Build 28）**。Fastlane 从 `project.yml` 读取版本，不再单独写死版本号。仓库使用 App Store Connect 中文语言名维护 50 个语言目录，上传时会自动导出为 Fastlane 所需的 locale code。

每个语言目录同步以下六类字段：

- `name.txt`：App 名称
- `subtitle.txt`：副标题
- `promotional_text.txt`：推广文本
- `description.txt`：应用描述
- `release_notes.txt`：当前版本新增内容
- `keywords.txt`：关键词

## 使用

Fastlane 2.237.0 的当前锁定依赖需要 Ruby 3.2 或更高版本。本机如仍显示 macOS 自带的 Ruby 2.6，可使用 Homebrew Ruby：

```bash
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
bundle install
bundle exec fastlane ios tests
bundle exec fastlane ios metadata
bundle exec fastlane ios beta
bundle exec fastlane ios release
```

`metadata` 只上传元数据，不上传构建；`beta` 上传工程当前 Build 到 TestFlight；`release` 上传构建和元数据，但不会自动提交审核。各上传流程会先检查 50 种语言的元数据、生成 JSON 与工程版本是否一致，以及本地化是否完整。

## 认证

推荐使用 App Store Connect API Key：

```bash
export ASC_KEY_ID="..."
export ASC_ISSUER_ID="..."
export ASC_KEY_FILEPATH="/absolute/path/to/AuthKey_....p8"
```

也可以通过 `FASTLANE_USER` 使用 Apple ID 会话。密钥、密码和 `.p8` 文件不要提交到仓库。

## Locale

完整的 50 种语言与 locale 对照见 `metadata/README.md`。上传前可运行：

```bash
python3 scripts/export_metadata_json.py
python3 scripts/export_metadata_json.py --check
python3 scripts/check_localization.py --strict
```

## iPhone Duo 截屏

Duo 基础适配与待验收项见 [适配记录](../docs/qa/2026-10-06-iphone-duo.md)。完整验收和截图需要 Xcode 27.1 或更高版本的 Duo Device Hub / 实机。

将真实截图按语言放入 `fastlane/screenshots/iphone-duo/<locale>/`，上传前运行：

```bash
python3 scripts/check_iphone_duo_screenshots.py --require-both
```

`--require-both` 是项目建议的内外屏验收检查。当前 `metadata` 和 `release` 流程跳过截屏，检查通过后仍需在 App Store Connect 上传并预览；生成的 `app_store_metadata.json` 不包含截屏。
