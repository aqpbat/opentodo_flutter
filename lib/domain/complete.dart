// Completing, skipping and acting on one occurrence of a recurring task, and the
// repair of a series that stands on an exception date.
//
// ported from web/src/lib/recurring.ts (records, budget, moveDates, recordFields,
// planCompletion, planSkip) and web/src/lib/seriesPlan.ts (planActOn, planDetach,
// copyReminders, planRepair); the server's port is internal/sync/occurrences.go.
// Pinned by web/src/lib/series.fixture.json (copied unchanged into test/vectors/).
// See docs/recurrence.md and docs/sync.md §Recurring tasks.
//
// Pure planning functions over task rows. A row is a `Map<String, Object?>` with
// the task fields of `opDefaults['task']` (lib/core/schema_generated.dart) plus
// its `'id'`; `due` is `null` or `{'date': 'YYYY-MM-DD', 'time'?: 'HH:MM',
// 'tz'?: 'Area/City'}`. Every value written is a function of inputs all devices
// share (series id, rule, due date, occurrence date, the series' records), so two
// devices acting on the same occurrence offline write identical entities (the
// record's id is `occurrenceId(series, date)`) and converge under
// last-writer-wins.
//
// Output: a `List<Change>`, the shape web `mutateMany` takes. A later
// `mutate()` writes the whole list as ONE batch: one HLC timestamp and one device
// for every op, one `Op` per (entity, entityId, field) of each patch, with a
// `fields` map unfolded into one `fields.<id>` op per custom field. [changesToOps]
// does exactly that expansion.
//
// Not ported (single-piece series only): the lineage of a split series
// (`split_from` pieces, their derived `until` and shared `for N times` budget,
// web lineage.ts) and the chore rotation (web rotation.ts; pass the next
// assignee in instead).

import '../core/ids.dart';
import 'change.dart';
import 'recurrence.dart';

export 'change.dart';

/// A task (or other entity) row.
typedef Row = Map<String, Object?>;

// ---- rows ----

Map<String, Object?>? _due(Row t) => (t['due'] as Map?)?.cast<String, Object?>();
String? _dueDate(Row t) => _due(t)?['date'] as String?;
bool _set(Object? v) => v != null && v != false && v != '' && v != 0;

/// The parsed rule of an open, live series, or null when [task] is not one.
Rule? seriesRule(Row? task) {
  if (task == null) return null;
  final rec = task['recurrence'];
  if (rec is! String || rec.isEmpty || _set(task['completed_at']) || _set(task['deleted_at'])) return null;
  return parseRule(rec).rule;
}

/// The date of the occurrence the series currently stands on.
String occurrenceDate(Row series, String today) => _dueDate(series) ?? today;

// ---- records ----

/// The state of an occurrence record.
enum RecordState { open, done, skipped }

/// An occurrence record of a series: the row, the date it stands for, its state.
class OccurrenceRecord {
  final Row task;
  final String date;
  final RecordState state;
  const OccurrenceRecord(this.task, this.date, this.state);
}

/// The occurrence date a task stands for: `occurrence_date`, or its due date
/// for a record written before the field.
String? recordDate(Row task) => (task['occurrence_date'] as String?) ?? _dueDate(task);

/// True for an occurrence record of [seriesId]: it points at the series and has
/// the id derived from its date.
bool isRecordOf(String seriesId, Row task) {
  if (task['series_id'] != seriesId) return false;
  final date = recordDate(task);
  return date != null && task['id'] == occurrenceId(seriesId, date);
}

/// True for any occurrence record (of whatever series).
bool isOccurrenceRecord(Row task) {
  final s = task['series_id'];
  return s is String && s.isNotEmpty && isRecordOf(s, task);
}

RecordState recordState(Row task) {
  if (!_set(task['completed_at'])) return RecordState.open;
  return task['skipped'] == true ? RecordState.skipped : RecordState.done;
}

