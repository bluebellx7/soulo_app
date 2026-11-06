#!/usr/bin/env python3
"""Validate Soulo's 50 runtime and App Store localizations."""
import json, re, sys
from collections import Counter
from pathlib import Path
from app_store_locales import APP_STORE_LOCALE_NAMES
from feature_localization_keys import source_keys

ROOT=Path(__file__).resolve().parent.parent; RESOURCES=ROOT/"Soulo"; METADATA=ROOT/"fastlane"/"metadata"
PATTERN=re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;',re.M)
PLACEHOLDER=re.compile(r'%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGcCsSpaA%]')
FILES=("name.txt","subtitle.txt","promotional_text.txt","description.txt","release_notes.txt","keywords.txt")
LIMITS={"name.txt":30,"subtitle.txt":30,"promotional_text.txt":170,"description.txt":4000,"release_notes.txt":4000,"keywords.txt":100}
FEATURE_TERMS=("Soulo", "Apple", "iPad", "HTML", "Command-L", "Command-T", "Command-W",
               "Command-Shift-T", "Command-R", "Command-F", "Command-N")
def load(path): return dict(PATTERN.findall(path.read_text(encoding="utf-8"))) if path.exists() else {}
def main():
    errors=[]; english=load(RESOURCES/"en.lproj"/"Localizable.strings")
    tool_english=load(RESOURCES/"en-US.lproj"/"ReadingTools.strings")
    feature_english=load(RESOURCES/"en-US.lproj"/"FeatureImprovements.strings")
    feature_keys={json.loads('"'+key+'"') for key in feature_english}
    missing_feature_keys=source_keys(RESOURCES/"Source")-feature_keys
    if missing_feature_keys: errors.append("FeatureImprovements source keys missing: "+", ".join(sorted(missing_feature_keys)))
    # Independent reading/playback labels are part of every supported locale,
    # not optional English fallbacks hidden by a green main-table check.
    for path in RESOURCES.glob("*.lproj/*.strings"):
        entries=PATTERN.findall(path.read_text(encoding="utf-8"))
        duplicates=[key for key,count in Counter(key for key,_ in entries).items() if count>1]
        if duplicates: errors.append(f"{path.relative_to(RESOURCES)}: duplicate keys {duplicates}")
        for key,value in entries:
            if not value.strip(): errors.append(f"{path.relative_to(RESOURCES)}:{key}: empty value")
        if path.name in ("ReadingTools.strings", "FeatureImprovements.strings"):
            source_values=tool_english if path.name=="ReadingTools.strings" else feature_english
            values=dict(entries)
            if set(values)!=set(source_values): errors.append(f"{path.parent.name}: {path.stem} key parity")
            for key,source in source_values.items():
                if PLACEHOLDER.findall(values.get(key,""))!=PLACEHOLDER.findall(source):
                    errors.append(f"{path.parent.name}:{path.stem}:{key}: placeholders")
                value=values.get(key, "")
                if re.search(r"<\s*x\b|&lt;\s*x\b", value, re.I): errors.append(f"{path.parent.name}:{path.stem}:{key}: translation marker")
                if path.name=="FeatureImprovements.strings":
                    for term in FEATURE_TERMS:
                        if term in source and term not in value: errors.append(f"{path.parent.name}:{path.stem}:{key}: missing {term}")
    for locale,label in APP_STORE_LOCALE_NAMES.items():
        values=load(RESOURCES/f"{locale}.lproj"/"Localizable.strings")
        if set(values)!=set(english): errors.append(f"{locale}: key parity {len(values)}/{len(english)}")
        tools=load(RESOURCES/f"{locale}.lproj"/"ReadingTools.strings")
        if set(tools)!=set(tool_english): errors.append(f"{locale}: ReadingTools coverage {len(tools)}/{len(tool_english)}")
        features=load(RESOURCES/f"{locale}.lproj"/"FeatureImprovements.strings")
        if set(features)!=set(feature_english): errors.append(f"{locale}: FeatureImprovements coverage {len(features)}/{len(feature_english)}")
        for key,source in english.items():
            if PLACEHOLDER.findall(values.get(key,""))!=PLACEHOLDER.findall(source): errors.append(f"{locale}:{key}: placeholders")
        if len(load(RESOURCES/f"{locale}.lproj"/"InfoPlist.strings"))!=5: errors.append(f"{locale}: InfoPlist")
        for filename in FILES:
            path=METADATA/label/filename
            if not path.exists() or not path.read_text(encoding="utf-8").strip(): errors.append(f"{label}/{filename}: missing"); continue
            if len(path.read_text(encoding="utf-8").strip())>LIMITS[filename]: errors.append(f"{label}/{filename}: too long")
    actual={p.name for p in METADATA.iterdir() if p.is_dir()}; expected=set(APP_STORE_LOCALE_NAMES.values())
    if actual!=expected: errors.append(f"metadata directories mismatch: missing={expected-actual}, extra={actual-expected}")
    print(f"[soulo/l10n] {len(english)} keys × {len(APP_STORE_LOCALE_NAMES)} locales")
    print(f"[soulo/l10n] ReadingTools {len(tool_english)} keys × {len(APP_STORE_LOCALE_NAMES)} locales")
    print(f"[soulo/l10n] FeatureImprovements {len(feature_english)} keys × {len(APP_STORE_LOCALE_NAMES)} locales")
    if errors:
        print("\n".join("ERROR "+x for x in errors[:100])); return 1
    print("[soulo/l10n] all checks passed"); return 0
if __name__=="__main__": sys.exit(main())
