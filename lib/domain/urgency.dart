// The urgency score (OpenSpec change urgency-sort, design D2): one number per open
// task from its due day, deadline, priority, the tasks it blocks, its age, a
// running timer and the blocked, deferred and Someday terms. Derived, never
// stored; it reads no content, so it is the same on an encrypted account.
//
// ported from web/src/lib/urgency.ts (Go twin: internal/urgency); all run
// test/vectors/urgency.vectors.json.
import 'dependencies.dart';
import 'local_day.dart';

/// The component keys, in the order the parts are listed.
enum UrgencyKey { due, deadline, priority, blocks, age, timer, blocked, deferred, someday }

/// One component: its key, its rounded value and the number its label names
/// (days, tasks or the priority).
class UrgencyPart {
  const UrgencyPart(this.key, this.value, this.n);
  final UrgencyKey key;
  final double value;
  final int n;

  @override
  String toString() => 'UrgencyPart(${key.name}, $value, $n)';
}

class Urgency {
  const Urgency(this.score, this.parts);
  final double score;
  final List<UrgencyPart> parts;
}

/// What a task's score needs besides the task: the viewer's logical today and
/// zone, and the derived facts.
class UrgencyInput {
  const UrgencyInput({
    required this.today,
    required this.zone,
    this.dayStart = 0,
    this.blocks = 0,
    this.blocked = false,
    this.timer = false,
  });

  /// The logical today, `YYYY-MM-DD` (see [ViewerZone.logicalDay]).
  final String today;
  final ViewerZone zone;

  /// Minutes after midnight the day starts (user_prefs.day_start), 0 = midnight.
  final int dayStart;

  /// Open, live tasks waiting for this one (see [blocksCount]).
  final int blocks;

  /// The task waits for an open, live task (see blockedMap in dependencies.dart).
  final bool blocked;

  /// The viewer's running time entry is on this task.
  final bool timer;
}

const List<double> _priority = [0, 6, 3.9, 1.8, 0];

/// Two decimals, a half away from zero (as Math.round on the magnitude).
double _round2(double x) => x.sign * ((x.abs() * 100) + 0.5).floorToDouble() / 100;

/// The proximity ramp: 1 a week or more late, 0.2 two weeks or more ahead,
/// linear between.
double ramp(int d) {
  if (d <= -7) return 1;
  if (d >= 14) return 0.2;
  return 0.2 + 0.8 * (14 - d) / 21;
}

/// The score of an open task, or null for a completed or deleted one.
Urgency? urgency(Map<String, dynamic> task, UrgencyInput x) {
  if (truthy(task['completed_at']) || truthy(task['deleted_at'])) return null;
  final parts = <UrgencyPart>[];
  void add(UrgencyKey key, double raw, int n) {
    final value = _round2(raw);
    if (value != 0 && value.isFinite) parts.add(UrgencyPart(key, value, n));
  }

  final due = x.zone.localDate(task['due']);
  if (due != null) {
    final d = daysBetweenIso(x.today, due);
    add(UrgencyKey.due, 12 * ramp(d), d);
  }
  final deadline = task['deadline'];
  if (deadline is String && deadline.isNotEmpty) {
    final d = daysBetweenIso(x.today, deadline);
    add(UrgencyKey.deadline, 8 * ramp(d), d);
  }
  final p = task['priority'];
  final priority = p is num ? p.toInt() : 0;
  add(
    UrgencyKey.priority,
    priority >= 0 && priority < _priority.length ? _priority[priority] : 0,
    priority,
  );
  if (x.blocks > 0) add(UrgencyKey.blocks, 8, x.blocks);
  final created = task['created_at'];
  final createdMs = created is num ? created.toInt() : 0;
  final rawAge = daysBetweenIso(x.zone.logicalDay(createdMs, x.dayStart), x.today);
  final age = rawAge < 0 ? 0 : rawAge;
  add(UrgencyKey.age, 2 * (age < 365 ? age : 365) / 365, age);
  if (x.timer) add(UrgencyKey.timer, 4, 0);
  if (x.blocked) add(UrgencyKey.blocked, -5, 0);
  final start = task['start'];
  if (start == 'someday') {
    add(UrgencyKey.someday, -6, 0);
  } else if (start is String && start.isNotEmpty && start.compareTo(x.today) > 0) {
    add(UrgencyKey.deferred, -3, daysBetweenIso(x.today, start));
  }
  var sum = 0.0;
  for (final part in parts) {
    sum += part.value;
  }
  return Urgency(_round2(sum), parts);
}

/// Open, live tasks waiting for each task, by id (a task blocking only closed or
/// deleted ones blocks nothing).
Map<String, int> blocksCount(Iterable<Map<String, dynamic>> tasks) {
  final out = <String, int>{};
  for (final t in tasks) {
    final b = t['blocked_by'];
    if (truthy(t['completed_at']) || truthy(t['deleted_at']) || b is! List || b.isEmpty) continue;
    for (final id in b.whereType<String>().toSet()) {
      if (id != t['id']) out[id] = (out[id] ?? 0) + 1;
    }
  }
  return out;
}

/// A task's urgency, null for a completed or deleted one.
typedef UrgencyOf = Urgency? Function(Map<String, dynamic> task);

/// The scorer of one task snapshot: the blocking facts are worked out once, on
/// the first score asked, and each row is scored once.
// ported from web/src/app/useUrgency.tsx urgencyOf
UrgencyOf urgencyOf(
  List<Map<String, dynamic>> tasks,
  String today,
  ViewerZone zone, {
  String? runningTaskId,
  int dayStart = 0,
}) {
  Map<String, int>? blocks;
  Map<String, int>? blocked;
  final cache = Map<Map<String, dynamic>, Urgency?>.identity();
  return (task) {
    if (cache.containsKey(task)) return cache[task];
    final bs = blocks ??= blocksCount(tasks);
    final bd = blocked ??= blockedMap(tasks);
    final id = task['id'] as String?;
    final u = urgency(
      task,
      UrgencyInput(
        today: today,
        zone: zone,
        dayStart: dayStart,
        blocks: bs[id] ?? 0,
        blocked: bd.containsKey(id),
        timer: runningTaskId != null && runningTaskId == id,
      ),
    );
    cache[task] = u;
    return u;
  };
}

/// The urgency order of a list (ascending = most urgent first, like a rank); a
/// task without a score (completed) comes last in either direction; ties by due,
/// priority, position and id.
// ported from web/src/lib/views.ts compareTasks, case 'urgency'
int Function(Map<String, dynamic>, Map<String, dynamic>) compareByUrgency(
  UrgencyOf of,
  ViewerZone zone, {
  bool descending = false,
}) {
  final sign = descending ? -1 : 1;
  int fallback(Map<String, dynamic> a, Map<String, dynamic> b) {
    final c = zone.compareDue(a['due'], b['due']);
    if (c != 0) return c;
    final p = _num(a['priority']).compareTo(_num(b['priority']));
    if (p != 0) return p;
    final pos = _num(a['position']).compareTo(_num(b['position']));
    if (pos != 0) return pos;
    return ((a['id'] as String?) ?? '').compareTo((b['id'] as String?) ?? '');
  }

  return (a, b) {
    final x = of(a)?.score;
    final y = of(b)?.score;
    if (x == null || y == null) {
      final c = x != null ? -1 : (y != null ? 1 : 0);
      return c != 0 ? c : fallback(a, b);
    }
    final c = sign * y.compareTo(x);
    return c != 0 ? c : fallback(a, b);
  };
}

num _num(Object? v) => v is num ? v : 0;
