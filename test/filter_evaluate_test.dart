// Evaluator behaviour beyond the shared vectors, checked line by line against
// web/src/lib/filter/evaluate.ts, flow.ts and dependencies.ts.

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/filter.dart';

Row task(String id, [Map<String, Object?> more = const {}]) => {
      'id': id, 'title': id, 'description': '', 'labels': <Object?>[], 'priority': 4, 'due': null, //
      'project_id': null, 'parent_id': null, 'section_id': null, 'completed_at': null, 'deleted_at': null,
      'created_at': 0, 'position': 0, 'blocked_by': <Object?>[], 'fields': <String, Object?>{}, ...more,
    };

List<String> ids(FilterResult r) => (r as FilterOk).tasks.map((t) => t['id'] as String).toList();

void main() {
  const today = '2026-11-04';

  test('available: sequential project offers its first task only', () {
    final tasks = [
      task('a', {'project_id': 'p', 'position': 1}),
      task('b', {'project_id': 'p', 'position': 2}),
      task('c', {'project_id': 'p', 'position': 3, 'recurrence': 'every day'}),
      task('d', {'project_id': 'q', 'start': '2026-12-01'}),
      task('e', {'project_id': 'q', 'blocked_by': ['b']}),
      task('f', {'project_id': 'q'}),
    ];
    final ctx = FilterContext(today: today, tasks: tasks, projects: [
      {'id': 'p', 'name': 'P', 'flow_mode': 'sequential', 'deleted_at': null},
      {'id': 'q', 'name': 'Q', 'deleted_at': null},
    ]);
    expect(ids(runFilter('available', tasks, ctx)), ['a', 'c', 'f']);
  });

  test('available: a sequential parent offers its first open subtask', () {
    final tasks = [
      task('parent', {'flow_mode': 'sequential'}),
      task('s1', {'parent_id': 'parent', 'position': 1, 'completed_at': 5}),
      task('s2', {'parent_id': 'parent', 'position': 2}),
      task('s3', {'parent_id': 'parent', 'position': 3}),
    ];
    expect(ids(runFilter('available', tasks, FilterContext(today: today, tasks: tasks))), ['parent', 's2']);
  });

  test('blocked: a cycle is broken at the newest blocked_by clock', () {
    final tasks = [
      task('x', {'blocked_by': ['y'], '_clock': {'blocked_by': {'ts': 2, 'device': 'd'}}}),
      task('y', {'blocked_by': ['x'], '_clock': {'blocked_by': {'ts': 1, 'device': 'd'}}}),
    ];
    // x's edge is newest, so x stops blocking on y; y still waits for x.
    expect(ids(runFilter('blocked', tasks, FilterContext(today: today, tasks: tasks))), ['y']);
  });

  test('field terms: types decide the comparison; impossible ones are errors', () {
    final tasks = [
      task('a', {'project_id': 'p', 'fields': {'f_paid': true, 'f_client': 'Acme', 'f_when': '2026-11-06'}}),
      task('b', {'project_id': 'sub', 'fields': {'f_client': 'acme'}}),
      task('c', {'project_id': 'other', 'fields': {'f_client': 'Acme'}}),
    ];
    final ctx = FilterContext(
      today: today,
      projects: [
        {'id': 'p', 'name': 'P', 'parent_id': null},
        {'id': 'sub', 'name': 'Sub', 'parent_id': 'p'},
        {'id': 'other', 'name': 'Other', 'parent_id': null},
      ],
      fields: [
        {'id': 'f_paid', 'name': 'Paid', 'type': 'checkbox', 'project_id': 'p'},
        {'id': 'f_client', 'name': 'Client', 'type': 'text', 'project_id': 'p'},
        {'id': 'f_when', 'name': 'When', 'type': 'date', 'project_id': 'p'},
      ],
    );
    expect(ids(runFilter('paid = true', tasks, ctx)), ['a']);
    expect(ids(runFilter('paid = false', tasks, ctx)), ['b']);
    expect(ids(runFilter('client = ACME', tasks, ctx)), ['a', 'b']);
    expect(ids(runFilter('when <= friday', tasks, ctx)), ['a']);
    expect(ids(runFilter('no when', tasks, ctx)), ['b']);
    final err = runFilter('client > 3', tasks, ctx) as FilterError;
    expect((err.error, err.position), ('Text fields support "=" only, at position 8', 8));
    expect((runFilter('paid > 1', tasks, ctx) as FilterError).error, 'Checkbox fields support "= true" or "= false" only, at position 6');
    expect((runFilter('when = 3', tasks, ctx) as FilterError).error, 'Field "when" holds dates: compare it with a date at position 6');
  });

  test('zone and day start are injected', () {
    final tasks = [
      task('zoned', {'due': {'date': '2026-11-05', 'time': '01:00', 'tz': 'Asia/Tokyo'}}),
      // 2026-11-04 02:00 UTC: before a 03:00 day start, so it belongs to 11-03.
      task('late', {'created_at': DateTime.utc(2026, 11, 4, 2).millisecondsSinceEpoch}),
    ];
    final plain = FilterContext(today: today, dayInstant: utcDayInstant);
    expect(ids(runFilter('tomorrow', tasks, plain)), ['zoned']);
    expect(ids(runFilter('created = today', tasks, plain)), ['late']);
    final shifted = FilterContext(
      today: today,
      dayInstant: utcDayInstant,
      dayStartMinutes: 180,
      localDue: (due) => due['tz'] == 'Asia/Tokyo' ? '2026-11-04' : due['date'] as String,
    );
    expect(ids(runFilter('today', tasks, shifted)), ['zoned']);
    expect(ids(runFilter('created = yesterday', tasks, shifted)), ['late']);
  });

  test('completed tasks, skipped habits and deleted rows', () {
    final tasks = [
      task('open'),
      task('done', {'completed_at': 10}),
      task('skip', {'completed_at': 10, 'skipped': true}),
      task('gone', {'deleted_at': 3}),
    ];
    final ctx = FilterContext(today: today);
    expect(ids(runFilter('no project', tasks, ctx)), ['open']);
    final all = compileFilter(withCompletedTasks(parseFilter('no project')!), ctx);
    expect(tasks.where(all.test).map((t) => t['id']), ['open', 'done']);
    expect(ids(runFilter('completed', tasks, ctx)), ['done']);
  });

  test('workspace terms read every workspace when given', () {
    final home = [task('h', {'workspace_id': 'w1'})];
    final work = [task('w', {'workspace_id': 'w2'})];
    final ctx = FilterContext(
      today: today,
      workspaces: [
        {'id': 'w1', 'name': 'Home'},
        {'id': 'w2', 'name': 'Work'},
      ],
      workspaceOf: (t) => t['workspace_id'] as String,
      everyWorkspace: FilterScope(tasks: [...home, ...work], projects: const [], labels: const []),
    );
    expect(ids(runFilter('workspace: work', home, ctx)), ['w']);
    final none = runFilter('workspace: Garden', home, ctx) as FilterOk;
    expect(none.tasks, isEmpty);
    expect(none.warnings, ['No workspace named "Garden"']);
    expect(ids(runFilter('p4', home, ctx)), ['h']);
  });

  test('membersFrom keeps one row per account', () {
    final members = membersFrom([
      {
        'members': [
          {'userId': 'u1', 'name': 'Ada', 'email': 'a@x'},
        ],
      },
      {
        'members': [
          {'userId': 'u1', 'name': 'Ada L', 'email': 'a@x'},
          {'userId': 'u2', 'name': 'Sam', 'email': 's@x'},
        ],
      },
    ]);
    expect(members.map((m) => (m.userId, m.name)), [('u1', 'Ada'), ('u2', 'Sam')]);
  });
}
