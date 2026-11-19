// Reminders: firing times, the show rule and the reminder writes.
//
// ported from web/src/lib/reminderTime.ts (pure time arithmetic),
// web/src/lib/reminders.ts (writes, as [Change] planners instead of mutate
// calls) and web/src/lib/ops.ts reminderFollowUps; rules in docs/sync.md
// §Reminders and internal/zoned/due.go.
//
// Rows are materialized Map rows (lib/core/schema_generated.dart opDefaults)
// that also carry their entity id under `id`. Every planner returns
// `List<Change>` for one `mutate(changes)` batch (see change.dart).

import '../core/ids.dart';
import '../core/op.dart';
import 'change.dart';
import 'dates.dart';

/// Due time assumed for a task that has a date but no time (local wall clock).
const String defaultReminderTime = '09:00';

/// Bounds of a reminder offset (server MaxReminderOffset): one year either way.
const int maxReminderOffset = 525600;

int? _int(Object? v) => v is num ? v.toInt() : null;

/// JS truthiness of a stored value (null, 0, false and '' are false).
bool _truthy(Object? v) => v != null && v != false && v != 0 && v != '';

// ---- firing times (reminderTime.ts) ----

/// The instant a due denotes: a zoned due is its wall time in its own zone; a
/// floating one is read in `zone` (the viewer's, i.e. this device's), at 09:00
/// when it has no time. Gap and overlap follow internal/zoned.
int dueInstant(Due due, {String? zone}) {
  if (isZoned(due)) {
    try {
      return zonedInstant(due.date, due.time!, due.tz!);
    } on ArgumentError {
      // Unknown zone on this device: fall back to the floating reading.
    }
  }
  return zonedInstant(due.date, due.time ?? defaultReminderTime, zone ?? viewerZone());
}

/// Firing instant of a relative reminder: due time plus offset; null without a
/// due date. `due` is a [Due] or its stored JSON.
int? relativeFireAt(Object? due, int? offsetMinutes, {String? zone}) {
  final d = Due.fromJson(due);
  if (d == null) return null;
  return dueInstant(d, zone: zone) + (offsetMinutes ?? 0) * 60000;
}

/// Firing instant of a deadline reminder: 09:00 local on the deadline day plus
/// offset; null without a deadline.
int? deadlineFireAt(Object? deadline, int? offsetMinutes, {String? zone}) {
  if (deadline is! String || deadline.isEmpty) return null;
  return dueInstant(Due(deadline), zone: zone) + (offsetMinutes ?? 0) * 60000;
}

/// The firing that `delivered_at` acknowledges is the current one.
bool isDelivered(Map<String, Object?> r) {
  final d = _int(r['delivered_at']), f = _int(r['fire_at']);
  return d != null && f != null && d >= f;
}

/// Dismissed for the current firing; a dismissal older than `fire_at` belongs
/// to an earlier firing and does not count.
bool isDismissed(Map<String, Object?> r) {
  final d = _int(r['dismissed_at']), f = _int(r['fire_at']);
  return d != null && f != null && d >= f;
}

/// Whether a reminder is shown now: `fire_at` ≤ now, not deleted, not dismissed
/// for the current firing, and its task exists and is neither completed nor deleted.
bool isReminderDue(Map<String, Object?> r, Map<String, Object?>? task, int now) {
  final fireAt = _int(r['fire_at']);
  if (_truthy(r['deleted_at']) || fireAt == null || fireAt > now) return false;
  if (isDismissed(r)) return false;
  return task != null && !_truthy(task['completed_at']) && !_truthy(task['deleted_at']);
}

enum SnoozeChoice { tenMinutes, oneHour, tomorrow }

/// The new firing instant for a snooze: +10 min, +1 h, or tomorrow 09:00 in `zone`.
int snoozeUntil(SnoozeChoice choice, int now, {String? zone}) {
  switch (choice) {
    case SnoozeChoice.tenMinutes:
      return now + 10 * 60000;
    case SnoozeChoice.oneHour:
      return now + 60 * 60000;
    case SnoozeChoice.tomorrow:
      final z = zone ?? viewerZone();
      return zonedInstant(addDaysIso(todayIso(now, z), 1), defaultReminderTime, z);
  }
}

/// By firing time (unset last), then creation time.
List<Map<String, Object?>> sortReminders(Iterable<Map<String, Object?>> list) {
  final out = [...list];
  int key(Map<String, Object?> r) => _int(r['fire_at']) ?? 0x7fffffffffffffff;
  out.sort((a, b) {
    final c = key(a).compareTo(key(b));
    return c != 0 ? c : (_int(a['created_at']) ?? 0).compareTo(_int(b['created_at']) ?? 0);
  });
  return out;
}

