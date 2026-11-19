// Shared zoned vectors (web/src/lib/zoned.vectors.json, copied unchanged) plus
// the behaviour cases of web/src/lib/dates.test.ts that do not depend on i18n.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/dates.dart';

const la = 'America/Los_Angeles';
const berlin = 'Europe/Berlin';

int utc(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

void main() {
  final vectors = jsonDecode(File('test/vectors/zoned.vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  group('zoned.vectors.json (internal/zoned agrees)', () {
    for (final v in (vectors['instant'] as List).cast<Map<String, dynamic>>()) {
      test('instant: ${v['note']}', () {
        final ms = zonedInstant(v['date'] as String, v['time'] as String, v['tz'] as String);
        expect(ms, DateTime.parse(v['utc'] as String).millisecondsSinceEpoch);
      });
    }
    for (final v in (vectors['local'] as List).cast<Map<String, dynamic>>()) {
      test('local: ${v['note']}', () {
        final ms = DateTime.parse(v['utc'] as String).millisecondsSinceEpoch;
        expect(instantToLocalDue(ms, v['zone'] as String),
            Due(v['date'] as String, time: v['time'] as String));
      });
    }
  });

  group('display in the viewer zone', () {
    const berlin9 = Due('2026-10-11', time: '09:00', tz: berlin);

    test('Berlin 09:00 seen from Los Angeles', () {
      expect(localDueOf(berlin9, la), const Due('2026-10-11', time: '00:00'));
    });

    test('Tokyo 02:00 on the 12th seen from Berlin crosses midnight', () {
      expect(localDueOf(const Due('2026-10-12', time: '02:00', tz: 'Asia/Tokyo'), berlin),
          const Due('2026-10-11', time: '19:00'));
    });

    test('floating dues are unchanged', () {
      const floating = Due('2026-10-11', time: '09:00');
      expect(identical(localDueOf(floating, la), floating), isTrue);
      expect(localDueOf(berlin9, berlin), const Due('2026-10-11', time: '09:00'));
    });

    test('spring-forward gap and autumn overlap', () {
      const gap = Due('2026-03-29', time: '02:30', tz: berlin);
      expect(localDueOf(gap, berlin), const Due('2026-03-29', time: '03:00'));
      expect(localDueOf(gap, 'Europe/London'), const Due('2026-03-29', time: '02:00'));
      const overlap = Due('2026-10-25', time: '02:30', tz: berlin);
      expect(dueToInstant(overlap), utc(2026, 10, 25, 0, 30));
      expect(localDueOf(overlap, 'UTC'), const Due('2026-10-25', time: '00:30'));
    });

    test('sorts a zoned 09:00 Berlin before a floating 08:00 from Los Angeles', () {
      const floating8 = Due('2026-10-11', time: '08:00');
      expect(compareDue(berlin9, floating8, la), -1);
      expect(compareDue(berlin9, floating8, berlin), 1);
      expect(compareDue(null, floating8), 1);
      expect(compareDue(const Due('2026-10-11'), floating8), 1);
    });

    test('floating dues resolve in the given zone', () {
      expect(dueToInstant(const Due('2026-10-11', time: '09:00'), zone: la), utc(2026, 10, 11, 16));
      expect(dueToInstant(const Due('2026-10-11'), zone: 'UTC'), utc(2026, 10, 11));
    });

    test('an unknown zone degrades to the floating reading', () {
      const odd = Due('2026-10-11', time: '09:00', tz: 'Mars/Olympus');
      expect(dueToInstant(odd, zone: 'UTC'), utc(2026, 10, 11, 9));
      expect(localDueOf(odd, la), const Due('2026-10-11', time: '09:00'));
    });

    test('dueTone', () {
      expect(dueTone(berlin9, today: '2026-10-11', zone: la), DueTone.today);
      expect(dueTone(const Due('2026-10-10'), today: '2026-10-11'), DueTone.overdue);
      expect(dueTone(const Due('2026-10-17'), today: '2026-10-11'), DueTone.soon);
      expect(dueTone(const Due('2026-10-18'), today: '2026-10-11'), DueTone.later);
      expect(dueTone(null), isNull);
    });
  });

  group('fix and release', () {
    test('fix keeps the shown time; date-only cannot be fixed', () {
      expect(fixDueToZone(const Due('2026-10-11', time: '09:00'), berlin),
          const Due('2026-10-11', time: '09:00', tz: berlin));
      const d = Due('2026-10-11');
      expect(identical(fixDueToZone(d, berlin), d), isTrue);
      expect(setDueZone(d, berlin), isNull);
      expect(setDueZone(const Due('2026-10-11', time: '09:00'), 'Nope/Zone'), isNull);
    });

    test('release in another zone keeps the displayed time', () {
      expect(releaseDue(const Due('2026-10-11', time: '09:00', tz: berlin), la),
          const Due('2026-10-11', time: '00:00'));
    });

    test('fix then release round-trips', () {
      for (final zone in [berlin, la, 'Asia/Kolkata']) {
        const d = Due('2026-03-08', time: '14:35');
        expect(releaseDue(fixDueToZone(d, zone), zone), d);
      }
    });

    test('editing a zoned due as displayed keeps its zone; clearing the time drops it', () {
      const berlin9 = Due('2026-10-11', time: '09:00', tz: berlin);
      expect(dueFromView(berlin9, const Due('2026-10-11', time: '01:00'), la),
          const Due('2026-10-11', time: '10:00', tz: berlin));
      expect(dueFromView(berlin9, const Due('2026-10-11'), la), const Due('2026-10-11'));
      expect(dueFromView(berlin9, null, la), isNull);
      expect(dueFromView(const Due('2026-10-11'), const Due('2026-10-12', time: '08:00'), la),
          const Due('2026-10-12', time: '08:00'));
    });
  });

  group('the logical day', () {
    const zurich = 'Europe/Zurich';
    int local(int y, int m, int d, int h, [int min = 0]) =>
        zonedInstant('$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}',
            '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}', zurich);

    test('before the day start the previous date', () {
      expect(logicalDay(local(2026, 10, 15, 1, 30), dayStart: 240, zone: zurich), '2026-10-14');
      expect(logicalDay(local(2026, 10, 15, 3, 59), dayStart: 240, zone: zurich), '2026-10-14');
      expect(logicalDay(local(2026, 10, 15, 4, 0), dayStart: 240, zone: zurich), '2026-10-15');
      expect(logicalDay(local(2026, 10, 15, 3, 29), dayStart: 210, zone: zurich), '2026-10-14');
      expect(logicalDay(local(2026, 10, 15, 3, 30), dayStart: 210, zone: zurich), '2026-10-15');
      expect(logicalDay(local(2026, 11, 1, 2), dayStart: 240, zone: zurich), '2026-10-31');
      expect(logicalDay(local(2027, 1, 1, 2), dayStart: 240, zone: zurich), '2026-12-31');
      expect(logicalDay(local(2028, 3, 1, 5), dayStart: 360, zone: zurich), '2028-02-29');
    });

    test('module state: viewer zone, day start and the clock', () {
      final savedClock = currentTimeMs;
      addTearDown(() {
        currentTimeMs = savedClock;
        setViewerZone('UTC');
        setDayStart(0);
      });
      currentTimeMs = () => utc(2026, 10, 15, 1, 30); // 03:30 in Zurich
      expect(setViewerZone(zurich), isTrue);
      expect(setViewerZone(zurich), isFalse);
      expect(setViewerZone('Not/AZone'), isFalse);
      expect(viewerZone(), zurich);
      expect(todayIso(), '2026-10-15');
      expect(logicalToday(), '2026-10-15');
      setDayStart(240);
      expect(currentDayStart(), 240);
      expect(logicalToday(), '2026-10-14');
      setDayStart(400);
      expect(currentDayStart(), 0);
    });

    test('readDayStart', () {
      const want = {'': 0, '00:00': 0, '04:00': 240, '03:30': 210, '06:00': 360, '06:01': 0, '09:00': 0, '4am': 0, '4:00': 0, '03:60': 0};
      want.forEach((pref, minutes) => expect(readDayStart(pref), minutes, reason: pref));
      expect(readDayStart(null), 0);
    });
  });

  group('calendar helpers', () {
    test('addDaysIso and daysBetweenIso', () {
      expect(addDaysIso('2026-03-28', 1), '2026-03-29');
      expect(addDaysIso('2026-12-31', 1), '2027-01-01');
      expect(addDaysIso('2028-03-01', -1), '2028-02-29');
      expect(daysBetweenIso('2026-10-11', '2026-10-18'), 7);
      expect(daysBetweenIso('2026-10-18', '2026-03-01'), -231);
    });

    test('week start and week days', () {
      // 2026-10-14 is a Wednesday.
      expect(weekdayOf('2026-10-14'), 3);
      expect(weekStartOf('2026-10-14'), '2026-10-12');
      expect(weekStartOf('2026-10-14', weekStart: 0), '2026-10-11');
      expect(weekStartOf('2026-10-14', weekStart: 6), '2026-10-10');
      expect(weekDays('2026-10-11').first, '2026-10-05');
      expect(readWeekStart('sun'), 0);
      expect(readWeekStart('system', system: 6), 6);
    });

    test('deadline countdown', () {
      final c = describeDeadline('2026-10-14', today: '2026-10-11')!;
      expect([c.days, c.tone], [3, DueTone.soon]);
      expect(describeDeadline('2026-10-11', today: '2026-10-11')!.tone, DueTone.overdue);
      expect(describeDeadline('2026-10-30', today: '2026-10-11')!.tone, DueTone.later);
      expect(describeDeadline('2026-10-30', today: '2026-10-11', dueDate: '2026-10-31')!.tone,
          DueTone.overdue);
      expect(describeDeadline(null), isNull);
    });

    test('quick choices', () {
      final due = quickChoices('due', today: '2026-10-14');
      expect(due.map((q) => q.date), ['2026-10-14', '2026-10-15', '2026-10-17', '2026-10-19']);
      final deadline = quickChoices('deadline', today: '2026-02-10');
      expect(deadline.map((q) => q.date), ['2026-02-15', '2026-02-28', '2026-02-24']);
    });

    test('due values', () {
      expect(Due.fromJson({'date': '2026-10-11', 'time': '09:00', 'tz': berlin}),
          const Due('2026-10-11', time: '09:00', tz: berlin));
      expect(Due.fromJson(null), isNull);
      expect(Due.fromJson({'date': ''}), isNull);
      expect(const Due('2026-10-11').toJson(), {'date': '2026-10-11'});
      expect(const Due('2026-02-29').isValid, isFalse);
      expect(const Due('2026-10-11', time: '24:00').isValid, isFalse);
      expect(const Due('2026-10-11', tz: berlin).isValid, isFalse);
      expect(const Due('2026-10-11', time: '09:00', tz: berlin).isValid, isTrue);
      expect(isKnownZone('Local'), isFalse);
      expect(isKnownZone('Asia/Calcutta'), isTrue);
    });
  });
}
