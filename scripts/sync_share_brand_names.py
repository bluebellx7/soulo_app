#!/usr/bin/env python3
"""Sync sharing footer names from the App Store metadata source files."""

import argparse
import json
import re
from pathlib import Path

from app_store_locales import APP_STORE_LOCALE_NAMES

ROOT = Path(__file__).resolve().parent.parent
PATTERN = re.compile(r'^("page_share_brand"\s*=\s*)"(?:[^"\\]|\\.)*";', re.MULTILINE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report stale names without writing files")
    args = parser.parse_args()
    stale = []
    for locale, label in APP_STORE_LOCALE_NAMES.items():
        name = (ROOT / "fastlane" / "metadata" / label / "name.txt").read_text(encoding="utf-8").strip()
        if not name:
            raise ValueError(f"{label}/name.txt is empty")
        path = ROOT / "Soulo" / f"{locale}.lproj" / "ReadingTools.strings"
        source = path.read_text(encoding="utf-8")
        updated, count = PATTERN.subn(lambda match: match[1] + json.dumps(name, ensure_ascii=False) + ";", source)
        if count != 1:
            raise ValueError(f"{path}: expected exactly one page_share_brand key")
        if updated != source:
            stale.append(locale)
            if not args.check:
                path.write_text(updated, encoding="utf-8")
    if args.check and stale:
        print("Sharing footer names are stale: " + ", ".join(stale))
        print("Run python3 scripts/sync_share_brand_names.py")
        return 1
    print(f"Sharing footer names {'match' if args.check else 'synced from'} App Store metadata ({len(APP_STORE_LOCALE_NAMES)} locales)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
