// The exchange loop (docs/sync.md §Exchange), ported from web/src/lib/sync.ts:
// push up to 500 outbox ops, pull what other devices wrote, repeat until both
// sides are quiet. Handles refusals (`rejected`), clock-skew refusals
// (web clockSkew.ts), held ops for reasons a later server may accept
// (web limits.ts), log generation changes (re-seed) and the triggers: a
// debounced request after a local edit, a periodic timer and manual runs.

import 'dart:async';
import 'dart:math' as math;

import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/op.dart';
import 'api.dart';
import 'store.dart';

/// One POST /api/v1/sync: takes the request body, returns the decoded answer
/// ([ApiClient.exchange] in the app, a fake server in tests).
typedef ExchangeFn = Future<Map<String, dynamic>> Function(Map<String, dynamic> body);

/// Transforms ops at the device boundary: content encryption of outgoing ops
/// and decryption of incoming ones (M1.6). Must keep ids and order.
typedef OpsTransform = Future<List<Op>> Function(List<Op> ops);

/// Features this client handles (docs/sync.md §Exchange).
const List<String> syncFeatures = ['clock_skew', 'invalid_ops'];

/// Refusal reasons that are a verdict on the value: the local change is
/// dropped and the server's value (served in the same answer) wins.
const Set<String> verdictReasons = {'invalid', 'forbidden', 'scope_change', 'not_a_member'};

const String clockSkewReason = 'clock_skew';

/// Meta key of ops held back for a reason a later server may accept
/// (`unknown_field`, server limits); offered again every [heldRetry].
const String heldMetaKey = 'held';

/// Devices only the server may write as (internal/sync/devices.go).
bool reservedDevice(String device) =>
    device == 'server' ||
    const ['server:', 'agent:', 'caldav:', 'issues:', 'rule:', 'calsync:', 'public:', 'page:']
        .any(device.startsWith);

enum SyncPhase { idle, syncing, offline, error, reseeding }

class SyncStatus {
  final SyncPhase phase;
  final int pending;
  final int? lastSyncedAt;
  final String? error;

  /// Ops the server refused as a verdict since the last [SyncEngine.dismissRejected].
  final int rejected;

  /// Ops held back for a reason a later server may accept.
  final int held;

  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.pending = 0,
    this.lastSyncedAt,
    this.error,
    this.rejected = 0,
    this.held = 0,
  });

  SyncStatus copyWith({
    SyncPhase? phase,
    int? pending,
    int? lastSyncedAt,
    String? Function()? error,
    int? rejected,
    int? held,
  }) =>
      SyncStatus(
        phase: phase ?? this.phase,
        pending: pending ?? this.pending,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        error: error != null ? error() : this.error,
        rejected: rejected ?? this.rejected,
        held: held ?? this.held,
      );

  @override
  String toString() => 'SyncStatus($phase pending=$pending error=$error rejected=$rejected held=$held)';
}

/// The answer was not a sync page (a proxy or captive portal answering 200):
/// nothing was synced and the outbox stays.
class BadSyncResponse implements Exception {
  final String message;
  BadSyncResponse(this.message);
  @override
  String toString() => 'BadSyncResponse: $message';
}

class SyncEngine {
  final SyncStore store;
  final ExchangeFn exchange;
  final Hlc hlc;
  final String device;
  final OpsTransform prepareOutgoing;
  final OpsTransform decodeIncoming;

  /// Minutes east of UTC, sent as `tzOffset`.
  final int Function() tzOffset;
  final Backoff backoff;
  final int Function() clock;

  /// Debounce after a local edit; the periodic poll interval; how often held
  /// ops are offered again.
  final Duration debounce;
  final Duration interval;
  final Duration heldRetry;

  /// Called with the ops applied from each page (UI refresh, reminders, …).
  final void Function(List<Op> applied)? onApplied;

  final _status = StreamController<SyncStatus>.broadcast();
  SyncStatus _current = const SyncStatus();

