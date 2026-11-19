// SQLite implementation of [SyncStore] on sqflite's API. It imports only
// `sqflite/sqlite_api.dart` (no Flutter), so tests open it through
// sqflite_common_ffi's factory and the app through sqflite's.

import 'dart:convert';

import 'package:sqflite/sqlite_api.dart';

import '../core/op.dart';
import 'store.dart';

/// The schema version [SqfliteStore] creates and upgrades to.
const int storeSchemaVersion = 1;

/// Schema steps: index i brings the database from version i to i + 1.
const List<List<String>> _migrations = [
  [
    'CREATE TABLE fields ('
        'entity TEXT NOT NULL, entity_id TEXT NOT NULL, field TEXT NOT NULL, '
        'value_json TEXT NOT NULL, ts INTEGER NOT NULL, device TEXT NOT NULL, '
        'PRIMARY KEY (entity, entity_id, field)) WITHOUT ROWID',
    'CREATE INDEX fields_entity ON fields (entity, entity_id)',
    'CREATE TABLE outbox ('
        'seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE, op_json TEXT NOT NULL)',
    'CREATE TABLE meta (key TEXT PRIMARY KEY, value_json TEXT NOT NULL) WITHOUT ROWID',
  ],
];

Future<void> _migrate(DatabaseExecutor db, int from, int to) async {
  for (var v = from; v < to; v++) {
    for (final sql in _migrations[v]) {
      await db.execute(sql);
    }
  }
}

class SqfliteStore extends SyncStore {
  final Database _db;
  final DatabaseExecutor _ex;
  final bool _inTx;

  SqfliteStore._(this._db, this._ex, this._inTx);

  /// Opens (creating or upgrading) the store at [path] with [factory]
  /// (sqflite's `databaseFactory` in the app, `databaseFactoryFfi` in tests;
  /// [inMemoryDatabasePath] for a throwaway store).
  static Future<SqfliteStore> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: storeSchemaVersion,
        onCreate: (db, version) => _migrate(db, 0, version),
        onUpgrade: (db, from, to) => _migrate(db, from, to),
      ),
    );
    return SqfliteStore._(db, db, false);
  }

  static StoredField _stored(Map<String, Object?> r) => StoredField(
        valueJson: r['value_json'] as String,
        ts: r['ts'] as int,
        device: r['device'] as String,
      );

  @override
  Future<StoredField?> getField(String entity, String entityId, String field) async {
    final rows = await _ex.query('fields',
        columns: ['value_json', 'ts', 'device'],
        where: 'entity = ? AND entity_id = ? AND field = ?',
        whereArgs: [entity, entityId, field]);
    return rows.isEmpty ? null : _stored(rows.first);
  }

  @override
  Future<Map<String, StoredField>> readRow(String entity, String entityId) async {
    final rows = await _ex.query('fields',
        columns: ['field', 'value_json', 'ts', 'device'],
        where: 'entity = ? AND entity_id = ?',
        whereArgs: [entity, entityId]);
    return {for (final r in rows) r['field'] as String: _stored(r)};
  }

  @override
  Future<Map<String, Map<String, StoredField>>> readEntity(String entity) async {
    final rows = await _ex.query('fields',
        columns: ['entity_id', 'field', 'value_json', 'ts', 'device'],
        where: 'entity = ?',
        whereArgs: [entity]);
    final out = <String, Map<String, StoredField>>{};
    for (final r in rows) {
      out.putIfAbsent(r['entity_id'] as String, () => {})[r['field'] as String] = _stored(r);
    }
    return out;
  }

  @override
  Future<List<FieldRecord>> allFields() async {
    final rows = await _ex.query('fields');
    return [
      for (final r in rows)
        FieldRecord(r['entity'] as String, r['entity_id'] as String, r['field'] as String, _stored(r)),
    ];
  }

  @override
  Future<List<Op>> applyOps(Iterable<Op> ops, {Set<String> rewritten = serverRewrittenFields}) =>
      transaction((tx) async {
        final ex = (tx as SqfliteStore)._ex;
        final applied = <Op>[];
        // Registers written earlier in this batch, so a later op of the same
        // field compares against them without another read.
        final seen = <String, StoredField?>{};
        for (final op in ops) {
          final key = '${op.entity}\u0000${op.entityId}\u0000${op.field}';
          final current =
              seen.containsKey(key) ? seen[key] : await tx.getField(op.entity, op.entityId, op.field);
          if (!opReplaces(op, current, rewritten: rewritten)) {
            seen[key] = current;
            continue;
          }
          final next = StoredField.fromValue(op.value, ts: op.ts, device: op.device);
          await ex.insert(
            'fields',
            {
              'entity': op.entity,
              'entity_id': op.entityId,
              'field': op.field,
              'value_json': next.valueJson,
              'ts': next.ts,
              'device': next.device,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          seen[key] = next;
          applied.add(op);
        }
        return applied;
      });

  @override
  Future<void> forgetField(String entity, String entityId, String field, {required int ts, required String device}) =>
      _ex.delete('fields',
          where: 'entity = ? AND entity_id = ? AND field = ? AND ts = ? AND device = ?',
          whereArgs: [entity, entityId, field, ts, device]);

  @override
  Future<void> appendOutbox(Iterable<Op> ops) => transaction((tx) async {
        final ex = (tx as SqfliteStore)._ex;
        for (final op in ops) {
          await ex.insert('outbox', {'op_id': op.id, 'op_json': jsonEncode(op.toJson())},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });

  @override
  Future<List<Op>> readOutbox({int limit = outboxBatchLimit}) async {
    final rows = await _ex.query('outbox', columns: ['op_json'], orderBy: 'seq', limit: limit);
    return [for (final r in rows) Op.fromJson(jsonDecode(r['op_json'] as String) as Map<String, dynamic>)];
  }

  @override
  Future<void> deleteOutbox(Iterable<String> opIds) async {
    final ids = opIds.toSet().toList();
    // Stay well below SQLite's bound-parameter limit.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      await _ex.delete('outbox',
          where: 'op_id IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
    }
  }

  @override
  Future<int> outboxCount() async {
    final rows = await _ex.rawQuery('SELECT COUNT(*) AS n FROM outbox');
    return rows.first['n'] as int;
  }

  @override
  Future<Object?> getMeta(String key) async {
    final rows = await _ex.query('meta', columns: ['value_json'], where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value_json'] as String);
  }

  @override
  Future<void> setMeta(String key, Object? value) async {
    if (value == null) {
      await _ex.delete('meta', where: 'key = ?', whereArgs: [key]);
    } else {
      await _ex.insert('meta', {'key': key, 'value_json': jsonEncode(value)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SyncStore tx) body) {
    if (_inTx) return body(this);
    return _db.transaction((txn) => body(SqfliteStore._(_db, txn, true)));
  }

  @override
  Future<void> clear() => transaction((tx) async {
        final ex = (tx as SqfliteStore)._ex;
        await ex.delete('fields');
        await ex.delete('outbox');
        await ex.delete('meta');
      });

  @override
  Future<void> close() => _db.close();
}
