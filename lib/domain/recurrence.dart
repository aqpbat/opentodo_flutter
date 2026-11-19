// Recurrence rules: parser, canonical form, next-occurrence calculator and the
// projected-occurrence walk.
//
// ported from web/src/lib/recurrence.ts and web/src/lib/occurrences.ts
// (walkOccurrences, nextFree); Go: internal/recurrence. All three are checked
// against recurrence.vectors.json and occurrences.vectors.json (copied unchanged
// into test/vectors/). See docs/recurrence.md.
//
// Dates are floating YYYY-MM-DD strings. All arithmetic runs on proleptic
// Gregorian day numbers, never on DateTime, so results do not depend on the
// device's time zone or on daylight saving changes.

/// A rule longer than this is refused.
const int maxRuleLength = 200;
const int _maxInterval = 999;
const int _maxCount = 10000;

/// The pattern of a rule.
enum RuleKind {
  /// `every N days|weeks|months|years`.
  interval,

  /// `every weekday` (Monday to Friday).
  weekday,

  /// `every mon, wed`; with [Rule.interval] > 1 `every 2 weeks on saturday`.
  weekdays,

  /// `every 15th`.
  monthDay,

  /// `every last day`.
  lastDay,

  /// The ordinal-th Monday-to-Friday day of the month (`every 2nd weekday`).
  workday,

  /// `every 2nd tuesday`; with [Rule.month] a yearly rule
  /// (`every last sunday of march`).
  nthWeekday,
}

/// The interval unit of a [RuleKind.interval] rule.
enum RuleUnit { day, week, month, year }

/// A parsed recurrence rule. Immutable; use [copyWith] to change the end.
class Rule {
  final RuleKind kind;

  /// Interval count for [RuleKind.interval]; week interval for
  /// [RuleKind.weekdays] (1 for plain weekday lists). 0 otherwise.
  final int interval;

  /// Unit of a [RuleKind.interval] rule.
  final RuleUnit? unit;

  /// Weekday bit mask (bit 1 = Monday … bit 7 = Sunday) for
  /// [RuleKind.weekday] and [RuleKind.weekdays].
  final int days;

  /// Day of month (1–31) for [RuleKind.monthDay].
  final int monthDay;

  /// 1–4, or -1 for the last ([RuleKind.workday], [RuleKind.nthWeekday]).
  final int ordinal;

  /// ISO weekday (1 = Monday … 7 = Sunday) of [RuleKind.nthWeekday].
  final int weekday;

  /// Month (1–12) of a yearly [RuleKind.nthWeekday]; null when monthly.
  final int? month;

  /// `after completion` (interval rules only).
  final bool afterCompletion;

  /// `until YYYY-MM-DD`, or null.
  final String? until;

  /// `for N times`, 0 when absent.
  final int count;

  const Rule({
    required this.kind,
    this.interval = 0,
    this.unit,
    this.days = 0,
    this.monthDay = 0,
    this.ordinal = 0,
    this.weekday = 0,
    this.month,
    this.afterCompletion = false,
    this.until,
    this.count = 0,
  });

  /// A copy with another end condition (`until` / `count`) or week interval.
  Rule copyWith({
    String? until,
    bool clearUntil = false,
    int? count,
    int? interval,
    bool? afterCompletion,
  }) =>
      Rule(
        kind: kind,
        interval: interval ?? this.interval,
        unit: unit,
        days: days,
        monthDay: monthDay,
        ordinal: ordinal,
        weekday: weekday,
        month: month,
        afterCompletion: afterCompletion ?? this.afterCompletion,
        until: clearUntil ? null : (until ?? this.until),
        count: count ?? this.count,
      );

  /// The canonical text (the form to store).
  String get canonical => canonicalOf(this);

  @override
  String toString() => 'Rule($canonical)';
}

/// The outcome of [parseRule]: [rule] and [canonical] when [ok], else [error].
class ParseResult {
  final Rule? rule;
  final String? canonical;
  final String? error;
  const ParseResult._(this.rule, this.canonical, this.error);
  bool get ok => rule != null;
}

