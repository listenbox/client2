#!/usr/bin/env bash
# Deliberate native artifact publication only. Normal client builds download
# pinned archives and never execute this source recipe.
set -euo pipefail

if [[ $# != 2 ]]; then
  echo 'usage: build_ffmpegkit_native.sh <macos-arm64|macos-x64|linux-x64|windows-x64> <new-work-directory>' >&2
  exit 2
fi

target="$1"
work_root="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
builders_commit=4dc903c2a29741b8f9b61dd94b10185bae69a493
ffmpeg_version=9.0.1
ffmpeg_sha256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635
jsoncpp_commit=89e2973c754a9c02a49974d839779b151e95afd6
sdl2_commit=98d1f3a45aae568ccd6ed5fec179330f47d4d356

case "$target" in
  macos-arm64)
    [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
      echo 'macos-arm64 requires a native Apple Silicon runner.' >&2; exit 1;
    }
    ffmpeg_os=darwin; ffmpeg_arch=aarch64; library=libffmpegkit.dylib
    bundle_name=bundle-base-macos-arm64-shared-small-lgpl
    ;;
  macos-x64)
    [[ "$(uname -s)" == Darwin && "$(uname -m)" == x86_64 ]] || {
      echo 'macos-x64 requires a native Intel macOS runner.' >&2; exit 1;
    }
    ffmpeg_os=darwin; ffmpeg_arch=x86_64; library=libffmpegkit.dylib
    bundle_name=bundle-base-macos-x64-shared-small-lgpl
    ;;
  linux-x64)
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
      echo 'linux-x64 requires a native x86-64 Linux runner.' >&2; exit 1;
    }
    ffmpeg_os=linux; ffmpeg_arch=x86_64; library=libffmpegkit.so
    bundle_name=bundle-base-linux-x64-shared-small-lgpl
    ;;
  windows-x64)
    [[ "${MSYSTEM:-}" == CLANG64 && "$(clang -dumpmachine)" == x86_64-*-windows-gnu ]] || {
      echo 'windows-x64 requires native MSYS2 CLANG64.' >&2; exit 1;
    }
    ffmpeg_os=mingw32; ffmpeg_arch=x86_64; library=libffmpegkit.dll
    bundle_name=bundle-base-windows-x64-shared-small-lgpl
    ;;
  *) echo "unsupported native target: $target" >&2; exit 2 ;;
esac

if [[ "$ffmpeg_os" == darwin ]]; then
  # Keep static dependencies on the same OS baseline as the shared library.
  export MACOSX_DEPLOYMENT_TARGET=11.0
fi

mkdir -p "$(dirname "$work_root")"
mkdir "$work_root"
work_root="$(cd "$work_root" && pwd)"
if ! command -v gsed >/dev/null; then
  mkdir "$work_root/tools"
  ln -s "$(command -v sed)" "$work_root/tools/gsed"
  export PATH="$work_root/tools:$PATH"
fi
git clone --quiet https://github.com/akashskypatel/ffmpeg-kit-builders.git "$work_root/builders"
git -C "$work_root/builders" checkout --quiet --detach "$builders_commit"
[[ "$(git -C "$work_root/builders" rev-parse HEAD)" == "$builders_commit" ]]
python3 "$script_dir/patch_ffmpegkit_signals.py" "$work_root/builders/FFmpegKit"
if [[ "$target" == linux-x64 || "$target" == windows-x64 ]]; then
  python3 "$script_dir/patch_ffmpegkit_publisher.py" "$target" "$work_root/builders/FFmpegKit"
fi

# The pinned upstream build uses jsoncpp 1.9.6 and SDL2 2.32.8. Build static
# copies so the published FFmpegKit library has no Homebrew/MSYS2 runtime
# dependency on those libraries.
dependency_prefix="$work_root/dependency-install"
git clone --quiet --depth 1 --branch 1.9.6 \
  https://github.com/open-source-parsers/jsoncpp.git "$work_root/jsoncpp"
[[ "$(git -C "$work_root/jsoncpp" rev-parse HEAD)" == "$jsoncpp_commit" ]]
cmake -S "$work_root/jsoncpp" -B "$work_root/jsoncpp-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_INSTALL_PREFIX="$dependency_prefix" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DJSONCPP_WITH_TESTS=OFF -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON
cmake --build "$work_root/jsoncpp-build" --parallel 4
cmake --install "$work_root/jsoncpp-build"

