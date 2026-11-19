// What `blocked`, `unblocked` and `available` read: open blockers per task and
// the project/subtask flow. Pure functions over materialised task rows
// (Map shapes per opDefaults in lib/core/schema_generated.dart).
// ported from web/src/lib/dependencies.ts (blockedMap, brokenEdges) and
// web/src/lib/flow.ts (FlowState.available); the Go twins are the server's
// internal/filter isBlocked and internal/flow.

typedef Row = Map<String, Object?>;

/// JavaScript truthiness of a row value: null, false, 0 and '' are false.
bool truthy(Object? v) => !(v == null || v == false || v == 0 || v == '');

String? strOf(Row r, String field) {
  final v = r[field];
  return v is String ? v : null;
}

List<String> blockersOf(Row t) => [
      for (final b in (t['blocked_by'] as List?) ?? const []) b as String,
    ];

bool _isOpen(Row? t) => t != null && !truthy(t['deleted_at']) && !truthy(t['completed_at']);

String _edgeKey(String from, String to) => '$from\u0000$to';

/// The blocked_by clock of a row, from its optional `_clock` map ({field: {ts, device}}).
(num, String) _clockOf(Row t) {
  final clock = t['_clock'];
  final c = clock is Map ? clock['blocked_by'] : null;
  if (c is! Map) return (0, '');
  return ((c['ts'] as num?) ?? 0, (c['device'] as String?) ?? '');
}

bool _newer(Row a, Row b) {
  final (at, ad) = _clockOf(a);
  final (bt, bd) = _clockOf(b);
  if (at != bt) return at > bt;
  if (ad != bd) return ad.compareTo(bd) > 0;
  return (a['id'] as String).compareTo(b['id'] as String) > 0;
}

/// The edges a local cycle breaks: within every cycle, the outgoing edges of the
/// member whose blocked_by clock is newest, repeated until no cycle is left.
Set<String> brokenEdges(List<Row> tasks) {
  final byId = {for (final t in tasks) t['id'] as String: t};
  final broken = <String>{};
  List<String> out(String id) {
    final t = byId[id];
    if (t == null) return const [];
    return blockersOf(t).where((b) => byId.containsKey(b) && !broken.contains(_edgeKey(id, b))).toList();
  }

  for (;;) {
    final ids = byId.keys.toList()..sort();
    final sccs = _stronglyConnected(ids, out).where((c) => c.length > 1).toList();
    if (sccs.isEmpty) return broken;
    for (final scc in sccs) {
      final members = scc.toSet();
      var loser = byId[scc[0]]!;
      for (final id in scc.skip(1)) {
        if (_newer(byId[id]!, loser)) loser = byId[id]!;
      }
      for (final b in out(loser['id'] as String)) {
        if (members.contains(b)) broken.add(_edgeKey(loser['id'] as String, b));
      }
    }
  }
}

/// Tarjan's strongly connected components over ids and an edge function.
List<List<String>> _stronglyConnected(List<String> ids, List<String> Function(String) edges) {
  var index = 0;
  final idx = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final on = <String>{};
  final out = <List<String>>[];
  void visit(String v) {
    idx[v] = index;
    low[v] = index++;
    stack.add(v);
    on.add(v);
    for (final w in edges(v)) {
      if (!idx.containsKey(w)) {
        visit(w);
        low[v] = low[v]! < low[w]! ? low[v]! : low[w]!;
      } else if (on.contains(w)) {
        low[v] = low[v]! < idx[w]! ? low[v]! : idx[w]!;
      }
    }
    if (low[v] == idx[v]) {
      final scc = <String>[];
      String w;
      do {
        w = stack.removeLast();
        on.remove(w);
        scc.add(w);
      } while (w != v);
      out.add(scc);
    }
  }

  for (final id in ids) {
    if (!idx.containsKey(id)) visit(id);
  }
  return out;
}

/// Open blockers per task (tasks without any are left out). Completed, deleted
/// and unknown blockers never block; a cycle is broken as [brokenEdges] says.
Map<String, int> blockedMap(List<Row> tasks) {
  final out = <String, int>{};
  if (!tasks.any((t) => blockersOf(t).isNotEmpty)) return out;
  final byId = {for (final t in tasks) t['id'] as String: t};
  final broken = brokenEdges(tasks);
  for (final t in tasks) {
    final blockers = blockersOf(t);
    if (blockers.isEmpty || truthy(t['completed_at']) || truthy(t['deleted_at'])) continue;
    final id = t['id'] as String;
    final n = blockers.where((b) => _isOpen(byId[b]) && !broken.contains(_edgeKey(id, b))).length;
    if (n > 0) out[id] = n;
  }
  return out;
}

// ---- flow (ported from web/src/lib/flow.ts) ----

int compareByPosition(Row a, Row b) {
  final pa = (a['position'] as num?) ?? 0;
  final pb = (b['position'] as num?) ?? 0;
  if (pa != pb) return pa < pb ? -1 : 1;
  return (a['id'] as String).compareTo(b['id'] as String);
}

String _projectFlowOf(Row? p) {
  final v = p?['flow_mode'];
  return v == 'sequential' || v == 'area' ? v as String : 'parallel';
}

String _effectiveSectionFlow(Row s, String project) {
  final own = s['flow_mode'];
  if (own == 'parallel' || own == 'sequential') return own as String;
  return project == 'sequential' ? 'sequential' : 'parallel';
}

bool _taskSequential(Row? t) => t?['flow_mode'] == 'sequential';

