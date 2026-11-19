import 'package:flutter_test/flutter_test.dart';
import 'package:opentodo_flutter/core/hlc.dart';

void main() {
  group('Hlc', () {
    test('stamps strictly increase even when the wall clock jumps back', () {
      var wall = 1000;
      final hlc = Hlc(wallClock: () => wall);
      expect(hlc.now(), 1000);
      expect(hlc.now(), 1001);
      wall = 500; // clock jumped backwards
      expect(hlc.now(), 1002);
      wall = 2000;
      expect(hlc.now(), 2000);
      expect(hlc.now(), 2001);
    });

    test('seed keeps a restart from reusing a timestamp', () {
      final hlc = Hlc(wallClock: () => 1000);
      hlc.seed(5000);
      expect(hlc.now(), 5001);
    });

    test('receive moves past the newest seen op', () {
      final hlc = Hlc(wallClock: () => 1000);
      hlc.receive(9000);
      expect(hlc.now(), 9001);
      hlc.receive(500); // older, ignored
      expect(hlc.now(), 9002);
    });

    test('small skew is tolerated, large skew is corrected', () {
      var wall = 10000;
      final hlc = Hlc(wallClock: () => wall);
      hlc.observeServerTime(11000); // 1 s skew: within tolerance
      expect(hlc.offset, 0);
      hlc.observeServerTime(20000); // 10 s skew: corrected
      expect(hlc.offset, 10000);
      expect(hlc.now(), 20000);
      wall = 20000; // local clock caught up
      hlc.observeServerTime(20000);
      expect(hlc.offset, 0);
    });

    test('a seed far ahead of the server is brought back', () {
      final hlc = Hlc(wallClock: () => 1000);
      hlc.seed(1000 + maxFutureSkewMs + 5000);
      hlc.observeServerTime(1000);
      expect(hlc.last, 1000);
    });

    test('clockRefused restarts only when far ahead', () {
      final hlc = Hlc(wallClock: () => 1000);
      hlc.seed(1000 + maxFutureSkewMs); // a full window ahead
      hlc.clockRefused(1000);
      expect(hlc.last, 1000); // more than half the window: restart

      final hlc2 = Hlc(wallClock: () => 1000);
      hlc2.seed(1000 + 60000); // one minute ahead: less than half the window
      hlc2.clockRefused(1000);
      expect(hlc2.last, 1000 + 60000); // keeps its stamps
    });

    test('seedOffset corrects stamps before the first sync', () {
      final hlc = Hlc(wallClock: () => 1000);
      hlc.seedOffset(5000);
      expect(hlc.now(), 6000);
    });
  });

  group('wins', () {
    test('no existing value always wins', () {
      expect(wins(1, 'a'), true);
    });
    test('greater ts wins', () {
      expect(wins(2, 'a', existingTs: 1, existingDevice: 'z'), true);
      expect(wins(1, 'z', existingTs: 2, existingDevice: 'a'), false);
    });
    test('tie goes to the greater device id', () {
      expect(wins(1, 'b', existingTs: 1, existingDevice: 'a'), true);
      expect(wins(1, 'a', existingTs: 1, existingDevice: 'b'), false);
      expect(wins(1, 'a', existingTs: 1, existingDevice: 'a'), false);
    });
  });
}
