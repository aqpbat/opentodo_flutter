// The shared HLC vectors of web/src/lib/hlc.vectors.json (copied unchanged):
// the same steps drive web/src/lib/hlc.test.ts and the Go property test.
// 'at' is the server's time; the device's wall clock reads at + skew.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/hlc.dart';

void main() {
  final vectors = jsonDecode(File('test/vectors/hlc.vectors.json').readAsStringSync())
      as Map<String, dynamic>;

  group('hlc.vectors.json', () {
    for (final clock in (vectors['clocks'] as List).cast<Map<String, dynamic>>()) {
      test(clock['name'] as String, () {
        var skew = (clock['skew'] as num).toInt();
        var wall = 0;
        final hlc = Hlc(wallClock: () => wall);
        final steps = (clock['steps'] as List).cast<Map<String, dynamic>>();
        for (var i = 0; i < steps.length; i++) {
          final step = steps[i];
          if (step['skew'] != null) skew = (step['skew'] as num).toInt();
          if (step['at'] != null) wall = (step['at'] as num).toInt() + skew;
          final at = 'step $i (${step['do']})';
          switch (step['do']) {
            case 'stamp':
              expect(hlc.now(), step['want'], reason: at);
            case 'receive':
              hlc.receive((step['ts'] as num).toInt());
            case 'observe':
              hlc.observeServerTime((step['server'] as num?)?.toInt());
            case 'refused':
              hlc.clockRefused((step['server'] as num).toInt());
            default:
              fail('unknown step ${step['do']}');
          }
          expect(hlc.last, step['want_last'], reason: at);
          expect(hlc.offset, step['want_offset'], reason: at);
        }
      });
    }

    test('compares like the vectors', () {
      for (final c in (vectors['wins'] as List).cast<Map<String, dynamic>>()) {
        final existing = c['existing'] as Map<String, dynamic>?;
        expect(
          wins((c['ts'] as num).toInt(), c['device'] as String,
              existingTs: (existing?['ts'] as num?)?.toInt(),
              existingDevice: existing?['device'] as String?),
          c['want'],
          reason: jsonEncode(c),
        );
      }
    });
  });
}
