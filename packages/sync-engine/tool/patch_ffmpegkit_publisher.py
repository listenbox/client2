#!/usr/bin/env python3
"""Patch pinned FFmpegKit build wiring for native artifact publication."""

from hashlib import sha256
from pathlib import Path
import sys


EXPECTED = {
    "CMakeLists.txt": "ce7f20ca1d5d511df27913439ebfbc65e2d35f7abe6375ee1254af80aeb81932",
    "FfmpegKitDependencies.cmake": "eacb5c969a5ef926ca84bf2c81cc666e2c53f1e7c3d13299cfb348f4ef6f850c",
    "pthread_compat.h": "7d594ed89e95b4b047426f7c6572c0edd1e149b05b6c5006cbbfa203e88c66cb",
    # Applied after patch_ffmpegkit_signals.py has moved diagnostics to stderr.
    "FFmpegKitConfig.cpp": "74c4a6269a19837624411a372343f6cb92bb9df1a9854e8a731562dd530dce8d",
}


def replace_pinned(path: Path, before: str, after: str) -> None:
    data = path.read_bytes()
    actual = sha256(data).hexdigest()
    if actual != EXPECTED[path.name]:
        raise SystemExit(f"Pinned FFmpegKit build source changed: {path}: {actual}")
    source = data.decode()
    if source.count(before) != 1:
        raise SystemExit(f"Pinned FFmpegKit build block changed: {path}")
    path.write_text(source.replace(before, after))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: patch_ffmpegkit_publisher.py "
            "<linux-x64|windows-x64|windows-arm64> <FFmpegKit source directory>"
        )
    target, root = sys.argv[1], Path(sys.argv[2])
    if target == "linux-x64":
        # Whole-archive loads both FFmpeg framepool.o copies, which define the
        # same symbols. Archive groups resolve referenced members repeatedly
        # without forcing unrelated duplicate implementations into the DSO.
        replace_pinned(
            root / "CMakeLists.txt",
            '''        elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
            target_link_libraries(ffmpegkit PRIVATE
                "-Wl,--whole-archive"
                ${FFMPEG_STATIC_LIBS}
                ${ALSA_LIBRARIES}
                "-Wl,--no-whole-archive"
                ${BUNDLE_LIBRARIES}
            )''',
            '''        elseif(CMAKE_SYSTEM_NAME MATCHES "Linux")
            target_link_libraries(ffmpegkit PRIVATE
                "-Wl,--start-group"
                ${FFMPEG_STATIC_LIBS}
                ${BUNDLE_LIBRARIES}
                "-Wl,--end-group"
                ${ALSA_LIBRARIES}
            )''',
        )
    elif target in ("windows-x64", "windows-arm64"):
        # MSYS2 winpthreads uses an integer pthread_t. The upstream wrapper
        # derives from the unrelated pthreads-win32 struct ABI.
        pthread_header = root / "src" / "pthread_compat.h"
        source = pthread_header.read_text()
        wrapper_start = source.index("#ifdef __cplusplus\n#include <stdbool.h>")
        wrapper_end = source.index("#endif // _WIN32")
        replace_pinned(pthread_header, source[wrapper_start:wrapper_end], "")
        # A winpthreads ID is not a Windows HANDLE. Stop and notify the callback
        # loop above this block, then join it through the API that created it.
        replace_pinned(
            root / "src" / "FFmpegKitConfig.cpp",
            '''    // Windows implementation
    WaitForSingleObject((HANDLE)callbackThread, 5000);
    CloseHandle((HANDLE)callbackThread);''',
            '''    pthread_join(callbackThread, nullptr);''',
        )
        # Both FFmpeg archives carry a framepool.o implementation. Resolve
        # their referenced objects together with static dependencies, without
        # forcing both copies into the DLL.
        replace_pinned(
            root / "CMakeLists.txt",
            '''                # 2. FFmpeg core - whole-archive to prevent dead-stripping of
                #    codecs and muxers that are referenced only by string tables
                "-Wl,--whole-archive"
                ${FFMPEG_STATIC_LIBS}
                "-Wl,--no-whole-archive"

                # 3. External dependency libs from pkg-config (SDL2, openmpt, rist,
                #    etc.) - grouped to resolve circular references between them.
                #    This is the block that was previously misplaced after -Bdynamic.
                "-Wl,--start-group"
                ${BUNDLE_LIBRARIES}
                "-Wl,--end-group"''',
            '''                # 2. Resolve FFmpeg and its static dependencies as a group.
                #    This retains referenced codecs without loading duplicate
                #    framepool implementations from separate archives.
                "-Wl,--start-group"
                ${FFMPEG_STATIC_LIBS}
                ${BUNDLE_LIBRARIES}
                "-Wl,--end-group"''',
        )
        # Native Windows pkg-config uses ';' between directories. Upstream's
        # ':' joins a drive-letter path to the first existing directory.
        replace_pinned(
            root / "cmake" / "FfmpegKitDependencies.cmake",
            '''    message(STATUS "Setting PKG_CONFIG_PATH to: \\"${FFMPEG_BUILD_DIR}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}\\"")
    set(ENV{PKG_CONFIG_PATH} "${FFMPEG_BUILD_DIR}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")''',
            '''    message(STATUS "Setting PKG_CONFIG_PATH to: \\"${FFMPEG_BUILD_DIR}/lib/pkgconfig;$ENV{PKG_CONFIG_PATH}\\"")
    set(ENV{PKG_CONFIG_PATH} "${FFMPEG_BUILD_DIR}/lib/pkgconfig;$ENV{PKG_CONFIG_PATH}")''',
        )
    else:
        raise SystemExit(f"unsupported native publisher target: {target}")


if __name__ == "__main__":
    main()
