// Upcoming as pure functions over task rows (opDefaults['task'] shape): which
// tasks it lists, the day each is listed under, its grouping by day, Start with
// Today, and the next days of a display.
//
// ported from:
//   web/src/lib/views.ts    (inUpcoming, deferredUnplaced, upcomingDate)
//   web/src/lib/span.ts     (spanOf)
//   web/src/lib/dayLists.ts (upcomingList, upcomingWithToday, groupUpcoming,
//                            nextDays)
import 'local_day.dart';
import 'today.dart';

final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// A task drawn across several days: its first day is `start`, its last day
/// `due.date`, [length] the number of days it covers (at least 2).
class Span {
  const Span(this.first, this.last, this.length);
  final String first;
  final String last;
  final int length;
}

/// The span a task is drawn as, or null: only when `span` is true, its start is
/// a date and its do-on date is later.
Span? spanOf(Map<String, dynamic> task) {
  if (!truthy(task['span'])) return null;
  final first = task['start'];
  final due = task['due'];
  final last = due is Map ? due['date'] : null;
  if (first is! String || last is! String) return null;
  if (!_isoDate.hasMatch(first) || !_isoDate.hasMatch(last) || first.compareTo(last) >= 0) {
    return null;
  }
  return Span(first, last, daysBetweenIso(first, last) + 1);
}

/// A deferred task without a project and without a do-on date: not an Inbox
/// task, so Upcoming lists it on its start date to keep it reachable.
bool deferredUnplaced(Map<String, dynamic> task, String today) =>
    !truthy(task['completed_at']) &&
    task['project_id'] == null &&
    !truthy(task['due']) &&
    isDeferred(task, today);

/// Upcoming lists open tasks due after today, undated ones whose deadline is
/// ahead, deferred unplaced tasks, and a span before its first day.
bool inUpcoming(Map<String, dynamic> task, String today, ViewerZone zone) {
  if (deferredUnplaced(task, today)) return true;
  // A span is listed once, under its first day, and only before it.
  if (spanOf(task) != null) return !truthy(task['completed_at']) && isDeferred(task, today);
  if (truthy(task['completed_at']) || !isActive(task, today)) return false;
  final due = zone.localDate(task['due']);
  if (due != null) return due.compareTo(today) > 0;
  final deadline = task['deadline'];
  return deadline is String && deadline.isNotEmpty && deadline.compareTo(today) > 0;
}

/// The Upcoming day a task is listed under: a span's first day, its due date
/// (viewer's zone), else its start date when deferred unplaced, else its deadline.
String? upcomingDate(Map<String, dynamic> task, ViewerZone zone, [String? today]) {
  final span = spanOf(task);
  if (span != null) return span.first;
  final due = zone.localDate(task['due']);
  if (due != null) return due;
  if (today != null && deferredUnplaced(task, today)) return task['start'] as String?;
  final deadline = task['deadline'];
  return deadline is String && deadline.isNotEmpty ? deadline : null;
}

/// Upcoming: open, active tasks due after today, and undated ones whose deadline
/// is ahead. Undated tasks sort after dated ones (due then priority).
List<Map<String, dynamic>> upcomingList(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone,
) {
  return stableSorted(
    tasks.where((t) => inUpcoming(t, today, zone)),
    (a, b) => compareDueThenPriority(a, b, zone),
  );
}

/// Upcoming with Start with Today: Today's list, then the Upcoming tasks Today
/// does not already hold, each task once. The assignee filter is not applied.
List<Map<String, dynamic>> upcomingWithToday(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone,
) {
  return [
    ...todayList(tasks, today, zone),
    ...upcomingList(tasks, today, zone).where((t) => !inToday(t, today, zone)),
  ];
}

/// One day of Upcoming and the tasks listed under it.
typedef UpcomingDay = ({String date, List<Map<String, dynamic>> tasks});

/// Upcoming's list (already sorted) bucketed by its day, in date order.
List<UpcomingDay> groupUpcoming(List<Map<String, dynamic>> list, ViewerZone zone, [String? today]) {
  final byDate = <String, List<Map<String, dynamic>>>{};
  for (final t in list) {
    final date = upcomingDate(t, zone, today);
    if (date == null || date.isEmpty) continue;
    (byDate[date] ??= []).add(t);
  }
  final dates = byDate.keys.toList()..sort();
  return [for (final d in dates) (date: d, tasks: byDate[d]!)];
}

/// The next [days] days after [today], each with the Upcoming tasks listed under
/// it (an empty list on a free day), for a display's columns.
List<UpcomingDay> nextDays(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone,
  int days,
) {
  final byDate = {
    for (final g in groupUpcoming(upcomingList(tasks, today, zone), zone, today)) g.date: g.tasks,
  };
  return [
    for (var i = 0; i < (days < 0 ? 0 : days); i++)
      (date: addDaysIso(today, i + 1), tasks: byDate[addDaysIso(today, i + 1)] ?? const []),
  ];
}
