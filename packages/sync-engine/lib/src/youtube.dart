import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'database.dart';
import 'download.dart';
import 'downloads.dart';
import 'innertube.dart';
import 'media.dart';
import 'publicapi/models.dart' as publicapi;
import 'sync.dart';
import 'validation.dart' as validation;

bool isYouTubeSource(String source) {
  final url = Uri.tryParse(source);
  return url != null &&
      {
        'youtube.com',
        'www.youtube.com',
        'm.youtube.com',
        'youtu.be',
      }.contains(url.host);
}

String playlistSource(String source) {
  final url = Uri.tryParse(source.trim());
  if (url == null ||
      source.length > 2048 ||
      url.scheme != 'https' ||
      !{'youtube.com', 'www.youtube.com'}.contains(url.host) ||
      url.path != '/playlist' ||
      url.userInfo.isNotEmpty ||
      url.hasPort ||
      url.queryParametersAll['list']?.length != 1) {
    throw const FormatException(
      'Enter a public YouTube playlist URL, such as https://www.youtube.com/playlist?list=PL…',
    );
  }
  final id = url.queryParameters['list']!;
  if (id.length < 2 ||
      id.length > 200 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
    throw const FormatException(
      'Enter a public YouTube playlist URL, such as https://www.youtube.com/playlist?list=PL…',
    );
  }
  return 'https://www.youtube.com/playlist?list=$id';
}

Future<({Map<String, dynamic> show, Report report})> importPlaylist(
  Api api,
  Engine engine,
  String source,
  String kind, {
  String? requestedSlug,
  void Function(Map<String, dynamic>)? onCreated,
}) async {
  final url = Uri.tryParse(source);
  if (url == null ||
      !isYouTubeSource(source) ||
      url.scheme != 'https' ||
      url.userInfo.isNotEmpty ||
      url.hasPort) {
    throw const FormatException('invalid YouTube source URL');
  }
  final collection = url.queryParameters.containsKey('list')
      ? playlistSource(source)
      : null;
  final canonical = collection ?? _canonicalVideo(url);
  final digest = sha256.convert(canonical.codeUnits).toString();
  final slug = validation.slug(
    requestedSlug ?? 'youtube-${digest.substring(0, 16)}',
  );
  final shows = await api.publicClient.listShows();
  if (shows.any((show) => show.slug == slug)) {
    throw StateError(
      'Podcast "$slug" already exists. Use sync to resume an imported podcast, or choose a new slug.',
    );
  }
  final youtube = await YouTube.open(api, api.cancel, engine.cookies);
  PlaylistSnapshot snapshot;
  try {
    if (collection != null) {
      snapshot = await youtube.snapshot(
        Uri.parse(collection).queryParameters['list']!,
      );
    } else {
      final id = Uri.parse(canonical).queryParameters['v']!;
      final playback = await youtube.media(id);
      if (playback is Unavailable)
        throw StateError('YouTube playback unavailable: ${playback.reason}');
      final media = (playback as Available).media;
      snapshot = PlaylistSnapshot(
        title: media.title,
        present: [Video(id, media.title, media.durationSeconds)],
        estimatedSeconds: media.estimatedSeconds,
        canRemove: true,
      );
    }
  } finally {
    await youtube.close();
  }
  final capacity = await api.publicClient.getImportCapacity();
  if (!capacity.hasActiveSubscription) {
    throw const PaymentRequired(
      'A paid podcast plan is required for YouTube imports. Choose a plan, then try again.',
    );
  }
  if (kind == 'video') {
    if (!capacity.videoAllowed) {
      throw const PaymentRequired(
        'A video podcast plan is required to import this playlist as video. Upgrade your plan, then try again.',
      );
    }
    final remaining = capacity.videoRemainingSeconds;
    if (snapshot.estimatedSeconds > remaining) {
      throw PaymentRequired(
        'This playlist needs about ${(snapshot.estimatedSeconds / 3600).toStringAsFixed(2)} hours of video storage. Your team has ${(remaining / 3600).toStringAsFixed(2)} hours available. Upgrade your plan, then try again.',
      );
    }
  }
  if (!{'audio', 'video'}.contains(kind))
    throw const FormatException('invalid podcast source kind');
  final show = await api.publicClient.createShow(
    body: publicapi.CreateShow(
      id: 'shw_${const Uuid().v4().replaceAll('-', '').substring(0, 16)}',
      title: snapshot.title,
      slug: slug,
      sourceKind: publicapi.ShowSourceKind.fromJson(kind),
      language: 'en',
      youtubeSourceUrl: canonical,
    ),
  );
  final showJson = show.toJson().cast<String, dynamic>();
  onCreated?.call(showJson);
  try {
    final report = await engine.importSnapshot(api, slug, canonical, snapshot);
    return (show: showJson, report: report);
  } catch (error) {
    throw StateError(
      'Podcast "$slug" was created. Resume it with sync. $error',
    );
  }
}