const List<String> _weekdayNames = [
  '', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday', //
];
const Map<String, int> _weekdayAliases = {
  'monday': 1, 'mon': 1, 'tuesday': 2, 'tue': 2, 'wednesday': 3, 'wed': 3, //
  'thursday': 4, 'thu': 4, 'friday': 5, 'fri': 5, 'saturday': 6, 'sat': 6,
  'sunday': 7, 'sun': 7,
};
const Map<String, int> _wordOrdinals = {
  'first': 1, 'second': 2, 'third': 3, 'fourth': 4, 'last': -1, //
};
const List<String> _monthNames = [
  '', 'january', 'february', 'march', 'april', 'may', 'june', 'july', //
  'august', 'september', 'october', 'november', 'december',
];
final Map<String, int> _monthAliases = () {
  final out = <String, int>{'sept': 9};
  for (var m = 1; m <= 12; m++) {
    out[_monthNames[m]] = m;
    out[_monthNames[m].substring(0, 3)] = m;
  }
  return out;
}();
const Map<String, RuleUnit> _units = {
  'day': RuleUnit.day, 'week': RuleUnit.week, 'month': RuleUnit.month, 'year': RuleUnit.year, //
};

/// `st`, `nd`, `rd` or `th` for n.
String ordinalSuffix(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return 'th';
  return n % 10 == 1
      ? 'st'
      : n % 10 == 2
          ? 'nd'
          : n % 10 == 3
              ? 'rd'
              : 'th';
}

final RegExp _numericOrdinalRe = RegExp(r'^([1-9][0-9]?)(st|nd|rd|th)$');
final RegExp _digitsRe = RegExp(r'^[0-9]+$');
final RegExp _positiveRe = RegExp(r'^[1-9][0-9]*$');
final RegExp _spaceRe = RegExp(r'\s+');

int? _numericOrdinal(String tok) {
  final m = _numericOrdinalRe.firstMatch(tok);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return n <= 31 && m.group(2) == ordinalSuffix(n) ? n : null;
}

int? _positiveInt(String? tok, int max) {
  if (tok == null || !_positiveRe.hasMatch(tok)) return null;
  final n = int.tryParse(tok);
  return n != null && n <= max ? n : null;
}

class _RuleError implements Exception {
  final String message;
  _RuleError(this.message);
}

/// Parse a rule; on success `canonical` is the form to store.
ParseResult parseRule(String input) {
  try {
    final rule = _Parser(input).parse();
    return ParseResult._(rule, canonicalOf(rule), null);
  } on _RuleError catch (e) {
    return ParseResult._(null, null, e.message);
  }
}

/// The canonical form of a valid rule, or null when it does not parse.
String? canonicalRule(String input) => parseRule(input).canonical;

class _Parser {
  final List<String> toks;
  int i = 1;

  _Parser(String input) : toks = _tokens(input) {
    if (input.length > maxRuleLength) {
      throw _RuleError('longer than $maxRuleLength characters');
    }
  }

  static List<String> _tokens(String input) => input
      .toLowerCase()
      .replaceAll(',', ' , ')
      .split(_spaceRe)
      .where((t) => t.isNotEmpty)
      .toList();

  String? peek([int k = 0]) => i + k < toks.length ? toks[i + k] : null;
  String? at(int j) => j < toks.length ? toks[j] : null;

  /// `name ((, | and | , and) name)*` from token i: the weekday mask.
  int weekdayList() {
    var days = 0;
    for (;;) {
      final item = peek();
      final wd = item == null ? null : _weekdayAliases[item];
      if (wd == null) throw _RuleError('expected a weekday, got "$item"');
      days |= 1 << wd;
      i++;
      var j = i;
      if (at(j) == ',') j++;
      if (at(j) == 'and') j++;
      if (j == i) return days;
      if (j >= toks.length) {
        throw _RuleError('expected a weekday after the list separator');
      }
      i = j;
    }
  }

