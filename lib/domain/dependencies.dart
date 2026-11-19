// Task dependencies (OpenSpec change task-dependencies, design D2, D3): the pure
// "blocked" derivation over local task rows. A task's `blocked_by` lists the
// tasks it waits for; a blocker counts while it is live and open. Completed,
// deleted and unknown ids never block. A cycle that exists for a moment on a
// device is broken identically everywhere: in each cycle the member with the
// newest `blocked_by` clock stops blocking.
//
// ported from web/src/lib/dependencies.ts (blockersOf, brokenEdges, openBlockers,
// blockedMap). Only the derivation; writes belong to the data layer.
import 'local_day.dart';

/// The clock of a row's `blocked_by` field as (ts, device); (0, '') when unknown.
typedef BlockedByClock = ({int ts, String device}) Function(Map<String, dynamic> task);

/// Reads `_clock.blocked_by` `{ts, device}` from the row, the shape the web
/// client keeps; the data layer may pass its own [BlockedByClock].
({int ts, String device}) defaultBlockedByClock(Map<String, dynamic> task) {
  final c = task['_clock'];
  final f = c is Map ? c['blocked_by'] : null;
  if (f is Map) {
    final ts = f['ts'];
    final dev = f['device'];
    return (ts: ts is num ? ts.toInt() : 0, device: dev is String ? dev : '');
  }
  return (ts: 0, device: '');
}

/// The ids the task waits for.
List<String> blockersOf(Map<String, dynamic>? task) {
  final b = task?['blocked_by'];
  return b is List ? b.whereType<String>().toList() : const [];
}

bool _isOpen(Map<String, dynamic>? t) =>
    t != null && !truthy(t['deleted_at']) && !truthy(t['completed_at']);

String _edgeKey(String from, String to) => '$from\u0000$to';

/// The edges a local cycle breaks: within every cycle, the outgoing edges of the
/// member whose blocked_by clock is newest, until no cycle is left.
Set<String> brokenEdges(
  Iterable<Map<String, dynamic>> tasks, [
  BlockedByClock clockOf = defaultBlockedByClock,
]) {
  final byId = {for (final t in tasks) t['id'] as String: t};
  final broken = <String>{};
  bool newer(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ca = clockOf(a);
    final cb = clockOf(b);
    if (ca.ts != cb.ts) return ca.ts > cb.ts;
    if (ca.device != cb.device) return ca.device.compareTo(cb.device) > 0;
    return (a['id'] as String).compareTo(b['id'] as String) > 0;
  }

  List<String> out(String id) =>
      blockersOf(byId[id])
          .where((b) => byId.containsKey(b) && !broken.contains(_edgeKey(id, b)))
          .toList();
  final ids = byId.keys.toList()..sort();
  for (;;) {
    final sccs = _stronglyConnected(ids, out).where((c) => c.length > 1).toList();
    if (sccs.isEmpty) return broken;
    for (final scc in sccs) {
      final members = scc.toSet();
      var loser = byId[scc[0]]!;
      for (final id in scc.skip(1)) {
        if (newer(byId[id]!, loser)) loser = byId[id]!;
      }
      final lid = loser['id'] as String;
      for (final b in out(lid)) {
        if (members.contains(b)) broken.add(_edgeKey(lid, b));
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

/// The task's blockers that are live and open.
List<Map<String, dynamic>> openBlockers(
  Map<String, dynamic> task,
  Map<String, Map<String, dynamic>> byId, [
  Set<String> broken = const {},
]) {
  final id = task['id'] as String?;
  return [
    for (final b in blockersOf(task))
      if (_isOpen(byId[b]) && !broken.contains(_edgeKey(id ?? '', b))) byId[b]!,
  ];
}

/// Open blockers per open, live task (tasks without any are left out).
Map<String, int> blockedMap(
  List<Map<String, dynamic>> tasks, [
  BlockedByClock clockOf = defaultBlockedByClock,
]) {
  final out = <String, int>{};
  if (!tasks.any((t) => blockersOf(t).isNotEmpty)) return out;
  final byId = {for (final t in tasks) t['id'] as String: t};
  final broken = brokenEdges(tasks, clockOf);
  for (final t in tasks) {
    if (blockersOf(t).isEmpty || truthy(t['completed_at']) || truthy(t['deleted_at'])) continue;
    final n = openBlockers(t, byId, broken).length;
    if (n > 0) out[t['id'] as String] = n;
  }
  return out;
}
