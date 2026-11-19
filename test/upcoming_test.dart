// Upcoming: selection, the day each task is listed under, grouping by day, Start
// with Today and the next days (behaviour of web/src/lib/views.ts and dayLists.ts).

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/local_day.dart';
import 'package:opentodo_flutter/domain/upcoming.dart';

Map<String, dynamic> _task(
  String id, {
  Map<String, dynamic>? due,
  String? deadline,
  String? start,
  String? projectId,
  bool span = false,
  int priority = 4,
  Object? completedAt,
}) => {
  'id': id,
  'project_id': projectId,
  'priority': priority,
  'due': due,
  'deadline': deadline,
  'start': start,
  'span': span,
  'position': 0,
  'completed_at': completedAt,
  'deleted_at': null,
};

void main() {
  const utc = ViewerZone.utc;
  const today = '2026-11-02';

  test('lists open active tasks due after today and undated ones with a deadline ahead', () {
    final tasks = [
      _task('tomorrow', due: {'date': '2026-11-03'}),
      _task('today', due: {'date': today}),
      _task('dl', deadline: '2026-11-04'),
      _task('dlpast', deadline: '2026-11-01'),
      _task('done', due: {'date': '2026-11-03'}, completedAt: 1),
      _task('someday', due: {'date': '2026-11-03'}, start: 'someday'),
      _task('deferred-in-project', start: '2026-11-05', projectId: 'p'),
      _task('deferred-unplaced', start: '2026-11-05'),
    ];
    // Undated tasks follow the dated ones, then priority, position and id.
    expect(upcomingList(tasks, today, utc).map((t) => t['id']), [
      'tomorrow',
      'deferred-unplaced',
      'dl',
    ]);
  });

  test('a span is listed once, under its first day, only before it', () {
    final s = _task(
      's',
      start: '2026-11-04',
      due: {'date': '2026-11-06'},
      span: true,
      projectId: 'p',
    );
    expect(spanOf(s)!.length, 3);
    expect(inUpcoming(s, today, utc), isTrue);
    expect(upcomingDate(s, utc, today), '2026-11-04');
    expect(inUpcoming(s, '2026-11-04', utc), isFalse);
    // Not a span when the start is not before the due date.
    expect(spanOf({...s, 'start': '2026-11-06'}), isNull);
  });

  test('groups by day in date order: due date, deferred start, deadline', () {
    final tasks = [
      _task('b', due: {'date': '2026-11-05'}),
      _task('a', due: {'date': '2026-11-03', 'time': '09:00'}),
      _task('dl', deadline: '2026-11-03'),
      _task('deferred', start: '2026-11-04'),
    ];
    final groups = groupUpcoming(upcomingList(tasks, today, utc), utc, today);
    expect(
      [
        for (final g in groups) [g.date, g.tasks.map((t) => t['id']).toList()],
      ],
      [
        [
          '2026-11-03',
          ['a', 'dl'],
        ],
        [
          '2026-11-04',
          ['deferred'],
        ],
        [
          '2026-11-05',
          ['b'],
        ],
      ],
    );
  });

  test('a zoned due is listed under the viewer\'s day', () {
    // 20:00 New York on Nov 2 is Nov 3, 02:00 in Berlin.
    final t = _task('ny', due: {'date': '2026-11-02', 'time': '20:00', 'tz': 'America/New_York'});
    const berlin = ViewerZone('Europe/Berlin');
    expect(inUpcoming(t, today, berlin), isTrue);
    expect(upcomingDate(t, berlin), '2026-11-03');
    // ...and 17:00 on Nov 2 in Los Angeles: Today there, not Upcoming.
    const la = ViewerZone('America/Los_Angeles');
    expect(inUpcoming(t, today, la), isFalse);
  });

  test('Start with Today: Today first, then Upcoming without what Today holds', () {
    final tasks = [
      _task('later', due: {'date': '2026-11-03'}),
      _task('now', due: {'date': today}),
      _task('both', due: {'date': '2026-11-03'}, deadline: '2026-11-01'),
    ];
    expect(upcomingWithToday(tasks, today, utc).map((t) => t['id']), ['now', 'both', 'later']);
  });

  test('next days: one column per day, empty on a free day', () {
    final tasks = [
      _task('x', due: {'date': '2026-11-04'}),
    ];
    final days = nextDays(tasks, today, utc, 3);
    expect(
      [
        for (final d in days) [d.date, d.tasks.length],
      ],
      [
        ['2026-11-03', 0],
        ['2026-11-04', 1],
        ['2026-11-05', 0],
      ],
    );
    expect(nextDays(tasks, today, utc, -1), isEmpty);
  });

  test('date helpers cross month and year ends', () {
    expect(addDaysIso('2026-12-31', 1), '2027-01-01');
    expect(addDaysIso('2026-03-01', -1), '2026-02-28');
    expect(daysBetweenIso('2026-10-25', '2026-11-02'), 8);
    expect(daysBetweenIso('2026-11-02', '2026-10-25'), -8);
  });
}
