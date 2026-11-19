// The shared recurrence vectors of web/src/lib/recurrence.vectors.json and
// occurrences.vectors.json (copied unchanged): the same entries drive
// web/src/lib/recurrence.test.ts, occurrences.test.ts, recurrenceCompatible.test.ts
// and internal/recurrence (Go).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/domain/recurrence.dart';

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('test/vectors/$name').readAsStringSync()) as Map<String, dynamic>;

List<Map<String, dynamic>> _list(Map<String, dynamic> v, String key) =>
    (v[key] as List).cast<Map<String, dynamic>>();

// ---- the frozen 1.0 grammar (web/src/lib/testdata/recurrence-1.0.ts) ----
//
// The 1.0 parser is the current one without two forms: `every [N] week(s) on
// <weekdays>` and `<ordinal> <weekday> of|in <month>`. Every other branch and
// error is identical (compare the two files), so for an input the current
// parser accepts, 1.0 accepts it exactly when neither form was used.
bool _parse10(String input) {
  final r = parseRule(input);
  if (!r.ok) return false;
  if (r.rule!.kind == RuleKind.nthWeekday && r.rule!.month != null) return false;
  final toks = input.toLowerCase().replaceAll(',', ' , ').split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (toks.length > 2 && toks[1] == 'week' && toks[2] == 'on') return false;
  if (toks.length > 3 && RegExp(r'^[0-9]+$').hasMatch(toks[1]) && toks[3] == 'on') return false;
  return true;
}

// ported from web/src/lib/testdata/check10.ts
final _weeksOn = RegExp(r'^every ([0-9]+) weeks on ([a-z, ]+?)((?: until | for ).*)?$');
final _weekdayOfMonth = RegExp(r'^every (?:[1-4](?:st|nd|rd|th)|last) [a-z]+ of [a-z]+(?: until .*| for .*)?$');

/// Null when `rule`, stored for a task due on `due`, is fine: 1.0 reads it, or
/// no rule 1.0 reads gives the same dates. Otherwise why not.
String? check10(String rule, String? due) {
  if (_parse10(rule)) return null;
  final r = parseRule(rule);
  if (!r.ok) return '"$rule" is not a rule: ${r.error}';
  if (_weekdayOfMonth.hasMatch(r.canonical!)) return null;
  final m = _weeksOn.firstMatch(r.canonical!);
  if (m == null) return '"$rule" is not readable by 1.0 and not a form this check knows';
  final end = m.group(3) ?? '';
  final n = int.parse(m.group(1)!);
  for (final c in ['every $n weeks$end', 'every ${7 * n} days$end', 'every ${m.group(2)}$end']) {
    final old = parseRule(c);
    if (!old.ok || !_parse10(c)) continue;
    if (_sameDates(r.rule!, old.rule!, due)) {
      return '"$rule" is stored for a task due $due, but "$c", which 1.0 reads, gives the same dates';
    }
  }
  return null;
}

bool _sameDates(Rule a, Rule b, String? due) {
  var today = due ?? '2026-11-04';
  String? ca = due, cb = due;
  for (var i = 0; i < 60; i++) {
    String? na, nb;
    try {
      na = followingOccurrence(a, ca, today, today, i);
      nb = followingOccurrence(b, cb, today, today, i);
    } on ArgumentError {
      return false; // not a date: no dates to compare
    }
    if (na != nb) return false;
    if (na == null || nb == null) return true;
    ca = na;
    cb = nb;
    today = na;
  }
  return true;
}

