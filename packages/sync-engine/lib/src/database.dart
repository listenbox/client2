import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite_async/native.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:uuid/uuid.dart';

/// The local journal owns resumable effects; the API owns published state.
/// sqlite_async keeps its writer and reader pool off the application isolate.
class Database {
  Database._(this.root, this._connection);

  final Directory root;
  final SqliteDatabase _connection;

  static Future<Database> open(Directory profile) async {
    await profile.create(recursive: true);
    final lock = await File(p.join(profile.path, 'sync-schema.lock'))
        .open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    SqliteDatabase? connection;
    try {
      connection = SqliteDatabase.withFactory(
        _DurableOpenFactory(p.join(profile.path, 'sync.sqlite')),
      );
      await connection.initialize();
      await connection.writeTransaction((tx) async {
        final version =
            (await tx.get('PRAGMA user_version')).columnAt(0) as int;
        if (version != 0 && version != 1) {
          throw StateError('Unsupported sync journal version $version');
        }
        if (version == 0) {
          await tx.executeMultiple('''
CREATE TABLE transfers (
 origin TEXT NOT NULL, show_slug TEXT NOT NULL, source_url TEXT NOT NULL,
 collection_url TEXT NOT NULL, operation_id TEXT NOT NULL UNIQUE,
 manifest TEXT, upload_session_id TEXT,
 PRIMARY KEY(origin, show_slug, source_url, collection_url)
);
CREATE TABLE parts (
 operation_id TEXT NOT NULL REFERENCES transfers(operation_id) ON DELETE CASCADE,
 object_index INTEGER NOT NULL CHECK(object_index >= 0),
 part_number INTEGER NOT NULL CHECK(part_number > 0),
 PRIMARY KEY(operation_id, object_index, part_number)
);
CREATE TABLE downloads (
 operation_id TEXT NOT NULL REFERENCES transfers(operation_id) ON DELETE CASCADE,
 name TEXT NOT NULL, identity TEXT NOT NULL,
 PRIMARY KEY(operation_id, name)
);
CREATE TABLE download_ranges (
 operation_id TEXT NOT NULL, name TEXT NOT NULL,
 start INTEGER NOT NULL CHECK(start >= 0), sha256 TEXT NOT NULL,
 PRIMARY KEY(operation_id, name, start),
 FOREIGN KEY(operation_id, name) REFERENCES downloads(operation_id, name) ON DELETE CASCADE
);
CREATE TABLE source_items (
 origin TEXT NOT NULL, show_slug TEXT NOT NULL, collection_url TEXT NOT NULL,
 source_url TEXT NOT NULL, position INTEGER NOT NULL CHECK(position >= 0),
 PRIMARY KEY(origin, show_slug, source_url)
);
PRAGMA user_version=1;
''');
        }
      });
      return Database._(
        Directory(p.join(profile.path, 'transfers')),
        connection,
      );
    } catch (_) {
      await connection?.close();
      rethrow;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  Future<void> close() => _connection.close();

  Future<void> snapshot(
    String origin,
    String show,
    String collection,
    List<String> urls,
  ) => _connection.writeTransaction((tx) async {
    await tx.execute(
      'DELETE FROM source_items WHERE origin IS ? AND show_slug IS ?',
      [origin, show],
    );
    for (var i = 0; i < urls.length; i++) {
      await tx.execute(
        'INSERT INTO source_items VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING',
        [origin, show, collection, urls[i], i],
      );
    }
  });

  Future<String> operation(
    String origin,
    String show,
    String source,
    String collection,
  ) => _connection.writeTransaction((tx) async {
    await tx.execute(
      'INSERT INTO transfers (origin,show_slug,source_url,collection_url,operation_id) VALUES (?,?,?,?,?) ON CONFLICT DO NOTHING',
      [origin, show, source, collection, const Uuid().v4()],
    );
    final row = await tx.get(
      'SELECT operation_id FROM transfers WHERE origin IS ? AND show_slug IS ? AND source_url IS ? AND collection_url IS ?',
      [origin, show, source, collection],
    );
    return row['operation_id'] as String;
  });

  Future<Directory> directory(String operation) async {
    if (!Uuid.isValidUUID(fromString: operation))
      throw const FormatException('Invalid transfer operation');
    final result = Directory(p.join(root.path, operation));
    await result.create(recursive: true);
    return result;
  }

  Future<Map<String, dynamic>?> prepared(String operation) async {
    final row = await _connection.getOptional(
      'SELECT manifest FROM transfers WHERE operation_id IS ?',
      [operation],
    );
    if (row == null || row['manifest'] == null) return null;
    return jsonDecode(row['manifest'] as String) as Map<String, dynamic>;
  }

  Future<void> savePrepared(String operation, Map<String, dynamic> manifest) =>
      _connection.writeTransaction((tx) async {
        await tx.execute(
          'UPDATE transfers SET manifest=? WHERE operation_id IS ?',
          [jsonEncode(manifest), operation],
        );
        if ((await tx.get('SELECT changes()')).columnAt(0) != 1)
          throw StateError('Missing transfer operation');
      });

  Future<void> session(String operation, String session) =>
      _connection.writeTransaction((tx) async {
        await tx.execute(
          'DELETE FROM parts WHERE operation_id IS ? AND NOT EXISTS (SELECT 1 FROM transfers WHERE operation_id IS ? AND upload_session_id IS ?)',
          [operation, operation, session],
        );
        await tx.execute(
          'UPDATE transfers SET upload_session_id=? WHERE operation_id IS ?',
          [session, operation],
        );
        if ((await tx.get('SELECT changes()')).columnAt(0) != 1)
          throw StateError('Missing transfer operation');
      });

  Future<bool> hasPart(String operation, int object, int part) async =>
      await _connection.getOptional(
        'SELECT 1 FROM parts WHERE operation_id IS ? AND object_index IS ? AND part_number IS ?',
        [operation, object, part],
      ) !=
      null;

  Future<void> savePart(String operation, int object, int part) async {
    await _connection.execute(
      'INSERT INTO parts VALUES (?,?,?) ON CONFLICT DO NOTHING',
      [operation, object, part],
    );
  }

  Future<void> download(String operation, String name, String identity) =>
      _connection.writeTransaction((tx) async {
        await tx.execute(
          'DELETE FROM downloads WHERE operation_id IS ? AND name IS ? AND identity IS NOT ?',
          [operation, name, identity],
        );
        await tx.execute(
          'INSERT INTO downloads VALUES (?,?,?) ON CONFLICT DO NOTHING',
          [operation, name, identity],
        );
      });

  Future<String?> rangeHash(String operation, String name, int start) async {
    final row = await _connection.getOptional(
      'SELECT sha256 FROM download_ranges WHERE operation_id IS ? AND name IS ? AND start IS ?',
      [operation, name, start],
    );
    return row?['sha256'] as String?;
  }

  Future<void> saveRange(
    String operation,
    String name,
    int start,
    String hash,
  ) async {
    await _connection.execute(
      'INSERT INTO download_ranges VALUES (?,?,?,?) ON CONFLICT DO UPDATE SET sha256=excluded.sha256',
      [operation, name, start, hash],
    );
  }

  Future<void> forget(String origin, String show, String source) async {
    final rows = await _connection.getAll(
      'SELECT operation_id FROM transfers WHERE origin IS ? AND show_slug IS ? AND source_url IS ?',
      [origin, show, source],
    );
    for (final row in rows) {
      final directory = await this.directory(row['operation_id'] as String);
      if (await directory.exists()) await directory.delete(recursive: true);
    }
    await _connection.execute(
      'DELETE FROM transfers WHERE origin IS ? AND show_slug IS ? AND source_url IS ?',
      [origin, show, source],
    );
  }
}

base class _DurableOpenFactory extends NativeSqliteOpenFactory {
  _DurableOpenFactory(String path)
    : super(
        path: path,
        sqliteOptions: const SqliteOptions(
          journalMode: SqliteJournalMode.wal,
          synchronous: SqliteSynchronous.full,
          lockTimeout: Duration(seconds: 5),
          maxReaders: 5,
        ),
      );

  @override
  List<String> pragmaStatements(SqliteOpenOptions options) => [
    ...super.pragmaStatements(options),
    'PRAGMA fullfsync=ON',
    'PRAGMA checkpoint_fullfsync=ON',
    'PRAGMA foreign_keys=ON',
    'PRAGMA cache_size=-2000',
    'PRAGMA wal_autocheckpoint=1000',
    'PRAGMA temp_store=MEMORY',
  ];
}
