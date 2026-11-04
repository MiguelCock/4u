import 'package:flutter_test/flutter_test.dart';

import 'package:eyes4u/services/floor_detector.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);
  DateTime at(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));

  /// Readings every 200 ms from [from] to [to] seconds.
  void feed(
    FloorChangeDetector d,
    double Function(double s) pressure,
    num from,
    num to,
  ) {
    for (var s = from.toDouble(); s <= to; s += 0.2) {
      d.add(pressure(s), at(s));
    }
  }

  FloorChangeDetector waiting(int floors) {
    final d = FloorChangeDetector();
    feed(d, (_) => 900.0, 0, 6);
    d.start(floors, now: at(6));
    return d;
  }

  /// [floors] floors at 0.36 hPa each, over [seconds], from t=6.
  double Function(double) climb(int floors, num seconds) =>
      (s) => 900.0 - floors * 0.36 * ((s - 6) / seconds).clamp(0.0, 1.0);

  test('a climb is heard once it has held', () {
    final d = waiting(1);
    feed(d, climb(1, 15), 6, 25);
    expect(d.reached, isTrue);
    expect(d.delta, closeTo(-0.36, 0.05));
  });

  test('not before it has climbed', () {
    final d = waiting(1);
    feed(d, climb(1, 15), 6, 12);
    expect(d.reached, isFalse);
  });

  test('a descent', () {
    final d = waiting(-1);
    feed(d, (s) => 900.0 + 0.36 * ((s - 6) / 15).clamp(0.0, 1.0), 6, 25);
    expect(d.reached, isTrue);
  });

  test('going the wrong way does not count', () {
    final d = waiting(1);
    feed(d, (s) => 900.0 + 0.36 * ((s - 6) / 15).clamp(0.0, 1.0), 6, 40);
    expect(d.reached, isFalse);
  });

  test('a gust or a door does not count', () {
    final d = waiting(1);
    feed(d, (s) => s > 10 && s < 12 ? 899.5 : 900.0, 6, 40);
    expect(d.reached, isFalse);
  });

  test('a slow change in the weather does not count in 3 minutes', () {
    final d = waiting(1);
    // 1 hPa in 3 hours is already a fast change.
    feed(d, (s) => 900.0 - (s - 6) / 10800, 6, 186);
    expect(d.reached, isFalse);
  });

  test('two floors need twice the change', () {
    final d = waiting(2);
    feed(d, climb(1, 15), 6, 40);
    expect(d.reached, isFalse, reason: 'got off a floor early');
    feed(d, climb(2, 30), 40, 80);
    expect(d.reached, isTrue);
  });

  test('with no recent reading, the first one is the baseline', () {
    final d = FloorChangeDetector()..start(1, now: at(0));
    feed(d, (s) => 900.0 - 0.36 * (s / 15).clamp(0.0, 1.0), 0, 25);
    expect(d.reached, isTrue);
  });

  test('stop forgets the wait', () {
    final d = waiting(1)..stop();
    feed(d, climb(1, 15), 6, 25);
    expect(d.reached, isFalse);
    expect(d.delta, isNull);
    expect(d.pressure, isNotNull);
  });
}