  Rule parse() {
    if (toks.isEmpty || toks[0] != 'every') {
      throw _RuleError('must start with "every"');
    }
    final tok = peek();
    if (tok == null) throw _RuleError('missing pattern after "every"');
    Rule rule;
    if (_units.containsKey(tok)) {
      rule = Rule(kind: RuleKind.interval, interval: 1, unit: _units[tok]);
      i++;
      if (tok == 'week' && peek() == 'on') {
        i++;
        rule = Rule(kind: RuleKind.weekdays, days: weekdayList(), interval: 1);
      }
    } else if (tok == 'weekday' || tok == 'weekdays') {
      rule = const Rule(kind: RuleKind.weekday, days: 62); // 0b00111110
      i++;
    } else if (_digitsRe.hasMatch(tok)) {
      final n = _positiveInt(tok, _maxInterval);
      if (n == null) {
        throw _RuleError('interval must be from 1 to $_maxInterval');
      }
      final next = peek(1) ?? '';
      final singular = next.endsWith('s') ? next.substring(0, next.length - 1) : next;
      final unit = _units[singular];
      if (unit == null) {
        throw _RuleError('expected day(s), week(s), month(s) or year(s) after $tok');
      }
      rule = Rule(kind: RuleKind.interval, interval: n, unit: unit);
      i += 2;
      // every N weeks on <weekdays>.
      if (unit == RuleUnit.week && peek() == 'on') {
        i++;
        rule = Rule(kind: RuleKind.weekdays, days: weekdayList(), interval: n);
      }
    } else if (tok == 'last' && (peek(1) == 'day' || peek(1) == 'weekday')) {
      rule = peek(1) == 'day'
          ? const Rule(kind: RuleKind.lastDay)
          : const Rule(kind: RuleKind.workday, ordinal: -1);
      i += 2;
    } else if (_weekdayAliases.containsKey(tok)) {
      rule = Rule(kind: RuleKind.weekdays, days: weekdayList(), interval: 1);
    } else {
      rule = _ordinalPattern(tok);
    }
    if (peek() == 'after') {
      if (peek(1) != 'completion') {
        throw _RuleError('expected "completion" after "after"');
      }
      if (rule.kind != RuleKind.interval) {
        throw _RuleError('"after completion" only applies to day, week, month and year intervals');
      }
      rule = rule.copyWith(afterCompletion: true);
      i += 2;
    }
    if (peek() == 'until') {
      final d = peek(1);
      if (d == null || _dayNumber(d) == null) {
        throw _RuleError('until needs a date YYYY-MM-DD');
      }
      rule = rule.copyWith(until: d);
      i += 2;
    } else if (peek() == 'for') {
      final n = _positiveInt(peek(1), _maxCount);
      if (n == null || (peek(2) != 'times' && peek(2) != 'time')) {
        throw _RuleError('expected "for N times" with N from 1 to $_maxCount');
      }
      rule = rule.copyWith(count: n);
      i += 3;
    }
    if (i < toks.length) throw _RuleError('unexpected "${toks[i]}"');
    return rule;
  }

  /// `every 2nd`, `every first weekday`, `every last friday [of march]`.
  Rule _ordinalPattern(String tok) {
    final word = _wordOrdinals[tok];
    final num = _numericOrdinal(tok);
    if (word == null && num == null) throw _RuleError('unknown pattern "$tok"');
    final next = peek(1);
    if (next == 'weekday') {
      final ordinal = num ?? word ?? 0;
      if (ordinal > 4) throw _RuleError('weekday ordinal must be 1st to 4th or last');
      i += 2;
      return Rule(kind: RuleKind.workday, ordinal: ordinal);
    }
    if (next != null && _weekdayAliases.containsKey(next)) {
      final ordinal = num ?? word ?? 0;
      if (ordinal > 4) throw _RuleError('weekday ordinal must be 1st to 4th or last');
      i += 2;
      int? month;
      // `of <month>` (or `in <month>`) makes it yearly.
      final monthWord = peek(1) ?? '';
      if ((peek() == 'of' || peek() == 'in') && _monthAliases.containsKey(monthWord)) {
        month = _monthAliases[monthWord];
        i += 2;
      }
      return Rule(
        kind: RuleKind.nthWeekday,
        ordinal: ordinal,
        weekday: _weekdayAliases[next]!,
        month: month,
      );
    }
    if (num == null) throw _RuleError('expected a weekday after "$tok"');
    i++;
    return Rule(kind: RuleKind.monthDay, monthDay: num);
  }
}

