import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'config.dart';
import 'events.dart';
import 'publicapi/models.dart' as publicapi;
import 'validation.dart';
import 'youtube.dart' show fileHash, uploadPart;

Future<void> createEpisode(
  Api api, {
  required String show,
  required String title,
  required File file,
  String? description,
  String publication = 'publish',
  void Function(String)? onProgress,
}) async {
  if (!{'draft', 'publish'}.contains(publication))
    throw const FormatException('invalid publication');
  final path = file.absolute;
  final (length, hash) = await fileHash(path);
  final extension = p.extension(path.path).toLowerCase();
  final contentType = switch (extension) {
    '.mp3' => 'audio/mpeg',
    '.m4a' => 'audio/mp4',
    '.wav' => 'audio/wav',
    '.flac' => 'audio/flac',
    '.mp4' || '.m4v' => 'video/mp4',
    '.mov' => 'video/quicktime',
    _ => throw const FormatException(
      'unsupported media upload file; accepted extensions: .mp3, .m4a, .wav, .flac, .mp4, .m4v, .mov',
    ),
  };
  final key = sha256.convert(utf8.encode('$show\u0000$hash')).toString();
  final resumePath = p.join(
    api.config.directory,
    'episode-resume',
    '$key.json',
  );
  Map<String, dynamic> record;
  final resume = File(resumePath);
  if (resume.existsSync()) {
    final raw = jsonDecode(resume.readAsStringSync());
    if (raw is! Map<String, dynamic> ||
        raw['version'] != 1 ||
        raw['file_sha256'] != hash ||
        raw['file_byte_length'] != length) {
      throw const FormatException('invalid episode resume record');
    }
    record = raw;
    final expires = record['expires_at'];
    if (expires is! int ||
        (expires != 0 &&
            expires <= DateTime.now().millisecondsSinceEpoch &&
            !{
              'finalizing',
              'processing',
              'completed',
            }.contains(record['phase']))) {
      throw FormatException(
        'resumable upload expired; remove $resumePath to restart explicitly',
      );
    }
  } else {
    record = {
      'version': 1,
      'episode_id': '',
      'upload_session_id': '',
      'team_id': '',
      'show_id': '',
      'management_url': '',
      'file_path': path.path,
      'file_sha256': hash,
      'file_byte_length': length,
      'completed_parts': <Object>[],
      'expires_at': 0,
      'phase': 'prepared',
    };
  }
  if (!{'finalizing', 'processing', 'completed'}.contains(record['phase'])) {
    final response = await api.publicClient.createEpisodeUploadSession(
      body: publicapi.CreateEpisodeUploadSession(
        showSlug: show,
        title: title,
        fileName: p.basename(path.path),
        contentType: publicapi.EpisodeUploadContentType.fromJson(contentType),
        byteLength: length,
        sourceSha256: hash,
        description: description,
      ),
    );
    record['upload_session_id'] = response.uploadSessionId;
    record['team_id'] = response.teamId;
    record['show_id'] = response.showId;
    record['episode_id'] = response.episodeId ?? '';
    record['expires_at'] = response.expiresAt;
    record['phase'] = response.phase.value;
    record['completed_parts'] = response.completedParts
        .map((part) => part.toJson())
        .toList();
    writePrivateJson(resumePath, record);
    if (record['phase'] != 'finalizing') {
      final partSize = response.partSize;
      if (partSize < 5 << 20)
        throw StateError('invalid upload part size $partSize');
      final count = (length + partSize - 1) ~/ partSize;
      if (count > 10000)
        throw StateError('episode source requires too many parts');
      final completed = (record['completed_parts'] as List)
          .cast<Map<String, dynamic>>();
      final accepted = completed.map((part) => part['part_number']).toSet();
      final missing = [
        for (var number = 1; number <= count; number++)
          if (!accepted.contains(number)) number,
      ];
      _progress(record, onProgress);
      if (missing.isNotEmpty) {
        final signed = await api.publicClient.presignEpisodeUploadSessionParts(
          uploadSessionId: response.uploadSessionId,
          body: publicapi.PresignEpisodeUploadSessionParts(
            partNumbers: missing,
          ),
        );
        final pending = missing.toSet();
        for (final part in signed.parts) {
          final number = part.partNumber;
          if (!pending.remove(number))
            throw StateError('unexpected or duplicate signed part $number');
          final offset = (number - 1) * partSize;
          final size = (length - offset).clamp(0, partSize);
          final etag = await uploadPart(
            api,
            path,
            offset,
            size,
            Uri.parse(part.uploadUrl),
            method: part.method,
          );
          completed.add({'part_number': number, 'etag': etag, 'size': size});
          completed.sort(
            (a, b) =>
                (a['part_number'] as int).compareTo(b['part_number'] as int),
          );
          record['phase'] = 'uploading';
          writePrivateJson(resumePath, record);
          _progress(record, onProgress);
        }
        if (pending.isNotEmpty)
          throw const FormatException('signed response omitted upload parts');
      }
    }
    record['phase'] = 'finalizing';
    writePrivateJson(resumePath, record);
  }
  final episode = await api.publicClient.completeEpisodeUploadSession(
    uploadSessionId: record['upload_session_id'] as String,
    body: publicapi.CompleteEpisodeUploadSession(
      publication: publicapi.EpisodePublication.fromJson(publication),
    ),
  );
  record['episode_id'] = episode.id;
  record['show_id'] = episode.showId;
  final episodeId = record['episode_id'] as String;
  if (!validId(episodeId, 'ep_'))
    throw const FormatException('invalid episode management identifier');
  record['management_url'] =
      '${api.config.showUrl(record['team_id'] as String, record['show_id'] as String)}/episodes/$episodeId/edit';
  record['phase'] = 'processing';
  writePrivateJson(resumePath, record);
  final eventResponse = await api.publicClient.episodeUploadSessionEvents(
    uploadSessionId: record['upload_session_id'] as String,
  );
  final events = await EventStream.fromResponse(api, eventResponse);
  try {
    while (true) {
      final event = await events.next();
      switch (jsonString(event, 'type')) {
        case 'episode.processing.progress':
          final progress = publicapi.EpisodeProcessingProgressEvent.fromJson(
            event,
          );
          final percent = progress.percent;
          if (percent < 0 || percent > 100)
            throw const FormatException('invalid processing progress');
          onProgress?.call('Episode processing: $percent%');
        case 'episode.processing.safe_handoff':
          record['phase'] = 'completed';
          writePrivateJson(resumePath, record);
          onProgress?.call(
            '${publication == 'publish' ? 'Published episode' : 'Created draft episode'} "$title"\nOpen in Listenbox: ${record['management_url']}',
          );
          final handoff = publicapi.EpisodeProcessingSafeHandoffEvent.fromJson(
            event,
          );
          final video = handoff.youtubeVideoId;
          if (video is String && video.isNotEmpty)
            onProgress?.call(
              'YouTube (processing): https://www.youtube.com/watch?v=$video',
            );
          return;
        case 'episode.processing.failed':
          final failure = publicapi.EpisodeProcessingFailedEvent.fromJson(
            event,
          );
          throw StateError(
            'episode processing failed (${failure.errorCode}): ${failure.errorMessage}',
          );
        default:
          throw FormatException(
            'unknown episode processing event ${event['type']}',
          );
      }
    }
  } finally {
    await events.close();
  }
}

void _progress(Map<String, dynamic> record, void Function(String)? callback) {
  final completed = record['completed_parts'] as List;
  final saved = completed.fold<int>(
    0,
    (sum, part) => sum + ((part as Map<String, dynamic>)['size'] as int),
  );
  callback?.call(
    'Source upload: ${(saved * 100 ~/ (record['file_byte_length'] as int)).clamp(0, 100)}% saved',
  );
}