  Future<void>? _running;
  bool _again = false;
  Timer? _debounceTimer;
  Timer? _intervalTimer;
  Timer? _retryTimer;
  int _failures = 0;
  int _lastHeldRetry = 0;
  int _epoch = 0;

  SyncEngine({
    required this.store,
    required this.exchange,
    required this.hlc,
    required this.device,
    OpsTransform? prepareOutgoing,
    OpsTransform? decodeIncoming,
    int Function()? tzOffset,
    Backoff? backoff,
    int Function()? clock,
    this.debounce = const Duration(milliseconds: 250),
    this.interval = const Duration(seconds: 30),
    this.heldRetry = const Duration(minutes: 1),
    this.onApplied,
  })  : prepareOutgoing = prepareOutgoing ?? _identity,
        decodeIncoming = decodeIncoming ?? _identity,
        tzOffset = tzOffset ?? (() => DateTime.now().timeZoneOffset.inMinutes),
        backoff = backoff ?? Backoff(),
        clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static Future<List<Op>> _identity(List<Op> ops) async => ops;

  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus get status => _current;

  void _publish(SyncStatus next) {
    _current = next;
    if (!_status.isClosed) _status.add(next);
  }

  /// Seeds the clock from meta and starts the periodic poll.
  Future<void> start() async {
    hlc.seed(await store.hlcLast);
    hlc.seedOffset(await store.hlcOffset);
    _intervalTimer?.cancel();
    _intervalTimer = Timer.periodic(interval, (_) => requestSync(Duration.zero));
    requestSync(Duration.zero);
  }

  /// Stops timers and makes a running exchange stop before its next write
  /// (sign-out: web `stopSync`, a new local data epoch). Waits for it.
  Future<void> stop() async {
    _epoch++;
    _debounceTimer?.cancel();
    _intervalTimer?.cancel();
    _retryTimer?.cancel();
    _debounceTimer = _intervalTimer = _retryTimer = null;
    _again = false;
    final running = _running;
    if (running != null) await running.catchError((_) {});
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }

