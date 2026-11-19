// Completing recurring tasks: the shared series fixture
// (web/src/lib/series.fixture.json, copied unchanged; the cases on one series
// without splits, carries or ranges) and the convergence scenarios of
// docs/recurrence.md §Sync and convergence.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/ids.dart';
import 'package:opentodo_flutter/core/schema_generated.dart';
import 'package:opentodo_flutter/domain/complete.dart';

const _now = 1000;

Row _task(String id, Map<String, Object?> over) => {
      ...opDefaults['task']!.map((k, v) => MapEntry(k, v is List ? [...v] : (v is Map ? {...v} : v))),
      'id': id,
      ...over,
    };

// ---- the fixture (ported from web/src/lib/series.fixture.test.ts) ----

Row _fixtureSeries(Map<String, dynamic> c) => _task('s', {
      'title': 'Study',
      'position': 1,
      ...(c['series'] as Map<String, dynamic>),
    });

Row _fixtureRecord(Row of, Map<String, dynamic> r) {
  final date = r['date'] as String;
  final time = (of['due'] as Map?)?['time'];
  final due = r['due'] ?? (time != null ? {'date': date, 'time': time} : {'date': date});
  final out = <String, Object?>{
    ...of,
    'id': occurrenceId(of['id'] as String, date),
    'recurrence': null,
    'series_id': of['id'],
    'due': due,
    'title': r['title'] ?? of['title'],
    'split_from': null,
    'completed_at': r['state'] == 'open' ? null : 1,
    'skipped': r['state'] == 'skipped',
    'habit': false,
  };
  if (r['legacy'] == true) {
    out.remove('occurrence_date');
  } else {
    out['occurrence_date'] = date;
  }
  return out;
}

OccurrenceAction _actionOf(Map<String, dynamic> act) => switch (act['kind']) {
      'move' => MoveOccurrence((act['due'] as Map).cast<String, Object?>()),
      'edit' => EditOccurrence(((act['patch'] as Map?) ?? {}).cast<String, Object?>()),
      'skip' => const SkipOccurrence(),
      _ => const CompleteOccurrence(),
    };

/// The cases this port covers: one series, acting on an occurrence or repairing.
bool _covered(Map<String, dynamic> c) {
  if (c['client_only'] == true || c['pieces'] != null || c['range'] != null) return false;
  if (c['carry'] != null || c['carry_past'] != null || (c['target'] ?? 's') != 's') return false;
  final kind = (c['act'] as Map?)?['kind'];
  return c['repair'] == true || const ['complete', 'skip', 'move', 'edit'].contains(kind);
}

void _expectSubset(Map<String, Object?> got, Map<String, dynamic> want, String reason) {
  for (final e in want.entries) {
    expect(got.containsKey(e.key), isTrue, reason: '$reason: ${e.key} missing');
    expect(got[e.key], e.value, reason: '$reason: ${e.key}');
  }
}

void _runFixtureCase(Map<String, dynamic> c) {
  final series = _fixtureSeries(c);
  final tasks = <Row>[
    series,
    for (final r in (c['records'] as List).cast<Map<String, dynamic>>()) _fixtureRecord(series, r),
  ];
  final want = c['expect'] as Map<String, dynamic>;
  final today = c['today'] as String;
  if (c['repair'] == true) {
    final out = planRepair(series, tasks, today, _now);
    if (want['series'] == null) {
      expect(out, isEmpty);
    } else {
      expect(out, hasLength(1));
      expect(out[0].entityId, 's');
      expect(out[0].patch, want['series']);
    }
    return;
  }
  final act = c['act'] as Map<String, dynamic>;
  final plan = planActOn(series, act['date'] as String?, _actionOf(act), tasks, _now, today);
  if (want['ok'] == false) {
    expect(plan, isNull);
    return;
  }
  expect(plan, isNotNull);
  if (want['end'] == true) {
    expect(plan!.end, isTrue);
    return;
  }
  expect(plan!.end, isFalse);
  final seriesChange = plan.changes.where((ch) => ch.entityId == 's').toList();
  if (want['series'] == null) {
    expect(seriesChange, isEmpty);
  } else {
    expect(seriesChange.single.patch, want['series']);
  }
  final records = plan.changes.where((ch) => ch.entity == 'task' && ch.entityId != 's').toList();
  if (want.containsKey('record') && want['record'] == null) {
    expect(records, isEmpty);
    return;
  }
  expect(records.map((ch) => ch.entityId), [occurrenceId('s', want['record_date'] as String)]);
  _expectSubset(records[0].patch, want['record'] as Map<String, dynamic>, 'record');
  for (final k in ((want['record_absent'] as List?) ?? const []).cast<String>()) {
    expect(records[0].patch.containsKey(k), isFalse, reason: 'record must not hold $k');
  }
}

