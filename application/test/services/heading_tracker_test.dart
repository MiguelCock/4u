import 'dart:math';

import 'package:eyes4u/services/geo_utils.dart';
import 'package:eyes4u/services/heading_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime(2026, 10, 27, 12);
DateTime _at(double seconds) =>
    _t0.add(Duration(microseconds: (seconds * 1e6).round()));

/// Turns [degrees] (positive = right/clockwise) over [seconds] with the
/// phone held upright (y axis up), from [start] seconds.
double _turn(
  HeadingTracker t,
  double degrees, {
  double start = 0,
  double seconds = 2,
  bool upright = true,
}) {
  const step = 0.02;
  final rate = -degrees * pi / 180 / seconds; // CCW positive
  var s = start;
  for (var i = 0; i <= (seconds / step).round(); i++) {
    if (upright) {
      t.accelerometer(0, 9.81, 0);
      t.gyro(0, rate, 0, _at(s));
    } else {
      t.accelerometer(0, 0, 9.81);
      t.gyro(0, 0, rate, _at(s));
    }
    s += step;
  }
  return s;
}

void main() {
  test('a 90 degree turn reads 90 even when the compass says 70', () {
    final t = HeadingTracker();
    t.accelerometer(0, 9.81, 0);
    t.compass(0, _at(0));
    t.gyro(0, 0, 0, _at(0));
    final end = _turn(t, -90, start: 0.02);
    t.compass(290, _at(end)); // the compass only saw 70 degrees
    expect(signedTurn(t.value!, 270).abs(), lessThan(2));
    expect(t.source, 'gyro+compass');
  });

  test('works with the phone flat too', () {
    final t = HeadingTracker();
    t.accelerometer(0, 0, 9.81);
    t.compass(100, _at(0));
    t.gyro(0, 0, 0, _at(0));
    _turn(t, 45, start: 0.02, upright: false);
    expect(t.value, closeTo(145, 1));
  });

  test('walking a steady course corrects a wrong start', () {
    final t = HeadingTracker();
    t.accelerometer(0, 9.81, 0);
    t.compass(115, _at(0)); // 25 degrees off: really facing 90
    for (var s = 0; s <= 10; s++) {
      t.gyro(0, 0, 0, _at(s.toDouble()));
      t.gpsCourse(90, 1.2, _at(s.toDouble()));
    }
    expect(signedTurn(t.value!, 90).abs(), lessThan(2));
    expect(t.source, 'gyro+gps');
    // ...and the disturbed compass no longer pulls it back.
    t.compass(150, _at(11));
    t.compass(150, _at(20));
    expect(signedTurn(t.value!, 90).abs(), lessThan(2));
  });

  test('slow or jumpy GPS courses are ignored', () {
    final t = HeadingTracker();
    t.accelerometer(0, 9.81, 0);
    t.compass(0, _at(0));
    t.gyro(0, 0, 0, _at(0));
    for (var s = 1; s <= 5; s++) {
      t.gpsCourse(90, 0.3, _at(s.toDouble()));
    }
    expect(t.value, closeTo(0, 1e-9));
    for (var s = 6; s <= 10; s++) {
      t.gpsCourse(s.isEven ? 60 : 120, 1.2, _at(s.toDouble()));
    }
    expect(t.value, closeTo(0, 1e-9));
  });

  test('wraps around north', () {
    final t = HeadingTracker();
    t.accelerometer(0, 9.81, 0);
    t.compass(350, _at(0));
    t.gyro(0, 0, 0, _at(0));
    _turn(t, 20, start: 0.02);
    expect(t.value, closeTo(10, 1));
    for (var s = 3; s <= 15; s++) {
      t.gpsCourse(355, 1.0, _at(s.toDouble()));
    }
    expect(signedTurn(t.value!, 355).abs(), lessThan(1));
  });

  test('without a gyroscope it is just the compass', () {
    final t = HeadingTracker();
    t.compass(40, _at(0));
    t.compass(50, _at(1));
    expect(t.value, 50);
    expect(t.source, 'compass');
  });
}
