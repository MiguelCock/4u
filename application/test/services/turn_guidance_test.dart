import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/turn_guidance.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('rounding', () {
    test('turns round to 15-degree steps, never zero', () {
      expect(roundTurnDegrees(3), 15);
      expect(roundTurnDegrees(44), 45);
      expect(roundTurnDegrees(97), 90);
    });

    test('distances get coarser as they grow', () {
      expect(roundMeters(0.4), 1);
      expect(roundMeters(7.6), 8);
      expect(roundMeters(23), 25);
      expect(roundMeters(84), 80);
    });

    test('a turn above 150 degrees is "turn around"', () {
      expect(TurnCue.from(170).turnAround, isTrue);
      expect(TurnCue.from(-90).turnAround, isFalse);
      expect(TurnCue.from(-90).right, isFalse);
    });
  });

  group('TurnGuidance', () {
    test('says the turn first, then start walking once aligned', () {
      final g = TurnGuidance()..reset(now: t0);
      final first = g.update(turn: 90, metersToTarget: 15, now: at(0));
      expect(first, isA<TurnCue>());
      expect((first as TurnCue).right, isTrue);
      expect(first.degrees, 90);

      // Turning: aligned but not yet held long enough.
      expect(g.update(turn: 10, metersToTarget: 15, now: at(1000)), isNull);
      expect(g.update(turn: 5, metersToTarget: 15, now: at(2000)), isNull);
      final walk = g.update(turn: 4, metersToTarget: 15, now: at(2600));
      expect(walk, isA<StartWalkingCue>());
      expect((walk as StartWalkingCue).meters, 15);
      expect(g.walking, isTrue);
    });

    test('does not repeat the same turn instruction constantly', () {
      final g = TurnGuidance()..reset(now: t0);
      expect(
        g.update(turn: -90, metersToTarget: 10, now: at(0)),
        isA<TurnCue>(),
      );
      expect(g.update(turn: -88, metersToTarget: 10, now: at(5000)), isNull);
      // A meaningful change after the minimum gap is announced...
      expect(
        g.update(turn: -40, metersToTarget: 10, now: at(5500)),
        isA<TurnCue>(),
      );
      // ...and so is no change at all after the idle repeat.
      expect(
        g.update(turn: -40, metersToTarget: 10, now: at(16000)),
        isA<TurnCue>(),
      );
    });

    test('walking stays quiet until a sustained drift', () {
      final g = TurnGuidance()..reset(now: t0, walking: true);
      expect(g.update(turn: 30, metersToTarget: 10, now: at(0)), isNull);
      expect(g.update(turn: 60, metersToTarget: 10, now: at(1000)), isNull);
      expect(g.update(turn: 60, metersToTarget: 10, now: at(3500)), isNull);
      final cue = g.update(turn: 60, metersToTarget: 10, now: at(4100));
      expect(cue, isA<TurnCue>());
      expect(g.walking, isFalse);
    });

    test('a brief glance away while walking is ignored', () {
      final g = TurnGuidance()..reset(now: t0, walking: true);
      expect(g.update(turn: 90, metersToTarget: 10, now: at(0)), isNull);
      expect(g.update(turn: 5, metersToTarget: 10, now: at(1000)), isNull);
      expect(g.update(turn: 90, metersToTarget: 10, now: at(3500)), isNull);
      expect(g.walking, isTrue);
    });

    test('an already-announced turn is not repeated right away', () {
      final g = TurnGuidance()..reset(now: t0, announcedTurn: 45);
      expect(g.update(turn: 45, metersToTarget: 10, now: at(500)), isNull);
    });
  });

  test('heading smoother wraps around north', () {
    final s = HeadingSmoother(alpha: 0.5);
    s.add(350);
    expect(s.add(10), anyOf(closeTo(0, 1), closeTo(360, 1)));
  });
}
