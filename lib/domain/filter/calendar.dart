// Floating-date helpers, durations and time sectors the filter needs.
// ported from web/src/lib/filter/parse.ts (shiftISO, weekdayOf, monthStart,
// validISO), web/src/lib/time.ts (durationMinutes) and web/src/lib/sectors.ts.
//
// Kept inside the filter package on purpose: lib/domain/dates.dart is a separate
// module; nothing here depends on a time zone, every date is calendar arithmetic
// on UTC DateTimes so no DST shift can move a day.

/// `YYYY-MM-DD` of a UTC date.
String isoOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_pad(d.month)}-${_pad(d.day)}';

String _pad(int n) => n.toString().padLeft(2, '0');

(int, int, int) _ymd(String iso) {
  final parts = iso.split('-');
  return (int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

/// Add days to a floating YYYY-MM-DD date (calendar arithmetic, no time zone).
String shiftIso(String iso, int days) {
  final (y, m, d) = _ymd(iso);
  return isoOf(DateTime.utc(y, m, d + days));
}

/// Day of week of a floating date, 0 = Sunday.
int weekdayOfIso(String iso) {
  final (y, m, d) = _ymd(iso);
  return DateTime.utc(y, m, d).weekday % 7;
}

/// First day of the calendar month `months` away from the month of `iso`.
String monthStartIso(String iso, int months) {
  final (y, m, _) = _ymd(iso);
  return isoOf(DateTime.utc(y, m + months, 1));
}

/// Whether a `YYYY-MM-DD` string names a real calendar day.
bool validIso(String iso) {
  final (y, m, d) = _ymd(iso);
  final dt = DateTime.utc(y, m, d);
  return dt.year == y && dt.month == m && dt.day == d;
}

final RegExp isoDateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

// ---- durations (ported from web/src/lib/time.ts) ----

final RegExp _hours = RegExp(r'^(\d+(?:\.\d+)?)h(?:(\d{1,2})(?:m|min)?)?$');
final RegExp _minutes = RegExp(r'^(\d+)(?:m|min|mins|minutes)?$');

/// The longest typed duration: 100 days.
const int maxDuration = 144000;

/// A typed duration in minutes: 30m, 45min, 1h, 1h30, 1h30m, 1.5h or a bare
/// number of minutes; null otherwise.
int? durationMinutes(String input) {
  final t = input.trim().toLowerCase();
  var m = _hours.firstMatch(t);
  if (m != null) {
    final mins = m.group(2) != null ? int.parse(m.group(2)!) : 0;
    if (mins > 59) return null;
    final total = (double.parse(m.group(1)!) * 60 + mins).round();
    return total <= maxDuration ? total : null;
  }
  m = _minutes.firstMatch(t);
  if (m != null) {
    final n = num.parse(m.group(1)!);
    return n <= maxDuration ? n.toInt() : null;
  }
  return null;
}

// ---- time sectors (ported from web/src/lib/sectors.ts) ----

enum SectorKind { week, month, quarter }

/// A week (1–53), month (1–12) or quarter (1–4) of a year.
class SectorPeriod {
  const SectorPeriod(this.kind, this.year, this.n);
  final SectorKind kind;
  final int year;
  final int n;
}

/// The relative words a sector can be named with, in the planning list's order.
const List<String> sectorWords = [
  'this-week',
  'next-week',
  'this-month',
  'next-month',
  'this-quarter',
  'next-quarter',
];

final RegExp _sectorRe = RegExp(r'^(\d{4})-(?:W(\d{2})|(\d{2})|Q(\d))$');

/// ISO weekday: 1 Monday … 7 Sunday.
int _isoDow(String iso) {
  final (y, m, d) = _ymd(iso);
  return DateTime.utc(y, m, d).weekday;
}

/// The ISO week a date falls in.
({int year, int week}) isoWeekOf(String iso) {
  final thursday = shiftIso(iso, 4 - _isoDow(iso));
  final (y, m, d) = _ymd(thursday);
  final ms = DateTime.utc(y, m, d).millisecondsSinceEpoch;
  final jan1 = DateTime.utc(y, 1, 1).millisecondsSinceEpoch;
  return (year: y, week: ((ms - jan1) / 86400000 / 7).floor() + 1);
}

/// 52 or 53: the number of ISO weeks of a year.
int isoWeeksIn(int year) => isoWeekOf('$year-12-28').week;

/// A stored sector as a period, or null when empty or invalid (years 2000–2999).
SectorPeriod? parseSector(Object? value) {
  if (value is! String) return null;
  final m = _sectorRe.firstMatch(value);
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  if (year < 2000 || year > 2999) return null;
  if (m.group(2) != null) {
    final n = int.parse(m.group(2)!);
    return n >= 1 && n <= isoWeeksIn(year) ? SectorPeriod(SectorKind.week, year, n) : null;
  }
  if (m.group(3) != null) {
    final n = int.parse(m.group(3)!);
    return n >= 1 && n <= 12 ? SectorPeriod(SectorKind.month, year, n) : null;
  }
  final n = int.parse(m.group(4)!);
  return n >= 1 && n <= 4 ? SectorPeriod(SectorKind.quarter, year, n) : null;
}

/// Whether a value is a valid stored sector ('' is "none", not a sector).
bool isSector(Object? value) => parseSector(value) != null;

String formatPeriod(SectorPeriod p) => switch (p.kind) {
      SectorKind.week => '${p.year}-W${_pad(p.n)}',
      SectorKind.month => '${p.year}-${_pad(p.n)}',
      SectorKind.quarter => '${p.year}-Q${p.n}',
    };

SectorPeriod _nextOf(SectorPeriod p) {
  final max = switch (p.kind) {
    SectorKind.week => isoWeeksIn(p.year),
    SectorKind.month => 12,
    SectorKind.quarter => 4,
  };
  return p.n < max ? SectorPeriod(p.kind, p.year, p.n + 1) : SectorPeriod(p.kind, p.year + 1, 1);
}

/// The viewer's current periods: this week is the ISO week holding the Monday
/// inside the viewer's current week. `weekStart` is 0 (Sunday) to 6.
Map<String, String> currentPeriods(String localDate, [int weekStart = 1]) {
  final ws = ((weekStart % 7) + 7) % 7;
  final dow = _isoDow(localDate) % 7;
  final start = shiftIso(localDate, -((dow - ws + 7) % 7));
  final monday = shiftIso(start, (1 - ws + 7) % 7);
  final w = isoWeekOf(monday);
  final week = SectorPeriod(SectorKind.week, w.year, w.week);
  final year = int.parse(localDate.substring(0, 4));
  final monthN = int.parse(localDate.substring(5, 7));
  final month = SectorPeriod(SectorKind.month, year, monthN);
  final quarter = SectorPeriod(SectorKind.quarter, year, (monthN - 1) ~/ 3 + 1);
  return {
    'this-week': formatPeriod(week),
    'next-week': formatPeriod(_nextOf(week)),
    'this-month': formatPeriod(month),
    'next-month': formatPeriod(_nextOf(month)),
    'this-quarter': formatPeriod(quarter),
    'next-quarter': formatPeriod(_nextOf(quarter)),
  };
}

/// The sector a relative word means on the viewer's date, or null.
String? resolveSectorPhrase(String word, String localDate, [int weekStart = 1]) {
  final w = word.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
  return sectorWords.contains(w) ? currentPeriods(localDate, weekStart)[w] : null;
}

/// Carried over: the period ended before the viewer's current period of its kind.
bool isCarried(String sector, String localDate, [int weekStart = 1]) {
  final p = parseSector(sector);
  if (p == null) return false;
  final cur = currentPeriods(localDate, weekStart);
  final now = parseSector(cur['this-${p.kind.name}'])!;
  final c = p.year != now.year ? p.year - now.year : p.n - now.n;
  return c < 0;
}