/// The live occurrence records of a series (a trashed record is left out).
List<OccurrenceRecord> recordsOf(String seriesId, Iterable<Row> tasks) => [
      for (final t in tasks)
        if (!_set(t['deleted_at']) && isRecordOf(seriesId, t)) OccurrenceRecord(t, recordDate(t)!, recordState(t)),
    ];

/// What `for N times` has used, and the exception dates.
class Budget {
  /// Occurrences used: done and open records (never skipped ones).
  final int taken;
  final int done;

  /// Exception dates: the dates of every record of the series.
  final Set<String> except;
  const Budget(this.taken, this.done, this.except);
}

/// The budget of [seriesId], leaving out the record of [exceptDate] (the
/// occurrence being acted on) from the count; its date stays an exception.
Budget seriesBudget(String seriesId, Iterable<Row> tasks, [String? exceptDate]) {
  var done = 0, open = 0;
  final except = <String>{};
  for (final r in recordsOf(seriesId, tasks)) {
    except.add(r.date);
    if (r.date == exceptDate) continue;
    if (r.state == RecordState.done) done++;
    if (r.state == RecordState.open) open++;
  }
  return Budget(done + open, done, except);
}

// ---- dates ----

/// The series' due on another date, keeping its time and zone.
Map<String, Object?> _moveDue(Map<String, Object?>? due, String date) {
  final time = due?['time'];
  if (time == null) return {'date': date};
  final tz = due!['tz'];
  return tz != null ? {'date': date, 'time': time, 'tz': tz} : {'date': date, 'time': time};
}

/// The series' dates on another occurrence: the due date moves to [next], and a
/// deadline and start move by the same number of calendar days. A series
/// without a deadline writes no deadline field.
Map<String, Object?> moveDates(Row series, String next, String today) {
  final out = <String, Object?>{'due': _moveDue(_due(series), next)};
  final from = occurrenceDate(series, today);
  final deadline = series['deadline'];
  if (deadline is String && deadline.isNotEmpty) out['deadline'] = shiftDate(deadline, from, next);
  // A start date moves the same way; evening stays on the series.
  final start = series['start'];
  if (start is String && start.isNotEmpty && start != 'someday') out['start'] = shiftDate(start, from, next);
  return out;
}

/// Fields an occurrence record inherits from its series, on the occurrence date [date].
Map<String, Object?> recordFields(Row series, String date, int now, String today) {
  final labels = series['labels'];
  final fields = series['fields'];
  return {
    'title': series['title'] ?? '',
    'description': series['description'] ?? '',
    'project_id': series['project_id'],
    'parent_id': series['parent_id'],
    'priority': series['priority'] ?? 4,
    'labels': labels is List ? List<Object?>.of(labels) : <Object?>[],
    'position': series['position'] ?? 0,
    'created_at': now,
    'deleted_at': null,
    'estimate_minutes': series['estimate_minutes'],
    'recurrence': null,
    'series_id': series['id'],
    ...moveDates(series, date, today),
    'occurrence_date': date,
    'completed_at': null,
    'skipped': false,
    // Only sent when set, as web.
    if (_set(series['section_id'])) 'section_id': series['section_id'],
    if (series['start'] == 'someday') 'start': 'someday',
    if (series['evening'] == true) 'evening': true,
    if (series['span'] == true) 'span': true,
    if (_set(series['day_part'])) 'day_part': series['day_part'],
    if (_set(series['energy'])) 'energy': series['energy'],
    if (_set(series['assignee_id'])) 'assignee_id': series['assignee_id'],
    if (_set(series['location'])) 'location': series['location'],
    if (fields is Map && fields.isNotEmpty) 'fields': Map<String, Object?>.of(fields.cast<String, Object?>()),
  };
}

/// [recordFields], except that a habit's record copies no note.
Map<String, Object?> occurrenceFields(Row series, String date, int now, String today) {
  final fields = recordFields(series, date, now, today);
  if (series['habit'] == true) fields.remove('description');
  return fields;
}

// ---- the current occurrence ----

