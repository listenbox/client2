/// Embedded YouTube.js bindings. The caller owns HTTP policy, cookies, format
/// selection, and cancellation of its transport.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:fjs/fjs.dart';

import 'src/youtubejs_asset.dart';
import 'src/youtubejs_host.dart';

typedef YouTubeTransport = Future<YouTubeResponse> Function(
  YouTubeRequest request,
);

final class YouTubeRequest {
  const YouTubeRequest({
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final Uint8List? body;
}

final class YouTubeResponse {
  const YouTubeResponse({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final Map<String, List<String>> headers;
  final Uint8List body;
}

final class YouTubeException implements Exception {
  const YouTubeException(this.message, {this.status, this.reason});
  final String message;
  final String? status;
  final String? reason;

  @override
  String toString() => 'YouTubeException: $message';
}

final class YouTubePlaylistEntry {
  const YouTubePlaylistEntry({
    required this.kind,
    required this.id,
    required this.title,
    required this.durationSeconds,
    required this.contentType,
    required this.durationBadges,
  });
  final String kind;
  final String? id;
  final String? title;
  final double? durationSeconds;
  final String? contentType;
  final List<String> durationBadges;
}

final class YouTubePlaylistAlert {
  const YouTubePlaylistAlert(this.kind, this.alertType);
  final String kind;
  final String? alertType;
}

final class YouTubePlaylistListing {
  const YouTubePlaylistListing({
    required this.title,
    required this.entries,
    required this.alerts,
    required this.parserFailed,
    required this.pages,
  });
  final String? title;
  final List<YouTubePlaylistEntry> entries;
  final List<YouTubePlaylistAlert> alerts;
  final bool parserFailed;
  final int pages;
}

final class YouTubeFormat {
  const YouTubeFormat({
    required this.index,
    required this.itag,
    required this.mimeType,
    required this.bitrate,
    required this.height,
    required this.hasAudio,
    required this.hasVideo,
    required this.isTypeOtf,
    required this.drmFamilies,
    required this.contentLength,
    required this.hasUrl,
    required this.hasCipher,
  });
  final int index;
  final int itag;
  final String mimeType;
  final double bitrate;
  final double? height;
  final bool hasAudio;
  final bool hasVideo;
  final bool isTypeOtf;
  final List<String> drmFamilies;
  final double? contentLength;
  final bool hasUrl;
  final bool hasCipher;
}

final class YouTubeVideoInfo {
  const YouTubeVideoInfo({
    required this.handle,
    required this.id,
    required this.title,
    required this.description,
    required this.durationSeconds,
    required this.isLive,
    required this.isUpcoming,
    required this.status,
    required this.reason,
    required this.publishDate,
    required this.uploadDate,
    required this.cpn,
    required this.formats,
  });
  final int handle;
  final String? id;
  final String? title;
  final String? description;
  final double? durationSeconds;
  final bool isLive;
  final bool isUpcoming;
  final String? status;
  final String? reason;
  final String? publishDate;
  final String? uploadDate;
  final String cpn;
  final List<YouTubeFormat> formats;
}

/// Owns a QuickJS worker isolate and brokers its HTTP requests through the
/// caller's transport. The application never runs JavaScript on its isolate.
final class YouTubeRuntime {
  YouTubeRuntime._(this._transport, this._isCancelled);

  final YouTubeTransport _transport;
  final bool Function()? _isCancelled;
  final ReceivePort _messages = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  final Map<int, Completer<Object?>> _pending = {};
  final Set<SendPort> _fetchReplies = {};
  Isolate? _worker;
  SendPort? _commands;
  int _nextRequest = 0;
  bool _closed = false;
  bool _portsClosed = false;
  Future<void>? _closeFuture;
  String userAgent = '';

  /// Starts a private isolate which owns all FJS state and the YouTube.js
  /// session. [transport] runs in the caller isolate and can use its cookie
  /// snapshot, proxy settings, and cancellation policy.
  static Future<YouTubeRuntime> open({
    String? nativeLibraryPath,
    required YouTubeTransport transport,
    String? cookie,
    bool Function()? isCancelled,
  }) async {
    final runtime = YouTubeRuntime._(transport, isCancelled);
    runtime._messages.listen(runtime._onMessage);
    runtime._errors.listen(
      (message) => runtime._workerFailed(
        YouTubeException('QuickJS worker failed: $message'),
      ),
    );
    runtime._exits.listen((_) {
      if (!runtime._exited.isCompleted) runtime._exited.complete();
      if (!runtime._closed)
        runtime._workerFailed(const YouTubeException('QuickJS worker exited'));
    });
    try {
      runtime._worker = await Isolate.spawn<_WorkerStart>(
        _youtubeWorker,
        _WorkerStart(
          runtime._messages.sendPort,
          nativeLibraryPath ?? bundledNativeLibraryPath(),
          cookie,
        ),
        onError: runtime._errors.sendPort,
        onExit: runtime._exits.sendPort,
      );
      await runtime._ready.future;
      return runtime;
    } catch (_) {
      runtime._worker?.kill(priority: Isolate.immediate);
      runtime._closePorts();
      rethrow;
    }
  }

  /// Finds the verified native library copied into a CLI or desktop bundle.
  static String bundledNativeLibraryPath() {
    final executable = File(Platform.resolvedExecutable).absolute;
    final directory = executable.parent;
    final filename = switch (Platform.operatingSystem) {
      'macos' => 'libfjs.dylib',
      'linux' => 'libfjs.so',
      'windows' => 'fjs.dll',
      _ => throw UnsupportedError('YouTube QuickJS requires a desktop target'),
    };
    final candidates = <String>[
      '${directory.path}${Platform.pathSeparator}$filename',
      '${directory.path}${Platform.pathSeparator}lib${Platform.pathSeparator}$filename',
      '${directory.parent.path}${Platform.pathSeparator}lib${Platform.pathSeparator}$filename',
      '${directory.parent.path}${Platform.pathSeparator}Frameworks${Platform.pathSeparator}$filename',
      '${directory.parent.path}${Platform.pathSeparator}Frameworks${Platform.pathSeparator}fjs.framework${Platform.pathSeparator}fjs',
    ];
    if (Platform.script.scheme == 'file') {
      var sourceDirectory = File.fromUri(Platform.script).absolute.parent;
      for (var depth = 0; depth < 6; depth++) {
        candidates.add(
          '${sourceDirectory.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}lib${Platform.pathSeparator}$filename',
        );
        final parent = sourceDirectory.parent;
        if (parent.path == sourceDirectory.path) break;
        sourceDirectory = parent;
      }
    }
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    throw YouTubeException(
      'Bundled QuickJS library is missing beside $executable',
    );
  }

  void _onMessage(dynamic message) {
    final values = message as List<Object?>;
    switch (values[0]) {
      case 'ready':
        _commands = values[1] as SendPort;
        userAgent = values[2] as String;
        if (!_ready.isCompleted) _ready.complete();
      case 'fetch':
        _serveFetch(values[1] as YouTubeRequest, values[2] as SendPort);
      case 'result':
        _pending.remove(values[1] as int)?.complete(values[2]);
      case 'error':
        _pending
            .remove(values[1] as int)
            ?.completeError(YouTubeException(values[2] as String));
      case 'fatal':
        _workerFailed(YouTubeException(values[1] as String));
    }
  }

  Future<void> _serveFetch(YouTubeRequest request, SendPort reply) async {
    if (_closed || (_isCancelled?.call() ?? false)) {
      reply.send(['error', 'YouTube operation cancelled']);
      return;
    }
    _fetchReplies.add(reply);
    try {
      final response = await _transport(request);
      if (_fetchReplies.remove(reply)) {
        reply.send(
          _closed || (_isCancelled?.call() ?? false)
              ? ['error', 'YouTube operation cancelled']
              : ['ok', response],
        );
      }
    } catch (error) {
      if (_fetchReplies.remove(reply)) reply.send(['error', '$error']);
    }
  }

  void _failAll(YouTubeException error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    for (final reply in _fetchReplies) {
      reply.send(['error', error.message]);
    }
    _fetchReplies.clear();
  }

  void _workerFailed(YouTubeException error) {
    _closed = true;
    _failAll(error);
    _worker?.kill(priority: Isolate.immediate);
    _closePorts();
  }

  Future<T> _invoke<T>(String method, [Object? argument]) async {
    if (_closed || (_isCancelled?.call() ?? false)) {
      throw const YouTubeException('YouTube operation cancelled');
    }
    final id = ++_nextRequest;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands!.send([id, method, argument]);
    return await result.future as T;
  }

  Future<YouTubePlaylistListing> scanPlaylist(String id) =>
      _invoke<YouTubePlaylistListing>('scanPlaylist', id);

  Future<YouTubeVideoInfo> getVideoInfo(String id) =>
      _invoke<YouTubeVideoInfo>('getVideoInfo', id);

  Future<Uri> decipherFormat(YouTubeVideoInfo info, YouTubeFormat format) =>
      _invoke<Uri>('decipherFormat', [info, format]);

  Future<void> releaseVideoInfo(YouTubeVideoInfo info) =>
      _invoke<void>('releaseVideoInfo', info);

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _failAll(const YouTubeException('YouTube operation cancelled'));
    final id = ++_nextRequest;
    final result = Completer<Object?>();
    _pending[id] = result;
    _commands?.send([id, 'close', null]);
    try {
      // Network waits are cancelled through the transport replies above. The
      // guard only terminates a worker stuck in synchronous JavaScript.
      await Future.any<void>([result.future.then((_) {}), _exited.future])
          .timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _worker?.kill(priority: Isolate.immediate);
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      _closePorts();
    }
  }

  void _closePorts() {
    if (_portsClosed) return;
    _portsClosed = true;
    _messages.close();
    _errors.close();
    _exits.close();
  }
}

final class _WorkerStart {
  const _WorkerStart(this.owner, this.nativeLibraryPath, this.cookie);
  final SendPort owner;
  final String nativeLibraryPath;
  final String? cookie;
}

Future<void> _youtubeWorker(_WorkerStart start) async {
  final commands = ReceivePort();
  _QuickJsRuntime? runtime;
  int? closeId;
  String? fatal;
  try {
    runtime = await _QuickJsRuntime.open(
      nativeLibraryPath: start.nativeLibraryPath,
      cookie: start.cookie,
      transport: (request) async {
        final reply = ReceivePort();
        try {
          start.owner.send(['fetch', request, reply.sendPort]);
          final result = (await reply.first) as List<Object?>;
          if (result[0] == 'error') throw YouTubeException(result[1] as String);
          return result[1] as YouTubeResponse;
        } finally {
          reply.close();
        }
      },
    );
    start.owner.send(['ready', commands.sendPort, runtime.userAgent]);
    await for (final raw in commands) {
      final command = raw as List<Object?>;
      final id = command[0] as int;
      final method = command[1] as String;
      final argument = command[2];
      try {
        final Object? result = switch (method) {
          'scanPlaylist' => await runtime.scanPlaylist(argument as String),
          'getVideoInfo' => await runtime.getVideoInfo(argument as String),
          'decipherFormat' => await runtime.decipherFormat(
            (argument as List)[0] as YouTubeVideoInfo,
            argument[1] as YouTubeFormat,
          ),
          'releaseVideoInfo' => await _releaseVideoInfo(
            runtime,
            argument as YouTubeVideoInfo,
          ),
          'close' => null,
          _ => throw YouTubeException('Unknown YouTube worker method $method'),
        };
        if (method == 'close') {
          await runtime.close();
          closeId = id;
          break;
        }
        start.owner.send(['result', id, result]);
      } catch (error) {
        start.owner.send(['error', id, '$error']);
      }
    }
  } catch (error) {
    fatal = '$error';
  } finally {
    await runtime?.close();
    if (_QuickJsRuntime._bindingReady != null) LibFjs.dispose();
    commands.close();
  }
  if (fatal != null) start.owner.send(['fatal', fatal]);
  if (closeId != null) start.owner.send(['result', closeId, null]);
}

Future<Object?> _releaseVideoInfo(
  _QuickJsRuntime runtime,
  YouTubeVideoInfo info,
) async {
  await runtime.releaseVideoInfo(info);
  return null;
}

/// Owns one QuickJS context inside the worker isolate.
final class _QuickJsRuntime {
  _QuickJsRuntime._(
    this._engine,
    this._transport,
    this._isCancelled,
    this.userAgent,
  );

  final JsEngine _engine;
  final YouTubeTransport _transport;
  final bool Function()? _isCancelled;
  final String userAgent;
  bool _closed = false;
  static Future<void>? _bindingReady;

  /// [nativeLibraryPath] may override the app bundle path during development.
  /// The default lookup is confined to this executable's native bundle.
  static Future<_QuickJsRuntime> open({
    String? nativeLibraryPath,
    required YouTubeTransport transport,
    String? cookie,
    bool Function()? isCancelled,
  }) async {
    final libraryPath =
        nativeLibraryPath ?? YouTubeRuntime.bundledNativeLibraryPath();
    if (!File(libraryPath).existsSync()) {
      throw YouTubeException(
        'Bundled QuickJS library is missing: $libraryPath',
      );
    }
    _bindingReady ??= LibFjs.init(
      externalLibrary: ExternalLibrary.open(libraryPath),
    );
    await _bindingReady;
    late _QuickJsRuntime runtime;
    final engine = await JsEngine.create(
      builtins: const JsBuiltinOptions(
        abort: true,
        console: true,
        crypto: true,
        exceptions: true,
        fetch: true,
        intl: true,
        json: true,
        navigator: true,
        streamWeb: true,
        timers: true,
        url: true,
        util: true, // Provides TextEncoder/TextDecoder required by protobuf.
      ),
    );
    try {
      await engine.init(
        bridge: (value) async {
          try {
            final input = _object(value.value);
            if (input['op'] != 'fetch') {
              throw const YouTubeException('Unknown QuickJS bridge operation');
            }
            final headers = <String, String>{};
            for (final pair in _list(input['headers'])) {
              final parts = _list(pair);
              headers[_string(parts[0])] = _string(parts[1]);
            }
            final body = input['body'];
            final response = await runtime._fetch(
              YouTubeRequest(
                url: Uri.parse(_string(input['url'])),
                method: _string(input['method']),
                headers: headers,
                body: body == null ? null : _bytes(body),
              ),
            );
            final headerPairs = <List<String>>[];
            for (final entry in response.headers.entries) {
              for (final value in entry.value) {
                headerPairs.add([entry.key, value]);
              }
            }
            return JsResult.ok(
              JsValue.from({
                'status': response.status,
                'headers': headerPairs,
                'body': response.body,
              }),
            );
          } catch (error) {
            return JsResult.err(JsError.bridge(error.toString()));
          }
        },
      );
      // The upstream CF Worker bundle only probes optional worker_threads.
      await engine.declareNewModule(
        module: JsModule.code(
          module: 'module',
          code: "export function createRequire() { return () => { throw new Error('Native module unavailable'); }; }",
        ),
      );
      await engine.eval(
        source: JsCode.code('''
        if (typeof File === 'undefined') globalThis.File = class File {};
        if (typeof CustomEvent === 'undefined') globalThis.CustomEvent = class CustomEvent {
          constructor(type, init) { this.type = type; this.detail = init?.detail; }
        };
      '''),
      );
      await engine.evaluateModule(
        module: JsModule.code(module: 'youtubejs', code: loadYoutubeJsBundle()),
      );
      await engine.evaluateModule(
        module: JsModule.code(
          module: 'client_youtubei_host',
          code: youtubeJsHost,
        ),
      );
      // The bridge closure is only invoked once [runtime] is initialized.
      runtime = _QuickJsRuntime._(engine, transport, isCancelled, '');
      final result = await engine.call(
        module: 'client_youtubei_host',
        method: 'initialize',
        params: [JsValue.from(cookie)],
      );
      runtime = _QuickJsRuntime._(
        engine,
        transport,
        isCancelled,
        _string(result.value),
      );
      return runtime;
    } catch (_) {
      await engine.close();
      rethrow;
    }
  }

  Future<YouTubeResponse> _fetch(YouTubeRequest request) async {
    _assertOpen();
    if (_isCancelled?.call() ?? false) {
      throw const YouTubeException('YouTube operation cancelled');
    }
    final response = await _transport(request);
    if (_isCancelled?.call() ?? false) {
      throw const YouTubeException('YouTube operation cancelled');
    }
    if (response.status < 100 || response.status > 599) {
      throw YouTubeException('Invalid YouTube HTTP status ${response.status}');
    }
    return response;
  }

  Future<YouTubePlaylistListing> scanPlaylist(String id) async {
    _assertOpen();
    final value = await _engine.call(
      module: 'client_youtubei_host',
      method: 'scanPlaylist',
      params: [JsValue.string(id)],
    );
    final data = _object(value.value);
    return YouTubePlaylistListing(
      title: data['title'] as String?,
      entries: _list(data['entries'])
          .map((item) {
            final entry = _object(item);
            return YouTubePlaylistEntry(
              kind: _string(entry['kind']),
              id: entry['id'] as String?,
              title: entry['title'] as String?,
              durationSeconds: _number(entry['durationSeconds']),
              contentType: entry['contentType'] as String?,
              durationBadges: _list(entry['durationBadges']).cast<String>(),
            );
          })
          .toList(growable: false),
      alerts: _list(data['alerts'])
          .map((item) {
            final alert = _object(item);
            return YouTubePlaylistAlert(
              _string(alert['kind']),
              alert['alertType'] as String?,
            );
          })
          .toList(growable: false),
      parserFailed: data['parserFailed'] == true,
      pages: _int(data['pages']),
    );
  }

  Future<YouTubeVideoInfo> getVideoInfo(String id) async {
    _assertOpen();
    final value = await _engine.call(
      module: 'client_youtubei_host',
      method: 'videoInfo',
      params: [JsValue.string(id)],
    );
    final data = _object(value.value);
    if (data['error'] != null) {
      final error = _object(data['error']);
      throw YouTubeException(
        _string(error['message']),
        status: error['status'] as String?,
        reason: error['reason'] as String?,
      );
    }
    return YouTubeVideoInfo(
      handle: _int(data['handle']),
      id: data['id'] as String?,
      title: data['title'] as String?,
      description: data['description'] as String?,
      durationSeconds: _number(data['durationSeconds']),
      isLive: data['isLive'] == true,
      isUpcoming: data['isUpcoming'] == true,
      status: data['status'] as String?,
      reason: data['reason'] as String?,
      publishDate: data['publishDate'] as String?,
      uploadDate: data['uploadDate'] as String?,
      cpn: _string(data['cpn']),
      formats: _list(data['formats'])
          .map((item) {
            final format = _object(item);
            return YouTubeFormat(
              index: _int(format['index']),
              itag: _int(format['itag']),
              mimeType: _string(format['mimeType']),
              bitrate: _number(format['bitrate']) ?? 0,
              height: _number(format['height']),
              hasAudio: format['hasAudio'] == true,
              hasVideo: format['hasVideo'] == true,
              isTypeOtf: format['isTypeOtf'] == true,
              drmFamilies: _list(format['drmFamilies']).cast<String>(),
              contentLength: _number(format['contentLength']),
              hasUrl: format['hasUrl'] == true,
              hasCipher: format['hasCipher'] == true,
            );
          })
          .toList(growable: false),
    );
  }

  Future<Uri> decipherFormat(
    YouTubeVideoInfo info,
    YouTubeFormat format,
  ) async {
    _assertOpen();
    final value = await _engine.call(
      module: 'client_youtubei_host',
      method: 'decipherFormat',
      params: [JsValue.integer(info.handle), JsValue.integer(format.index)],
    );
    return Uri.parse(_string(value.value));
  }

  Future<void> releaseVideoInfo(YouTubeVideoInfo info) async {
    if (_closed) return;
    await _engine.call(
      module: 'client_youtubei_host',
      method: 'releaseVideoInfo',
      params: [JsValue.integer(info.handle)],
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _engine.call(module: 'client_youtubei_host', method: 'shutdown');
      await _engine.runGc();
    } finally {
      await _engine.close();
    }
  }

  void _assertOpen() {
    if (_closed) throw const YouTubeException('YouTube runtime is closed');
  }
}

Map<String, Object?> _object(Object? value) =>
    (value as Map).cast<String, Object?>();
List<Object?> _list(Object? value) => (value as List).cast<Object?>();
String _string(Object? value) => value as String;
int _int(Object? value) => (value as num).toInt();
double? _number(Object? value) => (value as num?)?.toDouble();
Uint8List _bytes(Object value) => value is Uint8List
    ? value
    : Uint8List.fromList((value as List).cast<int>());
