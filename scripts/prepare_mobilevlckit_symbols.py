#!/usr/bin/env python3
"""Restore the pinned device dSYM before Xcode processes the XCFramework."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'ThirdParty/MobileVLCKit'
FRAMEWORK = PACKAGE / 'Artifacts/MobileVLCKit.xcframework'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    return {(line.split()[1], line.split()[2]) for line in output.splitlines() if line.startswith('UUID: ')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate without restoring files')
    args = parser.parse_args()
    metadata = json.loads((PACKAGE / 'artifacts.json').read_text())['debugSymbols']
    archive = PACKAGE / metadata['archive']
    if digest(archive) != metadata['sha256']:
        raise SystemExit('MobileVLCKit symbol archive checksum does not match artifacts.json')
    directory = FRAMEWORK / 'ios-arm64'
    bundle = directory / 'dSYMs/MobileVLCKit.framework.dSYM'
    dwarf = bundle / 'Contents/Resources/DWARF/MobileVLCKit'
    if not dwarf.is_file():
        if args.check:
            raise SystemExit('MobileVLCKit dSYM is missing; run scripts/prepare_mobilevlckit_symbols.py')
        with tempfile.TemporaryDirectory(prefix='soulo-vlc-symbols-') as temporary:
            staging = Path(temporary)
            with tarfile.open(archive) as source:
                for member in source:
                    parts = Path(member.name).parts
                    if not parts or parts[0] != bundle.name or '..' in parts or Path(member.name).is_absolute():
                        raise SystemExit('Unexpected path in MobileVLCKit symbol archive')
                    if member.isdir():
                        continue
                    if not member.isfile():
                        raise SystemExit('Unexpected non-regular file in MobileVLCKit symbol archive')
                    target = staging / member.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as content, target.open('wb') as destination:
                        shutil.copyfileobj(content, destination)
            staged = staging / bundle.name
            binary = directory / 'MobileVLCKit.framework/MobileVLCKit'
            if uuids(staged / 'Contents/Resources/DWARF/MobileVLCKit') != uuids(binary):
                raise SystemExit('MobileVLCKit dSYM UUID does not match the device framework')
            bundle.parent.mkdir(parents=True, exist_ok=True)
            if bundle.exists():
                shutil.rmtree(bundle)
            shutil.move(str(staged), str(bundle))
    binary = directory / 'MobileVLCKit.framework/MobileVLCKit'
    expected = {(metadata['uuid'], '(arm64)')}
    if uuids(dwarf) != expected or uuids(binary) != expected:
        raise SystemExit('MobileVLCKit framework and dSYM must both match the pinned arm64 UUID')
    info = plistlib.loads((FRAMEWORK / 'Info.plist').read_bytes())
    entry = next(item for item in info['AvailableLibraries'] if item['LibraryIdentifier'] == 'ios-arm64')
    if entry.get('DebugSymbolsPath') != 'dSYMs':
        raise SystemExit('MobileVLCKit XCFramework must declare DebugSymbolsPath: dSYMs')
    print('MobileVLCKit device dSYM verified: ' + metadata['uuid'])


if __name__ == '__main__':
    main()