void main() {
  final rv = _load('recurrence.vectors.json');
  final ov = _load('occurrences.vectors.json');

  group('recurrence.vectors.json parse', () {
    for (final v in _list(rv, 'parse')) {
      final input = v['input'] as String;
      test('parse ${jsonEncode(input)}', () {
        final r = parseRule(input);
        if (v['error'] == true) {
          expect(r.ok, isFalse, reason: r.canonical);
          return;
        }
        expect(r.ok, isTrue, reason: r.error);
        expect(r.canonical, v['canonical']);
        // The canonical form is a fixed point.
        expect(canonicalRule(v['canonical'] as String), v['canonical']);
      });
    }
  });

  group('recurrence.vectors.json next', () {
    for (final v in _list(rv, 'next')) {
      test(v['name'] as String, () {
        final today = v['today'] as String;
        expect(
          followingOccurrence(v['rule'] as String, v['due'] as String?, today,
              (v['completedOn'] as String?) ?? today, (v['done'] as num).toInt()),
          v['expected'],
        );
      });
    }
  });

  group('recurrence.vectors.json first', () {
    for (final v in _list(rv, 'first')) {
      test('${v['rule']} from ${v['from']}', () {
        expect(firstOccurrence(v['rule'] as String, v['from'] as String), v['expected']);
      });
    }
  });

  group('recurrence.vectors.json preview', () {
    for (final v in _list(rv, 'preview')) {
      test(v['name'] as String, () {
        expect(
          previewOccurrences(v['rule'] as String, v['due'] as String?, v['today'] as String,
              (v['done'] as num).toInt(), 3),
          (v['expected'] as List).cast<String>(),
        );
      });
    }
  });

  group('recurrence.vectors.json deadline', () {
    for (final v in _list(rv, 'deadline')) {
      test(v['name'] as String, () {
        expect(shiftDate(v['deadline'] as String, v['from'] as String, v['to'] as String), v['expected']);
      });
    }
  });

  group('recurrence.vectors.json compatible', () {
    for (final v in _list(rv, 'compatible')) {
      test(v['name'] as String, () {
        final got = compatibleRule(v['rule'] as String, v['due'] as String?);
        expect(got, v['expected']);
        if (parseRule(got).ok) expect(check10(got, v['due'] as String?), isNull);
      });
    }
  });

  group('occurrences.vectors.json cases', () {
    for (final v in _list(ov, 'cases')) {
      test(v['name'] as String, () {
        final rule = parseRule(v['rule'] as String).rule!;
        final walk = walkOccurrences(rule, v['due'] as String, v['today'] as String,
            (v['done'] as num).toInt(), v['from'] as String, v['to'] as String,
            except: ((v['exceptions'] as List?) ?? const []).cast<String>().toSet());
        expect(walk.dates, (v['dates'] as List).cast<String>());
        expect(walk.capped, v['capped']);
      });
    }
  });

  group('occurrences.vectors.json next', () {
    for (final v in _list(ov, 'next')) {
      test(v['name'] as String, () {
        final rule = parseRule(v['rule'] as String).rule!;
        final today = v['today'] as String;
        expect(
          nextFree(rule, v['due'] as String, today, today, (v['taken'] as num).toInt(),
              (v['exceptions'] as List).cast<String>().toSet()),
          v['next'],
        );
      });
    }
  });

  group('rules a 1.0 client reads', () {
    test('the 1.0 grammar reads the old forms and not the new ones', () {
      for (final rule in ['every 2 weeks', 'every saturday', 'every monday, friday for 3 times', 'every 2nd tuesday', 'every 3 days after completion']) {
        expect(_parse10(rule), isTrue, reason: rule);
      }
      for (final rule in ['every 2 weeks on saturday', 'every week on monday', 'every 3 weeks on monday, friday', 'every last sunday of march']) {
        expect(_parse10(rule), isFalse, reason: rule);
      }
    });

    test('check10 fails the new form where 1.0 has a rule with the same dates', () {
      expect(check10('every 2 weeks on saturday', '2026-11-07'), isNotNull);
      expect(check10('every 2 weeks on saturday', '2026-11-04'), isNull);
      expect(check10('every 2 weeks on saturday', null), isNull);
      expect(check10('every 3 weeks on monday, thursday', '2026-11-02'), isNull);
      expect(check10('every 2 weeks', '2026-11-07'), isNull);
    });
  });

  group('recurrence', () {
    test('shape of the vector files', () {
      expect(_list(rv, 'parse').length, greaterThan(50));
      expect(_list(rv, 'next').length, greaterThanOrEqualTo(60));
      expect(_list(ov, 'cases').any((v) => v['capped'] == true), isTrue);
    });

    test('rejects rules over the length limit', () {
      expect(parseRule('every day${' ' * maxRuleLength}').ok, isFalse);
      expect(parseRule('every blursday').error, isNotEmpty);
    });

    test('nthWeekdayDate', () {
      expect(nthWeekdayDate(2026, 3, 1, 1), '2026-03-02');
      expect(nthWeekdayDate(2027, 3, -1, 7), '2027-03-28');
    });

    test('weeklyInPhase', () {
      final r = parseRule('every 2 weeks on saturday').rule!;
      expect(weeklyInPhase(r, '2026-11-07', '2026-11-21'), isTrue);
      expect(weeklyInPhase(r, '2026-11-07', '2026-11-14'), isFalse);
      expect(weeklyInPhase(r, '2026-11-07', '2026-11-20'), isFalse);
    });

    test('invalid dates throw ArgumentError', () {
      expect(() => nextCalendar('every day', '2026-02-30', '2026-01-01'), throwsArgumentError);
      expect(() => followingOccurrence('every blursday', null, '2026-01-01', '2026-01-01'), throwsArgumentError);
    });
  });
}
