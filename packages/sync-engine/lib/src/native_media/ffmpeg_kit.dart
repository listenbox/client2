// Adapted from ffmpeg_kit_extended_flutter 0.6.2 by Akash Patel.
// Copyright (C) 2026 Akash Patel. LGPL-2.1-or-later; see NOTICE.md.
// Only the pure C session API is used; no Flutter plugin or UI runtime is needed.
@DefaultAsset('package:listenbox_sync_engine/ffmpegkit')
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _Session = Pointer<Void>;

@Native<Void Function()>(symbol: 'ffmpeg_kit_initialize')
external void _initialize();

@Native<_Session Function(Int, Pointer<Pointer<Char>>)>(
  symbol: 'ffmpeg_kit_create_session_from_argv',
)
external _Session _createFfmpeg(int argc, Pointer<Pointer<Char>> argv);

@Native<Void Function(_Session)>(symbol: 'ffmpeg_kit_session_execute_async')
external void _executeFfmpeg(_Session session);

@Native<Void Function(Int64)>(symbol: 'ffmpeg_kit_cancel_session')
external void _cancelFfmpeg(int sessionId);

@Native<Int64 Function(_Session)>(symbol: 'ffmpeg_kit_session_get_session_id')
external int _sessionId(_Session session);

@Native<UnsignedInt Function(_Session)>(symbol: 'ffmpeg_kit_session_get_state')
external int _state(_Session session);

@Native<Int64 Function(_Session)>(symbol: 'ffmpeg_kit_session_get_return_code')
external int _returnCode(_Session session);

@Native<Pointer<Char> Function(_Session)>(
  symbol: 'ffmpeg_kit_session_get_output',
)
external Pointer<Char> _output(_Session session);

@Native<Pointer<Char> Function(_Session)>(
  symbol: 'ffmpeg_kit_session_get_logs_as_string',
)
external Pointer<Char> _logs(_Session session);

@Native<Void Function(Pointer<Void>)>(symbol: 'ffmpeg_kit_free')
external void _free(Pointer<Void> pointer);

@Native<Void Function(_Session)>(symbol: 'ffmpeg_kit_close_session')
external void _closeFfmpeg(_Session session);

@Native<Int64 Function(_Session)>(
  symbol: 'ffmpeg_kit_session_get_statistics_count',
)
external int _statisticsCount(_Session session);

@Native<_Session Function(_Session, Int64)>(
  symbol: 'ffmpeg_kit_session_get_statistics_at',
)
external _Session _statisticsAt(_Session session, int index);

@Native<Double Function(_Session)>(symbol: 'ffmpeg_kit_statistics_get_time')
external double _statisticsTime(_Session statistics);

@Native<Void Function(_Session)>(symbol: 'ffmpeg_kit_handle_release')
external void _release(_Session handle);

bool _initialized = false;

typedef _MediaInfoComplete = Void Function(_Session, Pointer<Void>);

@Native<_Session Function(Int, Pointer<Pointer<Char>>)>(
  symbol: 'media_information_create_session_from_argv',
)
external _Session _createMediaInfo(int argc, Pointer<Pointer<Char>> argv);

@Native<
  Void Function(
    _Session,
    Pointer<NativeFunction<_MediaInfoComplete>>,
    Pointer<Void>,
  )
>(symbol: 'media_information_kit_set_complete_callback')
external void _setMediaInfoComplete(
  _Session session,
  Pointer<NativeFunction<_MediaInfoComplete>> callback,
  Pointer<Void> userData,
);

@Native<Void Function(_Session, Int64)>(
  symbol: 'media_information_session_execute_async',
)
external void _executeMediaInfo(_Session session, int timeout);

@Native<_Session Function(_Session)>(
  symbol: 'media_information_session_get_media_information',
)
external _Session _mediaInfo(_Session session);

@Native<Pointer<Char> Function(_Session)>(
  symbol: 'media_information_get_duration',
)
external Pointer<Char> _mediaDuration(_Session info);

@Native<Int64 Function(_Session)>(symbol: 'media_information_get_streams_count')
external int _mediaStreamsCount(_Session info);

@Native<_Session Function(_Session, Int64)>(
  symbol: 'media_information_get_stream_at',
)
external _Session _mediaStreamAt(_Session info, int index);

