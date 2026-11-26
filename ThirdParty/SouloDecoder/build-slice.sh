#!/usr/bin/env bash
set -euo pipefail
cd "$1"
root=$PWD
sdk=$2
arch=$3
jobs=${4:-6}
tag=$sdk-$arch
out="$root/out-with-symbols/$tag"
prefix="$out/prefix"
mkdir -p "$prefix"
export PATH="$root/tools/bin:$PATH"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
clang=$(xcrun --sdk "$sdk" --find clang)
platform=
if [[ $sdk == iphonesimulator ]]; then platform=-simulator; fi
target="$arch-apple-ios16.0$platform"
meson_arch=$arch
if [[ $arch == arm64 ]]; then meson_arch=aarch64; fi
cross="$out/cross.ini"
cat > "$cross" <<CROSS
[binaries]
c = ['$clang', '-target', '$target', '-isysroot', '$sysroot']
cpp = ['$clang++', '-target', '$target', '-isysroot', '$sysroot']
objc = ['$clang', '-target', '$target', '-isysroot', '$sysroot']
objcpp = ['$clang++', '-target', '$target', '-isysroot', '$sysroot']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = '$meson_arch'
cpu = '$meson_arch'
endian = 'little'
[built-in options]
c_args = ['-gline-tables-only']
cpp_args = ['-gline-tables-only']
objc_args = ['-gline-tables-only']
objcpp_args = ['-gline-tables-only']
CROSS
build() {
  local project=$1 src=$2
  shift 2
  if [[ ! -d $out/$project/meson-info ]]; then
    meson setup "$out/$project" "$root/$src" --cross-file "$cross" --prefix "$prefix" --libdir lib \
      --buildtype minsize -Ddebug=false --default-library static --wrap-mode nodownload "$@"
  fi
  meson compile -C "$out/$project" -j "$jobs"
  meson install -C "$out/$project" --no-rebuild
}

if [[ ! -f "$prefix/lib/libavcodec.a" ]]; then
  mkdir -p "$out/ffmpeg"
  pushd "$out/ffmpeg"
  extra=()
  if [[ $arch == x86_64 ]]; then extra=(--disable-x86asm); fi
  "$root/ffmpeg-8.0.3/configure" --prefix="$prefix" --cc="$clang" \
    --arch="$arch" --target-os=darwin --enable-cross-compile --sysroot="$sysroot" \
    --extra-cflags="-target $target -fvisibility=hidden" --extra-ldflags="-target $target" \
    --disable-autodetect --enable-static --disable-shared --disable-programs --disable-doc \
    --enable-debug=1 --disable-avdevice --enable-small \
    --disable-encoders --disable-muxers --enable-muxer=mp4 --disable-devices \
    --disable-filters --enable-filter=abuffer,abuffersink,aformat,anull,aresample,atempo,buffer,buffersink,format,null,scale,transpose,rotate,hflip,vflip,yadif,bwdif,overlay,volume,setpts,asetpts,hwdownload,hwupload \
    --disable-protocols --enable-protocol=file,pipe,crypto,data,http,https,tcp,tls,httpproxy,udp,rtp \
    --enable-securetransport --enable-zlib --enable-bzlib --enable-iconv --enable-videotoolbox \
    ${extra[@]+"${extra[@]}"}
  make -j "$jobs"
  make install
  popd
fi

if [[ ! -f "$prefix/lib/libplacebo.a" ]]; then
  build placebo libplacebo-7.351.0 -Dauto_features=disabled -Ddemos=false -Ddovi=disabled
fi
if [[ ! -f "$prefix/lib/libfribidi.a" ]]; then
  build fribidi fribidi-1.0.16 -Ddocs=false -Dbin=false -Dtests=false
fi
if [[ ! -f "$prefix/lib/libfreetype.a" ]]; then
  build freetype freetype-VER-2-14-1 -Dauto_features=disabled
fi
if [[ ! -f "$prefix/lib/libharfbuzz.a" ]]; then
  build harfbuzz harfbuzz-12.3.2 -Dauto_features=disabled -Dcoretext=enabled -Dtests=disabled -Ddocs=disabled
fi
if [[ ! -f "$prefix/lib/libass.a" ]]; then
  build ass libass-0.17.4 -Dauto_features=disabled -Dcoretext=enabled
fi
if [[ ! -f "$prefix/lib/libmpv.a" ]]; then
  build mpv mpv-0.41.0 -Dauto_features=disabled -Dgpl=false -Dcplayer=false -Dlibmpv=true \
    -Dgl=disabled -Daudiounit=enabled -Diconv=enabled -Dzlib=enabled -Dbuild-date=false
fi

framework="$out/SouloDecoder.framework"
mkdir -p "$framework/Headers" "$framework/Modules"
cp "$prefix/include/mpv/"{client,render,stream_cb}.h "$framework/Headers/"
printf '%s\n' 'framework module SouloDecoder {' '  header "client.h"' '  header "render.h"' '  header "stream_cb.h"' '  export *' '}' > "$framework/Modules/module.modulemap"
link_flags=$(pkg-config --static --libs mpv)
"$clang" -target "$target" -isysroot "$sysroot" -dynamiclib -dead_strip -fapplication-extension \
  -install_name '@rpath/SouloDecoder.framework/SouloDecoder' \
  -Wl,-exported_symbol,_mpv_\* -Wl,-force_load,"$prefix/lib/libmpv.a" \
  $link_flags -lc++ \
  -framework Foundation -framework CoreText -framework CoreGraphics -framework CoreFoundation \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework VideoToolbox \
  -framework AudioToolbox -framework AVFoundation -framework Security \
  -o "$framework/SouloDecoder"
python3 - "$sdk" "$framework/Info.plist" <<'PY'
import plistlib
import sys

platform = 'iPhoneOS' if sys.argv[1] == 'iphoneos' else 'iPhoneSimulator'
with open(sys.argv[2], 'wb') as info:
    plistlib.dump({
        'CFBundleDevelopmentRegion': 'en', 'CFBundleExecutable': 'SouloDecoder',
        'CFBundleIdentifier': 'com.dkluge.SouloDecoder', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'SouloDecoder', 'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': '0.41.0', 'CFBundleVersion': '1', 'MinimumOSVersion': '16.0',
        'CFBundleSupportedPlatforms': [platform],
    }, info)
PY
xcrun dsymutil "$framework/SouloDecoder" -o "$framework.dSYM"
dwarf="$framework.dSYM/Contents/Resources/DWARF/SouloDecoder"
if ! xcrun dwarfdump --debug-info "$dwarf" | awk '/DW_TAG_compile_unit/ { found = 1 } END { exit !found }'; then
  printf 'SouloDecoder dSYM has no debug information for %s\n' "$tag" >&2
  exit 1
fi
xcrun strip -x -S "$framework/SouloDecoder"
ls -lh "$framework/SouloDecoder"
