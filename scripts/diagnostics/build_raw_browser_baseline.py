#!/usr/bin/env python3
"""Build an independent UIKit/WebKit baseline; never changes Soulo's project.

Example:
  python3 scripts/diagnostics/build_raw_browser_baseline.py --profile ua --device UUID
  xcrun simctl launch UUID com.soulo.qa.RawBrowser.ua -profile ua -sampling NO

system -> inline -> autoplay -> ua -> fullscreen -> windows -> routing -> suspend
adds one native behavior at each step. script-NAME starts from suspend and adds
only NAME from the opt-in testExportBrowserScriptsForIsolation JSON export.
"""

import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="ua")
    parser.add_argument("--device", help="Explicit simulator UUID; installs without launching")
    parser.add_argument("--scripts-json", type=Path)
    args = parser.parse_args()
    profiles = {"system", "inline", "autoplay", "ua", "fullscreen", "windows", "routing", "suspend"}
    scripts = {"selection", "resources", "video", "session", "ads", "privacy", "navigation", "all", "handoff", "privacy-before"}
    if args.profile not in profiles and not (
        args.profile.startswith("script-") and args.profile.removeprefix("script-") in scripts
    ):
        parser.error("Unknown isolation profile")
    if args.profile.startswith("script-") and not args.scripts_json:
        parser.error("script profiles require --scripts-json from the export test")
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    folder = Path(tempfile.mkdtemp(prefix="soulo-raw-browser-"))
    app = folder / "Baseline.app"
    app.mkdir()
    bundle = "com.soulo.qa.RawBrowser." + args.profile
    info = {
        "CFBundleIdentifier": bundle,
        "CFBundleExecutable": "Baseline",
        "CFBundleName": "Baseline",
        "CFBundleDisplayName": "原始网页·" + args.profile,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSRequiresIPhoneOS": True,
        "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1, 2],
        "UILaunchScreen": {},
        "UIBackgroundModes": ["audio"],
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    }
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    if args.scripts_json:
        shutil.copyfile(args.scripts_json, app / "isolation-scripts.json")
    subprocess.run([
        "xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5",
        "-parse-as-library", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
        str(Path(__file__).with_name("RawBrowserBaseline.swift")),
        "-o", str(app / "Baseline"),
    ], check=True)
    if args.device:
        subprocess.run(["xcrun", "simctl", "install", args.device, str(app)], check=True)
    print(app)
    print("Bundle:", bundle)


if __name__ == "__main__":
    main()
