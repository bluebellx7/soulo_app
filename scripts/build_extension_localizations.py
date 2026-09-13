#!/usr/bin/env python3
"""Package only strings referenced by an extension, retaining every app locale.

The main app's .lproj files remain the source of truth. Run after Copy Bundle
Resources; exact string literals include keys passed through helper methods.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess

from check_localization import load

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["SouloWidget", "SouloShareExtension"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    sources = list((ROOT / args.target).rglob("*.swift"))
    sources.append(ROOT / "Soulo/Source/Shared/SouloSharedAction.swift")
    if args.target == "SouloWidget":
        sources.append(ROOT / "Soulo/Source/Shared/SouloSystemIntents.swift")
    literals = set(re.findall(r'"([a-z][a-z0-9_]+)"', "\n".join(p.read_text() for p in sources)))
    base = ROOT / "Soulo"
    tables = {
        "Localizable.strings": load(base / "en.lproj/Localizable.strings"),
        "ReadingTools.strings": load(base / "en-US.lproj/ReadingTools.strings"),
    }
    total = 0
    for locale in sorted(base.glob("*.lproj")):
        destination = output / locale.name
        destination.mkdir(parents=True, exist_ok=True)
        # Also remove full tables left by an incremental build of older configs.
        for name in [*tables, "InfoPlist.strings"]:
            (destination / name).unlink(missing_ok=True)
        for name, english in tables.items():
            keys = literals & english.keys()
            if not keys:
                continue
            # Parse escaped .strings values with Apple's parser before writing
            # binary tables, preserving newlines, quotes and Unicode exactly.
            canonical = {"de": "de-DE", "ar": "ar-SA", "es": "es-ES", "fr": "fr-FR"}.get(locale.stem, locale.stem)
            source = base / (canonical + ".lproj") / name
            fallback = base / ("en.lproj" if name == "Localizable.strings" else "en-US.lproj") / name
            parsed = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(source if source.exists() else fallback)]))
            if not keys <= parsed.keys():
                raise ValueError(f"Missing extension keys in {source}: {keys - parsed.keys()}")
            data = plistlib.dumps({key: parsed[key] for key in keys}, fmt=plistlib.FMT_BINARY)
            (destination / name).write_bytes(data)
            total += len(data)
    print(f"{args.target}: localized strings {total:,} bytes across all app locales")


if __name__ == "__main__":
    main()
