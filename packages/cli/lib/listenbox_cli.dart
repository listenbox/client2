import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:listenbox_sync_engine/sync_engine.dart';
import 'package:listenbox_sync_engine/sync_engine.dart' as p;

/// The same command runner is used by the release and development bundles.
Future<int> runListenbox(
  List<String> arguments, {
  required bool debugProfile,
}) async {
  final cancellation = CancellationToken();
  var interrupted = false;
  final signals = <StreamSubscription<ProcessSignal>>[];
  void interrupt(ProcessSignal _) {
    interrupted = true;
    cancellation.cancel();
  }

  signals.add(ProcessSignal.sigint.watch().listen(interrupt));
  if (!Platform.isWindows) {
    signals.add(ProcessSignal.sigterm.watch().listen(interrupt));
  }
  Api? api;
  try {
    final command = _ParsedCommand.parse(arguments);
    if (command.help) {
      stdout.writeln(_help(command.path));
      return 0;
    }
    if (command.version) {
      stdout.writeln('listenbox 0.1.0');
      return 0;
    }
    final config = Config.load(
      explicitPath: command.configPath,
      debugProfile: debugProfile,
    );
    api = await Api.open(
      config,
      cancel: cancellation,
      enableHttpLog: debugProfile,
    );
    await _execute(command, api, config, cancellation);
    return interrupted ? 130 : 0;
  } on _UsageError catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Run listenbox --help for usage.');
    return 2;
  } catch (error) {
    stderr.writeln(error);
    return interrupted ? 130 : 1;
  } finally {
    api?.close();
    for (final signal in signals) {
      await signal.cancel();
    }
  }
}

