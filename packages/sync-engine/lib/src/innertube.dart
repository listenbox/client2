import 'dart:convert';
import 'dart:typed_data';

import 'package:client_youtubei/client_youtubei.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'cancellation.dart';
import 'cookies.dart';
import 'download.dart';

class Video {
  const Video(this.id, this.title, this.durationSeconds);
  final String id;
  final String title;
  final int? durationSeconds;
}

class PlaylistSnapshot {
  const PlaylistSnapshot({
    required this.title,
    required this.present,
    required this.estimatedSeconds,
    required this.canRemove,
  });
  final String title;
  final List<Video> present;
  final int estimatedSeconds;
  final bool canRemove;
}

class Media {
  const Media({
    required this.title,
    required this.description,
    required this.publishedAt,
    required this.estimatedSeconds,
    required this.durationSeconds,
    required this.video,
    this.audio,
  });
  final String title;
  final String description;
  final int publishedAt;
  final int estimatedSeconds;
  final int? durationSeconds;
  final MediaStream video;
  final MediaStream? audio;
}

sealed class Playback {
  const Playback();
}

class Available extends Playback {
  const Available(this.media);
  final Media media;
}

class Unavailable extends Playback {
  const Unavailable(this.reason);
  final String reason;
}

class YouTube {
  YouTube._(this._runtime);
  final YouTubeRuntime _runtime;

  static Future<YouTube> open(
    Api api,
    CancellationToken cancel,
    CookieJar jar,
  ) async {
    final initialCookie = (await jar.snapshot()).headerFor(
      Uri.parse('https://www.youtube.com/'),
    );
    Future<YouTubeResponse> transport(YouTubeRequest input) async {
      cancel.throwIfCancelled();
      // Re-read on each request so cookie rotations are visible to later player
      // calls in the same scan. update() compares against this request's base.
      final snapshot = await jar.snapshot();
      final url = input.url;
      final host = url.host.toLowerCase();
      const allowed = [
        'youtube.com',
        'google.com',
        'googleapis.com',
        'googlevideo.com',
        'ytimg.com',
      ];
      if (url.scheme != 'https' ||
          !allowed.any((base) => host == base || host.endsWith('.$base'))) {
        throw const FormatException('unexpected YouTube API host');
      }
      final request = http.Request(input.method, url);
      for (final entry in input.headers.entries) {
        final lower = entry.key.toLowerCase();
        if (!{
          'cookie',
          'authorization',
          'x-goog-authuser',
          'x-goog-pageid',
          'host',
          'content-length',
        }.contains(lower)) {
          request.headers[entry.key] = entry.value;
        }
      }
      final cookie = snapshot.headerFor(url);
      if (cookie.isNotEmpty) {
        request.headers['cookie'] = cookie;
        if (host == 'www.youtube.com' && url.path.startsWith('/youtubei/')) {
          final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          final pairs = <String, String>{};
          for (final part in cookie.split('; ')) {
            final equal = part.indexOf('=');
            if (equal > 0)
              pairs[part.substring(0, equal)] = part.substring(equal + 1);
          }
          final signatures = <String>[];
          for (final entry in [
            ('SAPISIDHASH', pairs['SAPISID'] ?? pairs['__Secure-3PAPISID']),
            ('SAPISID1PHASH', pairs['__Secure-1PAPISID']),
            ('SAPISID3PHASH', pairs['__Secure-3PAPISID']),
          ]) {
            if (entry.$2 != null) {
              final digest = sha1.convert(
                utf8.encode('$timestamp ${entry.$2} https://www.youtube.com'),
              );
              signatures.add('${entry.$1} ${timestamp}_$digest');
            }
          }
          if (signatures.isNotEmpty) {
            request.headers['authorization'] = signatures.join(' ');
            request.headers['x-origin'] = 'https://www.youtube.com';
            request.headers['x-goog-authuser'] = '0';
          }
        }
      }
      if (input.body != null) request.bodyBytes = input.body!;
      final response = host == 'youtube.com' || host.endsWith('.youtube.com')
          ? await api.sendYouTube(request)
          : await api.sendExternal(request);
      final setCookies = response.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'set-cookie')
          .map((entry) => entry.value)
          .toList();
      if (setCookies.isNotEmpty) await jar.update(snapshot, url, setCookies);
      final bytes = await api.readBounded(response, 32 << 20);
      return YouTubeResponse(
        status: response.statusCode,
        headers: {
          for (final entry in response.headers.entries)
            entry.key: [entry.value],
        },
        body: Uint8List.fromList(bytes),
      );
    }

