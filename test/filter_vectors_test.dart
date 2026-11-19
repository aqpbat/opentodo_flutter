// The filter evaluator against the shared vectors of
// web/src/lib/filter/evaluate.vectors.json (copied unchanged to
// test/vectors/filter/): web/src/lib/filter/evaluate.vectors.test.ts and
// internal/filter/evaluate_test.go run the same file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/filter.dart';

/// A task row with the defaults the web test fills; `fields.<id>` keys go into `fields`.
Row taskRow(Map<String, Object?> row) {
  final fields = <String, Object?>{};
  final base = <String, Object?>{
    'title': '', 'description': '', 'labels': <Object?>[], 'priority': 4, 'due': null, 'project_id': null, //
    'section_id': null, 'parent_id': null, 'start': null, 'deadline': null, 'evening': false, 'day_part': null,
    'completed_at': null, 'deleted_at': null, 'created_at': 1792454400000, 'habit': false, 'origin': null,
    'energy': '', 'blocked_by': <Object?>[], 'position': 0,
  };
  for (final e in row.entries) {
    if (e.key.startsWith('fields.')) {
      fields[e.key.substring(7)] = e.value;
    } else {
      base[e.key] = e.value;
    }
  }
  return {...base, 'fields': fields};
}

List<Row> rows(Object? list) => [for (final r in list as List) (r as Map).cast<String, Object?>()];

void main() {
  final v = jsonDecode(File('test/vectors/filter/evaluate.vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final tasks = [for (final r in rows(v['tasks'])) taskRow(r)];
  final ctx = FilterContext(
    today: v['today'] as String,
    weekStart: v['week_start'] as int,
    labels: rows(v['labels']),
    projects: rows(v['projects']),
    fields: rows(v['fields']),
    tasks: tasks,
    tracked: (v['tracked'] as Map).cast<String, num>(),
    trackedOccurrence: (v['tracked_occurrence'] as Map).cast<String, num>(),
    me: v['me'] as String,
    members: [for (final m in rows(v['members'])) FilterMember.fromJson(m)],
    // The vectors are evaluated in UTC (Go's default zone, TZ=UTC in vitest).
    dayInstant: utcDayInstant,
  );
  final cases = rows(v['cases']);

  test('has the vectors', () => expect(cases.length, greaterThanOrEqualTo(50)));

  group('evaluate.vectors.json', () {
    for (final c in cases) {
      final query = c['query'] as String;
      test(query.isEmpty ? '(empty)' : query, () {
        final res = runFilter(query, tasks, ctx);
        if (res is FilterError) fail(res.error);
        final ok = res as FilterOk;
        expect(ok.tasks.map((t) => t['id']).toList(), (c['ids'] as List).cast<String>());
        expect(ok.warnings.length, (c['warnings'] as int?) ?? 0, reason: ok.warnings.join('; '));
      });
    }
  });

  test('an invalid query is an error, not a match', () {
    final res = runFilter('due before:', tasks, ctx);
    expect(res, isA<FilterError>());
  });
}