Future<void> _execute(
  _ParsedCommand command,
  Api api,
  Config config,
  CancellationToken cancellation,
) async {
  final path = command.path;
  final options = command.options;
  if (path == 'youtube-cookies import') {
    await CookieJar(config.directory).importFile(options.positionals.single);
    stdout.writeln('YouTube cookies updated. Sync your podcast to continue.');
    return;
  }
  if (path == 'youtube-cookies remove') {
    await CookieJar(config.directory).remove();
    stdout.writeln('YouTube cookies updated. Sync your podcast to continue.');
    return;
  }
  if (path == 'login') {
    await Auth.login(
      api,
      client: 'cli',
      openBrowser: (url) => stdout.writeln('Verification URL: $url'),
    );
    return;
  }
  if (path == 'auth logout') {
    await Auth.logout(api);
    return;
  }
  if (!api.hasCredential) {
    throw StateError('not logged in; run listenbox login');
  }
  switch (path) {
    case 'auth status':
      stdout.writeln(await Auth.status(api));
      return;
    case 'import':
      final source = options.positionals.single;
      final slug = options.value('slug');
      if (isYouTubeSource(source)) {
        final result = await _withClient(
          api,
          (engine) => engine.importPlaylist(
            source,
            'video',
            requestedSlug: slug,
            cancel: cancellation,
            onCreated: (show) {
              final createdSlug = _string(show, 'slug');
              stderr.writeln(
                'Created podcast ${jsonEncode(createdSlug)}. Resume with shows sync youtube --show $createdSlug',
              );
            },
          ),
        );
        final show = result.show;
        stdout.writeln(_string(show, 'slug'));
        stderr.writeln(
          '${result.report.added} added, ${result.report.skipped} skipped',
        );
        stderr.writeln('100%');
        stderr.writeln(
          'Open in Listenbox: ${config.showUrl(_string(show, 'team_id'), _string(show, 'id'))}',
        );
      } else {
        await _importRss(api, source, slug);
      }
      return;
    case 'shows list':
      for (final show in await api.publicClient.listShows()) {
        stdout.writeln(show.slug);
      }
      return;
    case 'shows create':
      await _createShow(api, config, options);
      return;
    case 'shows delete':
      final slug = options.required('show');
      final result = await api.publicClient.createShowDeletion(showSlug: slug);
      await _deleteEvents(
        api,
        await api.publicClient.showDeletionEvents(
          showDeletionRunId: result.showDeletionRunId,
        ),
        'show',
        slug,
      );
      return;
    case 'shows order':
      final show = options.required('show');
      final episodeIds = options.values('episode');
      final ids = episodeIds.isEmpty
          ? (await api.publicClient.getEpisodeOrder(showSlug: show)).episodeIds
          : (await _withClient(
                  api,
                  (engine) =>
                      engine.setOrder(show, episodeIds, cancel: cancellation),
                ))['episode_ids']
                as List;
      for (final id in ids) {
        if (id is! String)
          throw const FormatException('invalid episode order ID');
        stdout.writeln(id);
      }
      return;
    case 'shows sync youtube':
      final show = options.required('show');
      await _withClient(api, (engine) async {
        if (options.flag('watch')) {
          await for (final report in engine.watch(show, cancel: cancellation)) {
            stdout.writeln(report.toString());
          }
        } else {
          stdout.writeln(
            (await engine.sync(show, cancel: cancellation)).toString(),
          );
        }
      });
      return;
    case 'episodes list':
      await _listEpisodes(
        api,
        options.required('show'),
        int.parse(options.value('limit') ?? '100'),
      );
      return;
    case 'episodes create':
      final file = File(options.required('file'));
      try {
        final handle = await file.open(mode: FileMode.read);
        await handle.close();
      } on FileSystemException catch (error) {
        throw StateError(
          'open --file ${jsonEncode(file.path)}: ${error.message}',
        );
      }
      await _withClient(
        api,
        (engine) => engine.createEpisode(
          options.required('show'),
          options.required('title'),
          file,
          description: options.value('description'),
          publication: options.value('publication') ?? 'draft',
          cancel: cancellation,
          onProgress: (message) {
            if (message.startsWith('Published episode ') ||
                message.startsWith('Created draft episode ') ||
                message.startsWith('YouTube (processing): ')) {
              stdout.writeln(message);
            } else {
              stderr.writeln(message);
            }
          },
        ),
      );
      return;
    case 'episodes delete':
      final episode = options.required('episode');
      final result = await api.publicClient.createEpisodeDeletion(
        episodeId: episode,
      );
      await _deleteEvents(
        api,
        await api.publicClient.episodeDeletionEvents(
          episodeDeletionRunId: result.episodeDeletionRunId,
        ),
        'episode',
        episode,
      );
      return;
    case 'members list':
      await _membersList(api, options.value('show'));
      return;
    case 'members invite':
      await _membersInvite(api, options);
      return;
    case 'members role':
      await _membersRole(api, options);
      return;
    case 'members remove':
      await _membersRemove(api, options);
      return;
    default:
      throw _UsageError('unknown command $path');
  }
}

Future<T> _withClient<T>(Api api, Future<T> Function(Client) operation) async {
  final client = Client(api.config, enableHttpLog: api.enableHttpLog);
  final printed = <String, (Phase, int)>{};
  final changes = client.downloads.changes.listen((snapshot) {
    for (final item in snapshot.items) {
      final bucket = item.total == 0 ? 0 : item.received * 10 ~/ item.total;
      final state = (item.phase, bucket);
      if (printed[item.id] == state) continue;
      printed[item.id] = state;
      final title = item.title.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
      stderr.writeln('$title: ${_phaseLabel(item.phase)}');
    }
  });
  try {
    return await operation(client);
  } finally {
    await client.close();
    await changes.cancel();
  }
}

String _phaseLabel(Phase phase) => switch (phase) {
  Phase.queued => 'Queued',
  Phase.resolving => 'Resolving media',
  Phase.downloading => 'Downloading',
  Phase.preparing => 'Preparing media',
  Phase.uploading => 'Uploading',
  Phase.complete => 'Complete',
  Phase.skipped => 'Skipped',
  Phase.failed => 'Failed',
};

