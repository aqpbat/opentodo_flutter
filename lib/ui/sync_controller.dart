// What the UI needs from the sync engine: its status stream and a manual
// run. Screens depend on this interface, not on SyncEngine, so widget tests
// drive the shell with a fake.

import 'dart:async';

import '../data/sync_engine.dart';

abstract interface class SyncController {
  /// The current status (the stream's latest value).
  SyncStatus get status;

  /// Every status change.
  Stream<SyncStatus> get statusStream;

  /// Runs an exchange now (pull-to-sync, a tap on the status pill).
  Future<void> syncNow();
}

/// [SyncController] over the real [SyncEngine].
class EngineSyncController implements SyncController {
  final SyncEngine engine;
  EngineSyncController(this.engine);

  @override
  SyncStatus get status => engine.status;

  @override
  Stream<SyncStatus> get statusStream => engine.statusStream;

  @override
  Future<void> syncNow() => engine.syncNow();
}

/// A controller that never syncs and reports why (e.g. an encrypted account
/// before the content key can be unlocked on this device).
class DisabledSyncController implements SyncController {
  DisabledSyncController(String reason)
      : status = SyncStatus(phase: SyncPhase.error, error: reason);

  @override
  final SyncStatus status;

  @override
  Stream<SyncStatus> get statusStream => const Stream.empty();

  @override
  Future<void> syncNow() async {}
}
