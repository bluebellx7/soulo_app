#!/usr/bin/env python3
"""Collect literal keys from FeatureText.text calls, including branches/maps."""

from __future__ import annotations

import json
from pathlib import Path


def keys_in_source(source: str) -> set[str]:
    keys: set[str] = set()
    needle = "FeatureText.text("
    cursor = 0
    while (start := source.find(needle, cursor)) != -1:
        cursor = start + len(needle)
        depth = 1
        while cursor < len(source) and depth:
            character = source[cursor]
            if character == '"':
                end = cursor + 1
                while end < len(source):
                    if source[end] == "\\":
                        end += 2
                    elif source[end] == '"':
                        break
                    else:
                        end += 1
                literal = source[cursor:end + 1]
                try:
                    value = json.loads(literal)
                    if "\\(" not in value:
                        keys.add(value)
                except ValueError:
                    # Dynamic/interpolated strings need explicit review rather
                    # than being mistaken for a static localization key.
                    pass
                cursor = end + 1
                continue
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            cursor += 1
    return keys


def source_keys(directory: Path) -> set[str]:
    keys: set[str] = set()
    for path in directory.rglob("*.swift"):
        keys.update(keys_in_source(path.read_text(encoding="utf-8")))
    return keys


if __name__ == "__main__":
    for key in sorted(source_keys(Path(__file__).resolve().parent.parent / "Soulo/Source")):
        print(key)
