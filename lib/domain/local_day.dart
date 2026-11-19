// The viewer's zone as one value the list functions (today, upcoming, urgency)
// take, plus two small helpers. Every zone computation delegates to
// lib/domain/dates.dart (the IANA database of the `timezone` package), so any
// real zone works; this file only adapts the stored `due` maps of task rows.
import 'dates.dart' as dates;

export 'dates.dart' show addDaysIso, daysBetweenIso;

/// The viewer's IANA zone, explicit so the domain functions never read module
/// state behind the caller's back. Reads stored `due` values (decoded JSON maps)
/// as [dates.Due].
class ViewerZone {
  const ViewerZone(this.zone);

  /// The zone the app last set (dates.viewerZone()).
  factory ViewerZone.current() => ViewerZone(dates.viewerZone());

  static const ViewerZone utc = ViewerZone('UTC');

  /// The viewer's IANA zone name.
  final String zone;

  /// The due as seen by the viewer (a zoned due converted to the viewer's wall
  /// date and time, without tz); null without a due.
  dates.Due? localDueOf(Object? due) => dates.localDueOf(dates.Due.fromJson(due), zone);

  /// The due's calendar date in the viewer's zone, or null.
  String? localDate(Object? due) => localDueOf(due)?.date;

  /// The due's wall time in the viewer's zone, or null for a date-only due.
  String? localTime(Object? due) => localDueOf(due)?.time;

  /// The logical day of [ms] in the viewer's zone with [dayStart] minutes.
  String logicalDay(int ms, int dayStart) => dates.logicalDay(ms, dayStart: dayStart, zone: zone);

  /// Orders stored dues by the viewer's date then time; no due last.
  int compareDue(Object? a, Object? b) =>
      dates.compareDue(dates.Due.fromJson(a), dates.Due.fromJson(b), zone);

  @override
  String toString() => 'ViewerZone($zone)';
}

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