  /// Runs an exchange after [delay] (default: the edit debounce).
  void requestSync([Duration? delay]) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay ?? debounce, () => syncNow());
  }

  void dismissRejected() => _publish(_current.copyWith(rejected: 0));

  /// Runs an exchange now; a call while one runs schedules one more round
  /// after it and returns when that is done.
  Future<void> syncNow() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final epoch = _epoch;
    final run = () async {
      try {
        do {
          _again = false;
          await _exchange(epoch);
        } while (_again && epoch == _epoch);
      } finally {
        _running = null;
      }
    }();
    _running = run;
    return run;
  }

  Future<void> _exchange(int epoch) async {
    void alive() {
      if (epoch != _epoch) throw const _Stopped();
    }

    _publish(_current.copyWith(phase: SyncPhase.syncing, error: () => null, pending: await store.outboxCount()));
    try {
      await _requeueHeldIfDue();
      alive();
      var skewRounds = 0;
      for (;;) {
        final cursor = await store.cursor;
        final batch = await store.readOutbox();
        // A re-seed re-sends fields with the clock they were written with; a
        // field written by the server or an agent goes out as this device's
        // write at its original time (reseed-reserved-devices D1).
        final sent = [
          for (final o in batch)
            reservedDevice(o.device) ? (Op.fromJson(o.toJson())..device = device) : o,
        ];
        final wire = await prepareOutgoing(sent);
        alive();
        final res = await exchange({
          'device': device,
          'cursor': cursor,
          'ops': [for (final o in wire) o.toJson()],
          'features': syncFeatures,
          'tzOffset': tzOffset(),
        });
        alive();
        final page = _SyncPage.parse(res);

        hlc.observeServerTime(page.serverTime);
        if (await store.hlcOffset != hlc.offset) await store.setHlcOffset(hlc.offset);

        final skewed = page.rejected.where((r) => r.reason == clockSkewReason).toList();
        final verdicts = page.rejected.where((r) => verdictReasons.contains(r.reason)).toList();
        final heldNow = page.rejected
            .where((r) => r.reason != clockSkewReason && !verdictReasons.contains(r.reason))
            .toList();
        if (skewed.isNotEmpty && ++skewRounds > 3) {
          throw StateError('This device’s clock is far off and the server keeps refusing its changes. '
              'Your changes stay on this device.');
        }

        final incoming = await decodeIncoming(page.ops);
        alive();
        final applied = await store.transaction((tx) async {
          if (batch.isNotEmpty) await tx.deleteOutbox(batch.map((o) => o.id));
          final byId = {for (final o in sent) o.id: o};
          if (heldNow.isNotEmpty) await _hold(tx, [for (final r in heldNow) ?byId[r.id]]);
          await _restampSkewed(tx, [for (final r in skewed) ?byId[r.id]], skewed, page.serverTime);
          // A refused op never happened: forget its register so the server's
          // value (in page.ops) or the field's default wins.
          for (final r in verdicts) {
            final o = byId[r.id];
            if (o != null) await tx.forgetField(o.entity, o.entityId, o.field, ts: o.ts, device: o.device);
          }
          return tx.applyOps(incoming);
        });
        alive();
        if (incoming.isNotEmpty) {
          hlc.receive(incoming.map((o) => o.ts).reduce(math.max));
        }
        await store.setHlcLast(hlc.last);
        if (verdicts.isNotEmpty) _publish(_current.copyWith(rejected: _current.rejected + verdicts.length));
        if (applied.isNotEmpty) onApplied?.call(applied);

        if (await _generationChanged(page.generation)) {
          alive();
          _publish(_current.copyWith(phase: SyncPhase.reseeding));
          await reseed(page.generation!);
          alive();
          continue;
        }
        await store.setCursor(page.cursor);
        final left = await store.outboxCount();
        _publish(_current.copyWith(pending: left, held: await _heldCount()));
        if (!page.hasMore && left == 0) break;
      }
      _failures = 0;
      _publish(_current.copyWith(phase: SyncPhase.idle, lastSyncedAt: clock(), error: () => null));
    } on _Stopped {
      return;
    } on NetworkError catch (e) {
      if (epoch != _epoch) return;
      _publish(_current.copyWith(phase: SyncPhase.offline, error: () => e.toString()));
      _scheduleRetry();
    } on RateLimitedError catch (e) {
      if (epoch != _epoch) return;
      _publish(_current.copyWith(phase: SyncPhase.offline, error: () => e.toString()));
      _scheduleRetry(e.retryAfter);
    } catch (e) {
      if (epoch != _epoch) return;
      _publish(_current.copyWith(phase: SyncPhase.error, error: () => e.toString()));
      _scheduleRetry();
    }
  }

  void _scheduleRetry([Duration? atLeast]) {
    var d = backoff.delay(_failures++);
    if (atLeast != null && atLeast > d) d = atLeast;
    _retryTimer?.cancel();
    _retryTimer = Timer(d, () => syncNow());
  }

  /// Ops refused for a fast clock: the clock is corrected, the ops stamped
  /// again (ops that shared a timestamp share the new one, order kept), the
  /// rows' clocks follow, and they go out in the next round (web clockSkew.ts).
  Future<void> _restampSkewed(SyncStore tx, List<Op> refused, List<_Rejection> skewed, int? serverTime) async {
    if (refused.isEmpty) return;
    final st = skewed.map((r) => r.serverTime).nonNulls.firstOrNull ?? serverTime;
    if (st != null) hlc.clockRefused(st);
    refused.sort((a, b) => a.ts.compareTo(b.ts));
    final fresh = <int, int>{};
    final out = <Op>[];
    for (final op in refused) {
      final ts = fresh.putIfAbsent(op.ts, hlc.now);
      out.add(Op(id: op.id, entity: op.entity, entityId: op.entityId, field: op.field, value: op.value, ts: ts, device: op.device));
      // Only while the register still holds this op's value: a newer local edit keeps its own clock.
      final cur = await tx.getField(op.entity, op.entityId, op.field);
      if (cur != null && cur.ts == op.ts && cur.device == op.device) {
        await tx.forgetField(op.entity, op.entityId, op.field, ts: op.ts, device: op.device);
        await tx.applyOps([out.last]);
      }
    }
    await tx.appendOutbox(out);
    await tx.setHlcLast(hlc.last);
  }

  Future<void> _hold(SyncStore tx, List<Op> ops) async {
    final held = await _heldOps(tx);
    final ids = {for (final o in held) o.id};
    held.addAll(ops.where((o) => ids.add(o.id)));
    await tx.setMeta(heldMetaKey, [for (final o in held) o.toJson()]);
  }

  Future<List<Op>> _heldOps(SyncStore s) async => [
        for (final j in (await s.getMeta(heldMetaKey) as List?) ?? const [])
          Op.fromJson((j as Map).cast<String, dynamic>()),
      ];

  Future<int> _heldCount() async => ((await store.getMeta(heldMetaKey) as List?) ?? const []).length;

  Future<void> _requeueHeldIfDue() async {
    final now = clock();
    final since = now - _lastHeldRetry;
    if (since < heldRetry.inMilliseconds && since >= 0) return;
    _lastHeldRetry = now;
    await store.transaction((tx) async {
      final held = await _heldOps(tx);
      if (held.isEmpty) return;
      await tx.appendOutbox(held);
      await tx.setMeta(heldMetaKey, null);
    });
  }

  /// Adopts the first generation seen; true when a different one arrives
  /// (the server was restored from a backup, docs/sync.md §Log generation).
  Future<bool> _generationChanged(String? generation) async {
    if (generation == null || generation.isEmpty) return false;
    final stored = await store.generation;
    if (stored == null) {
      await store.setGeneration(generation);
      return false;
    }
    return stored != generation;
  }

  /// Re-emits every stored field as a new op with its stored clock (never a
  /// fresh timestamp), queues them, restarts the pull from zero and adopts
  /// [generation] — all in one transaction. Queued ops stay.
  Future<void> reseed(String generation) => store.transaction((tx) async {
        final fields = await tx.allFields();
        for (var i = 0; i < fields.length; i += 1000) {
          await tx.appendOutbox([
            for (final f in fields.skip(i).take(1000))
              Op(
                id: uuid(),
                entity: f.entity,
                entityId: f.entityId,
                field: f.field,
                value: f.stored.value,
                ts: f.stored.ts,
                device: f.stored.device,
              ),
          ]);
        }
        await tx.setCursor(0);
        await tx.setGeneration(generation);
      });
}

