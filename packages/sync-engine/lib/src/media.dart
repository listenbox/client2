import 'dart:io';

import 'audio.dart';
import 'native_media/ffmpeg_kit.dart';

class PreparedMedia {
  const PreparedMedia({
    required this.durationSeconds,
    required this.audioFile,
    required this.videoFile,
    required this.masterPlaylist,
    required this.files,
  });

  final int durationSeconds;
  final File audioFile;
  final File? videoFile;
  final File? masterPlaylist;
  final List<File> files;
}

/// Consumes `source-audio` for audio-only media, or `source-video` and
/// optional `source-audio` for video in [workingDirectory].
/// Only complete, validated outputs are returned for durable manifest creation.
Future<PreparedMedia> prepareMedia({
  required Directory workingDirectory,
  required bool audioOnly,
  required bool separateAudio,
  bool Function()? isCancelled,
  void Function(double fraction)? onProgress,
}) async {
  final sourceVideo = _file(workingDirectory, 'source-video');
  final sourceAudio = audioOnly || separateAudio
      ? _file(workingDirectory, 'source-audio')
      : sourceVideo;
  final audio = _file(workingDirectory, 'audio.m4a');
  final video = _file(workingDirectory, 'video.mp4');
  final hls = _directory(workingDirectory, 'hls');
  if (await audio.exists() || await video.exists() || await hls.exists()) {
    throw StateError('Prepared media output already exists');
  }
  if ((!audioOnly && !await sourceVideo.exists()) ||
      !await sourceAudio.exists()) {
    throw StateError('Downloaded media source is missing');
  }
  if (isCancelled?.call() ?? false) throw const MediaOperationCancelled();

  try {
    await prepareM4a(
      sourceAudio,
      audio,
      isCancelled: isCancelled,
      onProgress: (fraction) =>
          onProgress?.call(audioOnly ? fraction : fraction * 0.25),
    );
    if (audioOnly) {
      return PreparedMedia(
        durationSeconds: await preparedDuration(
          audio,
          isCancelled: isCancelled,
        ),
        audioFile: audio,
        videoFile: null,
        masterPlaylist: null,
        files: List.unmodifiable([audio]),
      );
    }

    final sourceDuration = await preparedDuration(
      sourceVideo,
      isCancelled: isCancelled,
    );
    await runMediaCommand(
      [
        '-hide_banner',
        '-nostdin',
        '-loglevel',
        'error',
        '-y',
        '-i',
        sourceVideo.path,
        '-i',
        audio.path,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        '-f',
        'mp4',
        video.path,
      ],
      isCancelled: isCancelled,
      expectedDurationSeconds: sourceDuration.toDouble(),
      onProgress: (fraction) => onProgress?.call(0.25 + fraction * 0.25),
    );
    if (!await hasFastStart(video)) {
      throw NativeMediaException('Prepared MP4 lacks fast start');
    }
    final dimensions = await _videoDimensions(video, isCancelled);
    final videoPlaylist = _file(hls, 'video/index.m3u8');
    final audioPlaylist = _file(hls, 'audio/index.m3u8');
    await videoPlaylist.parent.create(recursive: true);
    await audioPlaylist.parent.create(recursive: true);
    await _writeHls(
      video,
      videoPlaylist,
      'v',
      sourceDuration,
      isCancelled,
      (fraction) => onProgress?.call(0.5 + fraction * 0.25),
    );
    await _writeHls(
      video,
      audioPlaylist,
      'a',
      sourceDuration,
      isCancelled,
      (fraction) => onProgress?.call(0.75 + fraction * 0.25),
    );
    final videoDuration = await _playlistDuration(videoPlaylist);
    final audioDuration = await _playlistDuration(audioPlaylist);
    final duration = videoDuration < audioDuration
        ? videoDuration
        : audioDuration;
    final roundedDuration = duration.ceil();
    if (roundedDuration < 1 || roundedDuration > 604800) {
      throw NativeMediaException('Invalid HLS duration');
    }
    final master = _file(hls, 'master.m3u8');
    await master.writeAsString(
      '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n'
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,'
      'AUTOSELECT=YES,URI="audio/index.m3u8"\n'
      '#EXT-X-STREAM-INF:BANDWIDTH=12000000,RESOLUTION=$dimensions,AUDIO="audio"\n'
      'video/index.m3u8\n',
      flush: true,
    );
    final outputs = <File>[audio, video];
    await for (final entity in hls.list(recursive: true, followLinks: false)) {
      if (entity is File) outputs.add(entity);
    }
    outputs.sort((left, right) => left.path.compareTo(right.path));
    return PreparedMedia(
      durationSeconds: roundedDuration,
      audioFile: audio,
      videoFile: video,
      masterPlaylist: master,
      files: List.unmodifiable(outputs),
    );
  } catch (_) {
    if (await hls.exists()) await hls.delete(recursive: true);
    if (await video.exists()) await video.delete();
    if (await audio.exists()) await audio.delete();
    rethrow;
  }
}

