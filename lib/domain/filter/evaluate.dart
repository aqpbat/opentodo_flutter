// Filter evaluation: compile a parsed query once into a predicate over local
// task rows. Pure; names are resolved against the labels and projects passed in
// on every compile, so renames are picked up and deleted names degrade to a
// warning plus an empty match instead of an error.
// ported from web/src/lib/filter/evaluate.ts (the Go twin is
// internal/filter/evaluate.go; both run filter/evaluate.vectors.json).
//
// Rows are materialised entity maps, shaped as opDefaults in
// lib/core/schema_generated.dart; a task's custom field values live in its
// `fields` map ({fieldId: value}).

import 'calendar.dart';
import 'parse.dart';
import 'task_graph.dart';

/// The epoch milliseconds of the wall-clock time `minutes` after midnight of
/// the floating date `isoDate` in the viewer's zone.
typedef DayInstant = int Function(String isoDate, int minutes);

/// The viewer-local calendar date of a due value ({date, time?, tz?}).
typedef LocalDueDate = String Function(Map<String, Object?> due);

/// [DayInstant] in the device's own time zone (the web client's behaviour).
int deviceDayInstant(String isoDate, int minutes) {
  final p = isoDate.split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2], minutes ~/ 60, minutes % 60).millisecondsSinceEpoch;
}

/// [DayInstant] in UTC (the server's default zone; tests).
int utcDayInstant(String isoDate, int minutes) {
  final p = isoDate.split('-').map(int.parse).toList();
  return DateTime.utc(p[0], p[1], p[2], minutes ~/ 60, minutes % 60).millisecondsSinceEpoch;
}

/// The stored date of a due. A zoned due (`tz` set) is read on its own date:
/// callers that can convert zones pass [FilterContext.localDue].
String storedDueDate(Map<String, Object?> due) => (due['date'] as String?) ?? '';

/// One person `assigned: name` can match.
class FilterMember {
  const FilterMember({required this.userId, required this.name, required this.email});
  factory FilterMember.fromJson(Map<String, Object?> m) =>
      FilterMember(userId: m['userId'] as String, name: (m['name'] as String?) ?? '', email: (m['email'] as String?) ?? '');
  final String userId;
  final String name;
  final String email;
}

/// Every workspace's tasks, projects and labels, for a query naming a workspace.
class FilterScope {
  const FilterScope({required this.tasks, required this.projects, required this.labels});
  final List<Row> tasks;
  final List<Row> projects;
  final List<Row> labels;
}

/// What a compile reads besides the task. "Now" and the zone are injected:
/// [today] is the viewer's logical day, [dayInstant] places days in a zone.
class FilterContext {
  const FilterContext({
    required this.today,
    this.labels = const [],
    this.projects = const [],
    this.tasks,
    this.sections,
    this.weekStart = 1,
    this.dayStartMinutes = 0,
    this.dayInstant = deviceDayInstant,
    this.localDue = storedDueDate,
    this.fields,
    this.tracked,
    this.trackedOccurrence,
    this.workspaces,
    this.workspaceOf,
    this.everyWorkspace,
    this.me,
    this.members,
  });

  /// The viewer's local (logical) calendar date, YYYY-MM-DD.
  final String today;
  final List<Row> labels;
  final List<Row> projects;

  /// Every live task, for `blocked`, `unblocked` and `available`.
  final List<Row>? tasks;

  /// Every live section, for the sequences of `available`.
  final List<Row>? sections;

  /// First day of the week for `this week` and friends, 0 = Sunday.
  final int weekStart;

  /// The user's day start (minutes after midnight) for created/completed days.
  final int dayStartMinutes;
  final DayInstant dayInstant;
  final LocalDueDate localDue;

  /// Custom field definitions for `name cmp value` and `no name`.
  final List<Row>? fields;

  /// Tracked minutes per task id (every entry), and per current occurrence.
  final Map<String, num>? tracked;
  final Map<String, num>? trackedOccurrence;

  /// The cached workspaces ({id, name}) and a task's workspace id, for `workspace:`.
  final List<Row>? workspaces;
  final String Function(Row task)? workspaceOf;
  final FilterScope? everyWorkspace;