git clone --quiet --depth 1 --branch release-2.32.8 \
  https://github.com/libsdl-org/SDL.git "$work_root/sdl2"
[[ "$(git -C "$work_root/sdl2" rev-parse HEAD)" == "$sdl2_commit" ]]
cmake -S "$work_root/sdl2" -B "$work_root/sdl2-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_INSTALL_PREFIX="$dependency_prefix" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_STATIC_PIC=ON \
  -DSDL_TEST=OFF -DSDL_TESTS=OFF -DSDL_HIDAPI=OFF
cmake --build "$work_root/sdl2-build" --parallel 4
cmake --install "$work_root/sdl2-build"
[[ -s "$dependency_prefix/lib/libjsoncpp.a" ]]
[[ -s "$dependency_prefix/lib/libSDL2.a" ]]

curl --fail --location --retry 3 \
  "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz" \
  --output "$work_root/ffmpeg.tar.xz"
python3 - "$work_root/ffmpeg.tar.xz" "$ffmpeg_sha256" <<'PY'
import hashlib
from pathlib import Path
import sys

actual = hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit(f'FFmpeg source SHA-256 mismatch: {actual}')
PY
tar -xf "$work_root/ffmpeg.tar.xz" -C "$work_root"

ffmpeg_source="$work_root/ffmpeg-${ffmpeg_version}"
ffmpeg_prefix="$work_root/ffmpeg-install"
cd "$ffmpeg_source"
./configure \
  --prefix="$ffmpeg_prefix" \
  --target-os="$ffmpeg_os" --arch="$ffmpeg_arch" --cc=clang --cxx=clang++ \
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

if [[ "$target" == windows-x64 ]]; then
  # The pinned CMake guard checks MINGW before project() detects the compiler.
  # CLANG64 also uses libc++, so remove its x86 GCC runtime assumptions.
  python3 - "$work_root/builders/FFmpegKit/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
guard = '''# Enforce MinGW when building for Windows
if(WIN32 AND NOT MINGW)
    message(FATAL_ERROR "Windows builds require MinGW. Use MinGW-w64 toolchain for cross-compilation. MSVC is currently not supported.")
endif()
'''
project = 'project(ffmpeg-kit VERSION 8.0 LANGUAGES C CXX)'
if source.count(guard) != 1 or source.count(project) != 1:
    raise SystemExit('Pinned FFmpegKit CMake platform guard changed')
source = source.replace(guard, '').replace(project, project + '\n\n' + guard)
for old in (
    '"-static-libgcc"', '"-static-libstdc++"',
    '"-Wl,-u,__mingw_raise_matherr"', '"-Wl,--enable-runtime-pseudo-reloc"',
    '"-mstackrealign"', '"-mpreferred-stack-boundary=4"',
    '"-lstdc++"', '"-lgcc"', '"-lwinpthread"',
):
    if old not in source:
        raise SystemExit(f'Pinned FFmpegKit CMake input changed: {old}')
    source = source.replace(old, '')
path.write_text(source)
PY
fi
export PKG_CONFIG_PATH="$ffmpeg_prefix/lib/pkgconfig:$dependency_prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
for module in jsoncpp sdl2; do
  selected_libdir="$(pkg-config --variable=libdir "$module")"
  expected_libdir="$dependency_prefix/lib"
  if [[ "$target" == windows-x64 ]]; then
    # MSYS2 pkg-config returns drive-letter paths while Bash uses /d/... .
    selected_libdir="$(cygpath -m "$selected_libdir")"
    expected_libdir="$(cygpath -m "$expected_libdir")"
  fi
  [[ "$selected_libdir" == "$expected_libdir" ]] || {
    echo "Pinned static $module was not selected by pkg-config." >&2; exit 1;
  }
done

cmake_args=(
  -S "$work_root/builders/FFmpegKit" -B "$work_root/ffmpegkit-build"
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
  -DCMAKE_C_FLAGS="-iquote$ffmpeg_source"
  -DCMAKE_CXX_FLAGS="-iquote$ffmpeg_source"
  -DFFMPEG_SRC_DIR="$ffmpeg_source"
  -DFFMPEG_BUILD_DIR="$ffmpeg_prefix"
  -DDEPENDENCY_BUILD_DIR="$dependency_prefix"
  -DFFMPEG_KIT_BUNDLE_TYPE=base
  -DFFMPEG_KIT_VERSION=0.11.1
  -DBUILD_SHARED_LIBS=ON -DFFMPEG_STATIC=ON
)
if [[ "$ffmpeg_os" == darwin ]]; then
  [[ "$ffmpeg_arch" == aarch64 ]] && cmake_arch=arm64 || cmake_arch=x86_64
  cmake_args+=(
    -DCMAKE_OSX_ARCHITECTURES="$cmake_arch"
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)"
  )
