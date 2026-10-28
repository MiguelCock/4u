import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/turn_guidance.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('rounding', () {
    test('turns are spoken as slight, normal or around', () {
      expect(TurnCue.from(40).kind, TurnKind.slight);
      expect(TurnCue.from(-90).kind, TurnKind.normal);
      expect(TurnCue.from(140).kind, TurnKind.normal);
      expect(TurnCue.from(-170).kind, TurnKind.around);
    });

    test('distances are spoken as steps, coarser as they grow', () {
      expect(roundSteps(0.3), 1);
      expect(roundSteps(4.2), 6);
      expect(roundSteps(28), 40);
      expect(roundSteps(84), 120);
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
      expect(first.kind, TurnKind.normal);

      // Turning: aligned but not yet held long enough.
      expect(g.update(turn: 10, metersToTarget: 15, now: at(1000)), isNull);
      expect(g.update(turn: 5, metersToTarget: 15, now: at(2000)), isNull);
      final walk = g.update(turn: 4, metersToTarget: 15, now: at(2600));
      expect(walk, isA<StartWalkingCue>());
      expect((walk as StartWalkingCue).steps, 20);
      expect(g.walking, isTrue);
    });

    test('does not repeat the same turn instruction constantly', () {
      final g = TurnGuidance()..reset(now: t0);
      expect(
        g.update(turn: -90, metersToTarget: 10, now: at(0)),
        isA<TurnCue>(),
      );
      expect(g.update(turn: -88, metersToTarget: 10, now: at(5000)), isNull);
      // A meaningful change after the minimum gap is announced, once the
      // user has stopped turning...
      expect(g.update(turn: -40, metersToTarget: 10, now: at(5500)), isNull);
      expect(
        g.update(turn: -40, metersToTarget: 10, now: at(6600)),
        isA<TurnCue>(),
      );
      // ...and so is no change at all after the idle repeat.
      expect(
        g.update(turn: -40, metersToTarget: 10, now: at(17000)),
        isA<TurnCue>(),
      );
    });

    test('walking stays quiet until a sustained drift', () {
      final g = TurnGuidance()..reset(now: t0, walking: true);
      // Samples every 500 ms, like the app. 40° is within the 50° margin.
      for (var ms = 0; ms <= 2000; ms += 500) {
        expect(g.update(turn: 40, metersToTarget: 10, now: at(ms)), isNull);
      }
      // A real drift has to hold for the whole 5 s window.
      GuidanceCue? cue;
      var cuedAt = 0;
      for (var ms = 2500; ms <= 10000 && cue == null; ms += 500) {
        cue = g.update(turn: 70, metersToTarget: 10, now: at(ms));
        if (ms < 7000) expect(cue, isNull, reason: 'too early at $ms');
        cuedAt = ms;
      }
      expect(cue, isA<TurnCue>());
      // One correction, then quiet: still walking, no repeat for 10 s.
      expect(g.walking, isTrue);
      for (var ms = cuedAt + 500; ms < cuedAt + 10000; ms += 500) {
        expect(g.update(turn: 70, metersToTarget: 10, now: at(ms)), isNull);
      }
    });

    test('says nothing without a reliable heading', () {
      final g = TurnGuidance()..reset(now: t0);
      for (var ms = 0; ms <= 20000; ms += 500) {
        expect(
          g.update(turn: 90, metersToTarget: 10, now: at(ms), reliable: false),
          isNull,
        );
      }
    });

    test('compass sway while walking is ignored', () {
      final g = TurnGuidance()..reset(now: t0, walking: true);
      // Swinging ±60° every other sample: the median stays small.
      for (var i = 0; i < 20; i++) {
        final turn = i.isEven ? 60.0 : -5.0;
        expect(
          g.update(turn: turn, metersToTarget: 10, now: at(i * 500)),
          isNull,
        );
      }
      expect(g.walking, isTrue);
    });

    test('30 degrees off while walking no longer triggers a turn', () {
      final g = TurnGuidance()..reset(now: t0, walking: true);
      for (var ms = 0; ms <= 10000; ms += 500) {
        expect(g.update(turn: 30, metersToTarget: 20, now: at(ms)), isNull);
      }
    });

    test('an already-announced turn is not repeated right away', () {
      final g = TurnGuidance()..reset(now: t0, announcedTurn: 45);
      expect(g.update(turn: 45, metersToTarget: 10, now: at(500)), isNull);
    });
  });

  test('heading smoother wraps around north', () {
    final s = HeadingSmoother();
    s.add(350, at: t0);
    // After one time constant the estimate is ~63% of the way.
    final v = s.add(10, at: at(1000));
    expect(v, anyOf(closeTo(2.6, 1), closeTo(362.6, 1)));
  });

  test('heading smoothing is by time, not by number of readings', () {
    final fast = HeadingSmoother();
    final slow = HeadingSmoother();
    fast.add(0, at: t0);
    slow.add(0, at: t0);
    // The same 0.5 s of readings at 90°: 16 readings vs 1.
    for (var i = 1; i <= 16; i++) {
      fast.add(90, at: at(i * 32));
    }
    slow.add(90, at: at(512));
    expect(fast.value, closeTo(slow.value!, 6));
    // Half a second of a 90° jump moves it well under halfway.
    expect(fast.value!, lessThan(45));
  });

  test('true heading adds the declination', () {
    expect(trueHeading(10, -7.5), closeTo(2.5, 1e-9));
    expect(trueHeading(3, -7.5), closeTo(355.5, 1e-9));
  });

  group('arrivalRadius', () {
    test('scales with GPS accuracy within 5-15 m', () {
      expect(arrivalRadius(gpsAccuracy: 3), 6);
      expect(arrivalRadius(gpsAccuracy: 1), 5);
      expect(arrivalRadius(gpsAccuracy: 20), 15);
    });

    test('a short last leg is never swallowed by the radius', () {
      // The field test: a 12.8 m last leg ended the trip at its corner.
      final radius = arrivalRadius(gpsAccuracy: 8, lastLegMeters: 12.8);
      expect(radius, lessThan(12.8));
      expect(radius, closeTo(6.4, 1e-9));
    });

    test('a long last leg keeps the accuracy-based radius', () {
      expect(arrivalRadius(gpsAccuracy: 5, lastLegMeters: 40), 10);
    });
  });

  group('turning in progress', () {
    test('no repeat while the user is still rotating', () {
      final g = TurnGuidance()..reset(now: t0);
      expect(
        g.update(turn: -90, metersToTarget: 40, now: at(0)),
        isA<TurnCue>(),
      );
      // A 90-degree turn over 2 s, sampled every 0.5 s: never re-cued.
      for (final (ms, turn) in [
        (4500, -70.0),
        (5000, -55.0),
        (5500, -40.0),
        (6000, -30.0),
      ]) {
        expect(g.update(turn: turn, metersToTarget: 40, now: at(ms)), isNull);
      }
    });

    test('stopping halfway re-cues once it settles', () {
      final g = TurnGuidance()..reset(now: t0);
      expect(
        g.update(turn: -90, metersToTarget: 40, now: at(0)),
        isA<TurnCue>(),
      );
      expect(g.update(turn: -70, metersToTarget: 40, now: at(4500)), isNull);
      expect(g.update(turn: -50, metersToTarget: 40, now: at(5000)), isNull);
      expect(g.update(turn: -50, metersToTarget: 40, now: at(5500)), isNull);
      final cue = g.update(turn: -50, metersToTarget: 40, now: at(6100));
      expect(cue, isA<TurnCue>());
      expect((cue as TurnCue).kind, TurnKind.slight);
    });
  });

  group('cornerProgress', () {
    test('approaching, then a heads-up, then reached at the corner', () {
      expect(
        cornerProgress(metersToCorner: 20, alongRemaining: 20, crossTrack: 1),
        CornerProgress.approaching,
      );
      expect(
        cornerProgress(metersToCorner: 7, alongRemaining: 7, crossTrack: 1),
        CornerProgress.warn,
      );
      expect(
        cornerProgress(metersToCorner: 3.5, alongRemaining: 2.5, crossTrack: 2),
        CornerProgress.reached,
      );
    });

    test('far to the side, along-track progress alone does not count', () {
      expect(
        cornerProgress(metersToCorner: 20, alongRemaining: 1, crossTrack: 19),
        CornerProgress.approaching,
      );
    });

    test('already turned onto the next leg near the corner counts', () {
      expect(
        cornerProgress(
          metersToCorner: 5,
          alongRemaining: 5,
          crossTrack: 1,
          heading: 355,
          legBearing: 90,
          nextLegBearing: 0,
        ),
        CornerProgress.reached,
      );
      // Still facing along the current leg: just the heads-up.
      expect(
        cornerProgress(
          metersToCorner: 5,
          alongRemaining: 5,
          crossTrack: 1,
          heading: 85,
          legBearing: 90,
          nextLegBearing: 0,
        ),
        CornerProgress.warn,
      );
    });
  });
}
