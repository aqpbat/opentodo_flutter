// The device's copy of the field-level op log (docs/sync.md): one LWW register
// per (entity, entityId, field), the outbox of ops not yet acknowledged by the
// server, and a small key/value meta table (cursor, generation, device id, HLC).
//
// The web client keeps whole rows with a per-field `_clock` map
// (web/src/lib/db.ts, ops.ts `applyOps`); this store keeps the registers
// themselves and leaves building rows to lib/data/rows.dart. A field family op
// (`fields.<id>`, `appends.<id>`, `reactions.<account>`) is a register of its
// own under its full op field name, exactly like on the server.

import 'dart:convert';

import '../core/hlc.dart';
import '../core/op.dart';

/// The most ops one exchange request carries (docs/sync.md, Exchange).
const int outboxBatchLimit = 500;

/// Fields the server may store with a different value than the device sent,
/// keeping the op's clock (ops.ts SERVER_REWRITTEN): when the server's copy
/// arrives with the clock the register already has, its value is adopted.
const Set<String> serverRewrittenFields = {'comment.mentions', 'task.note_mentions'};

/// Well-known meta keys.
abstract final class MetaKeys {
  static const cursor = 'cursor';
  static const generation = 'generation';
  static const deviceId = 'deviceId';
  static const hlc = 'hlc';
  static const hlcOffset = 'hlcOffset';
}

/// One stored register: the winning value (as JSON text) and its clock.
class StoredField {
  final String valueJson;
  final int ts;
  final String device;

  const StoredField({required this.valueJson, required this.ts, required this.device});

  StoredField.fromValue(Object? value, {required this.ts, required this.device})
      : valueJson = jsonEncode(value);

  /// The decoded value (a fresh copy on every call).
  Object? get value => jsonDecode(valueJson);

  @override
  bool operator ==(Object other) =>
      other is StoredField && other.valueJson == valueJson && other.ts == ts && other.device == device;

  @override
  int get hashCode => Object.hash(valueJson, ts, device);

  @override
  String toString() => 'StoredField($valueJson ts=$ts device=$device)';
}

/// A register with its full address, as listed by [SyncStore.allFields].
class FieldRecord {
  final String entity;
  final String entityId;
  final String field;
  final StoredField stored;

  const FieldRecord(this.entity, this.entityId, this.field, this.stored);
}

/// Whether [op] replaces the register [current] under the winner rule.
///
/// The greater (ts, device) wins; an op with the very clock already stored is a
/// duplicate and changes nothing, except for [serverRewrittenFields], whose
/// served value is adopted.
bool opReplaces(Op op, StoredField? current, {Set<String> rewritten = serverRewrittenFields}) {
  if (op.beats(current?.ts, current?.device)) return true;
  return current != null &&
      current.ts == op.ts &&
      current.device == op.device &&
      rewritten.contains('${op.entity}.${op.field}') &&
      current.valueJson != jsonEncode(op.value);
}

/// Storage for the sync engine. Implementations: [MemoryStore] (tests) and
/// `SqfliteStore` (lib/data/store_sqflite.dart).
abstract class SyncStore {
  // --- registers ---

  /// One register, or null when no op for it was ever applied.
  Future<StoredField?> getField(String entity, String entityId, String field);

  /// Every register of one entity row (op field name → register); empty when
  /// the row does not exist.
  Future<Map<String, StoredField>> readRow(String entity, String entityId);

  /// Every row of an entity type: entityId → (field → register).
  Future<Map<String, Map<String, StoredField>>> readEntity(String entity);

  /// Every register in the store (generation re-seed, docs/sync.md Log generation).
  Future<List<FieldRecord>> allFields();

  /// Applies [ops] in one transaction under the winner rule (see [opReplaces]).
  /// Safe in any order and any number of times. Returns the ops that changed a
  /// register, in input order.
  Future<List<Op>> applyOps(Iterable<Op> ops, {Set<String> rewritten = serverRewrittenFields});

  // --- outbox ---

  /// Appends ops to the outbox, after the ones already there. An op whose id
  /// is already queued is not added twice.
  Future<void> appendOutbox(Iterable<Op> ops);

  /// The oldest queued ops, at most [limit], in insertion order.
  Future<List<Op>> readOutbox({int limit = outboxBatchLimit});

  /// Removes acknowledged ops by op id; unknown ids are ignored.
  Future<void> deleteOutbox(Iterable<String> opIds);

  Future<int> outboxCount();

  // --- meta ---

  /// A meta value as stored (any JSON value), or null.
  Future<Object?> getMeta(String key);

  /// Stores a JSON-encodable meta value; null removes the key.
  Future<void> setMeta(String key, Object? value);

  // --- transactions and lifecycle ---

  /// Runs [body] atomically: every write made through the store passed to it
  /// is kept or, when [body] throws, none is. Inside [body] only that store may
  /// be used. Nested calls run inside the outer transaction.
  Future<T> transaction<T>(Future<T> Function(SyncStore tx) body);

