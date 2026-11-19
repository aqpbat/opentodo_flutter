import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/ids.dart';

void main() {
  group('nameId', () {
    // Expected values computed independently (Python hashlib, same algorithm
    // as Go ids.NameID): SHA-256(ns:name), first 16 bytes, UUID v8 bits.
    test('occurrence id matches the independent computation', () {
      expect(occurrenceId('series-1', '2026-11-19'),
          '055b9592-5172-850d-b20c-8afd882b6624');
    });
    test('piece id matches the independent computation', () {
      expect(pieceId('series-1', '2026-11-19'),
          'a6a139e0-bc19-8d86-bf8b-2f4f34cfd6aa');
    });
    test('daily note id matches the independent computation', () {
      expect(nameId('daily-note', 'user-1:2026-11-19'),
          '1cdc11ea-f73e-8e7f-a3db-226171b3c501');
    });
    test('same inputs give the same id on every call', () {
      expect(occurrenceId('s', '2026-01-01'), occurrenceId('s', '2026-01-01'));
      expect(occurrenceId('s', '2026-01-01'),
          isNot(occurrenceId('s', '2026-01-02')));
    });
    test('version 8 and variant bits are set', () {
      final id = nameId('x', 'y');
      expect(id[14], '8');
      expect(['8', '9', 'a', 'b'], contains(id[19]));
    });
  });

  group('uuid', () {
    test('is a version 4 UUID', () {
      final id = uuid();
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(id), true);
    });
    test('is unique', () {
      final ids = List.generate(1000, (_) => uuid()).toSet();
      expect(ids.length, 1000);
    });
  });
}
