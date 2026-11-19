// Today as pure functions over task rows (opDefaults['task'] shape): which tasks
// Today lists, its groups (Earlier, the day, Morning/Afternoon/This Evening with
// day parts, Blocked), its order, Done today, and the optional closed list (the
// Today limit and its slots).
//
// ported from:
//   web/src/lib/views.ts       (isSomeday, isDeferred, isStarted, isActive,
//                               inToday, overdueInToday, inAnytime, inLater)
//   web/src/lib/dayParts.ts    (dayPartOf, dayPartFields, partOfTime, placedPart,
//                               dayPartsOn)
//   web/src/lib/dayLists.ts    (withoutArchived, today assignee filter, todayList,
//                               groupToday, earlierIds, completedOn)
//   web/src/lib/ordering.ts    (compareDueThenPriority)
//   web/src/lib/closedList.ts, closedListPrefs.ts (the closed list; shared vectors
//                               test/vectors/closedList.vectors.json)
//
// Every function that reads a due takes the viewer's [ViewerZone], so a zoned due
// (time + tz) is placed by the viewer's wall date and time, never the stored one.
// "today" is always the viewer's logical today (`YYYY-MM-DD`), passed in.
import 'dependencies.dart';
import 'local_day.dart';

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
num _num(Object? v) => v is num ? v : 0;

// ---- start dates, Someday and This Evening (views.ts) ----

/// Parked in Someday.
bool isSomeday(Map<String, dynamic> task) => task['start'] == 'someday';

/// Deferred: a start date still in the future.
bool isDeferred(Map<String, dynamic> task, String today) {
  final s = _str(task['start']);
  return s != null && s != 'someday' && s.compareTo(today) > 0;
}

/// Started: a start date that has come (the task stays in Today until handled).
bool isStarted(Map<String, dynamic> task, String today) {
  final s = _str(task['start']);
  return s != null && s != 'someday' && s.compareTo(today) <= 0;
}

/// Neither parked nor deferred: what the planning views and counts consider.
bool isActive(Map<String, dynamic> task, String today) =>
    !isSomeday(task) && !isDeferred(task, today);

/// The Later group of a project or Inbox view: deferred or parked.
bool inLater(Map<String, dynamic> task, String today) => isSomeday(task) || isDeferred(task, today);

/// A due date or deadline today or earlier: wins over deferral and parking.
bool _hardDate(Map<String, dynamic> task, String today, ViewerZone zone) {
  final due = zone.localDate(task['due']);
  final deadline = _str(task['deadline']);
  return (due != null && due.compareTo(today) <= 0) ||
      (deadline != null && deadline.compareTo(today) <= 0);
}

/// Today lists open tasks due today or earlier, whose deadline is today or past,
/// or whose start date has come. A hard date wins over deferral and Someday.
bool inToday(Map<String, dynamic> task, String today, ViewerZone zone) {
  if (truthy(task['completed_at'])) return false;
  return _hardDate(task, today, zone) || isStarted(task, today);
}

/// Within Today, the Earlier (overdue) group: due before today, or deadline
/// passed and not planned for today.
bool overdueInToday(Map<String, dynamic> task, String today, ViewerZone zone) {
  final due = zone.localDate(task['due']);
  final deadline = _str(task['deadline']);
  return (due != null && due.compareTo(today) < 0) ||
      (deadline != null && deadline.compareTo(today) < 0 && due != today);
}

/// Anytime: open, active tasks with no date of any kind and no start.
bool inAnytime(Map<String, dynamic> task, String today) =>
    !truthy(task['completed_at']) &&
    isActive(task, today) &&
    !truthy(task['due']) &&
    _str(task['deadline']) == null &&
    task['start'] == null &&
    !truthy(task['sector']);

// ---- day parts (dayParts.ts) ----

/// A part of the day; `null` stands for Any time.
enum DayPart { morning, afternoon, evening }

/// The part a task has: Evening when the flag is set, else its stored day_part;
/// an unknown value reads as none.
DayPart? dayPartOf(Map<String, dynamic> task) {
  if (truthy(task['evening'])) return DayPart.evening;
  return switch (task['day_part']) {
    'morning' => DayPart.morning,
    'afternoon' => DayPart.afternoon,
    _ => null,
  };
}

/// The fields that set [part] (null = Any time), always written together in one
/// batch: never `evening: true` with a day_part.
Map<String, dynamic> dayPartFields(DayPart? part) => part == DayPart.evening
    ? {'day_part': null, 'evening': true}
    : {'day_part': part?.name, 'evening': false};

