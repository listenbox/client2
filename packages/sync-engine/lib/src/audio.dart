import 'dart:io';
import 'dart:math';

import 'native_media/ffmpeg_kit.dart';

/// Remuxes AAC or converts other audio (including Opus and Vorbis) to AAC.
/// The output is a new fast-start M4A file and is removed on any failure.
Future<int> prepareM4a(
  File input,
  File output, {
  bool Function()? isCancelled,
  void Function(double fraction)? onProgress,
}) async {
  if (input.absolute.path == output.absolute.path || await output.exists()) {
    throw ArgumentError('Audio output must be a new file');
  }
  if (isCancelled?.call() ?? false) throw const MediaOperationCancelled();
  try {
    final sourceInfo = await probeMedia(input.path, isCancelled: isCancelled);
    final codec = sourceInfo.firstStream('audio')?.codec ?? '';
    if (codec.isEmpty) throw NativeMediaException('Source has no audio stream');
    final duration = _validDuration(sourceInfo.duration);
    final arguments = <String>[
      '-hide_banner',
      '-nostdin',
      '-loglevel',
      'error',
      '-y',
      '-i',
      input.path,
      '-map',
      '0:a:0',
      '-vn',
      '-sn',
      '-dn',
      '-c:a',
      codec == 'aac' ? 'copy' : 'aac',
    ];
    if (codec != 'aac') {
      arguments.addAll(['-ar', '48000', '-ac', '2', '-b:a', '128k']);
    }
    arguments.addAll(['-movflags', '+faststart', '-f', 'ipod', output.path]);
    await runMediaCommand(
      arguments,
      isCancelled: isCancelled,
      expectedDurationSeconds: duration,
      onProgress: onProgress,
    );
    final bytes = await output.length();
    if (bytes == 0 || !await hasFastStart(output)) {
      throw NativeMediaException('Prepared M4A is empty or lacks fast start');
    }
    await preparedDuration(output);
    return bytes;
  } catch (_) {
    if (await output.exists()) await output.delete();
    rethrow;
  }
}

/// Whole seconds used for remote admission, with the media contract's bounds.
Future<int> preparedDuration(File file, {bool Function()? isCancelled}) async {
  final seconds = await _probeDuration(file, isCancelled);
  if (!seconds.isFinite || seconds < 0 || seconds > 604800) {
    throw NativeMediaException('Invalid prepared media duration');
  }
  final rounded = seconds.ceil();
  if (rounded < 1 || rounded > 604800) {
    throw NativeMediaException('Invalid prepared media duration');
  }
  return rounded;
}

Future<double> _probeDuration(File file, bool Function()? isCancelled) async {
  final info = await probeMedia(file.path, isCancelled: isCancelled);
  return _validDuration(info.duration);
}

double _validDuration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) {
    throw NativeMediaException('Invalid media duration: $seconds');
  }
  return seconds;
}

/// Checks the top-level ISO BMFF boxes; `moov` must precede `mdat`.
Future<bool> hasFastStart(File file) async {
  final reader = await file.open();
  try {
    final total = await reader.length();
    var offset = 0;
    while (offset + 8 <= total) {
      await reader.setPosition(offset);
      final header = await reader.read(8);
      if (header.length != 8) return false;
      var size = 0;
      for (var index = 0; index < 4; index++) {
        size = (size << 8) | header[index];
      }
      var headerSize = 8;
      if (size == 1) {
        final extended = await reader.read(8);
        if (extended.length != 8) return false;
        size = 0;
        for (final byte in extended) {
          size = (size << 8) | byte;
        }
        headerSize = 16;
      } else if (size == 0) {
        size = total - offset;
      }
      if (size < headerSize || size > total - offset) return false;
      final kind = String.fromCharCodes(header.sublist(4, 8));
      if (kind == 'moov') return true;
      if (kind == 'mdat') return false;
      offset += max(size, headerSize);
    }
    return false;
  } finally {
    await reader.close();
  }
}