  /// The viewer, for `assigned: me`.
  final String? me;
  final List<FilterMember>? members;

  FilterContext copyWith({List<Row>? tasks, List<Row>? projects, List<Row>? labels}) => FilterContext(
        today: today,
        labels: labels ?? this.labels,
        projects: projects ?? this.projects,
        tasks: tasks ?? this.tasks,
        sections: sections,
        weekStart: weekStart,
        dayStartMinutes: dayStartMinutes,
        dayInstant: dayInstant,
        localDue: localDue,
        fields: fields,
        tracked: tracked,
        trackedOccurrence: trackedOccurrence,
        workspaces: workspaces,
        workspaceOf: workspaceOf,
        everyWorkspace: everyWorkspace,
        me: me,
        members: members,
      );
}

/// The people a membership cache knows, one per account (rows with a `members` list).
List<FilterMember> membersFrom(Iterable<Map<String, Object?>> memberships) {
  final byId = <String, FilterMember>{};
  for (final m in memberships) {
    for (final member in (m['members'] as List?) ?? const []) {
      final f = FilterMember.fromJson((member as Map).cast<String, Object?>());
      byId.putIfAbsent(f.userId, () => f);
    }
  }
  return byId.values.toList();
}

typedef Pred = bool Function(Row task);

class CompiledFilter {
  const CompiledFilter(this.test, this.warnings);
  final Pred test;

  /// One message per unknown label, project, field, member or workspace, in query order.
  final List<String> warnings;
}

sealed class FilterResult {
  const FilterResult();
}

class FilterOk extends FilterResult {
  const FilterOk({required this.empty, required this.tasks, required this.warnings});
  final bool empty;
  final List<Row> tasks;
  final List<String> warnings;
}

class FilterError extends FilterResult {
  const FilterError({required this.error, required this.offset});
  final String error;
  final int offset;
  int get position => offset + 1;
}

bool _never(Row _) => false;

String nameKey(String name) => name.trim().toLowerCase();

/// `(query) & (open | completed)`: the query with completed tasks shown.
FilterNode withCompletedTasks(FilterNode ast) => AndNode([ast, parseFilter('open | completed')!]);

/// True when the query mentions `completed` or `open`, or compares the
/// completion date; otherwise only open tasks match.
bool mentionsState(FilterNode n) => switch (n) {
      OrNode(:final items) || AndNode(:final items) => items.any(mentionsState),
      NotNode(:final item) => mentionsState(item),
      KeywordNode(:final keyword) => keyword == 'completed' || keyword == 'open',
      DateNode(:final field) => field == 'completed',
      _ => false,
    };

/// True when the query has a `workspace:` term anywhere.
bool namesWorkspace(FilterNode n) => switch (n) {
      OrNode(:final items) || AndNode(:final items) => items.any(namesWorkspace),
      NotNode(:final item) => namesWorkspace(item),
      WorkspaceNode() => true,
      _ => false,
    };

/// Every workspace's rows when the query names a workspace and they were given, else `ctx`.
FilterContext filterScope(FilterNode ast, FilterContext ctx) {
  final every = ctx.everyWorkspace;
  if (every == null || !namesWorkspace(ast)) return ctx;
  return ctx.copyWith(tasks: every.tasks, projects: every.projects, labels: every.labels);
}

/// A day against a range of days; a one-day range is a plain comparison.
bool _compareIso(String d, Cmp op, DateRange r) => switch (op) {
      Cmp.lt => d.compareTo(r.start) < 0,
      Cmp.le => d.compareTo(r.end) <= 0,
      Cmp.eq => d.compareTo(r.start) >= 0 && d.compareTo(r.end) <= 0,
      Cmp.ge => d.compareTo(r.start) >= 0,
      Cmp.gt => d.compareTo(r.end) > 0,
    };

bool _cmpNum(num a, Cmp op, num b) => switch (op) {
      Cmp.lt => a < b,
      Cmp.le => a <= b,
      Cmp.eq => a == b,
      Cmp.ge => a >= b,
      Cmp.gt => a > b,
    };

Object? _fieldValue(Row task, String id) {
  final f = task['fields'];
  return f is Map ? f[id] : null;
}