Future<void> _importRss(Api api, String source, String? slug) async {
  p.CreatedPublicRSSImport created;
  try {
    created = await api.publicClient.importRSS(
      body: p.ImportRSSRequest(sourceUrl: source, slug: slug),
    );
  } on ApiHttpException catch (error) {
    if (error.statusCode == 409) {
      throw StateError(
        slug == null
            ? 'import choice conflicts'
            : 'requested slug ${jsonEncode(slug)} conflicts',
      );
    }
    rethrow;
  }
  final events = await EventStream.fromResponse(
    api,
    await api.publicClient.importRSSRunEvents(importRunId: created.importRunId),
  );
  final progress = Progress();
  try {
    while (true) {
      final event = await events.next();
      switch (_string(event, 'type')) {
        case 'progress':
          progress.update(p.RSSImportProgressEvent.fromJson(event).percent);
          continue;
        case 'terminal':
          switch (p.PublicRSSImportTerminalEvent.fromJson(event)) {
            case p.PublicRSSImportCompletedTerminalEvent completed:
              final showSlug = _slug(completed.showSlug);
              _id(completed.feedId, 'lb_');
              final location = api.config.showUrl(
                completed.teamId,
                completed.showId,
              );
              progress.update(100);
              stdout.writeln(showSlug);
              stderr.writeln('Open in Listenbox: $location');
              return;
            case p.RSSImportCancelledTerminalEvent():
              throw StateError('RSS import was cancelled');
            case p.RSSImportFailedTerminalEvent failed:
              throw StateError(
                'RSS import failed '
                '(${failed.errorCode}): ${failed.errorMessage}',
              );
          }
        default:
          throw FormatException(
            'malformed import event ${jsonEncode(event['type'])}',
          );
      }
    }
  } finally {
    await events.close();
  }
}

Future<void> _deleteEvents(
  Api api,
  http.StreamedResponse response,
  String kind,
  String identity,
) async {
  final events = await EventStream.fromResponse(api, response);
  final progress = Progress();
  try {
    while (true) {
      final event = await events.next();
      switch (_string(event, 'type')) {
        case 'progress':
          final percent = kind == 'show'
              ? p.ShowDeletionProgressEvent.fromJson(event).percent
              : p.EpisodeDeletionProgressEvent.fromJson(event).percent;
          progress.update(percent);
          continue;
        case 'terminal':
          if (kind == 'show') {
            switch (p.ShowDeletionTerminalEvent.fromJson(event)) {
              case p.ShowDeletionCompletedEvent completed:
                if (completed.showSlug != identity) {
                  throw StateError('deletion completed for another show');
                }
              case p.ShowDeletionFailedEvent failed:
                throw StateError(
                  'delete show failed (${failed.errorCode}): ${failed.errorMessage}',
                );
            }
          } else {
            switch (p.EpisodeDeletionTerminalEvent.fromJson(event)) {
              case p.EpisodeDeletionCompletedEvent completed:
                if (completed.episodeId != identity) {
                  throw StateError('deletion completed for another episode');
                }
              case p.EpisodeDeletionFailedEvent failed:
                throw StateError(
                  'delete episode failed (${failed.errorCode}): ${failed.errorMessage}',
                );
            }
          }
          progress.update(100);
          stdout.writeln('Deleted $kind ${jsonEncode(identity)}');
          return;
        default:
          throw FormatException(
            'malformed deletion event ${jsonEncode(event['type'])}',
          );
      }
    }
  } finally {
    await events.close();
  }
}

Future<void> _createShow(Api api, Config config, _Options options) async {
  final slug = options.required('slug');
  final id = 'shw_${_randomHex(8)}';
  final artwork = options.value('artwork');
  final imageAssetId = artwork == null
      ? null
      : await _uploadArtwork(api, id, artwork);
  p.Show show;
  try {
    show = await api.publicClient.createShow(
      body: p.CreateShow(
        id: id,
        title: options.required('title'),
        slug: slug,
        language: options.required('language'),
        imageAssetId: imageAssetId,
        sourceKind: p.ShowSourceKind.fromJson(options.required('type')),
      ),
    );
  } on ApiHttpException catch (error) {
    if (error.statusCode == 409) {
      throw StateError('create show: slug ${jsonEncode(slug)} already exists');
    }
    rethrow;
  }
  stdout.writeln('Created show ${jsonEncode(show.slug)}');
  stdout.writeln('Open in Listenbox: ${config.showUrl(show.teamId, show.id)}');
}

