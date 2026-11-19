// A tiny rule-based ZoneOffset for tests: UTC, Europe/Berlin, America/New_York
// and America/Los_Angeles with the current EU and US daylight-saving rules. Enough
// for the shared vectors; the app plugs in a real tz database.
//
// TODO(M2.1): use the zone source of lib/domain/dates.dart once it lands.

const int _hour = 3600000;

int _utc(int y, int m, int d, [int h = 0]) => DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

/// Day of month of the [n]th (1-based) Sunday of month [m] of year [y].
int _nthSunday(int y, int m, int n) {
  final first = DateTime.utc(y, m, 1).weekday % 7; // 0 = Sunday
  return 1 + (7 - first) % 7 + 7 * (n - 1);
}

int _lastSunday(int y, int m) {
  final last = DateTime.utc(y, m + 1, 0);
  return last.day - last.weekday % 7;
}

int _eu(int ms, int std) {
  final y = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).year;
  final on = _utc(y, 3, _lastSunday(y, 3), 1);
  final off = _utc(y, 10, _lastSunday(y, 10), 1);
  return ms >= on && ms < off ? std + _hour : std;
}

int _us(int ms, int std) {
  final y = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).year;
  final on = _utc(y, 3, _nthSunday(y, 3, 2), 2) - std;
  final off = _utc(y, 11, _nthSunday(y, 11, 1), 2) - (std + _hour);
  return ms >= on && ms < off ? std + _hour : std;
}

/// The test [ZoneOffset] (see lib/domain/local_day.dart).
int testZoneOffset(int ms, String zone) {
  switch (zone) {
    case 'UTC':
      return 0;
    case 'Europe/Berlin':
      return _eu(ms, _hour);
    case 'America/New_York':
      return _us(ms, -5 * _hour);
    case 'America/Los_Angeles':
      return _us(ms, -8 * _hour);
  }
  throw ArgumentError.value(zone, 'zone', 'unknown time zone');
}