/// The task's origin when it is a readable object with a kind.
Map<Object?, Object?>? originOf(Row task) {
  final o = task['origin'];
  return o is Map && o['kind'] is String ? o : null;
}

/// deep, medium or low; '' and unknown values read as none.
String? energyOf(Row task) {
  final v = task['energy'];
  return v == 'deep' || v == 'medium' || v == 'low' ? v as String : null;
}

/// Evening when the flag is set, else the stored day_part; unknown reads as none.
String? dayPartOf(Row task) {
  if (truthy(task['evening'])) return 'evening';
  final v = task['day_part'];
  return v == 'morning' || v == 'afternoon' ? v as String : null;
}

/// Compile an AST into a predicate. Deleted tasks never match; open-only unless the
/// query mentions state. Throws FilterSyntaxError for a field term its type cannot answer.
CompiledFilter compileFilter(FilterNode ast, FilterContext given) {
  final c = _Compiler(filterScope(ast, given));
  final pred = c.build(ast);
  final openOnly = !mentionsState(ast);
  // Skipped habit records match no query, whatever its terms.
  bool test(Row t) => openOnly
      ? !truthy(t['deleted_at']) && t['completed_at'] == null && pred(t)
      : !truthy(t['deleted_at']) && !truthy(t['skipped']) && pred(t);
  return CompiledFilter(test, c.warnings);
}

/// Parse and evaluate in one step; syntax errors are returned, not thrown.
FilterResult runFilter(String source, List<Row> tasks, FilterContext ctx) {
  try {
    final ast = parseFilter(source);
    if (ast == null) return const FilterOk(empty: true, tasks: [], warnings: []);
    final compiled = compileFilter(ast, ctx.tasks != null ? ctx : ctx.copyWith(tasks: tasks));
    final every = ctx.everyWorkspace;
    final scope = every != null && namesWorkspace(ast) ? every.tasks : tasks;
    return FilterOk(empty: false, tasks: scope.where(compiled.test).toList(), warnings: compiled.warnings);
  } on FilterSyntaxError catch (e) {
    return FilterError(error: e.message, offset: e.offset);
  }
}

class _Compiler {
  _Compiler(this.ctx)
      : today = ctx.today,
        weekStart = ctx.weekStart,
        tomorrow = shiftIso(ctx.today, 1) {
    for (final l in ctx.labels.where((l) => !truthy(l['deleted_at']))) {
      (labelsByName[nameKey(strOf(l, 'name') ?? '')] ??= []).add(l['id'] as String);
    }
    for (final p in liveProjects) {
      (projectsByName[nameKey(strOf(p, 'name') ?? '')] ??= []).add(p['id'] as String);
      final parent = strOf(p, 'parent_id');
      if (parent != null) (children[parent] ??= []).add(p['id'] as String);
      projectById[p['id'] as String] = p;
    }
    for (final d in ctx.fields ?? const <Row>[]) {
      if (!truthy(d['deleted_at'])) (fieldsByName[nameKey(strOf(d, 'name') ?? '')] ??= []).add(d);
    }
  }

  final FilterContext ctx;
  final String today;
  final int weekStart;
  final String tomorrow;
  final List<String> warnings = [];
  late final List<Row> liveProjects = ctx.projects.where((p) => !truthy(p['deleted_at'])).toList();
  final Map<String, List<String>> labelsByName = {};
  final Map<String, List<String>> projectsByName = {};
  final Map<String, List<String>> children = {};
  final Map<String, Row> projectById = {};
  final Map<String, List<Row>> fieldsByName = {};
  final Map<String, Set<String>> _chains = {};
  Map<String, int>? _blocked;
  FlowState? _flow;

  void warn(String msg) {
    if (!warnings.contains(msg)) warnings.add(msg);
  }

  /// The project and its live ancestors (cycle-safe), whose fields apply to its tasks.
  Set<String> _chain(String projectId) => _chains[projectId] ??= () {
        final chain = {projectId};
        var cur = projectById[projectId];
        while (cur != null) {
          final parent = strOf(cur, 'parent_id');
          final p = parent != null ? projectById[parent] : null;
          if (p == null || chain.contains(parent)) break;
          chain.add(parent!);
          cur = p;
        }
        return chain;
      }();

