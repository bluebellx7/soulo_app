# Soulo Fastlane

本目录对应 App Store Connect 版本 **1.1.4（Build 18）**。仓库使用 App Store Connect 中文语言名维护 50 个语言目录，上传时会自动导出为 Fastlane 所需的 locale code。

每个语言目录同步以下六类字段：

- `name.txt`：App 名称
- `subtitle.txt`：副标题
- `promotional_text.txt`：推广文本
- `description.txt`：应用描述
- `release_notes.txt`：1.1.4 新增内容
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

`metadata` 只上传元数据，不上传构建；`beta` 上传 Build 18 到 TestFlight；`release` 上传构建和元数据，但不会自动提交审核。

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