class _Stopped implements Exception {
  const _Stopped();
}

class _Rejection {
  final String id;
  final String reason;
  final int? serverTime;
  _Rejection(this.id, this.reason, this.serverTime);
}

class _SyncPage {
  final List<Op> ops;
  final int cursor;
  final bool hasMore;
  final int? serverTime;
  final String? generation;
  final List<_Rejection> rejected;

  _SyncPage(this.ops, this.cursor, this.hasMore, this.serverTime, this.generation, this.rejected);

  static _SyncPage parse(Map<String, dynamic> r) {
    final ops = r['ops'];
    final cursor = r['cursor'];
    if (ops is! List || cursor is! num) {
      throw BadSyncResponse('The server sent an answer this app does not understand. '
          'Your changes stay on this device.');
    }
    return _SyncPage(
      [for (final o in ops) Op.fromJson((o as Map).cast<String, dynamic>())],
      cursor.toInt(),
      r['hasMore'] == true,
      (r['serverTime'] as num?)?.toInt(),
      r['generation'] as String?,
      [
        for (final x in (r['rejected'] as List?) ?? const [])
          _Rejection(
            (x as Map)['id'] as String,
            x['reason'] as String? ?? 'invalid',
            (x['serverTime'] as num?)?.toInt(),
          ),
      ],
    );
  }
}
