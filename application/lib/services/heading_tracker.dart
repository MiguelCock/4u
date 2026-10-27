import 'dart:math';

import 'geo_utils.dart';

/// Which way the user faces (degrees from true north), for guidance.
///
/// The compass alone wasn't good enough: in a field test it registered
/// about 70° for every real 90° left turn, so its error grew by ~20° at
/// each corner and guidance kept saying "turn left" on the third straight
/// while the user faced the right way. Here the gyroscope measures how far
/// the user turns, and absolute direction comes from the GPS course while
/// walking a steady straight. The compass only sets the starting direction,
/// and pulls weakly when there's been no walking to anchor to for a while.
///
/// Pure: the screen feeds it sensor readings, the tests feed it numbers.
class HeadingTracker {
  HeadingTracker({
    this.gpsTimeConstant = const Duration(seconds: 3),
    this.compassTimeConstant = const Duration(seconds: 60),
    this.gpsAnchorFor = const Duration(seconds: 60),
    this.minWalkingSpeed = 0.7,
    this.maxCourseSpread = 20,
  });

  /// How fast a steady walking course pulls the heading.
  final Duration gpsTimeConstant;

  /// How fast the compass pulls it, when it pulls at all.
  final Duration compassTimeConstant;

  /// After a GPS anchor, the compass is ignored this long.
  final Duration gpsAnchorFor;

  /// GPS course counts only at this speed (m/s) or faster.
  final double minWalkingSpeed;

  /// ...and only when the last 3 such courses stay within this (degrees).
  final double maxCourseSpread;

  double? _heading;
  bool _hasGyro = false;
  List<double>? _gravity;
  DateTime? _lastGyro;
  DateTime? _lastCompass;
  DateTime? _lastGps;
  DateTime? _gpsAnchoredAt;
  final List<({double course, DateTime at})> _courses = [];

  /// Degrees from true north (0-360), or null before any reading.
  double? get value => _heading == null ? null : _wrap(_heading!);

  /// `gyro+gps` (anchored to walking recently), `gyro+compass`, or
  /// `compass` (no gyroscope: just the smoothed compass).
  String get source {
    if (!_hasGyro) return 'compass';
    final anchored = _gpsAnchoredAt;
    return anchored != null &&
            (_lastGyro ?? anchored).difference(anchored) < gpsAnchorFor
        ? 'gyro+gps'
        : 'gyro+compass';
  }

  /// Accelerometer reading (m/s², device axes). At rest it points up, so
  /// its low-passed direction is the vertical the gyro is projected on.
  void accelerometer(double x, double y, double z) {
    final g = _gravity;
    if (g == null) {
      _gravity = [x, y, z];
      return;
    }
    const alpha = 0.1;
    g[0] += alpha * (x - g[0]);
    g[1] += alpha * (y - g[1]);
    g[2] += alpha * (z - g[2]);
  }

  /// Gyroscope reading (rad/s, device axes, counter-clockwise positive).
  /// Its component about the vertical is the turn rate, however the phone
  /// is held; counter-clockwise seen from above lowers the heading.
  void gyro(double x, double y, double z, DateTime at) {
    final last = _lastGyro;
    _lastGyro = at;
    final g = _gravity;
    if (g == null || last == null) return;
    final norm = sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
    if (norm < 1e-3) return;
    _hasGyro = true;
    final heading = _heading;
    if (heading == null) return;
    // A gap (app paused) isn't integrated: the rate is unknown in it.
    final dt = min(at.difference(last).inMicroseconds / 1e6, 0.2);
    if (dt <= 0) return;
    final up = (x * g[0] + y * g[1] + z * g[2]) / norm;
    _heading = heading - up * dt * 180 / pi;
  }

  /// Smoothed compass, already corrected to true north.
  void compass(double trueDegrees, DateTime at) {
    final last = _lastCompass;
    _lastCompass = at;
    final heading = _heading;
    if (heading == null || !_hasGyro) {
      // The start, or a phone without a gyroscope: the compass is all
      // there is.
      _heading = trueDegrees;
      return;
    }
    final anchored = _gpsAnchoredAt;
    if (anchored != null && at.difference(anchored) < gpsAnchorFor) return;
    if (last == null) return;
    _pull(trueDegrees, at.difference(last), compassTimeConstant);
  }

  /// GPS direction of travel (true north) and speed.
  void gpsCourse(double course, double speed, DateTime at) {
    final last = _lastGps;
    _lastGps = at;
    if (speed < minWalkingSpeed || course.isNaN) {
      _courses.clear();
      return;
    }
    _courses.add((course: course, at: at));
    _courses.removeWhere(
      (c) => at.difference(c.at) > const Duration(seconds: 5),
    );
    while (_courses.length > 3) {
      _courses.removeAt(0);
    }
    if (_courses.length < 3) return;
    final reference = _courses.last.course;
    final spread = _courses
        .map((c) => signedTurn(reference, c.course).abs())
        .reduce(max);
    if (spread > maxCourseSpread) return;
    _gpsAnchoredAt = at;
    if (_heading == null) {
      _heading = course;
      return;
    }
    if (last == null) return;
    final dt = at.difference(last);
    _pull(
      course,
      dt > const Duration(seconds: 2) ? const Duration(seconds: 2) : dt,
      gpsTimeConstant,
    );
  }

  void _pull(double target, Duration dt, Duration timeConstant) {
    final seconds = dt.inMicroseconds / 1e6;
    if (seconds <= 0) return;
    final alpha = 1 - exp(-seconds / (timeConstant.inMicroseconds / 1e6));
    _heading = _heading! + alpha * signedTurn(_heading!, target);
  }

  static double _wrap(double degrees) => (degrees % 360 + 360) % 360;
}
