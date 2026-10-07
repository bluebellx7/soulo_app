#!/usr/bin/env python3
"""Seed original sample documents in a dedicated Soulo Store simulator only."""
import argparse
import json
from pathlib import Path
import subprocess

SAMPLES_PATH = Path(__file__).resolve().parents[1] / "SouloTests" / "ReadingFixtures" / "store-samples.json"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("language", choices=["zh-Hans", "en-US"])
    args = parser.parse_args()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
    device = next((d for group in devices["devices"].values() for d in group if d["udid"] == args.device), None)
    if not device or not device["name"].startswith("Soulo Store "):
        parser.error("Only a dedicated simulator named 'Soulo Store ...' may be seeded.")
    # Clear this dedicated device's sample clipboard before capturing the home
    # page. Do not read or alter the host Mac's pasteboard.
    subprocess.run(["xcrun", "simctl", "pbcopy", args.device], input="", text=True, check=True)
    data = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", args.device, "com.dkluge.Soulo", "data"], text=True).strip())
    root = data / "Documents" / "Downloads"
    root.mkdir(parents=True, exist_ok=True)
    manifest = data / "Documents" / ".store-samples.json"
    if manifest.exists():
        for name in json.loads(manifest.read_text()):
            path = root / name
            if path.is_file(): path.unlink()
            elif path.is_dir() and not any(path.iterdir()): path.rmdir()
    chinese = args.language == "zh-Hans"
    names = ["沿着河流慢慢走.txt", "旅行清单.md", "灵感笔记.json", "旅行照片"] if chinese else ["A Walk Along the River.txt", "Travel Checklist.md", "Reading Notes.json", "Travel Photos"]
    (root / names[0]).write_text(json.loads(SAMPLES_PATH.read_text())[args.language])
    (root / names[1]).write_text("# 旅行清单\n\n- 车票\n- 相机\n- 笔记本\n- 雨伞\n" if chinese else "# Travel Checklist\n\n- Tickets\n- Camera\n- Notebook\n- Umbrella\n")
    (root / names[2]).write_text(json.dumps({"title": "清晨的发现" if chinese else "Morning Discoveries", "notes": ["留一点时间给散步" if chinese else "Leave some time for a walk"]}, ensure_ascii=False, indent=2))
    (root / names[3]).mkdir(exist_ok=True)
    manifest.write_text(json.dumps(names, ensure_ascii=False))
    print(f"Seeded {args.language} original samples in {device['name']}")

if __name__ == "__main__":
    main()
