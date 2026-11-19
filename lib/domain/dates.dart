// Dates, the logical day and zoned due values.
//
// ported from web/src/lib/dates.ts (the pure parts: no i18n or Intl
// formatting, which belongs to the UI layer) and internal/zoned (Go), checked
// against the shared web/src/lib/zoned.vectors.json.
//
// Zone data comes from the `timezone` package (the IANA database embedded in
// Dart, like Go's time/tzdata), because Dart's DateTime only knows UTC and the
// device's local zone. The viewer's zone, the day start and "now" are module
// state the app sets (and tests override); every function also takes them as
// optional arguments.

import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// ---- module state (injectable) ----

/// Current time in Unix ms. Tests replace it; the app leaves the default.
int Function() currentTimeMs = () => DateTime.now().millisecondsSinceEpoch;

String _viewerZone = 'UTC';
int _dayStartMinutes = 0;

/// The viewer's IANA zone, as last set (`UTC` until the app sets the device zone).
String viewerZone() => _viewerZone;

/// Sets the viewer's zone (a travelling device). Returns true when it changed;
/// an unknown zone name is ignored (returns false).
bool setViewerZone(String zone) {
  if (zone == _viewerZone || !isKnownZone(zone)) return false;
  _viewerZone = zone;
  _localCache.clear();
  return true;
}

/// Sets the day start the helpers read by default (0 to 360 minutes after midnight).
void setDayStart(int minutes) {
  _dayStartMinutes = minutes > 0 && minutes <= 360 ? minutes : 0;
}

/// The day start in minutes after midnight (0 is midnight, the default).
int currentDayStart() => _dayStartMinutes;

/// The stored `user_prefs.day_start` as minutes after midnight: `HH:MM` from
/// 00:00 to 06:00; empty, malformed or out of range reads as 0.
/// ported from web/src/lib/userPrefs.ts readDayStart.
int readDayStart(Object? value) {
  final m = RegExp(r'^(\d{2}):([0-5]\d)$').firstMatch(value is String ? value : '');
  if (m == null) return 0;
  final minutes = int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  return minutes <= 360 ? minutes : 0;
}

/// The stored `user_prefs.week_start` as 0 = Sunday … 6 = Saturday;
/// `system` and unknown values read as [system].
int readWeekStart(Object? value, {int system = 1}) =>
    const {'sun': 0, 'mon': 1, 'sat': 6}[value] ?? system;

// ---- zone database ----

bool _tzReady = false;

void _ensureTz() {
  if (_tzReady) return;
  tzdata.initializeTimeZones();
  _tzReady = true;
}

/// Maximum length of a zone name in a due value (internal/zoned MaxZoneLen).
const int maxZoneLen = 64;

final Map<String, tz.Location> _locations = {};

/// The location of a zone name accepted in a due value; throws [ArgumentError]
/// for an unknown, empty or `Local` name (as internal/zoned Load).
tz.Location zoneLocation(String zone) {
  final cached = _locations[zone];
  if (cached != null) return cached;
  if (zone.isEmpty || zone.length > maxZoneLen || zone == 'Local') {
    throw ArgumentError.value(zone, 'zone', 'unknown time zone');
  }
  _ensureTz();
  final tz.Location loc;
  if (zone == 'UTC') {
    loc = tz.UTC;
  } else {
    try {
      loc = tz.getLocation(zone);
    } on tz.LocationNotFoundException {
      throw ArgumentError.value(zone, 'zone', 'unknown time zone');
    }
  }
  return _locations[zone] = loc;
}

/// True when `zone` is a known IANA zone name.
bool isKnownZone(String zone) {
  try {
    zoneLocation(zone);
    return true;
  } on ArgumentError {
    return false;
  }
}

// ---- calendar dates ----

String _p2(int n) => n.toString().padLeft(2, '0');
String _isoOf(int y, int m, int d) => '${y.toString().padLeft(4, '0')}-${_p2(m)}-${_p2(d)}';

final RegExp _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _timeRe = RegExp(r'^(\d{2}):(\d{2})$');

/// Whether `iso` is a `YYYY-MM-DD` date that exists.
bool isValidDate(String iso) {
  final m = _dateRe.firstMatch(iso);
  if (m == null) return false;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  final dt = DateTime.utc(y, mo, d);
  return dt.year == y && dt.month == mo && dt.day == d;
}

/// Whether `hhmm` is a wall time `HH:MM` from 00:00 to 23:59.
bool isValidTime(String hhmm) {
  final m = _timeRe.firstMatch(hhmm);
  return m != null && int.parse(m.group(1)!) < 24 && int.parse(m.group(2)!) < 60;
}