Future<String> _uploadArtwork(Api api, String showId, String path) async {
  late final Uint8List raw;
  try {
    raw = await File(path).readAsBytes();
  } on FileSystemException catch (error) {
    throw StateError('read artwork $path: $error');
  }
  final contentType = _validateArtwork(raw);
  final name = Uri.file(path).pathSegments.last;
  final presign = await api.publicClient.createImageUploadPresign(
    body: p.CreateImageUploadPresign(
      showId: showId,
      byteLength: raw.length,
      contentType: p.CreateImageUploadPresignContentType.fromJson(contentType),
      fileName: name,
    ),
  );
  final upload = http.Request(presign.method, Uri.parse(presign.uploadUrl));
  upload.headers['Content-Type'] = contentType;
  upload.bodyBytes = raw;
  final response = await api.sendExternal(upload);
  await response.stream.drain<void>();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('upload artwork: HTTP ${response.statusCode}');
  }
  final complete = await api.publicClient.completeImageUpload(
    imageAssetId: presign.imageAssetId,
    body: p.CompleteImageUpload(objectKey: presign.objectKey),
  );
  return complete.id;
}

String _validateArtwork(Uint8List data) {
  final png = img.PngDecoder();
  final jpeg = img.JpegDecoder();
  final img.Decoder decoder;
  final String contentType;
  if (png.isValidFile(data)) {
    decoder = png;
    contentType = 'image/png';
  } else if (jpeg.isValidFile(data)) {
    decoder = jpeg;
    contentType = 'image/jpeg';
  } else {
    throw StateError('artwork must be a JPEG or PNG image');
  }

  img.DecodeInfo? info;
  try {
    info = decoder.startDecode(data);
  } catch (_) {
    throw StateError('read artwork dimensions: malformed image');
  }
  if (info == null) {
    throw StateError('read artwork dimensions: malformed image');
  }
  final width = info.width;
  final height = info.height;
  if (width != height || width < 1400 || width > 3000) {
    throw StateError(
      'upload a square image between 1400 and 3000 pixels. '
      'Attempted resolution: $width × $height pixels',
    );
  }

  img.Image? decoded;
  try {
    decoded = decoder.decodeFrame(0);
  } catch (_) {
    throw StateError('read artwork dimensions: malformed image');
  }
  if (decoded == null || decoded.width != width || decoded.height != height) {
    throw StateError('read artwork dimensions: malformed image');
  }
  return contentType;
}

Future<void> _listEpisodes(Api api, String show, int limit) async {
  String? cursor;
  final seen = <String>{};
  while (true) {
    final page = await api.publicClient.listEpisodes(
      showSlug: show,
      limit: limit,
      cursor: cursor,
    );
    for (final episode in page.episodes) {
      stdout.writeln(_id(episode.id, 'ep_'));
    }
    cursor = page.nextCursor;
    if (cursor == null) return;
    if (cursor.isEmpty || !seen.add(cursor)) {
      throw StateError('empty or repeated episode list cursor');
    }
  }
}

Future<void> _membersList(Api api, String? show) async {
  if (show == null) {
    final result = await api.publicClient.listTeamMembers();
    for (final member in result.members) {
      stdout.writeln(
        '${member.role.value}\t${member.user.email}\t${member.user.id}',
      );
    }
    for (final invite in result.invitations) {
      _printInvitation(
        invite.role.value,
        invite.email,
        invite.id,
        invite.expiresAt,
      );
    }
  } else {
    final result = await api.publicClient.listShowMembers(showSlug: show);
    for (final member in result.members) {
      stdout.writeln(
        '${member.accessSource.value}\t${member.role.value}\t${member.user.email}\t${member.user.id}',
      );
    }
    for (final invite in result.invitations) {
      _printInvitation(
        invite.role.value,
        invite.email,
        invite.id,
        invite.expiresAt,
      );
    }
  }
}

void _printInvitation(String role, String email, String id, int expiresAt) {
  final expiry =
      '${DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true).toIso8601String().substring(0, 19)}Z';
  stdout.writeln('pending\t$role\t$email\t$id\t$expiry');
}