String _ordinalWord(int ordinal) => ordinal < 0 ? 'last' : '$ordinal${ordinalSuffix(ordinal)}';

/// The canonical text of a parsed rule (Go: Rule.Canonical).
String canonicalOf(Rule r) {
  final s = StringBuffer('every ');
  switch (r.kind) {
    case RuleKind.interval:
      s.write(r.interval == 1 ? r.unit!.name : '${r.interval} ${r.unit!.name}s');
    case RuleKind.weekday:
      s.write('weekday');
    case RuleKind.weekdays:
      if (r.interval > 1) s.write('${r.interval} weeks on ');
      final names = <String>[];
      for (var wd = 1; wd <= 7; wd++) {
        if (r.days & (1 << wd) != 0) names.add(_weekdayNames[wd]);
      }
      s.write(names.join(', '));
    case RuleKind.monthDay:
      s.write('${r.monthDay}${ordinalSuffix(r.monthDay)}');
    case RuleKind.lastDay:
      s.write('last day');
    case RuleKind.workday:
      s.write('${_ordinalWord(r.ordinal)} weekday');
    case RuleKind.nthWeekday:
      s.write('${_ordinalWord(r.ordinal)} ${_weekdayNames[r.weekday]}');
      if (r.month != null) s.write(' of ${_monthNames[r.month!]}');
  }
  if (r.afterCompletion) s.write(' after completion');
  if (r.until != null) s.write(' until ${r.until}');
  if (r.count == 1) {
    s.write(' for 1 time');
  } else if (r.count > 1) {
    s.write(' for ${r.count} times');
  }
  return s.toString();
}

// ---- calendar arithmetic on day numbers (days since 1970-01-01) ----

int _fdiv(int a, int b) => (a / b).floor();

int _daysFromCivil(int y, int m, int d) {
  y -= m <= 2 ? 1 : 0;
  final era = _fdiv(y, 400);
  final yoe = y - era * 400;
  final doy = _fdiv(153 * (m > 2 ? m - 3 : m + 9) + 2, 5) + d - 1;
  final doe = yoe * 365 + _fdiv(yoe, 4) - _fdiv(yoe, 100) + doy;
  return era * 146097 + doe - 719468;
}

List<int> _civilFromDays(int z) {
  z += 719468;
  final era = _fdiv(z, 146097);
  final doe = z - era * 146097;
  final yoe = _fdiv(doe - _fdiv(doe, 1460) + _fdiv(doe, 36524) - _fdiv(doe, 146096), 365);
  final doy = doe - (365 * yoe + _fdiv(yoe, 4) - _fdiv(yoe, 100));
  final mp = _fdiv(5 * doy + 2, 153);
  final d = doy - _fdiv(153 * mp + 2, 5) + 1;
  final m = mp < 10 ? mp + 3 : mp - 9;
  return [yoe + era * 400 + (m <= 2 ? 1 : 0), m, d];
}

bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);

int _monthLen(int y, int m) {
  if (m == 2) return _isLeap(y) ? 29 : 28;
  return m == 4 || m == 6 || m == 9 || m == 11 ? 30 : 31;
}

/// ISO weekday, 1 = Monday … 7 = Sunday; day 0 (1970-01-01) was a Thursday.
int _isoWeekday(int z) => ((z % 7) + 7 + 3) % 7 + 1;

final RegExp _dateRe = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$');

/// Day number of a valid YYYY-MM-DD date, or null.
int? _dayNumber(String s) {
  final m = _dateRe.firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  if (mo < 1 || mo > 12 || d < 1 || d > _monthLen(y, mo)) return null;
  return _daysFromCivil(y, mo, d);
}

String _formatDate(int z) {
  final c = _civilFromDays(z);
  return '${c[0].toString().padLeft(4, '0')}-${c[1].toString().padLeft(2, '0')}-'
      '${c[2].toString().padLeft(2, '0')}';
}

int _mustDate(String s, String what) {
  final z = _dayNumber(s);
  if (z == null) {
    throw ArgumentError('recurrence: $what "$s" is not a valid YYYY-MM-DD date');
  }
  return z;
}

