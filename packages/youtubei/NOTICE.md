The QuickJS Dart API is the exact `fjs` 3.3.0 pub.dev package
(https://github.com/fluttercandies/fjs). Its generated bindings and license
remain upstream. The bundled native `libfjs` binaries are pinned to matching
FJS 3.3.0 source and flutter_rust_bridge 2.12.0 binding ABI. Their license is
retained in `FJS-LICENSE.txt` for binary distributions.

The YouTube.js source and license are in the pinned client workspace Git
submodule `vendor/youtubejs`. The ESM bundle is generated from that source.