/// The occurrence the series stands on for acting: its due date, or, when
/// another device's record made that date an exception, the next free date
/// after it. Null when no free date remains (the series is at its end).
String? currentOccurrence(Row series, Rule rule, Iterable<Row> tasks, String today) {
  final date = occurrenceDate(series, today);
  final b = seriesBudget(series['id'] as String, tasks);
  if (!b.except.contains(date) || rule.afterCompletion) return date;
  // The series needs one occurrence the records have not used up.
  return nextFree(rule, date, today, today, b.taken - 1, b.except);
}

/// The series as it stands on [date] (its dates moved there when a late
/// record moved it).
Row standOn(Row series, String date, String today) {
  if (date == occurrenceDate(series, today)) return series;
  return {...series, ...moveDates(series, date, today)};
}

/// The result of [planCompletion].
class CompletionPlan {
  /// True when the end condition is reached: no changes; the caller completes
  /// the series like a plain task (`completed_at`).
  final bool end;
  final List<Change> changes;

  /// The occurrence record written (`occurrenceId(series, date)`).
  final String? recordId;

  /// The series' next due date.
  final String? next;
  const CompletionPlan._(this.end, this.changes, this.recordId, this.next);
  static const CompletionPlan ended = CompletionPlan._(true, [], null, null);
}

/// Completing the series' current occurrence: the done occurrence record
/// (copy of the series, `recurrence` null, `series_id`, `occurrence_date`,
/// `completed_at` = [now]) and the series moved to the next occurrence that is
/// not an exception; or [CompletionPlan.ended]. [nextAssignee] passes a
/// rotation's turn (computed by the caller) on the series in the same batch.
CompletionPlan planCompletion(Row series, Iterable<Row> tasks, int now, String today, {String? nextAssignee}) {
  final rule = seriesRule(series);
  if (rule == null) throw ArgumentError('planCompletion: not an open recurring task');
  final list = tasks.toList();
  final date = currentOccurrence(series, rule, list, today);
  if (date == null) return CompletionPlan.ended;
  final at = standOn(series, date, today);
  final b = seriesBudget(series['id'] as String, list, date);
  final next = nextFree(rule, _dueDate(at), today, today, b.taken, b.except);
  if (next == null) return CompletionPlan.ended;
  final recordId = occurrenceId(series['id'] as String, date);
  final move = moveDates(at, next, today);
  if (nextAssignee != null && nextAssignee != series['assignee_id']) move['assignee_id'] = nextAssignee;
  return CompletionPlan._(false, [
    // A habit's full completion says it is not the tiny version.
    Change('task', recordId, {
      ...occurrenceFields(at, date, now, today),
      'completed_at': now,
      if (series['habit'] == true) 'tiny': false,
    }),
    Change('task', series['id'] as String, move),
  ], recordId, next);
}

/// Skips never count towards `for N times`.
const int _uncounted = -1;

/// The occurrence after the current one for skip: calendar rules use the
/// schedule, completion-relative rules count from today; exception dates are
/// jumped over. Null when it would pass `until`.
String? nextOnSkip(Row series, Rule rule, String today, [Iterable<Row> tasks = const []]) {
  final b = seriesBudget(series['id'] as String, tasks);
  return nextFree(rule, _dueDate(series), today, today, _uncounted, b.except);
}

/// Skipping the current occurrence moves the series on. For a habit it also
/// writes the occurrence record marked `skipped`, in the same batch. Null when
/// it cannot be skipped (the last occurrence: complete or delete it).
List<Change>? planSkip(Row series, int now, String today, [Iterable<Row> tasks = const []]) {
  final rule = seriesRule(series);
  if (rule == null) return null;
  final list = tasks.toList();
  final date = currentOccurrence(series, rule, list, today);
  if (date == null) return null;
  final at = standOn(series, date, today);
  final next = nextOnSkip(at, rule, today, list);
  if (next == null) return null;
  final move = Change('task', series['id'] as String, moveDates(at, next, today));
  if (series['habit'] != true) return [move];
  return [
    Change('task', occurrenceId(series['id'] as String, date), {
      ...occurrenceFields(at, date, now, today),
      'completed_at': now,
      'skipped': true,
    }),
    move,
  ];
}

