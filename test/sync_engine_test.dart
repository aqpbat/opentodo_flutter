import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/hlc.dart';
import 'package:opentodo_flutter/core/ids.dart';
import 'package:opentodo_flutter/core/op.dart';
import 'package:opentodo_flutter/data/api.dart';
import 'package:opentodo_flutter/data/store.dart';
import 'package:opentodo_flutter/data/sync_engine.dart';

import 'support/fake_sync_server.dart';

/// One installation: a store, a clock and an engine talking to [server].
class Device {
  final String id;
  final MemoryStore store = MemoryStore();
  final Hlc hlc;
  late final SyncEngine engine;
  int skew = 0;

  Device(this.id, FakeSyncServer server, {ExchangeFn? exchange})
      : hlc = Hlc(wallClock: () => 0) {
    hlc.wallClock = () => server.now + skew;
    engine = SyncEngine(
      store: store,
      exchange: exchange ?? server.exchange,
      hlc: hlc,
      device: id,
      tzOffset: () => 0,
      clock: () => server.now,
    );
  }

  /// A local edit: stamped, applied optimistically and queued.
  Future<Op> edit(String field, Object? value, {String entity = 'task', String entityId = 't1'}) async {
    final op = Op(id: uuid(), entity: entity, entityId: entityId, field: field, value: value, ts: hlc.now(), device: id);
    await store.applyOps([op]);
    await store.appendOutbox([op]);
    return op;
  }

  Future<Object?> value(String field, {String entity = 'task', String entityId = 't1'}) async =>
      (await store.getField(entity, entityId, field))?.value;
}