/// Recurring tasks, habits and Someday never hold or wait in a sequence.
bool _skipped(Row t) => truthy(t['recurrence']) || truthy(t['habit']) || t['start'] == 'someday';

const int _maxDepth = 64;

/// The "available" rule (project-flow-modes, subtask-flow): live, open, not
/// blocked, not waiting in sequence, neither Someday nor deferred. Worked out
/// lazily per project, as FlowState in flow.ts.
class FlowState {
  FlowState({required this.tasks, required this.projects, required this.sections, required this.today})
      : _byId = {for (final t in tasks) t['id'] as String: t};

  final List<Row> tasks;
  final List<Row> projects;
  final List<Row> sections;

  /// The user's logical today, YYYY-MM-DD.
  final String today;
  final Map<String, Row> _byId;
  final Map<String, bool> _out = {};
  final Map<String, Map<String, String>> _holds = {};
  Map<String, List<Row>>? _topByProject;
  Map<String, String>? _firstSubtask;

  List<Row> _tops(String projectId) {
    _topByProject ??= () {
      final m = <String, List<Row>>{};
      for (final t in tasks) {
        final pid = strOf(t, 'project_id');
        if (!_isOpen(t) || truthy(t['parent_id']) || pid == null || pid.isEmpty) continue;
        (m[pid] ??= []).add(t);
      }
      return m;
    }();
    return _topByProject![projectId] ?? const [];
  }

  /// Every parent whose subtasks go one at a time, with its first open, not skipped subtask ('' for none).
  Map<String, String> _firsts() {
    if (_firstSubtask != null) return _firstSubtask!;
    final firsts = <String, String>{};
    final best = <String, Row>{};
    for (final t in tasks) {
      final parentId = strOf(t, 'parent_id');
      final p = parentId != null && parentId.isNotEmpty ? _byId[parentId] : null;
      if (p == null || !_taskSequential(p)) continue;
      final pid = p['id'] as String;
      firsts.putIfAbsent(pid, () => '');
      if (!_isOpen(t) || _skipped(t)) continue;
      final b = best[pid];
      if (b == null || compareByPosition(t, b) < 0) {
        best[pid] = t;
        firsts[pid] = t['id'] as String;
      }
    }
    return _firstSubtask = firsts;
  }

  /// The open top-level tasks of the project that wait in sequence, and what holds each.
  Map<String, String> _holdsIn(String projectId) {
    final known = _holds[projectId];
    if (known != null) return known;
    final holds = <String, String>{};
    _holds[projectId] = holds;
    final list = _tops(projectId);
    if (list.isEmpty) return holds;
    final flow = _projectFlowOf(projects.where((p) => p['id'] == projectId).firstOrNull);
    final byId = {for (final s in sections) s['id'] as String: s};
    final live = sections.where((s) => s['project_id'] == projectId && !truthy(s['deleted_at'])).toList()..sort(compareByPosition);
    String? sectionOf(Row t) {
      final sid = strOf(t, 'section_id');
      final s = sid != null && sid.isNotEmpty ? byId[sid] : null;
      return s != null && !truthy(s['deleted_at']) && s['project_id'] == projectId ? s['id'] as String : null;
    }

    List<Row> inSection(String id) => list.where((t) => sectionOf(t) == id).toList()..sort(compareByPosition);
    void oneByOne(List<Row> group) {
      final cand = group.where((t) => !_skipped(t)).toList();
      for (final t in cand.skip(1)) {
        holds[t['id'] as String] = 'task:${cand[0]['id']}';
      }
    }

    if (flow != 'sequential') {
      for (final s in live) {
        if (_effectiveSectionFlow(s, flow) == 'sequential') oneByOne(inSection(s['id'] as String));
      }
      return holds;
    }
    // Sequential: loose tasks are one step each, then each section is one step.
    final loose = list.where((t) => sectionOf(t) == null).toList()..sort(compareByPosition);
    final steps = <(String, List<Row>, Row?)>[
      for (final t in loose) ('task:${t['id']}', [t], null),
      for (final s in live) ('section:${s['id']}', inSection(s['id'] as String), s),
    ];
    String? current;
    for (final (held, stepTasks, section) in steps) {
      final cand = stepTasks.where((t) => !_skipped(t)).toList();
      if (current != null) {
        for (final t in cand) {
          holds[t['id'] as String] = current;
        }
        continue;
      }
      if (cand.isEmpty) continue;
      if (section != null && _effectiveSectionFlow(section, flow) == 'sequential') oneByOne(stepTasks);
      current = held;
    }
    return holds;
  }

  bool _compute(String id) {
    final t = _byId[id];
    if (t == null || !_isOpen(t)) return false;
    String? held;
    var top = t;
    for (var d = 0; truthy(top['parent_id']) && d < _maxDepth; d++) {
      final p = _byId[top['parent_id']];
      if (p == null) break;
      final first = held == null && _isOpen(top) && !_skipped(top) ? _firsts()[p['id']] : null;
      if (first != null && first != top['id']) held = 'task:$first';
      top = p;
    }
    final topProject = strOf(top, 'project_id');
    final heldBy = held ??
        (!truthy(top['parent_id']) && topProject != null && topProject.isNotEmpty && _isOpen(top)
            ? _holdsIn(topProject)[top['id']]
            : null);
    final blocked = blockersOf(t).any((b) => _isOpen(_byId[b]));
    final start = t['start'];
    final later = truthy(start) && start != 'someday' && (start as String).compareTo(today) > 0;
    return heldBy == null && !blocked && start != 'someday' && !later;
  }

  /// Whether the task is available now.
  bool available(String id) => _out[id] ??= _compute(id);
}
