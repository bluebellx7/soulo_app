#!/usr/bin/env python3
"""Build the pinned LES runtime. No model weights, servers or TTS are bundled."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.runtime-build'
VENDOR = ROOT / 'Vendor'
SOURCE = 'https://github.com/tc-mb/llama.cpp-omni.git'
COMMIT = '96bbf61710d44421ea54e63f5194f9b17c20d877'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def build_slice(source, name, sdk, arch, minimum, ios=False):
    build = CACHE / ('les-' + name)
    options = ['-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_BUILD_TYPE=Release',
               '-DLLAMA_BUILD_APP=OFF', '-DLLAMA_BUILD_TESTS=OFF',
               '-DLLAMA_BUILD_EXAMPLES=OFF', '-DLLAMA_BUILD_SERVER=OFF',
               '-DLLAMA_BUILD_TOOLS=ON', '-DLLAMA_BUILD_COMMON=ON',
               '-DLLAMA_OPENSSL=OFF', '-DLLAMA_CURL=OFF', '-DGGML_NATIVE=OFF',
               '-DGGML_OPENMP=OFF', '-DGGML_METAL=ON', '-DGGML_METAL_EMBED_LIBRARY=ON',
               '-DGGML_METAL_USE_BF16=ON', '-DGGML_BLAS=ON',
               '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + minimum,
               '-DCMAKE_OSX_ARCHITECTURES=' + arch, '-DCMAKE_OSX_SYSROOT=' + sdk]
    if ios: options += ['-DCMAKE_SYSTEM_NAME=iOS', '-DIOS=ON']
    run('cmake', '-S', source, '-B', build, *options)
    run('cmake', '--build', build, '--target', 'mtmd', '--parallel', '4')
    framework = build / 'framework/llama.framework'
    headers = framework / 'Headers'
    headers.mkdir(parents=True, exist_ok=True)
    (framework / 'Modules').mkdir(exist_ok=True)
    public = [source / 'include/llama.h'] + list((source / 'ggml/include').glob('*.h'))
    public += [source / 'tools/mtmd/mtmd.h', source / 'tools/mtmd/mtmd-helper.h']
    for header in public: shutil.copy2(header, headers / header.name)
    (framework / 'Modules/module.modulemap').write_text('framework module llama {\n umbrella "Headers"\n link "c++"\n export *\n}\n')
    binary = framework / 'llama'
    names = {'libllama.a', 'libmtmd.a', 'libggml.a', 'libggml-base.a',
             'libggml-cpu.a', 'libggml-metal.a', 'libggml-blas.a'}
    libraries = sorted(lib for lib in build.rglob('lib*.a') if lib.name in names)
    if len(libraries) != 7: raise SystemExit('Missing or duplicate runtime libraries')
    combined = build / 'combined.a'
    run('xcrun', 'libtool', '-static', '-o', combined, *libraries)
    sysroot = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
    version_flag = ('-mios-simulator-version-min=' if sdk == 'iphonesimulator' else
                    '-mios-version-min=' if ios else '-mmacosx-version-min=') + minimum
    run('xcrun', '--sdk', sdk, 'clang++', '-dynamiclib', '-isysroot', sysroot,
        '-arch', arch, version_flag, '-Wl,-force_load,' + str(combined),
        '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'Accelerate',
        '-install_name', '@rpath/llama.framework/llama', '-o', binary)
    run('xcrun', 'strip', '-S', binary)
    info = dict(CFBundleExecutable='llama', CFBundleIdentifier='org.ggml.llama',
                CFBundleName='llama', CFBundlePackageType='FMWK',
                CFBundleShortVersionString='1.0', CFBundleVersion='1', MinimumOSVersion=minimum)
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    return framework


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-simulator', action='store_true')
    parser.add_argument('--source-directory', type=Path, help='Existing checkout at the exact pinned commit')
    args = parser.parse_args()
    CACHE.mkdir(exist_ok=True); VENDOR.mkdir(exist_ok=True)
    source = args.source_directory or CACHE / 'llama-les'
    if not source.exists():
        run('git', 'init', source)
        run('git', '-C', source, 'remote', 'add', 'origin', SOURCE)
        run('git', '-C', source, 'fetch', '--depth', '1', 'origin', COMMIT)
        run('git', '-C', source, 'checkout', '--detach', 'FETCH_HEAD')
    actual = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != COMMIT: raise SystemExit('Unexpected LES runtime source revision')
    if subprocess.check_output(['git', '-C', str(source), 'diff', '--name-only'], text=True).strip():
        raise SystemExit('Runtime sources have local edits; refusing a non-reproducible build')
    slices = [build_slice(source, 'macos', 'macosx', platform.machine(), '14.0'),
              build_slice(source, 'ios', 'iphoneos', 'arm64', '17.0', ios=True)]
    if not args.skip_simulator:
        slices.append(build_slice(source, 'simulator', 'iphonesimulator', platform.machine(), '17.0', ios=True))
    staging = VENDOR / 'llama-les.xcframework'
    if staging.exists(): shutil.rmtree(staging)
    command = ['xcrun', 'xcodebuild', '-create-xcframework']
    for framework in slices: command += ['-framework', str(framework)]
    run(*command, '-output', staging)
    destination = VENDOR / 'llama.xcframework'
    if destination.exists(): shutil.rmtree(destination)
    staging.rename(destination)
    (VENDOR / 'runtime-manifest.json').write_text(json.dumps(dict(
        source=SOURCE, commit=COMMIT, features=['llama', 'mtmd', 'MoE-SSD', 'LES'],
        simulator=not args.skip_simulator), indent=2) + '\n')
    print('Runtime ready:', destination, flush=True)


if __name__ == '__main__': main()