/// The part of a wall-clock time `HH:MM`: before 12:00 Morning, 12:00-17:59
/// Afternoon, from 18:00 Evening.
DayPart partOfTime(String time) {
  if (time.compareTo('12:00') < 0) return DayPart.morning;
  return time.compareTo('18:00') < 0 ? DayPart.afternoon : DayPart.evening;
}

/// Where Today places a task while day parts are on: its part, else the part of
/// its due time in the viewer's zone, else none (the Today group).
DayPart? placedPart(Map<String, dynamic> task, ViewerZone zone) {
  final own = dayPartOf(task);
  if (own != null) return own;
  final time = zone.localTime(task['due']);
  return time != null ? partOfTime(time) : null;
}

/// Whether the account groups Today by part of the day (user_prefs.day_parts).
bool dayPartsOn(Map<String, dynamic>? prefs) => prefs?['day_parts'] == 'on';

// ---- order (ordering.ts) ----

/// Date-sorted views (Today, Upcoming): due date and time in the viewer's zone,
/// then priority, then position, then id.
int compareDueThenPriority(Map<String, dynamic> a, Map<String, dynamic> b, ViewerZone zone) {
  final d = zone.compareDue(a['due'], b['due']);
  if (d != 0) return d;
  final p = _num(a['priority']).compareTo(_num(b['priority']));
  if (p != 0) return p;
  final pos = _num(a['position']).compareTo(_num(b['position']));
  if (pos != 0) return pos;
  return ((a['id'] as String?) ?? '').compareTo((b['id'] as String?) ?? '');
}

// ---- the lists (dayLists.ts) ----

/// The tasks the cross-project views consider: tasks of archived projects stay
/// out, except in the archived project's own list ([keepProject]), and graduated
/// habits stay out of every list.
List<Map<String, dynamic>> withoutArchived(
  List<Map<String, dynamic>> tasks,
  Iterable<Map<String, dynamic>> projects, [
  String? keepProject,
]) {
  final hidden = {
    for (final p in projects)
      if (truthy(p['archived'])) p['id'] as String,
  };
  return tasks.where((t) {
    if (t['habit_graduated_at'] != null) return false;
    final pid = _str(t['project_id']);
    return pid == null || !hidden.contains(pid) || pid == keepProject;
  }).toList();
}

/// Today hides tasks assigned to others only when the account stored `mine`.
/// [shared] is every project the membership cache knows; a project missing from
/// that cache is treated as not shared.
class TodayAssigneeFilter {
  const TodayAssigneeFilter(this.shared, this.me);
  final Set<String> shared;
  final String? me;
}

/// The hide to apply, or null while the option is off (user_prefs.today_assignees
/// is anything but `mine`). [sharedProjectIds] are the projects of the
/// membership cache.
TodayAssigneeFilter? todayAssigneeFilter(
  Map<String, dynamic>? prefs,
  Iterable<String> sharedProjectIds,
  String? me,
) {
  if (prefs?['today_assignees'] != 'mine') return null;
  return TodayAssigneeFilter(sharedProjectIds.toSet(), me);
}

/// A task Today drops: a known shared project, assigned, and the assignee is not
/// the viewer. Unassigned stays.
bool assignedToSomeoneElse(Map<String, dynamic> task, TodayAssigneeFilter? filter) {
  final pid = _str(task['project_id']);
  if (filter == null || !truthy(filter.me) || pid == null || !filter.shared.contains(pid)) {
    return false;
  }
  final assignee = _str(task['assignee_id']);
  return assignee != null && assignee != filter.me;
}

/// Today: open tasks due today or earlier (or deadline / start reached), by due
/// then priority. [hide] drops other people's shared tasks.
List<Map<String, dynamic>> todayList(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone, [
  TodayAssigneeFilter? hide,
]) {
  return stableSorted(
    tasks.where((t) => inToday(t, today, zone) && !assignedToSomeoneElse(t, hide)),
    (a, b) => compareDueThenPriority(a, b, zone),
  );
}

/// Today's list split into its groups.
class TodayGroups {
  const TodayGroups({
    required this.overdue,
    required this.day,
    required this.morning,
    required this.afternoon,
    required this.evening,
    required this.blocked,
  });

  /// Earlier: due before today, or a passed deadline.
  final List<Map<String, dynamic>> overdue;

