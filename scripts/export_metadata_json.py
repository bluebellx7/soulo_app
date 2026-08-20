#!/usr/bin/env python3
"""Export Fastlane metadata into the JSON consumed by ASC Metadata Relay."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
METADATA_ROOT = ROOT / "fastlane" / "metadata"
OUTPUT_PATH = ROOT / "fastlane" / "app_store_metadata.json"
APP_ID = "6761165330"

LOCALE_NAMES = OrderedDict([
    ("ar-SA", ("阿拉伯语", "Arabic")),
    ("bn-BD", ("孟加拉语", "Bengali")),
    ("ca", ("加泰罗尼亚语", "Catalan")),
    ("zh-Hans", ("简体中文", "Chinese (Simplified)")),
    ("zh-Hant", ("繁体中文", "Chinese (Traditional)")),
    ("hr", ("克罗地亚语", "Croatian")),
    ("cs", ("捷克语", "Czech")),
    ("da", ("丹麦语", "Danish")),
    ("nl-NL", ("荷兰语", "Dutch")),
    ("en-AU", ("英语（澳大利亚）", "English (Australia)")),
    ("en-CA", ("英语（加拿大）", "English (Canada)")),
    ("en-GB", ("英语（英国）", "English (U.K.)")),
    ("en-US", ("英语（美国）", "English (U.S.)")),
    ("fi", ("芬兰语", "Finnish")),
    ("fr-FR", ("法语", "French")),
    ("fr-CA", ("法语（加拿大）", "French (Canada)")),
    ("de-DE", ("德语", "German")),
    ("el", ("希腊语", "Greek")),
    ("gu-IN", ("古吉拉特语", "Gujarati")),
    ("he", ("希伯来语", "Hebrew")),
    ("hi", ("北印度语", "Hindi")),
    ("hu", ("匈牙利语", "Hungarian")),
    ("id", ("印度尼西亚语", "Indonesian")),
    ("it", ("意大利语", "Italian")),
    ("ja", ("日语", "Japanese")),
    ("kn-IN", ("坎纳达语", "Kannada")),
    ("ko", ("韩语", "Korean")),
    ("ms", ("马来语", "Malay")),
    ("ml-IN", ("马拉雅拉姆语", "Malayalam")),
    ("mr-IN", ("马拉地语", "Marathi")),
    ("no", ("挪威语", "Norwegian")),
    ("or-IN", ("奥里亚语", "Odia")),
    ("pl", ("波兰语", "Polish")),
    ("pt-BR", ("葡萄牙语（巴西）", "Portuguese (Brazil)")),
    ("pt-PT", ("葡萄牙语（葡萄牙）", "Portuguese (Portugal)")),
    ("pa-IN", ("旁遮普语", "Punjabi")),
    ("ro", ("罗马尼亚语", "Romanian")),
    ("ru", ("俄语", "Russian")),
    ("sk", ("斯洛伐克语", "Slovak")),
    ("sl-SI", ("斯洛文尼亚语", "Slovenian")),
    ("es-MX", ("西班牙语（墨西哥）", "Spanish (Mexico)")),
    ("es-ES", ("西班牙语（西班牙）", "Spanish (Spain)")),
    ("sv", ("瑞典语", "Swedish")),
    ("ta-IN", ("泰米尔语", "Tamil")),
    ("te-IN", ("泰卢固语", "Telugu")),
    ("th", ("泰语", "Thai")),
    ("tr", ("土耳其语", "Turkish")),
    ("uk", ("乌克兰语", "Ukrainian")),
    ("ur-PK", ("乌尔都语", "Urdu")),
    ("vi", ("越南语", "Vietnamese")),
])

SOURCE_FILES = OrderedDict([
    ("name", "name.txt"),
    ("subtitle", "subtitle.txt"),
    ("promotionalText", "promotional_text.txt"),
    ("description", "description.txt"),
    ("whatsNew", "release_notes.txt"),
    ("keywords", "keywords.txt"),
])
FIELD_LIMITS = {
    "name": 30,
    "subtitle": 30,
    "promotionalText": 170,
    "description": 4000,
    "whatsNew": 4000,
    "keywords": 100,
}
FORBIDDEN_INVISIBLE_CHARACTERS = {
    "\u00ad": "SOFT HYPHEN",
    "\u200b": "ZERO WIDTH SPACE",
    "\u2060": "WORD JOINER",
    "\ufeff": "ZERO WIDTH NO-BREAK SPACE",
}


def project_version() -> str:
    project_yml = ROOT / "project.yml"
    if project_yml.is_file():
        match = re.search(
            r"^\s*MARKETING_VERSION:\s*[\"']?([^\"'\s#]+)",
            project_yml.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        if match:
            return match.group(1)

    for project_file in sorted(ROOT.glob("**/*.xcodeproj/project.pbxproj")):
        match = re.search(
            r"MARKETING_VERSION\s*=\s*([^;]+);",
            project_file.read_text(encoding="utf-8"),
        )
        if match:
            return match.group(1).strip().strip('"')
    raise RuntimeError("MARKETING_VERSION was not found in project.yml or project.pbxproj")


def metadata_directory(locale: str, chinese_name: str) -> Path | None:
    for candidate in (METADATA_ROOT / chinese_name, METADATA_ROOT / locale):
        if candidate.is_dir():
            return candidate
    return None


def read_field(directory: Path, filename: str) -> str:
    path = directory / filename
    if not path.is_file():
        raise RuntimeError(f"missing metadata file: {path.relative_to(ROOT)}")
    value = path.read_text(encoding="utf-8").replace("\r\n", "\n").strip()
    if not value:
        raise RuntimeError(f"empty metadata file: {path.relative_to(ROOT)}")
    return value


def build_payload() -> tuple[dict, list[str]]:
    if not METADATA_ROOT.is_dir():
        raise RuntimeError("fastlane/metadata does not exist")

    locales = []
    warnings: list[str] = []
    for locale, (chinese_name, english_name) in LOCALE_NAMES.items():
        directory = metadata_directory(locale, chinese_name)
        if directory is None:
            continue
        fields = {
            field: read_field(directory, filename)
            for field, filename in SOURCE_FILES.items()
        }
        for field, limit in FIELD_LIMITS.items():
            if len(fields[field]) > limit:
                raise RuntimeError(
                    f"{directory.name}/{SOURCE_FILES[field]} is {len(fields[field])} "
                    f"characters; limit is {limit}"
                )
            invalid = sorted({
                FORBIDDEN_INVISIBLE_CHARACTERS[character]
                for character in fields[field]
                if character in FORBIDDEN_INVISIBLE_CHARACTERS
            })
            if invalid:
                warnings.append(
                    f"{locale}.{field} contains {', '.join(invalid)}; "
                    "the extension will leave it for manual processing"
                )
        locales.append({
            "locale": locale,
            "appStoreConnectNames": [chinese_name, english_name],
            "fields": fields,
        })

    if not locales:
        raise RuntimeError("no recognized locale directories found in fastlane/metadata")
    if len(locales) != len(LOCALE_NAMES):
        warnings.append(
            f"JSON contains {len(locales)} locale(s), not the complete {len(LOCALE_NAMES)}"
        )
    if APP_ID == "0":
        warnings.append(
            "app.id is the temporary value 0; replace APP_ID after creating the "
            "App Store Connect record, then regenerate before using the extension"
        )

    version = project_version()
    payload = {
        "schemaVersion": 1,
        "app": {
            "id": APP_ID,
            "platform": "ios",
            "version": version,
            "appStoreConnectUrl": (
                f"https://appstoreconnect.apple.com/apps/{APP_ID}/"
                "distribution/ios/version/inflight"
            ),
        },
        "fieldLimits": FIELD_LIMITS,
        "locales": locales,
    }
    return payload, warnings


def serialized(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify that the committed JSON matches its metadata and project version",
    )
    args = parser.parse_args()

    try:
        payload, warnings = build_payload()
        expected = serialized(payload)
        if args.check:
            if not OUTPUT_PATH.is_file():
                raise RuntimeError(f"missing generated file: {OUTPUT_PATH.relative_to(ROOT)}")
            if OUTPUT_PATH.read_text(encoding="utf-8") != expected:
                raise RuntimeError(
                    "generated JSON is stale; run python3 scripts/export_metadata_json.py"
                )
            action = "Verified"
        else:
            OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
            OUTPUT_PATH.write_text(expected, encoding="utf-8")
            action = "Exported"
    except RuntimeError as error:
        print(f"[app-store-metadata] error: {error}", file=sys.stderr)
        return 1

    print(
        f"[app-store-metadata] {action} {len(payload['locales'])} locale(s) "
        f"at {OUTPUT_PATH.relative_to(ROOT)}"
    )
    for warning in warnings:
        print(f"[app-store-metadata] warning: {warning}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