  /// Whether a field definition applies to the task's project (its own or an ancestor's).
  bool applies(Row task, Row def) {
    final pid = strOf(task, 'project_id');
    if (pid == null || pid.isEmpty) return false;
    return _chain(pid).contains(def['project_id']);
  }

  Map<String, int> blockedSet() => _blocked ??= () {
        if (ctx.tasks == null) warn('Blocked tasks cannot be told apart here');
        return blockedMap(ctx.tasks ?? const []);
      }();

  FlowState flowState() => _flow ??= () {
        if (ctx.tasks == null) warn('Blocked tasks cannot be told apart here');
        return FlowState(tasks: ctx.tasks ?? const [], projects: ctx.projects, sections: ctx.sections ?? const [], today: today);
      }();

  Map<String, num>? trackedOf(bool occurrence) => occurrence ? ctx.trackedOccurrence ?? ctx.tracked : ctx.tracked;

  String? dueDate(Row t) {
    final due = t['due'];
    return due is Map ? ctx.localDue(due.cast<String, Object?>()) : null;
  }

  int startOfDay(String iso) => ctx.dayInstant(iso, ctx.dayStartMinutes);

  Pred build(FilterNode n) {
    switch (n) {
      case OrNode(:final items):
        final ps = items.map(build).toList();
        return (t) => ps.any((p) => p(t));
      case AndNode(:final items):
        final ps = items.map(build).toList();
        return (t) => ps.every((p) => p(t));
      case NotNode(:final item):
        final p = build(item);
        return (t) => !p(t);
      case LabelNode(:final name):
        final ids = labelsByName[nameKey(name)];
        if (ids == null) {
          warn('No label named "$name"');
          return _never;
        }
        // Several labels may share a name after concurrent creation: any of them matches.
        final set = ids.toSet();
        return (t) => ((t['labels'] as List?) ?? const []).any(set.contains);
      case ProjectNode(:final name, :final descendants):
        final ids = projectsByName[nameKey(name)];
        if (ids == null) {
          warn('No project named "$name"');
          return _never;
        }
        final set = ids.toSet();
        if (descendants) {
          for (final id in ids) {
            set.addAll(_descendants(id));
          }
        }
        return (t) => t['project_id'] != null && set.contains(t['project_id']);
      case PriorityNode(:final value):
        return (t) => t['priority'] == value;
      case DateNode():
        return _datePred(n);
      case FieldNode():
        return _fieldTerm(n);
      case NoFieldNode(:final name):
        final defs = fieldsByName[nameKey(name)];
        if (defs == null) {
          warn('No field named "$name"');
          return _never;
        }
        return (t) => defs.any((d) {
              if (!applies(t, d)) return false;
              final v = _fieldValue(t, d['id'] as String);
              return v == null || v == '';
            });
      case SearchNode(:final text):
        final needle = text.toLowerCase();
        return (t) =>
            (strOf(t, 'title') ?? '').toLowerCase().contains(needle) ||
            (strOf(t, 'description') ?? '').toLowerCase().contains(needle);
      // The note is the task's description, never its title.
      case NotesNode(:final text):
        final needle = text.toLowerCase();
        return (t) => (strOf(t, 'description') ?? '').toLowerCase().contains(needle);
      case AssignedNode(:final name):
        return _assignedTo(name);
      case OriginNode(:final value):
        final want = value.toLowerCase();
        return (t) {
          final o = originOf(t);
          if (o == null) return false;
          return ((o['provider'] ?? o['kind']) as String).toLowerCase() == want;
        };
      // A relative word is the viewer's period of that name, on this evaluation's day.
      case SectorNode(:final value):
        final want = resolveSectorPhrase(value, today, weekStart) ?? value;
        return (t) => t['sector'] == want;
      case EnergyNode(:final value):
        return (t) => energyOf(t) == value;
      case WorkspaceNode(:final name):
        final ids = (ctx.workspaces ?? const <Row>[])
            .where((w) => nameKey(strOf(w, 'name') ?? '') == nameKey(name))
            .map((w) => w['id'])
            .toSet();
        final of = ctx.workspaceOf;
        if (ids.isEmpty || of == null) {
          warn('No workspace named "$name"');
          return _never;
        }
        return (t) => ids.contains(of(t));
      case TrackedNode(:final op, :final minutes, :final occurrence):
        final of = trackedOf(occurrence);
        return (t) => _cmpNum(of?[t['id']] ?? 0, op, minutes);
      case KeywordNode(:final keyword):
        return _keyword(keyword);
    }
  }

