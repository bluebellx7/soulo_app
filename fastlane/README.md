# Soulo Fastlane

本目录对应 App Store Connect 版本 **1.1.1（Build 12）**，使用 Fastlane 标准 locale code。

元数据目录只同步四类版本相关字段：

- `name.txt`：App 名称
- `subtitle.txt`：副标题
- `promotional_text.txt`：推广文本
- `release_notes.txt`：1.1.1 新增内容

未放置 `description.txt` 与 `keywords.txt`，因此执行元数据 lane 时会保留 App Store Connect 里已有的描述和关键词。

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

`metadata` 只上传元数据，不上传构建；`beta` 上传 Build 12 到 TestFlight；`release` 上传构建和元数据，但不会自动提交审核。

## 认证

推荐使用 App Store Connect API Key：

```bash
export ASC_KEY_ID="..."
export ASC_ISSUER_ID="..."
export ASC_KEY_FILEPATH="/absolute/path/to/AuthKey_....p8"
```

也可以通过 `FASTLANE_USER` 使用 Apple ID 会话。密钥、密码和 `.p8` 文件不要提交到仓库。

## Locale

| 目录 | App Store locale |
|---|---|
| `en-US` | English (U.S.) |
| `zh-Hans` | 简体中文 |
| `zh-Hant` | 繁體中文 |
| `ja` | 日本語 |
| `ko` | 한국어 |
| `fr-FR` | Français |
| `de-DE` | Deutsch |
| `es-ES` | Español |
| `vi` | Tiếng Việt |
| `pt-BR` | Português (Brasil) |
| `ru` | Русский |
| `tr` | Türkçe |
| `it` | Italiano |
| `ar-SA` | العربية |
| `th` | ไทย |
