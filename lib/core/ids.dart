// Ids, ported from OpenTodo's web/src/lib/ids.ts (mirrors internal/ids).
// NameID: the first 16 bytes of SHA-256(ns + ":" + name), formatted as an
// RFC 9562 version 8 UUID, so devices deriving an id from the same inputs
// create the same entity (concurrent offline completions converge).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

final Random _random = Random.secure();

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _uuidFormat(Uint8List b) {
  final h = _hex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Deterministic UUID-formatted id for [name] within namespace [ns]
/// (same as Go ids.NameID and web nameId).
String nameId(String ns, String name) {
  final digest = c.sha256.convert(utf8.encode('$ns:$name')).bytes;
  final b = Uint8List.fromList(digest.sublist(0, 16));
  b[6] = (b[6] & 0x0f) | 0x80;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _uuidFormat(b);
}

/// Id of the completed occurrence record of [seriesId] for [date].
String occurrenceId(String seriesId, String date) =>
    nameId('occurrence', '$seriesId:$date');

/// Id of the piece a split of [seriesId] from [date] starts.
String pieceId(String seriesId, String date) =>
    nameId('series-split', '$seriesId:$date');

/// Id of the "this occurrence only" copy of [seriesId] for [date].
String detachedId(String seriesId, String date) =>
    nameId('occurrence', '$seriesId:detach:$date');

/// A random RFC 9562 version 4 UUID.
String uuid() {
  final b = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    b[i] = _random.nextInt(256);
  }
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  return _uuidFormat(b);
}