int _addMonths(int z, int n) {
  final c = _civilFromDays(z);
  final idx = c[0] * 12 + (c[1] - 1) + n;
  final ny = _fdiv(idx, 12);
  final nm = idx - ny * 12 + 1;
  final last = _monthLen(ny, nm);
  return _daysFromCivil(ny, nm, c[2] < last ? c[2] : last);
}

int _step(Rule r, int anchor, int k) {
  switch (r.unit!) {
    case RuleUnit.week:
      return anchor + 7 * r.interval * k;
    case RuleUnit.month:
      return _addMonths(anchor, r.interval * k);
    case RuleUnit.year:
      return _addMonths(anchor, 12 * r.interval * k);
    case RuleUnit.day:
      return anchor + r.interval * k;
  }
}

/// The ordinal-th Monday-to-Friday day of month m (1–4, or -1 for the last).
int _workdayOf(int y, int m, int ordinal) {
  if (ordinal < 0) {
    var z = _daysFromCivil(y, m, _monthLen(y, m));
    while (_isoWeekday(z) > 5) {
      z--;
    }
    return z;
  }
  var z = _daysFromCivil(y, m, 1) - 1;
  for (var n = 0; n < ordinal;) {
    z++;
    if (_isoWeekday(z) <= 5) n++;
  }
  return z;
}

int _nthWeekdayOf(int y, int m, int ordinal, int wd) {
  if (ordinal < 0) {
    final z = _daysFromCivil(y, m, _monthLen(y, m));
    return z - ((_isoWeekday(z) - wd + 7) % 7);
  }
  final first = _daysFromCivil(y, m, 1);
  return first + ((wd - _isoWeekday(first) + 7) % 7) + 7 * (ordinal - 1);
}

/// The date of the `ordinal`-th `weekday` (1 = Monday … 7 = Sunday) of month
/// `m` of year `y`, as YYYY-MM-DD; `ordinal` is 1–4, or -1 for the last.
String nthWeekdayDate(int y, int m, int ordinal, int weekday) =>
    _formatDate(_nthWeekdayOf(y, m, ordinal, weekday));

int _inMonth(Rule r, int y, int m) {
  switch (r.kind) {
    case RuleKind.monthDay:
      final last = _monthLen(y, m);
      return _daysFromCivil(y, m, r.monthDay < last ? r.monthDay : last);
    case RuleKind.lastDay:
      return _daysFromCivil(y, m, _monthLen(y, m));
    case RuleKind.workday:
      return _workdayOf(y, m, r.ordinal);
    case RuleKind.nthWeekday:
      return _nthWeekdayOf(y, m, r.ordinal, r.weekday);
    default:
      throw StateError('recurrence: not a month pattern');
  }
}

/// The Monday of z's ISO week.
int _weekStart(int z) => z - (_isoWeekday(z) - 1);

/// For `every N weeks on <days>`: the first of its days strictly after z in a
/// week a multiple of N weeks from anchor's ISO week (Go: Rule.inPhaseAfter).
int _inPhaseAfter(Rule r, int anchor, int z) {
  final a = _weekStart(anchor);
  for (var x = z + 1;;) {
    final rem = _fdiv(_weekStart(x) - a, 7) % r.interval;
    if (rem != 0) {
      x = _weekStart(x) + 7 * (r.interval - rem);
      continue;
    }
    if (r.days & (1 << _isoWeekday(x)) != 0) return x;
    x++;
  }
}

/// Whether `every N weeks on <days>` schedules [date], with [anchor] (the due
/// date) setting the week phase.
bool weeklyInPhase(Rule r, String anchor, String date) {
  final z = _mustDate(date, 'date');
  if (r.days & (1 << _isoWeekday(z)) == 0) return false;
  if (r.interval <= 1) return true;
  return _fdiv(_weekStart(z) - _weekStart(_mustDate(anchor, 'anchor')), 7) % r.interval == 0;
}

