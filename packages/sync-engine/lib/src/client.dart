import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'auth.dart';
import 'cancellation.dart';
import 'config.dart';
import 'cookies.dart';
import 'downloads.dart';
import 'episodes.dart' as episode_upload;
import 'sync.dart' as synchronization;
import 'validation.dart' as validation;
import 'youtube.dart' as youtube;

class Catalog {
  const Catalog({
    required this.teams,
    required this.importTeam,
    required this.shows,
  });
  final List<Map<String, dynamic>> teams;
  final String? importTeam;
  final List<Map<String, dynamic>> shows;
}

class Client {
  Client(this.config, {this.enableHttpLog})
    : cookieJar = CookieJar(config.directory),
      _engine = synchronization.Engine(cookies: CookieJar(config.directory));
  final Config config;
  final bool? enableHttpLog;
  final CookieJar cookieJar;
  final synchronization.Engine _engine;
  final Set<CancellationToken> _tokens = {};
  final Set<Future<void>> _operations = {};
  bool _closed = false;

  DownloadManager get downloads => _engine.downloads;
  bool get hasCredentials {
    final file = File(config.authPath);
    if (!file.existsSync()) return false;
    try {
      final raw = jsonDecode(file.readAsStringSync());
      return raw is Map<String, dynamic> &&
          raw.length == 1 &&
          raw['api_key'] is String &&
          validation.credentialValid(raw['api_key'] as String);
    } catch (_) {
      return false;
    }
  }

  String upgradeUrl(String team) => config.upgradeUrl(team);
  String showUrl(Map<String, dynamic> show) =>
      config.showUrl(show['team_id'] as String, show['id'] as String);

  Future<T> _run<T>(
    CancellationToken? requested,
    Future<T> Function(Api) action,
  ) async {
    if (_closed) throw StateError('Client is closed');
    final token = requested?.child() ?? CancellationToken();
    _tokens.add(token);
    final completed = Completer<void>();
    _operations.add(completed.future);
    Api? api;
    try {
      api = await Api.open(config, cancel: token, enableHttpLog: enableHttpLog);
      return await action(api);
    } finally {
      api?.close();
      _tokens.remove(token);
      token.cancel();
      completed.complete();
      _operations.remove(completed.future);
    }
  }

  Future<Catalog> catalog({CancellationToken? cancel}) => _run(cancel, (
    api,
  ) async {
    if (!api.hasCredential) throw const AuthenticationRequired();
    final teams = await api.publicClient.listClientTeams();
    final shows = await api.publicClient.listShows();
    final account = await api.publicClient.whoami();
    return Catalog(
      teams: [for (final team in teams) team.toJson().cast<String, dynamic>()],
      importTeam: account.teamId,
      shows: [for (final show in shows) show.toJson().cast<String, dynamic>()],
    );
  });

  Future<Map<String, dynamic>> episodes(
    String slug, {
    String? cursor,
    CancellationToken? cancel,
  }) => _run(cancel, (api) async {
    if (!api.hasCredential) throw const AuthenticationRequired();
    final value = await api.publicClient.listEpisodes(
      showSlug: slug,
      limit: 50,
      cursor: cursor,
    );
    return value.toJson().cast<String, dynamic>();
  });

  Future<List<Download>> syncItems(String slug, {CancellationToken? cancel}) =>
      _run(cancel, (api) => _engine.items(api, slug));

  Future<void> login(
    FutureOr<void> Function(Uri) openBrowser, {
    CancellationToken? cancel,
    String client = 'desktop',
  }) => _run(
    cancel,
    (api) => Auth.login(api, client: client, openBrowser: openBrowser),
  );

  Future<void> logout() async {
    for (final token in _tokens.toList()) token.cancel();
    await Future.wait(_operations.toList());
    await _engine.downloads.drain();
    final api = await Api.open(config);
    try {
      await Auth.logout(api);
    } finally {
      api.close();
    }
    downloads.clear();
  }

  Future<({Map<String, dynamic> show, synchronization.Report report})>
  importPlaylist(
    String source,
    String kind, {
    String? requestedSlug,
    String? teamId,
    void Function(Map<String, dynamic>)? onCreated,
    CancellationToken? cancel,
  }) => _run(
    cancel,
    (api) => youtube.importPlaylist(
      api,
      _engine,
      source,
      kind,
      requestedSlug: requestedSlug,
      onCreated: onCreated,
    ),
  );

  Future<synchronization.Report> sync(
    String slug, {
    CancellationToken? cancel,
    void Function(synchronization.Report)? onReport,
  }) => _run(cancel, (api) async {
    final result = await _engine.once(api, slug);
    onReport?.call(result);
    return result;
  });

  Stream<synchronization.Report> watch(
    String slug, {
    CancellationToken? cancel,
  }) async* {
    if (_closed) throw StateError('Client is closed');
    final token = cancel?.child() ?? CancellationToken();
    _tokens.add(token);
    try {
      while (!token.isCancelled) {
        yield await sync(slug, cancel: token);
        if (!await nextScan(token)) break;
      }
    } finally {
      _tokens.remove(token);
      token.cancel();
    }
  }

  Future<bool> nextScan(CancellationToken cancel) => _engine.nextScan(cancel);

  Future<Map<String, dynamic>> setOrder(
    String slug,
    List<String> episodeIds, {
    CancellationToken? cancel,
  }) => _run(cancel, (api) => synchronization.setOrder(api, slug, episodeIds));

  Future<void> createEpisode(
    String show,
    String title,
    File file, {
    String? description,
    String publication = 'publish',
    CancellationToken? cancel,
    void Function(String)? onProgress,
  }) => _run(
    cancel,
    (api) => episode_upload.createEpisode(
      api,
      show: show,
      title: title,
      file: file,
      description: description,
      publication: publication,
      onProgress: onProgress,
    ),
  );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final token in _tokens.toList()) token.cancel();
    await Future.wait(_operations.toList());
    await _engine.close();
  }
}
