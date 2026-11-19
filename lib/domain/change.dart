// A batch of field changes, the unit a local edit is written in.
//
// ported from web/src/lib/ops.ts (`Change`, the op loop of `mutateMany`).
// Domain planners (reminders, completion, …) return `List<Change>`; the data
// layer's `mutate(changes)` applies the whole list as ONE batch: every field of
// every change becomes an op with a fresh id and the SAME `ts` and `device`
// (see [changesToOps]). That is how follow-up writes such as reminder `fire_at`
// share the timestamp and device of the `due` op that caused them
// (docs/sync.md §Reminders).

import '../core/ids.dart';
import '../core/op.dart';

class Change {
  final String entity;
  final String entityId;

  /// Field → JSON value (string, number, bool, null, List, Map).
  final Map<String, Object?> patch;

  const Change(this.entity, this.entityId, this.patch);

  Map<String, Object?> toJson() => {'entity': entity, 'entityId': entityId, 'patch': patch};

  @override
  String toString() => 'Change($entity/$entityId $patch)';
}

/// The ops of one batch: one per field, all with the same `ts` and `device`.
List<Op> changesToOps(
  Iterable<Change> changes, {
  required int ts,
  required String device,
  String Function() newId = uuid,
}) =>
    [
      for (final c in changes)
        for (final e in c.patch.entries)
          Op(id: newId(), entity: c.entity, entityId: c.entityId, field: e.key, value: e.value, ts: ts, device: device),
    ];
