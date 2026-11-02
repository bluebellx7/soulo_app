#!/usr/bin/env python3
"""Build the pinned eD2K/Kad Go engine as an iOS static XCFramework.

Only the library and its standard-library dependencies are linked. Upstream's
terminal UI is not imported. Go modules are pinned and verified with go.sum.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'ThirdParty/SouloED2K'

def run(args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/SouloED2KBuild')
    args = parser.parse_args()
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    run(['go', 'mod', 'verify'], cwd=PACKAGE / 'Bridge')
    for name, arch, goarch, simulator in [('device-arm64','arm64','arm64',False), ('sim-arm64','arm64','arm64',True), ('sim-x86_64','x86_64','amd64',True)]:
        sdk = 'iphonesimulator' if simulator else 'iphoneos'
        sdkpath = subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'], text=True).strip()
        cc = subprocess.check_output(['xcrun','--sdk',sdk,'--find','clang'], text=True).strip()
        target = f'{arch}-apple-ios17.0' + ('-simulator' if simulator else '')
        flags = f'-isysroot {sdkpath} -target {target}'
        directory = cache / name
        directory.mkdir(exist_ok=True)
        env = dict(os.environ, GOOS='ios', GOARCH=goarch, CGO_ENABLED='1', CC=cc,
                   CGO_CFLAGS=flags, CGO_LDFLAGS=flags)
        run(['go','build','-mod=readonly','-buildvcs=false','-buildmode=c-archive','-trimpath','-ldflags=-w',
             '-o',directory/'libSouloED2K.a','.'], cwd=PACKAGE/'Bridge',env=env)
    sim = cache / 'sim'
    sim.mkdir(exist_ok=True)
    run(['xcrun','lipo','-create',cache/'sim-arm64/libSouloED2K.a',cache/'sim-x86_64/libSouloED2K.a','-output',sim/'libSouloED2K.a'])
    output=PACKAGE/'Artifacts/SouloED2K.xcframework'
    if output.exists():shutil.rmtree(output)
    run(['xcodebuild','-create-xcframework','-library',cache/'device-arm64/libSouloED2K.a','-headers',PACKAGE/'Bridge/include',
         '-library',sim/'libSouloED2K.a','-headers',PACKAGE/'Bridge/include','-output',output])
    manifest={
        'source':'https://github.com/monkeyWie/goed2k',
        'revision':'f2a71d599deeb1b60595d71aa662d48b205699ed',
        'goVersion':subprocess.check_output(['go','version'],text=True).strip(),
        'sourceFiles':{str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in sorted((PACKAGE/'Source').rglob('*')) if p.is_file()},
        'files':{str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(output.rglob('*')) if p.is_file()}
    }
    (PACKAGE/'artifacts.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__':main()
