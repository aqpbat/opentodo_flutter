// Today: the closed list against the shared vectors of
// web/src/lib/closedList.vectors.json (copied unchanged, run the way
// web/src/lib/closedList.test.ts runs them), and the Today selection, groups and
// order on the boundary cases (overdue, evening, day parts, zoned due in another
// zone, logical day).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/local_day.dart';
import 'package:opentodo_flutter/domain/today.dart';

import 'support/test_zones.dart';

SlotTask _slot(Map<String, dynamic> t) => SlotTask(
  id: t['id'] as String,
  createdAt: t['created_at'] as num,
  earlier: t['earlier'] == true,
  due: t['due'] as String?,
  habit: t['habit'] == true,
  blocked: t['blocked'] == true,
  time: t['time'] as String?,
  deadline: t['deadline'] as String?,
);

Map<String, dynamic> _task(
  String id, {
  Map<String, dynamic>? due,
  String? deadline,
  String? start,
  int priority = 4,
  num position = 0,
  bool evening = false,
  String? dayPart,
  Object? completedAt,
  String? projectId,
  String? assignee,
  List<String> blockedBy = const [],
}) => {
  'id': id,
  'project_id': projectId,
  'priority': priority,
  'due': due,
  'deadline': deadline,
  'start': start,
  'position': position,
  'evening': evening,
  'day_part': dayPart,
  'completed_at': completedAt,
  'deleted_at': null,
  'assignee_id': assignee,
  'blocked_by': blockedBy,
  'created_at': 0,
  'habit_graduated_at': null,
  'skipped': false,
  'sector': '',
  'span': false,
};

