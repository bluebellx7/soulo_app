#!/usr/bin/env python3
"""Fill missing independent UI translations without changing app/store tables.

Existing translations remain authoritative. Only public interface copy is sent to
the same translation endpoint used by generate_all_localizations.py. Machine
translations still need native-speaker review; printf placeholders are validated
before any locale is written. Repeat runs reuse a local response cache.
"""

from __future__ import annotations

import argparse
import json
import re
import threading
import time
import urllib.parse
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import generate_all_localizations as shared

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Soulo"
CACHE_PATH = Path("/tmp/soulo_reading_tools_translation_cache.json")
PROTECTED_TERMS = [
    "Telegram", "Wi-Fi", "ZIP", "7z", "RAR", "EPUB", "PDF", "HLS",
    "ED2K", "HTTP", "HTTPS", "MP3", "AirPlay", "VLC", "Safari",
    "Pexels", "Pixabay", "Bing", "HTML", "URL", "JSON", "OCR", "TXT",
    "Apple", "iPad", "Command-Shift-T", "Command-L", "Command-T",
    "Command-W", "Command-R", "Command-F", "Command-N",
]
# Short standalone English labels can be mistranslated as verbs (Format) or
# unrelated nouns (Light). These equivalent phrases supply their UI context.
LABEL_CONTEXT = {
    "format": "File format",
    "appearance": "Reading theme",
    "paper": "Paper background",
    "light": "Light theme",
    "dark": "Dark theme",
    "loop": "Repeat current track",
    "mono": "Monospaced font",
    "reader_mode": "Reading mode",
    "bookshelf_hint": "Import a book to start reading. Your reading position is saved automatically.",
    "remove_from_shelf": "Remove from bookshelf · keep file",
}
EQUIVALENT_SHARED_KEYS = {
    "appearance": "appearance", "light": "appearance_light", "dark": "appearance_dark",
}
FEATURE_CONTEXT = {
    "Favorite wallpapers": "Favorite wallpapers",
    "Continue playing": "Resume playback",
    "Reading data": "Saved reading data",
    "Storage": "App storage",
    "Name A–Z": "File name A–Z",
    "Name Z–A": "File name Z–A",
    "Pin group": "Pin tab group",
    "Unpin group": "Unpin tab group",
    "Rename group": "Rename tab group",
    "Show duplicates": "Show only duplicates",
    "Try search": "Test search",
    "After this item": "Stop after current item",
    "Select visible": "Select all results",
}


def request(text: str, target: str) -> str:
    """Use Google's dictionary client; its response is a translated string list.

    The generator's older /single endpoint can return 429 for the same public
    copy while this client remains available. Fail explicitly rather than write
    the source language into an untranslated locale.
    """
    if target == "en" or not text.strip():
        return text
    key = target + "\0" + text
    with shared.lock:
        if key in shared.CACHE:
            return shared.CACHE[key]
    url = "https://clients5.google.com/translate_a/t?" + urllib.parse.urlencode({
        "client": "dict-chrome-ex", "sl": "en", "tl": target, "q": text,
    })
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=30) as response:
                payload = json.load(response)
            if not isinstance(payload, list) or not payload or not isinstance(payload[0], str):
                raise ValueError("Unexpected translation response")
            result = payload[0]
            if not result.strip():
                raise ValueError("Empty translation response")
            with shared.lock:
                shared.CACHE[key] = result
            return result
        except Exception as error:
            if attempt == 3:
                raise RuntimeError(f"translate {target}: {error}") from error
            time.sleep(attempt + 1)
    raise AssertionError("Unreachable")


def marker(identifier: str) -> str:
    # Some languages translate the attribute name `id` (e.g. Arabic `معرف`).
    # The protected identifier itself remains ASCII; accept the surrounding
    # attribute spelling without falling back to hundreds of individual calls.
    quote = r'["\'“”‘’]'
    return rf"<[xX][^<>]*?{quote}{re.escape(identifier)}{quote}[^<>]*?/\s*>"


def check(source: str, translated: str, locale: str, key: str) -> None:
    if not translated.strip():
        raise ValueError(f"{locale}:{key}: empty translation")
    if shared.PLACEHOLDER_RE.findall(source) != shared.PLACEHOLDER_RE.findall(translated):
        raise ValueError(f"{locale}:{key}: printf placeholders changed")
    if re.search(r"<\s*x\b|&lt;\s*x\b", translated, re.I):
        raise ValueError(f"{locale}:{key}: translation marker was not restored")


