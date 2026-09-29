import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'cancellation.dart';
import 'config.dart';
import 'publicapi/api.dart';
import 'validation.dart';

class AuthenticationRequired implements Exception {
  const AuthenticationRequired();
  @override
  String toString() => 'Sign in to Listenbox to continue.';
}

class PaymentRequired implements Exception {
  const PaymentRequired(this.message);
  final String message;
  @override
  String toString() => 'HTTP 402: $message';
}

class ApiHttpException implements Exception {
  const ApiHttpException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => 'HTTP $statusCode: $message';
}

/// Authenticates only requests to the configured API origin. Signed object and
/// media URLs must use [sendExternal] or [requestExternal].
class Api {
  Api._(
    this.config,
    this.cancel,
    this.httpClient,
    this._credential,
    this.enableHttpLog,
  );

  final Config config;
  final CancellationToken cancel;
  final http.Client httpClient;
  final bool enableHttpLog;
  String? _credential;
  int _credentialVersion = 0;

  String? get credential => _credential;
  bool get hasCredential => _credential != null;
  int get credentialVersion => _credentialVersion;
  late final PublicApiClient publicClient = PublicApiClient(
    baseUri: Uri.parse(config.apiOrigin),
    send: send,
    responseError: responseError,
    readBody: readBounded,
  );

  static Future<Api> open(
    Config config, {
    CancellationToken? cancel,
    http.Client? client,
    bool? enableHttpLog,
  }) async {
    String? credential;
    final file = File(config.authPath);
    if (file.existsSync()) {
      try {
        if (file.lengthSync() <= 64 << 10) {
          final decoded = jsonDecode(file.readAsStringSync());
          if (decoded is Map<String, dynamic> &&
              decoded.length == 1 &&
              decoded['api_key'] is String &&
              credentialValid(decoded['api_key'] as String)) {
            credential = decoded['api_key'] as String;
          }
        }
      } on FormatException {
        // A damaged local credential is treated as signed out.
      } on FileSystemException {
        // The API boundary will report authentication required.
      }
    }
    return Api._(
      config,
      cancel ?? CancellationToken(),
      client ?? _createHttpClient(),
      credential,
      enableHttpLog ?? !const bool.fromEnvironment('dart.vm.product'),
    );
  }

  void setCredential(String? value) {
    if (value != null && !credentialValid(value)) {
      throw const FormatException('invalid API credential');
    }
    _credential = value;
    _credentialVersion++;
  }

  void close() => httpClient.close();

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final expected = Uri.parse(config.apiOrigin);
    if (request.url.origin != expected.origin) {
      throw const FormatException(
        'API request origin does not match configured API',
      );
    }
    request.headers.remove('Authorization');
    request.headers.remove('Cookie');
    if (_credential != null) {
      request.headers['Authorization'] = 'Bearer $_credential';
    }
    request.followRedirects = false;
    return _send(request, apiRequest: true);
  }

  Future<http.StreamedResponse> sendExternal(http.BaseRequest request) {
    request.headers.remove('Authorization');
    request.headers.remove('Cookie');
    return _send(request, apiRequest: false);
  }

  /// Allows the YouTube session signature only on HTTPS YouTube hosts.
  Future<http.StreamedResponse> sendYouTube(http.BaseRequest request) {
    final host = request.url.host.toLowerCase();
    if (request.url.scheme != 'https' ||
        (host != 'youtube.com' && !host.endsWith('.youtube.com'))) {
      throw const FormatException(
        'YouTube authorization destination is invalid',
      );
    }
    request.followRedirects = false;
    return _send(request, apiRequest: false);
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request, {
    required bool apiRequest,
  }) async {
    cancel.throwIfCancelled();
    final watch = Stopwatch()..start();
    final diagnostic = apiRequest
        ? '${request.method} ${config.apiOrigin}${request.url.path.startsWith('/cli/authorizations/') ? '/cli/authorizations/{code}/events' : request.url.path}'
        : '${request.method} ${request.url.origin}';
    try {
      final response = await cancel.race(httpClient.send(request));
      if (enableHttpLog) {
        final trace = response.headers['x-trace-id'];
        stderr.writeln(
          'HTTP $diagnostic -> ${response.statusCode} (${watch.elapsedMilliseconds}ms) trace_id=${trace != null && validTraceId(trace) ? trace : '-'}',
        );
      }
      final eventStream =
          response.headers['content-type']?.startsWith('text/event-stream') ??
          false;
      return http.StreamedResponse(
        _controlledStream(
          response.stream,
          limit: apiRequest && !eventStream ? 4 << 20 : null,
        ),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (error) {
      if (enableHttpLog) {
        stderr.writeln(
          'HTTP $diagnostic -> failed (${watch.elapsedMilliseconds}ms): ${error.runtimeType}',
        );
      }
      rethrow;
    }
  }

  Stream<List<int>> _controlledStream(
    Stream<List<int>> source, {
    int? limit,
  }) async* {
    final iterator = StreamIterator(source);
    var received = 0;
    try {
      while (await cancel.race(iterator.moveNext())) {
        final chunk = iterator.current;
        if (limit != null && chunk.length > limit - received) {
          throw FormatException('HTTP response exceeds $limit bytes');
        }
        received += chunk.length;
        yield chunk;
      }
    } finally {
      await iterator.cancel();
    }
  }

  Future<Exception> responseError(http.StreamedResponse response) async {
    final status = response.statusCode;
    if (status == 401) return const AuthenticationRequired();
    final raw = await readBounded(
      response,
      64 << 10,
    ).catchError((_) => <int>[]);
    String message;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      message = decoded is Map<String, dynamic> && decoded['message'] is String
          ? decoded['message'] as String
          : utf8.decode(raw, allowMalformed: true).trim();
    } catch (_) {
      message = utf8.decode(raw, allowMalformed: true).trim();
    }
    if (status == 402) return PaymentRequired(message);
    return ApiHttpException(
      status,
      status == 403 ? 'permission denied' : redact(message),
    );
  }

  Future<List<int>> readBounded(
    http.StreamedResponse response,
    int limit,
  ) async {
    if (response.contentLength != null && response.contentLength! > limit) {
      throw FormatException('HTTP response exceeds $limit bytes');
    }
    final bytes = <int>[];
    final iterator = StreamIterator(response.stream);
    try {
      while (await cancel.race(iterator.moveNext())) {
        final chunk = iterator.current;
        if (chunk.length > limit - bytes.length) {
          throw FormatException('HTTP response exceeds $limit bytes');
        }
        bytes.addAll(chunk);
      }
    } finally {
      await iterator.cancel();
    }
    return bytes;
  }
}

http.Client _createHttpClient() {
  final context = SecurityContext(withTrustedRoots: true);
  final pem = Platform.environment['SSL_CERT_FILE'];
  if (pem != null && pem.isNotEmpty) context.setTrustedCertificates(pem);
  final client = HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 30)
    ..findProxy = HttpClient.findProxyFromEnvironment;
  return IOClient(client);
}