@Native<Pointer<Char> Function(_Session)>(symbol: 'stream_information_get_type')
external Pointer<Char> _streamType(_Session stream);

@Native<Pointer<Char> Function(_Session)>(
  symbol: 'stream_information_get_codec',
)
external Pointer<Char> _streamCodec(_Session stream);

@Native<Int64 Function(_Session)>(symbol: 'stream_information_get_width')
external int _streamWidth(_Session stream);

@Native<Int64 Function(_Session)>(symbol: 'stream_information_get_height')
external int _streamHeight(_Session stream);

class MediaOperationCancelled implements Exception {
  const MediaOperationCancelled();

  @override
  String toString() => 'Media preparation cancelled';
}

class NativeMediaException implements Exception {
  NativeMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NativeMediaStream {
  const NativeMediaStream({
    required this.type,
    required this.codec,
    required this.width,
    required this.height,
  });

  final String type;
  final String codec;
  final int width;
  final int height;
}

class NativeMediaInfo {
  const NativeMediaInfo({required this.duration, required this.streams});

  final double duration;
  final List<NativeMediaStream> streams;

  NativeMediaStream? firstStream(String type) {
    for (final stream in streams) {
      if (stream.type == type) return stream;
    }
    return null;
  }
}

/// Reads FFprobe's parsed JSON from its private output buffer. FFmpegKit's
/// session `get_output` is a shared-log view, so it cannot provide probe data
/// when native media sessions overlap.
Future<NativeMediaInfo> probeMedia(
  String path, {
  bool Function()? isCancelled,
}) async {
  if (isCancelled?.call() ?? false) throw const MediaOperationCancelled();
  if (!_initialized) {
    _initialize();
    _initialized = true;
  }
  final arguments = <String>[
    '-v',
    'error',
    '-hide_banner',
    '-print_format',
    'json',
    '-show_format',
    '-show_streams',
    '-show_chapters',
    '-i',
    path,
  ];
  final argv = calloc<Pointer<Char>>(arguments.length);
  final strings = <Pointer<Utf8>>[];
  _Session session = nullptr;
  try {
    for (var index = 0; index < arguments.length; index++) {
      final value = arguments[index].toNativeUtf8(allocator: calloc);
      strings.add(value);
      argv[index] = value.cast<Char>();
    }
    session = _createMediaInfo(arguments.length, argv);
    if (session == nullptr) {
      throw NativeMediaException('Could not create a native media probe');
    }
  } finally {
    for (final value in strings) {
      calloc.free(value);
    }
    calloc.free(argv);
  }

  final completed = Completer<void>();
  void onComplete(_Session session, Pointer<Void> userData) {
    if (!completed.isCompleted) completed.complete();
  }

  final callback = NativeCallable<_MediaInfoComplete>.listener(onComplete);
  try {
    _setMediaInfoComplete(session, callback.nativeFunction, nullptr);
    _executeMediaInfo(session, 5000);
    var cancellationRequested = false;
    Object? callbackFailure;
    StackTrace? callbackFailureTrace;
    while (!completed.isCompleted) {
      if (!cancellationRequested) {
        try {
          cancellationRequested = isCancelled?.call() ?? false;
        } catch (error, trace) {
          callbackFailure = error;
          callbackFailureTrace = trace;
          cancellationRequested = true;
        }
        if (cancellationRequested) _cancelFfmpeg(_sessionId(session));
      }
      if (!completed.isCompleted) {
        await Future.any<void>([
          completed.future,
          Future<void>.delayed(const Duration(milliseconds: 50)),
        ]);
      }
    }
    if (callbackFailure != null) {
      Error.throwWithStackTrace(callbackFailure, callbackFailureTrace!);
    }
    if (cancellationRequested || (isCancelled?.call() ?? false)) {
      throw const MediaOperationCancelled();
    }
    final code = _returnCode(session);
    final info = _mediaInfo(session);
    if (code != 0 || info == nullptr || _state(session) != 2) {
      if (info != nullptr) _release(info);
      throw NativeMediaException(
        'FFprobe failed (code $code): ${_readNativeString(_logs(session))}'
            .trim(),
      );
    }
    try {
      final duration = double.tryParse(_readNativeString(_mediaDuration(info)));
      final streams = <NativeMediaStream>[];
      final count = _mediaStreamsCount(info);
      if (count < 0) throw NativeMediaException('Could not read media streams');
      for (var index = 0; index < count; index++) {
        final stream = _mediaStreamAt(info, index);
        if (stream == nullptr) {
          throw NativeMediaException('Could not read media stream $index');
        }
        try {
          streams.add(
            NativeMediaStream(
              type: _readNativeString(_streamType(stream)),
              codec: _readNativeString(_streamCodec(stream)),
              width: _streamWidth(stream),
              height: _streamHeight(stream),
            ),
          );
        } finally {
          _release(stream);
        }
      }
      return NativeMediaInfo(
        duration: duration ?? double.nan,
        streams: List.unmodifiable(streams),
      );
    } finally {
      _release(info);
    }
  } finally {
    callback.close();
    _release(session);
  }
}

/// Runs an argv session on FFmpegKit's native worker. The Dart isolate stays
/// available for UI and network events, and cancellation settles native work.
Future<String> runMediaCommand(
  List<String> arguments, {
  bool Function()? isCancelled,
  double? expectedDurationSeconds,
  void Function(double fraction)? onProgress,
}) async {
  if (isCancelled?.call() ?? false) throw const MediaOperationCancelled();
  if (!_initialized) {
    _initialize();
    _initialized = true;
  }
  final argv = calloc<Pointer<Char>>(arguments.length);
  final strings = <Pointer<Utf8>>[];
  _Session session = nullptr;
  try {
    for (var index = 0; index < arguments.length; index++) {
      final value = arguments[index].toNativeUtf8(allocator: calloc);
      strings.add(value);
      argv[index] = value.cast<Char>();
    }
    session = _createFfmpeg(arguments.length, argv);
    if (session == nullptr) {
      throw NativeMediaException('Could not create a native media session');
    }
  } finally {
    for (final value in strings) {
      calloc.free(value);
    }
    calloc.free(argv);
  }

  try {
    final id = _sessionId(session);
    _executeFfmpeg(session);
    var cancellationRequested = false;
    var lastStatisticsCount = 0;
    Object? callbackFailure;
    StackTrace? callbackFailureTrace;
    while (true) {
      final state = _state(session);
      if (state == 2 || state == 3) break;
      var shouldCancel = false;
      if (!cancellationRequested) {
        try {
          shouldCancel = isCancelled?.call() ?? false;
        } catch (error, trace) {
          callbackFailure = error;
          callbackFailureTrace = trace;
          shouldCancel = true;
        }
      }
      if (shouldCancel) {
        cancellationRequested = true;
        _cancelFfmpeg(id);
      }
      if (!cancellationRequested &&
          onProgress != null &&
          expectedDurationSeconds != null &&
          expectedDurationSeconds > 0) {
        final count = _statisticsCount(session);
        if (count > lastStatisticsCount) {
          lastStatisticsCount = count;
          final statistics = _statisticsAt(session, count - 1);
          if (statistics != nullptr) {
            try {
              final elapsed = _statisticsTime(statistics) / 1000;
              if (elapsed.isFinite) {
                try {
                  onProgress(
                    (elapsed / expectedDurationSeconds).clamp(0.0, 0.99),
                  );
                } catch (error, trace) {
                  callbackFailure = error;
                  callbackFailureTrace = trace;
                  cancellationRequested = true;
                  _cancelFfmpeg(id);
                }
              }
            } finally {
              _release(statistics);
            }
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (callbackFailure != null) {
      Error.throwWithStackTrace(callbackFailure, callbackFailureTrace!);
    }
    if (cancellationRequested || (isCancelled?.call() ?? false)) {
      throw const MediaOperationCancelled();
    }
    final result = _readNativeString(_output(session));
    final code = _returnCode(session);
    if (code != 0 || _state(session) != 2) {
      final logs = _readNativeString(_logs(session));
      throw NativeMediaException(
        'FFmpeg failed (code $code): '
                '${logs.isNotEmpty ? logs : result}'
            .trim(),
      );
    }
    onProgress?.call(1);
    return result;
  } finally {
    _closeFfmpeg(session);
    _release(session);
  }
}

String _readNativeString(Pointer<Char> value) {
  if (value == nullptr) return '';
  try {
    return value.cast<Utf8>().toDartString();
  } finally {
    _free(value.cast<Void>());
  }
}
