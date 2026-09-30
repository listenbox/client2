import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'cancellation.dart';
import 'cookies.dart';
import 'database.dart';
import 'downloads.dart';
import 'events.dart';
import 'innertube.dart';
import 'publicapi/models.dart' as p;
import 'youtube.dart';

const watchInterval = Duration(hours: 1);

class Report {
  const Report({
    this.added = 0,
    this.removed = 0,
    this.unchanged = 0,
    this.skipped = 0,
    this.reordered = false,
  });
  final int added;
  final int removed;
  final int unchanged;
  final int skipped;
  final bool reordered;
  @override
  String toString() =>
      '$added added, $removed removed, $unchanged unchanged, $skipped skipped${reordered ? '; feed order updated' : ''}';
}

Future<p.SyncInventory> inventory(Api api, String slug) async {
  String? cursor;
  final seen = <String>{};
  p.Show? show;
  final episodes = <p.SyncEpisode>[];
  do {
    final page = await api.publicClient.getSyncInventory(
      showSlug: slug,
      cursor: cursor,
      limit: 500,
    );
    if (page.show.slug != slug)
      throw StateError('Sync inventory returned a different show');
    if (show != null &&
        (show.id != page.show.id || _source(show) != _source(page.show))) {
      throw StateError('Show source changed while reading inventory');
    }
    show ??= page.show;
    episodes.addAll(page.episodes);
    cursor = page.nextCursor;
    if (cursor != null && !seen.add(cursor))
      throw StateError('Sync inventory repeated a cursor');
  } while (cursor != null);
  return p.SyncInventory(show: show, episodes: episodes);
}

String? _source(p.Show show) => switch (show.youtube) {
  p.YouTubeImport connection => connection.sourceUrl,
  _ => null,
};

class Engine {
  Engine({DownloadManager? downloads, required this.cookies})
    : downloads = downloads ?? DownloadManager();
  final DownloadManager downloads;
  final CookieJar cookies;
  Database? _journal;
  Future<Database>? _openingJournal;
  final Stopwatch _scanClock = Stopwatch()..start();

  Future<Database> _database(Api api) async {
    if (_journal case final value?) return value;
    final opening = _openingJournal ??= Database.open(
      Directory(api.config.directory),
    );
    try {
      return _journal = await opening;
    } finally {
      _openingJournal = null;
    }
  }

  Future<List<Download>> items(Api api, String slug) async =>
      (await _database(api)).items(api.config.apiOrigin, slug);

  Future<void> close() async {
    await downloads.drain();
    await _journal?.close();
    _journal = null;
  }

  Future<bool> nextScan(CancellationToken cancel) async {
    final elapsed = _scanClock.elapsedMilliseconds;
    final period = watchInterval.inMilliseconds;
    final delay = Duration(
      milliseconds: ((elapsed ~/ period) + 1) * period - elapsed,
    );
    try {
      await cancel.race(Future<void>.delayed(delay));
      return true;
    } on OperationCancelled {
      return false;
    }
  }

  Future<Report> once(Api api, String slug) => _sync(api, slug);
  Future<Report> importSnapshot(
    Api api,
    String slug,
    String source,
    PlaylistSnapshot snapshot,
  ) => _sync(api, slug, admitted: (source, snapshot));