Future<void> _membersInvite(Api api, _Options options) async {
  final show = options.value('show');
  final email = options.required('email').trim().toLowerCase();
  final role = p.AssignableTeamRole.fromJson(options.required('role'));
  String invitedEmail;
  p.AssignableTeamRole invitedRole;
  if (show == null) {
    final result = await api.publicClient.createTeamInvitation(
      body: p.CreateTeamInvitation(email: email, role: role),
    );
    invitedEmail = result.email;
    invitedRole = result.role;
  } else {
    final result = await api.publicClient.createShowInvitation(
      showSlug: show,
      body: p.CreateShowInvitation(email: email, role: role),
    );
    invitedEmail = result.email;
    invitedRole = result.role;
  }
  stdout.writeln(
    'Invited $invitedEmail${show == null ? '' : ' to $show'} as ${invitedRole.value}.',
  );
}

Future<void> _membersRole(Api api, _Options options) async {
  final show = options.value('show');
  final member = options.required('member');
  final role = options.required('role');
  if (show == null) {
    await api.publicClient.updateTeamMemberRole(
      userId: member,
      body: p.UpdateTeamMemberRole(role: p.AssignableTeamRole.fromJson(role)),
    );
  } else {
    await api.publicClient.updateShowMemberRole(
      showSlug: show,
      userId: member,
      body: p.UpdateShowMemberRole(role: p.AssignableTeamRole.fromJson(role)),
    );
  }
  stdout.writeln(
    'Changed ${show == null ? 'member' : 'show member'} $member to $role.',
  );
}

Future<void> _membersRemove(Api api, _Options options) async {
  final show = options.value('show');
  final member = options.required('member');
  if (show == null) {
    await api.publicClient.removeTeamMember(userId: member);
  } else {
    await api.publicClient.removeShowMember(showSlug: show, userId: member);
  }
  stdout.writeln('Removed ${show == null ? 'member' : 'show member'} $member.');
}

String _string(Map<String, dynamic> object, String key) {
  final value = object[key];
  if (value is String) return value;
  throw FormatException('missing string $key');
}

