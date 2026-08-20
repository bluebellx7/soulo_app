# App Store 多语言元数据

本目录包含 App Store Connect 支持的全部 **50 个语言/地区**。目录名使用 App Store Connect 中文界面显示的名称，方便直接查找和维护；应用内 `.lproj` 仍使用 Apple locale shortcode。

每个语言目录均包含：

| 文件 | App Store Connect 字段 | 字符上限 |
|---|---|---:|
| `name.txt` | App Name | 30 |
| `subtitle.txt` | Subtitle | 30 |
| `promotional_text.txt` | Promotional Text | 170 |
| `description.txt` | Description | 4000 |
| `release_notes.txt` | What's New | 4000 |
| `keywords.txt` | Keywords | 100 |

中文目录名与官方 shortcode 的对应关系：

```text
阿拉伯语 ar-SA              孟加拉语 bn-BD            加泰罗尼亚语 ca
简体中文 zh-Hans            繁体中文 zh-Hant          克罗地亚语 hr
捷克语 cs                   丹麦语 da                 荷兰语 nl-NL
英语（澳大利亚） en-AU       英语（加拿大） en-CA      英语（英国） en-GB
英语（美国） en-US           芬兰语 fi                 法语 fr-FR
法语（加拿大） fr-CA         德语 de-DE                希腊语 el
古吉拉特语 gu-IN             希伯来语 he               北印度语 hi
匈牙利语 hu                 印度尼西亚语 id           意大利语 it
日语 ja                     卡纳达语 kn-IN            韩语 ko
马来语 ms                   马拉雅拉姆语 ml-IN        马拉地语 mr-IN
挪威语 no                   奥里亚语 or-IN            波兰语 pl
葡萄牙语（巴西） pt-BR       葡萄牙语（葡萄牙） pt-PT  旁遮普语 pa-IN
罗马尼亚语 ro               俄语 ru                   斯洛伐克语 sk
斯洛文尼亚语 sl-SI           西班牙语（墨西哥） es-MX  西班牙语（西班牙） es-ES
瑞典语 sv                   泰米尔语 ta-IN            泰卢固语 te-IN
泰语 th                     土耳其语 tr               乌克兰语 uk
乌尔都语 ur-PK              越南语 vi
```

维护命令：

```bash
python3 scripts/generate_all_localizations.py
python3 scripts/check_localization.py
METADATA_PATH=$(python3 scripts/export_fastlane_metadata.py)
bundle exec fastlane deliver --metadata_path "$METADATA_PATH" --skip_screenshots --skip_binary_upload
```

Fastlane `deliver` 只识别 locale shortcode，因此上传前由导出脚本生成临时兼容目录，不会改变仓库中的中文目录。检查脚本会验证 50 个 locale 的运行时键等集、中文目录名、占位符顺序、权限说明、商店字段完整性和字符上限。
