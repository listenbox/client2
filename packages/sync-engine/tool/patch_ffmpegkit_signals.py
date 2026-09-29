#!/usr/bin/env python3
"""Keep process ownership of signals, terminal, and stdout with the Dart VM.

Run only in deliberate native artifact publication, after checking out pinned
ffmpeg-kit-builders commit 4dc903c2a29741b8f9b61dd94b10185bae69a493.
Normal client builds download and verify the resulting shared libraries.
"""

from hashlib import sha256
from pathlib import Path
import sys


EXPECTED = {
    "ffmpeg.c": "ab4091c379045ff85823d9e231f5f97c59df1aaf9e4cfed0fa86b530ff7fcd6e",
    "ffmpeg_opt.c": "d77ef3fc0c7e17ea5bc3dcb511559d117cc80b5af3909c0a587420d92ed707d6",
    "AbstractSession.cpp": "53a7c16d606a551cac6cc356abcb6030fedcd42271cc2dee9cb1ab9a567fa63b",
    "MediaInformationJsonParser.cpp": "70cc18c6184890347e6ff683c3b2738f0dcaa1034c95caca186b4b51ca918ab2",
    "FFmpegKitConfig.cpp": "b0dc660962f6c296f949bee302117196d56a9689a498df844e2f640e1bf9b88d",
    "FFmpegSession.cpp": "29df4532352a4eaaae1d91caba0caff7da1c9b7b737671fced62d26a4a91c625",
    "AppleResourceGen.cmake": "68d1424fd91f2191d4395d203caa01f377e1bbea49635810a8decff93ab33ce9",
}


def pinned_source(path: Path) -> str:
    data = path.read_bytes()
    actual = sha256(data).hexdigest()
    if actual != EXPECTED[path.name]:
        raise SystemExit(f"Pinned FFmpegKit source changed: {path}: {actual}")
    return data.decode()


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise SystemExit("Pinned FFmpegKit signal handling source changed")
    return source.replace(before, after)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_ffmpegkit_signals.py <FFmpegKit source directory>")
    src = Path(sys.argv[1]) / "src"
    ffmpeg = src / "ffmpeg.c"
    options = src / "ffmpeg_opt.c"
    ffmpeg_source = pinned_source(ffmpeg)
    options_source = pinned_source(options)

    start = "void term_init(void)\n{\n"
    end = "\n}\n\n/* read a key without blocking */"
    if ffmpeg_source.count(start) != 1 or ffmpeg_source.count(end) != 1:
        raise SystemExit("Pinned FFmpegKit term_init boundary changed")
    before, rest = ffmpeg_source.split(start, 1)
    _, after = rest.split(end, 1)
    ffmpeg_source = (
        before
        + start
        + "    /* Embedded FFmpegKit never owns process signals or terminal state.\n"
        + "     * The Dart host cancels individual sessions via ffmpeg_kit_cancel_session. */"
        + end
        + after
    )
    options_source = replace_once(
        options_source,
        "                signal(SIGINT, SIG_DFL);\n",
        "                /* The embedding host retains its SIGINT handler. */\n",
    )
    ffmpeg.write_text(ffmpeg_source)
    options.write_text(options_source)

    # The host CLI reserves stdout for machine-readable results. FFmpegKit's
    # diagnostics, including initialization, log callback, and shutdown output,
    # remain visible on stderr alongside Dart's own progress and errors.
    for name in (
        "AbstractSession.cpp",
        "MediaInformationJsonParser.cpp",
        "FFmpegKitConfig.cpp",
        "FFmpegSession.cpp",
    ):
        path = src / name
        text = pinned_source(path)
        if "std::cout" not in text:
            raise SystemExit(f"Pinned FFmpegKit diagnostics changed: {path}")
        path.write_text(text.replace("std::cout", "std::cerr"))

    # bin2c runs during CMake configure, so it must use the build host CPU.
    # The pinned source forces ARM64 even on the macOS x64 publication runner.
    resource_gen = Path(sys.argv[1]) / "cmake" / "AppleResourceGen.cmake"
    cmake = pinned_source(resource_gen)
    resource_gen.write_text(
        replace_once(cmake, "\t\t\t\t-target arm64-apple-macos13.0\n", "")
    )


if __name__ == "__main__":
    main()