// ---- writes (reminders.ts) ----

/// A refused reminder write (bad input or a missing task).
class ReminderError implements Exception {
  final String message;
  const ReminderError(this.message);
  @override
  String toString() => 'ReminderError: $message';
}

/// What the user picked for a reminder.
sealed class ReminderInput {
  const ReminderInput();
}

/// Offset from the task's due time (negative = before).
class RelativeReminder extends ReminderInput {
  final int offsetMinutes;
  const RelativeReminder(this.offsetMinutes);
}

/// A fixed moment (Unix ms).
class AbsoluteReminder extends ReminderInput {
  final int fireAt;
  const AbsoluteReminder(this.fireAt);
}

/// Offset from 09:00 local on the task's deadline.
class DeadlineReminder extends ReminderInput {
  final int offsetMinutes;
  const DeadlineReminder(this.offsetMinutes);
}

/// Fires on a phone entering (`arrive`) or leaving (`leave`) the task's location.
class LocationReminder extends ReminderInput {
  final String kind;
  final int radiusM;
  const LocationReminder(this.kind, this.radiusM);
}

/// The kind-dependent fields: kind, offset_minutes, fire_at, radius_m.
Map<String, Object?> _shapeOf(ReminderInput input, Map<String, Object?>? task, String? zone) {
  switch (input) {
    case LocationReminder(:final kind, :final radiusM):
      if (kind != 'arrive' && kind != 'leave') throw ReminderError('unknown location kind $kind');
      if (radiusM < 100 || radiusM > 5000) throw const ReminderError('radius must be 100 to 5000 metres');
      return {'kind': kind, 'offset_minutes': null, 'fire_at': null, 'radius_m': radiusM};
    case AbsoluteReminder(:final fireAt):
      if (fireAt <= 0) throw const ReminderError('a reminder time is required');
      return {'kind': 'absolute', 'offset_minutes': null, 'fire_at': fireAt, 'radius_m': null};
    case RelativeReminder(:final offsetMinutes):
      _checkOffset(offsetMinutes);
      return {'kind': 'relative', 'offset_minutes': offsetMinutes, 'fire_at': relativeFireAt(task?['due'], offsetMinutes, zone: zone), 'radius_m': null};
    case DeadlineReminder(:final offsetMinutes):
      _checkOffset(offsetMinutes);
      return {'kind': 'deadline', 'offset_minutes': offsetMinutes, 'fire_at': deadlineFireAt(task?['deadline'], offsetMinutes, zone: zone), 'radius_m': null};
  }
}

void _checkOffset(int m) {
  if (m.abs() > maxReminderOffset) throw const ReminderError('offset out of range');
}

/// Add a reminder to `task` (its row with `id`). A relative reminder on an
/// undated task has no firing time yet. `id` defaults to a new uuid.
Change addReminderChange(Map<String, Object?>? task, ReminderInput input, {required int now, String? id, String? zone}) {
  if (task == null || _truthy(task['deleted_at'])) throw const ReminderError('task not found');
  final shape = _shapeOf(input, task, zone);
  final radius = shape.remove('radius_m');
  return Change('reminder', id ?? uuid(), {
    'task_id': task['id'],
    ...shape,
    // Only a location reminder writes a radius; the others keep the default.
    'radius_m': ?radius,
    'delivered_at': null,
    'dismissed_at': null,
    'created_at': now,
    'deleted_at': null,
  });
}

/// Edit a reminder (its row with `id`): new offset or moment, or another kind.
/// The firing time is recomputed and delivery state cleared when it moves.
Change updateReminderChange(Map<String, Object?> reminder, Map<String, Object?>? task, ReminderInput input, {String? zone}) {
  if (_truthy(reminder['deleted_at'])) throw const ReminderError('reminder not found');
  final shape = _shapeOf(input, task, zone);
  final patch = <String, Object?>{'kind': shape['kind'], 'offset_minutes': shape['offset_minutes'], 'fire_at': shape['fire_at']};
  final radius = shape['radius_m'];
  if (radius != null || reminder['radius_m'] != null) patch['radius_m'] = radius;
  if (patch['fire_at'] != _int(reminder['fire_at']) || shape['kind'] != reminder['kind'] || (radius != null && radius != reminder['radius_m'])) {
    patch['delivered_at'] = null;
    patch['dismissed_at'] = null;
  }
  return Change('reminder', reminder['id'] as String, patch);
}

/// Tombstone a reminder.
Change deleteReminderChange(String id, int now) => Change('reminder', id, {'deleted_at': now});

