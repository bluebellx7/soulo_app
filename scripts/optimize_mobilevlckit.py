#!/usr/bin/env python3
"""Remove unsupported 32-bit iOS slices without changing decoder features.

Run after extracting the pinned upstream MobileVLCKit archive. iOS 17+ devices
use arm64; both supported simulator architectures remain available.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'ThirdParty/MobileVLCKit'
FRAMEWORK = PACKAGE / 'Artifacts/MobileVLCKit.xcframework'

def main():
    manifest = FRAMEWORK / 'Info.plist'
    info = plistlib.loads(manifest.read_bytes())
    for item in info['AvailableLibraries']:
        if item.get('SupportedPlatformVariant') == 'simulator':
            continue
        directory = FRAMEWORK / item['LibraryIdentifier']
        binary = directory / 'MobileVLCKit.framework/MobileVLCKit'
        arches = subprocess.check_output(['lipo','-archs',str(binary)], text=True).split()
        if arches != ['arm64']:
            temporary = binary.with_suffix('.thin')
            subprocess.run(['lipo',str(binary),'-thin','arm64','-output',str(temporary)], check=True)
            temporary.replace(binary)
        # Preserve global/dynamic symbols, ObjC metadata and every codec.
        subprocess.run(['xcrun','strip','-S','-x',str(binary)], check=True)
        symbols = directory / 'dSYMs/MobileVLCKit.framework.dSYM/Contents/Resources/DWARF/MobileVLCKit'
        if symbols.is_file() and subprocess.check_output(['lipo','-archs',str(symbols)], text=True).split() != ['arm64']:
            temporary = symbols.with_suffix('.thin')
            subprocess.run(['lipo',str(symbols),'-thin','arm64','-output',str(temporary)], check=True)
            temporary.replace(symbols)
        item['SupportedArchitectures'] = ['arm64']
        item['LibraryIdentifier'] = 'ios-arm64'
        item['DebugSymbolsPath'] = 'dSYMs'
        if directory.name != 'ios-arm64':
            shutil.move(str(directory), str(FRAMEWORK/'ios-arm64'))
    manifest.write_bytes(plistlib.dumps(info, sort_keys=False))
    p=PACKAGE/'artifacts.json'
    values=json.loads(p.read_text())
    values['optimization']='iOS 17+ device arm64 only; non-global/debug symbols stripped; codecs unchanged'
    values['files']={str(f.relative_to(PACKAGE)):hashlib.sha256(f.read_bytes()).hexdigest()
                     for f in sorted(FRAMEWORK.rglob('*')) if f.is_file() and f.name in ['MobileVLCKit','Info.plist']}
    p.write_text(json.dumps(values,indent=2)+'\n')
    # The matching upstream symbols stay outside the installed application.
    subprocess.run([sys.executable, str(ROOT/'scripts/prepare_mobilevlckit_symbols.py')], check=True)

if __name__=='__main__':main()