  /// The live projects below `id` at any depth (cycle-safe), as descendants in tree.ts.
  Set<String> _descendants(String id) {
    final out = <String>{};
    final stack = [id];
    while (stack.isNotEmpty) {
      for (final c in children[stack.removeLast()] ?? const <String>[]) {
        if (c == id || out.contains(c)) continue;
        out.add(c);
        stack.add(c);
      }
    }
    return out;
  }

  Pred _datePred(DateNode n) {
    final range = resolveRange(n.date, today, weekStart);
    final op = n.op;
    if (n.field == 'created' || n.field == 'completed') {
      final field = '${n.field}_at';
      final start = startOfDay(range.start);
      final next = startOfDay(shiftIso(range.end, 1));
      return (t) {
        final ms = t[field];
        if (ms is! num) return false;
        return switch (op) {
          Cmp.lt => ms < start,
          Cmp.le => ms < next,
          Cmp.eq => ms >= start && ms < next,
          Cmp.ge => ms >= start,
          Cmp.gt => ms >= next,
        };
      };
    }
    // A task without a deadline never matches a `deadline` comparison.
    if (n.field == 'deadline') {
      return (t) => truthy(t['deadline']) && _compareIso(t['deadline'] as String, op, range);
    }
    // Only a start date compares; null and Someday never match.
    if (n.field == 'start') {
      return (t) => truthy(t['start']) && t['start'] != 'someday' && _compareIso(t['start'] as String, op, range);
    }
    return (t) {
      final d = dueDate(t);
      return d != null && _compareIso(d, op, range);
    };
  }

  Pred _fieldTerm(FieldNode n) {
    final defs = fieldsByName[nameKey(n.name)];
    if (defs == null) {
      warn('No field named "${n.name}"');
      return _never;
    }
    // Several projects may define the name, with different types: the term uses
    // every definition it can answer, and fails only when none can.
    final ps = <Pred>[];
    FilterSyntaxError? first;
    for (final d in defs) {
      try {
        ps.add(_fieldPred(d, n));
      } on FilterSyntaxError catch (e) {
        first ??= e;
      }
    }
    if (ps.isEmpty) throw first!;
    return (t) => ps.any((p) => p(t));
  }

  /// One field term against one definition: numbers numerically, dates with the
  /// date grammar, text/link/choice with `=` ignoring case, checkboxes with `= true/false`.
  Pred _fieldPred(Row def, FieldNode n) {
    final at = n.opPos;
    final id = def['id'] as String;
    Object? value(Row t) => applies(t, def) ? _fieldValue(t, id) : null;
    final label = '"${n.name}"';
    final op = n.op;
    switch (def['type']) {
      case 'number':
        final v = n.value;
        if (v is! NumberValue) {
          throw FilterSyntaxError('Field $label holds numbers: compare it with a number at position ${at + 1}', at, ['number']);
        }
        return (t) {
          final x = value(t);
          return x is num && _cmpNum(x, op, v.value);
        };
      case 'date':
        final v = n.value;
        if (v is! DateValue) {
          throw FilterSyntaxError('Field $label holds dates: compare it with a date at position ${at + 1}', at, ['date']);
        }
        final range = resolveRange(v.date, today, weekStart);
        return (t) {
          final x = value(t);
          return x is String && isoDateRe.hasMatch(x) && _compareIso(x, op, range);
        };
      case 'checkbox':
        final v = n.value;
        if (op != Cmp.eq || v is! BoolValue) {
          throw FilterSyntaxError('Checkbox fields support "= true" or "= false" only, at position ${at + 1}', at, ['"= true"', '"= false"']);
        }
        // An unset checkbox reads as unchecked.
        return (t) => applies(t, def) && (v.value ? value(t) == true : value(t) != true);
      default:
        if (op != Cmp.eq) {
          final type = switch (def['type']) { 'link' => 'Link', 'choice' => 'Choice', _ => 'Text' };
          throw FilterSyntaxError('$type fields support "=" only, at position ${at + 1}', at, ['"="']);
        }
        // A bare word that reads as a date (`client = today`) still compares as its text.
        final want = fieldValueText(n.value).toLowerCase();
        return (t) {
          final x = value(t);
          return x is String && x.toLowerCase() == want;
        };
    }
  }

