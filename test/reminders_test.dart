// Reminders: the shared default reminder vectors (web/src/lib/
// defaultReminder.vectors.json, copied unchanged; times are UTC) and the rules
// of docs/sync.md §Reminders: firing times, due moves in the same batch, the
// show rule and races between delivery and snooze.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/op.dart';
import 'package:opentodo_flutter/domain/change.dart';
import 'package:opentodo_flutter/domain/dates.dart';
import 'package:opentodo_flutter/domain/default_reminder.dart';
import 'package:opentodo_flutter/domain/reminders.dart';

int utc(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

const berlin = 'Europe/Berlin';
const min = 60000;

void main() {
  final v = jsonDecode(File('test/vectors/defaultReminder.vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  group('defaultReminder.vectors.json (internal/defaultreminder agrees)', () {
    final userId = v['user_id'] as String;
    final taskId = v['task_id'] as String;
    final defaultId = v['default_id'] as String;
    String id(String s) => s == r'$default' ? defaultId : s;

    test('derives the id from the person and the task', () {
      expect(defaultReminderId(userId, taskId), defaultId);
      expect(defaultReminderId('u2', taskId), isNot(defaultId));
    });

    test('reads stored values', () {
      for (final p in (v['parse'] as List).cast<List>()) {
        expect(parseDefaultReminder(p[0]), p[1], reason: '${p[0]}');
      }
      expect(parseDefaultReminder(null), isNull);
      expect(formatDefaultReminder(-30), '-30');
      expect(formatDefaultReminder(null), '');
    });

    for (final c in (v['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final got = planDefaultReminder(DefaultReminderInput(
          userId: userId,
          taskId: taskId,
          before: (c['before'] as Map?)?.cast<String, Object?>(),
          patch: (c['patch'] as Map).cast<String, Object?>(),
          reminders: [
            for (final r in (c['reminders'] as List).cast<Map<String, dynamic>>()) {...r, 'id': id(r['id'] as String)},
          ],
          batch: [
            for (final b in (c['batch'] as List).cast<Map<String, dynamic>>())
              Change('reminder', id(b['id'] as String), (b['patch'] as Map).cast<String, Object?>()),
          ],
          prefs: readDefaultReminders((c['prefs'] as Map).cast<String, Object?>()),
          now: (v['now'] as num).toInt(),
          zone: 'UTC',
        ));
        expect(got.map((e) => e.toJson()).toList(), [
          for (final e in (c['expect'] as List).cast<Map<String, dynamic>>())
            {'entity': 'reminder', 'entityId': id(e['id'] as String), 'patch': e['patch']},
        ]);
      });
    }
  });

  group('firing times', () {
    test('relative: due plus offset; date-only at 09:00 local; zoned in its own zone', () {
      expect(relativeFireAt({'date': '2026-10-11', 'time': '15:00'}, -30, zone: berlin), utc(2026, 10, 11, 12, 30));
      expect(relativeFireAt(const Due('2026-10-11'), 0, zone: berlin), utc(2026, 10, 11, 7));
      expect(relativeFireAt(const Due('2026-10-11'), -1440, zone: 'America/New_York'), utc(2026, 10, 10, 13));
      expect(relativeFireAt(const Due('2026-10-11', time: '09:00', tz: berlin), 0, zone: 'Asia/Tokyo'), utc(2026, 10, 11, 7));
      expect(relativeFireAt(null, -30), isNull);
      expect(relativeFireAt({'date': ''}, -30), isNull);
    });

    test('deadline: 09:00 local on the deadline plus offset', () {
      expect(deadlineFireAt('2026-10-14', -1440, zone: berlin), utc(2026, 10, 13, 7));
      expect(deadlineFireAt(null, 0), isNull);
    });

    test('snooze choices', () {
      final now = utc(2026, 10, 11, 22, 30); // 00:30 on the 12th in Berlin
      expect(snoozeUntil(SnoozeChoice.tenMinutes, now), now + 10 * min);
      expect(snoozeUntil(SnoozeChoice.oneHour, now), now + 60 * min);
      expect(snoozeUntil(SnoozeChoice.tomorrow, now, zone: berlin), utc(2026, 10, 13, 7));
      expect(snoozeUntil(SnoozeChoice.tomorrow, now, zone: 'UTC'), utc(2026, 10, 12, 9));
    });
  });

  group('show rule and races', () {
    final task = <String, Object?>{'id': 't1', 'completed_at': null, 'deleted_at': null};
    final fire = utc(2026, 10, 11, 9);
    Map<String, Object?> rem([Map<String, Object?> extra = const {}]) =>
        {'id': 'r1', 'task_id': 't1', 'kind': 'relative', 'fire_at': fire, 'delivered_at': null, 'dismissed_at': null, 'deleted_at': null, ...extra};

    test('shown when fire_at <= now on a live task', () {
      expect(isReminderDue(rem(), task, fire - 1), isFalse);
      expect(isReminderDue(rem(), task, fire), isTrue);
      expect(isReminderDue(rem({'deleted_at': 1}), task, fire), isFalse);
      expect(isReminderDue(rem({'fire_at': null}), task, fire), isFalse);
      expect(isReminderDue(rem(), {...task, 'completed_at': 5}, fire), isFalse);
      expect(isReminderDue(rem(), {...task, 'deleted_at': 5}, fire), isFalse);
      expect(isReminderDue(rem(), null, fire), isFalse);
    });

    test('a dismissal of the current firing hides it; one of an earlier firing does not', () {
      expect(isReminderDue(rem({'dismissed_at': fire + 1}), task, fire + 2), isFalse);
      expect(isReminderDue(rem({'dismissed_at': fire - 1}), task, fire + 2), isTrue);
    });

    test('a snooze racing the server delivery still fires again', () {
      // Snooze to fire + 1h; the server's delivery op of the old firing (written
      // after the snooze reached this device, so it wins delivered_at) is older
      // than the new fire_at and does not count.
      final snoozed = {...rem(), ...snoozeReminderChange('r1', fire + 60 * min).patch, 'delivered_at': fire + 5};
      expect(isDelivered(snoozed), isFalse);
      expect(isReminderDue(snoozed, task, fire + 30 * min), isFalse);
      expect(isReminderDue(snoozed, task, fire + 60 * min), isTrue);
      expect(isDelivered(rem({'delivered_at': fire})), isTrue);
    });

    test('dismiss, rearm, delete', () {
      expect(dismissReminderChange('r1', 7).patch, {'dismissed_at': 7});
      expect(rearmReminderChange('r1').patch, {'dismissed_at': null});
      expect(deleteReminderChange('r1', 7).patch, {'deleted_at': 7});
      expect(snoozeReminderChange('r1', 9).patch, {'fire_at': 9, 'delivered_at': null, 'dismissed_at': null});
    });

    test('sortReminders: by fire_at, unset last, then created_at', () {
      final sorted = sortReminders([
        {'id': 'a', 'fire_at': null, 'created_at': 1},
        {'id': 'b', 'fire_at': 20, 'created_at': 2},
        {'id': 'c', 'fire_at': 10, 'created_at': 3},
        {'id': 'd', 'fire_at': 20, 'created_at': 1},
      ]);
      expect(sorted.map((r) => r['id']), ['c', 'd', 'b', 'a']);
    });
  });

  group('due moves', () {
    final reminders = <Map<String, Object?>>[
      {'id': 'rel', 'task_id': 't1', 'kind': 'relative', 'offset_minutes': -30, 'fire_at': utc(2026, 10, 11, 8, 30), 'delivered_at': utc(2026, 10, 11, 8, 30), 'dismissed_at': utc(2026, 10, 11, 8, 31), 'deleted_at': null},
      {'id': 'rel0', 'task_id': 't1', 'kind': 'relative', 'offset_minutes': null, 'fire_at': utc(2026, 10, 11, 9), 'delivered_at': null, 'dismissed_at': null, 'deleted_at': null},
      {'id': 'gone', 'task_id': 't1', 'kind': 'relative', 'offset_minutes': 0, 'fire_at': 1, 'delivered_at': null, 'dismissed_at': null, 'deleted_at': 5},
      {'id': 'abs', 'task_id': 't1', 'kind': 'absolute', 'offset_minutes': null, 'fire_at': 7, 'delivered_at': null, 'dismissed_at': null, 'deleted_at': null},
      {'id': 'dl', 'task_id': 't1', 'kind': 'deadline', 'offset_minutes': 0, 'fire_at': 9, 'delivered_at': null, 'dismissed_at': null, 'deleted_at': null},
    ];
    Iterable<Map<String, Object?>> of(String taskId) => taskId == 't1' ? reminders : const [];

    test('every live relative reminder follows the new due; moved firings clear delivery', () {
      final changes = [const Change('task', 't1', {'due': {'date': '2026-10-12', 'time': '09:00'}})];
      final ups = reminderFollowUps(changes, of, zone: 'UTC');
      expect(ups.map((c) => c.toJson()), [
        {'entity': 'reminder', 'entityId': 'rel', 'patch': {'fire_at': utc(2026, 10, 12, 8, 30), 'delivered_at': null, 'dismissed_at': null}},
        {'entity': 'reminder', 'entityId': 'rel0', 'patch': {'fire_at': utc(2026, 10, 12, 9)}},
      ]);
    });

    test('the follow-ups share the due op ts and device in one batch', () {
      final batch = withReminderFollowUps([const Change('task', 't1', {'due': {'date': '2026-10-12'}})], of, zone: 'UTC');
      var n = 0;
      final ops = changesToOps(batch, ts: 42, device: 'flutter:d1', newId: () => 'op${n++}');
      expect(ops.map((o) => '${o.entity}.${o.field}'), [
        'task.due', 'reminder.fire_at', 'reminder.delivered_at', 'reminder.dismissed_at', 'reminder.fire_at',
      ]);
      expect(ops.every((o) => o.ts == 42 && o.device == 'flutter:d1'), isTrue);
      expect(ops.map((o) => o.id).toSet().length, ops.length);
      expect(ops[1].value, utc(2026, 10, 12, 8, 30)); // date-only: 09:00 minus 30 min
    });

    test('clearing the due nulls fire_at', () {
      final ups = reminderFollowUps([const Change('task', 't1', {'due': null})], of);
      expect(ups.map((c) => c.patch['fire_at']), [null, null]);
    });

    test('a zoned due fires at its own instant', () {
      final ups = reminderFollowUps([const Change('task', 't1', {'due': {'date': '2026-10-12', 'time': '09:00', 'tz': berlin}})], of, zone: 'America/Los_Angeles');
      expect(ups.first.patch['fire_at'], utc(2026, 10, 12, 6, 30));
    });

    test('a deadline change moves deadline reminders only', () {
      final ups = reminderFollowUps([const Change('task', 't1', {'deadline': '2026-10-20'})], of, zone: 'UTC');
      expect(ups.map((c) => c.toJson()), [
        {'entity': 'reminder', 'entityId': 'dl', 'patch': {'fire_at': utc(2026, 10, 20, 9)}},
      ]);
    });

    test('a fire_at the batch already writes is kept', () {
      final ups = reminderFollowUps([
        const Change('task', 't1', {'due': {'date': '2026-10-12'}}),
        const Change('reminder', 'rel', {'fire_at': 123}),
      ], of);
      expect(ups.map((c) => c.entityId), ['rel0']);
    });

    test('unrelated task changes write nothing', () {
      expect(reminderFollowUps([const Change('task', 't1', {'title': 'x'})], of), isEmpty);
    });

    test('shared task due arriving from another member: recompute own reminders', () {
      final ops = [Op(id: 'o', entity: 'task', entityId: 't1', field: 'due', value: null, ts: 1, device: 'other')];
      final task = <String, Object?>{'id': 't1', 'project_id': 'p1', 'deleted_at': null, 'due': {'date': '2026-10-12'}, 'deadline': null};
      final shared = sharedDueFollowUps(ops, tasks: {'t1': task}, sharedProjects: {'p1'}, remindersOf: of, zone: 'UTC');
      expect(shared.map((c) => c.entityId), ['rel', 'rel0', 'dl']);
      expect(shared.first.patch, {'fire_at': utc(2026, 10, 12, 8, 30), 'delivered_at': null, 'dismissed_at': null});
      expect(shared.last.patch['fire_at'], isNull);
      expect(sharedDueFollowUps(ops, tasks: {'t1': task}, sharedProjects: const {}, remindersOf: of), isEmpty);
    });
  });

  group('reminder writes', () {
    final task = <String, Object?>{'id': 't1', 'due': {'date': '2026-10-11', 'time': '15:00'}, 'deadline': '2026-10-14', 'deleted_at': null};

    test('add relative, absolute, deadline and location reminders', () {
      final rel = addReminderChange(task, const RelativeReminder(-10), now: 5, id: 'r1', zone: 'UTC');
      expect(rel.patch, {
        'task_id': 't1', 'kind': 'relative', 'offset_minutes': -10, 'fire_at': utc(2026, 10, 11, 14, 50),
        'delivered_at': null, 'dismissed_at': null, 'created_at': 5, 'deleted_at': null,
      });
      expect(addReminderChange(task, const AbsoluteReminder(99), now: 5).patch['fire_at'], 99);
      expect(addReminderChange(task, const DeadlineReminder(0), now: 5, zone: 'UTC').patch['fire_at'], utc(2026, 10, 14, 9));
      final loc = addReminderChange(task, const LocationReminder('arrive', 200), now: 5).patch;
      expect([loc['radius_m'], loc['fire_at'], loc['offset_minutes']], [200, null, null]);
      expect(addReminderChange({'id': 't2', 'due': null}, const RelativeReminder(0), now: 5).patch['fire_at'], isNull);
    });

    test('refused input', () {
      expect(() => addReminderChange(null, const RelativeReminder(0), now: 5), throwsA(isA<ReminderError>()));
      expect(() => addReminderChange({...task, 'deleted_at': 1}, const RelativeReminder(0), now: 5), throwsA(isA<ReminderError>()));
      expect(() => addReminderChange(task, const AbsoluteReminder(0), now: 5), throwsA(isA<ReminderError>()));
      expect(() => addReminderChange(task, const LocationReminder('leave', 50), now: 5), throwsA(isA<ReminderError>()));
    });

    test('update clears delivery state only when the firing moves', () {
      final r = <String, Object?>{'id': 'r1', 'task_id': 't1', 'kind': 'relative', 'offset_minutes': -10, 'fire_at': utc(2026, 10, 11, 14, 50), 'radius_m': null, 'deleted_at': null};
      expect(updateReminderChange(r, task, const RelativeReminder(-10), zone: 'UTC').patch,
          {'kind': 'relative', 'offset_minutes': -10, 'fire_at': utc(2026, 10, 11, 14, 50)});
      expect(updateReminderChange(r, task, const RelativeReminder(-30), zone: 'UTC').patch,
          {'kind': 'relative', 'offset_minutes': -30, 'fire_at': utc(2026, 10, 11, 14, 30), 'delivered_at': null, 'dismissed_at': null});
    });
  });

  test('defaultReminderChanges reads the batch', () {
    final changes = [const Change('task', 't1', {'due': {'date': '2026-11-06', 'time': '15:00'}})];
    final out = defaultReminderChanges(changes,
        userId: 'u1',
        prefs: const DefaultReminders(timed: -30),
        taskRow: (_) => {'id': 't1', 'due': null, 'completed_at': null, 'deleted_at': null, 'habit': false},
        remindersOf: (_) => const [],
        now: 1,
        zone: 'UTC');
    expect(out.single.entityId, v['default_id']);
    expect(out.single.patch['fire_at'], 1793975400000);
    expect(defaultReminderChanges(changes, userId: null, prefs: const DefaultReminders(timed: -30), taskRow: (_) => null, remindersOf: (_) => const [], now: 1), isEmpty);
    expect(viewerZone(), 'UTC');
  });
}
