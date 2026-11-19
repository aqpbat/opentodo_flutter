// The sync engine's end-to-end encryption boundary, ported from
// web/src/lib/e2eeSync.ts (prepareOutgoing / decryptIncoming).
//
// Encryption happens at one choke point: [E2eeSync.prepareOutgoing] runs on
// every batch right before it is uploaded, so whatever path created an op (an
// edit, the re-seed after a restore) nothing leaves the device in plaintext for
// an encrypted account. The store and the outbox hold plaintext, like every
// local table on the web (design D4: the device is the trust boundary).
//
// Decryption happens before incoming ops are applied
// ([E2eeSync.decodeIncoming]), so local rows, filters and search work on
// plaintext. A value that does not authenticate becomes the [undecryptable]
// placeholder; its envelope is remembered (web `_e2ee.raw`) so a re-seed sends
// the server's ciphertext back unchanged instead of the placeholder.
//
// Not ported yet (M4): wire marks (`markSent`), encrypt-on-sight
// (`normalizeOnSight`), mode reconciliation against the key record and the
// migration job.

import 'dart:typed_data';

import '../core/e2ee.dart';
import '../core/hlc.dart';
import '../core/op.dart';
import 'store.dart';

/// The value of a content field this device could not decrypt (web UNDECRYPTABLE).
const String undecryptable = '[Cannot decrypt]';

/// Meta key: envelopes of undecryptable registers, "entity\0id\0field" →
/// {v: envelope, ts, device} (the clock of the op that carried it).
const String rawEnvelopesMetaKey = 'e2ee.raw';

/// The account encrypts and this device holds no key: nothing may be pulled
/// or pushed until it is unlocked (web e2eeSync.ts LockedError).
class LockedError implements Exception {
  @override
  String toString() => 'This device is locked. Unlock it to sync.';
}

/// The two [OpsTransform]s of the sync engine for one account.
class E2eeSync {
  final SyncStore store;

  /// Whether the account encrypts (AccountState.encrypted).
  final bool Function() enabled;

  /// The unlocked account key (DEK), or null while locked.
  final Uint8List? Function() key;

  /// Ids of projects shared with other people: their content stays plaintext.
  /// Until project sharing is synced locally every project counts as personal.
  final Future<Set<String>> Function() sharedProjects;

  E2eeSync({
    required this.store,
    required this.enabled,
    required this.key,
    Future<Set<String>> Function()? sharedProjects,
  }) : sharedProjects = sharedProjects ?? (() async => const <String>{});

  static String _rawKey(String entity, String entityId, String field) => '$entity\u0000$entityId\u0000$field';

  /// Encrypts the content fields of an outgoing batch for an encrypted
  /// account (personal scope only). Empty strings and null stay as they are;
  /// an envelope this device could not decrypt goes back unchanged. Throws
  /// [LockedError] when the account encrypts and no key is unlocked.
  Future<List<Op>> prepareOutgoing(List<Op> ops) async {
    if (ops.isEmpty) return ops;
    final raw = await _raw();
    final on = enabled();
    final k = on ? key() : null;
    if (on && k == null) throw LockedError();
    final personal = on ? await _personalResolver(ops) : null;
    final out = <Op>[];
    for (final op in ops) {
      final kept = raw[_rawKey(op.entity, op.entityId, op.field)];
      if (kept is Map && kept['ts'] == op.ts && kept['device'] == op.device) {
        out.add(_with(op, kept['v']));
        continue;
      }
      if (k != null && _plaintextOf(op) != null && await personal!(op.entity, op.entityId)) {
        out.add(_with(op, sealValue(k, op.entity, op.entityId, op.field, op.value)));
      } else {
        out.add(op);
      }
    }
    return out;
  }