void main() {
  late FakeSyncServer server;
  setUp(() => server = FakeSyncServer());

  test('(a) two devices editing one field offline converge on the greater (ts, device)', () async {
    final a = Device('dev-a', server);
    final b = Device('dev-b', server);
    await a.edit('title', 'from A');
    await b.edit('title', 'from B');
    final bTs = (await b.store.getField('task', 't1', 'title'))!.ts;
    final aTs = (await a.store.getField('task', 't1', 'title'))!.ts;
    expect(aTs, bTs); // same wall clock: the tie goes to the greater device
    await a.engine.syncNow();
    await b.engine.syncNow();
    await a.engine.syncNow();
    expect(await a.value('title'), 'from B');
    expect(await b.value('title'), 'from B');
    expect(server.value('task', 't1', 'title'), 'from B');
    expect(a.engine.status.phase, SyncPhase.idle);

    // A later edit on A wins everywhere (the receive rule moved A's clock).
    await a.edit('title', 'A again');
    await a.engine.syncNow();
    await b.engine.syncNow();
    expect(await b.value('title'), 'A again');
  });

  test('(b) a pull of more than 1000 ops is paged until hasMore is false', () async {
    final writer = Device('writer', server);
    for (var i = 0; i < 2500; i++) {
      await writer.edit('title', 'task $i', entityId: 't$i');
    }
    // 2500 ops go up in batches of 500.
    await writer.engine.syncNow();
    expect(server.head, 2500);
    expect(server.requests.where((r) => (r['ops'] as List).isNotEmpty).length, 5);
    expect(server.requests.every((r) => (r['ops'] as List).length <= outboxBatchLimit), isTrue);

    final reader = Device('reader', server);
    server.requests.clear();
    await reader.engine.syncNow();
    expect(server.requests.length, 3); // 1000 + 1000 + 500
    expect(await reader.store.cursor, 2500);
    expect((await reader.store.readEntity('task')).length, 2500);
    expect(await reader.value('title', entityId: 't2499'), 'task 2499');
  });

  test('(c) a generation change re-seeds every field with its stored clock and pulls from zero', () async {
    final a = Device('dev-a', server);
    final b = Device('dev-b', server);
    await b.edit('priority', 2);
    await b.engine.syncNow();
    await a.engine.syncNow();
    final backup = server.head;
    await a.edit('title', 'after backup');
    await a.engine.syncNow();
    final clockBefore = await a.store.getField('task', 't1', 'title');
    expect(await a.store.generation, 'gen-1');

    server.restore(backup);
    expect(server.value('task', 't1', 'title'), isNull);
    server.now += 60000;
    await a.engine.syncNow();

    expect(await a.store.generation, server.generation);
    expect(await a.store.outboxCount(), 0);
    expect(server.value('task', 't1', 'title'), 'after backup');
    // Old clocks, not a fresh timestamp.
    final w = server.winners.values.firstWhere((o) => o.field == 'title');
    expect((w.ts, w.device), (clockBefore!.ts, clockBefore.device));
    // B's field was re-sent with B's clock: the device stays B's.
    expect(server.winners.values.firstWhere((o) => o.field == 'priority').device, 'dev-b');

    final c = Device('dev-c', server);
    await c.engine.syncNow();
    expect(await c.value('title'), 'after backup');
    expect(await c.value('priority'), 2);
  });

  test('(d) an invalid refusal drops the local change and takes the server value', () async {
    final b = Device('dev-b', server);
    await b.edit('title', 'server value');
    await b.engine.syncNow();

    final a = Device('dev-a', server);
    await a.engine.syncNow();
    server.refuse = (op) => op.device == 'dev-a' && op.field == 'title' ? 'invalid' : null;
    await a.edit('title', 'refused');
    await a.edit('priority', 1);
    await a.engine.syncNow();

    expect(await a.value('title'), 'server value');
    expect(await a.value('priority'), 1); // the rest of the batch applied
    expect(server.value('task', 't1', 'priority'), 1);
    expect(await a.store.outboxCount(), 0);
    expect(a.engine.status.rejected, 1);

    // A refused new field with no server value falls back to the default (no register).
    await a.edit('title', 'new', entityId: 't2');
    await a.engine.syncNow();
    expect(await a.store.getField('task', 't2', 'title'), isNull);
  });

  test('(e) a pull skips the device\'s own ops but advances the cursor past them', () async {
    final a = Device('dev-a', server);
    await a.edit('title', 'mine');
    await a.engine.syncNow();
    expect(server.responses.every((r) => (r['ops'] as List).isEmpty), isTrue);
    expect(await a.store.cursor, server.head);
    expect(server.head, 1);
  });

  test('(f) re-sending a batch whose answer was lost changes nothing', () async {
    var drop = true;
    final a = Device('dev-a', server, exchange: (body) async {
      final res = await server.exchange(body);
      if (drop) {
        drop = false;
        throw NetworkError('connection reset');
      }
      return res;
    });
    await a.edit('title', 'once');
    await a.engine.syncNow();
    expect(a.engine.status.phase, SyncPhase.offline);
    expect(await a.store.outboxCount(), 1);
    expect(server.head, 1);

    await a.engine.syncNow();
    await a.engine.stop();
    expect(a.engine.status.phase, SyncPhase.idle);
    expect(server.head, 1);
    expect(server.duplicates, 1);
    expect(await a.store.outboxCount(), 0);
  });

  test('a clock refusal restamps the ops and re-sends them in the same exchange', () async {
    final a = Device('dev-a', server);
    a.skew = 10 * 60 * 1000; // ten minutes fast
    final op = await a.edit('title', 'fast');
    await a.edit('priority', 1); // one edit after: its order must be kept
    await a.engine.syncNow();
    expect(server.head, 2);
    final title = server.winners.values.firstWhere((o) => o.field == 'title');
    expect(title.id, op.id); // same op id
    expect(title.ts, lessThanOrEqualTo(server.now + maxFutureSkewMs));
    final stored = (await a.store.getField('task', 't1', 'title'))!;
    expect(stored.ts, title.ts); // the row's clock followed
    expect(await a.store.outboxCount(), 0);
  });

  test('an unknown_field refusal is held and offered again later', () async {
    final a = Device('dev-a', server);
    server.refuse = (op) => op.field == 'future_field' ? 'unknown_field' : null;
    await a.edit('future_field', 'x');
    await a.engine.syncNow();
    expect(await a.store.outboxCount(), 0);
    expect(a.engine.status.held, 1);
    expect(await a.value('future_field'), 'x'); // the change is kept

    // The server learns the field; after the retry interval it goes out.
    server.refuse = null;
    server.now += const Duration(minutes: 2).inMilliseconds;
    await a.engine.syncNow();
    expect(server.value('task', 't1', 'future_field'), 'x');
    expect(a.engine.status.held, 0);
  });

  test('a re-seeded field last written by the server goes out as this device', () async {
    final a = Device('dev-a', server);
    await a.store.applyOps([
      Op(id: 's1', entity: 'task', entityId: 't1', field: 'title', value: 'via REST', ts: 5, device: 'server:abc'),
    ]);
    await a.engine.reseed('gen-x');
    await a.engine.syncNow();
    final sent = (server.requests.first['ops'] as List).cast<Map>();
    expect(sent.single['device'], 'dev-a');
    expect(sent.single['ts'], 5);
  });

  test('a page that is not a sync answer keeps the outbox and reports an error', () async {
    final a = Device('dev-a', server, exchange: (_) async => {'html': '<captive portal>'});
    await a.edit('title', 'kept');
    await a.engine.syncNow();
    await a.engine.stop();
    expect(a.engine.status.phase, SyncPhase.error);
    expect(await a.store.outboxCount(), 1);
  });

  test('stop() makes a running exchange give up before its next write', () async {
    late SyncEngine engine;
    final a = Device('dev-a', server, exchange: (body) async {
      unawaited(engine.stop()); // sign-out while the request is in flight
      return server.exchange(body);
    });
    engine = a.engine;
    await a.edit('title', 'x');
    await engine.syncNow();
    expect(await a.store.outboxCount(), 1); // the answer was not applied
    expect(await a.store.cursor, 0);
  });

  test('requestSync debounces edits into one exchange', () async {
    final a = Device('dev-a', server);
    final fast = SyncEngine(
      store: a.store,
      exchange: server.exchange,
      hlc: a.hlc,
      device: 'dev-a',
      debounce: const Duration(milliseconds: 20),
    );
    await a.edit('title', '1');
    fast.requestSync();
    await a.edit('title', '2');
    fast.requestSync();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(server.requests.length, 1);
    expect(server.value('task', 't1', 'title'), '2');
    await fast.dispose();
  });

  test('status stream reports syncing then idle with the pending count', () async {
    final a = Device('dev-a', server);
    final seen = <SyncPhase>[];
    final sub = a.engine.statusStream.listen((s) => seen.add(s.phase));
    await a.edit('title', 'x');
    await a.engine.syncNow();
    await Future<void>.delayed(Duration.zero);
    expect(seen.first, SyncPhase.syncing);
    expect(seen.last, SyncPhase.idle);
    expect(a.engine.status.pending, 0);
    expect(a.engine.status.lastSyncedAt, server.now);
    await sub.cancel();
  });
}