  /// Today's tasks that are not in the evening (with day parts on: no part and
  /// no due time).
  final List<Map<String, dynamic>> day;

  /// Morning and Afternoon: empty unless day parts are on.
  final List<Map<String, dynamic>> morning;
  final List<Map<String, dynamic>> afternoon;

  /// This Evening (with day parts on also an untagged task due from 18:00).
  final List<Map<String, dynamic>> evening;

  /// Blocked tasks, kept apart at the end.
  final List<Map<String, dynamic>> blocked;
}

/// Splits Today's list (already sorted) into Earlier, the day, This Evening and
/// Blocked. With [parts] (day parts on) the day is split further into Morning
/// and Afternoon, a task without a part placed by its due time. [blocked] holds
/// the ids of blocked tasks (see blockedMap).
TodayGroups groupToday(
  List<Map<String, dynamic>> list,
  String today,
  ViewerZone zone, {
  Set<String> blocked = const {},
  bool parts = false,
}) {
  bool isBlocked(Map<String, dynamic> t) => blocked.contains(t['id']);
  final waiting = list.where(isBlocked).toList();
  final ready = list.where((t) => !isBlocked(t)).toList();
  final overdue = ready.where((t) => overdueInToday(t, today, zone)).toList();
  final rest = ready.where((t) => !overdueInToday(t, today, zone)).toList();
  if (!parts) {
    return TodayGroups(
      overdue: overdue,
      day: rest.where((t) => !truthy(t['evening'])).toList(),
      morning: const [],
      afternoon: const [],
      evening: rest.where((t) => truthy(t['evening'])).toList(),
      blocked: waiting,
    );
  }
  final of = [for (final t in rest) placedPart(t, zone)];
  List<Map<String, dynamic>> where(DayPart? part) => [
    for (var i = 0; i < rest.length; i++)
      if (of[i] == part) rest[i],
  ];
  return TodayGroups(
    overdue: overdue,
    day: where(null),
    morning: where(DayPart.morning),
    afternoon: where(DayPart.afternoon),
    evening: where(DayPart.evening),
    blocked: waiting,
  );
}

/// The ids of Today's Earlier group as the list shows it: open tasks of active
/// projects due (or with a deadline) before today, blocked ones left out.
List<String> earlierIds(
  List<Map<String, dynamic>> tasks,
  Iterable<Map<String, dynamic>> projects,
  String today,
  ViewerZone zone, [
  TodayAssigneeFilter? hide,
]) {
  final live = withoutArchived(tasks.where((t) => !truthy(t['deleted_at'])).toList(), projects);
  final blocked = blockedMap(live).keys.toSet();
  return groupToday(
    todayList(live, today, zone, hide),
    today,
    zone,
    blocked: blocked,
  ).overdue.map((t) => t['id'] as String).toList();
}

/// Tasks completed on the logical day [today], most recent first; a habit's
/// skipped record is not a completion.
List<Map<String, dynamic>> completedOn(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone, {
  int dayStart = 0,
}) {
  return stableSorted(
    tasks.where((t) {
      final c = t['completed_at'];
      return c is num &&
          !truthy(t['deleted_at']) &&
          !truthy(t['skipped']) &&
          zone.logicalDay(c.toInt(), dayStart) == today;
    }),
    (a, b) => _num(b['completed_at']).compareTo(_num(a['completed_at'])),
  );
}

// ---- the closed list (closedList.ts, closedListPrefs.ts) ----

/// The largest limit (and the most ids a taken list keeps).
const int todayLimitMax = 20;

/// The limit choices of Settings (Custom takes any whole number from 1 to 20).
const List<int> todayLimitChoices = [3, 5, 7, 10];

/// The limit as stored: 0 (off) for a missing, non-integer or out-of-range value.
int readTodayLimit(Object? raw) {
  if (raw is int) return raw >= 1 && raw <= todayLimitMax ? raw : 0;
  if (raw is double && raw.isFinite && raw == raw.roundToDouble()) {
    return raw >= 1 && raw <= todayLimitMax ? raw.toInt() : 0;
  }
  return 0;
}

/// The account's limit (user_prefs.today_limit), 0 when off.
int todayLimitOf(Map<String, dynamic>? prefs) => readTodayLimit(prefs?['today_limit']);

/// A comma-separated id list of [date], or none when it was chosen on another day.
List<String> _idsOf(Object? list, Object? date, String today) {
  if (list is! String || list.isEmpty || date != today) return const [];
  return list.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
}