/// Snooze: a new firing time with delivered and dismissed state cleared, so it
/// fires again. Kind and offset are kept, so a later due change recomputes it.
Change snoozeReminderChange(String id, int fireAt) =>
    Change('reminder', id, {'fire_at': fireAt, 'delivered_at': null, 'dismissed_at': null});

/// Dismiss the current firing.
Change dismissReminderChange(String id, int now) => Change('reminder', id, {'dismissed_at': now});

/// A dismissed location reminder watches its place again.
Change rearmReminderChange(String id) => Change('reminder', id, {'dismissed_at': null});

// ---- follow-ups of due and deadline changes ----

/// The reminder rows (with `id`) of a task, live or deleted.
typedef RemindersOf = Iterable<Map<String, Object?>> Function(String taskId);

/// The `fire_at` writes a batch needs because it changes a task's `due` or
/// `deadline` (ported from ops.ts reminderFollowUps): every live relative
/// reminder follows `due`, every live deadline reminder follows `deadline`; a
/// moved firing also clears `delivered_at`/`dismissed_at` where set. Reminders
/// whose `fire_at` the batch already writes keep that value. Append the result
/// to the same batch, so the ops share the `due` op's ts and device.
List<Change> reminderFollowUps(List<Change> changes, RemindersOf remindersOf, {String? zone}) {
  final out = <Change>[];
  final written = {
    for (final c in changes)
      if (c.entity == 'reminder' && c.patch.containsKey('fire_at')) c.entityId,
  };
  for (final c in changes) {
    final hasDue = c.patch.containsKey('due');
    final hasDeadline = c.patch.containsKey('deadline');
    if (c.entity != 'task' || !(hasDue || hasDeadline)) continue;
    for (final r in remindersOf(c.entityId)) {
      final id = r['id'] as String;
      if (_truthy(r['deleted_at']) || written.contains(id)) continue;
      final offset = _int(r['offset_minutes']);
      final int? fireAt;
      if (r['kind'] == 'relative' && hasDue) {
        fireAt = relativeFireAt(c.patch['due'], offset, zone: zone);
      } else if (r['kind'] == 'deadline' && hasDeadline) {
        fireAt = deadlineFireAt(c.patch['deadline'], offset, zone: zone);
      } else {
        continue;
      }
      final p = <String, Object?>{'fire_at': fireAt};
      if (fireAt != _int(r['fire_at'])) {
        if (r['delivered_at'] != null) p['delivered_at'] = null;
        if (r['dismissed_at'] != null) p['dismissed_at'] = null;
      }
      out.add(Change('reminder', id, p));
    }
  }
  return out;
}

/// `changes` plus their [reminderFollowUps], ready for one `mutate` batch.
List<Change> withReminderFollowUps(List<Change> changes, RemindersOf remindersOf, {String? zone}) =>
    [...changes, ...reminderFollowUps(changes, remindersOf, zone: zone)];

/// After a pull: this device's own relative and deadline reminders of shared
/// tasks whose `due` or `deadline` arrived in `ops` (another member cannot write
/// our personal reminders). Personal tasks are skipped: the device that changed
/// the due wrote them in the same batch. Returns new changes (a new batch).
/// `tasks` maps task id → row; `sharedProjects` holds shared project ids.
List<Change> sharedDueFollowUps(
  Iterable<Op> ops, {
  required Map<String, Map<String, Object?>> tasks,
  required Set<String> sharedProjects,
  required RemindersOf remindersOf,
  String? zone,
}) {
  final taskIds = {
    for (final o in ops)
      if (o.entity == 'task' && (o.field == 'due' || o.field == 'deadline')) o.entityId,
  };
  final out = <Change>[];
  for (final taskId in taskIds) {
    final task = tasks[taskId];
    final project = task?['project_id'];
    if (task == null || project is! String || project.isEmpty || _truthy(task['deleted_at'])) continue;
    if (!sharedProjects.contains(project)) continue;
    for (final r in remindersOf(taskId)) {
      final kind = r['kind'];
      if (_truthy(r['deleted_at']) || (kind != 'relative' && kind != 'deadline')) continue;
      final offset = _int(r['offset_minutes']) ?? 0;
      final fireAt = kind == 'deadline'
          ? deadlineFireAt(task['deadline'], offset, zone: zone)
          : relativeFireAt(task['due'], offset, zone: zone);
      if (fireAt == _int(r['fire_at'])) continue;
      out.add(Change('reminder', r['id'] as String, {'fire_at': fireAt, 'delivered_at': null, 'dismissed_at': null}));
    }
  }
  return out;
}