// ---- a tiny LWW store: applies a batch of ops field by field ----

class _Store {
  final rows = <String, Row>{};
  final clocks = <String, (int, String)>{};
  void apply(List<Change> changes, int ts, String device) {
    var n = 0;
    for (final op in changesToOps(changes, ts: ts, device: device, newId: () => '${device}_${n++}')) {
      final key = '${op.entityId}.${op.field}';
      final c = clocks[key];
      if (!op.beats(c?.$1, c?.$2)) continue;
      clocks[key] = (op.ts, op.device);
      (rows[op.entityId] ??= {'id': op.entityId})[op.field] = op.value;
    }
  }
}

void main() {
  final fixture = jsonDecode(File('test/vectors/series.fixture.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  group('series.fixture.json (single-series cases)', () {
    final covered = cases.where(_covered).toList();
    test('covers the single-series cases', () => expect(covered.length, greaterThanOrEqualTo(25)));
    for (final c in covered) {
      test(c['name'] as String, () => _runFixtureCase(c));
    }
  });

  group('completing a recurring task', () {
    final series = _task('s', {
      'title': 'Report',
      'recurrence': 'every monday',
      'due': {'date': '2026-10-12', 'time': '09:00'},
      'deadline': '2026-10-14',
      'labels': ['work'],
    });

    test('writes the occurrence record and moves the series', () {
      final plan = planCompletion(series, [series], _now, '2026-10-12');
      expect(plan.end, isFalse);
      expect(plan.next, '2026-10-19');
      final record = plan.changes[0];
      expect(record.entityId, occurrenceId('s', '2026-10-12'));
      expect(plan.recordId, record.entityId);
      _expectSubset(record.patch, {
        'title': 'Report',
        'labels': ['work'],
        'recurrence': null,
        'series_id': 's',
        'occurrence_date': '2026-10-12',
        'due': {'date': '2026-10-12', 'time': '09:00'},
        'deadline': '2026-10-14',
        'completed_at': _now,
        'skipped': false,
      }, 'record');
      expect(plan.changes[1].entityId, 's');
      expect(plan.changes[1].patch, {
        'due': {'date': '2026-10-19', 'time': '09:00'},
        'deadline': '2026-10-21',
      });
    });

    test('two offline completions of the same occurrence converge to one record', () {
      // Device A completes at 10:00, device B (not yet synced) at 11:00.
      final a = planCompletion(series, [series], 5000, '2026-10-12');
      final b = planCompletion(series, [series], 6000, '2026-10-12');
      expect(a.recordId, b.recordId);
      expect(a.next, b.next);
      final store = _Store()..rows['s'] = {...series};
      store.apply(a.changes, 100, 'flutter:a');
      store.apply(b.changes, 200, 'flutter:b');
      final records = store.rows.values.where((r) => r['series_id'] == 's').toList();
      expect(records, hasLength(1));
      expect(records.single['due'], {'date': '2026-10-12', 'time': '09:00'});
      expect(store.rows['s']!['due'], {'date': '2026-10-19', 'time': '09:00'});
    });

    test('the series never stands on an exception date', () {
      // Wednesday completed early on another device; Monday's completion jumps over it.
      final weekly = _task('w', {'recurrence': 'every mon, wed, fri', 'due': {'date': '2026-10-12'}});
      final wed = _task(occurrenceId('w', '2026-10-14'), {
        'series_id': 'w',
        'occurrence_date': '2026-10-14',
        'due': {'date': '2026-10-14'},
        'completed_at': 1,
      });
      final plan = planCompletion(weekly, [weekly, wed], _now, '2026-10-12');
      expect(plan.next, '2026-10-16');
      // A device that rolled the series onto Wednesday before it saw the record repairs it.
      final rolled = {...weekly, 'due': {'date': '2026-10-14'}};
      final fix = planRepair(rolled, [rolled, wed], '2026-10-12', _now);
      expect(fix.single.patch, {'due': {'date': '2026-10-16'}});
      expect(planRepair(weekly, [weekly, wed], '2026-10-12', _now), isEmpty);
    });

    test('the end condition ends the series like a plain task', () {
      final last = _task('l', {'recurrence': 'every day for 1 time', 'due': {'date': '2026-10-12'}});
      expect(planCompletion(last, [last], _now, '2026-10-12').end, isTrue);
      expect(planSkip(last, _now, '2026-10-12', [last]), isNotNull, reason: 'a skip is never counted');
      final until = _task('u', {'recurrence': 'every day until 2026-10-12', 'due': {'date': '2026-10-12'}});
      expect(planSkip(until, _now, '2026-10-12', [until]), isNull);
    });

    test('a completion-relative rule counts from today', () {
      final rel = _task('r', {'recurrence': 'every 3 days after completion', 'due': {'date': '2026-10-12'}});
      expect(planCompletion(rel, [rel], _now, '2026-10-14').next, '2026-10-17');
    });

    test('a rotation passes the turn on the series', () {
      final plan = planCompletion({...series, 'assignee_id': 'u1'}, [series], _now, '2026-10-12', nextAssignee: 'u2');
      expect(plan.changes[1].patch['assignee_id'], 'u2');
      expect(plan.changes[0].patch['assignee_id'], 'u1');
    });
  });

  group('skip and this occurrence only', () {
    test('skipping a plain series writes only the move', () {
      final s = _task('s', {'recurrence': 'every day', 'due': {'date': '2026-10-12'}});
      final out = planSkip(s, _now, '2026-10-12', [s])!;
      expect(out.map((c) => c.entityId), ['s']);
      expect(out.single.patch, {'due': {'date': '2026-10-13'}});
    });

    test('skipping a habit writes the skipped record with the same id a completion writes', () {
      final h = _task('h', {'recurrence': 'every day', 'due': {'date': '2026-10-12'}, 'habit': true, 'description': 'note'});
      final out = planSkip(h, _now, '2026-10-12', [h])!;
      expect(out[0].entityId, occurrenceId('h', '2026-10-12'));
      expect(out[0].patch['skipped'], true);
      expect(out[0].patch.containsKey('description'), isFalse);
      expect(planCompletion(h, [h], _now, '2026-10-12').recordId, out[0].entityId);
    });

    test('this occurrence only writes an open record and copies relative reminders', () {
      final s = _task('s', {'recurrence': 'every day', 'due': {'date': '2026-10-12', 'time': '18:00'}});
      final reminders = <Row>[
        {'id': 'r1', 'task_id': 's', 'kind': 'relative', 'offset_minutes': -15, 'deleted_at': null},
        {'id': 'r2', 'task_id': 's', 'kind': 'absolute', 'fire_at': 1, 'deleted_at': null},
      ];
      final plan = planDetach(s, _now, '2026-10-12', [s], reminders, (due, offset) => 42 + (offset ?? 0))!;
      final recordId = occurrenceId('s', '2026-10-12');
      expect(plan.changes.map((c) => c.entityId), [recordId, 's', nameId('occurrence-reminder', '$recordId:r1')]);
      expect(plan.changes[0].patch['completed_at'], isNull);
      expect(plan.changes[0].patch['recurrence'], isNull);
      expect(plan.changes[1].patch, {'due': {'date': '2026-10-13', 'time': '18:00'}});
      expect(plan.changes[2].patch['fire_at'], 27);
      expect(plan.changes[2].patch['task_id'], recordId);
    });
  });

  test('changesToOps writes one op per field under one ts and device, unfolding custom fields', () {
    final ops = changesToOps([
      const Change('task', 't', {'title': 'x', 'fields': {'f1': 3, 'bad id!': 1}}),
      const Change('reminder', 'r', {'fire_at': 5}),
    ], ts: 77, device: 'flutter:d', newId: () => 'id');
    expect(ops.map((o) => '${o.entityId}.${o.field}=${o.value}'), ['t.title=x', 't.fields.f1=3', 'r.fire_at=5']);
    expect(ops.every((o) => o.ts == 77 && o.device == 'flutter:d'), isTrue);
  });
}
