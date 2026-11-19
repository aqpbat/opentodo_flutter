// The urgency score against the shared vectors of web/src/lib/urgency.vectors.json
// (copied unchanged), run the way web/src/lib/urgency.test.ts runs them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/dependencies.dart';
import 'package:opentodo_flutter/domain/local_day.dart';
import 'package:opentodo_flutter/domain/urgency.dart';

void main() {
  final vectors = jsonDecode(
    File('test/vectors/urgency.vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  group('urgency.vectors.json', () {
    for (final v in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'] as String, () {
        final task = v['task'] as Map<String, dynamic>;
        final all = [task, ...(v['others'] as List).cast<Map<String, dynamic>>()];
        final zone = ViewerZone(v['zone'] as String);
        final dayStart = (v['day_start'] as num).toInt();
        final now = DateTime.parse(v['now'] as String).millisecondsSinceEpoch;
        final today = zone.logicalDay(now, dayStart);
        final got = urgency(
          task,
          UrgencyInput(
            today: today,
            zone: zone,
            dayStart: dayStart,
            blocks: blocksCount(all)[task['id']] ?? 0,
            blocked: blockedMap(all).containsKey(task['id']),
            timer: v['running_task_id'] == task['id'],
          ),
        );
        final want = v['expect'] as Map<String, dynamic>?;
        if (want == null) {
          expect(got, isNull);
          return;
        }
        expect(got, isNotNull);
        expect(got!.score, (want['score'] as num).toDouble());
        expect(
          [
            for (final p in got.parts) [p.key.name, p.value],
          ],
          [
            for (final p in (want['parts'] as List).cast<Map<String, dynamic>>())
              [p['key'], (p['value'] as num).toDouble()],
          ],
        );
      });
    }
  });

  test('ramps from 1 a week late to 0.2 two weeks ahead', () {
    expect(ramp(-30), 1);
    expect(ramp(-7), 1);
    expect(ramp(0), closeTo(0.7333, 1e-4));
    expect(ramp(14), 0.2);
    expect(ramp(40), 0.2);
  });

  test('names the days and counts its labels use', () {
    final got = urgency({
      'priority': 2,
      'due': {'date': '2026-11-05'},
      'created_at': DateTime.parse('2026-10-03T12:00:00Z').millisecondsSinceEpoch,
      'completed_at': null,
      'deleted_at': null,
      'deadline': null,
      'start': '2026-11-04',
    }, const UrgencyInput(today: '2026-11-02', zone: ViewerZone.utc, blocks: 3))!;
    expect(
      [
        for (final p in got.parts) [p.key.name, p.n],
      ],
      [
        ['due', 3],
        ['priority', 2],
        ['blocks', 3],
        ['age', 30],
        ['deferred', 2],
      ],
    );
  });

  test('orders by urgency: most urgent first, closed last, ties by due', () {
    final created = DateTime.parse('2026-11-02T00:00:00Z').millisecondsSinceEpoch;
    Map<String, dynamic> t(String id, int priority, {String? due, int? completed}) => {
      'id': id,
      'priority': priority,
      'due': due == null ? null : {'date': due},
      'deadline': null,
      'start': null,
      'position': 0,
      'created_at': created,
      'completed_at': completed,
      'deleted_at': null,
      'blocked_by': <String>[],
    };
    final tasks = [
      t('low', 4),
      t('done', 1, completed: 1),
      t('p1', 1),
      t('due', 4, due: '2026-11-02'),
      t('low2', 4, due: '2026-12-30'),
    ];
    final of = urgencyOf(tasks, '2026-11-02', ViewerZone.utc);
    final asc = [...tasks]..sort(compareByUrgency(of, ViewerZone.utc));
    expect(asc.map((x) => x['id']), ['due', 'p1', 'low2', 'low', 'done']);
    final desc = [...tasks]..sort(compareByUrgency(of, ViewerZone.utc, descending: true));
    expect(desc.map((x) => x['id']), ['low', 'low2', 'p1', 'due', 'done']);
  });
}