/// The ids let in with Take a slot today, in the order taken (another day's
/// list reads as empty). [review] is the review row.
List<String> takenSlots(Map<String, dynamic>? review, String today) =>
    _idsOf(review?['slots'], review?['slots_date'], today);

/// One of Today's open tasks as the slot rule reads it.
class SlotTask {
  const SlotTask({
    required this.id,
    required this.createdAt,
    this.earlier = false,
    this.due,
    this.habit = false,
    this.blocked = false,
    this.time,
    this.deadline,
  });

  final String id;
  final num createdAt;

  /// In Today's Earlier group (overdue, or a passed deadline).
  final bool earlier;

  /// The date Earlier sorts by (the due date, else the deadline), YYYY-MM-DD.
  final String? due;

  /// A habit never takes a slot.
  final bool habit;

  /// Blocked by an open task: the fallback availability rule.
  final bool blocked;

  /// The due time in the viewer's zone, HH:MM, when the task has a due date.
  final String? time;

  /// The deadline, YYYY-MM-DD.
  final String? deadline;
}

/// The result of [fillSlots].
class SlotFill {
  const SlotFill({
    required this.limit,
    required this.slots,
    required this.waiting,
    required this.chosen,
  });

  /// 0 when the limit is off.
  final int limit;

  /// The tasks in the slots, in fill order.
  final List<String> slots;

  /// The tasks waiting for a slot, in fill order (the first comes in next).
  final List<String> waiting;

  /// How many slots hold a focus or taken task (Take a slot is refused when it
  /// equals the limit).
  final int chosen;
}

/// The fallback availability rule: available means not blocked.
bool notBlocked(SlotTask t) => !t.blocked;

int _byCreation(SlotTask a, SlotTask b) {
  final c = a.createdAt.compareTo(b.createdAt);
  return c != 0 ? c : a.id.compareTo(b.id);
}

int _byDue(SlotTask a, SlotTask b) {
  final c = (a.due ?? '').compareTo(b.due ?? '');
  return c != 0 ? c : _byCreation(a, b);
}

/// Fills Today's slots: today's focus, then the taken tasks in the order taken,
/// then Earlier oldest due first, then the rest oldest created first, ties by
/// id. Only available tasks count; habits never do. With the limit off every
/// counted task is in the slots and none waits. [review] is the review row
/// (focus, focus_date, slots, slots_date).
SlotFill fillSlots({
  required List<SlotTask> tasks,
  required Object? limit,
  required String today,
  Map<String, dynamic>? review,
  bool Function(SlotTask) available = notBlocked,
}) {
  final lim = readTodayLimit(limit);
  final counted = tasks.where((t) => !t.habit && available(t)).toList();
  final byId = {for (final t in counted) t.id: t};
  final order = <String>[];
  final seen = <String>{};
  void push(String id) {
    if (byId.containsKey(id) && seen.add(id)) order.add(id);
  }

  _idsOf(review?['focus'], review?['focus_date'], today).forEach(push);
  _idsOf(review?['slots'], review?['slots_date'], today).forEach(push);
  final chosen = order.length;
  stableSorted(
    counted.where((t) => t.earlier && !seen.contains(t.id)),
    _byDue,
  ).forEach((t) => push(t.id));
  stableSorted(counted.where((t) => !seen.contains(t.id)), _byCreation).forEach((t) => push(t.id));
  if (lim == 0) return SlotFill(limit: 0, slots: order, waiting: const [], chosen: 0);
  return SlotFill(
    limit: lim,
    slots: order.take(lim).toList(),
    waiting: order.skip(lim).toList(),
    chosen: chosen < lim ? chosen : lim,
  );
}

/// The taken list after Take a slot for [id], or null when every slot already
/// holds a focus or taken task ('full'). Ids that no longer count are dropped;
/// at most twenty.
List<String>? takeSlotList(SlotFill fill, List<String> taken, String id) {
  if (fill.limit > 0 && fill.chosen >= fill.limit) return null;
  final live = {...fill.slots, ...fill.waiting};
  final next = [...taken.where((x) => x != id && live.contains(x)), id];
  return next.length > todayLimitMax ? next.sublist(next.length - todayLimitMax) : next;
}

/// The taken list after Give back the slot for [id].
List<String> giveBackSlotList(List<String> taken, String id) =>
    taken.where((x) => x != id).toList();