String _randomHex(int bytes) {
  final random = Random.secure();
  return List.generate(
    bytes,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _nonblank(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw _UsageError('must not be blank');
  return trimmed;
}

String _slug(String value) {
  final trimmed = _nonblank(value);
  if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(trimmed)) {
    throw _UsageError(
      'must use lowercase letters, numbers, and single hyphens',
    );
  }
  return trimmed;
}

String _language(String value) {
  final trimmed = _nonblank(value);
  if (!RegExp(r'^[a-z]{2}(?:-[A-Z]{2})?$').hasMatch(trimmed)) {
    throw _UsageError('must use a language code such as en or en-US');
  }
  return trimmed;
}

String _id(String value, String prefix) {
  if (!RegExp('^${RegExp.escape(prefix)}[0-9a-f]{16}\$').hasMatch(value)) {
    throw _UsageError(
      'invalid ${prefix == 'ep_' ? 'episode' : 'feed'} ID ${jsonEncode(value)}',
    );
  }
  return value;
}

String _choice(String value, List<String> choices) {
  if (!choices.contains(value)) {
    throw _UsageError(
      'invalid value ${jsonEncode(value)}; choose ${choices.join(', ')}',
    );
  }
  return value;
}

class _UsageError implements Exception {
  const _UsageError(this.message);
  final String message;
}

class _Options {
  _Options(this._values, this._flags, this.positionals);
  final Map<String, List<String>> _values;
  final Set<String> _flags;
  final List<String> positionals;

  String? value(String name) => _values[name]?.lastOrNull;
  String required(String name) =>
      value(name) ?? (throw _UsageError('missing required --$name'));
  List<String> values(String name) => _values[name] ?? const [];
  bool flag(String name) => _flags.contains(name);
}

class _ParsedCommand {
  _ParsedCommand(
    this.path,
    this.options,
    this.configPath,
    this.help,
    this.version,
  );
  final String path;
  final _Options options;
  final String? configPath;
  final bool help;
  final bool version;

  static _ParsedCommand parse(List<String> arguments) {
    final words = List<String>.from(arguments);
    String? config;
    var configSeen = false;
    var help = false;
    var version = false;
    for (var i = 0; i < words.length;) {
      final word = words[i];
      if (word == '--') break;
      if (word == '--help' || word == '-h') {
        help = true;
        words.removeAt(i);
      } else if (word == '--version' || word == '-V') {
        version = true;
        words.removeAt(i);
      } else if (word == '--config' || word.startsWith('--config=')) {
        if (configSeen) {
          throw const _UsageError('--config may only be provided once');
        }
        configSeen = true;
        final inline = word.indexOf('=');
        if (inline >= 0) {
          config = word.substring(inline + 1);
          words.removeAt(i);
        } else {
          if (i + 1 >= words.length || words[i + 1].startsWith('--')) {
            throw const _UsageError('missing --config value');
          }
          config = words[i + 1];
          words.removeRange(i, i + 2);
        }
      } else {
        i++;
      }
    }
    if (words.isEmpty) {
      if (help || version)
        return _ParsedCommand('', _Options({}, {}, []), config, help, version);
      throw const _UsageError('missing command');
    }
    final parts = <String>[];
    final top = words.removeAt(0);
    parts.add(top);
    if ([
      'auth',
      'youtube-cookies',
      'shows',
      'episodes',
      'members',
    ].contains(top)) {
      if (words.isEmpty) {
        if (help)
          return _ParsedCommand(
            top,
            _Options({}, {}, []),
            config,
            true,
            version,
          );
        throw _UsageError('missing $top subcommand');
      }
      parts.add(words.removeAt(0));
      if (top == 'shows' && parts[1] == 'sync') {
        if (words.isEmpty && help) {
          return _ParsedCommand(
            'shows sync',
            _Options({}, {}, []),
            config,
            true,
            version,
          );
        }
        if (words.isEmpty)
          throw const _UsageError('missing shows sync subcommand');
        parts.add(words.removeAt(0));
      }
    }
    final path = parts.join(' ');
    final spec = _specs[path];
    if (spec == null) throw _UsageError('unknown command $path');
    if (help || version)
      return _ParsedCommand(path, _Options({}, {}, []), config, help, version);
    final values = <String, List<String>>{};
    final flags = <String>{};
    final positionals = <String>[];
    var positionalOnly = false;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (!positionalOnly && word == '--') {
        positionalOnly = true;
        continue;
      }
      if (positionalOnly || !word.startsWith('--')) {
        positionals.add(word);
        continue;
      }
      final split = word.indexOf('=');
      final name = word.substring(2, split < 0 ? null : split);
      if (spec.flags.contains(name)) {
        if (split >= 0) throw _UsageError('--$name does not take a value');
        flags.add(name);
        continue;
      }
      if (!spec.options.containsKey(name))
        throw _UsageError('unknown option --$name');
      if (name != 'episode' && values.containsKey(name)) {
        throw _UsageError('--$name may only be provided once');
      }
      final value = split >= 0
          ? word.substring(split + 1)
          : (i + 1 < words.length
                ? words[++i]
                : throw _UsageError('missing --$name value'));
      if (value.startsWith('--')) throw _UsageError('missing --$name value');
      final validator = spec.options[name]!;
      values.putIfAbsent(name, () => []).add(validator(value));
    }
    if (positionals.length != spec.positionalCount) {
      throw _UsageError(
        '$path expects ${spec.positionalCount} positional argument(s)',
      );
    }
    for (final name in spec.required) {
      if (!values.containsKey(name) && !flags.contains(name)) {
        throw _UsageError('missing required --$name');
      }
    }
    if (path == 'episodes list') {
      final limit = int.tryParse(values['limit']?.lastOrNull ?? '100');
      if (limit == null || limit < 1 || limit > 500) {
        throw const _UsageError('--limit must be between 1 and 500');
      }
    }
    return _ParsedCommand(
      path,
      _Options(values, flags, positionals),
      config,
      false,
      false,
    );
  }
}

typedef _Validator = String Function(String);

class _CommandSpec {
  const _CommandSpec(
    this.options, {
    this.flags = const {},
    this.required = const {},
    this.positionalCount = 0,
  });
  final Map<String, _Validator> options;
  final Set<String> flags;
  final Set<String> required;
  final int positionalCount;
}