/// First date matching the pattern strictly after day z.
int _firstAfter(Rule r, int z) {
  switch (r.kind) {
    case RuleKind.interval:
      return _step(r, z, 1);
    case RuleKind.weekday:
    case RuleKind.weekdays:
      if (r.kind == RuleKind.weekdays && r.interval > 1) return _inPhaseAfter(r, z, z);
      for (var i = 1; i <= 7; i++) {
        if (r.days & (1 << _isoWeekday(z + i)) != 0) return z + i;
      }
      return z + 7;
    default:
      final c = _civilFromDays(z);
      final y = c[0], m = c[1];
      if (r.kind == RuleKind.nthWeekday && r.month != null) {
        final hit = _nthWeekdayOf(y, r.month!, r.ordinal, r.weekday);
        return hit > z ? hit : _nthWeekdayOf(y + 1, r.month!, r.ordinal, r.weekday);
      }
      final hit = _inMonth(r, y, m);
      if (hit > z) return hit;
      return m == 12 ? _inMonth(r, y + 1, 1) : _inMonth(r, y, m + 1);
  }
}

/// A rule as given, or parsed from its text (throws [ArgumentError] when the
/// text is not a rule).
Rule asRule(Object rule) {
  if (rule is Rule) return rule;
  final p = parseRule(rule as String);
  if (!p.ok) throw ArgumentError('recurrence: ${p.error}');
  return p.rule!;
}

/// Next occurrence of a calendar rule: the first match strictly after `due`,
/// or, when that is already before `today`, the first match strictly after
/// today (catch-up). Interval rules keep their phase while catching up.
/// No due = today. [rule] is a [Rule] or its text.
String nextCalendar(Object rule, String? due, String today) {
  final r = asRule(rule);
  final item = _mustDate(today, 'today');
  final d = due != null && due.isNotEmpty ? _mustDate(due, 'due') : item;
  var c = _firstAfter(r, d);
  if (c >= item) return _formatDate(c);
  if (r.kind == RuleKind.weekdays && r.interval > 1) return _formatDate(_inPhaseAfter(r, d, item));
  if (r.kind != RuleKind.interval) return _formatDate(_firstAfter(r, item));
  if (r.unit == RuleUnit.day || r.unit == RuleUnit.week) {
    final size = r.unit == RuleUnit.week ? 7 * r.interval : r.interval;
    return _formatDate(d + size * (_fdiv(item - d, size) + 1));
  }
  for (var k = 2;; k++) {
    c = _step(r, d, k);
    if (c > item) return _formatDate(c);
  }
}

/// Next occurrence of an interval rule counted from the local completion date.
String nextAfterCompletion(Object rule, String completedOn) {
  final r = asRule(rule);
  if (r.kind != RuleKind.interval) {
    throw ArgumentError('recurrence: only interval rules are completion-relative');
  }
  return _formatDate(_step(r, _mustDate(completedOn, 'completedOn'), 1));
}

/// What completing the current occurrence does: the next due date, or null
/// when the end condition is reached and the series completes like a plain
/// task. [done] is the number of occurrences already used (done and open
/// records); a negative value never reaches `for N times` (a skip).
String? followingOccurrence(Object rule, String? due, String today, String completedOn,
    [int done = 0]) {
  final r = asRule(rule);
  final next = r.afterCompletion ? nextAfterCompletion(r, completedOn) : nextCalendar(r, due, today);
  if (r.count > 0 && done + 1 >= r.count) return null;
  if (r.until != null && next.compareTo(r.until!) > 0) return null;
  return next;
}

/// First occurrence on or after `from`: the due date given to an undated task
/// that gets a rule.
String firstOccurrence(Object rule, String from) {
  final r = asRule(rule);
  final z = _mustDate(from, 'from');
  if (r.kind == RuleKind.interval) return from;
  // `every 2 weeks on saturday`: the nearest Saturday, which then sets the week phase.
  return _formatDate(_firstAfter(r.kind == RuleKind.weekdays ? r.copyWith(interval: 1) : r, z - 1));
}

