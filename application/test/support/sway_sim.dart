import 'dart:math';

import 'package:eyes4u/services/heading_tracker.dart';

/// A synthetic walk for [HeadingTracker] (#263): a phone held upright in
/// front of the chest (device y up, z towards the user, camera forward),
/// walking with step bounce and surge, sideways sway, and a steady lean,
/// through turns at known times. Feeds 50 Hz accelerometer and gyroscope
/// readings built from the true orientation, and returns the tracker's
/// heading error (degrees, signed) at each sample.
///
/// World frame: x east, y up, z south. Heading is clockwise from north.
class SwayWalk {
  SwayWalk({
    this.leanDeg = 0,
    this.swayDeg = 0,
    this.bounce = 0,
    this.surge = 0,
    this.stepHz = 2,
    this.yawSwayDeg = 0,
    this.turns = const [],
  });

  final double leanDeg; // steady forward/back tilt of the phone (pitch)
  final double swayDeg; // side-to-side roll amplitude, at half the step rate
  final double bounce; // vertical step acceleration amplitude, m/s²
  final double surge; // forward step acceleration amplitude, m/s²
  final double stepHz;

  /// The phone's direction swinging left and right with the steps (a real
  /// turn of the phone, at half the step rate), degrees.
  final double yawSwayDeg;

  /// (start s, degrees right, duration s).
  final List<(double, double, double)> turns;

  static const rate = 50.0;
  static const g = 9.81;

  double trueHeading(double t) {
    var h = yawSwayDeg * sin(2 * pi * stepHz / 2 * t);
    for (final (start, deg, dur) in turns) {
      if (t >= start + dur) {
        h += deg;
      } else if (t > start) {
        h += deg * (t - start) / dur;
      }
    }
    return h;
  }

  /// Device-to-world rotation at [t]: heading (about up), then pitch (about
  /// the device x axis), then roll (about the device z axis).
  List<List<double>> _rotation(double t) {
    final yaw = -trueHeading(t) * pi / 180; // CCW positive about up
    final pitch = leanDeg * pi / 180;
    final roll = swayDeg * pi / 180 * sin(2 * pi * stepHz / 2 * t);
    return _mul(_mul(_rotY(yaw), _rotX(pitch)), _rotZ(roll));
  }

  /// Runs [seconds] and returns the heading error at every sample.
  List<double> run(HeadingTracker tracker, double seconds, DateTime t0) {
    final errors = <double>[];
    final dt = 1 / rate;
    var prev = _rotation(0);
    // Start where it really faces (heading 0).
    tracker.compass(0, t0);
    for (var i = 1; i <= (seconds * rate).round(); i++) {
      final t = i * dt;
      final r = _rotation(t);
      final at = t0.add(Duration(microseconds: (t * 1e6).round()));
      // Specific force in the world: gravity's reaction (up) plus the
      // step's linear acceleration (vertical bounce, forward surge).
      final h = trueHeading(t) * pi / 180;
      final up = g + bounce * sin(2 * pi * stepHz * t);
      final fwd = surge * sin(2 * pi * stepHz * t + pi / 2);
      final world = [fwd * sin(h), up, -fwd * cos(h)];
      final dev = _apply(_transpose(r), world);
      tracker.accelerometer(dev[0], dev[1], dev[2]);
      // Body rate from the rotation between samples: R_prev^T R ≈ I + [ω]dt.
      final d = _mul(_transpose(prev), r);
      tracker.gyro(
        (d[2][1] - d[1][2]) / 2 / dt,
        (d[0][2] - d[2][0]) / 2 / dt,
        (d[1][0] - d[0][1]) / 2 / dt,
        at,
      );
      prev = r;
      final value = tracker.value;
      if (value != null) {
        final e = ((value - trueHeading(t)) % 360 + 540) % 360 - 180;
        errors.add(e);
      }
    }
    return errors;
  }
}

List<List<double>> _rotX(double a) => [
  [1, 0, 0],
  [0, cos(a), -sin(a)],
  [0, sin(a), cos(a)],
];
List<List<double>> _rotY(double a) => [
  [cos(a), 0, sin(a)],
  [0, 1, 0],
  [-sin(a), 0, cos(a)],
];
List<List<double>> _rotZ(double a) => [
  [cos(a), -sin(a), 0],
  [sin(a), cos(a), 0],
  [0, 0, 1],
];

List<List<double>> _mul(List<List<double>> a, List<List<double>> b) => [
  for (var i = 0; i < 3; i++)
    [
      for (var j = 0; j < 3; j++)
        a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j],
    ],
];
List<List<double>> _transpose(List<List<double>> a) => [
  for (var j = 0; j < 3; j++) [for (var i = 0; i < 3; i++) a[i][j]],
];
List<double> _apply(List<List<double>> a, List<double> v) => [
  for (var i = 0; i < 3; i++) a[i][0] * v[0] + a[i][1] * v[1] + a[i][2] * v[2],
];
