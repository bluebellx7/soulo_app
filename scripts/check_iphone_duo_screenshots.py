#!/usr/bin/env python3
"""Check actual Duo screenshots on macOS; never resize or manufacture assets.

Source (verified 2026-10-06):
https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
Place only Duo images in fastlane/screenshots/iphone-duo/<locale>/.
"""

import argparse
from collections import defaultdict
from pathlib import Path
import subprocess
import sys

SIZES = {
    (1398, 2034): "outer",
    (2034, 1398): "outer",
    (2007, 2853): "inner",
    (2853, 2007): "inner",
}
DEFAULT_PATH = Path(__file__).resolve().parents[1] / "fastlane/screenshots/iphone-duo"


def inspect_image(path):
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "-g", "hasAlpha", str(path)],
        capture_output=True, text=True, check=True,
    )
    properties = {}
    for line in result.stdout.splitlines():
        if ": " in line:
            key, value = line.strip().split(": ", 1)
            properties[key] = value
    return properties


def check_directory(directory, require_both=False):
    images = sorted(path for path in directory.rglob("*")
                    if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg"})
    errors = []
    displays = defaultdict(set)
    counts = defaultdict(int)
    if not images:
        return [f"No Duo screenshots found in {directory}. Capture them with Xcode 27.1 or later on Duo."], 0
    for path in images:
        locale = str(path.parent.relative_to(directory))
        counts[locale] += 1
        try:
            properties = inspect_image(path)
            size = (int(properties["pixelWidth"]), int(properties["pixelHeight"]))
            if size not in SIZES:
                errors.append(f"{path}: unsupported Duo dimensions {size[0]} × {size[1]}")
            else:
                displays[locale].add(SIZES[size])
            if properties.get("format") not in {"png", "jpeg"}:
                errors.append(f"{path}: content must be PNG or JPEG")
            if properties.get("hasAlpha") != "no":
                errors.append(f"{path}: remove the alpha channel before upload")
        except (OSError, subprocess.CalledProcessError, KeyError, ValueError) as error:
            errors.append(f"{path}: cannot inspect image ({error})")
    for locale, count in counts.items():
        if count > 10:
            errors.append(f"{locale}: {count} images; App Store Connect accepts at most 10 per device size")
        # Both displays are a project QA recommendation, not an assertion that
        # Apple requires both. At least one accepted image passes by default.
        if require_both and displays[locale] != {"inner", "outer"}:
            errors.append(f"{locale}: include captures of both inner and outer displays")
    return errors, len(images)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", default=DEFAULT_PATH)
    parser.add_argument("--require-both", action="store_true", help="Project QA: require inner and outer display assets per supplied locale")
    arguments = parser.parse_args()
    errors, count = check_directory(arguments.directory, arguments.require_both)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print(f"Checked {count} Duo screenshots: accepted dimensions, PNG/JPEG, no alpha.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