/// The rule a writer stores for a task due on [due]: the form a 1.0 client
/// reads when one means the same thing. `every N weeks on <day>` whose due date
/// falls on that day is stored as `every N weeks`; anything else is stored in
/// canonical form. A rule that does not parse is returned as given.
/// Go: recurrence.Compatible.
String compatibleRule(String rule, String? due) {
  final p = parseRule(rule);
  if (!p.ok) return rule;
  final r = p.rule!;
  final z = due == null ? null : _dayNumber(due);
  if (r.kind != RuleKind.weekdays || r.interval <= 1 || z == null || r.days != 1 << _isoWeekday(z)) {
    return p.canonical!;
  }
  return canonicalOf(Rule(
    kind: RuleKind.interval,
    interval: r.interval,
    unit: RuleUnit.week,
    until: r.until,
    count: r.count,
  ));
}

/// Up to n occurrences that would follow the current one if each were
/// completed on time (calendar rules), or today and then on each due date
/// (completion-relative), stopping at the end condition.
List<String> previewOccurrences(Object rule, String? due, String today, [int done = 0, int n = 3]) {
  final r = asRule(rule);
  final out = <String>[];
  var cur = due;
  for (var i = 1; i <= n; i++) {
    final completedOn = r.afterCompletion && i > 1 && cur != null ? cur : today;
    final next = followingOccurrence(r, cur, today, completedOn, done + i - 1);
    if (next == null) break;
    out.add(next);
    cur = next;
  }
  return out;
}

/// `date` moved by as many calendar days as from `from` to `to`
/// (Go: recurrence.ShiftDate; web recurring.ts shiftDate). A series' deadline
/// and start move with its due date this way.
String shiftDate(String date, String from, String to) => _formatDate(
    _mustDate(date, 'date') + _mustDate(to, 'to') - _mustDate(from, 'from'));

// ---- projected occurrences (ported from web/src/lib/occurrences.ts) ----

/// Projections drawn per series per range at most.
const int maxProjections = 31;

/// The result of [walkOccurrences].
class OccurrenceWalk {
  /// Floating occurrence dates inside the range, at most `max`.
  final List<String> dates;

  /// True when the cap stopped the walk before the range ended.
  final bool capped;
  const OccurrenceWalk(this.dates, this.capped);
}

/// The walk shared with the server: from the current due, each next occurrence
/// as if every one were completed on time (calendar rules) or on its own day
/// (completion-relative rules; today for an overdue first step), counting
/// [taken] occurrences already used (done and open records) so `for N times`
/// stops it, and `until`. A date in [except] is an exception of the series:
/// never listed, and it uses up no occurrence. [local] maps a floating date to
/// the viewer's day it is compared with the range on (identity by default).
OccurrenceWalk walkOccurrences(
  Rule rule,
  String due,
  String today,
  int taken,
  String from,
  String to, {
  String Function(String date)? local,
  Set<String> except = const {},
  int max = maxProjections,
}) {
  final dates = <String>[];
  var cur = due;
  final gap = _mustDate(from, 'from') - _mustDate(cur, 'due');
  // The walk reaches `from` first; the guard stops a runaway rule after that.
  final limit = max + 1 + (gap < 0 ? 0 : (gap > 3700 ? 3700 : gap)) + except.length;
  var k = 0;
  for (var i = 0; i < limit; i++) {
    final completedOn = rule.afterCompletion ? (i == 0 && cur.compareTo(today) < 0 ? today : cur) : today;
    final next = followingOccurrence(rule, cur, today, completedOn, taken + k);
    if (next == null || next.compareTo(cur) <= 0) break;
    final seen = local == null ? next : local(next);
    if (seen.compareTo(to) > 0) break;
    cur = next;
    if (except.contains(next)) continue;
    k++;
    if (seen.compareTo(from) >= 0) {
      if (dates.length == max) return OccurrenceWalk(dates, true);
      dates.add(next);
    }
  }
  return OccurrenceWalk(dates, false);
}

/// The first occurrence after [due] that is not an exception date, as
/// completing the current one with [taken] occurrences already used does; null
/// when the end condition comes first (Go: recurrence.Rule.NextFree).
String? nextFree(Rule rule, String? due, String today, String completedOn, int taken, Set<String> except) {
  var next = followingOccurrence(rule, due, today, completedOn, taken);
  for (var i = 0; next != null && except.contains(next); i++) {
    if (i == 3700) return null;
    next = followingOccurrence(rule, next, today, rule.afterCompletion ? next : today, taken);
  }
  return next;
}
