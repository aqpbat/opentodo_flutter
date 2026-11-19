// A minimal hybrid logical clock, ported from OpenTodo's web/src/lib/hlc.ts:
// wall-clock milliseconds nudged forward so timestamps issued by this device
// are strictly increasing even when the system clock jumps backwards, and
// corrected towards server time when the local clock is clearly off.

import 'dart:math' as math;

/// How far ahead of the server's clock an op may be stamped
/// (internal/sync MaxFutureSkewMs).
const int maxFutureSkewMs = 5 * 60 * 1000;

/// Skews up to this size are left alone, so network latency causes no jitter.
const int _skewToleranceMs = 2000;

/// How far ahead of the server a refused clock may stay without restarting.
const int _restartAfterRefusalMs = maxFutureSkewMs ~/ 2;

class Hlc {
  /// The wall clock in Unix ms; injectable for tests.
  int Function() wallClock;

  int _last = 0;
  int _offset = 0;

  Hlc({int Function()? wallClock})
      : wallClock = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  int now() {
    final n = wallClock() + _offset;
    _last = math.max(n, _last + 1);
    return _last;
  }

  /// Called with the last timestamp persisted by this device so a restart
  /// never reuses one.
  void seed(int ts) {
    if (ts > _last) _last = ts;
  }

  /// The receive rule: called with the newest timestamp of received ops, so
  /// the next local edit wins last-writer-wins even when the local wall clock
  /// runs behind the writer's.
  void receive(int ts) {
    if (ts > _last) _last = ts;
  }

  /// Called after each sync: the offset follows the server whenever the skew
  /// is large and goes back to zero once the local clock is right again.
  void observeServerTime(int? serverTime) {
    if (serverTime == null) return;
    final skew = serverTime - wallClock();
    _offset = skew.abs() > _skewToleranceMs ? skew : 0;
    if (_last > serverTime + maxFutureSkewMs) _last = serverTime;
  }

  /// Called when the server refused ops as stamped too far ahead
  /// (reason `clock_skew`).
  void clockRefused(int serverTime) {
    observeServerTime(serverTime);
    if (_last > serverTime + _restartAfterRefusalMs) _last = serverTime;
  }

  int get last => _last;

  /// The current correction towards server time, in milliseconds.
  int get offset => _offset;

  /// Called at start-up with the stored offset, so stamps before the first
  /// sync are corrected too.
  void seedOffset(int stored) {
    _offset = stored;
  }
}

/// Last-writer-wins comparison shared with the server (internal/sync/ops.go):
/// the greater ts wins; on a tie the greater device id wins.
bool wins(int ts, String device, {int? existingTs, String? existingDevice}) {
  if (existingTs == null || existingDevice == null) return true;
  return ts > existingTs || (ts == existingTs && device.compareTo(existingDevice) > 0);
}