  /// Decrypts incoming content values before they are applied. A value that
  /// does not authenticate (wrong key, tampering, moved to another entity or
  /// field) becomes [undecryptable]; the op is kept and the batch goes on.
  /// Ciphertext while the account encrypts and the device is locked throws
  /// [LockedError]: the page is not applied and the cursor does not move.
  Future<List<Op>> decodeIncoming(List<Op> ops) async {
    if (ops.isEmpty) return ops;
    final k = key();
    final out = <Op>[];
    final failed = <Op>[];
    for (final op in ops) {
      if (!isEnvelope(op.value) || !isContentField(op.entity, op.field)) {
        out.add(op);
        continue;
      }
      if (k == null && enabled()) throw LockedError();
      Object? value;
      try {
        if (k == null) throw DecryptError('no key');
        value = openValue(k, op.entity, op.entityId, op.field, op.value);
      } catch (_) {
        value = undecryptable;
        failed.add(op);
      }
      out.add(_with(op, value));
    }
    if (failed.isNotEmpty) await _remember(failed);
    return out;
  }

  Future<Map<String, Object?>> _raw() async =>
      ((await store.getMeta(rawEnvelopesMetaKey) as Map?) ?? const {}).cast<String, Object?>();

  /// Remembers the envelopes of [failed] and forgets those whose register has
  /// since moved on (a newer edit replaced the placeholder).
  Future<void> _remember(List<Op> failed) async {
    final raw = Map.of(await _raw());
    for (final op in failed) {
      final k = _rawKey(op.entity, op.entityId, op.field);
      final cur = raw[k];
      if (cur is Map && !op.beats((cur['ts'] as num?)?.toInt(), cur['device'] as String?)) continue;
      raw[k] = {'v': op.value, 'ts': op.ts, 'device': op.device};
    }
    for (final e in raw.entries.toList()) {
      final parts = e.key.split('\u0000');
      final m = e.value;
      if (parts.length != 3 || m is! Map) {
        raw.remove(e.key);
        continue;
      }
      final stored = await store.getField(parts[0], parts[1], parts[2]);
      // A register with a newer clock than the envelope: a later write replaced
      // the placeholder. Not stored yet or older: the op is applied in this page.
      if (stored != null &&
          wins(stored.ts, stored.device, existingTs: (m['ts'] as num?)?.toInt(), existingDevice: m['device'] as String?)) {
        raw.remove(e.key);
      }
    }
    await store.setMeta(rawEnvelopesMetaKey, raw.isEmpty ? null : raw);
  }

  static Op _with(Op op, Object? value) => Op(
        id: op.id,
        entity: op.entity,
        entityId: op.entityId,
        field: op.field,
        value: value,
        ts: op.ts,
        device: op.device,
        actor: op.actor,
      );

  /// The plaintext an outgoing op encrypts, or null when it stays as it is
  /// (not content, empty, null, already an envelope).
  static String? _plaintextOf(Op op) {
    if (!isContentField(op.entity, op.field) || isEnvelope(op.value)) return null;
    final text = contentToString(op.entity, op.field, op.value);
    return text == null || text.isEmpty ? null : text;
  }

  /// Whether an op's entity lives in the personal scope, the only scope that
  /// is ever encrypted. A task follows its project; sections, fields, rules
  /// and notes follow their project; comments, attachments and time entries
  /// their task; everything else is personal.
  Future<Future<bool> Function(String entity, String id)> _personalResolver(List<Op> batch) async {
    final shared = await sharedProjects();
    final latest = <String, Object?>{};
    for (final op in batch) {
      if (op.field == 'project_id' || op.field == 'task_id') {
        latest['${op.entity}:${op.entityId}:${op.field}'] = op.value;
      }
    }
    Future<String?> ref(String entity, String id, String field) async {
      final k = '$entity:$id:$field';
      if (latest.containsKey(k)) return latest[k] as String?;
      return (await store.getField(entity, id, field))?.value as String?;
    }

    bool projectPersonal(String? pid) => pid == null || pid.isEmpty || !shared.contains(pid);
    if (shared.isEmpty) return (_, _) async => true;
    return (entity, id) async {
      switch (entity) {
        case 'project':
          return projectPersonal(id);
        case 'task':
        case 'section':
        case 'field':
        case 'rule':
        case 'note':
          return projectPersonal(await ref(entity, id, 'project_id'));
        case 'time_entry':
        case 'comment':
        case 'attachment':
          final taskId = await ref(entity, id, 'task_id');
          return taskId == null ? true : projectPersonal(await ref('task', taskId, 'project_id'));
        default:
          return true;
      }
    };
  }
}