List<int> _ymd(String iso) {
  final parts = iso.split('-');
  if (parts.length < 3) throw FormatException('invalid date', iso);
  return [int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2])];
}

/// The calendar date `days` after `iso` (negative goes back).
String addDaysIso(String iso, int days) {
  final [y, m, d] = _ymd(iso);
  final dt = DateTime.utc(y, m, d + days);
  return _isoOf(dt.year, dt.month, dt.day);
}

/// Whole days from calendar date `from` to `to` (negative when `to` is earlier).
int daysBetweenIso(String from, String to) {
  DateTime u(String iso) {
    final [y, m, d] = _ymd(iso);
    return DateTime.utc(y, m, d);
  }

  return u(to).difference(u(from)).inDays;
}

/// Day of the week of a calendar date, 0 = Sunday … 6 = Saturday.
int weekdayOf(String iso) {
  final [y, m, d] = _ymd(iso);
  return DateTime.utc(y, m, d).weekday % 7;
}

/// Wall-clock components [y, m, d, hh, mm, ss] of an instant in `zone`.
List<int> _wallOf(int ms, String zone) {
  final t = tz.TZDateTime.fromMillisecondsSinceEpoch(zoneLocation(zone), ms);
  return [t.year, t.month, t.day, t.hour, t.minute, t.second];
}

/// The calendar date (`YYYY-MM-DD`) of an instant in `zone` (the viewer's by default).
String todayIso([int? ms, String? zone]) {
  final w = _wallOf(ms ?? currentTimeMs(), zone ?? _viewerZone);
  return _isoOf(w[0], w[1], w[2]);
}

/// The logical day an instant belongs to: its calendar date in `zone`, or the
/// previous date while its wall time is before `dayStart` minutes after
/// midnight. Compares the wall clock, so on a daylight-saving night the boundary
/// stays at the stated local time (same rule as internal/digest LogicalDay).
String logicalDay(int ms, {int? dayStart, String? zone}) {
  final start = dayStart ?? _dayStartMinutes;
  final w = _wallOf(ms, zone ?? _viewerZone);
  final iso = _isoOf(w[0], w[1], w[2]);
  return start > 0 && w[3] * 60 + w[4] < start ? addDaysIso(iso, -1) : iso;
}

/// The logical today: the day the person is living in now (see [logicalDay]).
String logicalToday({int? dayStart, int? now, String? zone}) =>
    logicalDay(now ?? currentTimeMs(), dayStart: dayStart, zone: zone);

/// The first day of the week that contains `iso`; `weekStart` 0 = Sunday … 6 = Saturday.
String weekStartOf(String iso, {int weekStart = 1}) {
  final back = (weekdayOf(iso) - weekStart + 7) % 7;
  return addDaysIso(iso, -back);
}

/// The seven days of the week that contains `iso`, from the preferred first day.
List<String> weekDays(String iso, {int weekStart = 1}) {
  final start = weekStartOf(iso, weekStart: weekStart);
  return [for (var i = 0; i < 7; i++) addDaysIso(start, i)];
}

// ---- due values ----

/// A task's `due` value (docs/sync.md §Schema): a calendar date, an optional
/// wall time and, only together with the time, an IANA zone that makes it zoned.
class Due {
  final String date;
  final String? time;
  final String? tz;

  const Due(this.date, {this.time, this.tz});

  /// Reads a stored `due` (decoded JSON); null for null, a non-object or an empty date.
  /// Unknown members are dropped; empty `time`/`tz` read as absent.
  static Due? fromJson(Object? v) {
    if (v is Due) return v;
    if (v is! Map) return null;
    final date = v['date'];
    if (date is! String || date.isEmpty) return null;
    final time = v['time'];
    final zone = v['tz'];
    return Due(
      date,
      time: time is String && time.isNotEmpty ? time : null,
      tz: zone is String && zone.isNotEmpty ? zone : null,
    );
  }

  /// The stored shape: `{"date"}`, `{"date","time"}` or `{"date","time","tz"}`.
  Map<String, Object?> toJson() => {
        'date': date,
        if (time != null) 'time': time,
        if (tz != null) 'tz': tz,
      };

  /// Whether this is a value the server accepts: the date exists, the time is
  /// 00:00–23:59, and `tz` (a known zone) only together with `time`.
  bool get isValid =>
      isValidDate(date) &&
      (time == null || isValidTime(time!)) &&
      (tz == null || (time != null && isKnownZone(tz!)));