// ---- acting on one occurrence ----

/// What to do with one occurrence.
sealed class OccurrenceAction {
  const OccurrenceAction();
}

/// Complete it (`tiny`: a habit logged as its tiny version).
class CompleteOccurrence extends OccurrenceAction {
  final bool tiny;
  const CompleteOccurrence({this.tiny = false});
}

class SkipOccurrence extends OccurrenceAction {
  const SkipOccurrence();
}

/// Move it to another due (`{'date', 'time'?, 'tz'?}`).
class MoveOccurrence extends OccurrenceAction {
  final Map<String, Object?> due;
  const MoveOccurrence(this.due);
}

/// Edit its fields alone.
class EditOccurrence extends OccurrenceAction {
  final Map<String, Object?> patch;
  const EditOccurrence(this.patch);
}

/// "This occurrence only": write its open record without a rule.
class DetachOccurrence extends OccurrenceAction {
  const DetachOccurrence();
}

/// The result of [planActOn].
class ActPlan {
  final List<Change> changes;
  final String recordId;

  /// The record existed before this action.
  final bool existed;

  /// The record's fields as an untouched open occurrence on its date: what an
  /// Undo goes back to.
  final Map<String, Object?> base;

  /// Completing the current occurrence reached the end condition: no changes;
  /// the caller completes the series like a plain task.
  final bool end;
  const ActPlan(this.changes, this.recordId, this.existed, this.base, {this.end = false});
}

/// Fire instant (epoch ms) of a relative reminder [offsetMinutes] before or
/// after [due] (`{'date', 'time'?, 'tz'?}`); supplied by the reminder module.
typedef RelativeFireAt = int? Function(Map<String, Object?> due, int? offsetMinutes);

/// Whether [date] is an occurrence of the series the user can act on: the
/// current occurrence, a projected date (within the end condition, not an
/// exception), or a date with a record.
bool isActionable(Row series, Rule rule, String date, Iterable<Row> tasks, String today) {
  final list = tasks.toList();
  final current = currentOccurrence(series, rule, list, today);
  if (current == null || date.compareTo(current) < 0) return false;
  final id = series['id'] as String;
  final b = seriesBudget(id, list, current);
  if (b.except.contains(date) || date == current) return true;
  if (rule.afterCompletion) return false;
  return walkOccurrences(rule, current, today, b.taken, date, date, except: b.except).dates.contains(date);
}

/// Act on one occurrence ([date], or the current one when null): complete,
/// skip, move, edit or detach it alone. On the current occurrence the series
/// also moves to its next free date; on a later one only the record is written.
/// An existing record is updated in place. Moving, editing or detaching writes
/// an open record and copies the series' relative [reminders] onto it (fire_at
/// from [fireAt]). Null when the date cannot be acted on.
ActPlan? planActOn(
  Row series,
  String? date,
  OccurrenceAction action,
  Iterable<Row> tasks,
  int now,
  String today, {
  List<Row> reminders = const [],
  RelativeFireAt? fireAt,
  String? nextAssignee,
}) {
  final rule = seriesRule(series);
  if (rule == null) return null;
  final list = tasks.toList();
  final current = currentOccurrence(series, rule, list, today);
  if (current == null) return null;
  final on = date ?? current;
  if (!isActionable(series, rule, on, list, today)) return null;
  final id = series['id'] as String;
  final recordId = occurrenceId(id, on);
  final existing = list.any((t) => t['id'] == recordId && !_set(t['deleted_at']) && isRecordOf(id, t));
  final at = standOn(series, current, today);
  final base = occurrenceFields(at, on, now, today);
  final state = _statePatch(action, now);
  if (action is CompleteOccurrence && series['habit'] == true) state['tiny'] = action.tiny;
  if (existing) {
    if (action is DetachOccurrence) return null;
    return ActPlan([Change('task', recordId, state)], recordId, true, base);
  }
  if (on == current && (action is CompleteOccurrence || action is SkipOccurrence)) {
    if (action is CompleteOccurrence) {
      final plan = planCompletion(series, list, now, today, nextAssignee: nextAssignee);
      if (plan.end) return ActPlan(const [], recordId, false, base, end: true);
      if (action.tiny) plan.changes[0].patch['tiny'] = true;
      return ActPlan(plan.changes, recordId, false, base);
    }
    final skip = planSkip(series, now, today, list);
    return skip == null ? null : ActPlan(skip, recordId, false, base);
  }
  final changes = <Change>[
    Change('task', recordId, {...base, ...state}),
  ];
  if (on == current) {
    // The record uses up an occurrence: the series continues only within the budget.
    final b = seriesBudget(id, list, on);
    final next = nextFree(rule, on, today, today, b.taken, {...b.except, on});
    if (next == null) return null;
    changes.add(Change('task', id, moveDates(at, next, today)));
  }
  if (state['completed_at'] == null) {
    final due = (state['due'] as Map?)?.cast<String, Object?>() ?? (base['due'] as Map).cast<String, Object?>();
    changes.addAll(copyReminders(id, recordId, due, reminders, now, fireAt));
  }
  return ActPlan(changes, recordId, false, base);
}

