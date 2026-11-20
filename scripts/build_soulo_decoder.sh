#!/usr/bin/env bash
# Rebuild the pinned iOS playback framework. App builds use the checked-in artifact.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=${1:-$(mktemp -d /tmp/soulo-decoder-build.XXXXXX)}
mkdir -p "$work"
cd "$work"
work=$PWD
package="$repo/ThirdParty/SouloDecoder"

fetch() {
    local file=$1 sha=$2 url=$3
    if [[ ! -f "$file" ]]; then
        if ! curl --noproxy '*' --connect-timeout 8 --speed-time 8 --speed-limit 150000 -fsSL "$url" -o "$file.part"; then
            curl --connect-timeout 8 --fail --silent --show-error --location "$url" -o "$file.part"
        fi
        mv "$file.part" "$file"
    fi
    printf '%s  %s\n' "$sha" "$file" | shasum -a 256 --check --status
    tar xf "$file"
}

if [[ ! -f .soulo-sources-ready ]]; then
    fetch mpv.tar.gz ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209 \
        https://codeload.github.com/mpv-player/mpv/tar.gz/refs/tags/v0.41.0
    fetch ffmpeg.tar.xz 6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818 \
        https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz
    fetch libplacebo.tar.gz 716954501d9b76e6906fddda66febc5886493d0673dd265ec1e6e52f4e5cd7c6 \
        https://codeload.github.com/haasn/libplacebo/tar.gz/refs/tags/v7.351.0
    fetch vulkan.tar.gz 7c1874f9186d9e7d5245e279cdccaa77a66ed8f52871b428630aeb771dc7623c \
        https://codeload.github.com/KhronosGroup/Vulkan-Headers/tar.gz/refs/tags/v1.4.321
    fetch fastfloat.tar.gz e14a33089712b681d74d94e2a11362643bd7d769ae8f7e7caefe955f57f7eacd \
        https://codeload.github.com/fastfloat/fast_float/tar.gz/refs/tags/v8.0.2
    fetch libass.tar.gz c287d180d93dc9c9021872574b618ac49027e84cc90e1289318b1ee68bb42251 \
        https://codeload.github.com/libass/libass/tar.gz/refs/tags/0.17.4
    fetch fribidi.tar.gz 5a1d187a33daa58fcee2ad77f0eb9d136dd6fa4096239199ba31e850d397e8a8 \
        https://codeload.github.com/fribidi/fribidi/tar.gz/refs/tags/v1.0.16
    fetch freetype.tar.gz 44bd69d1f0750603410cfd4f26f1c5523c5a3a087a2dfa8639b757dc7c6677be \
        https://codeload.github.com/freetype/freetype/tar.gz/refs/tags/VER-2-14-1
    fetch harfbuzz.tar.xz 6f6db164359a2da5a84ef826615b448b33e6306067ad829d85d5b0bf936f1bb8 \
        https://github.com/harfbuzz/harfbuzz/releases/download/12.3.2/harfbuzz-12.3.2.tar.xz
    for entry in Vulkan-Headers fast_float; do
        rmdir "libplacebo-7.351.0/3rdparty/$entry"
    done
    mv Vulkan-Headers-1.4.321 libplacebo-7.351.0/3rdparty/Vulkan-Headers
    mv fast_float-8.0.2 libplacebo-7.351.0/3rdparty/fast_float
    patch -d mpv-0.41.0 -p1 < "$package/Patches/mpv-audio-session.patch"
    patch -d ffmpeg-8.0.3 -p1 < "$package/Patches/ffmpeg-http-cookie-scope.patch"
    touch .soulo-sources-ready
fi

if [[ ! -x tools/bin/meson ]]; then
    python3 -m venv tools
    if ! env -u ALL_PROXY -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u http_proxy -u https_proxy \
        tools/bin/pip install 'meson==1.11.2' 'ninja==1.13.2' 'jinja2==3.1.6'; then
        tools/bin/pip install 'meson==1.11.2' 'ninja==1.13.2' 'jinja2==3.1.6'
    fi
fi

jobs=$(sysctl -n hw.logicalcpu)
for sdk in iphoneos iphonesimulator; do
    "$package/build-slice.sh" "$work" "$sdk" arm64 "$jobs"
done
"$package/build-slice.sh" "$work" iphonesimulator x86_64 "$jobs"
out="$work/out-with-symbols"
device="$out/iphoneos-arm64/SouloDecoder.framework"
sim_arm="$out/iphonesimulator-arm64/SouloDecoder.framework"
sim_intel="$out/iphonesimulator-x86_64/SouloDecoder.framework"
sim="$out/ios-simulator/SouloDecoder.framework"
mkdir -p "$(dirname "$sim")"
ditto "$sim_arm" "$sim"
xcrun lipo -create "$sim_arm/SouloDecoder" "$sim_intel/SouloDecoder" -output "$sim/SouloDecoder"

dwarf_path=Contents/Resources/DWARF/SouloDecoder
ditto "$sim_arm.dSYM" "$sim.dSYM"
xcrun lipo -create "$sim_arm.dSYM/$dwarf_path" "$sim_intel.dSYM/$dwarf_path" -output "$sim.dSYM/$dwarf_path"

for framework in "$device" "$sim"; do
    binary_uuids=$(xcrun dwarfdump --uuid "$framework/SouloDecoder" | awk '/^UUID:/ { print $2, $3 }' | sort)
    symbol_uuids=$(xcrun dwarfdump --uuid "$framework.dSYM/$dwarf_path" | awk '/^UUID:/ { print $2, $3 }' | sort)
    if [[ -z "$binary_uuids" || "$binary_uuids" != "$symbol_uuids" ]]; then
        printf 'SouloDecoder dSYM UUID mismatch for %s\n' "$framework" >&2
        exit 1
    fi
done

stage=$(mktemp -d "$work/framework.XXXXXX")
xcodebuild -create-xcframework \
    -framework "$device" -debug-symbols "$device.dSYM" \
    -framework "$sim" -debug-symbols "$sim.dSYM" \
    -output "$stage/SouloDecoder.xcframework"
printf 'Built framework at %s/SouloDecoder.xcframework\n' "$stage"
