// The SyncStore contract, run against every implementation
// (store_test.dart: MemoryStore, store_sqflite_test.dart: SqfliteStore).

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/op.dart';
import 'package:opentodo_flutter/data/store.dart';

int _seq = 0;

Op op(String field, Object? value, int ts, String device,
        {String entity = 'task', String entityId = 't1', String? id}) =>
    Op(
      id: id ?? 'op-${_seq++}',
      entity: entity,
      entityId: entityId,
      field: field,
      value: value,
      ts: ts,
      device: device,
    );

void runSyncStoreContract(Future<SyncStore> Function() open) {
  late SyncStore store;
  setUp(() async => store = await open());
  tearDown(() => store.close());

  group('winner rule', () {
    test('greater ts wins regardless of order', () async {
      await store.applyOps([op('title', 'new', 200, 'a'), op('title', 'old', 100, 'z')]);
      expect(await store.getField('task', 't1', 'title'),
          StoredField.fromValue('new', ts: 200, device: 'a'));
    });

    test('tie on ts: greater device wins, in either order', () async {
      final a = op('title', 'from-a', 100, 'dev-a');
      final b = op('title', 'from-b', 100, 'dev-b');
      await store.applyOps([b, a]);
      expect((await store.getField('task', 't1', 'title'))!.value, 'from-b');
      await store.clear();
      await store.applyOps([a]);
      expect(await store.applyOps([b]), [b]);
      expect((await store.getField('task', 't1', 'title'))!.value, 'from-b');
    });

    test('a losing op changes nothing and is not reported', () async {
      await store.applyOps([op('priority', 1, 500, 'a')]);
      final applied = await store.applyOps([op('priority', 2, 400, 'b')]);
      expect(applied, isEmpty);
      expect((await store.getField('task', 't1', 'priority'))!.value, 1);
    });

    test('applying the same op twice is idempotent', () async {
      final o = op('labels', ['x', 'y'], 100, 'a');
      expect(await store.applyOps([o]), [o]);
      expect(await store.applyOps([o]), isEmpty);
      expect(await store.applyOps([o, o]), isEmpty);
      expect(await store.readRow('task', 't1'),
          {'labels': StoredField.fromValue(['x', 'y'], ts: 100, device: 'a')});
    });

    test('server-rewritten fields adopt the served value with the same clock', () async {
      await store.applyOps([op('note_mentions', ['u1', 'u2'], 100, 'a')]);
      final served = op('note_mentions', ['u1'], 100, 'a');
      expect(await store.applyOps([served]), [served]);
      expect((await store.getField('task', 't1', 'note_mentions'))!.value, ['u1']);
      // Other fields with the same clock stay a duplicate.
      await store.applyOps([op('title', 'x', 100, 'a')]);
      expect(await store.applyOps([op('title', 'y', 100, 'a')]), isEmpty);
    });

    test('values keep their JSON shape', () async {
      final due = {'date': '2026-01-02', 'time': '09:30', 'tz': 'Europe/Berlin'};
      await store.applyOps([
        op('due', due, 1, 'a'),
        op('deleted_at', null, 1, 'a'),
        op('evening', true, 1, 'a'),
        op('position', 1.5, 1, 'a'),
      ]);
      final row = await store.readRow('task', 't1');
      expect(row['due']!.value, due);
      expect(row['deleted_at']!.value, isNull);
      expect(row['evening']!.value, true);
      expect(row['position']!.value, 1.5);
    });
  });

  group('forgetField', () {
    test('removes the register only while it holds the given clock', () async {
      await store.applyOps([op('title', 'mine', 300, 'me')]);
      await store.forgetField('task', 't1', 'title', ts: 299, device: 'me');
      expect((await store.getField('task', 't1', 'title'))!.value, 'mine');
      await store.forgetField('task', 't1', 'title', ts: 300, device: 'me');
      expect(await store.getField('task', 't1', 'title'), isNull);
      // An older server value can win now.
      await store.applyOps([op('title', 'server', 100, 'other')]);
      expect((await store.getField('task', 't1', 'title'))!.value, 'server');
    });
  });

  group('families', () {
    test('fields.<id> and appends.<id> are separate registers', () async {
      await store.applyOps([
        op('fields.f1', 'one', 10, 'a'),
        op('fields.f2', 2, 10, 'a'),
        op('appends.x', 'tail', 10, 'a'),
        op('fields.f1', 'older', 5, 'b'),
        op('fields.f2', 3, 20, 'b'),
      ]);
      final row = await store.readRow('task', 't1');
      expect(row.keys.toSet(), {'fields.f1', 'fields.f2', 'appends.x'});
      expect(row['fields.f1']!.value, 'one');
      expect(row['fields.f2'], StoredField.fromValue(3, ts: 20, device: 'b'));
      expect(row['appends.x']!.value, 'tail');
    });
  });

  group('reads', () {
    test('readEntity groups rows; allFields lists every register', () async {
      await store.applyOps([
        op('title', 'a', 1, 'd', entityId: 't1'),
        op('title', 'b', 1, 'd', entityId: 't2'),
        op('name', 'p', 1, 'd', entity: 'project', entityId: 'p1'),
      ]);
      final tasks = await store.readEntity('task');
      expect(tasks.keys.toSet(), {'t1', 't2'});
      expect(tasks['t2']!['title']!.value, 'b');
      expect(await store.readEntity('label'), isEmpty);
      expect(await store.readRow('task', 'nope'), isEmpty);
      expect(await store.getField('task', 'nope', 'title'), isNull);
      final all = await store.allFields();
      expect(all.map((r) => '${r.entity}/${r.entityId}.${r.field}').toSet(),
          {'task/t1.title', 'task/t2.title', 'project/p1.name'});
    });
  });

  group('outbox', () {
    test('append, read in order up to the limit, delete by id', () async {
      final ops = [for (var i = 0; i < 700; i++) op('title', 'v$i', i, 'd', id: 'o$i')];
      await store.appendOutbox(ops.take(300));
      await store.appendOutbox(ops.skip(300));
      expect(await store.outboxCount(), 700);
      final batch = await store.readOutbox();
      expect(batch.length, outboxBatchLimit);
      expect(batch.first.id, 'o0');
      expect(batch.last.id, 'o499');
      expect(batch[3].toJson(), ops[3].toJson());
      expect((await store.readOutbox(limit: 2)).map((o) => o.id), ['o0', 'o1']);
      await store.deleteOutbox([for (final o in batch) o.id, 'unknown']);
      expect(await store.outboxCount(), 200);
      expect((await store.readOutbox()).first.id, 'o500');
    });

    test('an op id already queued is not added twice', () async {
      final o = op('title', 'x', 1, 'd', id: 'dup');
      await store.appendOutbox([o]);
      await store.appendOutbox([o]);
      expect(await store.outboxCount(), 1);
    });

    test('outbox ops round-trip structured values', () async {
      final o = op('due', {'date': '2026-03-04'}, 7, 'd', id: 'x');
      await store.appendOutbox([o]);
      expect((await store.readOutbox()).single.toJson(), o.toJson());
    });
  });

  group('meta', () {
    test('typed helpers default and persist', () async {
      expect(await store.cursor, 0);
      expect(await store.generation, isNull);
      expect(await store.deviceId, isNull);
      expect(await store.hlcLast, 0);
      expect(await store.hlcOffset, 0);
      await store.setCursor(42);
      await store.setGeneration('4f1c');
      await store.setDeviceId('flutter:abc');
      await store.setHlcLast(1760060000123);
      await store.setHlcOffset(-3000);
      expect(await store.cursor, 42);
      expect(await store.generation, '4f1c');
      expect(await store.deviceId, 'flutter:abc');
      expect(await store.hlcLast, 1760060000123);
      expect(await store.hlcOffset, -3000);
    });

    test('arbitrary keys hold JSON values; null removes', () async {
      await store.setMeta('features', {'a': [1, 2], 'b': true});
      expect(await store.getMeta('features'), {'a': [1, 2], 'b': true});
      await store.setMeta('features', null);
      expect(await store.getMeta('features'), isNull);
    });
  });

  group('transactions', () {
    test('a throwing transaction keeps none of its writes', () async {
      await store.applyOps([op('title', 'before', 1, 'a')]);
      await store.setCursor(1);
      await expectLater(
        store.transaction((tx) async {
          await tx.applyOps([op('title', 'after', 2, 'a')]);
          await tx.appendOutbox([op('title', 'after', 2, 'a', id: 'queued')]);
          await tx.setCursor(2);
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect((await store.getField('task', 't1', 'title'))!.value, 'before');
      expect(await store.outboxCount(), 0);
      expect(await store.cursor, 1);
    });

    test('a completed transaction keeps all writes and returns its value', () async {
      final r = await store.transaction((tx) async {
        await tx.applyOps([op('title', 'x', 1, 'a')]);
        await tx.appendOutbox([op('title', 'x', 1, 'a', id: 'q')]);
        await tx.setCursor(9);
        return 'done';
      });
      expect(r, 'done');
      expect((await store.getField('task', 't1', 'title'))!.value, 'x');
      expect(await store.outboxCount(), 1);
      expect(await store.cursor, 9);
    });

    test('clear removes everything', () async {
      await store.applyOps([op('title', 'x', 1, 'a')]);
      await store.appendOutbox([op('title', 'x', 1, 'a')]);
      await store.setCursor(3);
      await store.clear();
      expect(await store.allFields(), isEmpty);
      expect(await store.outboxCount(), 0);
      expect(await store.cursor, 0);
    });
  });
}
