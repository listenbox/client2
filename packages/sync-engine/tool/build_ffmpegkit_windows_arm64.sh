#!/usr/bin/env bash
# Deliberate native artifact publication only. Run in MSYS2 CLANGARM64 on
# Windows 11 ARM64; normal Dart/Flutter builds never execute this script.
set -euo pipefail

if [[ "${MSYSTEM:-}" != CLANGARM64 ]]; then
  echo 'This recipe requires native MSYS2 CLANGARM64.' >&2
  exit 1
fi

builders_commit=4dc903c2a29741b8f9b61dd94b10185bae69a493
ffmpeg_version=9.0.1
ffmpeg_sha256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
work_root="${1:-$PWD/.ffmpegkit-arm64-build}"
mkdir -p "$work_root"
work_root="$(cd "$work_root" && pwd)"

git clone --quiet https://github.com/akashskypatel/ffmpeg-kit-builders.git "$work_root/builders"
git -C "$work_root/builders" checkout --quiet --detach "$builders_commit"
[[ "$(git -C "$work_root/builders" rev-parse HEAD)" == "$builders_commit" ]]

curl --fail --location --retry 3 \
  "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz" \
  --output "$work_root/ffmpeg.tar.xz"
printf '%s  %s\n' "$ffmpeg_sha256" "$work_root/ffmpeg.tar.xz" | sha256sum --check --status
tar -xf "$work_root/ffmpeg.tar.xz" -C "$work_root"

ffmpeg_source="$work_root/ffmpeg-${ffmpeg_version}"
ffmpeg_prefix="$work_root/ffmpeg-install"
cd "$ffmpeg_source"
./configure \
  --prefix="$ffmpeg_prefix" \
  --target-os=mingw32 --arch=aarch64 --cc=clang --cxx=clang++ \
  --disable-everything --disable-autodetect --disable-programs \
  --disable-doc --disable-debug --disable-network \
  --disable-shared --enable-static --enable-pic \
  --enable-avdevice --enable-avfilter --enable-swscale --enable-swresample \
  --enable-protocol=file \
  --enable-demuxer=mov,matroska,ogg,aac \
  --enable-muxer=ipod,mp4,hls,mpegts \
  --enable-decoder=aac,opus,vorbis,h264 \
  --enable-encoder=aac \
  --enable-parser=aac,opus,vorbis,h264 \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb \
  --enable-filter=abuffer,abuffersink,aformat,aresample,anull \
  --disable-asm
make -j4
make install-libs install-headers
cp config.h config_components.h "$ffmpeg_prefix/include/"

# The pinned upstream CMake file assumes x86 MinGW's libstdc++/libgcc and
# x86 stack flags. CLANGARM64 supplies libc++ through clang++ instead.
python3 - "$work_root/builders/FFmpegKit/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
replacements = {
    '"-static-libgcc"': '',
    '"-static-libstdc++"': '',
    '"-Wl,-u,__mingw_raise_matherr"': '',
    '"-Wl,--enable-runtime-pseudo-reloc"': '',
    '"-mstackrealign"': '',
    '"-mpreferred-stack-boundary=4"': '',
    '"-lstdc++"': '',
    '"-lgcc"': '',
    '"-lwinpthread"': '',
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f'Pinned FFmpegKit CMake input changed: {old}')
    source = source.replace(old, new)
path.write_text(source)
PY

export PKG_CONFIG_PATH="$ffmpeg_prefix/lib/pkgconfig:$MSYSTEM_PREFIX/lib/pkgconfig"
cmake -S "$work_root/builders/FFmpegKit" -B "$work_root/ffmpegkit-build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DFFMPEG_BUILD_DIR="$ffmpeg_prefix" \
  -DDEPENDENCY_BUILD_DIR="$MSYSTEM_PREFIX" \
  -DFFMPEG_KIT_BUNDLE_TYPE=base \
  -DFFMPEG_KIT_VERSION=0.11.1 \
  -DBUILD_SHARED_LIBS=ON -DFFMPEG_STATIC=ON
cmake --build "$work_root/ffmpegkit-build" --parallel 4

dll="$work_root/ffmpegkit-build/libffmpegkit.dll"
[[ -s "$dll" ]]
file "$dll" | grep -Eiq 'PE32.*(Aarch64|ARM64)'
objdump -p "$dll" | grep -q 'ffmpeg_kit_create_session_from_argv'
objdump -p "$dll" | grep -q 'ffprobe_kit_create_session_from_argv'

bundle="$work_root/bundle-base-windows-arm64-shared-small-lgpl"
mkdir -p "$bundle/bin" "$bundle/licenses"
cp "$dll" "$bundle/bin/"
cp "$work_root/builders/LICENSE" "$bundle/licenses/ffmpeg-kit_license.txt"
cp "$ffmpeg_source/COPYING.LGPLv2.1" "$bundle/licenses/ffmpeg_license.txt"
# Copy all non-Windows DLL imports recursively from the pinned CLANGARM64
# toolchain, including its libc++ runtime if the linker retained it dynamic.
declare -A scanned=()
queue=("$bundle/bin/libffmpegkit.dll")
while ((${#queue[@]})); do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ -z "${scanned[$current]:-}" ]] || continue
  scanned["$current"]=1
  while IFS= read -r name; do
    source_dll="$MSYSTEM_PREFIX/bin/$name"
    if [[ -f "$source_dll" ]]; then
      target_dll="$bundle/bin/$name"
      if [[ ! -f "$target_dll" ]]; then
        cp "$source_dll" "$target_dll"
        queue+=("$target_dll")
      fi
    fi
  done < <(objdump -p "$current" | sed -n 's/^[[:space:]]*DLL Name: //p')
done

cat > "$bundle/NOTICE.txt" <<EOF
FFmpegKit Extended source commit: $builders_commit
FFmpeg source: https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz
FFmpeg source SHA-256: $ffmpeg_sha256
Build: native MSYS2 CLANGARM64; LGPL, no GPL or nonfree options.
Licenses: see pinned upstream FFmpegKit and FFmpeg source repositories.
EOF
cd "$work_root"
zip -qr bundle-base-windows-arm64-shared-small-lgpl.zip \
  bundle-base-windows-arm64-shared-small-lgpl
sha256sum bundle-base-windows-arm64-shared-small-lgpl.zip
