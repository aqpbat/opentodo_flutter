// Inbox membership (OpenSpec change inbox-means-unplaced, design D1, D2): a task
// is in the Inbox while it is open, live, not placed, and none of its parents is
// placed either: a subtask is part of its parent's plan, so it follows the parent
// out of the Inbox. Placed means a project or a schedule (a do-on date, a start
// date, past or future, Someday, or a time sector); a deadline, a reminder or a
// label alone does not place a task. Derived from synced fields only, so it needs
// no clock and converges with them.
//
// ported from web/src/lib/inbox.ts (Go twin: internal/inbox); both, and this file,
// run test/vectors/inbox.vectors.json.
//
// Rows are task maps shaped like opDefaults['task'] (lib/core/schema_generated.dart).
import 'local_day.dart';

/// Finds a task by id, to walk a subtask's parents; null when it is not known here.
typedef InboxParentOf = Map<String, dynamic>? Function(String id);

/// Parents deeper than this are not walked (a guard against a cycle in synced data).
const int _maxDepth = 64;

/// A do-on date, a start date, Someday or a time sector.
bool isScheduled(Map<String, dynamic> task) =>
    truthy(task['due']) || truthy(task['start']) || truthy(task['sector']);

/// A project or a schedule: the task has a place outside the Inbox.
bool isPlaced(Map<String, dynamic> task) => task['project_id'] != null || isScheduled(task);

/// Whether the task is in the Inbox. With [parentOf], a subtask is left out when
/// any parent it can find is placed (whether that parent is open, done or
/// deleted); a parent that is not found ends the walk.
bool isInboxTask(Map<String, dynamic> task, [InboxParentOf? parentOf]) {
  if (truthy(task['completed_at']) || truthy(task['deleted_at']) || isPlaced(task)) {
    return false;
  }
  var parent = task['parent_id'] as String?;
  for (
    var depth = 0;
    parent != null && parent.isNotEmpty && parentOf != null && depth < _maxDepth;
    depth++
  ) {
    final p = parentOf(parent);
    if (p == null) break;
    if (isPlaced(p)) return false;
    parent = p['parent_id'] as String?;
  }
  return true;
}

/// A parent lookup over [tasks] (each with an `id`) for [isInboxTask].
InboxParentOf inboxParents(Iterable<Map<String, dynamic>> tasks) {
  final byId = {for (final t in tasks) t['id'] as String: t};
  return (id) => byId[id];
}

/// The tasks of [tasks] that are in the Inbox; parents are looked up in [known]
/// (default: [tasks]). Keeps the input order.
List<Map<String, dynamic>> inboxTasks(
  List<Map<String, dynamic>> tasks, [
  Iterable<Map<String, dynamic>>? known,
]) {
  final parentOf = inboxParents(known ?? tasks);
  return tasks.where((t) => isInboxTask(t, parentOf)).toList();
}