  @override
  bool operator ==(Object other) =>
      other is Due && other.date == date && other.time == time && other.tz == tz;

  @override
  int get hashCode => Object.hash(date, time, tz);

  @override
  String toString() => 'Due(${toJson()})';
}

/// Whether a due is zoned (has a time and a zone).
bool isZoned(Due? due) => due != null && due.tz != null && due.time != null;

/// The instant (Unix ms) of wall time `date` `time` in `zone`: a wall time in a
/// spring-forward gap resolves to the transition (the first valid instant after
/// it), one in an autumn overlap to its first occurrence. Throws [ArgumentError]
/// for an unknown zone and [FormatException] for a malformed date or time.
int zonedInstant(String date, String time, String zone) {
  final loc = zoneLocation(zone);
  final [y, mo, d] = _ymd(date);
  final hm = time.split(':');
  if (hm.length < 2) throw FormatException('invalid time', time);
  final wall = DateTime.utc(y, mo, d, int.parse(hm[0]), int.parse(hm[1])).millisecondsSinceEpoch;
  int offsetAt(int ms) => loc.timeZone(ms).offset.inMilliseconds;
  const day = Duration.millisecondsPerDay;
  final before = offsetAt(wall - day);
  final after = offsetAt(wall + day);
  int? best;
  for (final o in [before, after]) {
    final c = wall - o;
    if (offsetAt(c) == o && (best == null || c < best)) best = c;
  }
  if (best != null) return best;
  // Gap: wall - before lies after the transition; the transition itself is the
  // first valid instant after the missing wall times (Go: ZoneBounds start).
  final guess = wall - before;
  final start = loc.lookupTimeZone(guess).start;
  return start > -8640000000000000 ? start : guess;
}

/// The wall date and time of an instant in `zone` (the viewer's by default), as a floating due.
Due instantToLocalDue(int ms, [String? zone]) {
  final w = _wallOf(ms, zone ?? _viewerZone);
  return Due(_isoOf(w[0], w[1], w[2]), time: '${_p2(w[3])}:${_p2(w[4])}');
}

/// The instant a due denotes: a zoned due in its own zone; a floating one read
/// in `zone` (the viewer's by default), at `fallbackTime` when it has no time.
int dueToInstant(Due due, {String? zone, String fallbackTime = '00:00'}) {
  if (isZoned(due)) {
    try {
      return zonedInstant(due.date, due.time!, due.tz!);
    } on ArgumentError {
      // A zone this device does not know: degrade to the floating reading.
    }
  }
  return zonedInstant(due.date, due.time ?? fallbackTime, zone ?? _viewerZone);
}

final Map<String, Due> _localCache = {};

/// The due as seen in `zone` (the viewer's by default): the same value for a
/// floating due, the converted wall date and time (no `tz`) for a zoned one.
/// Used for every list, heading, sort order and grouping.
Due? localDueOf(Due? due, [String? zone]) {
  if (due == null) return null;
  if (!isZoned(due)) return due;
  final z = zone ?? _viewerZone;
  final key = '${due.date} ${due.time} ${due.tz} $z';
  var out = _localCache[key];
  if (out == null) {
    try {
      out = instantToLocalDue(zonedInstant(due.date, due.time!, due.tz!), z);
    } on ArgumentError {
      out = Due(due.date, time: due.time);
    }
    if (_localCache.length > 5000) _localCache.clear();
    _localCache[key] = out;
  }
  return out;
}

/// The due's calendar date in `zone` (the viewer's by default), or null.
String? localDate(Due? due, [String? zone]) => localDueOf(due, zone)?.date;

/// `Berlin`, `Los Angeles`, `UTC`: the readable part of a zone name.
String zoneCity(String zone) => zone.substring(zone.lastIndexOf('/') + 1).replaceAll('_', ' ');

/// Fix a timed floating due to `zone` (the viewer's), keeping what is displayed.
Due fixDueToZone(Due due, [String? zone]) {
  if (due.time == null || due.tz != null) return due;
  return Due(due.date, time: due.time, tz: zone ?? _viewerZone);
}

/// Fix a timed due to any IANA `zone`, keeping its stored wall date and time.
/// Null when the due has no time or the zone is unknown (the caller writes nothing).
Due? setDueZone(Due due, String zone) {
  if (due.time == null || !isKnownZone(zone)) return null;
  return Due(due.date, time: due.time, tz: zone);
}

/// Release a zoned due to a floating one at the date and time displayed in `zone`.
Due releaseDue(Due due, [String? zone]) {
  if (due.tz == null) return due;
  final l = localDueOf(due, zone)!;
  return Due(l.date, time: l.time);
}

