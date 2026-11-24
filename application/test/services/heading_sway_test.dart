import 'package:eyes4u/services/heading_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/sway_sim.dart';

double _worst(List<double> errors) =>
    errors.map((e) => e.abs()).reduce((a, b) => a > b ? a : b);

void main() {
  final t0 = DateTime(2026, 11, 24, 12);
  const turns = [(10.0, 90.0, 2.0), (25.0, -90.0, 2.0)];

  test('sanity: a still, upright phone through two turns stays right', () {
    final errors = SwayWalk(turns: turns).run(HeadingTracker(), 40, t0);
    expect(_worst(errors.skip(10).toList()), lessThan(2));
  });

  // Ordinary walking: the heading stays within 5°.
  for (final (name, walk) in [
    ('a 15° lean', SwayWalk(leanDeg: 15, turns: turns)),
    ('step bounce and surge', SwayWalk(bounce: 2.5, surge: 1.5, turns: turns)),
    (
      'sway, lean and steps together',
      SwayWalk(leanDeg: 15, swayDeg: 8, bounce: 2.5, surge: 1.5, turns: turns),
    ),
  ]) {
    test('$name: within 5° through two turns (#263)', () {
      final errors = walk.run(HeadingTracker(), 40, t0);
      expect(_worst(errors.skip(10).toList()), lessThan(5));
    });
  }

  // Extreme motion reaches 11-12° today. A slower, gated or faster gravity
  // filter each did worse on these (#263), so they pin today's level.
  for (final (name, walk) in [
    (
      '30° lean, 20° sway, hard steps',
      SwayWalk(leanDeg: 30, swayDeg: 20, bounce: 5, surge: 3, turns: turns),
    ),
    (
      'slow 1 Hz steps, 25° sway',
      SwayWalk(
        leanDeg: 20,
        swayDeg: 25,
        bounce: 4,
        surge: 3,
        stepHz: 1,
        turns: turns,
      ),
    ),
  ]) {
    test('$name: no worse than 15°', () {
      final errors = walk.run(HeadingTracker(), 40, t0);
      expect(_worst(errors.skip(10).toList()), lessThan(15));
    });
  }

  test('the phone swinging with each step is followed, and measured', () {
    final tracker = HeadingTracker();
    final errors = SwayWalk(
      yawSwayDeg: 12,
      bounce: 2.5,
      turns: turns,
    ).run(tracker, 40, t0);
    // It's a real swing of the phone, so the tracker follows it...
    expect(_worst(errors.skip(10).toList()), lessThan(3));
    // ...and swayDeg reports it: about twice the amplitude.
    final sway = tracker.swayDeg(t0.add(const Duration(seconds: 40)))!;
    expect(sway, closeTo(24, 3));
  });

  test('pitch and roll read how the phone is held', () {
    final tracker = HeadingTracker();
    SwayWalk(leanDeg: 15).run(tracker, 5, t0);
    expect(tracker.pitchDeg!.abs(), closeTo(15, 1));
    expect(tracker.rollDeg!.abs(), lessThan(1));
  });
}