  /// Removes every register, outbox op and meta key (sign-out).
  Future<void> clear();

  Future<void> close();

  // --- typed meta helpers ---

  Future<int> get cursor async => _int(await getMeta(MetaKeys.cursor));
  Future<void> setCursor(int v) => setMeta(MetaKeys.cursor, v);

  Future<String?> get generation async => await getMeta(MetaKeys.generation) as String?;
  Future<void> setGeneration(String? v) => setMeta(MetaKeys.generation, v);

  Future<String?> get deviceId async => await getMeta(MetaKeys.deviceId) as String?;
  Future<void> setDeviceId(String v) => setMeta(MetaKeys.deviceId, v);

  /// The last HLC timestamp this device issued or received ([Hlc.seed] at start-up).
  Future<int> get hlcLast async => _int(await getMeta(MetaKeys.hlc));
  Future<void> setHlcLast(int v) => setMeta(MetaKeys.hlc, v);

  /// The stored server-time correction ([Hlc.seedOffset] at start-up).
  Future<int> get hlcOffset async => _int(await getMeta(MetaKeys.hlcOffset));
  Future<void> setHlcOffset(int v) => setMeta(MetaKeys.hlcOffset, v);

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// An in-memory [SyncStore] for tests and previews.
class MemoryStore extends SyncStore {
  // entity → entityId → field → register
  Map<String, Map<String, Map<String, StoredField>>> _fields = {};
  // Outbox as wire JSON, so callers cannot mutate queued ops.
  List<String> _outbox = [];
  Map<String, String> _meta = {};
  bool _inTx = false;

  @override
  Future<StoredField?> getField(String entity, String entityId, String field) async =>
      _fields[entity]?[entityId]?[field];

  @override
  Future<Map<String, StoredField>> readRow(String entity, String entityId) async =>
      Map.of(_fields[entity]?[entityId] ?? const {});

  @override
  Future<Map<String, Map<String, StoredField>>> readEntity(String entity) async => {
        for (final e in (_fields[entity] ?? const <String, Map<String, StoredField>>{}).entries)
          e.key: Map.of(e.value),
      };

  @override
  Future<List<FieldRecord>> allFields() async => [
        for (final ent in _fields.entries)
          for (final row in ent.value.entries)
            for (final f in row.value.entries) FieldRecord(ent.key, row.key, f.key, f.value),
      ];

  @override
  Future<List<Op>> applyOps(Iterable<Op> ops, {Set<String> rewritten = serverRewrittenFields}) =>
      transaction((_) async {
        final applied = <Op>[];
        for (final op in ops) {
          final row = _fields.putIfAbsent(op.entity, () => {}).putIfAbsent(op.entityId, () => {});
          if (!opReplaces(op, row[op.field], rewritten: rewritten)) continue;
          row[op.field] = StoredField.fromValue(op.value, ts: op.ts, device: op.device);
          applied.add(op);
        }
        return applied;
      });

  @override
  Future<void> appendOutbox(Iterable<Op> ops) async {
    final queued = {for (final s in _outbox) (jsonDecode(s) as Map)['id']};
    for (final op in ops) {
      if (queued.add(op.id)) _outbox.add(jsonEncode(op.toJson()));
    }
  }

  @override
  Future<List<Op>> readOutbox({int limit = outboxBatchLimit}) async => [
        for (final s in _outbox.take(limit)) Op.fromJson(jsonDecode(s) as Map<String, dynamic>),
      ];

  @override
  Future<void> deleteOutbox(Iterable<String> opIds) async {
    final ids = opIds.toSet();
    _outbox.removeWhere((s) => ids.contains((jsonDecode(s) as Map)['id']));
  }

  @override
  Future<int> outboxCount() async => _outbox.length;

  @override
  Future<Object?> getMeta(String key) async {
    final s = _meta[key];
    return s == null ? null : jsonDecode(s);
  }

  @override
  Future<void> setMeta(String key, Object? value) async {
    if (value == null) {
      _meta.remove(key);
    } else {
      _meta[key] = jsonEncode(value);
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function(SyncStore tx) body) async {
    if (_inTx) return body(this);
    // Registers are immutable, so copying the maps is a full snapshot.
    final fields = {
      for (final ent in _fields.entries)
        ent.key: {for (final row in ent.value.entries) row.key: Map.of(row.value)},
    };
    final outbox = List.of(_outbox);
    final meta = Map.of(_meta);
    _inTx = true;
    try {
      return await body(this);
    } catch (_) {
      _fields = fields;
      _outbox = outbox;
      _meta = meta;
      rethrow;
    } finally {
      _inTx = false;
    }
  }

  @override
  Future<void> clear() async {
    _fields = {};
    _outbox = [];
    _meta = {};
  }

  @override
  Future<void> close() async {}
}