fi
cmake "${cmake_args[@]}"
cmake --build "$work_root/ffmpegkit-build" --parallel 4

if [[ "$target" == windows-x64 ]]; then
  binary="$work_root/ffmpegkit-build/$library"
  [[ -s "$binary" ]]
  file "$binary" | grep -Ei 'PE32.*x86-64' >/dev/null
  objdump -p "$binary" | grep 'ffmpeg_kit_create_session_from_argv' >/dev/null
  objdump -p "$binary" | grep 'ffprobe_kit_create_session_from_argv' >/dev/null
  mkdir -p "$work_root/$bundle_name/bin"
  cp "$binary" "$work_root/$bundle_name/bin/"
  declare -A scanned=()
  queue=("$work_root/$bundle_name/bin/$library")
  windows_system_dir="$(cygpath -u "${WINDIR:?}")/System32"
  while ((${#queue[@]})); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -z "${scanned[$current]:-}" ]] || continue
    scanned["$current"]=1
    while IFS= read -r name; do
      source_dll="$MSYSTEM_PREFIX/bin/$name"
      if [[ -f "$source_dll" ]]; then
        target_dll="$work_root/$bundle_name/bin/$name"
        if [[ ! -f "$target_dll" ]]; then
          cp "$source_dll" "$target_dll"
          queue+=("$target_dll")
        fi
      elif [[ "${name,,}" == api-ms-win-* || "${name,,}" == ext-ms-win-* || -f "$windows_system_dir/$name" ]]; then
        : # Windows API set or OS-owned DLL.
      else
        echo "Unresolved non-system DLL import in $current: $name" >&2
        exit 1
      fi
    done < <(objdump -p "$current" | sed -n 's/^[[:space:]]*DLL Name: //p')
  done
else
  binary="$work_root/ffmpegkit-build/$library"
  [[ -s "$binary" ]]
  nm -g "$binary" | grep 'ffmpeg_kit_create_session_from_argv' >/dev/null
  nm -g "$binary" | grep 'ffprobe_kit_create_session_from_argv' >/dev/null
  if [[ "$target" == linux-x64 ]]; then
    file "$binary" | grep -Ei 'ELF 64-bit.*x86-64' >/dev/null
    if ldd "$binary" | grep 'not found' >/dev/null; then
      echo 'Unresolved Linux shared library dependency.' >&2; exit 1
    fi
  else
    file "$binary" | grep -F "$cmake_arch" >/dev/null
    if otool -L "$binary" | grep -Eq '/opt/homebrew|/usr/local'; then
      echo 'macOS binary retains a Homebrew runtime dependency.' >&2; exit 1
    fi
  fi
  mkdir -p "$work_root/$bundle_name/lib"
  cp "$binary" "$work_root/$bundle_name/lib/"
fi

mkdir -p "$work_root/$bundle_name/licenses"
cp "$work_root/builders/LICENSE" "$work_root/$bundle_name/licenses/ffmpeg-kit_license.txt"
cp "$ffmpeg_source/COPYING.LGPLv2.1" "$work_root/$bundle_name/licenses/ffmpeg_license.txt"
cp "$work_root/jsoncpp/LICENSE" "$work_root/$bundle_name/licenses/jsoncpp_license.txt"
cp "$work_root/sdl2/LICENSE.txt" "$work_root/$bundle_name/licenses/sdl2_license.txt"
cat > "$work_root/$bundle_name/NOTICE.txt" <<EOF
FFmpegKit Extended source commit: $builders_commit
FFmpeg source: https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz
FFmpeg source SHA-256: $ffmpeg_sha256
jsoncpp source commit: $jsoncpp_commit
SDL2 source commit: $sdl2_commit
Build: native $target; base LGPL bundle with explicit FFmpegKit cancellation.
Signal patch: packages/sync-engine/tool/patch_ffmpegkit_signals.py
EOF
cd "$work_root"
zip -qr "$bundle_name.zip" "$bundle_name"
python3 - "$bundle_name.zip" <<'PY'
import hashlib
from pathlib import Path
import sys

path = Path(sys.argv[1])
print(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}')
PY