/// The value to store when the user edits a due as displayed: `view` is in the
/// viewer's zone. A zoned original stays fixed to its zone (the edited wall time
/// is converted back into it); without a time the zone is dropped.
Due? dueFromView(Due? original, Due? view, [String? zone]) {
  if (view == null) return null;
  if (original?.tz == null) return view;
  if (view.time == null) return Due(view.date);
  try {
    final at = zonedInstant(view.date, view.time!, zone ?? _viewerZone);
    final l = instantToLocalDue(at, original!.tz);
    return Due(l.date, time: l.time, tz: original.tz);
  } on ArgumentError {
    return Due(view.date, time: view.time);
  }
}

/// Order of two dues as seen in `zone`: by date, then time (a date-only due
/// after the timed ones of its day); null sorts last.
int compareDue(Due? a, Due? b, [String? zone]) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  final la = localDueOf(a, zone)!;
  final lb = localDueOf(b, zone)!;
  final byDate = la.date.compareTo(lb.date);
  if (byDate != 0) return byDate.sign;
  return (la.time ?? '99:99').compareTo(lb.time ?? '99:99').sign;
}

/// The tone of a due relative to the logical today (the non-text part of
/// describeDue in dates.ts).
enum DueTone { overdue, today, soon, later }

/// `overdue` before today, `today`, `soon` from tomorrow to six days ahead,
/// `later` after; null without a due. Compared in `zone` (the viewer's).
DueTone? dueTone(Due? due, {String? today, String? zone}) {
  if (due == null) return null;
  final t = today ?? logicalToday(zone: zone);
  final d = localDueOf(due, zone)!.date;
  if (d.compareTo(t) < 0) return DueTone.overdue;
  if (d == t) return DueTone.today;
  if (d.compareTo(addDaysIso(t, 7)) < 0) return DueTone.soon;
  return DueTone.later;
}

/// The countdown of a deadline: `days` from today (negative after it) and its tone.
class DeadlineCountdown {
  final int days;

  /// `overdue`, `soon` or `later` (never `today`).
  final DueTone tone;
  const DeadlineCountdown(this.days, this.tone);
}

/// Tone `later` beyond seven days, `soon` within seven, `overdue` on the day
/// and after, and also when the task is planned (`dueDate`, a local date) after
/// its deadline. Null without a deadline.
DeadlineCountdown? describeDeadline(String? deadline, {String? today, String? dueDate}) {
  if (deadline == null || deadline.isEmpty) return null;
  final days = daysBetweenIso(today ?? logicalToday(), deadline);
  final late = days <= 0 || (dueDate != null && dueDate.compareTo(deadline) > 0);
  return DeadlineCountdown(days, late ? DueTone.overdue : (days <= 7 ? DueTone.soon : DueTone.later));
}

/// One quick choice of the When popover: an id and the date it means
/// (`'someday'` for Someday). Labels are the UI's.
class QuickChoice {
  final String id;
  final String date;
  const QuickChoice(this.id, this.date);
}

/// The quick choices of a date segment (`due`, `start` or `deadline`), weeks
/// following `weekStart` (0 = Sunday).
List<QuickChoice> quickChoices(String kind, {String? today, int weekStart = 1}) {
  final t = today ?? logicalToday();
  final ws = weekStartOf(t, weekStart: weekStart);
  final nextWeek = addDaysIso(ws, 7);
  final dow = weekdayOf(t);
  final weekend = dow == 6 || dow == 0 ? t : addDaysIso(t, 6 - dow);
  final [y, m, _] = _ymd(t);
  final endOfMonth = _isoOf(y, m, DateTime.utc(y, m + 1, 0).day);
  switch (kind) {
    case 'due':
      return [
        QuickChoice('today', t),
        QuickChoice('tomorrow', addDaysIso(t, 1)),
        QuickChoice('weekend', weekend),
        QuickChoice('next-week', nextWeek),
      ];
    case 'start':
      return [
        QuickChoice('today', t),
        QuickChoice('tomorrow', addDaysIso(t, 1)),
        QuickChoice('next-week', nextWeek),
        const QuickChoice('someday', 'someday'),
      ];
    case 'deadline':
      return [
        QuickChoice('end-of-week', addDaysIso(ws, 6)),
        QuickChoice('end-of-month', endOfMonth),
        QuickChoice('two-weeks', addDaysIso(t, 14)),
      ];
  }
  throw ArgumentError.value(kind, 'kind');
}