  /// `assigned: me` is the viewer; any other name matches every member with that name or email.
  Pred _assignedTo(String name) {
    if (name.toLowerCase() == 'me') {
      final me = ctx.me;
      if (me == null || me.isEmpty) return _never;
      return (t) => t['assignee_id'] == me;
    }
    final key = nameKey(name);
    final ids = (ctx.members ?? const <FilterMember>[])
        .where((m) => nameKey(m.name) == key || nameKey(m.email) == key)
        .map((m) => m.userId)
        .toSet();
    if (ids.isEmpty) {
      warn('No member named "$name"');
      return _never;
    }
    return (t) => t['assignee_id'] != null && ids.contains(t['assignee_id']);
  }

  Pred _keyword(String keyword) {
    switch (keyword) {
      case 'overdue':
        return (t) {
          final d = dueDate(t);
          return d != null && d.compareTo(today) < 0;
        };
      case 'today':
        return (t) => dueDate(t) == today;
      case 'tomorrow':
        return (t) => dueDate(t) == tomorrow;
      case 'no date':
        return (t) => t['due'] == null;
      case 'no time':
        return (t) => t['due'] is Map && !truthy((t['due'] as Map)['time']);
      case 'no project':
        return (t) => t['project_id'] == null;
      case 'no labels':
        return (t) => ((t['labels'] as List?) ?? const []).isEmpty;
      case 'no deadline':
        return (t) => !truthy(t['deadline']);
      case 'no start':
        return (t) => !truthy(t['start']);
      case 'someday':
        return (t) => t['start'] == 'someday';
      case 'deferred':
        return (t) => truthy(t['start']) && t['start'] != 'someday' && (t['start'] as String).compareTo(today) > 0;
      case 'evening':
        return (t) => truthy(t['evening']);
      // The stored part of the day, never the part a due time places it in.
      case 'morning':
      case 'afternoon':
        return (t) => dayPartOf(t) == keyword;
      // A habit's skipped occurrence record is not a completion.
      case 'completed':
        return (t) => t['completed_at'] != null && !truthy(t['skipped']);
      case 'open':
        return (t) => t['completed_at'] == null;
      case 'subtask':
        return (t) => t['parent_id'] != null;
      case 'habit':
        return (t) => t['habit'] == true;
      case 'origin':
        return (t) => originOf(t) != null;
      case 'no origin':
        return (t) => originOf(t) == null;
      case 'energy':
        return (t) => energyOf(t) != null;
      case 'no energy':
        return (t) => energyOf(t) == null;
      case 'sector':
        return (t) => isSector(t['sector']);
      case 'no sector':
        return (t) => !isSector(t['sector']);
      case 'carried':
        return (t) => isCarried(strOf(t, 'sector') ?? '', today, weekStart);
      case 'assigned':
        return (t) => truthy(t['assignee_id']);
      case 'unassigned':
        return (t) => !truthy(t['assignee_id']);
      // A note of only whitespace is no note.
      case 'notes':
        return (t) => (strOf(t, 'description') ?? '').trim().isNotEmpty;
      case 'no notes':
        return (t) => (strOf(t, 'description') ?? '').trim().isEmpty;
      // At least one minute of live tracked time.
      case 'tracked':
      case 'tracked occurrence':
        final of = trackedOf(keyword == 'tracked occurrence');
        return (t) => (of?[t['id']] ?? 0) >= 1;
      case 'blocked':
        final b = blockedSet();
        return (t) => b.containsKey(t['id']);
      case 'unblocked':
        final b = blockedSet();
        return (t) => !b.containsKey(t['id']);
      // Available now: not blocked, not waiting in sequence, neither Someday nor deferred.
      case 'available':
        final f = flowState();
        return (t) => f.available(t['id'] as String);
    }
    return _never;
  }
}
