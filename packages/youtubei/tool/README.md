# Native FJS release recipe

The normal build hook consumes FJS only as published binaries in
`../native_artifacts.json`; it never compiles FJS or QuickJS from source.
The hook does compile a tiny Rust resource that embeds the pinned YouTube.js
source bundle. The Dart API comes from the exact pinned pub package `fjs`
3.3.0, including its QuickJS integration. Its native libraries must come from
that same package source. Upgrade the pub dependency, Dart API usage, and all
five native assets together; an older FJS library has a different binding ABI
and cannot fill a missing target.

On a native runner for each target, with Rust 1.98.1 and a C toolchain available,
run `dart run tool/build_native.dart <target> <output-directory>` from the
`client_youtubei` package. The script downloads the immutable pub.dev FJS 3.3.0
source archive, checks its pinned SHA-256, builds with Cargo `--locked`, and
prints the resulting library hash. The repository's Cargo config wraps that
manual build with the prebuilt Kache 0.27.0 executable, reusing compiled Rust
dependencies across checkouts without sharing a `target/` directory. Publish
the library as an immutable release asset; add its URL and hash to
`native_artifacts.json`. Required targets are
`macos-arm64`, `macos-x64`, `linux-x64`, `windows-x64`, and `windows-arm64`.
All five targets are pinned by URL and SHA-256 in `native_artifacts.json`.
macOS uses upstream FJS 3.3.0 release assets. Linux and Windows use the
immutable `listenbox/client2` release built from the same pinned FJS source.
