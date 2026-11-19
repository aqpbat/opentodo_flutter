// Default reminders: when a person's write gives a task that had no due date a
// due date, one relative reminder with that person's default for the kind of
// due (timed or date only) joins the same batch (design D3). Its id is derived
// from the person and the task (D4), so two devices scheduling the same task
// offline converge on one reminder. When the due switches between a date only
// and a time, an untouched default reminder takes the other default (D5).
//
// ported from web/src/lib/defaultReminder.ts (shared with the server's
// internal/defaultreminder), pinned by defaultReminder.vectors.json.

import '../core/ids.dart';
import 'change.dart';
import 'dates.dart';
import 'reminders.dart';

/// The two defaults in minutes from the due time (09:00 for a date only); null is none.
class DefaultReminders {
  final int? timed;
  final int? dated;
  const DefaultReminders({this.timed, this.dated});
}

/// One stored value: a whole number of minutes within the limit, else none.
int? parseDefaultReminder(Object? value) {
  if (value is! String || !RegExp(r'^-?\d{1,7}$').hasMatch(value)) return null;
  final n = int.parse(value);
  return n.abs() <= maxReminderOffset ? n : null;
}

/// The stored value of a choice: '' for none, else the offset as a decimal string.
String formatDefaultReminder(int? minutes) => minutes == null ? '' : '$minutes';

/// The account's defaults from its user_prefs row; empty, malformed or out of range is none.
DefaultReminders readDefaultReminders(Map<String, Object?>? row) => DefaultReminders(
      timed: parseDefaultReminder(row?['reminder_default_timed']),
      dated: parseDefaultReminder(row?['reminder_default_dated']),
    );

/// The id of a person's default reminder on a task: the same on every device and the server.
String defaultReminderId(String userId, String taskId) => nameId('default-reminder', '$userId\u0000$taskId');

bool _truthy(Object? v) => v != null && v != false && v != 0 && v != '';
bool _timed(Due d) => d.time != null && d.time!.isNotEmpty;

class DefaultReminderInput {
  final String userId;
  final String taskId;

  /// The stored task row, or null when this write creates it.
  final Map<String, Object?>? before;

  /// Every field the write sets on the task.
  final Map<String, Object?> patch;

  /// This person's stored reminder rows (with `id`) of the task, live or deleted.
  final List<Map<String, Object?>> reminders;

  /// Reminder changes already in the same batch (any task; others are ignored).
  final List<Change> batch;
  final DefaultReminders prefs;
  final int now;

  /// Zone floating dues are read in (the viewer's by default).
  final String? zone;

  const DefaultReminderInput({
    required this.userId,
    required this.taskId,
    required this.before,
    required this.patch,
    required this.reminders,
    this.batch = const [],
    required this.prefs,
    required this.now,
    this.zone,
  });
}

/// The task's reminders after the batch: stored rows with the batch's changes over them, plus new ones.
List<Map<String, Object?>> _mergedReminders(DefaultReminderInput input) {
  final byId = <String, Map<String, Object?>>{
    for (final r in input.reminders) r['id'] as String: {...r},
  };
  for (final c in input.batch) {
    if (c.entity != 'reminder') continue;
    final prev = byId[c.entityId];
    if (prev == null && c.patch['task_id'] != input.taskId) continue;
    byId[c.entityId] = {...?prev, ...c.patch, 'id': c.entityId};
  }
  return [
    for (final r in byId.values)
      if (!r.containsKey('task_id') || r['task_id'] == input.taskId) r,
  ];
}

/// The reminder changes one write adds for one task: none, a new default
/// reminder, or the default reminder switched to the other kind of due.
List<Change> planDefaultReminder(DefaultReminderInput input) {
  if (!input.patch.containsKey('due')) return const [];
  int? fire(Due due, int offset) => relativeFireAt(due, offset, zone: input.zone);
  final id = defaultReminderId(input.userId, input.taskId);
  final reminders = _mergedReminders(input);
  final own = reminders.where((r) => r['id'] == id).firstOrNull;
  final oldDue = Due.fromJson(input.before?['due']);
  final newDue = Due.fromJson(input.patch['due']);
  if (newDue == null) return const [];
  int? pref(Due d) => _timed(d) ? input.prefs.timed : input.prefs.dated;
  // A due whose old kind had no default never got one: the switch to a kind
  // with a default counts as getting a due (D3).
  if (oldDue != null && !(_timed(oldDue) != _timed(newDue) && pref(oldDue) == null && own == null)) {
    // D5: the kind of due changed and the default reminder is untouched.
    if (_timed(oldDue) == _timed(newDue) || own == null || _truthy(own['deleted_at']) || (own['kind'] ?? 'relative') != 'relative') {
      return const [];
    }
    final from = pref(oldDue);
    final to = pref(newDue);
    if (from == null || to == null || own['offset_minutes'] != from || from == to) return const [];
    return [
      Change('reminder', id, {'offset_minutes': to, 'fire_at': fire(newDue, to), 'delivered_at': null, 'dismissed_at': null}),
    ];
  }
  // D3: the task gets a due date.
  final offset = pref(newDue);
  if (offset == null) return const [];
  final after = {...?input.before, ...input.patch};
  if (_truthy(after['completed_at']) || _truthy(after['deleted_at']) || after['habit'] == true) return const [];
  if (reminders.any((r) => !_truthy(r['deleted_at']) && (r['kind'] ?? 'relative') == 'relative')) return const [];
  // A default reminder the person deleted stays deleted; one Undo removed (no offset left) may come back.
  // (A missing offset key is JS `undefined`, which is `!== null`.)
  if (own != null && (!_truthy(own['deleted_at']) || !own.containsKey('offset_minutes') || own['offset_minutes'] != null)) {
    return const [];
  }
  return [
    Change('reminder', id, {
      'task_id': input.taskId,
      'kind': 'relative',
      'offset_minutes': offset,
      'fire_at': fire(newDue, offset),
      'delivered_at': null,
      'dismissed_at': null,
      'created_at': input.now,
      'deleted_at': null,
    }),
  ];
}

/// The default reminder changes of a local batch (design D6), pure: `taskRow`
/// and `remindersOf` read this device's store. Skip it for restores (Undo,
/// version restore, Trash), like `mutateMany(…, {restore: true})`.
List<Change> defaultReminderChanges(
  List<Change> changes, {
  required String? userId,
  required DefaultReminders prefs,
  required Map<String, Object?>? Function(String taskId) taskRow,
  required RemindersOf remindersOf,
  required int now,
  String? zone,
}) {
  final patches = <String, Map<String, Object?>>{};
  for (final c in changes) {
    if (c.entity != 'task') continue;
    patches[c.entityId] = {...?patches[c.entityId], ...c.patch};
  }
  final scheduled = patches.entries.where((e) => Due.fromJson(e.value['due']) != null).toList();
  if (scheduled.isEmpty || (prefs.timed == null && prefs.dated == null) || userId == null || userId.isEmpty) {
    return const [];
  }
  final batch = changes.where((c) => c.entity == 'reminder').toList();
  return [
    for (final e in scheduled)
      ...planDefaultReminder(DefaultReminderInput(
        userId: userId,
        taskId: e.key,
        before: taskRow(e.key),
        patch: e.value,
        reminders: remindersOf(e.key).toList(),
        batch: batch,
        prefs: prefs,
        now: now,
        zone: zone,
      )),
  ];
}