  Future<Report> _sync(
    Api api,
    String slug, {
    (String, PlaylistSnapshot)? admitted,
  }) async {
    await Directory(api.config.directory).create(recursive: true);
    final key = sha256
        .convert('${api.config.apiOrigin}\u0000$slug'.codeUnits)
        .toString();
    final lock = await File(p.join(api.config.directory, 'sync-$key.lock'))
        .open(mode: FileMode.append);
    var locked = false;
    try {
      try {
        await lock.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw StateError(
          'Another client is already syncing this show on this computer',
        );
      }
      final journal = await _database(api);
      final before = await inventory(api, slug);
      final collection = _source(before.show);
      if (collection == null)
        throw StateError(
          'This podcast has no YouTube import. Import a playlist to create a new podcast.',
        );
      final source = Uri.parse(collection);
      final youtube = await YouTube.open(api, api.cancel, cookies);
      try {
        PlaylistSnapshot snapshot;
        if (admitted != null) {
          if (collection != admitted.$1)
            throw StateError('Show source differs from the admitted playlist');
          snapshot = admitted.$2;
        } else if (source.queryParameters.containsKey('list')) {
          snapshot = await youtube.snapshot(source.queryParameters['list']!);
        } else {
          final id = source.queryParameters['v'];
          if (id == null) throw StateError('Show source has no video ID');
          snapshot = PlaylistSnapshot(
            title: before.show.title,
            present: [Video(id, 'YouTube video $id', null)],
            estimatedSeconds: 0,
            canRemove: true,
          );
        }
        final orderedUrls = snapshot.present
            .map((video) => 'https://www.youtube.com/watch?v=${video.id}')
            .toList();
        await journal.snapshot(api.config.apiOrigin, slug, collection, [
          for (final video in snapshot.present)
            (
              url: 'https://www.youtube.com/watch?v=${video.id}',
              title: video.title,
              duration: video.durationSeconds,
            ),
        ], canRemove: snapshot.canRemove);
        final remote = orderedUrls.toSet();
        // Published inventory is the authority after a lost acknowledgement.
        for (final episode in before.episodes) {
          await journal.published(
            api.config.apiOrigin,
            slug,
            episode.sourceUrl,
          );
          await journal.forget(api.config.apiOrigin, slug, episode.sourceUrl);
        }
        final existing = {
          for (final episode in before.episodes) episode.sourceUrl: episode,
        };
        final additions = snapshot.present
            .where(
              (video) => !existing.containsKey(
                'https://www.youtube.com/watch?v=${video.id}',
              ),
            )
            .toList();
        for (final video in additions) {
          await journal.operation(
            api.config.apiOrigin,
            slug,
            'https://www.youtube.com/watch?v=${video.id}',
            collection,
          );
        }
        final positions = {
          for (final (index, video) in snapshot.present.indexed)
            video.id: index,
        };
        final transfers = downloads.enqueue(slug, before.show.title, [
          for (final video in additions)
            (id: video.id, title: video.title, position: positions[video.id]!),
        ]);
        for (var i = 0; i < additions.length; i++)
          transfers[i].duration(additions[i].durationSeconds);
        var added = 0, skipped = 0, removed = 0;
        final failures = <Object>[];
        await Future.wait([
          for (var i = 0; i < additions.length; i++)
            () async {
              final video = additions[i];
              final transfer = transfers[i];
              ActiveTransfer? active;
              Object? taskError;
              try {
                active = await transfer.acquire(api.cancel);
                final result = await importVideo(
                  api,
                  youtube,
                  journal,
                  slug: slug,
                  id: video.id,
                  collection: collection,
                  audioOnly: before.show.sourceKind == p.ShowSourceKind.audio,
                  transfer: transfer,
                );
                if (result is Published) {
                  added++;
                  await journal.published(
                    api.config.apiOrigin,
                    slug,
                    'https://www.youtube.com/watch?v=${video.id}',
                  );
                }
                if (result is Skipped) {
                  skipped++;
                  transfer.skipped(result.reason);
                  await journal.outcome(
                    api.config.apiOrigin,
                    slug,
                    transfer.item,
                  );
                }
              } catch (error) {
                taskError = error;
                failures.add(error);
                if (error is! OperationCancelled) {
                  transfer.error(error);
                  await journal.outcome(
                    api.config.apiOrigin,
                    slug,
                    transfer.item,
                  );
                }
              } finally {
                active?.finish(taskError);
              }
            }(),
        ]);
        if (failures.isNotEmpty) {
          final signIn = failures.whereType<SignInRequired>().firstOrNull;
          if (signIn != null) throw signIn;
          throw StateError(
            '${failures.length} transfer(s) failed: ${failures.join('; ')}',
          );
        }
        for (final episode in before.episodes) {
          final sourceUrl = episode.sourceUrl;
          if (snapshot.canRemove && !remote.contains(sourceUrl)) {
            await _delete(api, slug, episode.id);
            await journal.forget(api.config.apiOrigin, slug, sourceUrl);
            removed++;
          }
        }
        final after = await inventory(api, slug);
        if (_source(after.show) != collection)
          throw StateError('Show source changed during sync');
        final published = {
          for (final episode in after.episodes) episode.sourceUrl: episode,
        };
        final ordered = [
          for (final url in orderedUrls)
            if (published[url] != null) published[url]!,
        ];
        var reordered = false;
        for (var i = 0; i < ordered.length; i++) {
          if (ordered[i].position != i) {
            reordered = true;
            break;
          }
        }
        if (reordered)
          await setOrder(api, slug, [
            for (final episode in ordered) episode.id,
          ]);
        return Report(
          added: added,
          removed: removed,
          unchanged: existing.keys
              .where((url) => !snapshot.canRemove || remote.contains(url))
              .length,
          skipped: skipped,
          reordered: reordered,
        );
      } finally {
        await youtube.close();
      }
    } finally {
      if (locked) await lock.unlock();
      await lock.close();
    }
  }

  Stream<Report> watch(Api api, String slug) async* {
    while (!api.cancel.isCancelled) {
      final report = await once(api, slug);
      if (api.cancel.isCancelled) break;
      yield report;
      if (!await nextScan(api.cancel)) break;
    }
  }
}

Future<Map<String, dynamic>> setOrder(
  Api api,
  String slug,
  List<String> episodeIds,
) async {
  final value = await api.publicClient.setEpisodeOrder(
    showSlug: slug,
    body: p.SetEpisodeOrder(episodeIds: episodeIds),
  );
  return value.toJson().cast<String, dynamic>();
}

Future<void> _delete(Api api, String slug, String episode) async {
  final result = await api.publicClient.createSyncEpisodeDeletion(
    showSlug: slug,
    episodeId: episode,
  );
  final response = await api.publicClient.episodeDeletionEvents(
    episodeDeletionRunId: result.episodeDeletionRunId,
  );
  final events = await EventStream.fromResponse(api, response);
  try {
    while (true) {
      final event = await events.next();
      if (event['type'] != 'terminal') continue;
      final terminal = p.EpisodeDeletionTerminalEvent.fromJson(event);
      if (terminal is! p.EpisodeDeletionCompletedEvent)
        throw StateError('Episode deletion failed');
      if (terminal.episodeId != episode)
        throw StateError('Deletion completed for a different episode');
      return;
    }
  } finally {
    await events.close();
  }
}
