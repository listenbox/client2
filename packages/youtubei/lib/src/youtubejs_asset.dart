import 'dart:convert';
import 'dart:ffi';

/// Reads the immutable YouTube.js ESM bundle embedded by the build hook.
/// The native library only stores bytes; all runtime behavior remains in Dart.
String loadYoutubeJsBundle() {
  final length = _bundleLength();
  if (length <= 0) throw StateError('Embedded YouTube.js bundle is empty');
  return utf8.decode(_bundleData().asTypedList(length));
}

@Native<Pointer<Uint8> Function()>(
  symbol: 'listenbox_youtubejs_data',
  assetId: 'package:client_youtubei/src/youtubejs_asset.dart',
)
external Pointer<Uint8> _bundleData();

@Native<Size Function()>(
  symbol: 'listenbox_youtubejs_length',
  assetId: 'package:client_youtubei/src/youtubejs_asset.dart',
)
external int _bundleLength();
