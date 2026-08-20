#!/usr/bin/env python3
"""Validate Soulo's 50 runtime and App Store localizations."""
import re, sys
from pathlib import Path
from app_store_locales import APP_STORE_LOCALE_NAMES

ROOT=Path(__file__).resolve().parent.parent; RESOURCES=ROOT/"Soulo"; METADATA=ROOT/"fastlane"/"metadata"
PATTERN=re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;',re.M)
PLACEHOLDER=re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGcCsSpaA%]')
FILES=("name.txt","subtitle.txt","promotional_text.txt","description.txt","release_notes.txt","keywords.txt")
LIMITS={"name.txt":30,"subtitle.txt":30,"promotional_text.txt":170,"description.txt":4000,"release_notes.txt":4000,"keywords.txt":100}
def load(path): return dict(PATTERN.findall(path.read_text(encoding="utf-8"))) if path.exists() else {}
def main():
    errors=[]; english=load(RESOURCES/"en.lproj"/"Localizable.strings")
    for locale,label in APP_STORE_LOCALE_NAMES.items():
        values=load(RESOURCES/f"{locale}.lproj"/"Localizable.strings")
        if set(values)!=set(english): errors.append(f"{locale}: key parity {len(values)}/{len(english)}")
        for key,source in english.items():
            if PLACEHOLDER.findall(values.get(key,""))!=PLACEHOLDER.findall(source): errors.append(f"{locale}:{key}: placeholders")
        if len(load(RESOURCES/f"{locale}.lproj"/"InfoPlist.strings"))!=6: errors.append(f"{locale}: InfoPlist")
        for filename in FILES:
            path=METADATA/label/filename
            if not path.exists() or not path.read_text(encoding="utf-8").strip(): errors.append(f"{label}/{filename}: missing"); continue
            if len(path.read_text(encoding="utf-8").strip())>LIMITS[filename]: errors.append(f"{label}/{filename}: too long")
    actual={p.name for p in METADATA.iterdir() if p.is_dir()}; expected=set(APP_STORE_LOCALE_NAMES.values())
    if actual!=expected: errors.append(f"metadata directories mismatch: missing={expected-actual}, extra={actual-expected}")
    print(f"[soulo/l10n] {len(english)} keys × {len(APP_STORE_LOCALE_NAMES)} locales")
    if errors:
        print("\n".join("ERROR "+x for x in errors[:100])); return 1
    print("[soulo/l10n] all checks passed"); return 0
if __name__=="__main__": sys.exit(main())