void main() {
  final vectors = jsonDecode(
    File('test/vectors/closedList.vectors.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final vToday = vectors['today'] as String;

  group('closedList.vectors.json', () {
    test('reads the stored limit', () {
      for (final pair in (vectors['limits'] as List).cast<List>()) {
        expect(readTodayLimit(pair[0]), pair[1], reason: '${pair[0]}');
      }
    });

    for (final v in (vectors['cases'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'] as String, () {
        final raw = (v['tasks'] as List).cast<Map<String, dynamic>>();
        final tasks = raw.map(_slot).toList();
        final availableById = {for (final t in raw) t['id'] as String: t['available'] != false};
        final review = <String, dynamic>{
          'focus_date': '',
          'focus': '',
          'slots_date': '',
          'slots': '',
          ...?(v['review'] as Map<String, dynamic>?),
        };
        final fill = fillSlots(
          tasks: tasks,
          limit: v['limit'],
          today: vToday,
          review: review,
          available: v['predicate'] == 'flow' ? (t) => availableById[t.id]! : notBlocked,
        );
        final want = v['expect'] as Map<String, dynamic>;
        expect(fill.limit, want['limit']);
        expect(fill.slots, want['slots']);
        expect(fill.waiting, want['waiting']);
        expect(fill.chosen, want['chosen']);

        final byId = {for (final t in tasks) t.id: t};
        final soon = timeSensitive(
          [for (final id in fill.waiting) byId[id]!],
          vToday,
          v['now'] as String?,
        );
        expect([
          for (final s in soon) {'id': s.id, 'time': s.time, 'passed': s.passed},
        ], (v['time_sensitive'] as List?) ?? const []);
        expect(nextWaiting(soon)?.id, v['next']);

        final take = v['take'] as Map<String, dynamic>?;
        if (take != null) {
          final got = takeSlotList(fill, takenSlots(review, vToday), take['id'] as String);
          expect(got ?? 'full', take['taken']);
        }
      });
    }
  });

  group('closed list extras', () {
    test('reads now on the logical today: past 24:00 after midnight before the day start', () {
      expect(waitingNow(9, 5, '2026-10-30', '2026-10-30'), '09:05');
      expect(waitingNow(1, 30, '2026-10-30', '2026-10-31'), '25:30');
    });

    test('gives a slot back', () {
      expect(giveBackSlotList(['a', 'b', 'c'], 'b'), ['a', 'c']);
    });

    test('keeps at most twenty taken ids', () {
      final ids = [for (var i = 0; i < 25; i++) 't${i.toString().padLeft(2, '0')}'];
      final tasks = [for (var i = 0; i < 25; i++) SlotTask(id: ids[i], createdAt: i)];
      final fill = fillSlots(tasks: tasks, limit: 20, today: vToday);
      final unchosen = SlotFill(
        limit: fill.limit,
        slots: fill.slots,
        waiting: fill.waiting,
        chosen: 0,
      );
      final taken = takeSlotList(unchosen, ids.sublist(0, 20), 't24');
      expect(taken, isNotNull);
      expect(taken!.length, 20);
      expect(taken.last, 't24');
    });

    test('take a slot writes the review fields; full writes nothing', () {
      final tasks = [const SlotTask(id: 'a', createdAt: 1), const SlotTask(id: 'b', createdAt: 2)];
      final fill = fillSlots(tasks: tasks, limit: 1, today: vToday);
      expect(takeSlotFields(null, vToday, fill, 'b'), {'slots_date': vToday, 'slots': 'b'});
      final review = {'focus_date': vToday, 'focus': 'a'};
      final full = fillSlots(tasks: tasks, limit: 1, today: vToday, review: review);
      expect(takeSlotFields(review, vToday, full, 'b'), isNull);
    });
  });

  group('Today selection', () {
    const utc = ViewerZone.utc;
    const today = '2026-11-02';

    test(
      'lists overdue, due today, deadline reached and started; not tomorrow, done or someday',
      () {
        final tasks = [
          _task('over', due: {'date': '2026-10-30'}),
          _task('today', due: {'date': today}),
          _task('dl', deadline: today),
          _task('dlpast', deadline: '2026-11-01', due: {'date': '2026-11-05'}),
          _task('started', start: '2026-10-01'),
          _task('tomorrow', due: {'date': '2026-11-03'}),
          _task('done', due: {'date': today}, completedAt: 1),
          _task('someday', start: 'someday'),
          _task('deferred', start: '2026-11-04'),
          _task('somedaydue', start: 'someday', due: {'date': today}),
        ];
        final ids = todayList(tasks, today, utc).map((t) => t['id']).toSet();
        expect(ids, {'over', 'today', 'dl', 'dlpast', 'started', 'somedaydue'});
      },
    );

    test('Earlier: due before today, or deadline passed unless planned for today', () {
      expect(overdueInToday(_task('a', due: {'date': '2026-11-01'}), today, utc), isTrue);
      expect(overdueInToday(_task('b', deadline: '2026-11-01'), today, utc), isTrue);
      expect(
        overdueInToday(_task('c', deadline: '2026-11-01', due: {'date': today}), today, utc),
        isFalse,
      );
      expect(overdueInToday(_task('d', deadline: today), today, utc), isFalse);
      expect(
        overdueInToday(_task('e', due: {'date': today, 'time': '00:00'}), today, utc),
        isFalse,
      );
    });

    test('orders by due date and time, date-only after timed, then priority, position, id', () {
      final tasks = [
        _task('dateonly', due: {'date': today}, priority: 1),
        _task('late', due: {'date': today, 'time': '18:00'}),
        _task('early', due: {'date': today, 'time': '08:00'}),
        _task('older', due: {'date': '2026-10-01'}, priority: 4),
        _task('p2', due: {'date': today}, priority: 2),
        _task('p2b', due: {'date': today}, priority: 2, position: -1),
        _task('nodue', deadline: today),
      ];
      expect(todayList(tasks, today, utc).map((t) => t['id']), [
        'older',
        'early',
        'late',
        'dateonly',
        'p2b',
        'p2',
        'nodue',
      ]);
    });

    test('groups: Earlier, day, This Evening, Blocked (day parts off)', () {
      final tasks = [
        _task('over', due: {'date': '2026-10-30'}, evening: true),
        _task('day', due: {'date': today, 'time': '19:00'}),
        _task('eve', due: {'date': today}, evening: true),
        _task('wait', due: {'date': today}, blockedBy: ['day']),
      ];
      final g = groupToday(todayList(tasks, today, utc), today, utc, blocked: {'wait'});
      expect(g.overdue.map((t) => t['id']), ['over']);
      expect(g.day.map((t) => t['id']), ['day']);
      expect(g.evening.map((t) => t['id']), ['eve']);
      expect(g.blocked.map((t) => t['id']), ['wait']);
      expect(g.morning, isEmpty);
      expect(g.afternoon, isEmpty);
    });

    test(
      'day parts on: own part wins over the time; untagged by due time; 12:00 and 18:00 bounds',
      () {
        final tasks = [
          _task('any', due: {'date': today}),
          _task('m', due: {'date': today, 'time': '11:59'}),
          _task('noon', due: {'date': today, 'time': '12:00'}),
          _task('a', due: {'date': today, 'time': '17:59'}),
          _task('six', due: {'date': today, 'time': '18:00'}),
          _task('own', due: {'date': today, 'time': '20:00'}, dayPart: 'morning'),
          _task('flag', due: {'date': today, 'time': '07:00'}, evening: true, dayPart: 'morning'),
          _task('bogus', due: {'date': today}, dayPart: 'night'),
        ];
        final g = groupToday(todayList(tasks, today, utc), today, utc, parts: true);
        expect(g.day.map((t) => t['id']).toSet(), {'any', 'bogus'});
        expect(g.morning.map((t) => t['id']).toSet(), {'m', 'own'});
        expect(g.afternoon.map((t) => t['id']).toSet(), {'noon', 'a'});
        expect(g.evening.map((t) => t['id']).toSet(), {'six', 'flag'});
      },
    );

    test('dayPartFields never writes evening with a day_part', () {
      expect(dayPartFields(DayPart.evening), {'day_part': null, 'evening': true});
      expect(dayPartFields(DayPart.morning), {'day_part': 'morning', 'evening': false});
      expect(dayPartFields(null), {'day_part': null, 'evening': false});
    });

    test('a zoned due is placed by the viewer\'s wall date, not the stored one', () {
      // 20:00 New York on Nov 2 is 02:00 on Nov 3 in Berlin.
      final ny = _task(
        'ny',
        due: {'date': '2026-11-02', 'time': '20:00', 'tz': 'America/New_York'},
      );
      const berlin = ViewerZone('Europe/Berlin', offsetOf: testZoneOffset);
      const la = ViewerZone('America/Los_Angeles', offsetOf: testZoneOffset);
      expect(inToday(ny, '2026-11-02', berlin), isFalse);
      expect(inToday(ny, '2026-11-03', berlin), isTrue);
      expect(inToday(ny, '2026-11-02', la), isTrue);
      // 01:00 Berlin on Nov 3 is 16:00 Nov 2 in Los Angeles: overdue there on Nov 3.
      final be = _task('be', due: {'date': '2026-11-03', 'time': '01:00', 'tz': 'Europe/Berlin'});
      expect(overdueInToday(be, '2026-11-03', la), isTrue);
      expect(placedPart(be, la), DayPart.afternoon);
      expect(placedPart(be, berlin), DayPart.morning);
      // An unknown zone degrades to the stored wall date and time.
      final odd = _task('odd', due: {'date': '2026-11-02', 'time': '23:00', 'tz': 'Mars/Olympus'});
      expect(inToday(odd, '2026-11-02', berlin), isTrue);
      expect(placedPart(odd, berlin), DayPart.evening);
    });

    test('hides tasks of shared projects assigned to someone else only with `mine`', () {
      final tasks = [
        _task('mine', due: {'date': today}, projectId: 'shared', assignee: 'me'),
        _task('theirs', due: {'date': today}, projectId: 'shared', assignee: 'you'),
        _task('open', due: {'date': today}, projectId: 'shared'),
        _task('private', due: {'date': today}, projectId: 'solo', assignee: 'you'),
      ];
      final hide = todayAssigneeFilter({'today_assignees': 'mine'}, ['shared'], 'me');
      expect(todayList(tasks, today, utc, hide).map((t) => t['id']).toSet(), {
        'mine',
        'open',
        'private',
      });
      expect(todayAssigneeFilter({'today_assignees': ''}, ['shared'], 'me'), isNull);
    });

    test('earlierIds leaves out archived projects, deleted and blocked tasks', () {
      final tasks = [
        _task('a', due: {'date': '2026-10-01'}),
        _task('arch', due: {'date': '2026-10-01'}, projectId: 'old'),
        {
          ..._task('del', due: {'date': '2026-10-01'}),
          'deleted_at': 5,
        },
        _task('blk', due: {'date': '2026-10-01'}, blockedBy: ['a']),
      ];
      final projects = [
        {'id': 'old', 'archived': true},
      ];
      expect(earlierIds(tasks, projects, today, utc), ['a']);
    });

    test('completedOn: the logical day of completion, most recent first, skipped left out', () {
      final at = DateTime.parse('2026-11-03T02:00:00Z').millisecondsSinceEpoch;
      final tasks = [
        _task('late', completedAt: at),
        _task('noon', completedAt: DateTime.parse('2026-11-02T12:00:00Z').millisecondsSinceEpoch),
        {..._task('skip', completedAt: at), 'skipped': true},
        _task('open'),
      ];
      expect(completedOn(tasks, today, utc).map((t) => t['id']), ['noon']);
      expect(completedOn(tasks, today, utc, dayStart: 240).map((t) => t['id']), ['late', 'noon']);
    });

    test('the logical day: before the day start it is still yesterday', () {
      final ms = DateTime.parse('2026-11-05T01:30:00Z').millisecondsSinceEpoch;
      expect(utc.logicalDay(ms, 240), '2026-11-04');
      expect(utc.logicalDay(ms, 0), '2026-11-05');
    });
  });
}
