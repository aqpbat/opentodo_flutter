// Small date and zone helpers shared by inbox, urgency, today and upcoming.
//
// TODO(M2.1): use lib/domain/dates.dart. This file is a stop-gap written while
// M2.1 (dates and zoned due) was developed in parallel; the logic is ported from
// web/src/lib/dates.ts (zonedInstant, instantToLocalDue, localDueOf, compareDue,
// addDaysISO, daysBetweenISO, logicalDay). Once dates.dart lands, replace the
// bodies here with calls into it (or delete this file and update the imports).
//
// Time zones are injected: a [ZoneOffset] gives a zone's UTC offset at an instant,
// so the domain code never reads the device clock or a tz database itself.

/// The offset of IANA [zone] from UTC at instant [ms] (Unix milliseconds), in
/// milliseconds. Throws for a zone it does not know.
typedef ZoneOffset = int Function(int ms, String zone);

/// The default [ZoneOffset]: knows only UTC (and its aliases), throws otherwise.
int utcOnlyOffset(int ms, String zone) {
  if (zone == 'UTC' || zone == 'Etc/UTC' || zone == 'GMT' || zone == 'Etc/GMT') {
    return 0;
  }
  throw ArgumentError.value(zone, 'zone', 'unknown time zone');
}

const int _dayMs = 86400000;

/// JavaScript truthiness of a synced field (null, false, 0 and '' are unset).
bool truthy(Object? v) {
  if (v == null || v == false) return false;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

/// A stably sorted copy of [items] (JavaScript's Array.prototype.sort is stable,
/// Dart's List.sort is not guaranteed to be).
List<T> stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = [for (final (i, x) in items.indexed) (i, x)];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1 - b.$1;
  });
  return [for (final e in indexed) e.$2];
}

String _p(int n, [int w = 2]) => n.toString().padLeft(w, '0');

String _isoOf(DateTime utc) => '${_p(utc.year, 4)}-${_p(utc.month)}-${_p(utc.day)}';

DateTime _parseIso(String iso) {
  final parts = iso.split('-').map(int.parse).toList();
  return DateTime.utc(parts[0], parts[1], parts[2]);
}

/// `iso` plus [days] calendar days (both `YYYY-MM-DD`).
// ported from web/src/lib/dates.ts addDaysISO
String addDaysIso(String iso, int days) {
  final d = _parseIso(iso);
  return _isoOf(DateTime.utc(d.year, d.month, d.day + days));
}

/// Whole days from calendar date [from] to [to] (negative when [to] is earlier).
// ported from web/src/lib/dates.ts daysBetweenISO
int daysBetweenIso(String from, String to) =>
    (_parseIso(to).millisecondsSinceEpoch - _parseIso(from).millisecondsSinceEpoch) ~/ _dayMs;

/// The viewer's zone plus the offset source to read it: everything that turns an
/// instant or a zoned due into the viewer's wall date and time.
class ViewerZone {
  const ViewerZone(this.zone, {this.offsetOf = utcOnlyOffset});

  /// UTC with the UTC-only offset source.
  static const ViewerZone utc = ViewerZone('UTC');

  /// The viewer's IANA zone.
  final String zone;
  final ZoneOffset offsetOf;

  /// The wall date (`YYYY-MM-DD`) and time (`HH:MM`) of [ms] in [inZone]
  /// (the viewer's by default).
  // ported from web/src/lib/dates.ts instantToLocalDue
  ({String date, String time}) wallOf(int ms, [String? inZone]) {
    final z = inZone ?? zone;
    final w = DateTime.fromMillisecondsSinceEpoch(ms + offsetOf(ms, z), isUtc: true);
    return (date: _isoOf(w), time: '${_p(w.hour)}:${_p(w.minute)}');
  }

  /// The instant of wall time [date] [time] in [inZone]: a wall time in a gap
  /// resolves to the transition, one in an overlap to the earlier instant.
  // ported from web/src/lib/dates.ts zonedInstant
  int zonedInstant(String date, String time, String inZone) {
    final d = _parseIso(date);
    final hm = time.split(':').map(int.parse).toList();
    final wall = DateTime.utc(d.year, d.month, d.day, hm[0], hm[1]).millisecondsSinceEpoch;
    final before = offsetOf(wall - _dayMs, inZone);
    final after = offsetOf(wall + _dayMs, inZone);
    int? best;
    for (final o in [before, after]) {
      final c = wall - o;
      if (offsetOf(c, inZone) == o && (best == null || c < best)) best = c;
    }
    if (best != null) return best;
    var lo = wall - after;
    var hi = wall - before;
    while (hi - lo > 1000) {
      final mid = lo + ((hi - lo) ~/ 2000) * 1000;
      if (offsetOf(mid, inZone) == before) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
  }

  /// The due as seen by the viewer: a floating due as it is, a zoned one (time
  /// and tz) converted to the viewer's wall date and time without `tz`. A zone
  /// that cannot be resolved degrades to the stored wall date and time.
  // ported from web/src/lib/dates.ts localDueOf
  Map<String, dynamic>? localDueOf(Object? due) {
    if (due is! Map) return null;
    final date = due['date'];
    if (date is! String) return null;
    final time = due['time'];
    final tz = due['tz'];
    if (!truthy(tz) || !truthy(time)) return Map<String, dynamic>.from(due);
    try {
      final w = wallOf(zonedInstant(date, time as String, tz as String));
      return {'date': w.date, 'time': w.time};
    } catch (_) {
      return {'date': date, 'time': time};
    }
  }

  /// The due's calendar date in the viewer's zone, or null.
  String? localDate(Object? due) => localDueOf(due)?['date'] as String?;

  /// The due's wall time in the viewer's zone, or null for a date-only due.
  String? localTime(Object? due) {
    final t = localDueOf(due)?['time'];
    return t is String && t.isNotEmpty ? t : null;
  }

  /// The logical day of [ms]: its wall date, or the day before while the wall
  /// clock is before [dayStart] minutes after midnight.
  // ported from web/src/lib/urgency.ts logicalDayIn / dates.ts logicalDay
  String logicalDay(int ms, int dayStart) {
    final w = wallOf(ms);
    final hm = w.time.split(':').map(int.parse).toList();
    return dayStart > 0 && hm[0] * 60 + hm[1] < dayStart ? addDaysIso(w.date, -1) : w.date;
  }

  /// Orders dues by the viewer's date then time; a date-only due after the timed
  /// ones of its day, no due last.
  // ported from web/src/lib/dates.ts compareDue
  int compareDue(Object? a, Object? b) {
    final la = localDueOf(a);
    final lb = localDueOf(b);
    if (la == null && lb == null) return 0;
    if (la == null) return 1;
    if (lb == null) return -1;
    final da = la['date'] as String;
    final db = lb['date'] as String;
    if (da != db) return da.compareTo(db) < 0 ? -1 : 1;
    final ta = truthy(la['time']) ? la['time'] as String : '99:99';
    final tb = truthy(lb['time']) ? lb['time'] as String : '99:99';
    return ta.compareTo(tb).sign;
  }
}