String _canonicalVideo(Uri url) {
  final id = url.host == 'youtu.be'
      ? url.pathSegments.firstOrNull
      : (url.queryParameters['v'] ??
            (url.path.startsWith('/shorts/') || url.path.startsWith('/embed/')
                ? url.pathSegments.lastOrNull
                : null));
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id))
    throw const FormatException('invalid YouTube video ID');
  return 'https://www.youtube.com/watch?v=$id';
}

sealed class ImportOutcome {
  const ImportOutcome();
}

class Published extends ImportOutcome {
  const Published();
}

class Skipped extends ImportOutcome {
  const Skipped(this.reason);
  final String reason;
}

Future<ImportOutcome> importVideo(
  Api api,
  YouTube youtube,
  Database journal, {
  required String slug,
  required String id,
  required String collection,
  required bool audioOnly,
  Transfer? transfer,
}) async {
  final source = 'https://www.youtube.com/watch?v=$id';
  final operation = await journal.operation(
    api.config.apiOrigin,
    slug,
    source,
    collection,
  );
  final directory = await journal.directory(operation);
  var manifest = await journal.prepared(operation);
  if (manifest != null) {
    final objects = manifest['objects'];
    if (objects is! List)
      throw const FormatException('invalid prepared package manifest');
    for (final entry in objects) {
      if (entry is! Map<String, dynamic>)
        throw const FormatException('invalid prepared package object');
      final file = File(p.join(directory.path, entry['name'] as String));
      final hashed = await fileHash(file);
      if (hashed.$1 != entry['byte_length'] || hashed.$2 != entry['sha256']) {
        throw StateError(
          'Prepared media changed on disk; cannot resume this upload',
        );
      }
    }
  } else {
    for (final name in ['audio.m4a', 'video.mp4', 'hls']) {
      final entity = FileSystemEntity.typeSync(p.join(directory.path, name));
      if (entity == FileSystemEntityType.directory)
        Directory(p.join(directory.path, name)).deleteSync(recursive: true);
      if (entity == FileSystemEntityType.file)
        File(p.join(directory.path, name)).deleteSync();
    }
    final playback = await youtube.media(id);
    if (playback is Unavailable) return Skipped(playback.reason);
    final media = (playback as Available).media;
    transfer
      ?..title(media.title)
      ..duration(media.durationSeconds);
    try {
      if (audioOnly) {
        await downloadMedia(
          api,
          media.audio ?? media.video,
          File(p.join(directory.path, 'source-audio')),
          cancel: api.cancel,
          transfer: transfer,
          journal: journal,
          operation: operation,
        );
      } else {
        await downloadMedia(
          api,
          media.video,
          File(p.join(directory.path, 'source-video')),
          cancel: api.cancel,
          transfer: transfer,
          journal: journal,
          operation: operation,
        );
        if (media.audio != null) {
          await downloadMedia(
            api,
            media.audio!,
            File(p.join(directory.path, 'source-audio')),
            cancel: api.cancel,
            transfer: transfer,
            journal: journal,
            operation: operation,
          );
        }
      }
    } on MediaUnavailable catch (error) {
      return Skipped(error.toString());
    }
    transfer?.phase(Phase.preparing);
    final prepared = await prepareMedia(
      workingDirectory: directory,
      audioOnly: audioOnly,
      separateAudio: media.audio != null,
      isCancelled: () => api.cancel.isCancelled,
    );
    final objects = <publicapi.PreparedMediaObject>[];
    final files = prepared.files.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final name = p
          .relative(file.path, from: directory.path)
          .replaceAll('\\', '/');
      final hashed = await fileHash(file);
      final durable = await file.open(mode: FileMode.append);
      try {
        await durable.flush();
      } finally {
        await durable.close();
      }
      final contentType = name.endsWith('.m3u8')
          ? 'application/vnd.apple.mpegurl'
          : (name == 'audio.m4a' || name.startsWith('hls/audio/'))
          ? 'audio/mp4'
          : 'video/mp4';
      objects.add(
        publicapi.PreparedMediaObject(
          name: name,
          contentType: publicapi.PreparedMediaObjectContentType.fromJson(
            contentType,
          ),
          byteLength: hashed.$1,
          sha256: hashed.$2,
        ),
      );
    }
    manifest = publicapi.CreateEpisodePackage(
      showSlug: slug,
      sourceUrl: source,
      operationId: operation,
      title: media.title,
      description: media.description,
      durationSeconds: prepared.durationSeconds,
      publishedAt: media.publishedAt,
      objects: objects,
    ).toJson().cast<String, dynamic>();
    await journal.savePrepared(operation, manifest);
  }
  transfer?.phase(Phase.uploading);
  final session = await api.publicClient.createEpisodePackage(
    body: publicapi.CreateEpisodePackage.fromJson(manifest),
  );
  if (session.status == publicapi.EpisodePackageStatus.completed) {
    await journal.forget(api.config.apiOrigin, slug, source);
    return const Published();
  }
  if (session.status != publicapi.EpisodePackageStatus.uploading)
    throw StateError('Package session is ${session.status}');
  final sessionId = session.uploadSessionId;
  final partSize = session.partSize;
  if (partSize < 5 << 20)
    throw const FormatException('invalid package part size');
  await journal.session(operation, sessionId);
  final objects = manifest['objects'] as List;
  for (var ordinal = 0; ordinal < objects.length; ordinal++) {
    final object = objects[ordinal] as Map<String, dynamic>;
    final length = object['byte_length'] as int;
    var offset = 0;
    var number = 1;
    while (offset < length) {
      api.cancel.throwIfCancelled();
      final partLength = (length - offset).clamp(0, partSize);
      if (!await journal.hasPart(operation, ordinal, number)) {
        final signed = await api.publicClient.presignEpisodePackageParts(
          uploadSessionId: sessionId,
          objectIndex: ordinal,
          body: publicapi.PresignEpisodeUploadSessionParts(
            partNumbers: [number],
          ),
        );
        if (signed.parts.isEmpty) break;
        if (signed.parts.length != 1 ||
            signed.parts.single.partNumber != number)
          throw const FormatException('invalid signed package part');
        await uploadPart(
          api,
          File(p.join(directory.path, object['name'] as String)),
          offset,
          partLength,
          Uri.parse(signed.parts.single.uploadUrl),
        );
        await journal.savePart(operation, ordinal, number);
      }
      offset += partLength;
      number++;
    }
  }
  final completed = await api.publicClient.completeEpisodePackage(
    uploadSessionId: sessionId,
  );
  if (completed.status != publicapi.EpisodePackageStatus.completed)
    throw StateError('prepared media did not complete');
  await journal.forget(api.config.apiOrigin, slug, source);
  return const Published();
}

Future<(int, String)> fileHash(File file) async {
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0)
    throw StateError('media must be a non-empty regular file: ${file.path}');
  final hash = await sha256.bind(file.openRead()).first;
  return (stat.size, hash.toString());
}

Future<String> uploadPart(
  Api api,
  File file,
  int offset,
  int length,
  Uri url, {
  String method = 'PUT',
}) async {
  final request = http.Request(method, url);
  request.bodyBytes = await file
      .openRead(offset, offset + length)
      .expand((bytes) => bytes)
      .toList();
  if (request.bodyBytes.length != length)
    throw StateError('upload source part was truncated');
  request.headers['Content-Length'] = '$length';
  final response = await api.sendExternal(request);
  if (response.statusCode < 200 || response.statusCode >= 300)
    throw StateError('upload source part returned HTTP ${response.statusCode}');
  final etag = response.headers['etag'];
  if (etag == null) throw StateError('upload part returned no ETag');
  await api.readBounded(response, 64 << 10);
  return etag;
}