Future<void> _writeHls(
  File input,
  File playlist,
  String stream,
  int duration,
  bool Function()? isCancelled,
  void Function(double fraction)? onProgress,
) async {
  final root = playlist.parent;
  // URI resolution would decode `%05` as a control byte in FFmpeg's template.
  final segment = File('${root.path}${Platform.pathSeparator}segment-%05d.m4s');
  await runMediaCommand(
    [
      '-hide_banner',
      '-nostdin',
      '-loglevel',
      'error',
      '-y',
      '-i',
      input.path,
      '-map',
      '0:$stream:0',
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_time',
      '6',
      '-hls_playlist_type',
      'vod',
      '-hls_segment_type',
      'fmp4',
      '-hls_fmp4_init_filename',
      'init.mp4',
      '-hls_segment_filename',
      _hlsPath(segment),
      _hlsPath(playlist),
    ],
    isCancelled: isCancelled,
    expectedDurationSeconds: duration.toDouble(),
    onProgress: onProgress,
  );
}

Future<String> _videoDimensions(File file, bool Function()? isCancelled) async {
  final info = await probeMedia(file.path, isCancelled: isCancelled);
  final video = info.firstStream('video');
  if (video == null || video.width < 1 || video.height < 1) {
    throw NativeMediaException('Prepared video has invalid dimensions');
  }
  return '${video.width}x${video.height}';
}

Future<double> _playlistDuration(File playlist) async {
  final text = await playlist.readAsString();
  if (!text.contains('#EXT-X-ENDLIST') ||
      !text.contains('#EXT-X-MAP:URI="init.mp4"')) {
    throw NativeMediaException('Incomplete HLS playlist: ${playlist.path}');
  }
  final init = _file(playlist.parent, 'init.mp4');
  if (!await init.exists() || await init.length() == 0) {
    throw NativeMediaException('Missing HLS initialization: ${playlist.path}');
  }
  var total = 0.0;
  var segments = 0;
  for (final line in text.split('\n')) {
    if (line.startsWith('#EXTINF:')) {
      final value = double.tryParse(line.substring(8).split(',').first);
      if (value == null || !value.isFinite || value <= 0) {
        throw NativeMediaException('Invalid HLS segment duration');
      }
      total += value;
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      if (!RegExp(r'^segment-\d+\.m4s$').hasMatch(line)) {
        throw NativeMediaException('Unsafe HLS segment path: $line');
      }
      final file = _file(playlist.parent, line);
      if (!await file.exists() || await file.length() == 0) {
        throw NativeMediaException('Missing HLS segment: $line');
      }
      segments++;
    }
  }
  if (segments < 1 || total <= 0 || !total.isFinite) {
    throw NativeMediaException('HLS playlist has no valid segments');
  }
  return total;
}

File _file(Directory root, String relative) =>
    File.fromUri(root.uri.resolve(relative));

Directory _directory(Directory root, String relative) =>
    Directory.fromUri(root.uri.resolve('$relative/'));

String _hlsPath(File file) => file.path.replaceAll('\\', '/');
