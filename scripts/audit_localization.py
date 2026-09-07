#!/usr/bin/env python3
"""Audit runtime coverage and compact-label length; never rewrite translations.

Character counts are review hints, not pixel-fit or linguistic accuracy proofs.
Run the native LocalizationLayoutTests for actual font shaping and UI snapshots.
"""
import argparse
import re
from pathlib import Path
from check_localization import APP_STORE_LOCALE_NAMES, ROOT, RESOURCES, load

COMPACT_KEYS = ('bookmarks', 'library_history_tab', 'downloads', 'library_files_tab',
                'library_books_tab', 'share', 'copy_link', 'library', 'home_screen',
                'web_capture', 'web_translate', 'settings_privacy', 'ad_block_subscriptions')
# Product names / terms intentionally shared across languages.
SHARED_TERMS = {'privacy_gpc', 'live_activity', 'web_translate_google', 'wallpaper_bing',
                'wallpaper_pixabay', 'wallpaper_pexels', 'batch_import_action'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'docs/LOCALIZATION_AUDIT.md')
    args = parser.parse_args()
    english = load(RESOURCES/'en.lproj/Localizable.strings')
    tool_english = load(RESOURCES/'en-US.lproj/ReadingTools.strings')
    swift = (RESOURCES/'Source/Services/ReadingTools/ToolText.swift').read_text()
    mapping_source = swift.split('static let sharedKeys = [', 1)[1].split(']', 1)[0]
    shared_keys = dict(re.findall(r'"([^"]+)"\s*:\s*"([^"]+)"', mapping_source))
    rows, english_candidates, long_labels = [], [], []
    for locale, name in APP_STORE_LOCALE_NAMES.items():
        values = load(RESOURCES/f'{locale}.lproj/Localizable.strings')
        tools = load(RESOURCES/f'{locale}.lproj/ReadingTools.strings')
        missing_tools = [key for key in tool_english if key not in tools and shared_keys.get(key) not in values]
        candidates = [] if locale.startswith('en') else [
            key for key, value in values.items()
            if value == english.get(key) and ' ' in value and re.search('[A-Za-z]', value)
            and not key.startswith('platform_') and key not in SHARED_TERMS
        ]
        long = [key for key in COMPACT_KEYS if len(values[key]) > 18]
        rows.append(f'| {name} `{locale}` | {len(values)}/{len(english)} | {len(tool_english)-len(missing_tools)}/{len(tool_english)} | {len(candidates)} | {len(long)} |')
        english_candidates.extend((locale, key, values[key]) for key in candidates)
        long_labels.extend((locale, key, values[key]) for key in long)
    lines = [
        '# 翻译与长度检查', '',
        '生成命令：`python3 scripts/audit_localization.py`。', '',
        '## 检查范围与结论', '',
        '- 覆盖全部 50 种语言的主文案，以及阅读工具独立文案表。商店字段长度由 `check_localization.py --strict` 单独验证。',
        '- 主文案键齐全不代表已完成语言校对；下表同时列出英文候选和工具英文回退。品牌名不按漏译计算。',
        f'- 新增工具只有简体中文、繁体中文和美国英语具有完整独立表。其余 44 种非英语语言各复用 {len(shared_keys)} 个已本地化的通用操作和资料库标签，另外 {len(tool_english) - len(shared_keys)} 项仍回退英文；不能算作完整翻译。其他 3 个英语地区回退英文属于正常显示。',
        '- 紧凑标签超过 18 个 Unicode 码位仅提示复核。阿拉伯文、印度文字、组合字符与拉丁字母的实际宽度不同，不能用字符数直接断言截断。',
        '- 本次修正资料库短标签、过滤列表标题、明显的动词/名词误译，以及隐私与批量导入的英文遗漏；未宣称对 50 种语言的所有长段落完成母语审校。', '',
        '## 覆盖情况', '',
        '| 语言 | 主表键 | 工具表或同义复用 | 英文候选 | 长标签候选 |',
        '| --- | ---: | ---: | ---: | ---: |', *rows, '',
        '## 尚需复核的英文候选', '',
        '荷兰语的 `Open downloads in Soulo.` 同时也是正确的荷兰语表达，属于已确认的同形文案，保留作为检查器的可见候选。', '',
    ]
    if english_candidates:
        lines += ['| 语言 | 键 | 文案 |', '| --- | --- | --- |']
        lines += [f'| `{loc}` | `{key}` | {value.replace("|", " / ")} |' for loc,key,value in english_candidates]
    else:
        lines += ['当前规则未发现候选。该检查不能识别所有语法、语境或单词级漏译。']
    lines += ['', '## 紧凑控件长标签复核清单', '',
              '资料库放不下时横向滚动；全屏动作按空间使用四列或两列，工具栏选项允许换行；破坏性确认说明保持完整。以下文案应结合设备字体继续验收，不应直接截取字符串。', '',
              '| 语言 | 键 | 文案 | 码位数 |', '| --- | --- | --- | ---: |']
    lines += [f'| `{loc}` | `{key}` | {value.replace("|", " / ")} | {len(value)} |' for loc,key,value in long_labels]
    lines += ['', '## 人工验收', '',
              '1. 切换德语、法语、阿拉伯语、泰米尔语和日语，打开资料库，检查五项标签、选中背景和点击切换。',
              '2. 打开自定义浏览器工具栏及全屏下拉面板，检查长名称可完整换行，按钮不互相遮挡。',
              '3. 在系统中放大文字，重复检查；阿拉伯语同时检查从右向左顺序，网址和配对码仍应清晰。',
              '4. 检查广告过滤与隐私页的标题、状态、清除确认；确认文案与实际操作对应。',
              '5. 新增工具其余语言的长段落、专有术语和错误提示仍需完整翻译及母语复核；不要把英文回退当作已验收。', '']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text('\n'.join(lines), encoding='utf-8')
    print(f'50 locales; {len(english_candidates)} English candidates; {len(long_labels)} compact-label review candidates')
    print(args.output)

if __name__ == '__main__':
    main()