def write(path: Path, values: OrderedDict[str, str], table: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    header = f"/* Soulo {table} — machine-assisted translation; review in context. */"
    if path.exists():
        previous = path.read_text(encoding="utf-8").splitlines()
        if previous and ("selected labels reviewed in context" in previous[0] or "reviewed source copy" in previous[0]):
            header = previous[0]
    text = (
        header + "\n\n"
        + "\n".join(f'"{shared.esc(k)}" = "{shared.esc(v)}";' for k, v in values.items())
        + "\n"
    )
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("locales", nargs="*", help="Default: all 50 supported locales")
    parser.add_argument("--table", choices=["ReadingTools", "FeatureImprovements"], default="ReadingTools")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--refine-generated-labels", action="store_true",
                        help="Revise ambiguous labels only in new machine-assisted tables")
    args = parser.parse_args()
    context = LABEL_CONTEXT if args.table == "ReadingTools" else FEATURE_CONTEXT
    unknown = set(args.locales) - set(shared.LOCALES)
    if unknown:
        parser.error("Unknown locales: " + ", ".join(sorted(unknown)))

    # Use an independent cache; never overwrite the broader metadata generator's
    # cache or run its entry point (which would modify App Store source files).
    shared.CACHE_PATH = CACHE_PATH
    try:
        shared.CACHE = {key: value for key, value in json.loads(CACHE_PATH.read_text(encoding="utf-8")).items()
                        if isinstance(value, str) and value.strip()}
    except (OSError, ValueError):
        shared.CACHE = {}
    shared.PROTECTED[:] = sorted(set(shared.PROTECTED + PROTECTED_TERMS), key=len, reverse=True)
    shared.request = request
    shared.marker = marker

    source = shared.load(RESOURCES / f"en-US.lproj/{args.table}.strings")
    if not source:
        parser.error(f"Missing or empty English source: en-US.lproj/{args.table}.strings")
    shared_keys = {}
    if args.table == "ReadingTools":
        mapping_text = (RESOURCES / "Source/Services/ReadingTools/ToolText.swift").read_text()
        mapping_text = mapping_text.split("static let sharedKeys = [", 1)[1].split("]", 1)[0]
        shared_keys = dict(re.findall(r'"([^\"]+)"\s*:\s*"([^\"]+)"', mapping_text))
        shared_keys.update(EQUIVALENT_SHARED_KEYS)
    targets: dict[str, list[str]] = {}
    for locale, target in shared.LOCALES.items():
        if not args.locales or locale in args.locales:
            targets.setdefault(target, []).append(locale)

    cache_write_lock = threading.Lock()

    def persist_cache() -> None:
        with cache_write_lock:
            with shared.lock:
                payload = json.dumps(shared.CACHE, ensure_ascii=False)
            temporary = CACHE_PATH.with_suffix(".tmp")
            temporary.write_text(payload, encoding="utf-8")
            temporary.replace(CACHE_PATH)

    def generate(target: str, locales: list[str]) -> list[str]:
        refining = args.refine_generated_labels
        if refining:
            locales = [locale for locale in locales if target != "en" and
                       (RESOURCES / f"{locale}.lproj/{args.table}.strings").exists() and
                       "machine-assisted translation" in (RESOURCES / f"{locale}.lproj/{args.table}.strings").read_text()]
            if not locales:
                return [target + " (original labels preserved)"]
        existing = {locale: shared.load(RESOURCES / f"{locale}.lproj/{args.table}.strings") for locale in locales}
        shared_values = {locale: shared.load(RESOURCES / f"{locale}.lproj/Localizable.strings") for locale in locales}
        needed = list(context) if refining else list(dict.fromkeys(
            key for locale in locales for key in source
            if key not in existing[locale] and shared_keys.get(key) not in shared_values[locale]
        ))
        translations = dict(zip(needed, shared.translate([
            context.get(key, source[key]) if target != "en" else source[key] for key in needed
        ], target)))
        for key, value in translations.items():
            try:
                check(source[key], value, target, key)
            except ValueError:
                # A batch can mangle one densely protected sentence. Retry the
                # individual phrase, then plain text if the markup itself was
                # the cause. Never accept broken printf fields or lost brands.
                phrase = context.get(key, source[key])
                repaired = shared.translate([phrase], target)[0]
                try:
                    check(source[key], repaired, target, key)
                except ValueError:
                    repaired = request(phrase, target)
                    check(source[key], repaired, target, key)
                    for term in shared.PROTECTED:
                        if term in phrase and term not in repaired:
                            raise ValueError(f"{target}:{key}: protected term was not retained: {term}")
                translations[key] = repaired
        persist_cache()
        completed = []
        for locale in locales:
            if set(existing[locale]) == set(source) and not refining:
                completed.append(locale + " (preserved)")
                continue
            values = OrderedDict()
            for key, text in source.items():
                value = translations.get(key) if refining and key in context else existing[locale].get(key)
                if refining and args.table == "ReadingTools" and key in EQUIVALENT_SHARED_KEYS:
                    value = shared_values[locale].get(EQUIVALENT_SHARED_KEYS[key], value)
                if value is None:
                    value = shared_values[locale].get(shared_keys.get(key, ""), translations.get(key))
                if value is None:
                    raise ValueError(f"{locale}:{key}: missing translation")
                check(text, value, locale, key)
                values[key] = value
            write(RESOURCES / f"{locale}.lproj/{args.table}.strings", values, args.table)
            completed.append(locale)
        return completed

    errors = []
    try:
        with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
            futures = {pool.submit(generate, target, locales): target for target, locales in targets.items()}
            for future in as_completed(futures):
                try:
                    print("completed " + ", ".join(future.result()), flush=True)
                except Exception as error:
                    errors.append(str(error))
                    print("ERROR " + str(error), flush=True)
    finally:
        persist_cache()
    if errors:
        raise SystemExit(f"{len(errors)} target language(s) failed; no English fallback was written for them")
    print(f"validated {args.table}: {len(source)} keys across {sum(map(len, targets.values()))} locales", flush=True)


if __name__ == "__main__":
    main()
