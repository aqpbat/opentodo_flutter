import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/e2ee.dart';
import 'package:opentodo_flutter/core/hlc.dart';
import 'package:opentodo_flutter/core/ids.dart';
import 'package:opentodo_flutter/core/op.dart';
import 'package:opentodo_flutter/data/e2ee_sync.dart';
import 'package:opentodo_flutter/data/mutate.dart';
import 'package:opentodo_flutter/data/rows.dart';
import 'package:opentodo_flutter/data/store.dart';
import 'package:opentodo_flutter/data/sync_engine.dart';
import 'package:opentodo_flutter/domain/change.dart';
import 'package:opentodo_flutter/domain/reminders.dart';

import 'support/fake_sync_server.dart';

/// One installation wired like the app: store, shared clock, E2EE boundary,
/// engine and mutator.
class Device {
  final String id;
  final MemoryStore store = MemoryStore();
  final Hlc hlc;
  bool encrypted;
  Uint8List? key;
  Set<String> shared = {};
  int syncRequests = 0;
  late final E2eeSync e2ee;
  late final SyncEngine engine;
  late final Mutator mutator;

  Device(this.id, FakeSyncServer server, {this.encrypted = false, this.key, String? userId})
      : hlc = Hlc(wallClock: () => 0) {
    hlc.wallClock = () => server.now;
    e2ee = E2eeSync(store: store, enabled: () => encrypted, key: () => key, sharedProjects: () async => shared);
    engine = SyncEngine(
      store: store,
      exchange: server.exchange,
      hlc: hlc,
      device: id,
      prepareOutgoing: e2ee.prepareOutgoing,
      decodeIncoming: e2ee.decodeIncoming,
      tzOffset: () => 0,
      clock: () => server.now,
    );
    mutator = Mutator(
      store: store,
      hlc: hlc,
      device: id,
      onMutated: () => syncRequests++,
      userId: () => userId,
      encrypted: () => encrypted,
      zone: () => 'UTC',
      clock: () => server.now,
    );
  }

  Future<Object?> value(String entity, String entityId, String field) async =>
      (await store.getField(entity, entityId, field))?.value;
}

Uint8List testKey([int seed = 7]) => Uint8List.fromList(List.generate(32, (i) => (i * 13 + seed) & 0xff));