    final runtime = await YouTubeRuntime.open(
      transport: transport,
      cookie: initialCookie.isEmpty ? null : initialCookie,
      isCancelled: () => cancel.isCancelled,
    );
    return YouTube._(runtime);
  }

  Future<void> close() => _runtime.close();

  Future<PlaylistSnapshot> snapshot(String id) async {
    final listing = await _runtime.scanPlaylist(id);
    if (listing.parserFailed || listing.pages > 10000)
      throw const FormatException(
        'YouTube playlist could not be parsed completely; no changes were made',
      );
    var canRemove = true;
    for (final alert in listing.alerts) {
      if (alert.alertType == 'INFO' || alert.alertType == 'WARNING') {
        canRemove = false;
      } else {
        throw const FormatException('YouTube could not list this playlist');
      }
    }
    final seen = <String>{};
    final present = <Video>[];
    var estimated = 0;
    for (final entry in listing.entries) {
      final id = entry.id;
      if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
        throw const FormatException(
          'Playlist contains an unidentified unavailable item',
        );
      }
      if (entry.kind != 'PlaylistVideo' &&
          !(entry.kind == 'LockupView' &&
              {'VIDEO', 'SHORT'}.contains(entry.contentType))) {
        throw const FormatException(
          'Unsupported playlist item; listing is incomplete',
        );
      }
      if (!seen.add(id)) continue;
      final seconds =
          entry.durationSeconds ?? _badgeDuration(entry.durationBadges);
      final int known = seconds != null && seconds.isFinite && seconds > 0
          ? seconds.ceil()
          : 0;
      estimated += known;
      if (estimated > 1 << 53)
        throw const FormatException(
          'Playlist duration exceeds the supported range',
        );
      final bounded =
          seconds != null &&
              seconds.isFinite &&
              seconds > 0 &&
              seconds <= 7 * 24 * 3600
          ? seconds.toInt()
          : null;
      present.add(
        Video(
          id,
          entry.title?.trim().isNotEmpty == true
              ? entry.title!
              : 'YouTube video $id',
          bounded,
        ),
      );
    }
    final title = listing.title;
    if (title == null || title.isEmpty)
      throw const FormatException('YouTube playlist missing title');
    return PlaylistSnapshot(
      title: title,
      present: present,
      estimatedSeconds: estimated,
      canRemove: canRemove,
    );
  }

  Future<Playback> media(String id) async {
    YouTubeVideoInfo info;
    try {
      info = await _runtime.getVideoInfo(id);
    } on YouTubeException catch (error) {
      if (error.status == 'ERROR' || error.status == 'UNPLAYABLE') {
        return Unavailable(error.reason ?? 'Video unavailable');
      }
      if (error.status == 'LOGIN_REQUIRED') throw SignInRequired(error.reason);
      rethrow;
    }
    try {
      switch (info.status) {
        case 'OK':
          break;
        case 'UNPLAYABLE':
          return Unavailable(info.reason ?? 'Video unavailable');
        case 'LOGIN_REQUIRED':
          throw SignInRequired(info.reason);
        default:
          throw StateError(
            'YouTube could not resolve $id (${info.status}): ${info.reason ?? 'No reason supplied'}',
          );
      }
      if (info.isLive || info.isUpcoming)
        return const Unavailable(
          'Live or upcoming video; sync after it has finished',
        );
      final formats = info.formats;
      if (!formats.any((format) => format.hasUrl || format.hasCipher)) {
        throw StateError(
          'YouTube returned no downloadable stream URLs; video resolution is not the problem',
        );
      }
      final usable = formats
          .where(
            (format) =>
                format.drmFamilies.isEmpty &&
                !format.isTypeOtf &&
                (format.hasUrl || format.hasCipher),
          )
          .toList();
      final videos =
          usable
              .where(
                (format) =>
                    format.hasVideo &&
                    format.mimeType.contains('avc1') &&
                    format.height != null &&
                    format.height! > 0 &&
                    format.height! <= 1080,
              )
              .toList()
            ..sort((a, b) => b.height!.compareTo(a.height!));
      if (videos.isEmpty)
        throw StateError(
          'YouTube video has no AVC rendition at or below 1080p',
        );
      final chosen = videos.first;
      final audios =
          usable.where((format) => format.hasAudio && !format.hasVideo).toList()
            ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      if (!chosen.hasAudio && audios.isEmpty)
        throw StateError('YouTube video has no audio stream');
      if (info.id != id)
        throw StateError(
          'YouTube metadata video ID differs from the requested video',
        );
      final published = info.publishDate ?? info.uploadDate;
      if (published == null || published.isEmpty)
        throw StateError('YouTube video has no publication date');
      final date = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(published)
          ? DateTime.utc(
              int.parse(published.substring(0, 4)),
              int.parse(published.substring(5, 7)),
              int.parse(published.substring(8, 10)),
            )
          : DateTime.tryParse(published);
      if (date == null) throw StateError('YouTube publication date is invalid');
      final estimated =
          info.durationSeconds != null &&
              info.durationSeconds!.isFinite &&
              info.durationSeconds! > 0
          ? info.durationSeconds!.ceil()
          : 0;
      final duration =
          info.durationSeconds != null &&
              info.durationSeconds!.isFinite &&
              info.durationSeconds! > 0 &&
              info.durationSeconds! <= 7 * 24 * 3600
          ? info.durationSeconds!.toInt()
          : null;
      Future<MediaStream> stream(YouTubeFormat format) async {
        final url = await _runtime.decipherFormat(info, format);
        return MediaStream(
          url: url,
          identity: '${format.itag}:${format.mimeType}:${format.contentLength}',
          userAgent: _runtime.userAgent,
        );
      }

      return Available(
        Media(
          title: info.title ?? id,
          description: info.description ?? '',
          publishedAt: date.toUtc().millisecondsSinceEpoch,
          estimatedSeconds: estimated,
          durationSeconds: duration,
          video: await stream(chosen),
          audio: chosen.hasAudio ? null : await stream(audios.first),
        ),
      );
    } finally {
      await _runtime.releaseVideoInfo(info);
    }
  }
}

double? _badgeDuration(List<String> badges) {
  for (final badge in badges) {
    final parts = badge.split(':');
    if (parts.length < 2 ||
        parts.length > 3 ||
        parts.any((part) => !RegExp(r'^\d+$').hasMatch(part)))
      continue;
    var seconds = 0;
    var valid = true;
    for (var i = 0; i < parts.length; i++) {
      final number = int.parse(parts[i]);
      if (i > 0 && number >= 60) {
        valid = false;
        break;
      }
      seconds = seconds * 60 + number;
    }
    if (valid) return seconds.toDouble();
  }
  return null;
}