/// "This occurrence only": the current occurrence's open record and the series
/// moved on to its next free occurrence. Null when there is none.
ActPlan? planDetach(Row series, int now, String today,
        [Iterable<Row> tasks = const [], List<Row> reminders = const [], RelativeFireAt? fireAt]) =>
    planActOn(series, null, const DetachOccurrence(), tasks, now, today, reminders: reminders, fireAt: fireAt);

Map<String, Object?> _statePatch(OccurrenceAction action, int now) => switch (action) {
      CompleteOccurrence() => {'completed_at': now, 'skipped': false},
      SkipOccurrence() => {'completed_at': now, 'skipped': true},
      MoveOccurrence(:final due) => {'due': due},
      EditOccurrence(:final patch) => {...patch},
      DetachOccurrence() => {},
    };

/// Copies of the series' relative reminders for a materialised occurrence: ids
/// derived from the record and the reminder so devices converge, fire_at from
/// the record's own due. Absolute and deadline reminders stay on the series.
List<Change> copyReminders(String seriesId, String recordId, Map<String, Object?> due, List<Row> reminders, int now,
    RelativeFireAt? fireAt) {
  final out = <Change>[];
  for (final r in reminders) {
    if (r['task_id'] != seriesId || _set(r['deleted_at']) || ((r['kind'] as String?) ?? 'relative') != 'relative') continue;
    if (fireAt == null) throw ArgumentError('copyReminders: relative reminders need fireAt');
    final offset = (r['offset_minutes'] as num?)?.toInt();
    out.add(Change('reminder', nameId('occurrence-reminder', '$recordId:${r['id']}'), {
      'task_id': recordId,
      'kind': 'relative',
      'offset_minutes': offset,
      'fire_at': fireAt(due, offset),
      'delivered_at': null,
      'dismissed_at': null,
      'created_at': now,
      'deleted_at': null,
    }));
  }
  return out;
}

// ---- repair ----

/// A series due on one of its exception dates (it rolled before this device
/// saw another device's record) moves to the next free occurrence; every
/// device computes the same value. When none is left the series completes as
/// at its end condition. Empty when nothing needs repair. Run after a pull for
/// every series whose rows or records it touched (not for a viewer's).
List<Change> planRepair(Row series, Iterable<Row> tasks, String today, int now) {
  final rule = seriesRule(series);
  final date = _dueDate(series);
  if (rule == null || rule.afterCompletion || date == null) return const [];
  final list = tasks.toList();
  final b = seriesBudget(series['id'] as String, list);
  if (!b.except.contains(date)) return const [];
  final next = currentOccurrence(series, rule, list, today);
  return [
    Change('task', series['id'] as String, next == null ? {'completed_at': now} : moveDates(series, next, today)),
  ];
}