final _specs = <String, _CommandSpec>{
  'login': const _CommandSpec({}),
  'auth status': const _CommandSpec({}),
  'auth logout': const _CommandSpec({}),
  'import': _CommandSpec({'slug': _slug}, positionalCount: 1),
  'youtube-cookies import': const _CommandSpec({}, positionalCount: 1),
  'youtube-cookies remove': const _CommandSpec({}),
  'shows list': const _CommandSpec({}),
  'shows order': _CommandSpec(
    {'show': _slug, 'episode': (value) => _id(value, 'ep_')},
    required: {'show'},
  ),
  'shows sync youtube': _CommandSpec(
    {'show': _slug},
    flags: {'watch'},
    required: {'show'},
  ),
  'shows create': _CommandSpec(
    {
      'title': _nonblank,
      'slug': _slug,
      'type': (value) => _choice(value, ['audio', 'video']),
      'language': _language,
      'artwork': (value) => value,
    },
    required: {'title', 'slug', 'type', 'language'},
  ),
  'shows delete': _CommandSpec(
    {'show': _slug},
    flags: {'yes'},
    required: {'show', 'yes'},
  ),
  'episodes list': _CommandSpec(
    {'show': _slug, 'limit': (value) => value},
    required: {'show'},
  ),
  'episodes create': _CommandSpec(
    {
      'show': _slug,
      'title': _nonblank,
      'description': _nonblank,
      'file': (value) => value,
      'publication': (value) => _choice(value, ['draft', 'publish']),
    },
    required: {'show', 'title', 'file'},
  ),
  'episodes delete': _CommandSpec(
    {'episode': (value) => _id(value, 'ep_')},
    flags: {'yes'},
    required: {'episode', 'yes'},
  ),
  'members list': _CommandSpec({'show': _slug}),
  'members invite': _CommandSpec(
    {
      'email': _nonblank,
      'role': (value) => _choice(value, ['read', 'write']),
      'show': _slug,
    },
    required: {'email', 'role'},
  ),
  'members role': _CommandSpec(
    {
      'member': _nonblank,
      'role': (value) => _choice(value, ['read', 'write']),
      'show': _slug,
    },
    required: {'member', 'role'},
  ),
  'members remove': _CommandSpec(
    {'member': _nonblank, 'show': _slug},
    flags: {'yes'},
    required: {'member', 'yes'},
  ),
};

String _help(String path) {
  if (path.isNotEmpty) {
    final spec = _specs[path];
    if (spec == null) {
      final commands =
          _specs.keys
              .where((command) => command.startsWith('$path '))
              .map(
                (command) =>
                    command.substring(path.length + 1).split(' ').first,
              )
              .toSet()
              .toList()
            ..sort();
      return 'Usage: listenbox $path <COMMAND>\n\nCommands:\n  ${commands.join('\n  ')}';
    }
    final out = StringBuffer('Usage: listenbox $path');
    if (spec.options.isNotEmpty || spec.flags.isNotEmpty)
      out.write(' [OPTIONS]');
    if (spec.positionalCount > 0) {
      out.write(path == 'import' ? ' <SOURCE_URL>' : ' <FILE>');
    }
    out.writeln();
    out.writeln();
    out.writeln('Options:');
    for (final name in spec.options.keys) {
      out.writeln(
        '  --$name VALUE${spec.required.contains(name) ? ' (required)' : ''}',
      );
    }
    for (final name in spec.flags) {
      out.writeln(
        '  --$name${spec.required.contains(name) ? ' (required)' : ''}',
      );
    }
    out.writeln('  --config PATH');
    out.write('  -h, --help');
    return out.toString();
  }
  return '''Publish and manage podcasts on Listenbox

Usage: listenbox [--config PATH] <COMMAND>

Commands:
  login                 Authorize this CLI with Listenbox
  auth status|logout    Show or remove current authorization
  import                Import an RSS feed or public YouTube video/playlist
  youtube-cookies       Import or remove a YouTube session
  shows                 List, create, delete, order, or sync podcasts
  episodes              List, create, or delete episodes
  members               Manage team or show members

Options:
  --config PATH         Path to CLI config file
  -h, --help            Show help
  -V, --version         Show version''';
}