/// The review-row fields Take a slot writes (one op on review `me`), or null
/// when the slots are full and nothing is written.
Map<String, dynamic>? takeSlotFields(
  Map<String, dynamic>? review,
  String today,
  SlotFill fill,
  String id,
) {
  final next = takeSlotList(fill, takenSlots(review, today), id);
  return next == null ? null : {'slots_date': today, 'slots': next.join(',')};
}

/// The review-row fields Give back the slot writes.
Map<String, dynamic> giveBackSlotFields(Map<String, dynamic>? review, String today, String id) => {
  'slots_date': today,
  'slots': giveBackSlotList(takenSlots(review, today), id).join(','),
};

/// A waiting task that has a time today: its due time, or null for a deadline
/// today without one; [passed] once that time is before now.
class TimeSensitive {
  const TimeSensitive(this.id, this.time, this.passed);
  final String id;
  final String? time;
  final bool passed;
}

/// The waiting tasks that are time-sensitive: due today with a time, or with a
/// deadline today. Soonest first: by time, then the deadlines without a time,
/// ties in fill order. [waiting] is in fill order. [now] is the wall time of the
/// logical today (`HH:MM`, past 24:00 after midnight before the day start, see
/// [waitingNow]); a task whose time is before it is passed.
List<TimeSensitive> timeSensitive(List<SlotTask> waiting, String today, [String? now]) {
  final out = <(TimeSensitive, int)>[];
  for (final (at, t) in waiting.indexed) {
    final timed = t.due == today && truthy(t.time) ? t.time : null;
    if (timed != null || t.deadline == today) {
      final passed = timed != null && truthy(now) && timed.compareTo(now!) < 0;
      out.add((TimeSensitive(t.id, timed, passed), at));
    }
  }
  String key(TimeSensitive x) => x.time ?? '24:00';
  out.sort((a, b) {
    final c = key(a.$1).compareTo(key(b.$1));
    return c != 0 ? c : a.$2 - b.$2;
  });
  return [for (final e in out) e.$1];
}

/// The one the folded heading names: the first whose time has not passed.
TimeSensitive? nextWaiting(List<TimeSensitive> soon) {
  for (final x in soon) {
    if (!x.passed) return x;
  }
  return null;
}

/// Now as [timeSensitive] reads it: the wall time `HH:MM` of the logical today,
/// with 24 hours added after midnight before the day start. [hour] and [minute]
/// are the viewer's wall clock; [calendarDay] its calendar date.
String waitingNow(int hour, int minute, String logicalDay, String calendarDay) {
  final h = hour + (logicalDay.compareTo(calendarDay) < 0 ? 24 : 0);
  return '${h.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// [timeSensitive] over Today's waiting task rows in fill order, with each task
/// and its due time in the viewer's zone (null for a deadline today without one).
List<({Map<String, dynamic> task, String? time, bool passed})> waitingTimeSensitive(
  List<Map<String, dynamic>> waiting,
  String today,
  ViewerZone zone, [
  String? now,
]) {
  final byId = {for (final t in waiting) t['id'] as String: t};
  final rows = [
    for (final t in waiting)
      SlotTask(
        id: t['id'] as String,
        createdAt: _num(t['created_at']),
        due: zone.localDate(t['due']) ?? _str(t['deadline']),
        time: zone.localTime(t['due']),
        deadline: _str(t['deadline']),
      ),
  ];
  return [
    for (final x in timeSensitive(rows, today, now))
      (task: byId[x.id]!, time: x.time, passed: x.passed),
  ];
}

/// One of Today's task rows as the slot rule reads it.
SlotTask slotTaskOf(
  Map<String, dynamic> task,
  String today,
  ViewerZone zone,
  Set<String> blocked,
) => SlotTask(
  id: task['id'] as String,
  createdAt: _num(task['created_at']),
  earlier: overdueInToday(task, today, zone),
  due: zone.localDate(task['due']) ?? _str(task['deadline']),
  habit: truthy(task['habit']),
  blocked: blocked.contains(task['id']),
);

/// Today's slots from its open task rows: [unavailable] holds the ids that never
/// count (blocked, or held in sequence by a project flow).
SlotFill todaySlots(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone,
  Map<String, dynamic>? prefs,
  Map<String, dynamic>? review,
  Set<String> unavailable,
) {
  return fillSlots(
    tasks: [for (final t in tasks) slotTaskOf(t, today, zone, unavailable)],
    limit: prefs?['today_limit'],
    today: today,
    review: review,
  );
}