void main() {
  late FakeSyncServer server;
  setUp(() => server = FakeSyncServer());

  group('mutate', () {
    test('one batch: one ts and device, applied, queued, clock persisted, sync requested', () async {
      final d = Device('dev-a', server);
      final ops = await d.mutator.mutate(const [
        Change('task', 't1', {'title': 'Buy milk', 'priority': 2}),
        Change('project', 'p1', {'name': 'Home'}),
      ]);
      expect(ops, hasLength(3));
      expect(ops.map((o) => o.ts).toSet(), hasLength(1));
      expect(ops.every((o) => o.device == 'dev-a'), isTrue);
      expect(await d.value('task', 't1', 'title'), 'Buy milk');
      expect(await d.store.outboxCount(), 3);
      expect(await d.store.hlcLast, ops.first.ts);
      expect(d.syncRequests, 1);

      final next = await d.mutator.mutate(const [Change('task', 't1', {'title': 'Buy oat milk'})]);
      expect(next.single.ts, greaterThan(ops.first.ts));
      expect(await d.mutator.mutate(const [Change('task', 't1', {})]), isEmpty);
      expect(d.syncRequests, 2);
    });

    test('a restart never reuses a timestamp: the clock is seeded from meta', () async {
      final d = Device('dev-a', server);
      await d.store.setHlcLast(server.now + 5000);
      final ops = await d.mutator.mutate(const [Change('task', 't1', {'title': 'x'})]);
      expect(ops.single.ts, server.now + 5001);
    });

    test('a due change moves relative reminders in the same batch (pitfall 10)', () async {
      final d = Device('dev-a', server);
      await d.mutator.mutate(const [Change('task', 't1', {'title': 'Call', 'due': {'date': '2027-03-01', 'time': '10:00'}})]);
      final task = await loadRow(d.store, 'task', 't1');
      await d.mutator.mutate([addReminderChange(task, const RelativeReminder(-30), id: 'r1', now: server.now, zone: 'UTC')]);
      // Delivered, then the due moves.
      await d.mutator.mutate(const [Change('reminder', 'r1', {'delivered_at': 1})]);
      final ops = await d.mutator.mutate(const [Change('task', 't1', {'due': {'date': '2027-03-02', 'time': '10:00'}})]);
      final fire = ops.firstWhere((o) => o.entity == 'reminder' && o.field == 'fire_at');
      expect(fire.ts, ops.first.ts);
      expect(fire.value, DateTime.utc(2027, 3, 2, 9, 30).millisecondsSinceEpoch);
      expect(ops.any((o) => o.field == 'delivered_at' && o.value == null), isTrue);
    });

    test('a task getting a due date gets the default reminder', () async {
      final d = Device('dev-a', server, userId: 'u1');
      await d.store.applyOps([
        Op(id: uuid(), entity: 'user_prefs', entityId: userPrefsId, field: 'reminder_default_timed', value: '15', ts: 1, device: 'server'),
      ]);
      final ops = await d.mutator.mutate(const [Change('task', 't1', {'due': {'date': '2027-03-01', 'time': '10:00'}})]);
      final rem = ops.where((o) => o.entity == 'reminder').toList();
      expect(rem, isNotEmpty);
      expect(rem.every((o) => o.ts == ops.first.ts), isTrue);
      expect(rem.firstWhere((o) => o.field == 'offset_minutes').value, 15);

      // Restores (Undo, Trash) skip it.
      final restored = await d.mutator.mutate(const [Change('task', 't2', {'due': {'date': '2027-03-01'}})], restore: true);
      expect(restored.where((o) => o.entity == 'reminder'), isEmpty);
    });

    test('completing records completed_by; reopening clears it', () async {
      final d = Device('dev-a', server, userId: 'u1');
      final done = await d.mutator.mutate(const [Change('task', 't1', {'completed_at': 5})]);
      expect(done.firstWhere((o) => o.field == 'completed_by').value, 'u1');
      final open = await d.mutator.mutate(const [Change('task', 't1', {'completed_at': null})]);
      expect(open.firstWhere((o) => o.field == 'completed_by').value, isNull);
    });

    test('note documents are never written; description only without a document (rule 4)', () async {
      final d = Device('dev-a', server);
      expect(() => d.mutator.mutate(const [Change('task', 't1', {'notes_doc': 'x'})]), throwsA(isA<ProtectedFieldError>()));
      expect(() => d.mutator.mutate(const [Change('task', 't1', {'appends.a1': 'x'})]), throwsA(isA<ProtectedFieldError>()));
      await d.mutator.mutate(const [Change('task', 't1', {'description': 'plain'})]);
      await d.store.applyOps([
        Op(id: uuid(), entity: 'task', entityId: 't1', field: 'notes_doc', value: 'yjs-state', ts: 1, device: 'other'),
      ]);
      await expectLater(
        d.mutator.mutate(const [Change('task', 't1', {'title': 'ok', 'description': 'overwrite'})]),
        throwsA(isA<ProtectedFieldError>()),
      );
      expect(await d.value('task', 't1', 'description'), 'plain');
      expect(await d.value('task', 't1', 'title'), isNull);
      expect(await d.store.outboxCount(), 1);
    });

    test('content too long to encrypt is refused before any op exists', () async {
      final d = Device('dev-a', server, encrypted: true, key: testKey());
      final long = 'x' * (maxPlaintextBytes + 1);
      await expectLater(d.mutator.mutate([Change('task', 't1', {'title': long})]), throwsA(isA<PlaintextTooLongError>()));
      expect(await d.store.outboxCount(), 0);
      d.encrypted = false;
      await d.mutator.mutate([Change('task', 't1', {'title': long})]);
      expect(await d.store.outboxCount(), 1);
    });

    test('createTask: uuid id, defaults, created_at, increasing positions', () async {
      final d = Device('dev-a', server);
      final id = await d.mutator.createTask(const NewTask(title: '  Write report ', labels: ['l1'], priority: 1));
      final id2 = await d.mutator.createTask(const NewTask(title: 'Second'));
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4')));
      final row = Task((await loadRow(d.store, 'task', id))!);
      expect(row.data['title'], 'Write report');
      expect(row.data['priority'], 1);
      expect(row.data['labels'], ['l1']);
      expect(row.data['created_at'], server.now);
      expect(row.data['completed_at'], isNull);
      expect(row.data['description'], '');
      final row2 = (await loadRow(d.store, 'task', id2))!;
      expect(row2['position'] as num, greaterThan(row.data['position'] as num));
      expect((await d.store.readOutbox()).where((o) => o.entityId == id).map((o) => o.field),
          containsAll(['title', 'created_at', 'position', 'deleted_at', 'project_id']));
    });
  });

  group('E2EE in the exchange', () {
    test('plaintext account: the server sees plaintext', () async {
      final d = Device('dev-a', server);
      await d.mutator.mutate(const [Change('task', 't1', {'title': 'Secret plan'})]);
      await d.engine.syncNow();
      expect(server.value('task', 't1', 'title'), 'Secret plan');
    });

    test('encrypted account: offline edit queues plaintext, the server sees an envelope', () async {
      final k = testKey();
      final d = Device('dev-a', server, encrypted: true, key: k);
      await d.mutator.mutate(const [
        Change('task', 't1', {'title': 'Secret plan', 'priority': 1, 'description': ''}),
      ]);
      // Offline: the outbox and the store hold plaintext.
      expect((await d.store.readOutbox()).firstWhere((o) => o.field == 'title').value, 'Secret plan');
      await d.engine.syncNow();
      expect(d.engine.status.phase, SyncPhase.idle);
      expect(await d.store.outboxCount(), 0);
      final wire = server.value('task', 't1', 'title');
      expect(isEnvelope(wire), isTrue);
      expect(decryptValue(k, 'task', 't1', 'title', wire as String), 'Secret plan');
      // Non-content and empty content stay plaintext.
      expect(server.value('task', 't1', 'priority'), 1);
      expect(server.value('task', 't1', 'description'), '');
      expect(await d.value('task', 't1', 'title'), 'Secret plan');
    });

    test('content of a shared project stays plaintext', () async {
      final d = Device('dev-a', server, encrypted: true, key: testKey());
      d.shared = {'p-shared'};
      await d.mutator.mutate(const [
        Change('task', 't1', {'title': 'Team task', 'project_id': 'p-shared'}),
        Change('task', 't2', {'title': 'Mine', 'project_id': 'p-own'}),
        Change('project', 'p-shared', {'name': 'Team'}),
      ]);
      await d.engine.syncNow();
      expect(server.value('task', 't1', 'title'), 'Team task');
      expect(server.value('project', 'p-shared', 'name'), 'Team');
      expect(isEnvelope(server.value('task', 't2', 'title')), isTrue);
    });

    test('an incoming envelope is decrypted before it is applied', () async {
      final k = testKey();
      final a = Device('dev-a', server, encrypted: true, key: k);
      final b = Device('dev-b', server, encrypted: true, key: k);
      await a.mutator.mutate(const [
        Change('task', 't1', {'title': 'Secret plan', 'origin': {'kind': 'email', 'from': 'x@y'}}),
      ]);
      await a.engine.syncNow();
      expect(isEnvelope(server.value('task', 't1', 'origin')), isTrue);
      await b.engine.syncNow();
      expect(await b.value('task', 't1', 'title'), 'Secret plan');
      expect(await b.value('task', 't1', 'origin'), {'kind': 'email', 'from': 'x@y'});
    });

    test('a tampered envelope becomes a placeholder and the batch still applies', () async {
      final k = testKey();
      final b = Device('dev-b', server, encrypted: true, key: k);
      final good = encryptValue(k, 'task', 't1', 'title', 'Fine');
      // Moved to another field: the binding no longer authenticates.
      final moved = encryptValue(k, 'task', 't1', 'title', 'Moved');
      final flipped = encryptValue(k, 'task', 't2', 'title', 'Flipped');
      final tampered = flipped.substring(0, flipped.length - 2) + (flipped.endsWith('AA') ? 'BB' : 'AA');
      final wrongKey = encryptValue(testKey(99), 'task', 't3', 'title', 'Other key');
      Map<String, dynamic> op(String id, String field, Object? v) =>
          Op(id: uuid(), entity: 'task', entityId: id, field: field, value: v, ts: server.now - 10, device: 'dev-x').toJson();
      await server.exchange({
        'device': 'dev-x',
        'cursor': 0,
        'features': syncFeatures,
        'ops': [
          op('t1', 'title', good),
          op('t1', 'description', moved),
          op('t2', 'title', tampered),
          op('t3', 'title', wrongKey),
          op('t3', 'priority', 2),
        ],
      });
      await b.engine.syncNow();
      expect(b.engine.status.phase, SyncPhase.idle);
      expect(await b.value('task', 't1', 'title'), 'Fine');
      expect(await b.value('task', 't1', 'description'), undecryptable);
      expect(await b.value('task', 't2', 'title'), undecryptable);
      expect(await b.value('task', 't3', 'title'), undecryptable);
      expect(await b.value('task', 't3', 'priority'), 2);
      expect(await b.store.cursor, server.head);

      // A re-seed sends the server's ciphertext back, never the placeholder.
      server.restore(0);
      await b.engine.syncNow();
      expect(server.value('task', 't2', 'title'), tampered);
      expect(server.value('task', 't1', 'title'), isNot('Fine'));
      expect(decryptValue(k, 'task', 't1', 'title', server.value('task', 't1', 'title') as String), 'Fine');

      // A later local edit replaces the placeholder and is sealed normally.
      await b.mutator.mutate(const [Change('task', 't2', {'title': 'Rewritten'})]);
      await b.engine.syncNow();
      expect(decryptValue(k, 'task', 't2', 'title', server.value('task', 't2', 'title') as String), 'Rewritten');
    });

    test('a locked device neither pushes nor applies ciphertext', () async {
      final k = testKey();
      final a = Device('dev-a', server, encrypted: true, key: k);
      await a.mutator.mutate(const [Change('task', 't1', {'title': 'Secret'})]);
      await a.engine.syncNow();

      final b = Device('dev-b', server, encrypted: true);
      await b.mutator.mutate(const [Change('task', 't9', {'title': 'Offline note'})]);
      await b.engine.syncNow();
      expect(b.engine.status.phase, SyncPhase.error);
      expect(await b.store.outboxCount(), 1);
      expect(server.value('task', 't9', 'title'), isNull);
      await b.engine.stop();

      // Pull only: ciphertext arrives while locked → nothing applied, cursor stays.
      final c = Device('dev-c', server, encrypted: true);
      await c.engine.syncNow();
      expect(c.engine.status.phase, SyncPhase.error);
      expect(await c.value('task', 't1', 'title'), isNull);
      expect(await c.store.cursor, 0);
      await c.engine.stop();

      // Unlocked: it goes through.
      c.key = k;
      await c.engine.syncNow();
      expect(await c.value('task', 't1', 'title'), 'Secret');
    });
  });
}
