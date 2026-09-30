import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'api.dart';
import 'cancellation.dart';
import 'database.dart';
import 'downloads.dart';

class MediaUnavailable implements Exception {
  @override
  String toString() =>
      'YouTube did not allow playback of this video. It will be checked again at the next sync.';
}

class MediaStream {
  const MediaStream({
    required this.url,
    required this.identity,
    required this.userAgent,
  });
  final Uri url;
  final String identity;
  final String userAgent;
}

Future<void> downloadMedia(
  Api api,
  MediaStream source,
  File path, {
  required CancellationToken cancel,
  Transfer? transfer,
  Database? journal,
  String? operation,
}) async {
  cancel.throwIfCancelled();
  http.Request request(int start, int end, String? validator) {
    final result = http.Request('GET', source.url);
    result.headers.addAll({
      'Range': 'bytes=$start-$end',
      'Origin': 'https://youtube.com',
      'User-Agent': source.userAgent,
      if (validator != null) 'If-Range': validator,
    });
    return result;
  }

  final first = await api.sendExternal(request(0, 0, null));
  if (first.statusCode == 403) throw MediaUnavailable();
  if (first.statusCode != 206)
    throw StateError('Resolve download length: HTTP ${first.statusCode}');
  final contentRange = first.headers['content-range'];
  final match = RegExp(r'^bytes 0-0/(\d+)$').firstMatch(contentRange ?? '');
  if (match == null) throw StateError('Invalid initial media range');
  final total = int.parse(match[1]!);
  if (total <= 0 || total > 5000000000000)
    throw StateError('Invalid media length');
  final etag = first.headers['etag'];
  final validator = etag != null && !etag.startsWith('W/')
      ? etag
      : first.headers['last-modified'];
  final revision = validator ?? source.url.queryParameters['lmt'];
  await api.readBounded(first, 64 << 10);
  final identity =
      '${source.identity}:$total:${revision ?? DateTime.now().microsecondsSinceEpoch}';
  if (journal != null && operation != null)
    await journal.download(operation, p.basename(path.path), identity);
  await path.parent.create(recursive: true);
  final resized = await path.open(
    mode: path.existsSync() ? FileMode.append : FileMode.write,
  );
  try {
    await resized.truncate(total);
  } finally {
    await resized.close();
  }
  transfer?.startDownload(total);

  Future<void> one(int start) async {
    cancel.throwIfCancelled();
    final end = (start + rangeBytes).clamp(0, total) - 1;
    final length = end - start + 1;
    final file = await path.open(mode: FileMode.append);
    try {
      final savedHash = journal == null
          ? null
          : await journal.rangeHash(operation!, p.basename(path.path), start);
      if (savedHash != null) {
        await file.setPosition(start);
        final saved = await file.read(length);
        if (saved.length == length &&
            sha256.convert(saved).toString() == savedHash) {
          transfer?.range(start, length, RangePhase.complete);
          return;
        }
      }
      final response = await api.sendExternal(request(start, end, validator));
      if (response.statusCode == 403) throw MediaUnavailable();
      if (response.statusCode != 206)
        throw StateError(
          'Download range returned HTTP ${response.statusCode}; source may have changed',
        );
      if (response.headers['content-range'] != 'bytes $start-$end/$total')
        throw StateError('Media range differs from the requested bytes');
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        cancel.throwIfCancelled();
        if (bytes.length + chunk.length > length)
          throw StateError('Media range exceeded its declared length');
        bytes.addAll(chunk);
        transfer?.range(start, bytes.length, RangePhase.active);
      }
      if (bytes.length != length) throw StateError('Media range was truncated');
      await file.setPosition(start);
      await file.writeFrom(bytes);
      await file.flush();
      if (journal != null)
        await journal.saveRange(
          operation!,
          p.basename(path.path),
          start,
          sha256.convert(bytes).toString(),
        );
      transfer?.range(start, length, RangePhase.complete);
    } finally {
      await file.close();
    }
  }

  Object? firstError;
  StackTrace? firstStack;
  for (var base = 0; base < total; base += rangeBytes * rangesPerTransfer) {
    if (firstError != null) break;
    final work = <Future<void>>[];
    for (var index = 0; index < rangesPerTransfer; index++) {
      final start = base + index * rangeBytes;
      if (start < total) work.add(one(start));
    }
    final settled = await Future.wait(
      work.map((future) async {
        try {
          await future;
          return null;
        } catch (error, stack) {
          return (error, stack);
        }
      }),
    );
    for (final result in settled) {
      if (result != null) {
        firstError ??= result.$1;
        firstStack ??= result.$2;
      }
    }
  }
  if (firstError != null)
    Error.throwWithStackTrace(firstError, firstStack ?? StackTrace.current);
}
