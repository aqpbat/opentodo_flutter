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

final RegExp _fieldId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// The ops of one batch: one per field, all with the same `ts` and `device`.
/// A task's `fields` map (custom field values) unfolds into one `fields.<id>`
/// op per custom field.
List<Op> changesToOps(
  Iterable<Change> changes, {
  required int ts,
  required String device,
  String Function() newId = uuid,
}) {
  final ops = <Op>[];
  for (final c in changes) {
    c.patch.forEach((field, value) {
      if (c.entity == 'task' && field == 'fields') {
        ((value as Map?) ?? const {}).forEach((id, v) {
          if (_fieldId.hasMatch(id as String)) {
            ops.add(Op(id: newId(), entity: c.entity, entityId: c.entityId, field: 'fields.$id', value: v, ts: ts, device: device));
          }
        });
        return;
      }
      ops.add(Op(id: newId(), entity: c.entity, entityId: c.entityId, field: field, value: value, ts: ts, device: device));
    });
  }
  return ops;
}
